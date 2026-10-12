extends SceneTree
const SkinUtil := preload("res://tools/model_refinement/allies/skin_util.gd")
func _initialize() -> void:
	for path in OS.get_cmdline_user_args():
		var w := (load(path) as PackedScene).instantiate() as Node3D
		get_root().add_child(w)
		await process_frame
		await process_frame
		var players: Dictionary = w.get("action_players")
		for action in ["idle", "attack", "run"]:
			w.call("play_" + action)
			w.set_process(false)
			var p := players.get(action) as AnimationPlayer
			var anim := p.get_animation(p.current_animation)
			p.pause()
			var ys := []
			for i in 12:
				p.seek(anim.length * i / 12.0, true)
				await process_frame
				ys.append(snappedf(SkinUtil.posed_bounds(w, 5).position.y, 0.001))
			print("FOOT %s %s min=%.3f max=%.3f %s" % [path.get_file(), action, ys.min(), ys.max(), ys])
		w.queue_free()
	quit(0)
