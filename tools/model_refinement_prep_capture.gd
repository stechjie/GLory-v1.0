extends SceneTree
## Real PrepScreen fixture; use a disposable project copy with:
## application/config/use_custom_user_dir=true
## application/config/custom_user_dir_name="glory-model-capture-<label>"
## Godot --path ISOLATED_PROJECT --rendering-method gl_compatibility \
##   --resolution 1600x720 --always-on-top --script res://tools/model_refinement_prep_capture.gd \
##   -- --out /absolute/evidence/path --variant old|new
## Reads the project's canonical unit table. Does not patch its model route.
const OLD_PATH := "res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_animated.tscn"
const NEW_PATH := "res://assets/models/units/god_guard_refined/god_guard_refined.tscn"
const PLACEMENTS := [
	{"id":"god_guard","zone":"board","slot":12,"star":1},
	{"id":"god_priest","zone":"board","slot":7,"star":1},
	{"id":"god_arbiter","zone":"board","slot":2,"star":1},
	# Two one-star guardians auto-combine in real PrepScreen._refresh_all().
	# Keep three distinct star tiers so the fixture survives normal game rules.
	{"id":"god_guard","zone":"bench","slot":3,"star":2},
	{"id":"god_guard","zone":"bench","slot":5,"star":4},
]
var _out := ""
var _variant := "new"
var _validate_only := false
var _probe_only := false
var _prep: Control
var _report: Dictionary = {}
var _failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] in ["--out","--variant"] and i+1 >= args.size():
			push_error("Missing capture argument value"); quit(2); return
		match args[i]:
			"--out": _out = ProjectSettings.globalize_path(args[i+1])
			"--variant": _variant = args[i+1]
			"--validate-fixture": _validate_only = true
			"--probe-nodes": _probe_only = true
	if _validate_only:
		await process_frame
		var registry := root.get_node("DataRegistry")
		registry.call("load_all")
		var fixture_definitions: Dictionary = {}
		for unit in registry.call("get_table","race_units").get("units",[]):
			fixture_definitions[str(unit.get("id",""))] = unit
		var state := root.get_node("GameState")
		var errors := _fixture_errors(state.get("board_slots"),state.get("bench_slots"),fixture_definitions)
		var fixture_report := {"scope":"headless fixture bounds and definitions only; does not validate rendered PrepScreen","passed":errors.is_empty(),"board_size":state.get("board_slots").size(),"bench_size":state.get("bench_slots").size(),"placements":PLACEMENTS,"failures":errors}
		if not _out.is_empty():
			DirAccess.make_dir_recursive_absolute(_out)
			var file := FileAccess.open(_out.path_join("prep-fixture-validation.json"),FileAccess.WRITE)
			if file == null:
				push_error("Cannot write fixture validation report"); quit(2); return
			file.store_string(JSON.stringify(fixture_report,"\t"))
		print("MODEL_PREP_FIXTURE_VALIDATION ",JSON.stringify(fixture_report))
		quit(0 if errors.is_empty() else 1); return
	if _out.is_empty() or _variant not in ["old","new"]:
		push_error("Model prep capture requires --out /absolute/path --variant old|new")
		quit(2); return
	if not OS.get_user_data_dir().contains("glory-model-capture-"):
		push_error("Model prep capture requires isolated glory-model-capture-* custom user directory")
		quit(2); return
	if DisplayServer.get_name()=="headless" and not _probe_only:
		push_error("Model prep capture needs real rendered pixels; headless cannot pass")
		quit(2); return
	if DirAccess.make_dir_recursive_absolute(_out)!=OK:
		push_error("Cannot create output directory"); quit(2); return
	await process_frame
	for service_name in ["NetworkService","RealtimeService","AnalyticsService","ChatService","AnnouncementService","MailService"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.set_process(false)
			service.set_physics_process(false)
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var data := root.get_node("DataRegistry")
	data.call("load_all")
	var definitions: Dictionary = {}
	for unit in data.call("get_table","race_units").get("units",[]): definitions[str(unit.get("id",""))]=unit
	var expected := OLD_PATH if _variant=="old" else NEW_PATH
	if str(definitions.get("god_guard",{}).get("model",""))!=expected:
		push_error("Canonical god_guard.model does not match requested variant; change only isolated copy's route or choose correct variant")
		quit(2); return
	var game := root.get_node("GameState")
	game.call("reset_run")
	game.set("round_index",7)
	game.set("gold",1043)
	game.set("player_formation_hp",49)
	game.set("enemy_formation_hp",15)
	game.set("carrots",12)
	game.set("last_harvest_round",7)
	var budget: Script = load("res://effects/vfx3d/core/VFXQualityBudget.gd")
	budget.set("tier",1)
	var board: Array = game.get("board_slots")
	var bench: Array = game.get("bench_slots")
	var fixture_errors := _fixture_errors(board,bench,definitions)
	if not fixture_errors.is_empty():
		_failures.append_array(fixture_errors)
		_report = {"scope":"fixture rejected before array assignment","variant":_variant,"board_size":board.size(),"bench_size":bench.size()}
		_finish(); return
	for placement in PLACEMENTS:
		var cell := {"uid":"model_capture_%s_%d"%[placement.zone,placement.slot],"id":placement.id,"star":placement.star,"def":definitions[placement.id].duplicate(true)}
		if placement.zone=="board":board[int(placement.slot)]=cell
		else:bench[int(placement.slot)]=cell
	game.set("board_slots",board)
	game.set("bench_slots",bench)
	var offers: Array = game.get("shop_offers")
	for i in offers.size(): offers[i]=definitions[["god_guard","god_priest","god_arbiter"][i%3]].duplicate(true)
	game.set("shop_offers",offers)
	root.size = Vector2i(1600,720)
	seed(20261003)
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	_prep=packed.instantiate() as Control
	root.add_child(_prep)
	var deadline := Time.get_ticks_msec()+(15000 if _probe_only else 90000)
	var next_diagnostic := Time.get_ticks_msec()+3000
	var ready := false
	while Time.get_ticks_msec()<deadline:
		await process_frame
		if _actors_ready():
			ready=true;break
		if Time.get_ticks_msec() >= next_diagnostic:
			print("MODEL_PREP_WAIT ",JSON.stringify(_actor_diagnostics()))
			next_diagnostic = Time.get_ticks_msec()+10000
	if not ready:
		_failures.append("Real PrepScreen actors failed readiness; see actor_diagnostics")
		_report = {"scope":"real PrepScreen actor node readiness; not a rendered screenshot","variant":_variant,"actor_diagnostics":_actor_diagnostics()}
		_finish();return
	# Let normal reveal/lighting settle, then seek only the idle animation used
	# by the real preparation view. No battle movement is injected into Prep.
	for i in 30: await process_frame
	var actors: Array = []
	for placement in PLACEMENTS:
		var actor := _actor_for(placement)
		var visual := _visual_for(actor)
		var definition: Dictionary = actor.get_meta("resolved_visual",{})
		var wanted := expected if placement.id=="god_guard" else str(definitions[placement.id].model)
		if str(definition.get("model",""))!=wanted or visual.scene_file_path!=wanted:
			_failures.append("Wrong real prep model for "+str(placement))
		if visual.has_method("play_idle"):visual.call("play_idle")
		var selected: Array = []
		for player in visual.find_children("*","AnimationPlayer",true,false):
			player.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
			if not player.current_animation.is_empty():
				var clip: Animation=player.get_animation(player.current_animation)
				player.seek(minf(0.8,maxf(0.0,clip.length-0.0001)),true)
				player.advance(0.0)
				selected.append({"path":str(visual.get_path_to(player)),"animation":str(player.current_animation),"time":player.current_animation_position})
		var feet: Variant = _prep.call("_prep_model_foot_center",visual)
		var foot_valid := feet is Vector3 and Vector2(feet.x,feet.z).length()<0.06
		if not foot_valid:_failures.append("Feet not centered in real prep actor "+str(placement))
		actors.append({"placement":placement,"actor_path":str(actor.get_path()),"resolved_model":definition.get("model",""),"visual_scene_path":visual.scene_file_path,"visual_kind":str(actor.get_meta("visual_kind","")),"actor_position":_v3(actor.global_position),"actor_scale":_v3(actor.global_basis.get_scale()),"visual_position":_v3(visual.position),"visual_scale":_v3(visual.scale),"foot_center":_v3(feet) if feet is Vector3 else null,"foot_center_check":foot_valid,"animations":selected,"meshes":_mesh_rows(visual)})
	_prep.process_mode=Node.PROCESS_MODE_DISABLED
	var viewport := _prep.get("_prep_river_viewport") as SubViewport
	_report={"scope":"actual PrepScreen presentation fixture, not a model-only stage or device performance test","variant":_variant,"canonical_guardian_model":expected,"renderer":RenderingServer.get_current_rendering_method(),"user_directory":OS.get_user_data_dir(),"window":str(root.size),"viewport":str(viewport.size),"scaling_3d_scale":viewport.scaling_3d_scale,"msaa_3d":viewport.msaa_3d,"network":"offline; service processing disabled","actors":actors,"source_unit_table_sha256":FileAccess.get_sha256("res://data/units/race_units.json")}
	_report["actor_diagnostics"] = _actor_diagnostics()
	if _probe_only:
		_report["scope"] = "headless real PrepScreen nodes, model route, idle pose and feet only; no rendered visual acceptance"
		_finish(); return
	for i in 4:
		viewport.render_target_update_mode=SubViewport.UPDATE_ONCE
		await process_frame
		await RenderingServer.frame_post_draw
	var screenshot := root.get_texture().get_image()
	var output_name := "prep-%s-1600x720.png"%_variant
	if screenshot==null or screenshot.is_empty() or screenshot.save_png(_out.path_join(output_name))!=OK:
		_failures.append("Failed to save real PrepScreen screenshot")
	_report["screenshot"]=output_name
	_finish()

func _fixture_errors(board: Array,bench: Array,definitions: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	var occupied: Dictionary = {}
	var merge_groups: Dictionary = {}
	for placement in PLACEMENTS:
		var zone := str(placement.get("zone",""))
		var slot := int(placement.get("slot",-1))
		var id := str(placement.get("id",""))
		if zone not in ["board","bench"]:
			errors.append("Invalid fixture zone: "+zone); continue
		var capacity := board.size() if zone == "board" else bench.size()
		if slot < 0 or slot >= capacity:
			errors.append("Fixture %s slot %d outside [0,%d)"%[zone,slot,capacity])
		var key := "%s:%d"%[zone,slot]
		if occupied.has(key): errors.append("Duplicate fixture slot: "+key)
		occupied[key] = true
		if not definitions.has(id): errors.append("Fixture unit is missing: "+id)
		var star := int(placement.get("star",0))
		if star < 1: errors.append("Invalid fixture star: "+key)
		if star >= 1 and star < GameConstants.MAX_MERGE_STAR:
			var merge_key := "%s:%d"%[id,star]
			merge_groups[merge_key] = int(merge_groups.get(merge_key,0))+1
			if int(merge_groups[merge_key]) >= GameConstants.copies_to_upgrade(star):
				errors.append("Fixture would auto-combine in real PrepScreen: "+merge_key)
	return errors

func _actor_for(placement: Dictionary) -> Node3D:
	var dictionary: Variant = _prep.get("_prep_board_model_nodes" if placement.zone=="board" else "_prep_standby_model_nodes")
	return dictionary.get(int(placement.slot)) as Node3D if dictionary is Dictionary else null

func _visual_for(actor: Node3D) -> Node3D:
	if actor == null: return null
	var visual_path := NodePath(str(actor.get_meta("prep_visual_root","")))
	return actor.get_node_or_null(visual_path) as Node3D if not visual_path.is_empty() else null

func _actor_diagnostics() -> Array:
	var rows: Array = []
	for placement in PLACEMENTS:
		var dictionary: Variant = _prep.get("_prep_board_model_nodes" if placement.zone=="board" else "_prep_standby_model_nodes")
		var actor := _actor_for(placement)
		var row := {"placement":placement,"dictionary_keys":dictionary.keys() if dictionary is Dictionary else [],"found":actor != null,"ready":false}
		var slots: Array = root.get_node("GameState").get("board_slots" if placement.zone=="board" else "bench_slots")
		var cell: Variant = slots[int(placement.slot)]
		row["live_cell"] = {"id":cell.get("id",""),"star":cell.get("star",0)} if cell is Dictionary else null
		if actor != null:
			var visual := _visual_for(actor)
			var pending := bool(actor.get_meta("prep_anchor_update_pending",false))
			var centered := bool(actor.get_meta("prep_model_centered",false))
			var meshes := visual.find_children("*","MeshInstance3D",true,false).size() if visual != null else 0
			row.merge({"actor_path":str(actor.get_path()),"visible_in_tree":actor.is_visible_in_tree(),"visible":actor.visible,"pending_meta_present":actor.has_meta("prep_anchor_update_pending"),"pending":pending,"centered":centered,"prep_visual_root":str(actor.get_meta("prep_visual_root","")),"visual_found":visual != null,"visual_scene_path":visual.scene_file_path if visual != null else "","resolved_model":actor.get_meta("resolved_visual",{}).get("model",""),"mesh_count":meshes,"ready":actor.is_visible_in_tree() and not pending and centered and visual != null and meshes > 0},true)
		rows.append(row)
	return rows

func _actors_ready() -> bool:
	for row in _actor_diagnostics():
		if not row.ready:return false
	return true

func _mesh_rows(visual: Node3D) -> Array:
	var rows: Array = []
	for node in visual.find_children("*","MeshInstance3D",true,false):
		var mesh: Mesh=node.mesh
		if mesh==null:continue
		var materials: Array=[]
		for i in mesh.get_surface_count():
			var material: Material=node.get_active_material(i)
			materials.append({"resource":material.resource_path if material else "null","shader":material.shader.resource_path if material is ShaderMaterial else "StandardMaterial3D"})
		rows.append({"node":str(visual.get_path_to(node)),"visible":node.is_visible_in_tree(),"surfaces":mesh.get_surface_count(),"materials":materials})
	return rows

func _v3(value: Vector3) -> Array:return [value.x,value.y,value.z]

func _finish() -> void:
	# Prep starts a real threaded BattleScreen preload. Let that finish before
	# engine shutdown; freeing Prep then awaiting a frame resumes its coroutine
	# on a destroyed instance and can interrupt the resource loader.
	if is_instance_valid(_prep):
		var battle_path := str(_prep.get("_battle_thread_path"))
		var deadline := Time.get_ticks_msec()+30000
		while not battle_path.is_empty() and ResourceLoader.load_threaded_get_status(battle_path)==ResourceLoader.THREAD_LOAD_IN_PROGRESS and Time.get_ticks_msec()<deadline:
			await process_frame
		if not battle_path.is_empty() and ResourceLoader.load_threaded_get_status(battle_path)==ResourceLoader.THREAD_LOAD_LOADED:
			_prep.call("_harvest_battle_scene")
	_report["failures"]=_failures
	_report["passed"]=_failures.is_empty() and _report.has("actors")
	var file:=FileAccess.open(_out.path_join("prep-%s-report.json"%_variant),FileAccess.WRITE)
	if file!=null:file.store_string(JSON.stringify(_report,"\t"))
	else:_failures.append("Cannot write prep report")
	print("MODEL_PREP_CAPTURE_COMPLETE passed=%s failures=%d output=%s"%[str(_report.get("passed",false)),_failures.size(),_out])
	quit(0 if _failures.is_empty() and _report.get("passed",false) else 1)
