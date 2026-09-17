extends Node

# 电脑版语音后端（docs/聊天系统设计.md 第九节「电脑版语音」，2026-09-17 试用版）。
#
# 方法与 VoiceService 调的安卓插件方法同名同参（startSession / stopSession / setCapture /
# readPackets / pushPacket / getStatus / getCapabilities / hasRecordPermission），
# VoiceService 分不出是哪一个 —— 界面、状态机、战斗服务器转发都不用改。
# tools/voice_check 钉着这张方法表。
#
# 🔴 这一版是**试用**：先听外放回声严不严重，再决定要不要做回声消除。边界：
#   - 只有 ADPCM。手机能解；**安卓 10 起的手机发的是 Opus，这里解不了** —— 不放，
#     记在状态里（remotes[].opus_dropped），队友面板上会提示
#   - 没有回声消除、降噪、自动音量。外放开麦时队友会听到自己的回声
#   - 录音用 Godot 自带的麦克风输入：project.godot 里 audio/driver/enable_input 只对 Windows 打开
#     （.windows 覆盖）。手机不走这条：Godot 自带的安卓录音没有回声消除
#
# 说话检测、打包、抖动缓冲的参数与安卓插件一致（GloryVoicePlugin.java / RemoteStream.java），
# 数值由 voice_check 对账。流程也照抄：检测到说话 → 编码器归零 → 先发 40 毫秒预录 →
# 每 2 帧打一个包；说完 400 毫秒才算停。

const Adpcm := preload("res://scripts/voice/VoiceAdpcm.gd")
const Packet := preload("res://scripts/voice/VoicePacketCodec.gd")

const SLOTS := 6
# --- 与 GloryVoicePlugin.java 一致 ---
const FRAMES_PER_PACKET := 2
const MAX_QUEUED_PACKETS := 50
const MAX_PACKETS_PER_READ := 12
const VAD_MIN_THRESHOLD := 0.006
const VAD_MAX_THRESHOLD := 0.06
const VAD_HANGOVER_FRAMES := 20
const VAD_PREROLL_FRAMES := 2
const SPEAKING_LEVEL := 0.02

# --- 电脑独有 ---
const MIC_BUS := "GloryVoiceMic"
const INPUT_SETTING := "audio/driver/enable_input"
# 麦克风缓冲。游戏卡一下（切场景、读资源）时 _process 会隔很久才来取，
# 缓冲太小就会整段丢声；0.5 秒够扛一次普通的卡顿。
const CAPTURE_BUFFER_SEC := 0.5
# 播放器里最多预先塞这么多帧（40 毫秒）。塞多了延迟变大，塞少了容易断。
const PLAYBACK_LOOKAHEAD_FRAMES := 2
const PLAYBACK_BUFFER_SEC := 0.25
# Windows「隐私 → 麦克风 → 允许桌面应用访问」关着时，录到的是全零、不报错。连续这么久全零就提示。
const MIC_SILENT_SEC := 2.0


# 一个队友传过来的语音：序号校验 + 解码 + 抖动缓冲。逻辑照抄 RemoteStream.java，
# 只是解码直接在主线程做（ADPCM 很便宜，GDScript 每秒 16000 个采样没压力）。
class Remote extends RefCounted:
	# --- 与 RemoteStream.java 一致 ---
	const START_FRAMES := 3
	const MAX_QUEUED_FRAMES := 20
	const IDLE_RESET_MS := 1500
	const SHORT_SPURT_WAIT_MS := 60

	var ring: Array[PackedInt32Array] = []
	var buffering := true
	# 播放时放空了。只有同一段话的下一个包真的来了，才算一次欠载。
	var drained := false
	var expected_seq := -1
	var last_push_ms := -100000
	var level := 0.0
	var packets := 0
	var frames_lost := 0
	var packets_late := 0
	var packets_bad := 0
	var frames_dropped := 0
	var underruns := 0
	# 电脑版解不了的 Opus 包。大于 0 说明这个队友用的是安卓 10 起的手机。
	var opus_dropped := 0
	var last_codec := -1
	var player: AudioStreamPlayer = null
	var playback: AudioStreamGeneratorPlayback = null
	var capacity := 0

	func push(packet: PackedByteArray, now_ms: int) -> void:
		var parsed := Packet.parse(packet)
		if parsed.is_empty():
			packets_bad += 1
			return
		var seq: int = parsed.seq
		var fresh: bool = expected_seq < 0 or bool(parsed.spurt_start) or now_ms - last_push_ms > IDLE_RESET_MS
		if not fresh:
			var diff := (seq - expected_seq) & 0xffff
			if diff >= 0x8000:
				# 比已经收到的还旧：迟到或重复。后面的已经在放了，再放只会是一声杂音。
				packets_late += 1
				return
			frames_lost += diff
			if drained:
				underruns += 1
		drained = false
		last_push_ms = now_ms
		var frames: Array[PackedByteArray] = parsed.frames
		expected_seq = (seq + frames.size()) & 0xffff
		packets += 1
		last_codec = int(parsed.codec)
		if last_codec != Packet.CODEC_ADPCM:
			opus_dropped += 1
			return
		for frame in frames:
			ring.append(Adpcm.decode_block(frame, 0))
		# 最多压 400 毫秒。再多就是越积越延迟：宁可丢最老的，也不要一直慢半拍。
		while ring.size() > MAX_QUEUED_FRAMES:
			ring.pop_front()
			frames_dropped += 1

	# 交出下一帧要放的声音；还在攒缓冲或者放空了就是空数组。
	func pull(now_ms: int) -> PackedInt32Array:
		if buffering:
			if ring.size() >= START_FRAMES or (not ring.is_empty() and now_ms - last_push_ms >= SHORT_SPURT_WAIT_MS):
				buffering = false
			else:
				level = 0.0
				return PackedInt32Array()
		if ring.is_empty():
			buffering = true
			drained = true
			level = 0.0
			return PackedInt32Array()
		var frame: PackedInt32Array = ring.pop_front()
		level = Adpcm.rms(frame)
		return frame


var _running := false
var _capturing := false
var _remotes: Dictionary = {}          # slot -> Remote（第一次收到包时才建播放器）
var _outgoing: Array[PackedByteArray] = []

# 采集
var _mic_player: AudioStreamPlayer = null
var _capture: AudioEffectCapture = null
var _resample_ratio := 3.0
var _rs_pos := 0.0
var _rs_sum := 0.0
var _rs_count := 0
var _frame := PackedInt32Array()
var _frame_len := 0
var _silent_sec := 0.0

# 说话检测与打包（照抄 GloryVoicePlugin.captureLoop / Packetizer）
var _encoder := Adpcm.new_state()
var _noise_floor := 0.01
var _hangover := 0
var _active := false
var _preroll: Array[PackedInt32Array] = []
var _pending: Array[PackedByteArray] = []
var _seq := 0
var _spurt_start := false
var _mic_level := 0.0

# 统计
var _packets_encoded := 0
var _packets_dropped_out := 0


func _init() -> void:
	_frame.resize(Adpcm.FRAME_SAMPLES)


# --- 与安卓插件同名的方法 ----------------------------------------------------------

func hasRecordPermission() -> bool:
	# Windows 没有「应用内请求麦克风权限」这回事；被系统隐私设置挡住时录到的是全零，
	# 由 mic_silent 提示（见 MIC_SILENT_SEC）。
	return true


func getCapabilities() -> String:
	return JSON.stringify({
		"platform": "desktop",
		"aec_available": false,
		"ns_available": false,
		"agc_available": false,
		"sample_rate": Adpcm.SAMPLE_RATE,
		"frames_per_packet": FRAMES_PER_PACKET,
		"max_packet_bytes": Packet.MAX_PACKET_BYTES,
		"opus_encoder_api": false,
		"opus_selftest": "desktop_unsupported",
		"has_record_permission": true,
		"input_enabled": input_enabled(),
	})


func startSession(_speakerphone: bool) -> String:
	# 电脑上没有「听筒 / 外放」之分，参数只为与插件同形。
	_running = true
	return ""


func stopSession() -> void:
	setCapture(false)
	for slot in _remotes.keys():
		_free_remote(_remotes[slot])
	_remotes.clear()
	_outgoing.clear()
	_running = false


func setCapture(enabled: bool) -> String:
	if enabled and not _running:
		return "no_session"
	if enabled == _capturing:
		return ""
	if not enabled:
		_flush()
		if _mic_player != null:
			_mic_player.stop()
			_mic_player.queue_free()
			_mic_player = null
		_capturing = false
		_active = false
		_mic_level = 0.0
		return ""
	if not input_enabled():
		return "input_disabled"
	_ensure_mic_bus()
	if _capture == null:
		return "record_init_failed"
	_reset_capture_state()
	_capture.clear_buffer()
	_mic_player = AudioStreamPlayer.new()
	_mic_player.name = "GloryVoiceMicPlayer"
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = MIC_BUS
	add_child(_mic_player)
	_mic_player.play()
	_capturing = true
	return ""


func readPackets() -> PackedByteArray:
	# 同插件：一次最多交 12 个，每个前面是 u16 LE 长度（VoiceService.split_packets 拆）。
	var blob := PackedByteArray()
	var taken := 0
	while not _outgoing.is_empty() and taken < MAX_PACKETS_PER_READ:
		var packet: PackedByteArray = _outgoing.pop_front()
		var head := PackedByteArray()
		head.resize(2)
		head.encode_u16(0, packet.size())
		blob.append_array(head)
		blob.append_array(packet)
		taken += 1
	return blob


func pushPacket(slot: int, packet: PackedByteArray) -> void:
	if not _running or slot < 0 or slot >= SLOTS:
		return
	_remote(slot).push(packet, Time.get_ticks_msec())


func getStatus() -> String:
	var speaking: Array[int] = []
	var remotes: Array[Dictionary] = []
	var opus_seen := false
	for slot in _remotes.keys():
		var r: Remote = _remotes[slot]
		if r.level >= SPEAKING_LEVEL:
			speaking.append(int(slot))
		if r.opus_dropped > 0:
			opus_seen = true
		remotes.append({
			"slot": int(slot),
			"level": r.level,
			"codec": "opus" if r.last_codec == Packet.CODEC_OPUS else ("adpcm" if r.last_codec == Packet.CODEC_ADPCM else ""),
			"queued": r.ring.size(),
			"packets": r.packets,
			"lost": r.frames_lost,
			"late": r.packets_late,
			"bad": r.packets_bad,
			"dropped": r.frames_dropped,
			"underruns": r.underruns,
			"opus_dropped": r.opus_dropped,
		})
	speaking.sort()
	return JSON.stringify({
		"platform": "desktop",
		"running": _running,
		"capturing": _capturing,
		"mic_active": _active,
		"mic_level": _mic_level,
		"mic_silent": _capturing and _silent_sec >= MIC_SILENT_SEC,
		"codec": "adpcm",
		"opus_selftest": "desktop_unsupported",
		"opus_from_teammates": opus_seen,
		"output_device": AudioServer.output_device,
		"input_device": AudioServer.input_device,
		"packets_encoded": _packets_encoded,
		"packets_dropped_out": _packets_dropped_out,
		"remotes": remotes,
		"speaking_slots": speaking,
	})


# --- 其余 ----------------------------------------------------------------------

# 录音输入有没有打开。读**带平台覆盖**的值：项目里写的是 driver/enable_input.windows。
static func input_enabled() -> bool:
	return bool(ProjectSettings.get_setting_with_override(INPUT_SETTING))


func _process(delta: float) -> void:
	if not _running:
		return
	if _capturing:
		_drain_capture(delta)
	_feed_players()


func _ensure_mic_bus() -> void:
	var idx := AudioServer.get_bus_index(MIC_BUS)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, MIC_BUS)
		# 静音：自己的声音不从自己的喇叭放出来（那会直接啸叫）。
		# 静音只挡往外送，总线上的效果器照常拿得到数据。
		AudioServer.set_bus_mute(idx, true)
		var effect := AudioEffectCapture.new()
		effect.buffer_length = CAPTURE_BUFFER_SEC
		AudioServer.add_bus_effect(idx, effect)
	_capture = AudioServer.get_bus_effect(idx, 0) as AudioEffectCapture


func _reset_capture_state() -> void:
	_resample_ratio = maxf(1.0, AudioServer.get_mix_rate() / float(Adpcm.SAMPLE_RATE))
	_rs_pos = 0.0
	_rs_sum = 0.0
	_rs_count = 0
	_frame_len = 0
	_silent_sec = 0.0
	Adpcm.clear_state(_encoder)
	_noise_floor = 0.01
	_hangover = 0
	_active = false
	_preroll.clear()
	_pending.clear()
	_spurt_start = false


# 混音采样率（通常 48000）→ 16000 单声道。每个输出采样取对应那一段输入的平均，
# 顺带当了一个粗糙的低通，免得高频折叠成杂音。
func _drain_capture(delta: float) -> void:
	var available := _capture.get_frames_available()
	if available <= 0:
		# 连数据都没有（驱动没起来）也算「没声音」。
		_silent_sec += delta
		return
	var buffer := _capture.get_buffer(available)
	for v in buffer:
		_rs_sum += (v.x + v.y) * 0.5
		_rs_count += 1
		_rs_pos += 1.0
		if _rs_pos < _resample_ratio:
			continue
		_rs_pos -= _resample_ratio
		var sample := _rs_sum / _rs_count
		_rs_sum = 0.0
		_rs_count = 0
		_frame[_frame_len] = clampi(roundi(sample * 32767.0), -32768, 32767)
		_frame_len += 1
		if _frame_len == Adpcm.FRAME_SAMPLES:
			_frame_len = 0
			_on_capture_frame(_frame.duplicate())


# 一帧（20 毫秒、320 个采样）。照抄 GloryVoicePlugin.captureLoop 的循环体。
func _on_capture_frame(frame: PackedInt32Array) -> void:
	var level := Adpcm.rms(frame)
	_mic_level = level
	if level == 0.0:
		_silent_sec += float(Adpcm.FRAME_SAMPLES) / Adpcm.SAMPLE_RATE
	else:
		_silent_sec = 0.0
	# 噪声底往下跟得快、往上跟得慢：说话时它几乎不动，安静下来很快回落。
	if level < _noise_floor:
		_noise_floor += (level - _noise_floor) * 0.1
	else:
		_noise_floor += (level - _noise_floor) * 0.005
	var threshold := clampf(_noise_floor * 3.0, VAD_MIN_THRESHOLD, VAD_MAX_THRESHOLD)
	if level > threshold:
		_hangover = VAD_HANGOVER_FRAMES
	elif _hangover > 0:
		_hangover -= 1
	var now_active := _hangover > 0
	if now_active and not _active:
		_start_spurt()
		for held in _preroll:
			_add_frame(held)
		_preroll.clear()
	if now_active:
		_add_frame(frame)
	else:
		if _active:
			_flush()
		_preroll.append(frame)
		if _preroll.size() > VAD_PREROLL_FRAMES:
			_preroll.pop_front()
	_active = now_active


func _start_spurt() -> void:
	_flush()
	Adpcm.clear_state(_encoder)
	_spurt_start = true


func _add_frame(frame: PackedInt32Array) -> void:
	var encoded := Adpcm.encode_block(frame, 0, _encoder)
	if not _pending.is_empty() and Packet.size_of(_pending) + 1 + encoded.size() > Packet.MAX_PACKET_BYTES:
		_flush()
	_pending.append(encoded)
	if _pending.size() >= FRAMES_PER_PACKET:
		_flush()


func _flush() -> void:
	if _pending.is_empty():
		return
	var packet := Packet.build(_seq, _spurt_start, Packet.CODEC_ADPCM, _pending)
	_seq = (_seq + _pending.size()) & 0xffff
	_pending = []
	_spurt_start = false
	_packets_encoded += 1
	_outgoing.append(packet)
	# 攒着没人取（没连上服务器）就丢最老的，同插件。
	while _outgoing.size() > MAX_QUEUED_PACKETS:
		_outgoing.pop_front()
		_packets_dropped_out += 1


func _remote(slot: int) -> Remote:
	if _remotes.has(slot):
		return _remotes[slot]
	var r := Remote.new()
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = Adpcm.SAMPLE_RATE
	generator.buffer_length = PLAYBACK_BUFFER_SEC
	r.player = AudioStreamPlayer.new()
	r.player.name = "GloryVoiceSlot%d" % slot
	r.player.stream = generator
	add_child(r.player)
	r.player.play()
	r.playback = r.player.get_stream_playback() as AudioStreamGeneratorPlayback
	if r.playback != null:
		# 刚开始播放器是空的，这时能塞的量就是它的容量。
		r.capacity = r.playback.get_frames_available()
	_remotes[slot] = r
	return r


func _free_remote(r: Remote) -> void:
	if r.player != null and is_instance_valid(r.player):
		r.player.stop()
		r.player.queue_free()
	r.player = null
	r.playback = null


func _feed_players() -> void:
	var now := Time.get_ticks_msec()
	for slot in _remotes.keys():
		var r: Remote = _remotes[slot]
		if r.playback == null:
			continue
		while r.playback.get_frames_available() >= Adpcm.FRAME_SAMPLES \
				and r.capacity - r.playback.get_frames_available() < PLAYBACK_LOOKAHEAD_FRAMES * Adpcm.FRAME_SAMPLES:
			var frame := r.pull(now)
			if frame.is_empty():
				break
			var stereo := PackedVector2Array()
			stereo.resize(frame.size())
			for i in frame.size():
				var s := frame[i] / 32768.0
				stereo[i] = Vector2(s, s)
			r.playback.push_buffer(stereo)
