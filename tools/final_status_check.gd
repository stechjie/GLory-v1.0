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
	LocaleManager.set_locale("zh")
	if PetService.effect_text("pet_mushroom") != "己方棋子生命 +10%":
		push_error("final status: pet summary is not connected")
		get_tree().quit(1)
		return
	if not PetService.skill_detail_text("pet_tiger").contains("无限累计"):
		push_error("final status: pet detail is not connected")
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
	print("FINAL_STATUS_CHECK_OK")
	get_tree().quit(0)
