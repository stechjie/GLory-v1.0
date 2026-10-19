extends SceneTree

# Small, network-free contract check for the first level reward reveal.
func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var script := load("res://scenes/menu/LevelUpRewardDialog.gd") as GDScript
	var dialog := script.new() as Control
	dialog.call("configure", [2], [{"level": 2, "units": ["god_priest"],
		"coin": 0, "diamond": 0, "prep_prompt": false}])
	root.add_child(dialog)
	await process_frame
	var reveal := dialog.call("tutorial_reveal_target") as Button
	if reveal == null or not reveal.is_visible_in_tree():
		_fail("reveal action missing")
		return
	var flags := {"announced": false, "received": false}
	dialog.connect("revealed", func() -> void: flags["announced"] = true)
	reveal.pressed.emit()
	await process_frame
	var claim := dialog.call("tutorial_claim_target") as Button
	if not bool(flags["announced"]) or claim == null or not claim.is_visible_in_tree():
		_fail("claim action missing after reveal")
		return
	dialog.connect("claimed", func(_go_prep: bool) -> void: flags["received"] = true)
	claim.pressed.emit()
	await process_frame
	if not bool(flags["received"]):
		_fail("claim signal missing")
		return
	dialog.queue_free()
	var menu := (load("res://scenes/menu/MainMenu.tscn") as PackedScene).instantiate() as Control
	root.add_child(menu)
	await process_frame
	for method in ["tutorial_profile_target", "tutorial_prep_target"]:
		var target := menu.call(method) as Control
		if target == null or not target.is_visible_in_tree() or target.size.x < 100:
			_fail("menu guide target missing: " + method)
			return
	menu.queue_free()
	var prep := (load("res://scenes/menu/PetScreen.tscn") as PackedScene).instantiate() as Control
	root.add_child(prep)
	await process_frame
	for method in ["tutorial_pet_target", "tutorial_race_tab_target", "tutorial_god_target"]:
		if prep.call(method) == null:
			_fail("prep guide target missing: " + method)
			return
	print("CHECK_RESULT name=tutorial_reward_ui status=PASS checked=8 failures=0")
	quit(0)


func _fail(reason: String) -> void:
	push_error(reason)
	print("CHECK_RESULT name=tutorial_reward_ui status=FAIL reason=" + reason)
	quit(1)
