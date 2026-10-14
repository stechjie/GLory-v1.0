extends Node
const Fixture = preload("res://scripts/qa/FixedBattleFixture.gd")
const Sim = preload("res://scripts/battle/BattleSimulator.gd")
const OUT := "E:/Users/WINDOWS/Desktop/其他/神圣脉冲特效_20261015/"
var records: Array = []
var captured := {}
var screen
var before := false
var max_live := 0
var failures := 0
func _ready() -> void:
	before = "--before" in OS.get_cmdline_user_args()
	for svc in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService"]:
		var n := get_tree().root.get_node_or_null(svc)
		if n != null: n.set_process(false)
	get_tree().root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	Fixture.setup_match_state(6, 20261015)
	var gods := ["god_priest", "god_priestess", "god_guard", "god_aurora", "god_angel", "god_arbiter", "god_archangel"]
	var b := Fixture.board_from_ids(gods)
	GameState.board_slots = b
	NetworkService.team_boards[0] = Fixture.board_submission(b, Fixture.empty_mercenary_slots())
	var replay := Sim.compute_team_replay(0, "god-pulse-20261015")
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(var_to_bytes(replay))
	var replay_hash := digest.finish().hex_encode()
	print("[PULSE] replay_sha256=", replay_hash)
	NetworkService.team_active = false
	NetworkService.team_replay_rival = {}
	GameState.set_pending_battle_package({"mode":"team_replay", "round_index":6, "replay":replay})
	screen = (load("res://scenes/battle/BattleScreen.tscn") as PackedScene).instantiate()
	add_child(screen)
	var cutoff := Time.get_ticks_msec() + 90000
	var last := -1
	while Time.get_ticks_msec() < cutoff:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		if not screen._battle_setup_ready: continue
		var frame: int = screen._replay_frame
		if frame == last: continue
		last = frame
		var row := {"frame":frame,"units":[]}
		var active := 0
		for uid in screen._replay_by_uid:
			var f: Dictionary = screen._replay_by_uid[uid]
			var status: Dictionary = f.get("statuses", {}).get("invulnerable", {})
			var expected := bool(f.get("alive",false)) and bool(status.get("dot_pass",false)) and float(status.get("remaining",0)) > 0
			var actor = screen._battle_3d_models.get(uid)
			var fx = actor.find_child("DivinePulseInvulnerability",true,false) if is_instance_valid(actor) else null
			var has_fx: bool = is_instance_valid(fx) and fx.visible and not fx.is_queued_for_deletion()
			if has_fx: active += 1
			if not before and expected != has_fx:
				failures += 1
				print("[PULSE] MISMATCH frame=", frame, " uid=", uid, " expected=", expected, " effect=", has_fx)
			if expected or has_fx:
				row.units.append({"uid":uid,"id":f.id,"remaining":status.get("remaining",0),"effect":has_fx,"resource":fx.get_script().resource_path if has_fx else ""})
		max_live = maxi(max_live,active)
		records.append(row)
		for shot in [{"tag":"start","frame":11},{"tag":"hold","frame":15},{"tag":"end","frame":23},{"tag":"repeat","frame":65}]:
			if frame >= shot.frame and not captured.has(shot.tag):
				get_viewport().get_texture().get_image().save_png(OUT + ("before_" if before else "after_") + shot.tag + ".png")
				captured[shot.tag] = true
		if frame >= 72 or screen._finished: break
	var report := {"before":before,"max_live":max_live,"failures":failures,"replay_sha256":replay_hash,"samples":records,"renderer":RenderingServer.get_current_rendering_method(),"gpu":RenderingServer.get_video_adapter_name(),"viewport":str(screen._battle_3d_viewport.size),"screenshots":captured.keys()}
	screen.queue_free()
	await get_tree().process_frame
	report["remaining_pulse_nodes"] = get_tree().get_nodes_in_group("divine_pulse_vfx").size()
	var file := FileAccess.open(OUT + ("before" if before else "after") + "_formal.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	print("[PULSE] finished max=",max_live," mismatches=",failures," shots=",captured.size())
	get_tree().quit(1 if failures > 0 or captured.size() != 4 else 0)


