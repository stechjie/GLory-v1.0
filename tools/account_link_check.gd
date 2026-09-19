extends Node

# 「连不上账号服务器就进不了游戏」的后半段（Main._watch_account_link）。
#
# 启动页那一半由 bootstrap_check 管（entry_view 是纯函数）。这里管的是
# **进了游戏之后**：此前主菜单完全不监听掉线，玩家会停在一个显示已登录、
# 其实已经断了的主菜单里。
#
# 最要紧的几条，失败时都**不报错**：
#
#   1. 对局中绝不能被送回启动页 —— 那等于毁掉一局。对局界面靠 _enter_match_flow()
#      自报；漏一个，那个界面的玩家掉线就会被踢出对局。
#   2. _clear() 必须把对局标记复位。否则打完一局回主菜单，标记还是 true，
#      之后掉线永远不会被送回去 —— 规则悄悄失效。
#   3. 启动页与主菜单的耐心值是同一个数（AccountConfig.CONNECT_PATIENCE_SEC）。
#   4. 发布包里不能有「离线自测」—— 那是绕开这条规则的入口。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const MainDouble := preload("res://tools/account_link_check_main_double.gd")
const AccountConfig := preload("res://scripts/account/AccountConfig.gd")
const CHECK_NAME := "account_link"

const MAIN_PATH := "res://scenes/main/Main.gd"
const MENU_PATH := "res://scenes/menu/MainMenu.gd"
const BOOTSTRAP_PATH := "res://scenes/bootstrap/Bootstrap.gd"

# 对局类界面。**每一个**都必须在 _clear() 之后标记自己。
const MATCH_SCREENS: PackedStringArray = [
	"_show_prep", "_show_battle", "_show_game_over", "_show_team3v3_lobby", "_show_selftest",
]

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_rule_and_exceptions()
	_check_timer()
	_check_sources()
	_h.finish(get_tree())


# --- 判据 ---------------------------------------------------------------------

func _check_rule_and_exceptions() -> void:
	var main = MainDouble.new()
	var saved_team: bool = NetworkService.team_active
	var saved_tutorial: bool = TutorialMode.active
	var saved_kicked: bool = RealtimeService.get("_kicked")

	NetworkService.team_active = false
	TutorialMode.active = false
	RealtimeService.set("_kicked", false)

	_h.expect(main._should_watch_account_link(), "menu_not_watched",
		"在主菜单、没在对局、没在教学、没被顶号 —— 这时掉线必须被盯着")

	main._in_match_flow = true
	_h.expect(not main._should_watch_account_link(), "match_flow_watched",
		"对局中也在盯掉线 —— 账号服务器一抖就会把玩家踢出正在打的对局")
	main._in_match_flow = false

	NetworkService.team_active = true
	_h.expect(not main._should_watch_account_link(), "team_room_watched",
		"在联机房间里也在盯 —— 战斗服务器有自己的重连，这里不该插手")
	NetworkService.team_active = false

	TutorialMode.active = true
	_h.expect(not main._should_watch_account_link(), "tutorial_watched",
		"教学中也在盯 —— 教学是本地流程，不该因为账号服务器掉线被打断")
	TutorialMode.active = false

	RealtimeService.set("_kicked", true)
	_h.expect(not main._should_watch_account_link(), "kicked_watched",
		"被顶号也在盯 —— 那条有自己的提示，而且绝不能自动重连（两台设备会无限互踢）")
	RealtimeService.set("_kicked", false)

	# 2：_clear() 必须复位对局标记。
	main._in_match_flow = true
	main._clear()
	_h.expect(not main._in_match_flow, "clear_keeps_match_flag",
		"_clear() 没把对局标记清掉 —— 打完一局回主菜单后，掉线将永远不会被送回启动页")

	NetworkService.team_active = saved_team
	TutorialMode.active = saved_tutorial
	RealtimeService.set("_kicked", saved_kicked)
	main.free()


# --- 计时 ---------------------------------------------------------------------

func _check_timer() -> void:
	var main = MainDouble.new()
	var saved_team: bool = NetworkService.team_active
	var saved_tutorial: bool = TutorialMode.active
	NetworkService.team_active = false
	TutorialMode.active = false

	# 门禁里实时连接没有启动，is_online() 恒为 false —— 正好是「掉线」的状态。
	_h.expect(not RealtimeService.is_online(), "harness_online",
		"门禁环境里实时连接居然是在线的，下面的计时断言不成立")

	var patience := AccountConfig.CONNECT_PATIENCE_SEC
	main._watch_account_link(patience * 0.5)
	_h.expect(main.return_calls == 0, "returned_too_early",
		"掉线才 %.1f 秒就送回启动页了（耐心值 %.1f 秒）—— 网络一抖就被踢" % [patience * 0.5, patience])

	main._watch_account_link(patience * 0.6)
	_h.expect(main.return_calls == 1, "never_returned",
		"掉线累计 %.1f 秒（超过耐心值 %.1f）仍没送回启动页" % [patience * 1.1, patience])

	# 对局中计时要归零，不能「攒着」—— 否则打完一局一回主菜单就立刻被踢。
	var fresh = MainDouble.new()
	fresh._watch_account_link(patience * 0.9)
	fresh._in_match_flow = true
	fresh._watch_account_link(60.0)
	fresh._in_match_flow = false
	fresh._watch_account_link(patience * 0.2)
	_h.expect(fresh.return_calls == 0, "offline_time_carried_over",
		"对局前攒下的掉线时间带到了对局后 —— 回主菜单那一刻会被立刻踢回启动页")

	NetworkService.team_active = saved_team
	TutorialMode.active = saved_tutorial
	main.free()
	fresh.free()


# --- 源码 ---------------------------------------------------------------------

func _check_sources() -> void:
	var main_src := FileAccess.get_file_as_string(MAIN_PATH).replace("\r\n", "\n")
	for fn in MATCH_SCREENS:
		var body := _function_body(main_src, str(fn))
		if not _h.expect(not body.is_empty(), "match_screen_missing",
				"Main.gd 里找不到 %s —— 改名了的话这里要跟着改" % fn):
			continue
		_h.expect(body.contains("_enter_match_flow()"), "match_screen_unmarked",
			"%s 没有调 _enter_match_flow() —— 这个界面上的玩家掉线会被踢出对局" % fn)

	var boot_src := FileAccess.get_file_as_string(BOOTSTRAP_PATH).replace("\r\n", "\n")
	_h.expect(boot_src.contains("ENTRY_CONNECT_PATIENCE_SEC := AccountConfig.CONNECT_PATIENCE_SEC"),
		"patience_forked",
		"启动页的耐心值不再引用 AccountConfig —— 同一条规则出现了两个数")

	var menu_src := FileAccess.get_file_as_string(MENU_PATH).replace("\r\n", "\n")
	var at := menu_src.find("_menu_text(\"离线自测\"")
	var gate := menu_src.rfind("if OS.is_debug_build():", at)
	_h.expect(at >= 0 and gate >= 0 and at - gate < 600, "offline_button_in_release",
		"「离线自测」不在 OS.is_debug_build() 之内 —— 发布包里的玩家能绕开「连不上就进不了游戏」")


# 取 `func name(` 到下一个顶格 `func ` 之间的文本。
func _function_body(src: String, fn_name: String) -> String:
	var start := src.find("\nfunc %s(" % fn_name)
	if start < 0:
		return ""
	var end := src.find("\nfunc ", start + 1)
	return src.substr(start, (end - start) if end > 0 else -1)
