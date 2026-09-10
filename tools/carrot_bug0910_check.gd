extends Node

const Harness = preload("res://tools/CheckHarness.gd")
const Ledger = preload("res://scripts/multiplayer/EconomyLedger.gd")
const CampPanel = preload("res://scenes/prep/CarrotCampPanelV3.gd")
const Format = preload("res://scripts/ui/UnitDetailFormat.gd")

func _ready() -> void:
	var h = Harness.new("carrot_bug0910")
	var saved := [GameState.round_index, GameState.gold, GameState.harvest_tech_level, GameState.tutorial_mode]
	GameState.round_index = 1
	GameState.gold = 100
	GameState.harvest_tech_level = 0
	h.expect(not GameState.upgrade_harvest_tech().get("ok", false) and GameState.gold == 100 and GameState.harvest_tech_level == 0, "round1_local", "首回合禁止升级且不扣费")
	var panel = CampPanel.new()
	add_child(panel)
	panel.setup(Callable(), Callable())
	panel.refresh()
	h.expect(panel._tech_button.disabled and panel._tech_note.text == "下一回合解锁升级", "round1_ui", "首回合禁用按钮并显示解锁提示")
	GameState.round_index = 2
	panel.refresh()
	h.expect(not panel._tech_button.disabled and panel._tech_note.text == "升级后，下回合生效", "round2_ui", "第二回合解锁并恢复原提示")
	h.expect(GameState.upgrade_harvest_tech().get("ok", false) and GameState.gold == 0 and GameState.harvest_tech_level == 1, "round2_local", "第二回合正常扣费升级")
	h.expect(not GameState.upgrade_harvest_tech().get("ok", false) and GameState.gold == 0, "poor_local", "余额不足不扣费")
	panel.free()
	var prep := {"gold": 100, "harvest_tech_level": 0}
	h.expect(not Ledger._upgrade_harvest_tech(prep, {"round_index": 2}, {"round_index": 1}).get("ok", false) and prep.gold == 100 and prep.harvest_tech_level == 0, "round1_server", "服务端拒绝首回合升级，忽略客户端伪造回合")
	h.expect(Ledger._upgrade_harvest_tech(prep, {}, {"round_index": 2}).get("ok", false) and prep.gold == 0 and prep.harvest_tech_level == 1, "round2_server", "服务端第二回合正常升级")
	for merc in DataRegistry.data.mercenaries.mercenaries:
		GameState.tutorial_mode = false
		var carrot_text := ("%d carrots" if Format.is_en() else "%d萝卜") % int(merc.carrot_cost)
		h.expect(Format.format_unit_def(merc).contains(carrot_text), "merc_carrots", "普通对局佣兵详情显示萝卜：" + str(merc.id))
		GameState.tutorial_mode = true
		var gold_text := ("%d G" if Format.is_en() else "%d金") % int(merc.cost)
		h.expect(Format.format_unit_def(merc).contains(gold_text), "tutorial_gold", "引导佣兵详情保持金币：" + str(merc.id))
	GameState.tutorial_mode = false
	h.expect(Format.purchase_price_text({"cost": 25}) == ("25 G" if Format.is_en() else "25金"), "unit_gold", "普通棋子保持金币")
	GameState.round_index = saved[0]
	GameState.gold = saved[1]
	GameState.harvest_tech_level = saved[2]
	GameState.tutorial_mode = saved[3]
	h.finish(get_tree())
