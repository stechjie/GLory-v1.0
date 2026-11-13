extends SceneTree

# Exercise the actual formation wrappers directly: prep/preview callers do not
# pass through BattleVfx's separate hidden-animation guard.
const TABLE := "res://data/formation/formation_allies.json"
var passes := 0
var failures: Array[String] = []
var rows: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _expect(ok: bool, message: String) -> void:
	if ok:
		passes += 1
	else:
		failures.append(message)

func _run() -> void:
	var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TABLE))
	for definition in table.get("allies", []):
		await _check_wrapper(definition, false)
		await _check_wrapper(definition, true)
	var report := {"passes": passes, "failures": failures, "rows": rows}
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out" and i + 1 < args.size():
			var file := FileAccess.open(args[i + 1], FileAccess.WRITE)
			file.store_string(JSON.stringify(report, "\t"))
	print("FORMATION_ALLY_ANIMATION_ACTIVITY ", JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)

func _check_wrapper(definition: Dictionary, idle_only: bool) -> void:
	var uid := str(definition.get("id", ""))
	var label := uid + (" idle-only" if idle_only else " all-actions")
	var scene := load(str(definition.get("model", ""))) as PackedScene
	_expect(scene != null, label + ": scene must load")
	if scene == null:
		return
	var wrapper := scene.instantiate() as Node3D
	if idle_only:
		wrapper.set_meta("load_idle_only", true)
	root.add_child(wrapper)
	await process_frame
	await process_frame
	var nodes: Dictionary = wrapper.get("action_nodes")
	var players: Dictionary = wrapper.get("action_players")
	var proxy := wrapper.get_node("AnimationPlayer") as AnimationPlayer
	wrapper.set_process(false)
	var switches := 0
	for action in ["idle", "run", "attack", "idle", "attack", "run", "idle"]:
		wrapper.call("play_" + action)
		var resolved: String = action if nodes.has(action) else "idle"
		_expect(str(wrapper.get("current_action")) == resolved,
			label + ": current action after " + action)
		_expect(proxy.is_playing(), label + ": proxy remains active")
		for key in players.keys():
			var player := players[key] as AnimationPlayer
			var branch := nodes[key] as Node3D
			var active: bool = str(key) == resolved
			_expect(branch.visible == active, label + ": visibility for " + str(key))
			if player != null:
				_expect(player.is_playing() == active,
					label + ": playing state for " + str(key) + " after " + action)
		var current := players.get(resolved) as AnimationPlayer
		if current != null:
			current.advance(0.12)
			var advanced := current.current_animation_position
			_expect(advanced > 0.0, label + ": active clip advances after " + action)
			if action in ["idle", "run"]:
				wrapper.call("play_" + action)
				_expect(is_equal_approx(current.current_animation_position, advanced),
					label + ": repeated " + action + " preserves playback position")
			switches += 1
	# Simulate reuse after every action player has previously been active.
	if not idle_only:
		for player in players.values():
			if player != null:
				(player as AnimationPlayer).play()
		wrapper.call("play_idle")
		for key in players.keys():
			var player := players[key] as AnimationPlayer
			if player != null:
				_expect(player.is_playing() == (str(key) == "idle"),
					label + ": reuse clears stale playback on " + str(key))
	rows.append({"id": uid, "idle_only": idle_only, "actions": nodes.size(), "switches": switches})
	wrapper.queue_free()
	await process_frame
