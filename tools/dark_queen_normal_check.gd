extends Node

# Exercise the shipped wrapper and all three corrected assets. No original FBX
# or machine-specific audit directory is needed. This also catches cloud merges
# that accidentally restore the old filenames or expose two actions at once.
const CheckHarness := preload("res://tools/CheckHarness.gd")
const MODEL_PATH := "res://assets/models/units/dark_queen_animated/dark_queen_animated.tscn"
const ACTIONS := ["idle", "attack", "run"]
const EXPECTED_TRIANGLES := 3054
const SAMPLE_COUNT := 8
const SAMPLE_INTERVAL := 0.025

var _h: CheckHarness


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new("dark_queen_normal")
	var packed := load(MODEL_PATH) as PackedScene
	if not _h.expect(packed != null, "queen_scene_missing", MODEL_PATH):
		_h.finish(get_tree())
		return
	var model := packed.instantiate() as Node3D
	if not _h.expect(model != null, "queen_root_invalid", MODEL_PATH):
		_h.finish(get_tree())
		return
	add_child(model)
	await get_tree().process_frame
	var action_nodes: Dictionary = model.get("action_nodes")
	var action_players: Dictionary = model.get("action_players")
	_h.expect(action_nodes.size() == 3, "queen_actions_missing",
		"Expected idle, attack and run; loaded %s." % str(action_nodes.keys()))
	for action in ACTIONS:
		var action_root := action_nodes.get(action) as Node3D
		var player := action_players.get(action) as AnimationPlayer
		if not _h.expect(action_root != null and player != null, "queen_action_unavailable", action):
			continue
		_h.expect(action_root.scene_file_path.ends_with("dark_queen_%s_smooth.fbx" % action),
			"queen_old_asset_selected", "%s loaded %s." % [action, action_root.scene_file_path])
		model.call("play_" + action)
		await get_tree().process_frame
		var geometry := _geometry_stats(action_root)
		_h.expect(int(geometry["triangles"]) == EXPECTED_TRIANGLES, "queen_topology_changed",
			"%s has %d triangles; expected %d." % [action, geometry["triangles"], EXPECTED_TRIANGLES])
		_h.expect(int(geometry["invalid_normals"]) == 0, "queen_invalid_normals", action)
		_h.expect(int(geometry["flat_faces"]) < EXPECTED_TRIANGLES * 0.05,
			"queen_flat_normals_regressed", "%s has %d flat-normal faces." % [action, geometry["flat_faces"]])
		var start_position := player.current_animation_position
		var previous_position := start_position
		var advanced := 0.0
		var stopped := 0
		var backward := 0
		var wrong_visibility := 0
		for _sample in SAMPLE_COUNT:
			await get_tree().create_timer(SAMPLE_INTERVAL).timeout
			if not player.is_playing():
				stopped += 1
			var position := player.current_animation_position
			if position > previous_position:
				advanced += position - previous_position
			elif position < previous_position - 0.001:
				backward += 1
			previous_position = position
			var visible_actions: Array[String] = []
			for key in action_nodes:
				var node := action_nodes[key] as Node3D
				if node != null and node.is_visible_in_tree():
					visible_actions.append(str(key))
			if visible_actions.size() != 1 or visible_actions[0] != action or _visible_mesh_count(model) != 1:
				wrong_visibility += 1
		_h.expect(stopped == 0, "queen_animation_stopped", "%s stopped in %d samples." % [action, stopped])
		_h.expect(advanced >= 0.1 and backward == 0, "queen_animation_did_not_advance",
			"%s advanced %.6f seconds with %d resets." % [action, advanced, backward])
		_h.expect(wrong_visibility == 0, "queen_actions_overlap",
			"%s has incorrect visible actions/meshes in %d samples." % [action, wrong_visibility])
		_h.note("%s: triangles=%d flat_faces=%d time=%.6f->%.6f advanced=%.6f stopped=%d visibility_errors=%d"
			% [action, geometry["triangles"], geometry["flat_faces"], start_position,
			previous_position, advanced, stopped, wrong_visibility])
	model.queue_free()
	await get_tree().process_frame
	_h.finish(get_tree())


func _visible_mesh_count(root: Node) -> int:
	var count := 0
	if root is MeshInstance3D and root.is_visible_in_tree():
		count += 1
	for child in root.get_children():
		count += _visible_mesh_count(child)
	return count


func _geometry_stats(root: Node) -> Dictionary:
	var result := {"triangles": 0, "flat_faces": 0, "invalid_normals": 0}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not node is MeshInstance3D or node.mesh == null:
			continue
		for surface in node.mesh.get_surface_count():
			var arrays: Array = node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if indices.is_empty():
				for i in vertices.size():
					indices.append(i)
			result["triangles"] += indices.size() / 3
			if normals.size() != vertices.size():
				result["invalid_normals"] += vertices.size()
				continue
			for normal in normals:
				if not normal.is_finite() or normal.length_squared() < 0.9 or normal.length_squared() > 1.1:
					result["invalid_normals"] += 1
			for i in range(0, indices.size() - 2, 3):
				var a := normals[indices[i]]
				var b := normals[indices[i + 1]]
				var c := normals[indices[i + 2]]
				if a.is_equal_approx(b) and a.is_equal_approx(c):
					result["flat_faces"] += 1
	return result
