extends SceneTree
## Reports the runtime albedo wiring of the refined priestess plus the dark texel
## and dark triangle-centre counts for all three actions.
##
## The albedo is read with Image.load_from_file(resource_path) instead of
## Texture2D.get_image(): the imported .png becomes a VRAM-compressed (s3tc)
## texture, and get_pixel() on it logs one ERROR per texel (a 38 MB log in the
## original probe run). Reading the source PNG gives the pre-import pixels and
## still asserts which texture the material is actually wired to.
## Usage: godot --headless --path . --script tools/model_refinement/priestess_texture_probe.gd -- [--out <abs-json>]
func _initialize(): call_deferred("run")

func run():
	var args := OS.get_cmdline_user_args()
	var out: String = args[args.find("--out") + 1] if "--out" in args else ""

	var scene = load("res://assets/models/units/god_priestess_refined/god_priestess_refined.tscn").instantiate()
	root.add_child(scene)
	scene.set_process(false)
	for p in scene.find_children("*", "AnimationPlayer", true, false):
		p.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL

	var tex: Texture2D = scene.REFINED_BODY.get_shader_parameter("albedo_texture")
	print("WIRED_TEXTURE ", tex.resource_path, " size=", tex.get_width(), "x", tex.get_height())

	var img := Image.load_from_file(tex.resource_path)
	if img == null:
		push_error("LOAD_FAILED " + str(tex.resource_path)); quit(1); return
	var w := img.get_width(); var h := img.get_height()
	var bins := {"dark": 0, "total": w * h}
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.r + c.g + c.b < 0.08: bins.dark += 1
	print("TEXTURE_BINS ", JSON.stringify(bins), " texture_path=", tex.resource_path)

	var report := {"wired_texture_path": tex.resource_path, "texture_size": [w, h], "texture_bins": bins, "actions": {}}
	for action in ["idle", "run", "attack"]:
		scene.call("play_" + action)
		var mis: Array = scene.action_nodes[action].find_children("*", "MeshInstance3D", true, false)
		var mesh: Mesh = mis[0].mesh
		var dark := 0; var total := 0; var rows := []
		for s in mesh.get_surface_count():
			var a: Array = mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			var uvs: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
			for i in range(0, idx.size(), 3):
				var uv: Vector2 = (uvs[idx[i]] + uvs[idx[i + 1]] + uvs[idx[i + 2]]) / 3.0
				var px := clampi(int(uv.x * w), 0, w - 1)
				var py := clampi(int(uv.y * h), 0, h - 1)
				var col := img.get_pixel(px, py)
				total += 1
				if col.r + col.g + col.b < 0.30:
					dark += 1
					if rows.size() < 8: rows.append({"tri": i / 3, "uv": [uv.x, uv.y], "rgb": [col.r, col.g, col.b], "a": col.a})
		print("ACTION ", action, " triangles=", total, " dark_center_tris=", dark)
		report.actions[action] = {"triangles": total, "dark_center_tris": dark, "sample": rows}
	if out != "":
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		FileAccess.open(out, FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	quit()
