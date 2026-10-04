extends SceneTree
## Export a unit wrapper's real runtime rig/mesh facts for refinement work.
## Godot --headless --path <project> --script res://tools/model_refinement/export_unit_reference.gd -- \
##   --model <wrapper scene res path> --unit-id <id> --out <dir>
##
## Writes <out>/rig.json and one <out>/reference_<k>.glb per distinct action rig.
## Nothing in the project is written.
##
## Space contract (all Godot, Y-up, wrapper-root units):
##  - bones[].global_rest is each bone's rest in wrapper-root space;
##  - reference_<k>.glb is skeleton k's body in its rest pose (upright), static,
##    albedo only. Every rig here binds at rest (checked: rest_bind_deviation),
##    so rest pose == undeformed bind mesh moved into root space;
##  - a part vertex v authored against reference_<k> attaches to bone B of that
##    rig with local = inverse(global_rest[B]) * v, and stores binds[B].pose so
##    the runtime only attaches it to a skeleton whose skin has the same bind.

var _args := {}


func _initialize() -> void:
	var raw := OS.get_cmdline_user_args()
	for i in raw.size():
		if raw[i].begins_with("--") and i + 1 < raw.size() and not raw[i + 1].begins_with("--"):
			_args[raw[i].substr(2)] = raw[i + 1]
	call_deferred("_run")


func _fail(message: String) -> void:
	push_error("UNIT_REFERENCE_ERROR " + message)
	quit(2)


func _run() -> void:
	for key in ["model", "unit-id", "out"]:
		if not _args.has(key):
			_fail("missing --" + key)
			return
	var packed := load(str(_args.model)) as PackedScene
	if packed == null:
		_fail("cannot load " + str(_args.model))
		return
	var model := packed.instantiate() as Node3D
	root.add_child(model)
	await process_frame
	await process_frame
	for player in model.find_children("*", "AnimationPlayer", true, false):
		(player as AnimationPlayer).stop()
	var out := str(_args.out)
	DirAccess.make_dir_recursive_absolute(out)
	var skeletons: Array = []
	var references := {}
	for found in model.find_children("*", "Skeleton3D", true, false):
		var skeleton := found as Skeleton3D
		skeleton.reset_bone_poses()
		var row := _skeleton_row(model, skeleton)
		if row.is_empty():
			continue
		if float(row.rest_bind_deviation) > 0.001:
			_fail("%s does not bind at rest (%.4f); the upright reference contract would be wrong" % [row.path, row.rest_bind_deviation])
			return
		var key := "%s|%s" % [row.mesh_fingerprint, JSON.stringify(row.upright)]
		if not references.has(key):
			var file := "reference_%d.glb" % references.size()
			if not _export_reference(row.body, row.upright_xform, out.path_join(file)):
				_fail("cannot write " + file)
				return
			references[key] = file
		row.reference = references[key]
		row.erase("body")
		row.erase("upright_xform")
		skeletons.append(row)
	var clips: Array = []
	for found in model.find_children("*", "AnimationPlayer", true, false):
		var player := found as AnimationPlayer
		var list: Array = []
		for name in player.get_animation_list():
			var clip := player.get_animation(name)
			list.append({"name": str(name), "length": clip.length, "loop_mode": clip.loop_mode, "tracks": clip.get_track_count()})
		clips.append({"player": str(model.get_path_to(player)), "animations": list})
	var report := {"unit_id": str(_args["unit-id"]), "model": str(_args.model), "godot": Engine.get_version_info().string,
		"coordinate_contract": "See header of res://tools/model_refinement/export_unit_reference.gd.",
		"skeletons": skeletons, "animation_players": clips}
	var json := FileAccess.open(out.path_join("rig.json"), FileAccess.WRITE)
	json.store_string(JSON.stringify(report, "\t"))
	json.close()
	var summary: Array = []
	for row in skeletons:
		summary.append("%s->%s aabb=%s" % [row.path.get_slice("/", 1) if row.path.contains("/") else row.path, row.reference, row.upright_aabb])
	print("UNIT_REFERENCE_COMPLETE unit=%s skeletons=%d references=%d %s" % [_args["unit-id"], skeletons.size(), references.size(), " | ".join(summary)])
	model.free()
	quit(0)


func _root_xform(model: Node3D, node: Node3D) -> Transform3D:
	return model.global_transform.affine_inverse() * node.global_transform


func _xform_dict(t: Transform3D) -> Dictionary:
	return {"basis_x": [t.basis.x.x, t.basis.x.y, t.basis.x.z], "basis_y": [t.basis.y.x, t.basis.y.y, t.basis.y.z],
		"basis_z": [t.basis.z.x, t.basis.z.y, t.basis.z.z], "origin": [t.origin.x, t.origin.y, t.origin.z]}


func _skeleton_row(model: Node3D, skeleton: Skeleton3D) -> Dictionary:
	var body: MeshInstance3D = null
	for found in skeleton.find_children("*", "MeshInstance3D", true, false):
		var candidate := found as MeshInstance3D
		if candidate.skin != null and candidate.mesh != null and candidate.get_node_or_null(candidate.skeleton) == skeleton:
			body = candidate
			break
	if body == null:
		return {}
	var to_root := _root_xform(model, skeleton)
	var bones: Array = []
	for i in skeleton.get_bone_count():
		bones.append({"name": skeleton.get_bone_name(i), "parent": skeleton.get_bone_parent(i),
			"global_rest": _xform_dict(to_root * skeleton.get_bone_global_rest(i))})
	# rest * bind is the same rigid transform for every bone exactly when the rig
	# binds at its rest pose; that transform moves the bind mesh upright into root space.
	var binds: Array = []
	var upright := Transform3D()
	var deviation := 0.0
	for b in body.skin.get_bind_count():
		var bone := body.skin.get_bind_bone(b)
		if bone < 0:
			bone = skeleton.find_bone(body.skin.get_bind_name(b))
		if bone < 0:
			continue
		var pose := body.skin.get_bind_pose(b)
		var candidate := to_root * skeleton.get_bone_global_rest(bone) * pose
		if binds.is_empty():
			upright = candidate
		else:
			deviation = maxf(deviation, maxf(maxf((candidate.basis.x - upright.basis.x).length(), (candidate.basis.y - upright.basis.y).length()),
				maxf((candidate.basis.z - upright.basis.z).length(), (candidate.origin - upright.origin).length())))
		binds.append({"bone": skeleton.get_bone_name(bone), "pose": _xform_dict(pose)})
	var aabb := upright * body.mesh.get_aabb()
	return {"path": str(model.get_path_to(skeleton)), "bone_count": bones.size(), "body": body, "upright_xform": upright,
		"mesh": {"vertices": _vertex_count(body.mesh), "triangles": _triangle_count(body.mesh), "surfaces": body.mesh.get_surface_count()},
		"mesh_fingerprint": _mesh_fingerprint(body.mesh), "rest_bind_deviation": deviation, "upright": _xform_dict(upright),
		"upright_aabb": {"min": [aabb.position.x, aabb.position.y, aabb.position.z], "max": [aabb.end.x, aabb.end.y, aabb.end.z]},
		"bones": bones, "binds": binds}


func _vertex_count(mesh: Mesh) -> int:
	var total := 0
	for s in mesh.get_surface_count():
		total += (mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return total


func _triangle_count(mesh: Mesh) -> int:
	var total := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		total += (indices as PackedInt32Array).size() / 3 if indices != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return total


func _mesh_fingerprint(mesh: Mesh) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for s in mesh.get_surface_count():
		ctx.update((mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).to_byte_array())
	return ctx.finish().hex_encode().substr(0, 16)


func _export_reference(body: MeshInstance3D, upright: Transform3D, path: String) -> bool:
	var out_mesh := ArrayMesh.new()
	for s in body.mesh.get_surface_count():
		var arrays := body.mesh.surface_get_arrays(s)
		var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var normals := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
		var moved := PackedVector3Array()
		var turned := PackedVector3Array()
		moved.resize(verts.size())
		turned.resize(verts.size())
		for v in verts.size():
			moved[v] = upright * verts[v]
			turned[v] = (upright.basis * normals[v]).normalized()
		var plain := []
		plain.resize(Mesh.ARRAY_MAX)
		plain[Mesh.ARRAY_VERTEX] = moved
		plain[Mesh.ARRAY_NORMAL] = turned
		plain[Mesh.ARRAY_TEX_UV] = arrays[Mesh.ARRAY_TEX_UV]
		plain[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
		out_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, plain)
		var albedo: Texture2D = null
		var material := body.get_active_material(s)
		if material is ShaderMaterial:
			albedo = (material as ShaderMaterial).get_shader_parameter("albedo_texture") as Texture2D
		elif material is BaseMaterial3D:
			albedo = (material as BaseMaterial3D).albedo_texture
		var standard := StandardMaterial3D.new()
		standard.albedo_texture = albedo
		out_mesh.surface_set_material(s, standard)
	var scene_root := Node3D.new()
	scene_root.name = "reference"
	var instance := MeshInstance3D.new()
	instance.name = "OriginalBodyRest"
	instance.mesh = out_mesh
	scene_root.add_child(instance)
	instance.owner = scene_root
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_scene(scene_root, state)
	if error == OK:
		error = document.write_to_filesystem(state, path)
	scene_root.free()
	return error == OK
