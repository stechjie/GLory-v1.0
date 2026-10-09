extends Node

# 10.09 bug 文档第 2 条（选了金钱类宝藏后，获得的技能按钮排进左下角宝藏区、
# 点不到）的**几何判据**。
#
# 为什么要写成门禁而不是读源码：
#   * 症状是「压盖」——左侧「羁绊/宝藏」栏（`SynergyPanel._left_panel`）的内容最低点
#     越过了左下角宝藏 logo 面板（`TreasurePanel`）的顶边，金钱宝藏按钮因此落进宝藏
#     区、被盖住点不到。「越没越过」只有把整页真例化、真让容器把 `_refresh_all()` 跑完
#     才算得出来；读 `SELL_LEFT_PANEL_TOP_RESERVE` 的值本身不构成判据。
#   * 修复手段是把 `PrepUI.SELL_LEFT_PANEL_TOP_RESERVE` 由 132 收到 48（栏顶从与头像
#     间空 92px 收到只留 8px）。若只断言「常量 == 48」，任何为别的目的改这个数都会红，
#     而真正的产品约束是「栏顶紧贴头像」+「内容最低点不压宝藏区」。所以本门禁量几何，
#     不量常量 —— 把常量改回 132，几何必然变红，这才是判别力所在。
#
# 判据（两种窗口尺寸都跑，取最矮的 1600×720 作最坏情况）：
#   1. 栏顶不得与头像重叠：gap = panel.top − avatar.bottom >= 0
#   2. gap 必须收敛到「紧贴」量级（<= 40px）。旧预留 132 会给出约 92px ⇒ 红
#   3. 栏内容最低点 <= `TreasurePanel` 顶边（不压盖）
#   4. 栏里每个按钮的底边 <= `TreasurePanel` 顶边（按钮整体在宝藏区上方）
#   5. 至少渲染出 1 个按钮 —— 否则说明这个用例没真的覆盖到「金钱宝藏」场景
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/prep_layout_1009_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "prep_layout_1009"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

# 头像底边到羁绊栏顶端的最大允许空档。收 132→48 后实测 8px；给到 40px 吸收字体/主题
# 差异，同时旧值（约 92px）必红。
const MAX_AVATAR_PANEL_GAP := 40.0

# 1600×758：宽屏（安卓真机/模拟器比例）下的画布高；1600×720（16:9）最矮 ⇒ 可用高度
# 最小，是压盖最容易发生的形状，两种都覆盖。
const WINDOW_SIZES: Array[Vector2i] = [Vector2i(1266, 600), Vector2i(1600, 720)]

# 用户反馈里点名的「金钱类宝藏」，两枚都挂上以确保栏里长出可点按钮。
const MONEY_TREASURES: Array[String] = ["money_golden_altar", "money_generous_fate"]

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	DataRegistry.load_all()
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "%s 无法加载" % PREP_SCENE):
		_h.finish(get_tree())
		return
	for size in WINDOW_SIZES:
		await _measure(packed, size)
	_h.finish(get_tree())


func _measure(packed: PackedScene, size: Vector2i) -> void:
	var tag := "%dx%d" % [size.x, size.y]
	get_viewport().size = size
	_setup_game_state()

	var prep := packed.instantiate()
	add_child(prep)
	for i in 6:
		await get_tree().process_frame
	prep.call("_refresh_all")
	for i in 3:
		await get_tree().process_frame

	var ri := prep.get("_ready_indicator") as Control
	var synergy: Object = prep.get("_synergy")
	var lp: Control = null
	if synergy != null:
		lp = synergy.get("_left_panel") as Control
	var tp := prep.find_child("TreasurePanel", true, false) as Control

	if not _h.expect(ri != null and lp != null and tp != null, "node_missing",
			"[%s] 量测节点缺失：ready_indicator=%s left_panel=%s TreasurePanel=%s" % [
				tag, str(ri != null), str(lp != null), str(tp != null)]):
		_teardown(prep)
		return

	var avatar_bottom := ri.get_global_rect().end.y
	var panel_top := lp.get_global_rect().position.y
	var treasure_top := tp.get_global_rect().position.y

	# `_left_panel` 自带 SIZE_EXPAND_FILL（会被撑满剩余高度），所以它的 rect 高度不代表
	# 实际内容；真正的内容边界要逐子节点取「底边最大值」。
	var content_bottom := panel_top
	var buttons: Array[Control] = []
	for c in lp.get_children():
		if c is Control:
			content_bottom = maxf(content_bottom, (c as Control).get_global_rect().end.y)
			if c is Button:
				buttons.append(c)

	var gap := panel_top - avatar_bottom
	_h.note("[%s] avatar_bottom=%.1f panel_top=%.1f gap=%.1f content_bottom=%.1f treasure_top=%.1f buttons=%d" % [
		tag, avatar_bottom, panel_top, gap, content_bottom, treasure_top, buttons.size()])

	# 1) 栏顶不叠到头像（收得过猛就会红）
	_h.expect(gap >= 0.0, "panel_overlaps_avatar",
		"[%s] 羁绊/宝藏栏顶端(%.1f) 高于头像底边(%.1f)，压住头像（gap=%.1f）" % [
			tag, panel_top, avatar_bottom, gap])
	# 2) 栏顶紧贴头像（旧预留 132 会给出约 92px ⇒ 红）
	_h.expect(gap <= MAX_AVATAR_PANEL_GAP, "avatar_panel_gap_too_large",
		"[%s] 头像与羁绊栏之间空档 %.1fpx 超过 %.0fpx：用户反馈的空位没被用上（SELL_LEFT_PANEL_TOP_RESERVE 预留过多）" % [
			tag, gap, MAX_AVATAR_PANEL_GAP])
	# 3) 栏内容不压左下角宝藏区
	_h.expect(content_bottom <= treasure_top, "panel_content_overlaps_treasure",
		"[%s] 羁绊/宝藏栏内容最低点 %.1f 越过 TreasurePanel 顶边 %.1f，压盖 %.1fpx" % [
			tag, content_bottom, treasure_top, content_bottom - treasure_top])
	# 4) 每个按钮都在宝藏区上方
	for b in buttons:
		var br := b.get_global_rect()
		_h.expect(br.end.y <= treasure_top, "treasure_button_overlaps_treasure",
			"[%s] 羁绊栏按钮「%s」底边 %.1f 越过 TreasurePanel 顶边 %.1f" % [
				tag, str(b.text).substr(0, 18), br.end.y, treasure_top])
	# 5) 确实渲染出了按钮（否则本用例没覆盖到目标场景）
	_h.expect(buttons.size() >= 1, "no_treasure_buttons_found",
		"[%s] 羁绊栏里一个按钮都没渲染出来 —— 本用例没真的覆盖到金钱宝藏场景" % tag)

	_teardown(prep)


func _teardown(prep: Node) -> void:
	prep.queue_free()
	await get_tree().process_frame


func _setup_game_state() -> void:
	NetworkService.team_active = true
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	GameState.reset_run()
	GameState.tutorial_mode = false
	GameState.team_mode = true
	# 四个种族各上一枚 ⇒ 羁绊栏长出 4 行（与用户截图一致，把栏内容撑到接近满高）。
	var races: Array[String] = ["god", "dark", "undead", "human"]
	for i in races.size():
		var p := _piece_for_race(races[i])
		if not p.is_empty():
			GameState.board_slots[i] = p
	GameState.owned_treasures = MONEY_TREASURES.duplicate()


func _piece_for_race(race: String) -> Dictionary:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for u in units:
		var d: Dictionary = u
		if str(d.get("race", "")) != race:
			continue
		if bool(d.get("unique_on_board", false)):
			continue
		return {"id": str(d.get("id", "")), "uid": "probe_%s" % race, "star": 1, "def": d.duplicate(true)}
	return {}
