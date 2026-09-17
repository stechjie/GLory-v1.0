extends Node

# 朋友申请红点 / 提示音门禁（9.17 第四轮反馈）。
#
# ## 要证明的那句话
#
# 「有人申请加你好友」时：①「朋友」按键亮红点；② 响一声提示音。
#
# ## 这次的真实故障
#
# 两条反馈（音效不响 + 没红点）**是同一个根因**：`MainMenu._refresh_friend_requests()`
# 连同 `_friends_dot` 都写好了，但 `_ready()` 里**漏了那一次调用** ——
# 整个函数从没被执行过，红点永远是 `_build()` 里的初值 false，提示音一次都没响。
# 镜像 `GLory-codex` 上这段是「整块不存在」（本批新加），不是「改坏了」。
#
# 所以本门禁最要紧的一条不是「逻辑对不对」，而是「**它在 _ready() 里被调了没有**」。
# 判据是**数一次 add_child 之后真正发生的取数次数**（真跑 `_ready()`）——
# 而不是在源码里找那行字符串：后者会被注释里的同名文本蒙对。
#
# ## 为什么用 Probe 而不是直接实例化 MainMenu.tscn
#
# `MainMenu._ready()` 里有钱包 / 资料 / 音乐这些要碰网络与常驻服务的调用，
# 无头下拿不到真实答复。它们与「朋友申请」无关，逐个打桩；
# `_fetch_friend_requests()` 是为此留的唯一一个缝
# （同 `ProfileScreen._send_friend_request` 的先例：`friends08_check` 就靠它打桩）。
# `_refresh_friend_requests()` 与 `_ready()` 本身都走真实现。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const MenuScript := preload("res://scenes/menu/MainMenu.gd")

const CHECK_NAME := "friend_request_alert"

# 两条互不相同的申请。用不同 key 是因为「已提醒过」的记账是 static 的 ——
# 同一个 key 再跑一次本来就不该响，那会把「去重」和「没响」混成一件事。
const FRESH := {"friend_code": "AAAAAAAA", "created_at": "2026-09-17T00:00:00Z"}
const SEEN := {"friend_code": "BBBBBBBB", "created_at": "2026-09-17T00:01:00Z"}

class MenuProbe:
	extends "res://scenes/menu/MainMenu.gd"
	var fetch_calls := 0
	var fetch_response := {"code": 200, "body": {"incoming": []}}
	# 唯一的取数缝：真实现转调 AccountManager.fetch_friend_requests()。
	# 带一帧 await 是为了与被替换掉的那个协程同形（await 的必须是协程）。
	func _fetch_friend_requests() -> Dictionary:
		fetch_calls += 1
		await get_tree().process_frame
		return fetch_response
	# 下面几条都要碰网络或常驻服务，与朋友申请无关，逐个打桩。
	func _start_menu_music() -> void:
		pass
	func _refresh_saved_match() -> void:
		pass
	func _refresh_wallet() -> void:
		pass
	func _ensure_profile_loaded() -> void:
		pass
	func _refresh_profile_plate() -> void:
		pass

var _h: CheckHarness
var _master_mute_before := false
var _seen_before: Dictionary = {}
var _state_before := 0
var _player_before := ""


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)

	_state_before = AccountManager.state
	_player_before = AccountManager.player_id
	_seen_before = AccountManager.friend_request_seen.duplicate(true)
	AccountManager.friend_request_seen.clear()
	_set_logged_in()

	var master := AudioServer.get_bus_index("Master")
	_master_mute_before = AudioServer.is_bus_mute(master) if master >= 0 else false
	PlayerProfile.set_presentation_toggle("ui_sound", true)
	if master >= 0:
		AudioServer.set_bus_mute(master, false)

	SfxService.install()
	await get_tree().process_frame
	await get_tree().process_frame
	if not _h.expect(SfxService.voices_ready(), "voice_pool_not_in_tree",
			"8 个播放器还没全进树 —— 「没响」的断言在这种实现上恒真"):
		_bail()
		return
	if not _h.expect(Presentation.ui_sound_allowed(), "ui_sound_precondition_failed",
			"开关开着、Master 没静音，ui_sound_allowed() 却是 false —— 后面的断言无从谈起"):
		_bail()
		return

	await _case_ready_pulls_requests()
	await _case_poll_keeps_refreshing()
	await _case_seen_stays_quiet()
	await _case_fetch_failure_keeps_dot()
	await _case_logged_out_no_fetch()
	await _case_pure_helpers()

	_restore()
	SfxService.shutdown()
	_h.finish(get_tree())


func _bail() -> void:
	_restore()
	SfxService.shutdown()
	_h.finish(get_tree())


# 主回归面：真跑 _ready()，证明它**确实拉了一次**朋友申请，并据此点亮红点、响一声。
func _case_ready_pulls_requests() -> void:
	var menu := MenuProbe.new()
	menu.fetch_response = {"code": 200, "body": {"incoming": [FRESH]}}
	SfxService.reset_counters_for_check()
	add_child(menu)          # 真 _ready() 在这一行跑
	await _settle(3)
	_h.expect(menu.fetch_calls == 1, "ready_did_not_refresh",
		"主菜单 _ready() 没有拉朋友申请（红点与提示音都不会有；这一行曾漏掉）")
	_h.expect(menu._friends_dot != null and is_instance_valid(menu._friends_dot),
		"friends_dot_missing", "「朋友」按键上找不到红点节点")
	_h.expect(menu._friends_dot.visible, "friends_dot_hidden",
		"有未读申请时「朋友」按键的红点没亮")
	var played := SfxService.play_count(SfxService.CUE_CHAT_ALERT)
	_h.expect(played == 1, "alert_not_played",
		"收到新申请没响提示音（播了 %d 次）" % played)

	# 同一份申请再拉一次不该再响（节流之外还按申请键去重）。
	SfxService.reset_counters_for_check()
	await menu._refresh_friend_requests()
	await _settle(2)
	_h.expect(SfxService.play_count(SfxService.CUE_CHAT_ALERT) == 0,
		"same_request_replayed", "同一份申请重新拉取又响了 %d 声"
			% SfxService.play_count(SfxService.CUE_CHAT_ALERT))
	menu.free()


# 停在客厅不动时也要收得到。朋友申请**没有实时推送**（socket 只推私聊与公告），
# 轮询是唯一的近实时手段；没有它的话，「已经停在大厅时收到的申请」要等下一次
# 进出页面才会亮 —— 而大厅恰恰是停留最久的页面。
func _case_poll_keeps_refreshing() -> void:
	AccountManager.friend_request_seen.clear()
	var menu := MenuProbe.new()
	menu.fetch_response = {"code": 200, "body": {"incoming": []}}
	add_child(menu)
	await _settle(3)
	if not _h.expect(menu._friend_request_poll != null and is_instance_valid(menu._friend_request_poll),
			"poll_timer_missing", "「朋友」红点没有轮询定时器 —— 停在大厅不动时收不到新申请"):
		menu.free()
		return
	if not _h.expect(is_equal_approx(menu._friend_request_poll.wait_time, MenuScript.FRIEND_REQUEST_POLL_SEC),
			"poll_interval_wrong",
			"轮询间隔是 %s 秒，与常量 %s 不一致"
				% [menu._friend_request_poll.wait_time, MenuScript.FRIEND_REQUEST_POLL_SEC]):
		menu.free()
		return
	# 真实场景里是 Timer 自己发，这里直接发同一个信号，等价于「到点了」。
	var before := menu.fetch_calls
	menu._friend_request_poll.timeout.emit()
	await _settle(3)
	_h.expect(menu.fetch_calls == before + 1, "poll_did_not_repeat",
		"轮询到点后没有再拉一次（%d -> %d）" % [before, menu.fetch_calls])
	menu.free()


# 已经在朋友界面里看过的申请：不亮红点、也不再响。
func _case_seen_stays_quiet() -> void:
	AccountManager.mark_friend_requests_seen([SEEN])
	var menu := MenuProbe.new()
	menu.fetch_response = {"code": 200, "body": {"incoming": [SEEN]}}
	SfxService.reset_counters_for_check()
	add_child(menu)
	await _settle(3)
	_h.expect(menu.fetch_calls == 1, "seen_case_not_refreshed",
		"已读用例里 _ready() 没有拉申请（拉了 %d 次）" % menu.fetch_calls)
	_h.expect(not menu._friends_dot.visible, "seen_dot_still_on",
		"已经看过的申请，红点还在亮")
	_h.expect(SfxService.play_count(SfxService.CUE_CHAT_ALERT) == 0,
		"seen_request_played", "已经看过的申请又响了一声")
	menu.free()


# 拉不到时**保持现状**：宁可留着上一次的红点，也不要让网络抖一下把提示抹掉。
func _case_fetch_failure_keeps_dot() -> void:
	AccountManager.friend_request_seen.clear()
	var menu := MenuProbe.new()
	menu.fetch_response = {"code": 200, "body": {"incoming": [FRESH]}}
	add_child(menu)
	await _settle(3)
	if not _h.expect(menu._friends_dot.visible, "fixture_dot_not_on",
			"夹具没能把红点点亮，后面「失败时保持」的断言就无从谈起"):
		menu.free()
		return
	menu.fetch_response = {"code": 0, "error": "连不上账号服务器"}
	SfxService.reset_counters_for_check()
	await menu._refresh_friend_requests()
	await _settle(2)
	_h.expect(menu._friends_dot.visible, "dot_cleared_on_failure",
		"拉取失败时红点被抹掉了 —— 网络抖一下就把「有人申请加你」弄丢了")
	_h.expect(SfxService.play_count(SfxService.CUE_CHAT_ALERT) == 0,
		"failure_played", "拉取失败时响了提示音")
	menu.free()
	AccountManager.friend_request_seen.clear()


func _case_logged_out_no_fetch() -> void:
	AccountManager.state = AccountManager.State.IDLE
	AccountManager.player_id = ""
	var menu := MenuProbe.new()
	menu.fetch_response = {"code": 200, "body": {"incoming": [FRESH]}}
	add_child(menu)
	await _settle(3)
	_h.expect(menu.fetch_calls == 0, "logged_out_still_fetched",
		"没登录也去拉了朋友申请（%d 次）" % menu.fetch_calls)
	_h.expect(not menu._friends_dot.visible, "logged_out_dot_on",
		"没登录时红点却是亮的")
	menu.free()
	_set_logged_in()


func _case_pure_helpers() -> void:
	var key := AccountManager.friend_request_key(FRESH)
	_h.expect(key.begins_with(AccountManager.player_id + ":"), "key_without_player",
		"申请键没带 player_id —— 换账号会串（%s）" % key)
	_h.expect(AccountManager.has_unread_friend_requests([FRESH]), "unread_not_detected",
		"未读申请没被判成未读")
	AccountManager.mark_friend_requests_seen([FRESH])
	_h.expect(not AccountManager.has_unread_friend_requests([FRESH]), "seen_not_remembered",
		"标为已读之后仍被判成未读")
	# 同一个人重新发的新申请要重新提醒（created_at 变了就是新的）。
	var again := {"friend_code": FRESH["friend_code"], "created_at": "2026-09-17T09:00:00Z"}
	_h.expect(AccountManager.friend_request_key(again) != key, "resend_same_key",
		"同一个人重新发送的申请与旧的撞键 —— 会被去重吞掉")
	_h.expect(AccountManager.has_unread_friend_requests([again]), "resend_not_unread",
		"重新发送的申请没被判成未读")
	AccountManager.friend_request_seen.clear()


# --- 夹具 ---------------------------------------------------------------------

func _set_logged_in() -> void:
	AccountManager.state = AccountManager.State.LOGGED_IN
	AccountManager.player_id = "GATE_PLAYER"


func _restore() -> void:
	AccountManager.state = _state_before
	AccountManager.player_id = _player_before
	AccountManager.friend_request_seen = _seen_before
	if _master_mute_before:
		var master := AudioServer.get_bus_index("Master")
		if master >= 0:
			AudioServer.set_bus_mute(master, true)


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame
