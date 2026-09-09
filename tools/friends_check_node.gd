extends Node

# 交友系统的客户端门禁（docs/交友系统设计.md）。
#
# 后端那半在 backend/tests/test_friends.py。这里守的是**客户端独有、
# 且坏了不会报错**的几件事：
#
#   1. 心跳间隔与后端的 TTL 对不上 -> 在线状态闪烁或永远显示离线。
#      两个常量在两种语言里，分开改不会有任何症状，只能靠断言。
#   2. 好友码校验与数据库字母表漂了 -> 玩家手抄一个合法的码却被本地拒掉。
#   3. 门面方法缺一个 -> 界面上那个按钮点了没反应。
#   4. 主菜单按钮还连着「敬请期待」-> 整个系统进不去。
#
# 用法：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/friends_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "friends"
const BACKEND_FRIENDS := "res://backend/app/friends.py"
const SQL_004 := "res://database/004_profile_display.sql"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_heartbeat_matches_backend()
	_case_friend_code_alphabet()
	_case_facade_methods()
	_case_menu_button_wired()
	_case_main_routes()
	_case_screen_contract()
	await _case_screen_builds()
	_h.finish(get_tree())


# --- 1. 跨语言常量 ------------------------------------------------------------


func _case_heartbeat_matches_backend() -> void:
	var source := _read(BACKEND_FRIENDS)
	if not _h.expect(not source.is_empty(), "backend_source_missing",
			"读不到 %s —— 无法核对心跳常量" % BACKEND_FRIENDS):
		return

	var beat := _grab_number(source, "HEARTBEAT_INTERVAL_SEC = ")
	var ttl := _grab_number(source, "PRESENCE_TTL = dt.timedelta(seconds=")
	if not _h.expect(beat > 0.0 and ttl > 0.0, "backend_constants_unreadable",
			"从 friends.py 里解析不出 HEARTBEAT_INTERVAL_SEC / PRESENCE_TTL，正则可能过期"):
		return

	# 客户端发得比后端判定的 TTL 慢，好友那边就会一直看到「离线」——
	# 而客户端这边一切正常，日志里什么都没有。
	_h.expect(is_equal_approx(AccountManager.PRESENCE_HEARTBEAT_SEC, beat),
		"heartbeat_mismatch",
		"客户端心跳 %.0f 秒与后端 HEARTBEAT_INTERVAL_SEC %.0f 秒不一致"
			% [AccountManager.PRESENCE_HEARTBEAT_SEC, beat])
	_h.expect(AccountManager.PRESENCE_HEARTBEAT_SEC < ttl, "heartbeat_exceeds_ttl",
		"心跳 %.0f 秒 >= 后端 TTL %.0f 秒，在线状态会闪烁"
			% [AccountManager.PRESENCE_HEARTBEAT_SEC, ttl])
	# 至少要能容忍丢一次心跳，否则等于没有余量。
	_h.expect(ttl >= AccountManager.PRESENCE_HEARTBEAT_SEC * 2.0, "ttl_has_no_slack",
		"TTL %.0f 秒不足心跳的两倍，丢一个包就显示离线" % ttl)


# --- 2. 好友码 ----------------------------------------------------------------


func _case_friend_code_alphabet() -> void:
	# 与 database/004 的 check 约束同源。排掉的 0 O 1 I L 是最容易抄错的字符。
	for bad in ["", "1234567", "123456789", "7K2M9Q4", "7K2M9Q4B0", "7K2M9Q4O"]:
		_h.expect(not AccountManager.friend_code_problem(bad).is_empty(),
			"bad_code_accepted", "非法好友码 %s 被本地放行了" % bad)
	for good in ["7K2M9Q4B", "7k2m9q4b", " 7K2M9Q4B "]:
		_h.expect(AccountManager.friend_code_problem(good).is_empty(),
			"good_code_rejected", "合法好友码 %s 被本地拒了" % good)
	_h.expect(AccountManager.normalize_friend_code(" 7k2m9q4b ") == "7K2M9Q4B",
		"normalize_wrong", "好友码归一必须去空白并转大写（库里一律存大写）")

	# 与 SQL 的正则逐字符对齐：两边各改各的话，会出现「生成得出来但本地存不进去」。
	var sql := _read(SQL_004)
	if _h.expect(sql.contains("friend_code ~"), "sql_regex_missing",
			"004 里找不到 friend_code 的 check 约束"):
		for ch in "OIL01":
			_h.expect(not AccountManager.friend_code_problem("7K2M9Q4" + ch).is_empty(),
				"confusable_accepted", "易混字符 %s 应当被拒（004 的字母表排掉了它）" % ch)


# --- 3. 门面 ------------------------------------------------------------------


func _case_facade_methods() -> void:
	for method in [
		"fetch_friends", "fetch_friend_requests", "send_friend_request",
		"accept_friend_request", "drop_friend_request", "remove_friend",
		"fetch_blocks", "block_player", "unblock_player", "fetch_recent_players",
		"fetch_presence_visibility", "update_presence_visibility",
		"configure_presence", "start_presence", "stop_presence", "report_presence_now",
	]:
		_h.expect(AccountManager.has_method(method), "facade_method_missing",
			"AccountManager 缺 %s() —— 界面上对应的按钮会点了没反应" % method)

	# 昵称永远带好友码。players.player_name 不唯一（database/001），
	# 只显示昵称就能被改同名的人冒充。
	_h.expect(AccountManager.display_name("Leno", "7K2M9Q4B") == "Leno #7K2M9Q4B",
		"display_name_drift", "display_name 必须是「昵称 #好友码」")


# --- 4 / 5. 接线 --------------------------------------------------------------


func _case_menu_button_wired() -> void:
	var menu: GDScript = load("res://scenes/menu/MainMenu.gd")
	if not _h.expect(menu != null, "menu_script_missing", "读不到 MainMenu.gd"):
		return
	var signals := []
	for s in menu.get_script_signal_list():
		signals.append(str(s.get("name", "")))
	_h.expect(signals.has("friends_requested"), "menu_signal_missing",
		"MainMenu 没有 friends_requested 信号")

	# 按钮还连着「敬请期待」的话，整个系统根本进不去 —— 而这不会报错。
	var source := _read("res://scenes/menu/MainMenu.gd")
	var hit := source.contains("Vector2(28, 300), Vector2(132, 132), _emit_friends")
	_h.expect(hit, "menu_button_not_wired",
		"主菜单「朋友」按钮没接到 _emit_friends（还连着 _show_coming_soon？）")


func _case_main_routes() -> void:
	var main: GDScript = load("res://scenes/main/Main.gd")
	if not _h.expect(main != null, "main_script_missing", "读不到 Main.gd"):
		return
	var methods := []
	for m in main.get_script_method_list():
		methods.append(str(m.get("name", "")))
	for needed in ["_show_friends_screen", "_show_public_profile", "_join_room_by_id",
			"_install_presence_reporting"]:
		_h.expect(methods.has(needed), "main_route_missing",
			"Main.gd 缺 %s() —— 好友界面进不去或心跳没接线" % needed)


func _case_screen_contract() -> void:
	var screen: GDScript = load("res://scenes/menu/FriendsScreen.gd")
	if not _h.expect(screen != null, "screen_script_missing", "读不到 FriendsScreen.gd"):
		return
	var signals := []
	for s in screen.get_script_signal_list():
		signals.append(str(s.get("name", "")))
	for needed in ["back_requested", "profile_requested", "join_room_requested"]:
		_h.expect(signals.has(needed), "screen_signal_missing",
			"FriendsScreen 缺信号 %s —— Main 那边的 connect 会在运行时报错" % needed)


# --- 6. 界面真的能搭起来 ------------------------------------------------------


func _case_screen_builds() -> void:
	# 纯静态断言挡不住「Tokens 常量名写错」「某个节点忘了 add_child」这类错误，
	# 它们只在界面真的被搭出来时才炸。这里把整页搭一遍。
	#
	# 没有后端也能跑：AccountManager 未登录时 _request 直接返回 401，不发请求。
	var packed: PackedScene = load("res://scenes/menu/FriendsScreen.tscn")
	if not _h.expect(packed != null, "screen_scene_missing", "读不到 FriendsScreen.tscn"):
		return
	var screen: Control = packed.instantiate()
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(screen.get_child_count() > 0, "screen_built_nothing",
		"FriendsScreen 搭完之后一个子节点都没有")

	# 三个页签都切一遍：每个页签是一条独立的渲染路径，只验默认那个等于没验。
	for tab in [0, 1, 2]:
		screen.call("_switch_tab", tab)
		await get_tree().process_frame
		_h.item()
	screen.queue_free()


# --- 小工具 -------------------------------------------------------------------


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _grab_number(source: String, prefix: String) -> float:
	var at := source.find(prefix)
	if at < 0:
		return -1.0
	var rest := source.substr(at + prefix.length(), 24)
	var digits := ""
	for ch in rest:
		if ch.is_valid_int() or ch == ".":
			digits += ch
		else:
			break
	return float(digits) if not digits.is_empty() else -1.0
