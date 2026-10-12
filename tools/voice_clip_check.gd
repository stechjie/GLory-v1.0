extends Node

# 聊天里的短语音（docs/聊天系统设计.md「语音消息」，2026-10-11）的门禁。
#
# 验不了的：真的录到声音、真的传上去、真的播出来 —— 要真麦克风、真服务器、真手机。
# 这里钉的全是**不报错、只是坏**的那几件，它们的共同症状是玩家只看到一句「语音发送失败」：
#
#   1. 🔴 客户端写的 WAV 头和账号服务器的解析器对不上（build_wav vs voice_clips.parse_wav）。
#      两边读同一份字节：tools/fixtures/voice_clip_wav.json。pytest 那边按同一份判服务端。
#   2. 🔴 文件名形状卡不死路径穿越 —— media 会被拼进 /media/<name> 这个 URL，
#      而**对局里的 media 是别的玩家的手机送过来的**。两处（客户端、战斗服务器）都要拦。
#   3. 🔴 秒数不能信对端：它决定语音条宽度，传一个 99999 过来就能把界面拉爆。
#   4. 三种语言里的常量（Python / GDScript / SQL）对不上：客户端让你录 30 秒、服务端拒收。
#   5. 客户端节流与服务端额度的关系：间隔 × 额度 ≥ 窗口，否则诚实客户端被静默丢包。
#   6. 三个渠道共用一套显示（气泡 / 记录行）与一个录音按钮：两套画法迟早会漂。
#   7. 举报带得上编号 —— 对局里的语音不落库，这条链断了不会报错。
#   8. 通话中不能录语音（麦克风只有一个）。
#
# 「加了 @rpc 方法必须顶协议号」那三个钉子在 tools/chat_check.gd，不在这里。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . res://tools/voice_clip_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RateLimitService := preload("res://scripts/multiplayer/RateLimitService.gd")
const RoomChatLog := preload("res://scripts/multiplayer/RoomChatLog.gd")
const VoiceClipRow := preload("res://ui/components/VoiceClipRow.gd")
const VoiceRecordButton := preload("res://ui/components/VoiceRecordButton.gd")

const CHECK_NAME := "voice_clip"
const FIXTURE_PATH := "res://tools/fixtures/voice_clip_wav.json"
const PY_VOICE_CLIPS := "res://backend/app/voice_clips.py"
const PY_ROUTES_CHAT := "res://backend/app/routes/chat.py"
const PY_ROUTES_WORLD := "res://backend/app/routes/world.py"
const PY_REPORTS := "res://backend/app/reports.py"
const PY_ROUTES_REPORTS := "res://backend/app/routes/reports.py"
const MIGRATION := "res://database/033_voice_clips.sql"
const CLIP_SERVICE := "res://scripts/autoload/VoiceClipService.gd"
const CHAT_INPUT_BAR := "res://ui/components/ChatInputBar.gd"
const WORLD_PANEL := "res://scenes/menu/WorldChatPanel.gd"
const CHAT_SCREEN := "res://scenes/menu/ChatScreen.gd"
const LOBBY := "res://scenes/menu/Team3v3Lobby.gd"
const PREP_UI := "res://scenes/prep/PrepUI.gd"
const SEAT_CARD := "res://scenes/prep/panels/PrepSeatCard.gd"

# 路径穿越与形状不对的几种写法。全都必须被两处形状判据拒掉。
const BAD_NAMES := [
	"../../etc/passwd",
	"a/../../secret.ogg",
	"/etc/passwd",
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff.ogg/../x",
	"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff.ogg",
	"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF.ogg",
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff.wav",
	"",
]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_wav_matches_fixture()
	_case_media_shape_blocks_traversal()
	_case_sanitize_clamps_untrusted_seconds()
	_case_constants_match_server()
	_case_scopes_match_server()
	_case_throttle_covers_server_quota()
	_case_one_bubble_one_button()
	_case_entry_carries_clip()
	_case_report_path_passes_clip()
	_case_no_recording_during_call()
	_h.finish(get_tree())


# --- 1. 客户端的 WAV 头 = 服务端解析器认的那一种 -------------------------------
#
# 对不上的症状：录完「语音发送失败」，日志里只有一句 ClipRejected。
# 夹具由 backend/tests/test_voice_clips_stdlib.py 一起校验：两边读同一份字节，谁先漂谁红。
func _case_wav_matches_fixture() -> void:
	var fixture := _fixture()
	if not _h.expect(not fixture.is_empty(), "fixture_unreadable",
			"读不到 %s —— 这条判据就没有对账的基准了" % FIXTURE_PATH):
		return

	var rate := int(fixture.get("rate", 0))
	var count := int(fixture.get("sample_count", 0))
	var silence := PackedFloat32Array()
	silence.resize(count)
	var wav := VoiceClipService.build_wav(silence, rate)
	_h.expect(wav.size() == 44 + count * 2, "wav_size",
		"%d 个采样应该是 %d 字节，build_wav 给了 %d" % [count, 44 + count * 2, wav.size()])
	_h.expect(wav.slice(0, 44).hex_encode() == str(fixture.get("silence_header_hex", "")),
		"wav_header_drifted",
		"build_wav 的 44 字节头和夹具不一样了。改了头就要重算 %s、"
			% FIXTURE_PATH
		+ "并跑一次 backend/tests/test_voice_clips_stdlib.py —— 两边各自绿的话，"
		+ "真机上的症状是「录完发不出去」。")

	# 采样编码的边界：超幅必须**夹住**而不是绕回（绕回的听感是一声爆响）。
	var probes := PackedFloat32Array()
	for value in (fixture.get("probe_inputs", []) as Array):
		probes.append(float(value))
	var encoded := VoiceClipService.build_wav(probes, rate).slice(44)
	_h.expect(encoded.hex_encode() == str(fixture.get("probe_hex", "")), "wav_samples_drifted",
		"采样编码和夹具不一样了（夹的是 0 / 正负半幅 / 正负满幅 / 超幅 / 四舍五入 / 极小值）。"
		+ "超幅那两个尤其要紧：夹不住就会绕回成反相的满幅，听起来是一声爆响。")


# --- 2. 文件名形状：拦路径穿越 -------------------------------------------------
#
# 🔴 为什么这条是红的：收到消息的那一方会去 /media/<media> 下载。
# 私聊和世界频道的 payload 来自账号服务器（可信），但**房间 / 对局里的那条是
# 别的玩家的手机经战斗服务器转过来的** —— 一个改包的客户端塞 "../../.." 进来，
# 就是让别人的手机去抓媒体服务器上的任意路径。
func _case_media_shape_blocks_traversal() -> void:
	var good := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.ogg"
	_h.expect(good.length() == 68, "fixture_name_length", "测试用的文件名拼错了")
	_h.expect(VoiceClipService.media_ok(good), "client_rejects_good_name",
		"客户端不认 %s —— 它会拒播自己能收到的语音" % good)
	_h.expect(NetworkService.voice_media_ok(good), "server_rejects_good_name",
		"战斗服务器不认 %s —— 语音一条都转不出去" % good)
	for bad in BAD_NAMES:
		_h.expect(not VoiceClipService.media_ok(bad), "client_allows_bad_name",
			"客户端放过了 \"%s\"：它会被拼进 /media/<name> 去下载" % bad)
		_h.expect(not NetworkService.voice_media_ok(bad), "server_allows_bad_name",
			"战斗服务器放过了 \"%s\"：它会被转给同房间所有人的手机" % bad)

	# 两处 GDScript 的形状必须是同一个（SQL 那一处由 pytest 判）。
	_h.expect(VoiceClipService.MEDIA_PATTERN == NetworkService.VOICE_MEDIA_PATTERN,
		"media_pattern_mismatch",
		"客户端与战斗服务器的文件名形状不一样了（%s / %s）：一边放过、另一边拒播，"
			% [VoiceClipService.MEDIA_PATTERN, NetworkService.VOICE_MEDIA_PATTERN]
		+ "症状是「别人能听我不能听」。")


# --- 3. 秒数以服务器登记的为准，对端给的一律夹住 -------------------------------
func _case_sanitize_clamps_untrusted_seconds() -> void:
	var media := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.ogg"
	var huge := NetworkService.sanitize_voice("cid", media, 99999.0)
	_h.expect(not huge.is_empty(), "sanitize_rejected_good", "合法的那组被 sanitize_voice 拒了")
	_h.expect(float(huge.get("seconds", -1.0)) == NetworkService.VOICE_MAX_SECONDS,
		"seconds_not_clamped",
		"秒数没夹到上限（给了 99999，收敛成 %s）。界面按它算语音条宽度 —— "
			% str(huge.get("seconds", "?"))
		+ "不夹的话一条消息就能把记录面板拉爆。")
	_h.expect(float(NetworkService.sanitize_voice("cid", media, -5.0).get("seconds", -1.0)) >= 0.0,
		"negative_seconds", "负秒数没夹住")
	_h.expect(NetworkService.sanitize_voice("", media, 3.0).is_empty(), "empty_clip_id_allowed",
		"clip_id 空串也放过了 —— 那条语音点下去没反应，而且举报时查不到东西")
	_h.expect(NetworkService.sanitize_voice(
			"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", media, 3.0).is_empty(),
		"long_clip_id_allowed", "clip_id 长度没卡（uuid 是 36 位）")
	_h.expect(NetworkService.VOICE_MAX_SECONDS == VoiceClipService.MAX_SECONDS,
		"max_seconds_mismatch",
		"战斗服务器夹的上限（%.1f）和客户端录音上限（%.1f）不一样"
			% [NetworkService.VOICE_MAX_SECONDS, VoiceClipService.MAX_SECONDS])


# --- 4. 三种语言里的那几个数 ---------------------------------------------------
#
# 对不上的方向都很难看：客户端上限大 → 录完被服务端拒；小 → 录不到承诺的 30 秒。
func _case_constants_match_server() -> void:
	var py := _read(PY_VOICE_CLIPS)
	if not _h.expect(not py.is_empty(), "python_unreadable", "读不到 %s" % PY_VOICE_CLIPS):
		return
	var py_max := _py_number(py, "MAX_SECONDS")
	var py_min := _py_number(py, "MIN_SECONDS")
	_h.expect(py_max == VoiceClipService.MAX_SECONDS, "max_seconds",
		"Python 的 MAX_SECONDS 是 %s，GDScript 是 %.1f" % [str(py_max), VoiceClipService.MAX_SECONDS])
	_h.expect(py_min == VoiceClipService.MIN_SECONDS, "min_seconds",
		"Python 的 MIN_SECONDS 是 %s，GDScript 是 %.1f" % [str(py_min), VoiceClipService.MIN_SECONDS])
	_h.expect(py.contains(str(VoiceClipService.SAMPLE_RATE)), "sample_rate_not_allowed",
		"客户端用 %d Hz 录，但 Python 的 ALLOWED_RATES 里找不到这个数 —— 服务端会回 bad_rate"
			% VoiceClipService.SAMPLE_RATE)

	# 旧客户端那条占位文字：服务端写进 body，旧包会把它当文字画出来。
	# 世界频道的 body 有长度约束（033），塞不进去就是 insert 撞 check → HTTP 500。
	var sql := _read(MIGRATION)
	var bound := RegEx.create_from_string(
		"kind = 'voice' and char_length\\(body\\) between ([0-9]+) and ([0-9]+)").search(sql)
	if _h.expect(bound != null, "world_body_constraint_missing",
			"033 里世界频道那条 body 约束的写法变了，这条判据要跟着改"):
		var low := int(bound.get_string(1))
		var high := int(bound.get_string(2))
		var placeholder: String = RoomChatLog.VOICE_PLACEHOLDER % int(VoiceClipService.MAX_SECONDS)
		_h.expect(placeholder.length() >= low and placeholder.length() <= high,
			"placeholder_breaks_constraint",
			"占位文字「%s」(%d 字) 不满足 033 的 %d–%d —— 世界频道发语音会 HTTP 500"
				% [placeholder, placeholder.length(), low, high])


# --- 5. 三个渠道名 -------------------------------------------------------------
func _case_scopes_match_server() -> void:
	var sql := _read(MIGRATION)
	for scope in [VoiceClipService.SCOPE_PRIVATE, VoiceClipService.SCOPE_WORLD,
			VoiceClipService.SCOPE_MATCH]:
		_h.expect(sql.contains("'%s'" % scope), "scope_missing_in_sql",
			"033 的 scope 约束里没有 \"%s\" —— 用这个渠道上传会被 403「这段语音不能发到这里」" % scope)
	# 私聊走 routes/chat.py、世界频道走 routes/world.py，各自核的渠道不能串。
	_h.expect(_read(PY_ROUTES_CHAT).contains("\"%s\"" % VoiceClipService.SCOPE_PRIVATE),
		"chat_route_scope", "routes/chat.py 核的不是 private 渠道")
	_h.expect(_read(PY_ROUTES_WORLD).contains("\"%s\"" % VoiceClipService.SCOPE_WORLD),
		"world_route_scope", "routes/world.py 核的不是 world 渠道")


# --- 6. 客户端节流 vs 服务端额度 -----------------------------------------------
#
# 服务端超限是**静默丢弃**（不计 strike、也不回执）。客户端这边挡不住的话，
# 发出去的话会凭空消失 —— 同 chat_text 那段注释说的事。
func _case_throttle_covers_server_quota() -> void:
	var quota := int(RateLimitService.LIMITS.get("chat_voice", 0))
	if not _h.expect(quota > 0, "chat_voice_limit_missing",
			"RateLimitService.LIMITS 里没有 chat_voice —— 会落到默认 20，等于没限"):
		return
	var window := float(RateLimitService.WINDOW_SEC)
	var interval := float(NetworkService.VOICE_SEND_MIN_INTERVAL_SEC)
	_h.expect(interval * float(quota) >= window, "throttle_too_loose",
		"间隔 %.1f 秒 × 额度 %d < 窗口 %.1f 秒：按最快速度发，第 %d 条会落在同一个窗口里"
			% [interval, quota, window, quota + 1]
		+ "被服务端静默丢掉，而客户端什么都没拦 —— 玩家看到的是话凭空消失。")
	# 语音比文字贵（一条最长 30 秒），间隔不该比文字还松。
	_h.expect(interval >= float(NetworkService.TEXT_SEND_MIN_INTERVAL_SEC),
		"voice_cheaper_than_text",
		"语音间隔 %.1f 秒比文字的 %.1f 秒还短"
			% [interval, NetworkService.TEXT_SEND_MIN_INTERVAL_SEC])


# --- 7. 三个渠道共用一套显示 + 一个录音按钮 ------------------------------------
func _case_one_bubble_one_button() -> void:
	# 气泡（私聊 / 世界频道）：两个界面都走 VoiceClipBubble。
	for path in [CHAT_SCREEN, WORLD_PANEL]:
		var src := _read(path)
		_h.expect(src.contains("VoiceClipBubble.gd"), "bubble_not_shared",
			"%s 没用 VoiceClipBubble —— 两套画法迟早会漂（一边有「正在播」一边没有，不报错）" % path)
		_h.expect(src.contains("ChatService.is_voice"), "voice_branch_missing",
			"%s 里没有「这条是不是语音」的分支：语音会被当成文字画出一个占位串" % path)
	# 记录行（房间 / 对局）：大厅和摆放界面都走 VoiceClipRow。
	for path in [LOBBY, PREP_UI]:
		var src := _read(path)
		_h.expect(src.contains("VoiceClipRow.gd"), "row_not_shared",
			"%s 没用 VoiceClipRow —— 语音那行会只剩「[语音 12″]」几个字，点不开听" % path)
		_h.expect(src.contains("RoomChatLog.is_voice_entry"), "row_branch_missing",
			"%s 里没有「这条记录是不是语音」的分支" % path)
	# 录音按钮：四处都走 VoiceRecordButton（局内那两处经 ChatInputBar）。
	for path in [CHAT_SCREEN, WORLD_PANEL, CHAT_INPUT_BAR]:
		_h.expect(_read(path).contains("VoiceRecordButton"), "record_button_not_shared",
			"%s 没用 VoiceRecordButton" % path)
	for path in [LOBBY, PREP_UI]:
		_h.expect(_read(path).contains("on_voice"), "match_entry_missing",
			"%s 没把语音接到 ChatInputBar（少了 on_voice）—— 那个界面只能打字" % path)

	# 按钮与记录行都能真的建起来：load() 过不代表 new() 过（静态函数里引了 autoload）。
	var button := VoiceRecordButton.create(VoiceClipService.SCOPE_MATCH)
	_h.expect(button != null, "record_button_uninstantiable", "VoiceRecordButton.create() 返回 null")
	if button != null:
		button.free()
	var row := VoiceClipRow.wrap(_voice_entry(), Label.new())
	_h.expect(row != null, "row_uninstantiable", "VoiceClipRow.wrap() 返回 null")
	if row != null:
		row.free()


# --- 8. 记录里带着编号（举报要用） ---------------------------------------------
func _case_entry_carries_clip() -> void:
	var entry := _voice_entry()
	_h.expect(RoomChatLog.is_voice_entry(entry), "entry_not_voice",
		"make_entry 带了 voice 却没被认成语音")
	_h.expect(int(entry.get("phrase_id", -1)) == 0 and str(entry.get("text", "x")).is_empty(),
		"entry_mixes_kinds", "语音记录里还留着短语 id / 文字：显示时会两样都画出来")
	var en := RoomChatLog.line_text(entry, true)
	var zh := RoomChatLog.line_text(entry, false)
	_h.expect(zh.contains("12") and en.contains("12"), "line_text_loses_seconds",
		"line_text 没把秒数画出来（中文「%s」英文「%s」）—— 只吃一行字的地方会显示空白" % [zh, en])

	# 翻记录找「这个人最后那段语音」：举报面板只认一段。
	var history := RoomChatLog.new()
	history.add(7, RoomChatLog.make_entry(1, 0, "", false, 0, {}, {}, 1, false,
		{"clip_id": "old", "media": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.ogg",
		"seconds": 2.0}))
	history.add(7, RoomChatLog.make_entry(1, 0, "随便说句话", false, 0, {}, {}, 1, false))
	history.add(7, RoomChatLog.make_entry(1, 0, "", false, 0, {}, {}, 2, false,
		{"clip_id": "new", "media": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.ogg",
		"seconds": 5.0}))
	var latest := history.latest_voice_clip(1, {})
	_h.expect(latest == "new", "latest_clip_wrong",
		"latest_voice_clip 取到的是 \"%s\"，应该是最后那条" % latest)
	_h.expect(history.latest_voice_clip(2, {}).is_empty(), "latest_clip_wrong_person",
		"latest_voice_clip 把别人的语音算到这个座位头上了 —— 举报会挂错人的证据")


# --- 9. 举报带得上编号 --------------------------------------------------------
#
# 🔴 房间 / 对局里的语音**不落库**，账号服务器翻不出他发过什么。
# 不把编号带上去，后台就只看得到「谁举报了谁」—— 这条链断了不会报错。
func _case_report_path_passes_clip() -> void:
	var dialog: Script = load("res://ui/components/ReportDialog.gd")
	var has_clip := false
	for method in dialog.get_script_method_list():
		if str(method.get("name", "")) != "present":
			continue
		for arg in (method.get("args", []) as Array):
			if str(arg.get("name", "")) == "clip_id":
				has_clip = true
	_h.expect(has_clip, "report_dialog_no_clip",
		"ReportDialog.present 没有 clip_id 参数：举报语音时后台点不开听")
	_h.expect(_read(WORLD_PANEL).contains("clip_id"), "world_report_no_clip",
		"世界频道举报某一条时没带 clip_id")
	_h.expect(_read(SEAT_CARD).contains("report_requested"), "match_report_missing",
		"摆放界面的头像卡片上没有举报入口 —— 房间 / 对局里的语音就永远举报不了"
		+ "（那条消息不落库，证据只能靠 clip_id 从 voice_clips 里查）")
	_h.expect(_read(PREP_UI).contains("_on_seat_report_requested"), "match_report_unwired",
		"PrepUI 没接 PrepSeatCard 的举报信号：点了没反应")
	_h.expect(_read(PY_ROUTES_REPORTS).contains("clip_id"), "report_route_no_clip",
		"举报接口没收 clip_id")
	_h.expect(_read(PY_REPORTS).contains("hold_for_report"), "report_no_hold",
		"举报时没推迟语音文件的清理：保留期是 7~30 天，处理举报拖久一点，"
		+ "后台点开证据会是「这段语音已经没有了」")


# --- 10. 通话中不能录语音 -----------------------------------------------------
#
# 麦克风只有一个。组队语音（LiveKit）占着的时候再开 AudioEffectCapture，
# 录出来的是空的或者断续的 —— 玩家只会觉得「语音坏了」。
func _case_no_recording_during_call() -> void:
	var src := _read(CLIP_SERVICE)
	_h.expect(src.contains("VoiceService.mode") or src.contains("VoiceService.Mode"),
		"no_call_guard",
		"start_recording 里没判「是不是正在通话」—— 麦克风只有一个，抢起来录出来是空的")
	_h.expect(src.contains("input_enabled"), "no_input_guard",
		"没判麦克风输入有没有开（project.godot 的 driver/enable_input）")


# --- 小工具 -------------------------------------------------------------------


func _voice_entry() -> Dictionary:
	return RoomChatLog.make_entry(1, 0, "", true, 0, {}, {}, 2, false,
		{"clip_id": "cid",
		"media": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.ogg",
		"seconds": 12.0})


func _fixture() -> Dictionary:
	var text := _read(FIXTURE_PATH)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# Python 里的 `NAME = 12.5`。读不到返回 NAN（判据会因此红，不会静默当 0）。
func _py_number(src: String, name: String) -> float:
	var found := RegEx.create_from_string("(?m)^%s = ([0-9.]+)" % name).search(src)
	return NAN if found == null else float(found.get_string(1))
