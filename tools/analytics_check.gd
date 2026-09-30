extends Node

# 运营数据第二批（scripts/autoload/AnalyticsService.gd，docs/运营数据.md 第六节）的客户端验收。
#
# 每条都对应一个**不会报错、只会让后台的数悄悄不对**的失败：
#
#   1. 专服、门禁（headless）里整个关着：不往真账号服务器发、不写队列文件
#   2. 🔴 事件名、字段和账号服务器的名单（backend/app/client_events.py）对得上 ——
#      名单外的事件服务器整条拒收，名单外的字段悄悄丢掉
#   3. 🔴 报错文字里的 IP、电脑路径、长串令牌、邮箱先抹掉；res:// 路径不能被误抹
#   4. 队列有上限；🔴 换号之后上一个人记的不挂到下一个人名下
#   5. 每回合结果按回合去重（重连会再收一次）；赢没赢按服务器的连败数判；
#      打完的局、没开的局不记「中途离开」
#   6. 同一种报错一次启动只报一次
#   7. 教学步骤耗时只算前台（手机切后台那段不算）
#   8. 队列存到本机、重开能读回来，7 天前的丢掉
#   9. 发出去的 JSON 里整数不是科学计数法（服务器按整数收）
#  10. 接线：教学四处、对局两处、战斗播放两处、账号门面、autoload 顺序
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/analytics_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Service := preload("res://scripts/autoload/AnalyticsService.gd")

const CHECK_NAME := "analytics"
const BACKEND_PATH := "res://backend/app/client_events.py"
# 门禁自己的队列文件，不碰这台电脑上真实的那份。
const TEMP_QUEUE := "user://analytics_check_queue.bin"

var _h: CheckHarness
var _py := ""


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_py = FileAccess.get_file_as_string(BACKEND_PATH)
	_case_live_autoload_is_off_in_headless()
	_case_events_match_backend()
	_case_props_are_cleaned_and_scrubbed()
	_case_queue_bound_and_account_switch()
	_case_rounds_and_leaving()
	_case_errors_are_deduplicated()
	_case_foreground_clock()
	_case_queue_survives_restart()
	_case_payload_is_plain_json()
	_case_wiring()
	SaveManager.remove_all_variants(TEMP_QUEUE)
	_h.finish(get_tree())


func _fresh() -> Service:
	var svc: Service = Service.new()
	svc.queue_path = TEMP_QUEUE
	svc.enable()
	return svc


func _events(svc: Service, event_name: String) -> Array:
	var out: Array = []
	for event in svc._queue:
		if str(event["name"]) == event_name:
			out.append(event)
	return out


# 服务器名单里这种事件那一段（从 `"name": {` 到它的 `}`）。
func _backend_fields(event_name: String) -> String:
	var start := _py.find('"%s": {' % event_name)
	if start < 0:
		return ""
	var end := _py.find("}", start)
	return _py.substr(start, end - start + 1)


# 事件真带出来的每个字段，服务器的名单里都要有 —— 不然这个字段到了服务器就被悄悄丢掉。
func _expect_fields_known(event: Dictionary) -> void:
	var event_name := str(event["name"])
	var fields := _backend_fields(event_name)
	if not _h.expect(not fields.is_empty(), "event_unknown_to_backend",
			"客户端会报 %s，但 client_events.EVENTS 里没有 —— 服务器会整条拒收" % event_name):
		return
	for key in (event["props"] as Dictionary).keys():
		_h.expect(fields.contains('"%s":' % key), "field_unknown_to_backend",
			"%s 带了字段 %s，服务器名单里没有 —— 到了服务器会被丢掉" % [event_name, key])


# --- 1 -------------------------------------------------------------------------

func _case_live_autoload_is_off_in_headless() -> void:
	_h.expect(not AnalyticsService._enabled, "live_enabled_in_headless",
		"headless 下 AnalyticsService 开着 —— 门禁和专服会往线上账号服务器发假数据")
	var before := AnalyticsService._queue.size()
	AnalyticsService.track("app_open", {"first": true})
	_h.expect(AnalyticsService._queue.size() == before, "live_track_records_in_headless",
		"关着的时候 track() 仍然往队列里放")


# --- 2 -------------------------------------------------------------------------

func _case_events_match_backend() -> void:
	if not _h.expect(not _py.is_empty(), "backend_unreadable", "读不到 %s" % BACKEND_PATH):
		return
	_h.expect(_py.contains("BATCH_MAX = %d" % Service.BATCH_MAX), "batch_max_drift",
		"一批最多几条两边不一样（客户端 %d）—— 服务器会整批 422，客户端把这一批丢掉" % Service.BATCH_MAX)
	# 源码里每一处 track("xxx"、以及服务里按名字记的事件，服务器名单里都得有。
	var pattern := RegEx.create_from_string("track\\(\"([a-z_]+)\"")
	for path in ["res://scripts/autoload/AnalyticsService.gd", "res://scenes/battle/BattleScreen.gd"]:
		var source := FileAccess.get_file_as_string(path)
		var found := pattern.search_all(source)
		_h.expect(not found.is_empty(), "no_track_calls", "%s 里一处 track 都没找到" % path)
		for m in found:
			var event_name := m.get_string(1)
			_h.expect(_py.contains('"%s": {' % event_name), "event_unknown_to_backend",
				"%s 会报 %s，服务器名单里没有 —— 整条拒收" % [path, event_name])


# --- 3 -------------------------------------------------------------------------

func _case_props_are_cleaned_and_scrubbed() -> void:
	var svc := _fresh()
	svc.track("perf", {"fps": 59.876, "nested": {"a": 1}, "list": [1, 2], "ok": true, "slow": 3,
		# 带空格：一整串 500 个 x 会被当成令牌抹成 <redacted>，测不到截断。
		"ctx": "ab ".repeat(200)})
	var props: Dictionary = svc._queue[0]["props"]
	_h.expect(not props.has("nested") and not props.has("list"), "nested_props_kept",
		"字典、数组也进了事件 —— 服务器只收标量")
	_h.expect(is_equal_approx(float(props["fps"]), 59.88), "float_not_rounded", "小数没有截到两位：%s" % str(props["fps"]))
	_h.expect(str(props["ctx"]).length() == Service.MAX_STRING, "string_not_capped", "字符串没截断")
	var raw := ("connect 34.124.141.90:8080 failed, key C:\\Users\\stech\\AppData\\Roaming\\key.pem "
		+ "/home/glory/.env token eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIn0 mail a.b@example.com "
		+ "at res://scenes/battle/BattleScreen.gd:1070 user://glory_reconnect.json")
	var clean := svc._scrub(raw)
	for secret in ["34.124.141.90", "stech", "/home/glory", "eyJhbGci", "a.b@example.com"]:
		_h.expect(not clean.contains(secret), "secret_not_scrubbed", "抹字之后还留着 %s：%s" % [secret, clean])
	_h.expect(clean.contains("res://scenes/battle/BattleScreen.gd:1070") and clean.contains("user://glory_reconnect.json"),
		"res_path_scrubbed", "res:// / user:// 路径被当成电脑路径抹掉了 —— 报错就不知道在哪一行：%s" % clean)
	var uuid_re := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	_h.expect(uuid_re.search(svc._uuid()) != null and uuid_re.search(svc.session_id) != null,
		"uuid_malformed", "事件编号不是标准 UUID —— 服务器整批 422")
	svc.free()


# --- 4 -------------------------------------------------------------------------

func _case_queue_bound_and_account_switch() -> void:
	var svc := _fresh()
	for i in Service.MAX_QUEUE + 5:
		svc.track("perf", {"sec": i})
	_h.expect(svc._queue.size() == Service.MAX_QUEUE and svc._dropped == 5, "queue_unbounded",
		"队列没有上限（%d 条，丢了 %d）" % [svc._queue.size(), svc._dropped])
	_h.expect(int(svc._queue[0]["props"]["sec"]) == 5, "queue_drops_newest", "满了丢的不是最旧的")
	svc._queue = [{"id": "1", "pid": ""}, {"id": "2", "pid": "player-a"}, {"id": "3", "pid": "player-b"}]
	svc.keep_only_player("player-a")
	var ids: Array = []
	for event in svc._queue:
		ids.append(str(event["id"]))
	_h.expect(ids == ["1", "2"], "account_switch_leaks",
		"🔴 换号后上一个号记的还在队列里（%s）—— 会记到这个号名下" % str(ids))
	svc.free()


# --- 5 -------------------------------------------------------------------------

func _case_rounds_and_leaving() -> void:
	var svc := _fresh()
	svc.match_left("user_leave")
	_h.expect(_events(svc, "match_leave").is_empty(), "leave_without_match", "没开局就记了中途离开")
	svc.note_mode("ranked")
	svc._on_match_started()
	var state := {"completed_round": 5, "battle_id": "b5", "slot": 4, "kind": "boss", "loss_streak": 0,
		"team_hp": 40, "enemy_team_hp": 35, "gold": 12, "carrots": 3, "harvest_tech_level": 1, "run_over": false}
	svc._on_match_state(state)
	svc._on_match_state(state)
	var lost := state.duplicate()
	lost["completed_round"] = 6
	lost["battle_id"] = "b6"
	lost["loss_streak"] = 1
	svc._on_match_state(lost)
	var rounds := _events(svc, "round_result")
	if _h.expect(rounds.size() == 2, "round_not_deduplicated", "同一回合收两次记了两条（%d 条）" % rounds.size()):
		var first: Dictionary = rounds[0]["props"]
		_h.expect(bool(first["won"]) and not bool(rounds[1]["props"]["won"]), "round_win_wrong",
			"赢没赢判错了：服务器的连败数 0 = 这回合赢了")
		_h.expect(int(first["team"]) == 1 and str(first["mode"]) == "ranked" and str(first["kind"]) == "boss",
			"round_context_wrong", "回合结果的队伍 / 模式 / 类型不对：%s" % str(first))
		_h.expect(str(first["m"]) == str(_events(svc, "match_start")[0]["props"]["m"]), "round_not_linked",
			"回合结果和开局记录串不起来（本局编号不一样）")
		_expect_fields_known(rounds[0])
	_expect_fields_known(_events(svc, "match_start")[0])
	svc.match_left("user_leave")
	svc.match_left("user_leave")
	var leaves := _events(svc, "match_leave")
	_h.expect(leaves.size() == 1, "leave_counted_twice", "中途离开记了 %d 次" % leaves.size())
	if not leaves.is_empty():
		_expect_fields_known(leaves[0])
	# 打完的局：之后回主菜单不算中途离开。
	svc._on_match_started()
	var over := state.duplicate()
	over["completed_round"] = 21
	over["battle_id"] = "b21"
	over["run_over"] = true
	svc._on_match_state(over)
	svc.match_left("user_leave")
	_h.expect(_events(svc, "match_leave").size() == 1, "finished_match_counted_as_leave",
		"打完的局回主菜单也被记成中途离开")
	svc.free()


# --- 6 -------------------------------------------------------------------------

func _case_errors_are_deduplicated() -> void:
	var svc := _fresh()
	svc._catcher = Service.ErrorCatcher.new()
	svc._catcher.pending = [
		[Logger.ERROR_TYPE_ERROR, "res://a.gd:10", "f", "connect to 34.1.2.3 failed, attempt 1"],
		[Logger.ERROR_TYPE_ERROR, "res://a.gd:10", "f", "connect to 34.1.2.3 failed, attempt 2"],
		[Logger.ERROR_TYPE_SCRIPT, "res://b.gd:5", "g", "Invalid access to property 'x'"],
	]
	svc._drain_errors()
	var errors := _events(svc, "client_error")
	_h.expect(errors.size() == 2, "error_not_deduplicated", "同一处同一句（只差数字）报了多次：%d 条" % errors.size())
	_h.expect(svc._error_count == 3, "error_count_wrong", "报错总数 %d，应为 3" % svc._error_count)
	for event in errors:
		_h.expect(not str(event["props"]["msg"]).contains("34.1.2.3"), "error_ip_kept", "报错里的 IP 没抹掉")
		_expect_fields_known(event)
	svc._catcher = null
	svc.free()


# --- 7 -------------------------------------------------------------------------

func _case_foreground_clock() -> void:
	var svc := _fresh()
	# 门禁跑起来时引擎才启动一两秒，按实际启动时长取比例，别算出负的时刻。
	var now := Time.get_ticks_msec()
	var quarter := maxi(1, now / 4)
	svc._background_msec = quarter          # 之前在后台待过 1/4
	svc._paused_at_msec = now - quarter     # 现在又切到后台 1/4 了
	var fg := svc.foreground_msec()
	_h.expect(absi(fg - (now - 2 * quarter)) < 50, "background_counted",
		"前台时钟把后台时间也算进去了（%d，应约 %d）" % [fg, now - 2 * quarter])
	svc._paused_at_msec = -1
	svc._background_msec = 0
	svc._tutorial_step_fg = svc.foreground_msec() - 1234
	svc.tutorial_step("BUY_3", "PLACE_3", 1)
	var step: Dictionary = _events(svc, "tutorial_step")[0]
	_h.expect(absi(int(step["props"]["ms"]) - 1234) < 100, "step_time_wrong", "这一步停了多久算错了：%s" % str(step["props"]))
	_expect_fields_known(step)
	svc.tutorial_skipped("PLACE_3", 2)
	_expect_fields_known(_events(svc, "tutorial_skip")[0])
	svc.tutorial_resumed("PLACE_3", 2)
	_expect_fields_known(_events(svc, "tutorial_resume")[0])
	svc.free()


# --- 8 -------------------------------------------------------------------------

func _case_queue_survives_restart() -> void:
	SaveManager.remove_all_variants(TEMP_QUEUE)
	var svc := _fresh()
	svc.track("perf", {"sec": 7})
	svc._queue.append({"id": "old", "name": "perf", "t": svc._now_msec() - Service.MAX_AGE_MS - 1000,
		"pid": "", "sid": "", "props": {}})
	svc._dirty = true
	svc._persist()
	svc.free()
	var again := _fresh()
	again._load_queue()
	_h.expect(again._queue.size() == 1, "queue_not_restored",
		"重开后队列 %d 条（应为 1：新的留下、7 天前的丢掉）" % again._queue.size())
	if again._queue.size() == 1:
		var sec: Variant = again._queue[0]["props"]["sec"]
		_h.expect(typeof(sec) == TYPE_INT and int(sec) == 7, "queue_types_lost", "读回来的整数变了类型：%s" % str(sec))
	again.free()


# --- 9 -------------------------------------------------------------------------

func _case_payload_is_plain_json() -> void:
	var svc := _fresh()
	svc.track("round_result", {"round": 5, "won": true, "gold": 1234567})
	var event: Dictionary = svc._queue[0]
	var text := JSON.stringify({"sent_at": svc._now_msec(), "install_id": svc._uuid(), "events": [
		{"id": event["id"], "name": event["name"], "t": event["t"], "sid": event["sid"], "props": event["props"]}]})
	_h.expect(text.contains('"t":%d' % int(event["t"])) and not text.contains("e+"), "timestamp_not_integer",
		"时间戳没按整数写出去：%s" % text)
	_h.expect(text.contains('"gold":1234567'), "int_prop_not_integer", "整数字段没按整数写出去：%s" % text)
	svc.free()


# --- 10 ------------------------------------------------------------------------

func _body_of(source: String, header: String) -> String:
	var start := source.find(header)
	if start < 0:
		return ""
	var end := source.find("\nfunc ", start + header.length())
	return source.substr(start, (end if end > 0 else source.length()) - start)


func _case_wiring() -> void:
	var tutorial := FileAccess.get_file_as_string("res://scripts/tutorial/TutorialMode.gd")
	_h.expect(_body_of(tutorial, "func _advance_to(").contains("AnalyticsService.tutorial_step("), "tutorial_step_unwired",
		"教学的唯一推进入口 _advance_to 没记步骤 —— 教学漏斗全空")
	_h.expect(_body_of(tutorial, "func start(").contains("AnalyticsService.tutorial_started()"), "tutorial_start_unwired",
		"TutorialMode.start() 没记开始")
	_h.expect(_body_of(tutorial, "func restore_checkpoint(").contains("AnalyticsService.tutorial_resumed("),
		"tutorial_resume_unwired", "从断点恢复没记")
	_h.expect(_body_of(tutorial, "func _on_skip_dialog_result(").contains("AnalyticsService.tutorial_skipped("),
		"tutorial_skip_unwired", "确认跳过没记")
	var network := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	_h.expect(_body_of(network, "func request_user_leave(").contains("AnalyticsService.match_left("), "leave_unwired",
		"玩家主动退出的唯一入口没记中途离开")
	_h.expect(_body_of(network, "func team_request_create_room(").contains('AnalyticsService.note_mode("custom")')
		and _body_of(network, "func team_request_join_room(").contains('AnalyticsService.note_mode("custom")'),
		"custom_mode_unwired", "自己建房 / 按房号进房没记成 custom 模式")
	var account := FileAccess.get_file_as_string("res://scripts/autoload/AccountManager.gd")
	_h.expect(_body_of(account, "func join_match_queue(").contains("AnalyticsService.note_mode(mode)"), "queue_mode_unwired",
		"排队没记模式 —— 匹配进的局分不出休闲和排位")
	_h.expect(_body_of(account, "func post_events(").contains('"/v1/events"'), "post_events_path",
		"AccountManager.post_events 不是发到 /v1/events")
	var battle := FileAccess.get_file_as_string("res://scenes/battle/BattleScreen.gd")
	_h.expect(_body_of(battle, "func _finish_replay(").contains('AnalyticsService.track("replay_done"')
		and _body_of(battle, "func _fail_team_replay(").contains('AnalyticsService.track("replay_failed"'),
		"replay_unwired", "战斗播完 / 播放失败没记")
	var routes := FileAccess.get_file_as_string("res://backend/app/main.py")
	_h.expect(routes.contains("app.include_router(event_routes.router)"), "backend_route_missing",
		"账号服务器没挂 /v1/events —— 客户端会一直 404，队列攒满后开始丢")
	# AnalyticsService._ready 要连 NetworkService 的信号，所以必须排在它后面；StartupTrace 仍是第一个。
	var project := FileAccess.get_file_as_string("res://project.godot")
	var at_network := project.find('NetworkService="*res://')
	var at_analytics := project.find('AnalyticsService="*res://scripts/autoload/AnalyticsService.gd"')
	_h.expect(at_analytics > 0 and at_analytics > at_network, "autoload_order",
		"AnalyticsService 没注册，或排在 NetworkService 前面（_ready 里连它的信号会报错）")
