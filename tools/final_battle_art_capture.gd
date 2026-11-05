extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService", "VoiceService", "AccountManager"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.process_mode = Node.PROCESS_MODE_DISABLED
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	root.get_node("DataRegistry").load_all()
	var fixture = load("res://scripts/qa/FixedBattleFixture.gd")
	var game = root.get_node("GameState")
	fixture.setup_match_state(21, 20260823)
	var replay = load("res://scripts/battle/BattleSimulator.gd").compute_team_replay(0, "final-background-review")
	root.get_node("NetworkService").team_active = false
	game.set_pending_battle_package({"mode":"team_replay", "round_index":21, "replay":replay})
	var screen = load("res://scenes/battle/BattleScreen.tscn").instantiate()
	root.add_child(screen)
	var deadline := Time.get_ticks_msec() + 120000
	while not screen.get("_battle_setup_ready"):
		if Time.get_ticks_msec() > deadline:
			push_error("Battle setup timeout")
			quit(1)
			return
		await process_frame
	print("FINAL_ART_READY kind=", screen.call("_battlefield_kind"), " path=", screen.call("_battlefield_base_path"), " roster=", replay.get("roster", {}).size())
	var out := "res://reports/final_battle_background_20261105/"
	screen.set_process(false)
	screen.call("_apply_replay_frame", 0)
	screen.call("_refresh_visuals")
	screen.call("_update_3v3_dividers")
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out + "formation.png")
	print("FINAL_ART_CAPTURE formation")
	screen.set_process(true)
	await create_timer(2.3).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out + "opening.png")
	print("FINAL_ART_CAPTURE opening frame=", screen.get("_replay_frame"))
	await create_timer(4.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out + "combat.png")
	print("FINAL_ART_CAPTURE combat frame=", screen.get("_replay_frame"))
	screen.queue_free()
	await process_frame
	quit()
