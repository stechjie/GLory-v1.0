extends SceneTree
# Finds the yaw (0/90/180/270 + fine) that best aligns each action's posed top-view
# silhouette with the idle silhouette (IoU of XZ occupancy grids, model space).
# args: wrapper.tscn [...]
const SkinUtil := preload("res://tools/model_refinement/allies/skin_util.gd")
const N := 48

func _initialize() -> void:
	for path in OS.get_cmdline_user_args():
		var w := (load(path) as PackedScene).instantiate() as Node3D
		get_root().add_child(w)
		await process_frame
		await process_frame
		var nodes: Dictionary = w.get("action_nodes")
		var clouds := {}
		for action in ["idle", "attack", "run"]:
			w.call("play_" + action)
			w.set_process(false)
			var players: Dictionary = w.get("action_players")
			var p := players.get(action) as AnimationPlayer
			if p and p.current_animation != "":
				p.pause()
				p.seek(0.0, true)
			await process_frame
			var pts := SkinUtil.posed_points(w, 3)
			var inv := w.global_transform.affine_inverse()
			var xz := PackedVector2Array()
			for q in pts:
				var m := inv * q
				xz.append(Vector2(m.x, m.z))
			clouds[action] = xz
		var ref: PackedVector2Array = clouds["idle"]
		var ext := 0.0
		for v in ref:
			ext = maxf(ext, maxf(absf(v.x), absf(v.y)))
		var grid_ref := _grid(ref, 0.0, ext)
		for action in ["attack", "run"]:
			var best := -1.0
			var best_yaw := 0.0
			var scores := []
			for yaw_i in range(0, 360, 15):
				var g := _grid(clouds[action], float(yaw_i), ext)
				var iou := _iou(grid_ref, g)
				scores.append("%d:%.2f" % [yaw_i, iou])
				if iou > best:
					best = iou
					best_yaw = yaw_i
			print("YAW %s %s best_extra_yaw=%d iou=%.3f  (%s)" % [path.get_file(), action, best_yaw, best, " ".join(scores)])
		w.queue_free()
	quit(0)

func _grid(pts: PackedVector2Array, yaw_deg: float, ext: float) -> PackedByteArray:
	var g := PackedByteArray()
	g.resize(N * N)
	var r := deg_to_rad(yaw_deg)
	var c := cos(r)
	var s := sin(r)
	# center on centroid so root offsets do not dominate
	var cen := Vector2.ZERO
	for v in pts:
		cen += v
	cen /= maxf(1.0, pts.size())
	for v in pts:
		var d := v - cen
		# yaw about +Y: x' = x c + z s ; z' = -x s + z c
		var x := d.x * c + d.y * s
		var z := -d.x * s + d.y * c
		var ix := int((x / (ext * 1.3) * 0.5 + 0.5) * N)
		var iz := int((z / (ext * 1.3) * 0.5 + 0.5) * N)
		if ix >= 0 and ix < N and iz >= 0 and iz < N:
			g[iz * N + ix] = 1
	return g

func _iou(a: PackedByteArray, b: PackedByteArray) -> float:
	var i := 0
	var u := 0
	for k in a.size():
		if a[k] or b[k]:
			u += 1
			if a[k] and b[k]:
				i += 1
	return float(i) / maxf(1.0, u)
