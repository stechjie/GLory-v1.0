extends Node

# 10.06 反馈（10.06bug提交及修复.docx，8 条）里**能用 headless 驱动的那几条**的行为判据。
# 逐条对应：
#
#   第 2 条  房间「朋友列表」只显示昵称，不再挂着 `#好友码`
#   第 3 条  商店刷新键对齐右侧竖列；商店打开时语音三键整块隐藏
#   第 5 条  结算面板上、下各一排同样的按钮；「超过一屏」那句滚动提示已删
#   第 6 条  房间顶部文案只保留「等待结算中的玩家返回」
#   第 7 条  商店棋子落点仍在商店里时不触发购买
#   第 8 条  房间右上角有「静音 / 已静音」键，语义与备战期那颗同源
#
# **没进这个门禁的两条**（headless 拿不到像素真值 / 真光标，另有出口）：
#   第 1 条  棋盘计数图案去掉底板/描边/外发光（纯 `_draw`）
#            → 非 headless 探针 work/_qa_1006/deploy_counter_probe.tscn
#   第 4 条  赤律族羁绊图标黑底透明化（静态素材，判据就是 PNG 像素）
#            → 其他/work/_qa_1006/assert_crimson_logo.py
#
# 跑法：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/prep_1006_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const LobbyScene := preload("res://scenes/menu/Team3v3Lobby.tscn")
const SettlementPanel := preload("res://scenes/menu/FinalSettlementPanel.gd")
const Presentation := preload("res://effects/runtime/presentation/PresentationSettings.gd")

const CHECK_NAME := "prep_1006"
const VIEW := Vector2i(1266, 600)
# 右侧竖列中心到面板右缘的距离。PrepUI 里刷新键的 offset 就是按它算的
# （列中心 W-78、框宽 130 ⇒ offset_left = -78-65 = -143、offset_right = -78+65 = -13）。
const SIDE_COLUMN_CENTER := 78.0

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	await _case_bug2_friend_row_nickname_only()
	await _case_bug6_return_text_trimmed()
	await _case_bug8_room_mute_button()
	await _case_bug3_shop_refresh_and_voice_ui()
	await _case_bug5_settlement_button_rows()
	await _case_bug7_shop_drop_inside_store()
	_case_structure_guards()
	# 前提体检：六个用例各自至少贡献两条 checked；总数对不上就是有用例没跑到。
	# 用例体里都有 await，少写一个 await 会让它在挂起点直接返回、断言一条都不跑，
	# 门禁看着绿其实什么都没验（无声失效）。
	_h.expect(_h.checked_count() >= 20, "cases_not_executed",
		"检查项只有 %d 条（应 ≥20）—— 有用例没跑到（多半是忘了 await），门禁在无声失效"
			% _h.checked_count())
	_h.finish(get_tree())


# ── 第 2 条：朋友列表只显示昵称 ────────────────────────────────────────────────

func _case_bug2_friend_row_nickname_only() -> void:
	NetworkService.team_active = false
	var lobby := await _build_lobby()
	if lobby == null:
		_h.fail("lobby_unavailable_bug2", "Team3v3Lobby 场景无法实例化，朋友列表判据无法执行")
		return
	var row := lobby.call("_online_friend_row",
		{"player_name": "夜刃", "friend_code": "ABCD1234", "online": true}) as Label
	_h.expect(row != null, "bug2_row_missing", "在线好友行没有建出来（_online_friend_row 返回空）")
	if row != null:
		_h.expect(row.text == "夜刃", "bug2_nickname_only",
			"朋友列表应当只显示昵称「夜刃」，实际「%s」" % row.text)
		_h.expect(not row.text.contains("#") and not row.text.contains("ABCD1234"),
			"bug2_no_friend_code",
			"朋友列表里不该再出现 #好友码，实际「%s」" % row.text)
	_teardown_lobby(lobby)


# ── 第 6 条：顶部文案只留前半段 ────────────────────────────────────────────────

func _case_bug6_return_text_trimmed() -> void:
	# 进「有玩家还卡在结算」的状态，再走真实入口 `_start_block_reason(true)`。
	NetworkService.team_active = true
	NetworkService.team_slot_states = ["settling", "player", "player", "settling", "player", "player"]
	NetworkService.team_ready = [true, true, true, true, true, true]
	NetworkService.team_local_slot = 1
	var lobby := await _build_lobby()
	if lobby == null:
		_h.fail("lobby_unavailable_bug6", "Team3v3Lobby 场景无法实例化，房间文案判据无法执行")
		_restore_network()
		return
	var reason := str(lobby.call("_start_block_reason", true))
	var want := "Waiting for players to return from results" if _locale_en() else "等待结算中的玩家返回"
	_h.expect(reason == want, "bug6_text_trimmed",
		"顶部文案应当只剩「%s」，实际「%s」" % [want, reason])
	_h.expect(not reason.contains("请离") and not reason.contains("房主") and not reason.contains("kick"),
		"bug6_no_kick_clause",
		"「…或由房主请离」那半句必须删掉，实际「%s」" % reason)
	_teardown_lobby(lobby)
	_restore_network()


# ── 第 8 条：房间里也能控制音乐播放 ───────────────────────────────────────────

func _case_bug8_room_mute_button() -> void:
	NetworkService.team_active = false
	var master := AudioServer.get_bus_index("Master")
	var bus_before := master >= 0 and AudioServer.is_bus_mute(master)
	var music_before: bool = Presentation.music_allowed()
	var lobby := await _build_lobby()
	if lobby == null:
		_h.fail("lobby_unavailable_bug8", "Team3v3Lobby 场景无法实例化，静音键判据无法执行")
		return
	var btn := lobby.get("_mute_button") as Button
	_h.expect(btn != null and is_instance_valid(btn), "bug8_mute_button_missing",
		"房间界面没有建出静音键（_mute_button 为空）")
	if btn != null:
		_h.expect(btn.name == "MuteButton", "bug8_mute_name",
			"静音键的节点名应当是 MuteButton，实际「%s」" % btn.name)
		# 起点先归一成「未静音」，才谈得上后面那一串翻转。
		AudioServer.set_bus_mute(master, false) if master >= 0 else null
		PlayerProfile.set_presentation_toggle("music", true)
		lobby.call("_refresh")
		_h.expect(btn.text == _mute_text(false), "bug8_label_idle",
			"未静音时按键应写「%s」，实际「%s」" % [_mute_text(false), btn.text])
		lobby.call("_toggle_mute")
		_h.expect(master >= 0 and AudioServer.is_bus_mute(master), "bug8_toggle_mutes_bus",
			"按一下静音键应当把 Master 总线静音（引擎级状态，切场景仍生效）")
		_h.expect(btn.text == _mute_text(true), "bug8_label_muted",
			"静音后按键应写「%s」，实际「%s」" % [_mute_text(true), btn.text])
		lobby.call("_toggle_mute")
		_h.expect(master < 0 or not AudioServer.is_bus_mute(master), "bug8_toggle_unmutes_bus",
			"再按一下应当解除总线静音")
		_h.expect(btn.text == _mute_text(false), "bug8_label_restored",
			"解除后按键应回到「%s」，实际「%s」" % [_mute_text(false), btn.text])
		# ★ 最容易漏的那个状态：设置页把「背景音乐」关了，房间里的键也必须显示已静音，
		# 而且在这一态按下去要把声音真正打开（清总线静音 + 打开音乐开关），
		# 不是把一个本来就没静音的总线翻成静音 —— 按了像没反应。
		if master >= 0:
			AudioServer.set_bus_mute(master, false)
		PlayerProfile.set_presentation_toggle("music", false)
		lobby.call("_refresh")
		_h.expect(btn.text == _mute_text(true), "bug8_label_from_music_toggle",
			"设置页关掉背景音乐时，房间里的键也要显示「%s」，实际「%s」"
				% [_mute_text(true), btn.text])
		lobby.call("_toggle_mute")
		_h.expect(master >= 0 and not AudioServer.is_bus_mute(master) and Presentation.music_allowed(),
			"bug8_toggle_recovers_from_music_off",
			"在「设置页关了音乐」这一态按一下，应当把声音真正打开（清总线静音 + 打开音乐开关）")
		_h.expect(btn.text == _mute_text(false), "bug8_label_after_recover",
			"恢复后按键应写「%s」，实际「%s」" % [_mute_text(false), btn.text])
		# 还原现场，别把静音状态留给后面的用例 / 真机。
		if master >= 0:
			AudioServer.set_bus_mute(master, bus_before)
		PlayerProfile.set_presentation_toggle("music", music_before)
		_teardown_lobby(lobby)


# ── 第 3 条：刷新键对齐右侧竖列 + 开商店隐藏语音 UI ───────────────────────────

func _case_bug3_shop_refresh_and_voice_ui() -> void:
	var prep := await _build_prep()
	if prep == null:
		_h.fail("prep_unavailable_bug3", "PrepScreen 无法实例化，商店/语音判据无法执行")
		return
	var shop: Variant = prep.get("_shop")
	var refresh := (shop.get("refresh_button") as Button) if shop != null else null
	var side := (shop.get("side_controls") as Control) if shop != null else null
	_h.expect(refresh != null and side != null, "bug3_refresh_missing",
		"商店刷新键或外挂层没有建出来（refresh_button / side_controls 为空）")
	if refresh != null and side != null and side.size.x > 0.0:
		var center := refresh.get_global_rect().get_center().x
		var column := side.get_global_rect().position.x + side.size.x - SIDE_COLUMN_CENTER
		_h.expect(absf(center - column) <= 2.0, "bug3_refresh_aligned",
			"刷新键中心应当落在右侧竖列中心 x=%.1f，实际 x=%.1f（差 %.1f）"
				% [column, center, absf(center - column)])
		_h.expect(refresh.get_global_rect().end.x <= side.get_global_rect().end.x + 1.0,
			"bug3_refresh_inside_view",
			"刷新键右缘探出了屏幕（10.06 截图就是这个问题）：右缘 %.1f vs 可用右缘 %.1f"
				% [refresh.get_global_rect().end.x, side.get_global_rect().end.x])
	else:
		_h.fail("bug3_layout_unavailable",
			"side_controls 尺寸为 0，刷新键对齐判据无法执行（布局没跑起来）")
	# 语音三键：商店开 → 整块隐藏；商店关 → 回到原样（隐藏恢复走 set_deferred，下一帧生效）。
	# ★ 商店开时要收起来的是**整簇**：外面那层 `_comms_dock` 深色底板（308×88、z=19）
	# 比最左的语音键还宽一圈，垫在「语音/队友/所有人/聊天」四个键后面。第一版只藏了三个键，
	# 底板与聊天按钮留在原地 ⇒ 真机复测反馈「开商店而语音 UI 没消失」。所以这里连底板一起验。
	var vc: Variant = prep.get("_voice_controls")
	var dock := prep.get("_comms_dock") as Control
	var chat := prep.get("_chat_button") as Control
	var buttons: Array = []
	if vc != null:
		buttons = [vc.voice_button, vc.audience_button, vc.members_button]
	buttons.append(dock)
	buttons.append(chat)
	var usable := buttons.size() == 5
	for b in buttons:
		if b == null or not is_instance_valid(b):
			usable = false
	_h.expect(usable, "bug3_comms_cluster_missing",
		"PrepScreen 的通讯簇（语音三键 + _comms_dock + _chat_button）没建全，隐藏判据无法执行")
	if usable:
		var before: Array = []
		for b in buttons:
			before.append((b as Control).visible)
		# ★ 走**真实入口**：底部「商店」按钮按下去就是 `_shop.toggle_picker()` →
		# `_refresh_picker()` → `picker_toggled.emit` → 宿主 `_on_shop_picker_toggled`。
		# 直接调 `_on_shop_picker_toggled(true)` 只证明处理器本身对，证明不了这条接线通。
		var shop_v: Variant = prep.get("_shop")
		_h.expect(shop_v != null, "bug3_shop_missing",
			"商店面板没建出来，真实入口判据无法执行")
		if shop_v != null:
			shop_v.call("toggle_picker")
			await get_tree().process_frame
			_h.expect(bool(shop_v.get("picker_open")), "bug3_shop_open_precondition",
				"前置不成立：调了 toggle_picker() 之后 picker_open 仍为 false")
			for b in buttons:
				var c := b as Control
				_h.expect(not c.visible, "bug3_comms_hidden_%s" % c.name,
					"商店打开时通讯簇成员 %s 必须收起（10.06 第 3 条：右下角让位给刷新键），实际仍可见"
						% c.name)
			shop_v.call("toggle_picker")
			await get_tree().process_frame
			await get_tree().process_frame
			for i in buttons.size():
				var c := buttons[i] as Control
				_h.expect(c.visible == before[i], "bug3_comms_restored_%d_%s" % [i, c.name],
					"关掉商店后 %s 应当回到原样（原 %s，现 %s）" % [c.name, str(before[i]), str(c.visible)])
	_teardown_node(prep)


# ── 第 5 条：结算面板上、下各一排按钮，滚动提示已删 ──────────────────────────

func _case_bug5_settlement_button_rows() -> void:
	var panel: Control = SettlementPanel.new()
	var seats: Array = []
	for i in 6:
		seats.append({"name": "P%d" % i, "board": [], "mercenaries": [], "treasures": [],
			"stones": {}, "total_gold": 0, "round_damage": 0})
	panel.data = {"outcome": 0, "seats": seats, "stats": [], "local_team": 0,
		"allies": [], "can_return_room": true, "close_text": ""}
	add_child(panel)
	await get_tree().process_frame
	var back := _buttons_with_text(panel, "返回房间")
	var menu := _buttons_with_text(panel, "返回主菜单")
	_h.expect(back.size() == 2, "bug5_two_return_rows",
		"面板上、下应当各有一排「返回房间」按钮（10.06 第 5 条：不必滚到底才够得着），实际 %d 个"
			% back.size())
	_h.expect(menu.size() == 2, "bug5_two_menu_rows",
		"面板上、下应当各有一排「返回主菜单」按钮，实际 %d 个" % menu.size())
	var tracked: Array = panel.get("_return_buttons")
	_h.expect(tracked.size() == 2, "bug5_return_buttons_tracked",
		"两排的「返回房间」都要进 _return_buttons（否则 allow_return_retry 只恢复一排），实际 %d 个"
			% tracked.size())
	var hinted := false
	var hint_text := ""
	for node in panel.find_children("*", "Label", true, false):
		var t := str((node as Label).text)
		if t.contains("超过一屏") or t.contains("可上下滚动"):
			hinted = true
			hint_text = t
	_h.expect(not hinted, "bug5_scroll_hint_removed",
		"「↓ 本结算面板超过一屏，可上下滚动查看全部内容」那句提示必须删掉，实际还在：「%s」" % hint_text)
	# 接线判据（不是命中判据）：按上面那排的返回，两排要一起进「正在返回…」，
	# 否则玩家可以连点两次返回、发出两次请求。真鼠标命中由非 headless 探针覆盖。
	if back.size() == 2:
		(back[0] as Button).pressed.emit()
		await get_tree().process_frame
		var disabled := 0
		for b in tracked:
			if is_instance_valid(b) and (b as Button).disabled:
				disabled += 1
		_h.expect(disabled == 2, "bug5_both_rows_disabled_on_press",
			"按上面那排的「返回房间」后，两排都该禁用（防重复返回），实际禁用 %d/2" % disabled)
	panel.queue_free()
	await get_tree().process_frame


# ── 第 7 条：落点还在商店里就不算一次购买 ────────────────────────────────────

func _case_bug7_shop_drop_inside_store() -> void:
	var prep := await _build_prep()
	if prep == null:
		_h.fail("prep_unavailable_bug7", "PrepScreen 无法实例化，商店落点判据无法执行")
		return
	var shop: Variant = prep.get("_shop")
	if not _h.expect(shop != null, "bug7_shop_missing", "商店面板没有建出来"):
		_teardown_node(prep)
		return
	shop.call("toggle_picker")            # 真实入口：开商店
	await get_tree().process_frame
	await get_tree().process_frame
	var panel := shop.get("panel") as Control
	var opened := bool(shop.get("picker_open")) and panel != null and panel.visible and panel.size.x > 0.0
	_h.expect(opened, "bug7_shop_not_open",
		"前置不成立：商店没开、或弹窗尺寸为 0 —— 落点判据会空过")
	if opened:
		var inside := panel.get_global_rect().get_center()
		var outside := panel.get_global_rect().position - Vector2(48.0, 48.0)
		var shop_payload := {"kind": "shop", "index": 0}
		_h.expect(bool(prep.call("_shop_drop_inside_store", shop_payload, inside)),
			"bug7_inside_is_blocked",
			"落在商店弹窗内的松手应当被拦下（10.06 第 7 条：不当成一次购买）")
		_h.expect(not bool(prep.call("_shop_drop_inside_store", shop_payload, outside)),
			"bug7_outside_is_allowed",
			"落在商店外的松手不该被拦 —— 拖到棋盘/待命格照旧买入")
		_h.expect(not bool(prep.call("_shop_drop_inside_store", {"kind": "board", "index": 0}, inside)),
			"bug7_board_payload_not_blocked",
			"只有 kind=shop 才拦：棋盘上的棋子拖到商店区不该被这条规则吃掉")
		# 外挂层（钱袋 A / 刷新键）也压着棋盘下缘，落在它上面同属「还在商店里」。
		var side := shop.get("side_controls") as Control
		var hit_side := false
		if side != null and side.visible:
			for child in side.get_children():
				var c := child as Control
				if c != null and c.visible and c.size.x > 0.0 \
						and bool(prep.call("_shop_drop_inside_store", shop_payload, c.get_global_rect().get_center())):
					hit_side = true
					break
		_h.expect(hit_side, "bug7_side_layer_blocked",
			"落在商店外挂层（钱袋 A / 刷新键）上的松手也应当被拦下，否则「在商店里随手一拖」照样误购")
		shop.call("toggle_picker")        # 真实入口：关商店
		await get_tree().process_frame
		_h.expect(not bool(prep.call("_shop_drop_inside_store", shop_payload,
				panel.get_global_rect().get_center())), "bug7_closed_shop_not_blocked",
			"商店关着时这条规则不该生效（否则拖到棋盘上买入会被误拦）")
	_teardown_node(prep)


# ── 结构判据：行为断言够不着的那两处 ─────────────────────────────────────────
#
# 行为断言只验到「守卫函数本身」和「绘制结果」，验不到「两条拖拽路径到底有没有调用守卫」
# 与「_draw 里还在画哪几层」。这两处用读源码的方式兜住 —— 本仓先例：
# `team_lobby_seat_label_check._case_apply_shared_by_layout_and_refresh()` 也是这么做的。
func _case_structure_guards() -> void:
	var board := FileAccess.get_file_as_string("res://scenes/prep/PrepBoardController.gd")
	_h.expect(not board.is_empty(), "structure_board_source_missing",
		"读不到 PrepBoardController.gd，拖拽路径的结构判据无法执行")
	if not board.is_empty():
		_h.expect(_func_body(board, "func _drop_on_board(").contains("_shop_drop_inside_store"),
			"bug7_board_path_guarded",
			"_drop_on_board 没有调用 _shop_drop_inside_store —— 拖到棋盘那条路的误购没被拦下")
		_h.expect(_func_body(board, "func _drop_on_bench(").contains("_shop_drop_inside_store"),
			"bug7_bench_path_guarded",
			"_drop_on_bench 没有调用 _shop_drop_inside_store —— 拖到待命区那条路的误购没被拦下")
	var counter := FileAccess.get_file_as_string("res://scenes/prep/panels/PrepDeployCounter.gd")
	_h.expect(not counter.is_empty(), "structure_counter_source_missing",
		"读不到 PrepDeployCounter.gd，计数图案的结构判据无法执行")
	if not counter.is_empty():
		var draw := _func_body(counter, "func _draw(")
		_h.expect(not draw.contains("draw_soft_glow"), "bug1_no_glow",
			"计数图案的 _draw 里还在画外发光（10.06 第 1 条要去掉外圈那层光）")
		_h.expect(not draw.contains("PLATE_BG"), "bug1_no_plate",
			"计数图案的 _draw 里还在画深色底板（用户点名的「中间填充的黑色底色」）")
		_h.expect(not draw.contains("draw_polyline"), "bug1_no_border",
			"计数图案的 _draw 里还在画描边（用户点名的「外部椭圆」）")


# 取某个函数体的源码（签名之后、下一个顶层 `func ` 之前）。行尾先归一，否则
# CRLF 下 `find("\nfunc ")` 恒 -1，会静默退化成「取到文件末尾」。
func _func_body(src: String, signature: String) -> String:
	var text := src.replace("\r\n", "\n")
	var start := text.find(signature)
	if start < 0:
		return ""
	var rest := text.substr(start + signature.length())
	var nxt := rest.find("\nfunc ")
	return rest if nxt < 0 else rest.substr(0, nxt)


# ── 脚手架 ────────────────────────────────────────────────────────────────────

func _build_lobby() -> Control:
	get_viewport().size = VIEW
	var lobby: Control = LobbyScene.instantiate()
	add_child(lobby)
	await get_tree().process_frame
	return lobby


func _teardown_lobby(lobby: Control) -> void:
	if lobby != null and is_instance_valid(lobby):
		lobby.queue_free()
		await get_tree().process_frame


func _build_prep() -> Node:
	# 语音三键只在「联机 3v3」里建：PrepUI._build_chat_entry() 开头就是
	# `if GameState.tutorial_mode or not NetworkService.team_active: return`。
	# 不把这个开关打开，第 3 条那条用例测的就成了「根本没有语音键」而不是「有没有隐藏」。
	NetworkService.team_active = true
	GameState.reset_run()
	GameState.tutorial_mode = false
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if packed == null:
		return null
	var prep: Node = packed.instantiate()
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	return prep


func _teardown_node(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
		await get_tree().process_frame


func _restore_network() -> void:
	NetworkService.team_active = false
	NetworkService.team_slot_states = []
	NetworkService.team_ready = []


func _buttons_with_text(root: Node, text: String) -> Array:
	var out: Array = []
	for node in root.find_children("*", "Button", true, false):
		if (node as Button).text == text:
			out.append(node)
	return out


func _locale_en() -> bool:
	return TranslationServer.get_locale().begins_with("en")


# 与 Team3v3Lobby._mute_label_text() 同一口径、但独立写一遍：
# 期望值按「静音状态 + 当前语言」重新算，不调用生产函数（否则断言成了自证）。
func _mute_text(muted: bool) -> String:
	if LocaleManager.get_locale() == "en":
		return "Muted" if muted else "Mute"
	return "已静音" if muted else "静音"
