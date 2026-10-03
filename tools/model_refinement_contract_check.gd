extends SceneTree
## Headless GodGuard refinement contract. Default acceptance requires four real
## BoneAttachment3D parts. --expected-attachments 0 is an explicit early-stage
## material/rig check only and is reported as such; it is not final acceptance.
const OLD_PATH := "res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_animated.tscn"
const NEW_PATH := "res://assets/models/units/god_guard_refined/god_guard_refined.tscn"
const UNIT_TABLE := "res://data/units/race_units.json"
# Frozen source hashes from the read-only 2026-10-03 baseline. Assets are supplied
# outside Git as well; these hashes do not pretend that every asset is tracked.
const ORIGINAL_HASHES := {
	OLD_PATH:"cc243f8f439c96c9a8fdde1e782c1b0d1d8300b396b81d329869bc764d4c5f65",
	"res://assets/models/units/god_guard_crystalbound/GodGuardCrystalboundAnimationTest.gd":"2d8eba446d8e0ae9614a48b1049e9899be2d75380ea878b34a9c39277b121450",
	"res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_body_material.tres":"7bb26958553eef1d0b7c1c2a6580bc59f9f2b0846002c19a53c9625384992f23",
	"res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_albedo.png":"a47df08bd9f9b64a4086887bd90fe32cee6eea445f44d0c7c21ece6a4b7fea96",
	"res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_emission.png":"7382a24172c8d669ab03a08b4fe97cc0b00f2275e63156f13cbd9e84778e8457",
	"res://shaders/character_toon.gdshader":"53710755959ad3e23c24676980a778f2fb3e1e7d9b81ec487047613407f39bbc",
	"res://shaders/character_outline.gdshader":"49e465839d3677f09a2328429248bfa4532d110a6233eb511a3a9a73f12b068f",
}
const BASE_DEFINITION := {"id":"god_guard","star4":{"shield_control_immune":true,"start_shield_pct":0.4,"taunt_radius":240},"name":"光之卫士","race":"god","element":"land","tier":2,"cost":30,"hp":1520,"atk":46,"def":14,"attack_speed":0.75,"range":1,"move_speed":3.0,"crit":0.05,"crit_dmg":1.5,"skill_id":"guardian_shield_taunt","start_shield_pct":0.2,"taunt_radius":180.0,"model_attack_animation_name":"attack","model_attack_sync_seek":0.35,"model_attack_lock_time":0.45,"model_run_animation_name":"run","model_visual_scale":1,"model_base_yaw":180,"name_en":"Lightguard"}

var _checks: Array[Dictionary] = []
var _failures: Array[String] = []
var _out := ""
var _expected_attachments := 4
var _require_integrated := false
var _report: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] in ["--out", "--expected-attachments"] and i+1 >= args.size():
			push_error("Missing value for " + args[i]); quit(2); return
		match args[i]:
			"--out": _out = args[i+1]
			"--expected-attachments": _expected_attachments = int(args[i+1])
			"--require-integrated": _require_integrated = true
	if _expected_attachments not in [0,4]:
		push_error("expected attachments must be 0 for early-stage diagnosis or 4 for acceptance")
		quit(2); return
	_report = {"scope":"model resources, rig, animation, attachment motion and data contract; not rendered visual or phone performance acceptance", "source_old":OLD_PATH,"source_new":NEW_PATH,"expected_attachments":_expected_attachments,"acceptance_scope":"final_asset_contract" if _expected_attachments==4 else "early_material_rig_only","require_integrated":_require_integrated,"source_hashes":{},"animation_samples":[],"attachments":[]}
	_report["refined_resource_hashes"] = {}
	for filename in DirAccess.get_files_at(NEW_PATH.get_base_dir()):
		if filename.ends_with(".import") or filename.ends_with(".uid"):continue
		var path := NEW_PATH.get_base_dir().path_join(filename)
		_report.refined_resource_hashes[path] = FileAccess.get_sha256(path)
	_report["contract_tool_sha256"] = FileAccess.get_sha256("res://tools/model_refinement_contract_check.gd")
	for path in ORIGINAL_HASHES:
		var actual := FileAccess.get_sha256(path)
		_report.source_hashes[path] = actual
		_check(actual == ORIGINAL_HASHES[path], "source_unchanged:"+str(path), actual)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(UNIT_TABLE))
	var definition: Dictionary = {}
	if parsed is Dictionary:
		for candidate in parsed.get("units",[]):
			if str(candidate.get("id","")) == "god_guard": definition = candidate.duplicate(true)
	var route := str(definition.get("model",""))
	_report["formal_model_route"] = route
	definition.erase("model")
	_check(definition == JSON.parse_string(JSON.stringify(BASE_DEFINITION)), "gameplay_and_animation_sync_unchanged", "Only model route may differ; attack sync remains 0.35, lock 0.45")
	_check(route in [OLD_PATH,NEW_PATH], "model_route_known", route)
	if _require_integrated: _check(route == NEW_PATH,"formal_route_is_refined",route)
	var old_packed := load(OLD_PATH) as PackedScene
	var new_packed := load(NEW_PATH) as PackedScene
	if not _check(old_packed != null and new_packed != null,"both_scenes_load",""):
		_finish(); return
	var old := old_packed.instantiate() as Node3D
	if not _check(old != null,"old_root_node3d",""):
		_finish(); return
	root.add_child(old)
	await process_frame
	var old_body := old.get_node_or_null("Skeleton3D/Mesh1_0") as MeshInstance3D
	var old_skeleton := old.get_node_or_null("Skeleton3D") as Skeleton3D
	var old_player := old.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if not _check(old_body != null and old_skeleton != null and old_player != null,"old_structure_available",""):
		old.free(); _finish(); return
	old_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var old_material_before := _material_signature(old_body.get_active_material(0))
	var old_geometry_before := _mesh_signature(old_body.mesh)
	var old_skin_before := _skin_signature(old_body.skin)
	var old_animation_before: Dictionary = {}
	for action in ["idle","run","attack"]:
		if old_player.has_animation(action): old_animation_before[action] = _animation_signature(old_player.get_animation(action))
	var refined := new_packed.instantiate() as Node3D
	if not _check(refined != null,"new_root_node3d",""):
		old.free(); _finish(); return
	root.add_child(refined)
	await process_frame
	await process_frame
	var new_body := refined.get_node_or_null("Skeleton3D/Mesh1_0") as MeshInstance3D
	var new_skeleton := refined.get_node_or_null("Skeleton3D") as Skeleton3D
	var new_player := refined.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if not _check(new_body != null and new_skeleton != null and new_player != null,"new_inherits_original_structure",""):
		old.free(); refined.free(); _finish(); return
	new_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_check(refined.find_children("*","Skeleton3D",true,false).size()==1 and new_body.get_node_or_null(new_body.skeleton)==new_skeleton,"body_uses_only_original_skeleton","")
	_check(old_material_before == _material_signature(old_body.get_active_material(0)),"old_runtime_material_not_mutated","")
	_check(old_geometry_before == _mesh_signature(old_body.mesh),"old_runtime_mesh_not_mutated","")
	_check(old_geometry_before == _mesh_signature(new_body.mesh),"body_geometry_uv_weights_preserved","")
	_check(old_skin_before == _skin_signature(old_body.skin) and old_skin_before == _skin_signature(new_body.skin),"skin_bind_names_poses_preserved","")
	_check(new_body.get_active_material(0) != old_body.get_active_material(0),"refined_body_material_independent","")
	_check(new_skeleton.get_bone_count()==83 and old_skeleton.get_bone_count()==83,"original_83_bones",str(new_skeleton.get_bone_count()))
	if old_skeleton.get_bone_count()==new_skeleton.get_bone_count():
		for i in old_skeleton.get_bone_count():
			_check(old_skeleton.get_bone_name(i)==new_skeleton.get_bone_name(i) and old_skeleton.get_bone_parent(i)==new_skeleton.get_bone_parent(i) and old_skeleton.get_bone_rest(i).is_equal_approx(new_skeleton.get_bone_rest(i)),"bone_name_parent_rest:"+str(i),new_skeleton.get_bone_name(i))
	for action in ["idle","run","attack"]:
		_check(refined.has_method("play_"+action),"play_interface:"+action,"")
		if _check(old_player.has_animation(action) and new_player.has_animation(action),"animation_present:"+action,""):
			_check(old_animation_before[action] == _animation_signature(new_player.get_animation(action)),"animation_length_tracks_keys:"+action,"")
			_check(old_animation_before[action] == _animation_signature(old_player.get_animation(action)),"old_runtime_animation_not_mutated:"+action,"")
	var attachments: Array[BoneAttachment3D] = []
	for node in refined.find_children("*","BoneAttachment3D",true,false): attachments.append(node as BoneAttachment3D)
	_check(attachments.size()==_expected_attachments,"attachment_count",str(attachments.size()))
	var baseline_attachment_poses: Dictionary = {}
	var moved: Dictionary = {}
	var attachment_materials: Dictionary = {}
	for attachment in attachments:
		var name_value := str(refined.get_path_to(attachment))
		var bone_index := new_skeleton.find_bone(attachment.bone_name)
		_check(attachment.get_parent()==new_skeleton and bone_index>=0 and attachment.bone_idx==bone_index,"attachment_valid_binding:"+name_value,str(attachment.bone_name))
		_check(not attachment.override_pose,"attachment_does_not_drive_skeleton:"+name_value,"")
		var meshes := attachment.find_children("*","MeshInstance3D",true,false)
		_check(not meshes.is_empty(),"attachment_has_geometry:"+name_value,"")
		for mesh_node in meshes:
			if mesh_node.mesh == null:continue
			for surface_index in mesh_node.mesh.get_surface_count():
				var material: Material = mesh_node.get_active_material(surface_index)
				attachment_materials[material.get_instance_id() if material != null else 0] = true
		_report.attachments.append({"path":name_value,"bone":str(attachment.bone_name),"bone_index":bone_index,"mesh_count":meshes.size()})
		moved[name_value] = false
	if not attachments.is_empty():
		_check(attachment_materials.size()==1 and not attachment_materials.has(0),"attachments_share_one_real_material",str(attachment_materials.size()))
	for action in ["idle","run","attack"]:
		if not old_player.has_animation(action) or not new_player.has_animation(action): continue
		for moment in [0.20,0.65,1.0]:
			old.call("play_"+action)
			refined.call("play_"+action)
			old_player.seek(moment,true); old_player.advance(0.0)
			new_player.seek(moment,true); new_player.advance(0.0)
			old_skeleton.force_update_all_bone_transforms()
			new_skeleton.force_update_all_bone_transforms()
			await process_frame
			var poses_match := true
			for i in mini(old_skeleton.get_bone_count(),new_skeleton.get_bone_count()):
				poses_match = poses_match and old_skeleton.get_bone_global_pose(i).is_equal_approx(new_skeleton.get_bone_global_pose(i))
			_check(poses_match,"animation_evaluated_pose:%s:%.2f"%[action,moment],"")
			var sample := {"action":action,"time":moment,"old_position":old_player.current_animation_position,"new_position":new_player.current_animation_position,"bone_poses_equal":poses_match,"attachments":[]}
			for attachment in attachments:
				var key := str(refined.get_path_to(attachment))
				var bone := new_skeleton.find_bone(attachment.bone_name)
				if bone < 0: continue
				var expected := new_skeleton.global_transform*new_skeleton.get_bone_global_pose(bone)
				_check(attachment.global_transform.is_equal_approx(expected),"attachment_follows_bone:%s:%s:%.2f"%[key,action,moment],"")
				if baseline_attachment_poses.has(key):
					moved[key] = bool(moved[key]) or not attachment.global_transform.is_equal_approx(baseline_attachment_poses[key])
				else: baseline_attachment_poses[key]=attachment.global_transform
				sample.attachments.append({"path":key,"bone":str(attachment.bone_name),"position":_v3(attachment.global_position)})
			_report.animation_samples.append(sample)
	for key in moved: _check(bool(moved[key]),"attachment_moves_with_animation:"+str(key),"")
	var stats := _geometry_stats(refined)
	_report["refined_geometry"] = stats
	_check(int(stats.surfaces)<=6,"surface_budget_max_6",str(stats.surfaces))
	_check(int(stats.materials)<=4,"material_budget_max_4",str(stats.materials))
	_check(int(stats.vertices)<=20000,"visible_vertex_budget_max_20000",str(stats.vertices))
	_check(int(stats.max_texture_edge)<=1024,"runtime_texture_max_1024",str(stats.max_texture_edge))
	_check(old_material_before==_material_signature(old_body.get_active_material(0)),"old_material_still_unchanged_after_motion","")
	old.free(); refined.free()
	await process_frame
	_finish()

func _check(ok: bool, name_value: String, detail: String) -> bool:
	_checks.append({"name":name_value,"passed":ok,"detail":detail})
	if not ok:
		_failures.append(name_value+": "+detail)
		print("MODEL_CONTRACT_FAIL ",name_value," ",detail)
	return ok

func _animation_signature(animation: Animation) -> String:
	var tracks: Array = []
	for i in animation.get_track_count():
		var keys: Array = []
		for k in animation.track_get_key_count(i): keys.append([animation.track_get_key_time(i,k),animation.track_get_key_value(i,k),animation.track_get_key_transition(i,k)])
		tracks.append([animation.track_get_type(i),str(animation.track_get_path(i)),animation.track_is_enabled(i),animation.track_get_interpolation_type(i),animation.track_get_interpolation_loop_wrap(i),keys])
	return var_to_bytes([animation.length,animation.loop_mode,animation.step,tracks]).hex_encode().sha256_text()

func _mesh_signature(mesh: Mesh) -> String:
	var values: Array = []
	for i in mesh.get_surface_count():
		values.append([mesh.surface_get_primitive_type(i),mesh.surface_get_arrays(i),mesh.surface_get_blend_shape_arrays(i)])
	return var_to_bytes(values).hex_encode().sha256_text()

func _skin_signature(skin: Skin) -> String:
	if skin == null:return "null"
	var binds: Array = []
	for i in skin.get_bind_count():
		binds.append([skin.get_bind_bone(i),str(skin.get_bind_name(i)),skin.get_bind_pose(i)])
	return var_to_bytes(binds).hex_encode().sha256_text()

func _material_signature(material: Material) -> String:
	if material == null:return "null"
	var properties: Dictionary = {}
	for property in material.get_property_list():
		var name_value := str(property.name)
		if name_value.begins_with("shader_parameter/") or name_value in ["shader","render_priority"]:
			var value: Variant = material.get(name_value)
			properties[name_value] = value.resource_path if value is Resource else value
	return var_to_bytes([material.resource_path,properties,_material_signature(material.next_pass)]).hex_encode().sha256_text()

func _geometry_stats(model: Node3D) -> Dictionary:
	var result := {"vertices":0,"triangles":0,"surfaces":0,"materials":0,"max_texture_edge":0}
	var materials: Dictionary = {}
	for node in model.find_children("*","MeshInstance3D",true,false):
		var mesh: Mesh = node.mesh
		if mesh == null:continue
		for i in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(i)
			result.vertices += arrays[Mesh.ARRAY_VERTEX].size()
			result.triangles += int(arrays[Mesh.ARRAY_INDEX].size()/3) if arrays[Mesh.ARRAY_INDEX]!=null and arrays[Mesh.ARRAY_INDEX].size()>0 else int(arrays[Mesh.ARRAY_VERTEX].size()/3)
			result.surfaces += 1
			var material: Material = node.get_active_material(i)
			while material != null:
				materials[material.get_instance_id()] = true
				for property in material.get_property_list():
					var value: Variant = material.get(str(property.name))
					if value is Texture2D: result.max_texture_edge = maxi(int(result.max_texture_edge),maxi(value.get_width(),value.get_height()))
				material=material.next_pass
	result.materials = materials.size()
	return result

func _v3(value: Vector3) -> Array:
	return [value.x,value.y,value.z]

func _finish() -> void:
	_report["checks"] = _checks
	_report["failures"] = _failures
	_report["passed"] = _failures.is_empty() and not _checks.is_empty()
	_report["checked"] = _checks.size()
	if not _out.is_empty():
		var file := FileAccess.open(_out,FileAccess.WRITE)
		if file == null:
			push_error("Cannot write contract report: "+_out); quit(2); return
		file.store_string(JSON.stringify(_report,"\t"))
	print("CHECK_RESULT name=model_refinement_contract status=%s checked=%d failures=%d scope=%s"%["PASS" if _report.passed else "FAIL",_checks.size(),_failures.size(),_report.acceptance_scope])
	quit(0 if _report.passed else 1)
