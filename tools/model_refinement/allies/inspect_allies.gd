extends SceneTree
# Inventory of formation-ally wrappers: per action mesh / surface / vert / tri,
# skeleton, animation clips, and material textures. Prints one JSON document.
# Usage: godot --headless --path <proj> --script res://tools/inspect_allies.gd -- [--models a.tscn,b.tscn]

const DEFAULT_MODELS := [
	"res://assets/models/allies/formation_ally_1_animated/formation_ally_1_animated.tscn",
	"res://assets/models/allies/formation_ally_2_animated/formation_ally_2_animated.tscn",
	"res://assets/models/allies/formation_ally_3_animated/formation_ally_3_animated.tscn",
	"res://assets/models/allies/formation_ally_4_animated/formation_ally_4_animated.tscn",
	"res://assets/models/allies/formation_ally_5_animated/formation_ally_5_animated.tscn",
]

func _initialize() -> void:
	var models: Array = DEFAULT_MODELS
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--models" and i + 1 < args.size():
			models = Array(args[i + 1].split(","))
	var report := []
	for path in models:
		var scene := load(path) as PackedScene
		var root := scene.instantiate() as Node3D
		get_root().add_child(root)
		await process_frame
		await process_frame
		report.append(_inspect(path, root))
		root.queue_free()
		await process_frame
	print("INSPECT_JSON=" + JSON.stringify(report))
	quit(0)

func _inspect(path: String, root: Node3D) -> Dictionary:
	var out := {"path": path, "actions": {}}
	var action_nodes: Dictionary = root.get("action_nodes") if root.get("action_nodes") != null else {}
	var total_tris := 0
	var total_surfaces := 0
	for action in action_nodes.keys():
		var node := action_nodes[action] as Node3D
		var info := {"meshes": [], "skeletons": [], "anims": {}}
		var stack: Array[Node] = [node]
		var aabb := AABB()
		var first := true
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
				var mi := n as MeshInstance3D
				var verts := 0
				var tris := 0
				for s in mi.mesh.get_surface_count():
					var arr := mi.mesh.surface_get_arrays(s)
					var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
					verts += v.size()
					var idx = arr[Mesh.ARRAY_INDEX]
					tris += (idx.size() / 3) if idx != null and idx.size() > 0 else v.size() / 3
				total_tris += tris
				total_surfaces += mi.mesh.get_surface_count()
				var mat := mi.get_surface_override_material(0)
				var tex_info := {}
				if mat is ShaderMaterial:
					for p in ["albedo_texture", "normal_map_texture", "emission_mask"]:
						var t = (mat as ShaderMaterial).get_shader_parameter(p)
						if t is Texture2D:
							tex_info[p] = "%s %dx%d" % [t.resource_path.get_file(), t.get_width(), t.get_height()]
				var gx := mi.global_transform * mi.get_aabb()
				aabb = gx if first else aabb.merge(gx)
				first = false
				info.meshes.append({"name": String(mi.name), "surfaces": mi.mesh.get_surface_count(), "verts": verts, "tris": tris,
					"blend_shapes": mi.mesh.get_blend_shape_count() if mi.mesh is ArrayMesh else 0,
					"skin": mi.skin != null, "material": tex_info})
			if n is Skeleton3D:
				var sk := n as Skeleton3D
				var names := []
				for b in sk.get_bone_count():
					names.append(sk.get_bone_name(b))
				info.skeletons.append({"name": String(sk.name), "bones": sk.get_bone_count(), "names_hash": str(names).hash(), "first": names.slice(0, 6)})
			if n is AnimationPlayer:
				var ap := n as AnimationPlayer
				for a in ap.get_animation_list():
					var anim := ap.get_animation(a)
					info.anims[String(a)] = snappedf(anim.length, 0.001)
		info["aabb"] = [aabb.position, aabb.size]
		out.actions[action] = info
	out["resident_tris"] = total_tris
	out["resident_surfaces"] = total_surfaces
	return out
