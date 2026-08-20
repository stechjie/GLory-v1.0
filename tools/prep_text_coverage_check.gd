extends Node

# 守「数据表里的每一件宝物/联动都有文案」。
#
# 为什么值得单独一条：这三个函数都是 match + 兜底 return，
# 少写一条不会崩、不会报错，玩家只会看到占位符：
#   "暂未写入详细说明。" / "Description not yet available." / "联动效果待说明。"
# 加宝物是数据改动，最容易忘的就是回头补文案；而没有任何机制提醒。
#
# 与其把这几张查表搬来搬去（它们是**数据不是逻辑**，搬了也不减耦合），
# 不如加一条把「数据表」和「文案表」对起来的检查 —— 那才是这里真正的风险点。
#
# 现状：25 件宝物、11 条联动，中英文案当前都是齐的。这条检查是为了让它保持齐。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/prep_text_coverage_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
# 种族显示名已随羁绊面板搬到 SynergyPanel。用 preload 常量做类型标注 ——
# 按名字调用会被 dynamic_call 的棘轮记账。
const SynergyPanelScript := preload("res://scenes/prep/panels/SynergyPanel.gd")
const TreasurePanelScript := preload("res://scenes/prep/panels/TreasureChoicePanel.gd")

const CHECK_NAME := "prep_text_coverage"

const PLACEHOLDER_CN := "暂未写入详细说明。"
const PLACEHOLDER_EN := "Description not yet available."
const PLACEHOLDER_LINK := "联动效果待说明。"

var _h: CheckHarness
var _prep: Node


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		_h.finish(get_tree())
		return
	_prep = packed.instantiate()
	add_child(_prep)
	await get_tree().process_frame

	var table: Dictionary = DataRegistry.get_table("treasures")
	var treasures: Array = table.get("treasures", [])
	var linkages: Array = table.get("linkages", [])

	if not _h.expect(not treasures.is_empty(), "treasures_empty",
			"treasures 表为空 —— 检查集为空不算通过"):
		_h.finish(get_tree())
		return
	_h.expect(not linkages.is_empty(), "linkages_empty", "linkages 表为空")

	_check_treasures(treasures)
	_check_linkages(linkages)
	_check_race_names()

	print("[%s] 宝物 %d 件、联动 %d 条" % [CHECK_NAME, treasures.size(), linkages.size()])
	_h.finish(get_tree())


func _check_treasures(rows: Array) -> void:
	for row in rows:
		var tid := str((row as Dictionary).get("id", ""))
		if tid.is_empty():
			_h.fail("treasure_id_empty", "treasures 表里有一行没有 id")
			continue
		var tp := _prep.get("_treasure") as TreasurePanelScript
		var cn := "" if tp == null else tp.effect_text(tid)
		_h.expect(cn != PLACEHOLDER_CN and not cn.is_empty(), "treasure_text_missing_cn",
			"宝物 %s 缺中文说明（落到了占位符）" % tid)
		var en := "" if tp == null else tp.effect_text_en(tid)
		_h.expect(en != PLACEHOLDER_EN and not en.is_empty(), "treasure_text_missing_en",
			"宝物 %s 缺英文说明（落到了占位符）" % tid)


func _check_linkages(rows: Array) -> void:
	for row in rows:
		var lid := str((row as Dictionary).get("id", ""))
		if lid.is_empty():
			_h.fail("linkage_id_empty", "linkages 表里有一行没有 id")
			continue
		var tp2 := _prep.get("_treasure") as TreasurePanelScript
		var text := "" if tp2 == null else tp2.link_effect_text(lid)
		_h.expect(text != PLACEHOLDER_LINK and not text.is_empty(), "linkage_text_missing",
			"联动 %s 缺说明（落到了占位符）" % lid)
		# 联动的 requires 必须都是真实存在的宝物 id，否则这条联动永远触发不了。
		# link_phoenix 曾经就是靠人工核对才确认它的两件依赖存在的。
		for req in ((row as Dictionary).get("requires", []) as Array):
			var req_id := str(req)
			var found := false
			for t in DataRegistry.get_table("treasures").get("treasures", []):
				if str((t as Dictionary).get("id", "")) == req_id:
					found = true
					break
			_h.expect(found, "linkage_requires_unknown",
				"联动 %s 依赖的宝物 %s 在 treasures 表里不存在 —— 这条联动永远不会触发" % [lid, req_id])


# 四个种族的显示名不能落回原始 id（那说明 match 漏了一支）。
func _check_race_names() -> void:
	for race in ["god", "dark", "undead", "human"]:
		var panel := _prep.get("_synergy") as SynergyPanelScript
		var name := "" if panel == null else panel.race_name(race)
		_h.expect(name != race and not name.is_empty(), "race_name_missing",
			"种族 %s 没有显示名，直接返回了 id" % race)
