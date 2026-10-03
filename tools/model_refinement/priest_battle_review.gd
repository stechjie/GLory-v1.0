extends Node
# Uses actual simulation and BattleScreen. Run in a disposable project with
# custom_user_dir_name=GLoryPriestReview. Canonical definitions are never patched.
var screen
var output=""
var samples=[]
var shots={}
var actors_seen={}
var animations={}
var errors=[]
func _ready():call_deferred("run")
func run():
	if not str(ProjectSettings.get_setting("application/config/custom_user_dir_name","" )).begins_with("GLoryPriestReview"):push_error("Requires isolated GLoryPriestReview user directory");get_tree().quit(2);return
	var args=OS.get_cmdline_user_args();output=args[args.find("--out")+1]
	DirAccess.make_dir_recursive_absolute(output)
	for name in ["NetworkService","RealtimeService","AnalyticsService","ChatService","AnnouncementService","MailService","VoiceService","AccountManager"]:
		var service=get_tree().root.get_node_or_null(name)
		if service:service.process_mode=Node.PROCESS_MODE_DISABLED
	get_tree().root.multiplayer.multiplayer_peer=OfflineMultiplayerPeer.new()
	DataRegistry.load_all()
	var fixture=load("res://scripts/qa/FixedBattleFixture.gd")
	var round_index=int(args[args.find("--round")+1]) if "--round" in args else 1
	fixture.setup_match_state(round_index,20261003)
	# Character-specific fixed lineup; leave the shared frozen QA fixture intact.
	var board=fixture.board_from_ids(["god_priest","god_priestess","god_angel","god_guard"])
	board[12]=board[1];board[1]=null
	GameState.board_slots=board
	NetworkService.team_boards[0]=fixture.board_submission(board,fixture.empty_mercenary_slots())
	if round_index == 6:
		for lane in [1,2,4,5]:NetworkService.team_boards[lane]=fixture.board_submission(fixture.board_from_ids([]),fixture.empty_mercenary_slots())
		NetworkService.team_boards[3]=fixture.board_submission(fixture.board_from_ids(["human_swordsman","human_archer","human_cleric"]),fixture.empty_mercenary_slots())
	if "--movement" in args:
		# Legal sparse boards in distant lanes force a natural approach without
		# changing range, speed, damage, simulation positions or random state.
		for lane in range(6):NetworkService.team_boards[lane]=fixture.board_submission(fixture.board_from_ids([]),fixture.empty_mercenary_slots())
		NetworkService.team_boards[0]=fixture.board_submission(fixture.board_from_ids(["god_priest"]),fixture.empty_mercenary_slots())
		NetworkService.team_boards[5]=fixture.board_submission(fixture.board_from_ids(["human_archer"]),fixture.empty_mercenary_slots())
	var replay=load("res://scripts/battle/BattleSimulator.gd").compute_team_replay(0,"priest-review:20261003")
	NetworkService.team_active=false;NetworkService.team_replay_rival={}
	GameState.set_pending_battle_package({"mode":"team_replay","round_index":round_index,"replay":replay})
	screen=load("res://scenes/battle/BattleScreen.tscn").instantiate();get_tree().root.add_child(screen)
	var start=Time.get_ticks_msec();var last=-1;var complete=false
	while Time.get_ticks_msec()-start<150000 and is_instance_valid(screen):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		if not screen.get("_battle_setup_ready"):
			if screen.get("_finished"):errors.append("Battle preparation failed before ready");break
			continue
		var frame=int(screen.get("_replay_frame"))
		if frame==last:continue
		last=frame
		var row={"frame":frame,"priests":[]}
		var fighters:Dictionary=screen.get("_replay_by_uid")
		for uid in fighters:
			var f=fighters[uid]
			if f.get("id","")!="god_priest":continue
			var actor=screen.get("_unit_actor_registry").get_actor(str(uid))
			if not is_instance_valid(actor):continue
			var visual=actor.get("visual_root")
			if not is_instance_valid(visual):continue
			var a={"uid":uid,"model":visual.scene_file_path,"position":str(actor.position),"anchors":{},"animation":[]}
			for anchor in ["FootAnchor","CastAnchor","HitAnchor"]:
				var node=actor.get_node_or_null(anchor)
				if node:a.anchors[anchor]=str(node.position)
			for player in visual.find_children("*","AnimationPlayer",true,false):
				if player.is_playing():
					a.animation.append({"name":str(player.current_animation),"time":player.current_animation_position})
					animations[str(player.current_animation)]=true
			actors_seen[uid]=a;row.priests.append(a)
		samples.append(row)
		for threshold in [1,15,40,80,160,240]:
			if frame>=threshold and not shots.has(threshold):
				var file="battle-%03d.png"%threshold
				get_viewport().get_texture().get_image().save_png(output.path_join(file));shots[threshold]=file
		if frame>=replay.frames.size():complete=true;break
	if not complete:errors.append("Replay did not complete before timeout")
	if actors_seen.is_empty():errors.append("No priest actor observed")
	for a in actors_seen.values():
		var expected="res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn" if "--old" in args else "res://assets/models/units/god_priest_refined/god_priest_refined.tscn"
		if a.model!=expected:errors.append("Unexpected model "+a.model)
	var report={"scope":"offline actual BattleSimulator -> BattleScreen -> UnitActor3D, not online/mobile validation","completed":complete,"frames":replay.frames.size(),"actors":actors_seen,"animations":animations.keys(),"samples":samples,"screenshots":shots,"errors":errors,"renderer":RenderingServer.get_current_rendering_method(),"gpu":RenderingServer.get_video_adapter_name()}
	FileAccess.open(output.path_join("battle-report.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"));print("PRIEST_BATTLE ",complete," actors=",actors_seen.size()," errors=",errors)
	screen.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0 if errors.is_empty() else 1)
