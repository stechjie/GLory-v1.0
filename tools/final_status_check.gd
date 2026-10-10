extends Node

func _ready() -> void:
	DataRegistry.ensure_loaded()
	var table: Dictionary = DataRegistry.get_table("final_status")
	if DataRegistry.state != DataRegistry.State.READY:
		push_error("final status: DataRegistry did not load")
		get_tree().quit(1)
		return
	if table.get("units", {}).size() != 40 or table.get("pets", {}).size() != 5:
		push_error("final status: wrong unit or pet count")
		get_tree().quit(1)
		return
	var dragon_def: Dictionary = {}
	for unit in DataRegistry.get_table("race_units").get("units", []):
		if str(unit.get("id", "")) == "dark_dragon":
			dragon_def = unit
			break
	var dragon_catalog: Dictionary = table.get("units", {}).get("dark_dragon", {})
	if dragon_def.is_empty() or dragon_catalog.is_empty() or not is_equal_approx(float(UnitFactory.apply_star_stats(dragon_def, 1).get("damage_atk_pct", 0.0)), float(dragon_catalog.get("skill_damage_multiplier_1to3", 0.0))) or not is_equal_approx(float(UnitFactory.apply_star_stats(dragon_def, 4).get("damage_atk_pct", 0.0)), float(dragon_catalog.get("skill_damage_multiplier_4", 0.0))):
		push_error("final status: dark dragon battle damage does not match Excel")
		get_tree().quit(1)
		return
	LocaleManager.set_locale("zh")
	if PetService.effect_text("pet_mushroom") != "己方棋子生命 +10%":
		push_error("final status: pet summary is not connected")
		get_tree().quit(1)
		return
	if not PetService.skill_detail_text("pet_tiger").contains("无限累计"):
		push_error("final status: pet detail is not connected")
		get_tree().quit(1)
		return
	var altar_cost := TreasureService.golden_altar_hp_cost()
	if not FinalStatusCatalog.treasure_effect_cn("money_golden_altar").contains("每次 -%d 法阵 HP" % altar_cost):
		push_error("final status: golden altar runtime HP cost does not match Excel text")
		get_tree().quit(1)
		return
	var altar_room: Dictionary = NetworkService._new_room()
	altar_room.state = NetworkService.ROOM_PREP
	altar_room.slot_states = ["player", "player", "player", "player", "empty", "empty"]
	altar_room.team_hp = [30, 30]
	var altar_result := NetworkService._room_apply_altar(altar_room, 0)
	if not bool(altar_result.get("ok", false)) or int(altar_room.team_hp[0]) != 30 - altar_cost:
		push_error("final status: multiplayer altar did not deduct the Excel HP cost")
		get_tree().quit(1)
		return
	if not FinalStatusCatalog.synergy_cn("undead", 2).get("detail_cn", "").contains("30%"):
		push_error("final status: undead heal reduction is missing")
		get_tree().quit(1)
		return
	if not FinalStatusCatalog.linkage_effect_cn("link_phoenix").contains("40%"):
		push_error("final status: phoenix text is missing")
		get_tree().quit(1)
		return
	for scene_path in ["res://scenes/menu/ShopScreen.tscn", "res://scenes/menu/BagScreen.tscn", "res://scenes/menu/CodexScreen.tscn"]:
		if load(scene_path) == null:
			push_error("final status: failed to load " + scene_path)
			get_tree().quit(1)
			return
	if FinalStatusCatalog.linkage_effect_cn("link_blood_covenant").contains("表内字段"):
		push_error("final status: internal fields leaked into player text")
		get_tree().quit(1)
		return
	var fighter := {"uid": "phoenix_probe", "team": "player", "max_hp": 101, "hp": 0,
		"alive": false, "phoenix_used": true, "statuses": {}, "def": {"skill_id": "none"}}
	var state := {"elapsed": 1.0, "revive_queue": [{"due": 0.0, "fighter": fighter}],
		"player": [], "enemy": [], "log": []}
	BattleSimTreasures._process_revives(state)
	if state.player.size() != 1 or int(state.player[0].hp) != 40:
		push_error("final status: phoenix actual revived HP is not 40%")
		get_tree().quit(1)
		return
	var nun_allies: Array = [
		{"alive": true, "team": "player", "hp": 50, "max_hp": 100, "statuses": {"stun": {"time": 1.0}}},
		{"alive": true, "team": "player", "hp": 50, "max_hp": 100, "statuses": {"silence": {"time": 1.0}}},
	]
	BattleSimSkills._skill_holy_song({}, nun_allies, {"heal_pct": 0.15, "cleanse_control": true})
	if int(nun_allies[0].hp) != 65 or int(nun_allies[1].hp) != 65:
		push_error("final status: nun did not heal both living allies by 15%")
		get_tree().quit(1)
		return
	if int(nun_allies[0].statuses.is_empty()) + int(nun_allies[1].statuses.is_empty()) != 1:
		push_error("final status: nun did not cleanse exactly one affected ally")
		get_tree().quit(1)
		return
	print("FINAL_STATUS_CHECK_OK")
	get_tree().quit(0)
