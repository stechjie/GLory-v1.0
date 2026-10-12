extends Node

# 聊天里的短语音（docs/聊天系统设计.md「语音消息」，2026-10-11）。
#
# 和 VoiceService（LiveKit 的实时通话）是两回事：那个是对讲，说完就没了；
# 这个是录一段、存下来、对方什么时候看到都能听。三个渠道（好友私聊、世界频道、
# 房间与对局内）**共用这一个服务**，区别只在录完之后那条消息走哪条路。
#
#   录音 ──> 上传账号服务器（WAV）──> 服务器转 Ogg Vorbis ──> 回一个 clip_id + 文件名
#   收到消息 ──> 按文件名去 /media 下载 ──> AudioStreamOggVorbis 播放
#
# ## 为什么录音用 Godot 自带的麦克风
#
# 2026-10-11 在 4.7.1 上验过：LiveKit 的桥接已经加载时，Godot 自己的
# AudioEffectCapture 照样录得到。于是这条路**不碰安卓 AAR / Windows dll / iOS 三个原生库**
# —— 09-29 刚因为「改了桥接没重编」坏过一次。
#
# ## 为什么传没压缩的 WAV
#
# Godot 能**放** Ogg Vorbis（AudioStreamOggVorbis.load_from_buffer），但**压不了**。
# 30 秒的 WAV 约 960 KB，只有说话的人上传这一次；收的人下的是转好的 Ogg（约 90 KB）。
#
# 🔴 **麦克风只在录音时打开。** 录完立刻停掉播放器 —— 常开会让手机一直亮「麦克风使用中」，
# 那是玩家会截图来问的东西。

signal recording_changed(active: bool)
# 录音中每帧一次，给界面画计时与音量条。
signal recording_tick(seconds: float, level: float)
signal playback_changed(clip_id: String, playing: bool)

const AccountConfig := preload("res://scripts/account/AccountConfig.gd")

# 🔴 下面三个与 backend/app/voice_clips.py 的同名常量一致（tools/voice_clip_check 钉着）。
# 对不上的症状：客户端让你录 40 秒，服务器收下时直接拒 —— 玩家白录一遍，而且没人知道为什么。
const MAX_SECONDS := 30.0
const MIN_SECONDS := 0.6
const SAMPLE_RATE := 16000

const SCOPE_PRIVATE := "private"
const SCOPE_WORLD := "world"
const SCOPE_MATCH := "match"

const MIC_BUS := "VoiceClipMic"
# 录音缓冲。切场景、读资源会让 _process 隔很久才来取一次，缓冲太小就整段丢声。
const CAPTURE_BUFFER_SEC := 1.0
# 下载过的音频留在内存里，避免同一条反复点反复下。超过就丢最早的。
const CACHE_LIMIT := 24

var _recording := false
var _samples := PackedFloat32Array()
var _mic_player: AudioStreamPlayer = null
var _capture: AudioEffectCapture = null
var _resample_ratio := 3.0
var _rs_pos := 0.0
var _rs_sum := 0.0
var _rs_count := 0
var _peak := 0.0

var _play_player: AudioStreamPlayer = null
var _playing_clip := ""
var _cache: Dictionary = {}          # media 文件名 -> PackedByteArray
var _cache_order: Array[String] = []


func _ready() -> void:
	set_process(false)


# --- 录音 ---------------------------------------------------------------------

func is_recording() -> bool:
	return _recording


func recorded_seconds() -> float:
	return float(_samples.size()) / SAMPLE_RATE


# 开始录。返回空串 = 开了；否则是给玩家看的原因。
func start_recording() -> String:
	if _recording:
		return ""
	if not input_enabled():
		# 打包时漏了项目设置里的录音开关。是打包问题，不是玩家的错。
		return _text("这个版本不能录音", "Recording is not available in this build")
	# 🔴 通话中不让录：两边都要麦克风。比起偷偷把通话静音，这个行为更好解释。
	if VoiceService.mode != VoiceService.Mode.OFF:
		return _text("通话中不能录语音", "Can't record while voice chat is on")
	_ensure_bus()
	if _capture == null:
		return _text("麦克风打不开", "Microphone unavailable")
	_samples = PackedFloat32Array()
	_resample_ratio = maxf(1.0, AudioServer.get_mix_rate() / float(SAMPLE_RATE))
	_rs_pos = 0.0
	_rs_sum = 0.0
	_rs_count = 0
	_peak = 0.0
	_capture.clear_buffer()
	_mic_player = AudioStreamPlayer.new()
	_mic_player.name = "VoiceClipMicPlayer"
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = MIC_BUS
	add_child(_mic_player)
	_mic_player.play()
	_recording = true
	set_process(true)
	recording_changed.emit(true)
	return ""


# 丢掉这次录音（玩家取消、或者切走了界面）。
func cancel_recording() -> void:
	if not _recording:
		return
	_stop_capture()
	_samples = PackedFloat32Array()


# 停下来并上传。返回 {"ok": bool, "clip_id": String, "media": String, "seconds": float, "error": String}。
func finish_and_upload(scope: String) -> Dictionary:
	if not _recording:
		return {"ok": false, "error": _text("没有在录音", "Not recording")}
	_stop_capture()
	var seconds := recorded_seconds()
	if seconds < MIN_SECONDS:
		_samples = PackedFloat32Array()
		return {"ok": false, "error": _text("说得太短了，按住多说一会儿", "Too short — hold and speak a bit longer")}
	var wav := build_wav(_samples, SAMPLE_RATE)
	_samples = PackedFloat32Array()
	return await _upload(scope, wav)


func _stop_capture() -> void:
	_recording = false
	set_process(false)
	if _mic_player != null and is_instance_valid(_mic_player):
		_mic_player.stop()
		_mic_player.queue_free()
	_mic_player = null
	recording_changed.emit(false)


func _process(_delta: float) -> void:
	if not _recording or _capture == null:
		return
	var available := _capture.get_frames_available()
	if available > 0:
		# 混音采样率（通常 48000）→ 16000 单声道。每个输出采样取对应那一段的平均，
		# 顺带当了一个粗糙的低通，免得高频折叠成杂音。
		for v in _capture.get_buffer(available):
			_rs_sum += (v.x + v.y) * 0.5
			_rs_count += 1
			_rs_pos += 1.0
			if _rs_pos < _resample_ratio:
				continue
			_rs_pos -= _resample_ratio
			var sample := _rs_sum / _rs_count
			_rs_sum = 0.0
			_rs_count = 0
			_samples.append(sample)
			_peak = maxf(_peak * 0.92, absf(sample))
	recording_tick.emit(recorded_seconds(), clampf(_peak * 4.0, 0.0, 1.0))
	if recorded_seconds() >= MAX_SECONDS:
		# 到点自己停，但**不自动发出去** —— 让玩家看一眼再决定（同微信）。
		_stop_capture()


func _ensure_bus() -> void:
	var idx := AudioServer.get_bus_index(MIC_BUS)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, MIC_BUS)
		# 静音：自己的声音不从自己的喇叭出来（那会直接啸叫）。
		# 静音只挡往外送，总线上的效果器照常拿得到数据。
		AudioServer.set_bus_mute(idx, true)
		var effect := AudioEffectCapture.new()
		effect.buffer_length = CAPTURE_BUFFER_SEC
		AudioServer.add_bus_effect(idx, effect)
	_capture = AudioServer.get_bus_effect(idx, 0) as AudioEffectCapture


# 项目设置里有没有打开录音输入（project.godot 的 [audio] 只对 windows/android/ios 打开）。
static func input_enabled() -> bool:
	return bool(ProjectSettings.get_setting_with_override("audio/driver/enable_input"))


# --- WAV ----------------------------------------------------------------------

# 16 位单声道 WAV。服务端会自己再解一遍头（backend/app/voice_clips.py 的 parse_wav），
# 两边对不上的症状是「录完发不出去」，所以这里写的是最老实的 44 字节头，不加任何可选块。
static func build_wav(samples: PackedFloat32Array, rate: int) -> PackedByteArray:
	var count := samples.size()
	var data_bytes := count * 2
	var out := PackedByteArray()
	out.resize(44 + data_bytes)
	out.encode_u32(0, 0x46464952)              # "RIFF"
	out.encode_u32(4, 36 + data_bytes)
	out.encode_u32(8, 0x45564157)              # "WAVE"
	out.encode_u32(12, 0x20746d66)             # "fmt "
	out.encode_u32(16, 16)                     # fmt 块长度
	out.encode_u16(20, 1)                      # PCM
	out.encode_u16(22, 1)                      # 单声道
	out.encode_u32(24, rate)
	out.encode_u32(28, rate * 2)               # 每秒字节数
	out.encode_u16(32, 2)                      # 每帧字节数
	out.encode_u16(34, 16)                     # 位深
	out.encode_u32(36, 0x61746164)             # "data"
	out.encode_u32(40, data_bytes)
	for i in count:
		out.encode_s16(44 + i * 2, clampi(roundi(samples[i] * 32767.0), -32768, 32767))
	return out


# --- 上传 / 下载 ---------------------------------------------------------------

# 🔴 这是客户端里**唯一**不走 AccountManager._request() 的带身份请求 ——
# 它发的是裸字节（WAV），不是 JSON。正因为这样，它必须从 auth_header_lines()
# 取那份头清单，不能自己拼：2026-10-12 就是自己拼、漏了 X-Glory-Session，
# 一发语音服务器就回 409 session_replaced（看着像被顶号，其实只是少一个头）。
func _upload(scope: String, wav: PackedByteArray) -> Dictionary:
	# 令牌快过期就先续掉（_request() 对自己的请求也是这么做的），免得白跑一趟 401。
	# 用的是 AccountManager 里早就有的那个（RealtimeService 建连前也调它）。
	var ready: bool = await AccountManager.ensure_fresh_token()
	var token := AccountManager.access_token()
	if not ready or token.is_empty():
		return {"ok": false, "error": _text("还没登录", "Not signed in")}
	var http := HTTPRequest.new()
	http.timeout = AccountConfig.REQUEST_TIMEOUT_SEC
	add_child(http)
	# 头只从 AccountManager.auth_header_lines() 取，**不在这里再拼一份**。
	# 2026-10-12 的事故就是这条路自己拼、漏了 X-Glory-Session：服务端 current_claims
	# 拿空串去 uuid.UUID() 直接抛，一律回 409 session_replaced，表现是「一发语音就红字」
	# 而且必现。那个函数的注释写了为什么不许有第二份清单。
	# 这是裸字节请求（不是 JSON），所以 content_type 要自己给，Authorization 也自己补。
	var headers := AccountManager.auth_header_lines("audio/wav")
	headers.append("Authorization: Bearer %s" % token)
	var url := AccountConfig.endpoint("/v1/voice/clips?scope=%s" % scope)
	var err := http.request_raw(url, headers, HTTPClient.METHOD_POST, wav)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": _text("发不出去", "Could not send")}
	var result: Array = await http.request_completed
	http.queue_free()
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": _text("连不上服务器", "Cannot reach the server")}
	var code := int(result[1])
	var raw := (result[3] as PackedByteArray).get_string_from_utf8()
	var json := JSON.new()
	var body: Dictionary = {}
	if json.parse(raw) == OK and json.data is Dictionary:
		body = json.data
	if code == 409 and str(body.get("detail", "")) == "session_replaced":
		# 真的被顶号了。和 _request() 里同一条路：标记下来，并且说人话 ——
		# 直接把 "session_replaced" 这串字扔给玩家看，是 2026-10-12 真机上的样子。
		RealtimeService._mark_kicked()
		return {"ok": false,
			"error": _text("你的账号在其他设备登录", "Signed in on another device")}
	if code < 200 or code >= 300:
		# 会话被顶：服务端的 detail 是内部标记 "session_replaced"，**不是给玩家看的文案**。
		# 绝不能原样透出去（就是它变成了聊天里那行英文红字）。这里自己出中文，
		# 并让 RealtimeService 去走正常的「被顶号」流程（回启动页提示重新登录）。
		if code == 409 and str(body.get("detail", "")) == "session_replaced":
			RealtimeService._mark_kicked()
			return {"ok": false, "error": _text("你的账号在其他设备登录", "Signed in on another device")}
		# 服务端的 detail 是给玩家看的中文（配额、太短、太长、没装 ffmpeg…），直接用。
		return {"ok": false, "error": str(body.get("detail", _text("语音发送失败", "Voice message failed")))}
	return {
		"ok": true,
		"clip_id": str(body.get("clip_id", "")),
		"media": str(body.get("media", "")),
		"seconds": float(body.get("seconds", 0.0)),
	}


# --- 播放 ---------------------------------------------------------------------

func is_playing(clip_id: String) -> bool:
	return _playing_clip == clip_id and _play_player != null and is_instance_valid(_play_player) \
		and _play_player.playing


# 文件名的形状。[.] 而不是反斜杠转义：GDScript 会先吃掉一层反斜杠。
# 与 backend/app/announcements.py 的 MEDIA_NAME_RE、NetworkService.VOICE_MEDIA_PATTERN
# 是同一个形状（tools/voice_clip_check.gd 三处一起钉）。
const MEDIA_PATTERN := "^[0-9a-f]{64}[.]ogg$"
static var _media_re: RegEx = null


# 🔴 下载前的最后一道门。media 会被拼进 /media/<media> 这个 URL：
# 私聊和世界频道的 payload 来自账号服务器（可信），但**对局里的是别的玩家的手机送过来的** ——
# 一个改包的客户端塞 "../../.." 进来，就是让这台手机去抓媒体服务器上的任意路径。
# 战斗服务器那边也拦（NetworkService.sanitize_voice），这里是收到之后自己再拦一次。
static func media_ok(media: String) -> bool:
	if _media_re == null:
		_media_re = RegEx.new()
		_media_re.compile(MEDIA_PATTERN)
	return _media_re.search(media) != null


# 播一条。media 是文件名（payload 里带着），clip_id 只用来标识「现在在放哪条」。
func play(clip_id: String, media: String) -> void:
	if is_playing(clip_id):
		stop_playback()
		return
	stop_playback()
	if not media_ok(media):
		return
	var bytes: PackedByteArray = _cache.get(media, PackedByteArray())
	if bytes.is_empty():
		bytes = await _download(media)
		if bytes.is_empty():
			return
		_remember(media, bytes)
	var stream := AudioStreamOggVorbis.load_from_buffer(bytes)
	if stream == null:
		return
	_play_player = AudioStreamPlayer.new()
	_play_player.name = "VoiceClipPlayer"
	_play_player.stream = stream
	add_child(_play_player)
	_play_player.finished.connect(_on_playback_finished)
	_play_player.play()
	_playing_clip = clip_id
	playback_changed.emit(clip_id, true)


func stop_playback() -> void:
	var was := _playing_clip
	_playing_clip = ""
	if _play_player != null and is_instance_valid(_play_player):
		_play_player.stop()
		_play_player.queue_free()
	_play_player = null
	if not was.is_empty():
		playback_changed.emit(was, false)


func _on_playback_finished() -> void:
	stop_playback()


func _download(media: String) -> PackedByteArray:
	var http := HTTPRequest.new()
	http.timeout = AccountConfig.REQUEST_TIMEOUT_SEC
	add_child(http)
	# /media 是公开的（线上由 Caddy 直接发），不带令牌 —— 文件名就是内容哈希。
	var err := http.request(AccountConfig.endpoint("/media/%s" % media))
	if err != OK:
		http.queue_free()
		return PackedByteArray()
	var result: Array = await http.request_completed
	http.queue_free()
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) != 200:
		return PackedByteArray()
	return result[3] as PackedByteArray


func _remember(media: String, bytes: PackedByteArray) -> void:
	_cache[media] = bytes
	_cache_order.append(media)
	while _cache_order.size() > CACHE_LIMIT:
		var oldest: String = _cache_order.pop_front()
		_cache.erase(oldest)


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
