extends Node

# 系统邮件客户端（docs/邮件系统设计.md）：MailService、邮件界面、主菜单红点。
#
# 服务端的规则（领取只算一次、钻石进赠送列、附件有问题整封不给看）在
# backend/tests/test_mail.py。这里钉的是客户端这一侧**不报错的**失败：
#
#   1. 红点：没读的、或者附件没领的都要亮；都处理完了要灭
#   2. 存不上就是没做：没登录 / 网络不通时领取、删除都不能在本机假装成功
#   3. 领到之后本机那份要跟上（不然界面上「领取」按钮还在，玩家会再点）
#   4. 界面：领取 / 删除按钮只在该出现的时候出现；已拥有的附件要明说「跳过」
#   5. 推送类型与服务端一致；主菜单入口真的接上了；登出清空
#
# 全程不联网、不写 user://：请求在「没登录」时由 AccountManager 在本机直接判 401。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/mail_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const MailScreenScript := preload("res://scenes/menu/MailScreen.gd")
const MainMenuScript := preload("res://scenes/menu/MainMenu.gd")
const Currency := preload("res://scripts/account/Currency.gd")

const CHECK_NAME := "mail"
const BACKEND_MAIL := "res://backend/app/mail.py"
const DAY := 86400


var _h: CheckHarness
var _saved_login := {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_force_logged_out()
	MailService.reset()

	_case_push_type_matches_backend()
	_case_attention_rules()
	_case_apply_list_sanitizes()
	await _case_mark_read_is_local_first()
	_case_claim_result_updates_snapshot()
	await _case_failures_change_nothing()
	_case_currency_helper()
	await _case_screen_empty_and_list()
	await _case_screen_buttons_follow_state()
	await _case_screen_claim_failure()
	_case_claim_messages()
	await _case_main_menu_dot()
	_case_wiring_sources()

	MailService.reset()
	_restore_login()
	_h.finish(get_tree())


# --- 小工具 -------------------------------------------------------------------

# 没登录时 AccountManager 在本机就回 401，不发请求。
func _force_logged_out() -> void:
	_saved_login = {
		"token": AccountManager._access_token,
		"expires": AccountManager._token_expires_at,
		"state": AccountManager.state,
	}
	AccountManager._access_token = ""
	AccountManager._token_expires_at = 0.0


func _restore_login() -> void:
	AccountManager._access_token = str(_saved_login.get("token", ""))
	AccountManager._token_expires_at = float(_saved_login.get("expires", 0.0))
	AccountManager.state = int(_saved_login.get("state", AccountManager.State.IDLE))


func _mail(id: int, overrides: Dictionary = {}) -> Dictionary:
	var out := {
		"id": id,
		"title_zh": "补偿 %d" % id, "body_zh": "正文 %d" % id, "title_en": "", "body_en": "",
		"diamond": 0, "coin": 0, "items": [],
		"age_sec": 2 * DAY + 5, "expires_in_sec": 27 * DAY + 5,
		"read": false, "claimed": false,
	}
	out.merge(overrides, true)
	return out


func _pet_item() -> Dictionary:
	return {"id": "pet_cat", "kind": "pet", "name": "小猫", "name_en": "Cat"}


func _open_screen() -> MailScreenScript:
	var packed := load("res://scenes/menu/MailScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "screen_load_failed", "MailScreen.tscn 加载不出来"):
		return null
	var screen := packed.instantiate() as MailScreenScript
	if not _h.expect(screen != null, "screen_instantiate_failed", "MailScreen 实例化失败（脚本编译不过？）"):
		return null
	add_child(screen)
	return screen


func _settle(frames: int = 2) -> void:
	for _i in frames:
		await get_tree().process_frame


# --- 1. 契约 ------------------------------------------------------------------

func _case_push_type_matches_backend() -> void:
	var source := FileAccess.get_file_as_string(BACKEND_MAIL)
	if not _h.expect(not source.is_empty(), "backend_unreadable", "读不到 %s" % BACKEND_MAIL):
		return
	var re := RegEx.create_from_string("PUSH_TYPE = \"([a-z_]+)\"")
	var found := re.search(source)
	_h.expect(found != null and found.get_string(1) == MailService.PUSH_TYPE, "push_type_mismatch",
		"服务端推送类型与 MailService.PUSH_TYPE（%s）对不上 —— 红点永远不会被推亮" % MailService.PUSH_TYPE)


# --- 2. 红点与规则 --------------------------------------------------------------

func _case_attention_rules() -> void:
	var cases := [
		# [说明, 邮件, 该不该亮, 能不能领, 能不能删]
		["未读、无附件", _mail(1), true, false, false],
		["已读、无附件", _mail(1, {"read": true}), false, false, true],
		["已读、附件没领", _mail(1, {"read": true, "diamond": 5}), true, true, false],
		["已读、附件已领", _mail(1, {"read": true, "diamond": 5, "claimed": true}), false, false, true],
		["未读、只有物品", _mail(1, {"items": [_pet_item()]}), true, true, false],
	]
	for row in cases:
		MailService.apply_list([row[1]])
		_h.expect(MailService.needs_attention() == bool(row[2]), "attention_" + str(row[0]).uri_encode(),
			"%s：红点应为 %s" % [row[0], row[2]])
		_h.expect(MailService.is_claimable(row[1]) == bool(row[3]), "claimable_rule",
			"%s：能不能领应为 %s" % [row[0], row[3]])
		_h.expect(MailService.is_deletable(row[1]) == bool(row[4]), "deletable_rule",
			"%s：能不能删应为 %s（与服务端 mail.delete 同一条）" % [row[0], row[4]])
	MailService.apply_list([])
	_h.expect(not MailService.needs_attention(), "empty_attention", "空邮箱亮了红点")


func _case_apply_list_sanitizes() -> void:
	MailService.apply_list([_mail(3), "垃圾", {"id": 0}, {"title_zh": "没编号"}, _mail(2)])
	_h.expect(MailService.mails().size() == 2 and MailService.is_loaded(), "apply_list_filter",
		"列表应当只收有编号的两封，实际 %d" % MailService.mails().size())
	MailService.apply_list("不是数组")
	_h.expect(MailService.mails().is_empty(), "apply_list_non_array", "不是数组的答复应当当作空邮箱")


# 点开那一刻红点就该灭，不等网络；网络失败也不回滚（下次拉列表时服务端的真相会盖回来）。
func _case_mark_read_is_local_first() -> void:
	MailService.apply_list([_mail(5)])
	var fired := [0]
	var on_changed := func() -> void: fired[0] += 1
	MailService.changed.connect(on_changed)
	await MailService.mark_read(5)
	MailService.changed.disconnect(on_changed)
	_h.expect(bool(MailService.find(5).get("read", false)), "mark_read_not_local",
		"点开之后本机仍是未读 —— 红点要等网络才灭")
	_h.expect(fired[0] >= 1, "mark_read_no_signal", "标记已读没有通知界面")
	_h.expect(not MailService.needs_attention(), "mark_read_dot_stays", "已读、无附件，红点却还亮着")


func _case_claim_result_updates_snapshot() -> void:
	MailService.apply_list([_mail(7, {"diamond": 100}), _mail(8, {"coin": 5}), _mail(9)])
	var outcome := MailService._after_claim({"code": 200, "body": {
		"mail_ids": [7, 8], "diamond": 100, "coin": 5,
		"granted": [], "skipped": [], "wallet": {"diamond": 150, "coin": 5}, "replayed": false,
	}})
	_h.expect(bool(outcome.get("ok", false)) and int(outcome.get("diamond", 0)) == 100
			and int(outcome.get("coin", 0)) == 5, "claim_outcome", "领取结果没原样带回：%s" % str(outcome))
	var both := bool(MailService.find(7).get("claimed", false)) and bool(MailService.find(8).get("claimed", false))
	_h.expect(both, "claim_not_marked", "领到之后本机仍显示没领 —— 「领取」按钮会还在")
	_h.expect(bool(MailService.find(7).get("read", false)), "claim_not_read", "领过的邮件应当同时算已读")
	_h.expect(not bool(MailService.find(9).get("claimed", false)), "claim_marked_other",
		"没在回执里的邮件也被标成已领了")
	_h.expect(MailService.claimable_count() == 0, "claimable_after_claim", "全领完了还显示有可领的")

	var failed := MailService._after_claim({"code": 409, "error": "这封邮件没有附件"})
	_h.expect(not bool(failed.get("ok", true)) and str(failed.get("error", "")) == "这封邮件没有附件",
		"claim_error_passthrough", "服务端给的原因没有原样带给界面：%s" % str(failed))


func _case_failures_change_nothing() -> void:
	MailService.apply_list([_mail(11, {"diamond": 50, "read": true}), _mail(12, {"read": true})])
	var claimed: Dictionary = await MailService.claim(11)
	_h.expect(not bool(claimed.get("ok", true)), "claim_offline_ok", "没登录也报了领取成功")
	_h.expect(not bool(MailService.find(11).get("claimed", false)), "claim_offline_marked",
		"领取没成功，本机却标成已领 —— 玩家以为到手了")
	var all: Dictionary = await MailService.claim_all()
	_h.expect(not bool(all.get("ok", true)) and MailService.claimable_count() == 1, "claim_all_offline",
		"一键领取没成功却改了本机：%s" % str(all))
	var deleted: Dictionary = await MailService.delete_mail(12)
	_h.expect(not bool(deleted.get("ok", true)) and not MailService.find(12).is_empty(), "delete_offline",
		"删除没成功，邮件却从本机消失了")
	var count: int = await MailService.delete_read()
	_h.expect(count == -1 and MailService.mails().size() == 2, "delete_read_offline",
		"删除已读没成功却删了本机的（返回 %d、剩 %d 封）" % [count, MailService.mails().size()])
	MailService.reset()
	_h.expect(MailService.mails().is_empty() and not MailService.is_loaded(), "reset",
		"登出之后邮箱快照没清掉")


func _case_currency_helper() -> void:
	var pairs := [[0, "0"], [999, "999"], [1000, "1,000"], [89450, "89,450"], [1234567, "1,234,567"], [-1500, "-1,500"]]
	for pair in pairs:
		_h.expect(Currency.comma(int(pair[0])) == str(pair[1]), "comma",
			"千分位 %d -> %s，应为 %s" % [pair[0], Currency.comma(int(pair[0])), pair[1]])
	var diamond := Currency.icon("diamond") as AtlasTexture
	var gold := Currency.icon("coin") as AtlasTexture
	_h.expect(diamond != null and diamond.region == Currency.DIAMOND_ICON_REGION
			and gold != null and gold.region == Currency.GOLD_ICON_REGION, "icon_regions",
		"货币图标没按裁切区域裁（会显示成整条货币条被压扁的样子）")
	_h.expect(Currency.icon("diamond") == diamond, "icon_cached", "货币图标每次都新建一份")


# --- 3. 界面 ------------------------------------------------------------------

func _case_screen_empty_and_list() -> void:
	MailService.apply_list([])
	var screen := _open_screen()
	if screen == null:
		return
	await _settle()
	_h.expect(screen._empty_label.visible and screen._empty_label.text.contains("空"), "empty_state",
		"空邮箱应当显示「邮箱是空的」，实际 %s" % screen._empty_label.text)
	_h.expect(not screen._claim_button.visible and not screen._delete_button.visible, "empty_buttons",
		"空邮箱还露着领取 / 删除按钮")
	_h.expect(screen._claim_all_button.disabled and screen._delete_read_button.disabled, "empty_batch_buttons",
		"空邮箱的一键领取 / 删除已读应当点不了")

	MailService.apply_list([
		_mail(21, {"diamond": 300, "items": [_pet_item()]}),
		_mail(20, {"read": true}),
	])
	await _settle()
	_h.expect(screen._list_box.get_child_count() == 2, "list_rows",
		"两封邮件应当两行，实际 %d" % screen._list_box.get_child_count())
	_h.expect(screen.selected_id() == 21, "first_selected", "默认应当选中最新那封")
	_h.expect(screen._title_label.text == "补偿 21", "detail_title", "详情标题不对：%s" % screen._title_label.text)
	_h.expect(screen._meta_label.text == "2 天前 · 还剩 27 天", "meta_text",
		"时间行应为「2 天前 · 还剩 27 天」，实际 %s" % screen._meta_label.text)
	_h.expect(bool(MailService.find(21).get("read", false)), "open_marks_read", "显示出来的邮件没算读过")
	# 附件：钻石一格 + 宠物一格
	_h.expect(screen._attach_box.get_child_count() == 2 and screen._attach_title.visible, "attachment_chips",
		"应当显示两样附件，实际 %d" % screen._attach_box.get_child_count())
	var first_row := screen._list_box.get_child(0) as Button
	var dot := first_row.get_node_or_null("Dot") as Label if first_row != null else null
	_h.expect(dot != null and dot.visible, "row_dot_unclaimed", "附件没领的那一行没有红点")
	_h.expect(first_row != null and first_row.text.contains("附件"), "row_marks_gift",
		"有没领附件的那一行应当标出「附件」：%s" % (first_row.text if first_row != null else "?"))

	screen.select(20)
	await _settle()
	var second_row := screen._list_box.get_child(1) as Button
	var dot2 := second_row.get_node_or_null("Dot") as Label if second_row != null else null
	_h.expect(dot2 != null and not dot2.visible, "row_dot_read", "已读、无附件的那一行还亮着红点")
	_h.expect(not screen._attach_title.visible and screen._attach_box.get_child_count() == 0, "no_attachments",
		"没有附件的邮件还显示着附件区")
	screen.queue_free()
	await _settle()


func _case_screen_buttons_follow_state() -> void:
	MailService.apply_list([
		_mail(31, {"diamond": 10}),
		_mail(30, {"read": true, "coin": 3, "claimed": true}),
	])
	var screen := _open_screen()
	if screen == null:
		return
	await _settle()
	_h.expect(screen._claim_button.visible and not screen._delete_button.visible, "unclaimed_buttons",
		"附件没领：应当只有「领取」、没有「删除」")
	_h.expect(not screen._claim_all_button.disabled, "claim_all_enabled", "有可领的附件，一键领取却点不了")
	screen.select(30)
	await _settle()
	_h.expect(not screen._claim_button.visible and screen._delete_button.visible, "claimed_buttons",
		"附件已领：应当只有「删除」、没有「领取」")
	_h.expect(screen._attach_title.text.contains("已领取"), "claimed_title",
		"已领的附件区应当写明「已领取」：%s" % screen._attach_title.text)
	_h.expect(not screen._delete_read_button.disabled, "delete_read_enabled", "有已读可删的，删除已读却点不了")
	screen.queue_free()
	await _settle()


func _case_screen_claim_failure() -> void:
	MailService.apply_list([_mail(41, {"diamond": 10, "read": true})])
	var screen := _open_screen()
	if screen == null:
		return
	await _settle()
	screen._claim_button.pressed.emit()
	await _settle(3)
	_h.expect(screen._notice_label.visible and screen._notice_bad, "claim_failure_silent",
		"领取失败（没登录）没有任何提示")
	_h.expect(not screen._busy and not screen._claim_button.disabled, "claim_failure_stuck",
		"领取失败后按钮卡在忙碌里，玩家没法重试")
	_h.expect(screen._claim_button.visible and not bool(MailService.find(41).get("claimed", false)),
		"claim_failure_marked", "领取失败，界面却当成已领了")
	screen.queue_free()
	await _settle()


func _case_claim_messages() -> void:
	# 到账音效不在这里断言：它要本机导入过的音频资源和发声池，新音频没导入时
	# 这条会跟着一起红（与邮件无关）。音效的登记与调用点归 audio_sfx_check。
	var screen := MailScreenScript.new()
	screen._show_claim_outcome({"ok": true, "diamond": 1500, "coin": 0,
		"granted": [], "skipped": [_pet_item()], "replayed": false}, false)
	_h.expect(screen._notice.contains("钻石 +1,500") and screen._notice.contains("已经拥有，跳过：宠物：小猫"),
		"claim_message_skipped", "已拥有被跳过要明说，实际：%s" % screen._notice)
	screen._show_claim_outcome({"ok": true, "diamond": 0, "coin": 0,
		"granted": [], "skipped": [], "replayed": false}, true)
	_h.expect(screen._notice.contains("没有可领取"), "claim_all_nothing",
		"一键领取什么都没领到时应当说「没有可领取的附件」：%s" % screen._notice)
	screen._show_claim_outcome({"ok": true, "replayed": true}, false)
	_h.expect(screen._notice.contains("已经领过"), "claim_replayed_message",
		"另一台手机已经领过时应当说清楚：%s" % screen._notice)
	_h.expect(screen.item_text({"kind": "avatar_frame", "name": "金框"}) == "头像框：金框", "item_text",
		"附件名格式不对：%s" % screen.item_text({"kind": "avatar_frame", "name": "金框"}))
	_h.expect(screen.meta_text({"age_sec": 120, "expires_in_sec": 3600}) == "刚刚 · 今天过期", "meta_text_short",
		"时间行格式不对：%s" % screen.meta_text({"age_sec": 120, "expires_in_sec": 3600}))
	screen.free()


# --- 4. 主菜单与接线 ------------------------------------------------------------

func _case_main_menu_dot() -> void:
	MailService.apply_list([])
	var packed := load("res://scenes/menu/MainMenu.tscn") as PackedScene
	if not _h.expect(packed != null, "menu_load_failed", "MainMenu.tscn 加载不出来"):
		return
	var menu := packed.instantiate() as MainMenuScript
	if not _h.expect(menu != null, "menu_instantiate_failed", "MainMenu 实例化失败"):
		return
	add_child(menu)
	await _settle()
	_h.expect(menu._mail_dot != null and not menu._mail_dot.visible, "menu_dot_idle", "空邮箱时主菜单邮件亮了红点")
	MailService.apply_list([_mail(51)])
	await _settle()
	_h.expect(menu._mail_dot.visible, "menu_dot_new", "来了一封没读的邮件，主菜单邮件没亮红点")
	await MailService.mark_read(51)
	await _settle()
	_h.expect(not menu._mail_dot.visible, "menu_dot_cleared", "读完了，主菜单邮件红点还亮着")
	var fired := [0]
	menu.mail_requested.connect(func() -> void: fired[0] += 1)
	menu._emit_mail()
	_h.expect(fired[0] == 1, "menu_mail_signal", "点主菜单的邮件没有发出 mail_requested")
	menu.queue_free()
	await _settle()
	MailService.apply_list([])


func _case_wiring_sources() -> void:
	var main_src := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	_h.expect(main_src.contains("_menu.mail_requested.connect(_show_mail_screen)"), "main_route_missing",
		"Main 没接主菜单的邮件入口 —— 点了没反应")
	_h.expect(main_src.contains("MailService.reset()"), "main_logout_reset",
		"登出时没清邮箱 —— 换号后会看到上一个号的邮件")
	_h.expect(main_src.contains("MailService.refresh()"), "main_menu_refresh", "回主菜单时没刷新邮箱，红点不会自己亮")
	var menu_src := FileAccess.get_file_as_string("res://scenes/menu/MainMenu.gd")
	_h.expect(menu_src.contains("_add_hit(Vector2(1450, 25), Vector2(100, 100), _emit_mail"), "menu_hit_missing",
		"主菜单的邮件图标还是「敬请期待」")
	# 千分位与货币图标只许有一份（Currency.gd），见那边文件头。
	for path in ["res://scenes/menu/MainMenu.gd", "res://scenes/menu/ShopScreen.gd", "res://scenes/menu/MailScreen.gd"]:
		var src := FileAccess.get_file_as_string(path)
		_h.expect(not src.contains("func _comma(") and not src.contains("ICON_REGION :="), "currency_duplicated",
			"%s 又自己写了一份千分位 / 图标裁切，改格式或换图时会漏" % path)
