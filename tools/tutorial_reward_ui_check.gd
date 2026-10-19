extends Node

# Small, network-free contract check for the first level reward reveal.
func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var script := load("res://scenes/menu/LevelUpRewardDialog.gd") as GDScript
	var dialog := script.new() as Control
	dialog.call("configure", [2], [{"level": 2, "units": ["god_priest"],
		"coin": 0, "diamond": 0, "prep_prompt": false}])
	add_child(dialog)
	await get_tree().process_frame
	var reveal := dialog.call("tutorial_reveal_target") as Button
	if reveal == null or not reveal.is_visible_in_tree():
		_fail("reveal action missing")
		return
	var flags := {"announced": false, "received": false}
	dialog.connect("revealed", func() -> void: flags["announced"] = true)
	reveal.pressed.emit()
	await get_tree().process_frame
	var claim := dialog.call("tutorial_claim_target") as Button
	if not bool(flags["announced"]) or claim == null or not claim.is_visible_in_tree():
		_fail("claim action missing after reveal")
		return
	dialog.connect("claimed", func(_go_prep: bool) -> void: flags["received"] = true)
	claim.pressed.emit()
	await get_tree().process_frame
	if not bool(flags["received"]):
		_fail("claim signal missing")
		return
	dialog.queue_free()
	DataRegistry.load_all()
	var progression := (load("res://scenes/menu/ProgressionPanel.gd") as GDScript).new() as Control
	add_child(progression)
	await get_tree().process_frame
	progression.call("_show_state", {"level": 1, "xp": 0, "level_xp": 0, "next_xp": 60,
		"rewards": [
			{"level": 4, "units": ["god_priestess", "god_guard"]},
			{"level": 6, "units": ["god_aurora", "god_angel"]},
			{"level": 8, "units": ["god_arbiter", "god_archangel"]},
		]})
	for level in [4, 6, 8]:
		progression.call("_select_level", level)
		var detail := progression.get("_detail") as HBoxContainer
		var portrait_count := (detail.get_child(0) as Control).find_children("*", "TextureRect", true, false).size()
		if portrait_count != 2:
			_fail("level %d should preview two Divine portraits, found %d" % [level, portrait_count])
			return
	progression.queue_free()
	var result := (load("res://scenes/menu/GameOverScreen.gd") as GDScript).new() as Control
	result.set("result_kind", "win")
	result.set("show_details", true)
	result.set("tutorial_result", true)
	add_child(result)
	await get_tree().process_frame
	if result.call("tutorial_menu_target") == null:
		_fail("tutorial result lost Main Menu button when details are available")
		return
	result.queue_free()
	var menu := (load("res://scenes/menu/MainMenu.tscn") as PackedScene).instantiate() as Control
	add_child(menu)
	await get_tree().process_frame
	for method in ["tutorial_profile_target", "tutorial_prep_target"]:
		var target := menu.call(method) as Control
		if target == null or not target.is_visible_in_tree() or target.size.x < 100:
			_fail("menu guide target missing: " + method)
			return
	menu.queue_free()
	var prep := (load("res://scenes/menu/PetScreen.tscn") as PackedScene).instantiate() as Control
	add_child(prep)
	await get_tree().process_frame
	for method in ["tutorial_pet_target", "tutorial_race_tab_target", "tutorial_god_target"]:
		if prep.call(method) == null:
			_fail("prep guide target missing: " + method)
			return
	print("CHECK_RESULT name=tutorial_reward_ui status=PASS checked=12 failures=0")
	get_tree().quit(0)


func _fail(reason: String) -> void:
	push_error(reason)
	print("CHECK_RESULT name=tutorial_reward_ui status=FAIL reason=" + reason)
	get_tree().quit(1)
