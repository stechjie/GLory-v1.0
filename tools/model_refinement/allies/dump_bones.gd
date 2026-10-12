extends SceneTree
# Bone names + rest position in wrapper/model space for each action model of a refined wrapper.
func _initialize() -> void:
	for path in OS.get_cmdline_user_args():
		var w := (load(path) as PackedScene).instantiate() as Node3D
		get_root().add_child(w)
		await process_frame
		var nodes: Dictionary = w.get("action_nodes")
		for action in nodes.keys():
			var node := nodes[action] as Node3D
			var sk := node.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
			var line := "BONES %s %s n=%d :" % [path.get_file().get_basename(), action, sk.get_bone_count()]
			for b in sk.get_bone_count():
				var p := w.global_transform.affine_inverse() * sk.global_transform * sk.get_bone_global_rest(b).origin
				line += " %s(%.2f,%.2f,%.2f)" % [sk.get_bone_name(b), p.x, p.y, p.z]
			print(line)
		w.queue_free()
	quit(0)
