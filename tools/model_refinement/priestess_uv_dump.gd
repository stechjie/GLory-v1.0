extends SceneTree
## Dumps every triangle's three vertex UVs of the priestess body mesh so the
## Python atlas repair (pad_priestess_atlas.py) can rasterise the UV footprint.
## Usage: godot --headless --path . --script tools/model_refinement/priestess_uv_dump.gd -- --out <abs-json> [--original]
func _initialize(): call_deferred("run")

func run():
	var args := OS.get_cmdline_user_args()
	if not "--out" in args:
		push_error("Required: --out <absolute-json>"); quit(2); return
	var path: String = "res://assets/models/units/god_priestess_animated/god_priestess_animated.tscn" if "--original" in args else "res://assets/models/units/god_priestess_refined/god_priestess_refined.tscn"
	var scene = load(path).instantiate()
	root.add_child(scene)
	scene.set_process(false)
	for p in scene.find_children("*", "AnimationPlayer", true, false):
		p.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	scene.call("play_idle")
	var mis: Array = scene.action_nodes["idle"].find_children("*", "MeshInstance3D", true, false)
	var mesh: Mesh = mis[0].mesh
	var tris := []
	for s in mesh.get_surface_count():
		var a: Array = mesh.surface_get_arrays(s)
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		var uvs: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
		for i in range(0, idx.size(), 3):
			tris.append([
				[uvs[idx[i]].x, uvs[idx[i]].y],
				[uvs[idx[i + 1]].x, uvs[idx[i + 1]].y],
				[uvs[idx[i + 2]].x, uvs[idx[i + 2]].y]])
	print("TRIS ", tris.size(), " surfaces=", mesh.get_surface_count(), " source=", path)
	FileAccess.open(args[args.find("--out") + 1], FileAccess.WRITE).store_string(JSON.stringify({"tris": tris}))
	quit()
