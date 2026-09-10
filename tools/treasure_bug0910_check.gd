extends Node
const Harness = preload("res://tools/CheckHarness.gd")

func _ready() -> void:
	var h = Harness.new("treasure_bug0910")
	var owned := GameState.owned_treasures.duplicate()
	var pending := GameState.pending_treasure.duplicate(true)
	var saved_active: bool = TutorialMode.active
	var saved_step: int = TutorialMode.step
	var saved_gold: int = GameState.gold
	GameState.owned_treasures.assign(["atk_fury_roster"])
	TutorialMode._start_treasure(TutorialMode.TREASURE_2)
	var candidates: Array = GameState.pending_treasure.candidates
	h.expect(candidates.size() == 3 and not candidates.has("atk_fury_roster"), "unowned_offer", "第二次候选不含已拥有的狂怒阵容")
	var cleaned := TreasureService.available_candidates(["atk_fury_roster", "money_discount", "money_discount", "invalid"])
	h.expect(cleaned.size() == 3 and cleaned.count("money_discount") == 1 and not cleaned.has("invalid"), "sanitize", "候选去重并排除无效ID")
	GameState.pending_treasure.candidates = TutorialMode.TREASURE_2.duplicate()
	h.expect(not TreasureService.claim_local_choice("atk_fury_roster") and GameState.pending_treasure.active and GameState.owned_treasures.size() == 1, "reject_duplicate", "重复选择不能结束待选状态")
	h.expect(not TreasureService.claim_local_choice("def_iron_wall"), "reject_not_offered", "不允许领取候选外宝藏")
	GameState.pending_treasure.active = false
	TutorialMode.active = true
	TutorialMode.step = TutorialMode.Step.TAKE_TREASURE_2
	TutorialMode.sync()
	h.expect(GameState.pending_treasure.active and not GameState.pending_treasure.candidates.has("atk_fury_roster"), "recover_stuck", "卡住的旧教学进度重新提供有效候选")
	h.expect(TreasureService.claim_local_choice("money_discount") and GameState.owned_treasures.size() == 2, "claim_new", "选择新宝藏使持有数量增加到2")
	h.expect(not TreasureService.claim_local_choice("money_discount"), "double_click", "连续重复领取不会重复入袋")
	TutorialMode.sync()
	h.expect(TutorialMode.step == TutorialMode.Step.HIRE_MERC, "advance", "第二件宝藏领取后教学正常推进")
	GameState.owned_treasures.assign(owned)
	GameState.pending_treasure = pending
	GameState.gold = saved_gold
	TutorialMode.active = saved_active
	TutorialMode.step = saved_step
	h.finish(get_tree())
