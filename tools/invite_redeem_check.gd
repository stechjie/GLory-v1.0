extends Node

# 邀请码 / 兑换码客户端（scenes/menu/InviteRedeemPanel.gd + 资料页入口；2026-11-03 用户拍板）。
#
# 服务端的规则（上限、并发、发奖不拖垮结算、防爆破）在 backend/tests/test_invites_pg.py、
# test_redeem_pg.py。这里钉的是客户端这一侧**不报错的**失败：
#
#   1. 三个接口走 _request（带 X-Glory-Session 那条唯一路径），路径和方法对
#   2. 服务器的每一句新报错都有英文 —— 漏了的话英文玩家看到一行中文，界面不会报任何错
#   3. 面板按服务器给的状态显示：能填才有输入框；已填未达标 / 已发奖说清楚；读不到就不摆输入框
#   4. 失败保留输入（多半是抄错一个字）；成功后让邮箱马上刷新；提交中连点只发一次
#   5. 英文界面；资料页真的把面板放进了「资料设置」
#
# 全程不联网：面板注入假的 api，AccountManager 用替身截住 _request。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/invite_redeem_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Errors := preload("res://scripts/account/AccountErrorText.gd")

const CHECK_NAME := "invite_redeem"
const PANEL_PATH := "res://scenes/menu/InviteRedeemPanel.gd"
const PROFILE_PATH := "res://scenes/menu/ProfileScreen.gd"
const BACKEND_SOURCES := ["res://backend/app/invites.py", "res://backend/app/redeem.py"]

const STATUS_CAN_BIND := {"can_bind": true, "bound": false, "rewarded": false, "reward_level": 5,
	"invitee_diamond": 50, "inviter_diamond": 100}
const STATUS_BOUND := {"can_bind": false, "bound": true, "rewarded": false, "reward_level": 5,
	"invitee_diamond": 50, "inviter_diamond": 100}
const STATUS_REWARDED := {"can_bind": false, "bound": true, "rewarded": true, "reward_level": 5,
	"invitee_diamond": 50, "inviter_diamond": 100}


class AccountProbe extends "res://scripts/autoload/AccountManager.gd":
	var calls: Array = []

	func _request(method: int, path: String, payload: Variant = null, authed: bool = false,
			allow_refresh: bool = true) -> Dictionary:
		calls.append({"method": method, "path": path, "payload": payload, "authed": authed})
		return {"code": 200, "body": {}}


class FakeApi extends Node:
	signal release
	var status_reply: Dictionary = {}
	var bind_reply: Dictionary = {}
	var redeem_reply: Dictionary = {}
	var hold := false
	var calls: Array = []

	func fetch_invite() -> Dictionary:
		calls.append(["fetch"])
		return status_reply

	func bind_invite(code: String) -> Dictionary:
		calls.append(["bind", code])
		if hold:
			await release
		return bind_reply

	func redeem_code(code: String) -> Dictionary:
		calls.append(["redeem", code])
		if hold:
			await release
		return redeem_reply


var _h: CheckHarness
# 运行时 load，不 preload：面板编不过时 preload 会让本门禁自己也编不过，只剩超时（300 秒）。
var _panel_script: Script
var _mail_refreshes := 0
var _saved_locale := ""


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_saved_locale = TranslationServer.get_locale()
	TranslationServer.set_locale("zh")

	# 先确认面板脚本本身编得过。编不过时下面每一条都只是引擎红字、不算失败，
	# CHECK_RESULT 会照样 PASS（2026-11-03 真出过：辅助函数起名 _input，撞了 Control._input）。
	_panel_script = ResourceLoader.load(PANEL_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
	if not _h.expect(_panel_script != null and _panel_script.can_instantiate(), "panel_compiles",
			"InviteRedeemPanel.gd 编译失败（看日志里的 Parse Error）"):
		TranslationServer.set_locale(_saved_locale)
		_h.finish(get_tree())
		return

	await _case_account_wrappers()
	_case_server_messages_translated()
	await _case_status_states()
	await _case_bind_flow()
	await _case_redeem_flow()
	await _case_double_tap_sends_once()
	await _case_english()
	_case_profile_wiring()

	TranslationServer.set_locale(_saved_locale)
	_h.finish(get_tree())


# --- 小工具 -------------------------------------------------------------------

func _panel(status: Dictionary) -> Array:
	var api := FakeApi.new()
	api.status_reply = {"code": 200, "body": status} if not status.is_empty() else {"code": 0, "error": ""}
	add_child(api)
	var panel = _panel_script.new()
	panel.api = api
	panel.refresh_mail = func() -> void: _mail_refreshes += 1
	add_child(panel)
	await get_tree().process_frame
	return [panel, api]


func _drop(pair: Array) -> void:
	for node in pair:
		(node as Node).queue_free()


func _visible(control: Control) -> bool:
	return control.visible


# --- 1. 接口 ------------------------------------------------------------------

func _case_account_wrappers() -> void:
	var probe := AccountProbe.new()
	await probe.fetch_invite()
	await probe.bind_invite("  abcd2345 ")
	await probe.redeem_code(" glory-2026 ")
	var calls: Array = probe.calls
	_h.expect(calls.size() == 3, "wrapper_count", "三个封装应各发一次 _request，实际 %d 次" % calls.size())
	if calls.size() == 3:
		_h.expect(calls[0]["path"] == "/v1/me/invite" and calls[0]["method"] == HTTPClient.METHOD_GET,
			"fetch_path", "fetch_invite 应 GET /v1/me/invite，实际 %s" % str(calls[0]))
		_h.expect(calls[1]["path"] == "/v1/me/invite/bind" and calls[1]["method"] == HTTPClient.METHOD_POST
			and calls[1]["payload"] == {"code": "abcd2345"},
			"bind_path", "bind_invite 应 POST /v1/me/invite/bind 并去掉首尾空格，实际 %s" % str(calls[1]))
		_h.expect(calls[2]["path"] == "/v1/me/redeem" and calls[2]["method"] == HTTPClient.METHOD_POST
			and calls[2]["payload"] == {"code": "glory-2026"},
			"redeem_path", "redeem_code 应 POST /v1/me/redeem，实际 %s" % str(calls[2]))
		var all_authed := true
		for call in calls:
			all_authed = all_authed and bool(call["authed"])
		_h.expect(all_authed, "wrapper_authed", "三个接口都要带令牌（authed = true）")
	probe.free()


# --- 2. 报错的英文 --------------------------------------------------------------

func _case_server_messages_translated() -> void:
	var re := RegEx.new()
	# raise InviteRejected("invite_x", "中文") / RedeemRejected(...)，以及 RedeemLocked 的那句模板。
	re.compile("(?:InviteRejected|RedeemRejected)\\(\\s*\"[a-z_]+\",\\s*\"([^\"]+)\"|__init__\\(\"([^\"]+)\"")
	var messages: Array[String] = []
	for path: String in BACKEND_SOURCES:
		var source := FileAccess.get_file_as_string(path)
		_h.expect(not source.is_empty(), "backend_source", "读不到 %s" % path)
		for m in re.search_all(source):
			var text := m.get_string(1) if not m.get_string(1).is_empty() else m.get_string(2)
			if not messages.has(text):
				messages.append(text)
	_h.expect(messages.size() >= 14, "message_scan",
		"从服务端源码里只扫到 %d 句报错 —— 正则可能和代码写法对不上了" % messages.size())
	var cjk := RegEx.new()
	cjk.compile("[\\x{4e00}-\\x{9fff}]")
	for text in messages:
		var sample := text.replace("%d", "7")
		var english := Errors.localize(sample, "en")
		_h.expect(english != sample and cjk.search(english) == null, "missing_en",
			"服务器这句报错没有英文：%s（加到 scripts/account/AccountErrorText.gd）" % text)
		if text.contains("%d"):
			_h.expect(english.contains("7"), "template_number", "模板翻译丢了数字：%s → %s" % [sample, english])


# --- 3. 状态 ------------------------------------------------------------------

func _case_status_states() -> void:
	var pair := await _panel(STATUS_CAN_BIND)
	var panel = pair[0]
	_h.expect(_visible(panel._bind_row), "can_bind_row", "能填的时候要有填码输入框")
	_h.expect(not _visible(panel._bound_label), "can_bind_no_bound", "还没填，不该说「已填写」")
	var rule: String = panel._rule_label.text
	_h.expect(rule.contains("5") and rule.contains("100") and rule.contains("50"), "rule_numbers",
		"规则说明要用服务器给的数（5 级、100、50），实际「%s」" % rule)
	_h.expect(not rule.contains("/") and not rule.contains("已邀请"), "no_counts",
		"🔴 用户定了不显示邀请了几个 / 到账几个：%s" % rule)
	_drop(pair)

	pair = await _panel(STATUS_BOUND)
	panel = pair[0]
	_h.expect(not _visible(panel._bind_row), "bound_no_row", "已经填过了，输入框要收起来")
	_h.expect(_visible(panel._bound_label) and panel._bound_label.text.contains("5"), "bound_text",
		"已填未达标要说清楚「升到 5 级后发到邮箱」，实际「%s」" % panel._bound_label.text)
	_drop(pair)

	pair = await _panel(STATUS_REWARDED)
	panel = pair[0]
	_h.expect(panel._bound_label.text.contains("邮箱"), "rewarded_text",
		"发过奖要说奖励在邮箱，实际「%s」" % panel._bound_label.text)
	_drop(pair)

	pair = await _panel({})
	panel = pair[0]
	_h.expect(not _visible(panel._bind_row) and not _visible(panel._rule_label), "offline_hides",
		"读不到邀请状态时不该摆出一个点了必报错的输入框")
	_h.expect(_visible(panel._redeem_edit), "offline_redeem_stays", "读不到邀请状态不影响兑换码入口")
	panel.set_friend_code("ABCD2345")
	_h.expect(panel._code_label.text == "ABCD2345" and not panel._copy_btn.disabled, "friend_code_shown",
		"资料页给的好友码要显示出来、能复制")
	_drop(pair)


# --- 4. 提交 ------------------------------------------------------------------

func _case_bind_flow() -> void:
	var pair := await _panel(STATUS_CAN_BIND)
	var panel = pair[0]
	var api: FakeApi = pair[1]
	api.bind_reply = {"code": 409, "error": "不能填自己的邀请码"}
	panel._bind_edit.text = "abcd2345"
	await panel._on_bind()
	_h.expect(panel._message.text == "不能填自己的邀请码", "bind_error_shown", "填码失败要原样显示服务器的话")
	_h.expect(panel._bind_edit.text == "abcd2345", "bind_error_keeps_input", "失败要保留输入，方便改一个字再点")

	var before := _mail_refreshes
	api.bind_reply = {"code": 200, "body": STATUS_REWARDED}
	await panel._on_bind()
	_h.expect(api.calls.has(["bind", "abcd2345"]), "bind_sent", "填码要把输入框的内容发出去")
	_h.expect(panel._bind_edit.text.is_empty() and not _visible(panel._bind_row), "bind_success_collapses",
		"填成功后输入框清空并收起")
	_h.expect(_mail_refreshes == before + 1, "bind_rewarded_refreshes_mail",
		"填的时候已经够级、当场发了奖：邮箱要马上刷新")
	_drop(pair)


func _case_redeem_flow() -> void:
	var pair := await _panel(STATUS_BOUND)
	var panel = pair[0]
	var api: FakeApi = pair[1]
	await panel._on_redeem()
	_h.expect(not api.calls.has(["redeem", ""]) and api.calls.size() == 1, "redeem_empty_no_call",
		"空的兑换码不该发请求")

	api.redeem_reply = {"code": 400, "error": "兑换码无效，检查一下有没有抄错"}
	panel._redeem_edit.text = "GL0RY2026"
	await panel._on_redeem()
	_h.expect(panel._message.text.contains("兑换码无效") and panel._redeem_edit.text == "GL0RY2026",
		"redeem_error", "兑换失败要显示原因并保留输入")

	api.redeem_reply = {"code": 0, "error": ""}
	await panel._on_redeem()
	_h.expect(panel._message.text.contains("连不上"), "redeem_offline", "断网要说连不上，不是空白")

	var before := _mail_refreshes
	api.redeem_reply = {"code": 200, "body": {"mail_id": 7, "diamond": 100, "coin": 0, "items": []}}
	panel._redeem_edit.text = "GLORY2026"
	await panel._on_redeem()
	_h.expect(panel._redeem_edit.text.is_empty() and panel._message.text.contains("邮箱"), "redeem_success",
		"兑换成功：清空输入、告诉玩家去邮箱，实际「%s」" % panel._message.text)
	_h.expect(_mail_refreshes == before + 1, "redeem_refreshes_mail", "兑换成功后邮箱要马上刷新")
	_drop(pair)


func _case_double_tap_sends_once() -> void:
	var pair := await _panel(STATUS_BOUND)
	var panel = pair[0]
	var api: FakeApi = pair[1]
	api.hold = true
	api.redeem_reply = {"code": 200, "body": {}}
	panel._redeem_edit.text = "GLORY2026"
	panel._on_redeem()
	panel._on_redeem()
	panel._redeem_btn.pressed.emit()
	var sent := 0
	for call in api.calls:
		if call[0] == "redeem":
			sent += 1
	_h.expect(sent == 1, "double_tap", "提交中再点只能发一次，实际 %d 次" % sent)
	_h.expect(panel._redeem_btn.disabled, "busy_disables", "提交中按钮要变灰")
	api.release.emit()
	await get_tree().process_frame
	_h.expect(not panel._redeem_btn.disabled, "busy_released", "提交完按钮要恢复")
	_drop(pair)


# --- 5. 英文与入口 ----------------------------------------------------------------

func _case_english() -> void:
	TranslationServer.set_locale("en")
	var pair := await _panel(STATUS_CAN_BIND)
	var panel = pair[0]
	var cjk := RegEx.new()
	cjk.compile("[\\x{4e00}-\\x{9fff}]")
	var texts: Array[String] = [panel._rule_label.text, panel._bind_edit.placeholder_text,
		panel._redeem_edit.placeholder_text, panel._copy_btn.text, panel._redeem_btn.text]
	for text in texts:
		_h.expect(cjk.search(text) == null, "english_ui", "英文界面里还有中文：%s" % text)
	_h.expect(panel._rule_label.text.contains("level 5"), "english_rule", "英文规则说明：%s" % panel._rule_label.text)
	_drop(pair)
	TranslationServer.set_locale("zh")


func _case_profile_wiring() -> void:
	var profile := FileAccess.get_file_as_string(PROFILE_PATH)
	_h.expect(profile.contains("preload(\"res://scenes/menu/InviteRedeemPanel.gd\")"), "profile_preload",
		"资料页没有引入 InviteRedeemPanel")
	_h.expect(profile.contains("[_invite_panel, _danger_zone()]"), "profile_settings_column",
		"面板要放在「资料设置」里、注销上面")
	_h.expect(profile.contains("_invite_panel.set_friend_code(_field(\"friend_code\"))"), "profile_code",
		"资料页拿到资料后要把好友码交给面板")
	var panel_source := FileAccess.get_file_as_string(PANEL_PATH)
	_h.expect(panel_source.contains("GloryActionButton.tscn"), "action_button",
		"面板的按钮要实例化 GloryActionButton.tscn（procedural_ui_ratchet：新文件基线是 0）")
