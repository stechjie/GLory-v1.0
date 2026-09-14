package com.glory.voice;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.AudioEffect;
import android.media.audiofx.AutomaticGainControl;
import android.media.audiofx.NoiseSuppressor;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;
import java.util.concurrent.ConcurrentLinkedQueue;

/**
 * 游戏内组队语音的安卓端（docs/聊天系统设计.md 第九节，方案 ②「自建 + 手机自带的回声消除」）。
 *
 * 分工：
 *   这里      录音（通话模式 + 系统回声消除 / 降噪 / 自动增益）、判断有没有在说话、编码打包（Opus 或 ADPCM）；
 *             收队友的包、解码、抖动缓冲、混音、用通话流播放；插拔耳机时重新选输出设备。
 *   GDScript  scripts/autoload/VoiceService.gd：什么时候开关、屏蔽谁、把包交给 ③ 转发、把收到的包交回来。
 *
 * 为什么录音不用 Godot 自带的：Godot 的安卓录音没有设置录音模式，拿不到系统的回声消除。
 * 为什么播放也在这里：回声消除要知道扬声器在放什么，队友的声音必须走「通话」这条流。
 *
 * 两层开关：
 *   startSession / stopSession  进出通话模式、开始 / 停止放队友的声音（界面上的「只听」）
 *   setCapture                  开关麦克风（「开麦」）。关麦时 AudioRecord 整个释放 ——
 *                               安卓 12 起状态栏的麦克风指示灯才会熄，玩家看得见我们没在录。
 *
 * 编码（v1.1）：一开会话就在后台跑一次 Opus 自检（OpusCodec.selfTest，整个进程只跑一次）。
 * 自检通过后，下一段话开始时把编码器从 ADPCM 换成 Opus；运行中 Opus 出错就换回 ADPCM、不再试。
 * 包头带编码字段，队友按字段挑解码器，所以混着用也听得见。
 *
 * 线程：采集线程只往队列里放包；混音线程解码并靠 AudioTrack 的阻塞写入按真实时间走。
 * **不从这些线程往 Godot 发信号**，Godot 每帧来取（readPackets）—— 跨线程发信号最容易出事。
 * 切到后台就全停（后台录音要前台服务，这一版不做），回到前台由 VoiceService 重新打开。
 */
public class GloryVoicePlugin extends GodotPlugin {
    private static final String TAG = "GloryVoice";

    public static final int SLOTS = 6;
    /** 两帧一包（40 毫秒）：包数比一帧一包少一半，头部开销也少一半。 */
    private static final int FRAMES_PER_PACKET = 2;
    /** Godot 没来取时最多攒 2 秒，再多就丢最老的：不能让内存跟着卡顿一起涨。 */
    private static final int MAX_QUEUED_PACKETS = 50;
    /** readPackets() 一次最多交出这么多：再多说明 Godot 那边卡住了，一口气灌进网络反而更糟。 */
    private static final int MAX_PACKETS_PER_READ = 12;

    /** 说话判定：声音高于「自适应噪声底 × 3」（夹在上下限之间）算在说话。 */
    private static final float VAD_MIN_THRESHOLD = 0.006f;
    private static final float VAD_MAX_THRESHOLD = 0.06f;
    /** 停顿 400 毫秒以内不算说完：不然每个字之间都会断一次。 */
    private static final int VAD_HANGOVER_FRAMES = 20;
    /** 开口前的 40 毫秒也带上：判定总慢半拍，不带的话每句话的第一个音会被吃掉。 */
    private static final int VAD_PREROLL_FRAMES = 2;
    /** 界面上「正在说话」的门槛。 */
    private static final float SPEAKING_LEVEL = 0.02f;

    /** Opus 自检结果，整个进程只跑一次：null = 还没跑、"running"、"ok"，其余是失败原因。 */
    private static volatile String opusSelfTest = null;
    private static final Object SELF_TEST_LOCK = new Object();

    private final Object lock = new Object();
    private volatile boolean sessionRunning;
    private volatile boolean capturing;
    private volatile AudioTrack player;
    private Thread mixerThread;
    private volatile AudioRecord recorder;
    private Thread captureThread;
    private AcousticEchoCanceler aec;
    private NoiseSuppressor ns;
    private AutomaticGainControl agc;
    private AudioDeviceCallback deviceCallback;

    private final FrameCodec.DecoderFactory decoderFactory = new FrameCodec.DecoderFactory() {
        @Override
        public FrameCodec.Decoder create(int codecId) {
            if (codecId == FrameCodec.ADPCM) {
                return new FrameCodec.AdpcmDecoder();
            }
            if (codecId == FrameCodec.OPUS) {
                return OpusCodec.Decoder.create();
            }
            return null;
        }
    };

    private final RemoteStream[] remotes = new RemoteStream[SLOTS];
    private final ConcurrentLinkedQueue<byte[]> outgoing = new ConcurrentLinkedQueue<byte[]>();

    private int savedMode = AudioManager.MODE_NORMAL;
    private boolean savedSpeaker;
    private volatile boolean speakerPreferred = true;

    private volatile float micLevel;
    private volatile float playLevel;
    private volatile boolean micActive;
    private volatile int captureCodec = FrameCodec.ADPCM;
    private volatile long packetsEncoded;
    private volatile long packetsDroppedOut;
    private volatile long deviceEvents;
    private volatile String lastError = "";

    public GloryVoicePlugin(Godot godot) {
        super(godot);
        for (int i = 0; i < SLOTS; i++) {
            remotes[i] = new RemoteStream(decoderFactory);
        }
    }

    @Override
    public String getPluginName() {
        return "GloryVoice";
    }

    // --- 给 Godot 调的 ------------------------------------------------------------

    @UsedByGodot
    public boolean hasRecordPermission() {
        Context ctx = getContext();
        return ctx != null
                && ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
    }

    /** 这台手机「有没有」系统回声消除等能力（有 ≠ 效果好，效果只能听），以及编码相关的事实。JSON。 */
    @UsedByGodot
    public String getCapabilities() {
        JSONObject o = new JSONObject();
        try {
            o.put("aec_available", AcousticEchoCanceler.isAvailable());
            o.put("ns_available", NoiseSuppressor.isAvailable());
            o.put("agc_available", AutomaticGainControl.isAvailable());
            o.put("sdk_int", Build.VERSION.SDK_INT);
            o.put("manufacturer", Build.MANUFACTURER);
            o.put("model", Build.MODEL);
            o.put("sample_rate", AdpcmCodec.SAMPLE_RATE);
            o.put("frames_per_packet", FRAMES_PER_PACKET);
            o.put("max_packet_bytes", VoicePacket.MAX_PACKET_BYTES);
            o.put("opus_encoder_api", OpusCodec.encoderSupported());
            o.put("opus_selftest", opusSelfTest == null ? "not_run" : opusSelfTest);
            o.put("has_record_permission", hasRecordPermission());
        } catch (Exception e) {
            Log.w(TAG, "getCapabilities", e);
        }
        return o.toString();
    }

    /** 进通话模式、开始放队友的声音。返回空串 = 成功，否则是原因代码（VoiceService 翻译成人话）。 */
    @UsedByGodot
    public String startSession(boolean speakerphone) {
        synchronized (lock) {
            if (sessionRunning) {
                return "";
            }
            lastError = "";
            AudioManager am = audioManager();
            if (am == null) {
                return fail("no_audio_manager");
            }
            AudioTrack track;
            try {
                int minPlay = AudioTrack.getMinBufferSize(AdpcmCodec.SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO,
                        AudioFormat.ENCODING_PCM_16BIT);
                AudioAttributes attrs = new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build();
                AudioFormat fmt = new AudioFormat.Builder()
                        .setSampleRate(AdpcmCodec.SAMPLE_RATE)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build();
                track = new AudioTrack(attrs, fmt, Math.max(minPlay, AdpcmCodec.FRAME_SAMPLES * 2 * 4),
                        AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE);
            } catch (Exception e) {
                Log.w(TAG, "AudioTrack", e);
                return fail("play_init_failed");
            }
            if (track.getState() != AudioTrack.STATE_INITIALIZED) {
                track.release();
                return fail("play_init_failed");
            }
            savedMode = am.getMode();
            savedSpeaker = am.isSpeakerphoneOn();
            am.setMode(AudioManager.MODE_IN_COMMUNICATION);
            speakerPreferred = speakerphone;
            routeAudio(am);
            registerDeviceCallback(am);
            for (RemoteStream r : remotes) {
                r.reset();
            }
            outgoing.clear();
            packetsEncoded = 0;
            packetsDroppedOut = 0;
            player = track;
            track.play();
            sessionRunning = true;
            Thread t = new Thread(new Runnable() {
                @Override
                public void run() {
                    mixLoop();
                }
            }, "GloryVoiceMixer");
            t.setPriority(Thread.MAX_PRIORITY);
            mixerThread = t;
            t.start();
            ensureOpusSelfTest();
            return "";
        }
    }

    /** 全部停下并把手机的音频模式还原。**离开房间必须调**，否则整个游戏一直在通话模式里。 */
    @UsedByGodot
    public void stopSession() {
        stopCapture();
        Thread t;
        synchronized (lock) {
            if (!sessionRunning) {
                return;
            }
            sessionRunning = false;
            t = mixerThread;
            mixerThread = null;
        }
        joinQuietly(t);
        synchronized (lock) {
            // 解码器只在混音线程里用；线程已经退出，这里释放才安全。
            for (RemoteStream r : remotes) {
                r.releaseDecoders();
            }
            AudioTrack p = player;
            player = null;
            if (p != null) {
                try {
                    p.stop();
                } catch (Exception ignored) {
                }
                p.release();
            }
            AudioManager am = audioManager();
            if (am != null) {
                unregisterDeviceCallback(am);
                restoreAudio(am);
            }
            outgoing.clear();
            playLevel = 0f;
        }
    }

    /** 开关麦克风。要先 startSession。返回空串 = 成功，否则是原因代码。 */
    @UsedByGodot
    public String setCapture(boolean enabled) {
        if (!enabled) {
            stopCapture();
            return "";
        }
        synchronized (lock) {
            if (!sessionRunning) {
                return fail("no_session");
            }
            if (capturing) {
                return "";
            }
            if (!hasRecordPermission()) {
                return fail("no_permission");
            }
            int minRec = AudioRecord.getMinBufferSize(AdpcmCodec.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT);
            if (minRec <= 0) {
                return fail("bad_record_params");
            }
            AudioRecord rec;
            try {
                rec = new AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, AdpcmCodec.SAMPLE_RATE,
                        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                        Math.max(minRec, AdpcmCodec.FRAME_SAMPLES * 2 * 10));
            } catch (Exception e) {
                Log.w(TAG, "AudioRecord", e);
                return fail("record_init_failed");
            }
            if (rec.getState() != AudioRecord.STATE_INITIALIZED) {
                rec.release();
                return fail("record_init_failed");
            }
            attachEffects(rec.getAudioSessionId());
            try {
                rec.startRecording();
            } catch (Exception e) {
                Log.w(TAG, "startRecording", e);
                releaseEffects();
                rec.release();
                return fail("record_start_failed");
            }
            if (rec.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                // 麦克风被别的应用占着（正在打电话、别的语音软件开着）。
                releaseEffects();
                rec.release();
                return fail("mic_busy");
            }
            recorder = rec;
            capturing = true;
            Thread t = new Thread(new Runnable() {
                @Override
                public void run() {
                    captureLoop();
                }
            }, "GloryVoiceCapture");
            t.setPriority(Thread.MAX_PRIORITY);
            captureThread = t;
            t.start();
            return "";
        }
    }

    /** 取走录好的包：[u16 长度 LE][包]... 首尾相接。没有就是空数组。 */
    @UsedByGodot
    public byte[] readPackets() {
        ByteArrayOutputStream out = new ByteArrayOutputStream(512);
        int n = 0;
        byte[] packet;
        while (n < MAX_PACKETS_PER_READ && (packet = outgoing.poll()) != null) {
            out.write(packet.length & 0xff);
            out.write((packet.length >> 8) & 0xff);
            out.write(packet, 0, packet.length);
            n++;
        }
        return out.toByteArray();
    }

    /** 队友 slot 的一个包（③ 转发来的）。只入队，解码在混音线程里做。 */
    @UsedByGodot
    public void pushPacket(int slot, byte[] packet) {
        if (!sessionRunning || slot < 0 || slot >= SLOTS || packet == null) {
            return;
        }
        remotes[slot].push(packet, SystemClock.elapsedRealtime());
    }

    /** 屏蔽 / 取消屏蔽某个座位的声音（本地生效，不影响别人听）。VoiceService 按玩家屏蔽时在交包之前就丢了，这里是兜底。 */
    @UsedByGodot
    public void setRemoteMuted(int slot, boolean muted) {
        if (slot >= 0 && slot < SLOTS) {
            remotes[slot].setMuted(muted);
        }
    }

    @UsedByGodot
    public void setSpeakerphone(boolean on) {
        speakerPreferred = on;
        AudioManager am = audioManager();
        if (am != null && sessionRunning) {
            routeAudio(am);
        }
    }

    /** 当前状态，JSON。界面每 0.25 秒拉一次。 */
    @UsedByGodot
    public String getStatus() {
        JSONObject o = new JSONObject();
        try {
            o.put("running", sessionRunning);
            o.put("capturing", capturing);
            o.put("mic_active", micActive);
            o.put("mic_level", micLevel);
            o.put("play_level", playLevel);
            o.put("codec", captureCodec == FrameCodec.OPUS ? "opus" : "adpcm");
            o.put("opus_selftest", opusSelfTest == null ? "not_run" : opusSelfTest);
            AudioManager am = audioManager();
            o.put("mode", am != null ? am.getMode() : -1);
            o.put("packets_encoded", packetsEncoded);
            o.put("packets_dropped_out", packetsDroppedOut);
            o.put("device_events", deviceEvents);
            o.put("aec_enabled", effectEnabled(aec));
            o.put("ns_enabled", effectEnabled(ns));
            o.put("agc_enabled", effectEnabled(agc));
            JSONArray speaking = new JSONArray();
            JSONArray remote = new JSONArray();
            for (int s = 0; s < SLOTS; s++) {
                RemoteStream r = remotes[s];
                if (r.level >= SPEAKING_LEVEL) {
                    speaking.put(s);
                }
                if (r.packets == 0 && r.packetsBad == 0) {
                    continue;
                }
                JSONObject ro = new JSONObject();
                ro.put("slot", s);
                ro.put("level", r.level);
                ro.put("codec", r.lastCodec() == FrameCodec.OPUS ? "opus" : (r.lastCodec() == FrameCodec.ADPCM ? "adpcm" : ""));
                ro.put("queued", r.queued());
                ro.put("packets", r.packets);
                ro.put("lost", r.framesLost);
                ro.put("late", r.packetsLate);
                ro.put("bad", r.packetsBad);
                ro.put("bad_frames", r.framesBad);
                ro.put("dropped_packets", r.packetsDropped);
                ro.put("underruns", r.underruns);
                ro.put("dropped", r.framesDropped);
                ro.put("muted", r.isMuted());
                remote.put(ro);
            }
            o.put("speaking_slots", speaking);
            o.put("remote", remote);
            AudioTrack p = player;
            if (p != null) {
                o.put("track_underruns", p.getUnderrunCount());
                o.put("output_device", deviceName(p.getRoutedDevice()));
            }
            AudioRecord rec = recorder;
            if (rec != null) {
                o.put("input_device", deviceName(rec.getRoutedDevice()));
            }
            o.put("last_error", lastError);
        } catch (Exception e) {
            Log.w(TAG, "getStatus", e);
        }
        return o.toString();
    }

    // --- 生命周期 ------------------------------------------------------------------

    @Override
    public void onMainPause() {
        stopSession();
    }

    @Override
    public void onMainDestroy() {
        stopSession();
    }

    // --- 线程 ----------------------------------------------------------------------

    private void mixLoop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO);
        int[] acc = new int[AdpcmCodec.FRAME_SAMPLES];
        short[] out = new short[AdpcmCodec.FRAME_SAMPLES];
        while (sessionRunning) {
            Arrays.fill(acc, 0);
            boolean any = false;
            long now = SystemClock.elapsedRealtime();
            for (int s = 0; s < SLOTS; s++) {
                short[] frame;
                try {
                    frame = remotes[s].pull(now);
                } catch (RuntimeException e) {
                    // 一个队友的解码出错不能拖死整个混音线程（其他人还要听得见）。
                    Log.w(TAG, "remote " + s + " decode failed", e);
                    lastError = "decode_failed";
                    continue;
                }
                if (frame == null) {
                    continue;
                }
                any = true;
                for (int i = 0; i < frame.length; i++) {
                    acc[i] += frame[i];
                }
            }
            for (int i = 0; i < out.length; i++) {
                int v = acc[i];
                out[i] = (short) (v > 32767 ? 32767 : (v < -32768 ? -32768 : v));
            }
            playLevel = any ? RemoteStream.rms(out) : 0f;
            AudioTrack track = player;
            if (track == null) {
                break;
            }
            // 阻塞写：没人说话时写的是静音，这一句按真实时间把循环卡在每 20 毫秒一次。
            int written = track.write(out, 0, out.length);
            if (written < 0) {
                lastError = "track_write_" + written;
                SystemClock.sleep(20);
            }
        }
        playLevel = 0f;
    }

    private void captureLoop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO);
        Packetizer packetizer = new Packetizer(FRAMES_PER_PACKET, new FrameCodec.AdpcmEncoder(), new Packetizer.Sink() {
            @Override
            public void onPacket(byte[] packet) {
                enqueueOutgoing(packet);
            }
        });
        captureCodec = FrameCodec.ADPCM;
        short[] frame = new short[AdpcmCodec.FRAME_SAMPLES];
        short[][] preroll = new short[VAD_PREROLL_FRAMES][];
        int prerollNext = 0;
        int prerollCount = 0;
        float noiseFloor = 0.01f;
        int hangover = 0;
        boolean active = false;
        try {
            while (capturing) {
                AudioRecord rec = recorder;
                if (rec == null) {
                    break;
                }
                if (readFully(rec, frame) < frame.length) {
                    if (!capturing) {
                        break;
                    }
                    continue;
                }
                float level = RemoteStream.rms(frame);
                micLevel = level;
                // 噪声底往下跟得快、往上跟得慢：说话时它几乎不动，安静下来很快回落。
                if (level < noiseFloor) {
                    noiseFloor += (level - noiseFloor) * 0.1f;
                } else {
                    noiseFloor += (level - noiseFloor) * 0.005f;
                }
                float threshold = Math.max(VAD_MIN_THRESHOLD, Math.min(VAD_MAX_THRESHOLD, noiseFloor * 3f));
                if (level > threshold) {
                    hangover = VAD_HANGOVER_FRAMES;
                } else if (hangover > 0) {
                    hangover--;
                }
                boolean nowActive = hangover > 0;
                if (nowActive && !active) {
                    maybeSwitchToOpus(packetizer);
                    packetizer.startSpurt();
                    for (int i = 0; i < prerollCount; i++) {
                        int idx = (prerollNext - prerollCount + i + VAD_PREROLL_FRAMES) % VAD_PREROLL_FRAMES;
                        addFrame(packetizer, preroll[idx]);
                    }
                    prerollCount = 0;
                }
                if (nowActive) {
                    addFrame(packetizer, frame);
                } else {
                    if (active) {
                        packetizer.flush();
                    }
                    preroll[prerollNext] = frame.clone();
                    prerollNext = (prerollNext + 1) % VAD_PREROLL_FRAMES;
                    if (prerollCount < VAD_PREROLL_FRAMES) {
                        prerollCount++;
                    }
                }
                active = nowActive;
                micActive = nowActive;
            }
        } finally {
            try {
                packetizer.release();
            } catch (RuntimeException e) {
                Log.w(TAG, "packetizer release", e);
            }
            micActive = false;
        }
    }

    /** 一段话开始前：Opus 自检已经通过、手上还是 ADPCM，就换成 Opus。 */
    private void maybeSwitchToOpus(Packetizer packetizer) {
        if (packetizer.codecId() == FrameCodec.OPUS || !"ok".equals(opusSelfTest)) {
            return;
        }
        OpusCodec.Encoder opus = OpusCodec.Encoder.create();
        if (opus == null) {
            opusSelfTest = "encoder_create_failed";
            return;
        }
        packetizer.swapEncoder(opus).release();
        captureCodec = FrameCodec.OPUS;
    }

    /** 编码出错（只会是 Opus）：换回 ADPCM，这个进程里不再试 Opus，这一帧用 ADPCM 重编。 */
    private void addFrame(Packetizer packetizer, short[] frame) {
        try {
            packetizer.add(frame);
        } catch (RuntimeException e) {
            if (packetizer.codecId() != FrameCodec.OPUS) {
                throw e;
            }
            Log.w(TAG, "opus encode failed, falling back to ADPCM", e);
            opusSelfTest = "encode_failed";
            try {
                packetizer.swapEncoder(new FrameCodec.AdpcmEncoder()).release();
            } catch (RuntimeException ignored) {
            }
            captureCodec = FrameCodec.ADPCM;
            packetizer.add(frame);
        }
    }

    private void enqueueOutgoing(byte[] packet) {
        outgoing.add(packet);
        packetsEncoded++;
        while (outgoing.size() > MAX_QUEUED_PACKETS) {
            if (outgoing.poll() != null) {
                packetsDroppedOut++;
            }
        }
    }

    private void stopCapture() {
        Thread t;
        AudioRecord rec;
        synchronized (lock) {
            if (!capturing) {
                return;
            }
            capturing = false;
            t = captureThread;
            captureThread = null;
            rec = recorder;
        }
        if (rec != null) {
            try {
                rec.stop(); // 让采集线程里阻塞的 read() 返回
            } catch (Exception ignored) {
            }
        }
        joinQuietly(t);
        synchronized (lock) {
            releaseEffects();
            if (recorder != null) {
                recorder.release();
                recorder = null;
            }
            micLevel = 0f;
            micActive = false;
        }
    }

    // --- 内部 ----------------------------------------------------------------------

    /** Opus 自检放在后台线程：建两个 MediaCodec、编解 25 帧要一两百毫秒，不能卡在 Godot 线程上。 */
    private void ensureOpusSelfTest() {
        synchronized (SELF_TEST_LOCK) {
            if (opusSelfTest != null) {
                return;
            }
            if (!OpusCodec.encoderSupported()) {
                opusSelfTest = "android_below_10";
                return;
            }
            opusSelfTest = "running";
        }
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                String result = OpusCodec.selfTest();
                opusSelfTest = result.isEmpty() ? "ok" : result;
                Log.i(TAG, "opus self-test: " + opusSelfTest);
            }
        }, "GloryVoiceOpusSelfTest");
        t.start();
    }

    /** 插拔耳机、连上 / 断开蓝牙时重新选输出设备。安卓 6 起才有这个回调。 */
    private void registerDeviceCallback(AudioManager am) {
        if (Build.VERSION.SDK_INT < 23 || deviceCallback != null) {
            return;
        }
        deviceCallback = new AudioDeviceCallback() {
            @Override
            public void onAudioDevicesAdded(AudioDeviceInfo[] added) {
                onDevicesChanged();
            }

            @Override
            public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) {
                onDevicesChanged();
            }
        };
        try {
            am.registerAudioDeviceCallback(deviceCallback, new Handler(Looper.getMainLooper()));
        } catch (Exception e) {
            Log.w(TAG, "registerAudioDeviceCallback", e);
            deviceCallback = null;
        }
    }

    private void unregisterDeviceCallback(AudioManager am) {
        if (deviceCallback == null) {
            return;
        }
        try {
            am.unregisterAudioDeviceCallback(deviceCallback);
        } catch (Exception ignored) {
        }
        deviceCallback = null;
    }

    private void onDevicesChanged() {
        if (!sessionRunning) {
            return;
        }
        AudioManager am = audioManager();
        if (am != null) {
            routeAudio(am);
            deviceEvents++;
        }
    }

    private void attachEffects(int session) {
        // 系统效果挂在录音的 session 上。isAvailable() 为 false 的手机就是没有 ——
        // 这正是测试要记下来的事实，不是错误。个别机型 create() 会直接抛，吞掉当作没有。
        try {
            if (AcousticEchoCanceler.isAvailable()) {
                aec = AcousticEchoCanceler.create(session);
                if (aec != null) {
                    aec.setEnabled(true);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "aec", e);
            aec = null;
        }
        try {
            if (NoiseSuppressor.isAvailable()) {
                ns = NoiseSuppressor.create(session);
                if (ns != null) {
                    ns.setEnabled(true);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "ns", e);
            ns = null;
        }
        try {
            if (AutomaticGainControl.isAvailable()) {
                agc = AutomaticGainControl.create(session);
                if (agc != null) {
                    agc.setEnabled(true);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "agc", e);
            agc = null;
        }
    }

    private void releaseEffects() {
        if (aec != null) {
            aec.release();
            aec = null;
        }
        if (ns != null) {
            ns.release();
            ns = null;
        }
        if (agc != null) {
            agc.release();
            agc = null;
        }
    }

    /** 出声设备：蓝牙耳机 > 有线 / USB 耳机 > 扬声器（外放）> 听筒。横屏打游戏，听筒出声只会让人以为没声音。 */
    private void routeAudio(AudioManager am) {
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                AudioDeviceInfo pick = null;
                int best = 0;
                for (AudioDeviceInfo d : am.getAvailableCommunicationDevices()) {
                    int rank = deviceRank(d.getType());
                    if (rank > best) {
                        best = rank;
                        pick = d;
                    }
                }
                if (pick != null) {
                    am.setCommunicationDevice(pick);
                }
            } else {
                boolean headset = am.isWiredHeadsetOn() || am.isBluetoothScoOn();
                am.setSpeakerphoneOn(speakerPreferred && !headset);
            }
        } catch (Exception e) {
            Log.w(TAG, "routeAudio", e);
            lastError = "route: " + e.getMessage();
        }
    }

    private int deviceRank(int type) {
        switch (type) {
            case AudioDeviceInfo.TYPE_BLE_HEADSET:
            case AudioDeviceInfo.TYPE_BLUETOOTH_SCO:
                return 5;
            case AudioDeviceInfo.TYPE_WIRED_HEADSET:
            case AudioDeviceInfo.TYPE_USB_HEADSET:
                return 4;
            case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:
                return speakerPreferred ? 3 : 1;
            case AudioDeviceInfo.TYPE_BUILTIN_EARPIECE:
                return speakerPreferred ? 1 : 3;
            default:
                return 0;
        }
    }

    private void restoreAudio(AudioManager am) {
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                am.clearCommunicationDevice();
            } else {
                am.setSpeakerphoneOn(savedSpeaker);
            }
            am.setMode(savedMode);
        } catch (Exception e) {
            Log.w(TAG, "restoreAudio", e);
        }
    }

    private AudioManager audioManager() {
        Context ctx = getContext();
        return ctx == null ? null : (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
    }

    private String fail(String code) {
        lastError = code;
        return code;
    }

    private static boolean effectEnabled(AudioEffect effect) {
        if (effect == null) {
            return false;
        }
        try {
            return effect.getEnabled();
        } catch (Exception e) {
            return false;
        }
    }

    private static int readFully(AudioRecord rec, short[] buf) {
        int off = 0;
        while (off < buf.length) {
            int r = rec.read(buf, off, buf.length - off);
            if (r <= 0) {
                return off; // 出错或已经停了
            }
            off += r;
        }
        return off;
    }

    private static void joinQuietly(Thread t) {
        if (t == null) {
            return;
        }
        try {
            t.join(500);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static String deviceName(AudioDeviceInfo d) {
        if (d == null) {
            return "";
        }
        switch (d.getType()) {
            case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:
                return "扬声器";
            case AudioDeviceInfo.TYPE_BUILTIN_EARPIECE:
                return "听筒";
            case AudioDeviceInfo.TYPE_BUILTIN_MIC:
                return "机身麦克风";
            case AudioDeviceInfo.TYPE_WIRED_HEADSET:
            case AudioDeviceInfo.TYPE_WIRED_HEADPHONES:
                return "有线耳机";
            case AudioDeviceInfo.TYPE_BLUETOOTH_SCO:
                return "蓝牙（通话）";
            case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP:
                return "蓝牙（媒体）";
            case AudioDeviceInfo.TYPE_BLE_HEADSET:
                return "蓝牙 LE";
            case AudioDeviceInfo.TYPE_USB_HEADSET:
                return "USB 耳机";
            default:
                return "类型 " + d.getType();
        }
    }
}
