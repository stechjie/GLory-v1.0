extends SceneTree
# Contract check for the formation-ally refinement (2026-10-12).
#   godot --headless --path <proj> --script \
#     res://tools/model_refinement/allies/ally_refinement_contract_check.gd -- [--out report.json]
# Prints CHECK_RESULT PASS/FAIL and exits 0/1.
const SkinUtil := preload("res://tools/model_refinement/allies/skin_util.gd")
const TABLE := "res://data/formation/formation_allies.json"
const WRAPPER := "res://assets/models/allies/FormationAllyAnimated.gd"
const ORIGINAL_MODEL := {
	"ally_flame_claw": "res://assets/models/allies/formation_ally_1_animated/formation_ally_1_animated.tscn",
	"ally_soul_chain": "res://assets/models/allies/formation_ally_2_animated/formation_ally_2_animated.tscn",
	"ally_abyss_beast": "res://assets/models/allies/formation_ally_3_animated/formation_ally_3_animated.tscn",
	"ally_hell_inferno": "res://assets/models/allies/formation_ally_4_animated/formation_ally_4_animated.tscn",
	"ally_eternal_night": "res://assets/models/allies/formation_ally_5_animated/formation_ally_5_animated.tscn",
}
var passes := 0
var fails: Array = []
var rows: Array = []

func _ok(cond: bool, what: String) -> void:
	if cond:
		passes += 1
	else:
		fails.append(what)

func _initialize() -> void:
	var out := ""
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out":
			out = args[i + 1]
	var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TABLE))
	var seen := 0
	for def in table.get("allies", []):
		var uid := str(def.get("id"))
		if not ORIGINAL_MODEL.has(uid):
			continue
		seen += 1
		var path := str(def.get("model"))
		_ok(path == "res://assets/models/allies_refined/%s/%s_refined.tscn" % [uid, uid], "%s: table model -> refined scene" % uid)
		_ok(ResourceLoader.exists(ORIGINAL_MODEL[uid]), "%s: original wrapper kept for rollback" % uid)
		await _check_unit(uid, path, false)
		await _check_unit(uid, path, true)
	_ok(seen == 5, "table lists 5 formation allies (got %d)" % seen)
	var report := {"passes": passes, "fails": fails, "rows": rows}
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify(report, " "))
		f.close()
	for r in rows:
		print("ROW ", JSON.stringify(r))
	for msg in fails:
		print("FAIL ", msg)
	print("CHECK_RESULT %s passes=%d fails=%d" % ["PASS" if fails.is_empty() else "FAIL", passes, fails.size()])
	quit(0 if fails.is_empty() else 1)

func _check_unit(uid: String, path: String, idle_only: bool) -> void:
	var scene := load(path) as PackedScene
	_ok(scene != null, "%s: scene loads" % uid)
	if scene == null:
		return
	var w := scene.instantiate() as Node3D
	if idle_only:
		w.set_meta("load_idle_only", true)
	_ok(w.get_script() != null and (w.get_script() as Script).get_base_script() != null \
		and (w.get_script() as Script).get_base_script().resource_path == WRAPPER, "%s: wrapper extends original FormationAllyAnimated" % uid)
	for m in ["play_idle", "play_run", "play_attack"]:
		_ok(w.has_method(m), "%s: has %s" % [uid, m])
	get_root().add_child(w)
	await process_frame
	await process_frame
	var nodes: Dictionary = w.get("action_nodes")
	var players: Dictionary = w.get("action_players")
	var expected := ["idle"] if idle_only else ["idle", "attack", "run"]
	_ok(nodes.size() == expected.size(), "%s%s: loads %d action models (got %d)" % [uid, " idle-only" if idle_only else "", expected.size(), nodes.size()])
	var idle_h := 0.0
	# body fire: every flame point resolves to a bone on every loaded action rig
	var points: Array = w.get("flame_points")
	var emitters: Dictionary = w.get("_flame_emitters")
	_ok(points.size() >= 4, "%s: >= 4 flame points (got %d)" % [uid, points.size()])
	for action in expected:
		_ok(emitters.has(action) and (emitters[action] as Array).size() == points.size(),
			"%s %s: all %d flame points attached" % [uid, action, points.size()])
	for action in expected:
		var node := nodes.get(action) as Node3D
		_ok(node != null, "%s %s: action model present" % [uid, action])
		if node == null:
			continue
		# material: refined body material + outline pass, textures <= 1024, no alpha
		for mi in node.find_children("*", "MeshInstance3D", true, false):
			var mat := (mi as MeshInstance3D).get_surface_override_material(0) as ShaderMaterial
			_ok(mat != null and mat.resource_path.begins_with("res://assets/models/allies_refined/%s/" % uid), "%s %s: refined material" % [uid, action])
			if mat == null:
				continue
			_ok(mat.next_pass is ShaderMaterial and (mat.next_pass as ShaderMaterial).shader.resource_path == "res://shaders/character_outline.gdshader", "%s %s: outline pass" % [uid, action])
			for p in ["albedo_texture", "emission_mask"]:
				var t := mat.get_shader_parameter(p) as Texture2D
				_ok(t != null and maxi(t.get_width(), t.get_height()) <= 1024, "%s %s: %s <= 1024" % [uid, action, p])
				if t != null:
					var img := t.get_image()
					if img != null and img.is_compressed():
						img.decompress()
					_ok(img == null or not img.detect_alpha(), "%s %s: %s opaque" % [uid, action, p])
		# animation: an animation is chosen and actually changes the pose
		w.call("play_" + action)
		w.set_process(false)
		for key in emitters.keys():
			for e in emitters[key]:
				_ok((e as CPUParticles3D).emitting == (str(key) == action), "%s %s: only active action's fire emits (%s)" % [uid, action, key])
		var player := players.get(action) as AnimationPlayer
		_ok(player != null and player.current_animation != "", "%s %s: animation playing" % [uid, action])
		if player == null or player.current_animation == "":
			continue
		var clip := String(player.current_animation)
		var anim := player.get_animation(clip)
		player.pause()
		var samples := []
		for frac in [0.0, 0.33, 0.66]:
			player.seek(anim.length * frac, true)
			await process_frame
			samples.append(SkinUtil.posed_bounds(w, 7))
		var b0: AABB = samples[0]
		var moved := 0.0
		for b in samples:
			moved = maxf(moved, (b.position - b0.position).length() + (b.size - b0.size).length())
		var h := b0.end.y
		if action == "idle":
			idle_h = h
		var ratio := h / maxf(idle_h, 0.001)
		rows.append({"unit": uid, "idle_only": idle_only, "action": action, "clip": clip,
			"clip_len": snappedf(anim.length, 0.001), "height": snappedf(h, 0.001), "height_vs_idle": snappedf(ratio, 0.01),
			"foot_y": snappedf(b0.position.y, 0.001), "pose_motion": snappedf(moved, 0.0001)})
		_ok(ratio > 0.75 and ratio < 1.35, "%s %s: height %.2f x idle (visible, same scale)" % [uid, action, ratio])
		_ok(b0.position.y > -0.25 and b0.position.y < 0.2, "%s %s: grounded (foot_y %.3f)" % [uid, action, b0.position.y])
		_ok(moved > 0.002, "%s %s: pose changes over the clip (%.4f)" % [uid, action, moved])
	w.queue_free()
	await process_frame
