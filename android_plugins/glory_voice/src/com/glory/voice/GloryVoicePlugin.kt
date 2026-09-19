package com.glory.voice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.audiofx.AcousticEchoCanceler
import android.util.Log
import com.twilio.audioswitch.AudioDevice
import io.livekit.android.AudioOptions
import io.livekit.android.AudioType
import io.livekit.android.LiveKit
import io.livekit.android.LiveKitOverrides
import io.livekit.android.audio.AudioSwitchHandler
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.room.Room
import io.livekit.android.room.participant.Participant
import io.livekit.android.room.track.RemoteAudioTrack
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger

/**
 * 组队语音的安卓桥接（docs/语音LiveKit方案.md 5.1）：把 LiveKit 安卓开发包包成
 * scripts/autoload/VoiceService.gd 的 BRIDGE_METHODS 那一套方法。录音、回声消除、编码、网络、播放都是 LiveKit 做的，
 * 这里只管「进哪个房间、开不开麦、谁的音量是多少」和把状态报给 VoiceService。
 *
 * 声音模式只能在建房间时定（LiveKit 的 AudioType）：
 *   只听  MediaAudioType —— 媒体声道，系统不进通话模式，蓝牙耳机保持高音质，游戏声不受影响
 *   开麦  CallAudioType  —— 通话模式，系统回声消除；默认从外放出声（LiveKit 默认顺序：蓝牙 > 有线 > 外放 > 听筒）
 * 所以「只听 ↔ 开麦」要重进一次房间：getCapabilities 报 listen_mode_fixed_at_join = true，由 VoiceService 去重进。
 *
 * 线程：Godot 在它自己的线程上调这些方法。LiveKit 的操作全部投到主线程（main 协程作用域）；
 * getStatus 读的是主线程写好的快照（lock 保护）。每次进房 / 离开都换一个 generation，
 * 旧房间迟到的事件一律丢掉 —— 否则「刚退的房间」的断开事件会把新房间标成失败。
 */
class GloryVoicePlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val TAG = "GloryVoice"
        // 与 build.gradle.kts、addons/glory_voice/glory_voice_plugin.gd 一致（tools/voice_check 对账）。
        const val LIVEKIT_VERSION = "2.28.2"
        private const val STATUS_INTERVAL_MS = 250L
    }

    private val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val generation = AtomicInteger(0)

    // 只在主线程读写。
    private var room: Room? = null
    private var roomJob: Job? = null
    private var roomListenOnly = true
    private var wantMic = false
    // 语音身份 -> 音量（0 = 屏蔽）。新订阅到的声音按它设；跨房间保留（屏蔽跟着人走）。
    private val volumes = HashMap<String, Double>()

    // 给 getStatus 的快照（Godot 线程读，主线程写）。
    private val lock = Any()
    private var state = "disconnected"
    private var error = ""
    private var micOn = false
    private var micError = ""
    private var selfSpeaking = false
    private var speaking: List<String> = emptyList()
    private var participants: List<String> = emptyList()
    private var audioMode = ""
    private var output = ""

    override fun getPluginName(): String = "GloryVoice"

    @UsedByGodot
    fun hasRecordPermission(): Boolean {
        val ctx: Context = activity ?: return false
        return ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    }

    /** 开始连（异步）。空串 = 已开始；进展看 getStatus 的 state。 */
    @UsedByGodot
    fun joinRoom(url: String, token: String, listenOnly: Boolean): String {
        val ctx = activity?.applicationContext ?: return "no_activity"
        if (url.isBlank() || token.isBlank()) return "bad_args"
        val gen = generation.incrementAndGet()
        synchronized(lock) {
            state = "connecting"
            error = ""
            micOn = false
            micError = ""
            selfSpeaking = false
            speaking = emptyList()
            participants = emptyList()
            audioMode = if (listenOnly) "media" else "call"
            output = ""
        }
        main.launch {
            // 新房间默认不开麦；要开麦由 VoiceService 随后调 setMicrophoneEnabled（排在这之后，连上就生效）。
            wantMic = false
            teardown()
            if (generation.get() == gen) startRoom(gen, ctx, url, token, listenOnly)
        }
        return ""
    }

    @UsedByGodot
    fun leaveRoom() {
        generation.incrementAndGet()
        synchronized(lock) {
            state = "disconnected"
            error = ""
            micOn = false
            micError = ""
            selfSpeaking = false
            speaking = emptyList()
            participants = emptyList()
            audioMode = ""
            output = ""
        }
        main.launch {
            wantMic = false
            teardown()
        }
    }

    /** 开 / 关麦。还没连上时先记下，连上再生效；失败（异步）写进 getStatus 的 mic_error。 */
    @UsedByGodot
    fun setMicrophoneEnabled(enabled: Boolean): String {
        if (enabled && !hasRecordPermission()) return "no_permission"
        val gen = generation.get()
        synchronized(lock) { micError = "" }
        main.launch {
            wantMic = enabled
            val r = room ?: return@launch
            if (r.state == Room.State.CONNECTED) applyMic(gen, r, enabled)
        }
        return ""
    }

    /** 某个队友的音量，0 ~ 1（0 = 屏蔽，只影响自己）。 */
    @UsedByGodot
    fun setParticipantVolume(identity: String, volume: Double) {
        val v = volume.coerceIn(0.0, 10.0)
        main.launch {
            volumes[identity] = v
            val p = room?.remoteParticipants?.get(Participant.Identity(identity)) ?: return@launch
            for (publication in p.trackPublications.values) {
                (publication.track as? RemoteAudioTrack)?.setVolume(v)
            }
        }
    }

    @UsedByGodot
    fun getStatus(): String {
        val o = JSONObject()
        synchronized(lock) {
            o.put("state", state)
            o.put("error", error)
            o.put("mic_on", micOn)
            o.put("mic_error", micError)
            o.put("self_speaking", selfSpeaking)
            o.put("speaking", JSONArray(speaking))
            o.put("participants", JSONArray(participants))
            o.put("audio_mode", audioMode)
            o.put("output", output)
        }
        return o.toString()
    }

    @UsedByGodot
    fun getCapabilities(): String {
        val o = JSONObject()
        o.put("platform", "android")
        o.put("sdk", "livekit-android $LIVEKIT_VERSION")
        // 开麦时用通话模式：有系统回声消除就用系统的，没有就是 WebRTC 自己的。
        o.put("aec", if (AcousticEchoCanceler.isAvailable()) "system" else "webrtc")
        o.put("listen_mode_fixed_at_join", true)
        return o.toString()
    }

    // 切到后台：直接断开（不申请后台录音）。报 failed/paused，VoiceService 回到前台后重新要钥匙进房。
    override fun onMainPause() {
        generation.incrementAndGet()
        main.launch {
            val wasInRoom = room != null
            wantMic = false
            teardown()
            if (wasInRoom) {
                synchronized(lock) {
                    state = "failed"
                    error = "paused"
                    micOn = false
                    speaking = emptyList()
                    participants = emptyList()
                }
            }
        }
    }

    override fun onMainDestroy() {
        generation.incrementAndGet()
        teardown()
        main.cancel()
    }

    // --- 主线程 ------------------------------------------------------------------------

    private fun startRoom(gen: Int, ctx: Context, url: String, token: String, listenOnly: Boolean) {
        val type: AudioType = if (listenOnly) AudioType.MediaAudioType() else AudioType.CallAudioType()
        val r = LiveKit.create(
            appContext = ctx,
            overrides = LiveKitOverrides(audioOptions = AudioOptions(audioOutputType = type)),
        )
        room = r
        roomListenOnly = listenOnly
        roomJob = main.launch {
            launch { r.events.collect { event -> onRoomEvent(gen, event) } }
            launch {
                while (isActive) {
                    refreshSnapshot(gen, r)
                    delay(STATUS_INTERVAL_MS)
                }
            }
            try {
                r.connect(url, token)
                if (generation.get() != gen) return@launch
                snapshot(gen) {
                    state = "connected"
                    error = ""
                }
                if (wantMic) applyMic(gen, r, true)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                Log.w(TAG, "connect failed", e)
                fail(gen, "join_failed")
            }
        }
    }

    private fun onRoomEvent(gen: Int, event: RoomEvent) {
        if (generation.get() != gen) return
        when (event) {
            is RoomEvent.Reconnecting -> snapshot(gen) { state = "reconnecting" }
            is RoomEvent.Reconnected -> snapshot(gen) { state = "connected" }
            is RoomEvent.FailedToConnect -> fail(gen, "join_failed")
            // 自己 leaveRoom 引起的断开到不了这里（generation 已经变了）。
            is RoomEvent.Disconnected -> fail(gen, disconnectCode(event.reason?.name))
            is RoomEvent.TrackSubscribed -> {
                val track = event.track as? RemoteAudioTrack ?: return
                val identity = event.participant.identity?.value ?: return
                volumes[identity]?.let { track.setVolume(it) }
            }
            else -> Unit
        }
    }

    private fun disconnectCode(reason: String?): String = when (reason) {
        "PARTICIPANT_REMOVED" -> "removed"
        "ROOM_DELETED" -> "room_deleted"
        "DUPLICATE_IDENTITY" -> "duplicate_identity"
        else -> "disconnected"
    }

    private fun applyMic(gen: Int, r: Room, enabled: Boolean) {
        main.launch {
            try {
                val ok = r.localParticipant.setMicrophoneEnabled(enabled)
                snapshot(gen) {
                    micOn = enabled && ok
                    micError = if (enabled && !ok) "mic_failed" else ""
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: SecurityException) {
                snapshot(gen) {
                    micOn = false
                    micError = "no_permission"
                }
            } catch (e: Throwable) {
                Log.w(TAG, "microphone failed", e)
                snapshot(gen) {
                    micOn = false
                    micError = "mic_failed"
                }
            }
        }
    }

    private fun refreshSnapshot(gen: Int, r: Room) {
        val me = r.localParticipant
        val talking = r.activeSpeakers.filter { it !== me }.mapNotNull { it.identity?.value }
        val others = r.remoteParticipants.keys.map { it.value }
        val device = outputName(r)
        val reconnecting = r.state == Room.State.RECONNECTING
        snapshot(gen) {
            selfSpeaking = me.isSpeaking
            speaking = talking
            participants = others
            output = device
            if (reconnecting && state == "connected") state = "reconnecting"
        }
    }

    private fun outputName(r: Room): String {
        if (roomListenOnly) return "system"   // 媒体声道：出声设备由系统决定
        return when ((r.audioHandler as? AudioSwitchHandler)?.selectedAudioDevice) {
            is AudioDevice.BluetoothHeadset -> "bluetooth"
            is AudioDevice.WiredHeadset -> "wired"
            is AudioDevice.Speakerphone -> "speaker"
            is AudioDevice.Earpiece -> "earpiece"
            else -> ""
        }
    }

    private fun fail(gen: Int, code: String) {
        snapshot(gen) {
            state = "failed"
            error = code
            micOn = false
            speaking = emptyList()
            participants = emptyList()
        }
    }

    private inline fun snapshot(gen: Int, update: () -> Unit) {
        if (generation.get() != gen) return
        synchronized(lock) { update() }
    }

    private fun teardown() {
        roomJob?.cancel()
        roomJob = null
        val r = room ?: return
        room = null
        try {
            r.disconnect()
            r.release()
        } catch (e: Throwable) {
            Log.w(TAG, "teardown failed", e)
        }
    }
}
