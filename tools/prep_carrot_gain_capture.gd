extends Node


func _ready() -> void:
	var output := OS.get_environment("PREP_CARROT_GAIN_CAPTURE_PATH")
	if output.is_empty():
		push_error("PREP_CARROT_GAIN_CAPTURE_PATH is required")
		get_tree().quit(2)
		return
	GameState.reset_run()
	NetworkService.team_active = false
	var starter_pets := PetService.starter_ids()
	assert(not starter_pets.is_empty())
	PlayerProfile.active_pet = str(starter_pets[0])
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	assert(packed != null)
	var prep := packed.instantiate()
	add_child(prep)
	for _frame in 12:
		await get_tree().process_frame
	prep.call("refresh_carrot_gathering")
	for _frame in 8:
		await get_tree().process_frame
	prep.call("play_carrot_harvest_feedback", {4: 3})
	await get_tree().create_timer(0.28).timeout
	var image := get_viewport().get_texture().get_image()
	assert(image != null and not image.is_empty())
	assert(image.save_png(output) == OK)
	print("PREP_CARROT_GAIN_CAPTURE_OK %s" % output)
	get_tree().quit()

