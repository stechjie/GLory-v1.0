class_name LegacyBattleVfxAdapter
extends RefCounted

# Migration-period adapter (checklist section 2, "adapters/LegacyBattleVfxAdapter.gd").
#
# It turns BattlePresentationDirector cues into calls on the BattleVfx capabilities
# that already exist, so D4 makes the windup / contact / number / death beats
# readable without authoring any new art. D5 replaces this with real .tres profiles.
#
# Boundaries:
#   * It never reads or writes simulation state; it only receives immutable events.
#   * It only plays cues for units in BattlePresentationSlice. Everything else is
#     accepted and completed immediately so the Director's bookkeeping stays whole
#     while the legacy snapshot-diff path keeps drawing those units.
#   * It holds no NodePath across battles: the host node is re-checked every call.

const Slice := preload("res://effects/runtime/presentation/BattlePresentationSlice.gd")

# Beat lengths in seconds. Section B3 of the README asks for a 0.08-0.16s windup,
# a visible travel/contact beat and a short settle; these are the low end of that
# range so a 4.5s fixed round does not stretch into a much longer playback.
const WINDUP_SEC := 0.12
const PROJECTILE_SEC := 0.10
const IMPACT_SEC := 0.08
const DEATH_SEC := 0.35

var _host: Node = null
var _pending_timers: Array[SceneTreeTimer] = []
var _played_by_type: Dictionary = {}
var _skipped_unmigrated := 0


func _init(host: Node = null) -> void:
	_host = host


func configure_host(host: Node) -> void:
	_host = host


# Director contract: returns true if the cue was accepted. `completion` must be
# called exactly once per accepted cue.
func play_cue(event: Dictionary, completion: Callable, playback_speed: float) -> bool:
	if not _host_ready():
		return false
	var event_type := str(event.get("type", ""))
	var source_uid := str(event.get("source_uid", ""))
	var unit_id := _unit_id_for(source_uid)
	if not Slice.is_migrated(unit_id):
		# Not in the vertical slice: the legacy diff path still draws this unit, so
		# accept and finish immediately instead of dropping. Dropping here would
		# spam cue_dropped for every unmigrated attack in the round.
		_skipped_unmigrated += 1
		completion.call()
		return true
	var speed := maxf(0.01, playback_speed)
	match event_type:
		"attack_start":
			return _play_attack_start(event, source_uid, completion, speed)
		"projectile_spawn":
			return _play_projectile(event, source_uid, completion, speed)
		"impact":
			return _finish_after(IMPACT_SEC / speed, completion, "impact")
		"hit_number":
			return _play_hit_number(event, completion)
		"death":
			return _play_death(source_uid, completion, speed)
	# Any other migrated-unit cue (skill_shake, unit_skill_proc, ...) still belongs
	# to the legacy route in this stage.
	completion.call()
	return true


# Called by the Director on seek, skip, battle restart and dispose.
func cancel_all_transient() -> void:
	for timer in _pending_timers:
		if timer != null and is_instance_valid(timer):
			# Disconnecting is enough: SceneTreeTimer frees itself on timeout, and a
			# still-connected callback would complete a cue that no longer exists.
			for connection in timer.timeout.get_connections():
				timer.timeout.disconnect(connection.callable)
	_pending_timers.clear()


func stats() -> Dictionary:
	return {
		"played_by_type": _played_by_type.duplicate(true),
		"skipped_unmigrated": _skipped_unmigrated,
		"pending_timers": _pending_timers.size(),
	}


func reset_stats() -> void:
	_played_by_type.clear()
	_skipped_unmigrated = 0


func _play_attack_start(event: Dictionary, source_uid: String, completion: Callable, speed: float) -> bool:
	var ranged := str(event.get("skill_id", "")) == "basic_ranged"
	if not ranged:
		# Melee draws its slash on the windup beat; ranged waits for the projectile
		# event so the bolt and the swing never both fire for one attack.
		_host.call("slice_play_basic_attack", source_uid, _first_target(event), false)
		_count("attack_start")
	return _finish_after(WINDUP_SEC / speed, completion, "attack_start")


func _play_projectile(event: Dictionary, source_uid: String, completion: Callable, speed: float) -> bool:
	_host.call("slice_play_basic_attack", source_uid, _first_target(event), true)
	_count("projectile_spawn")
	return _finish_after(PROJECTILE_SEC / speed, completion, "projectile_spawn")


func _play_hit_number(event: Dictionary, completion: Callable) -> bool:
	var target_uid := _first_target(event)
	if not target_uid.is_empty():
		_host.call(
			"slice_spawn_hit_number",
			target_uid,
			int(event.get("amount", 0)),
			"heal" if str(event.get("kind", "dmg")) == "heal" else "dmg",
			bool(event.get("is_crit", false)),
			bool(event.get("skill", false)),
			str(event.get("race", ""))
		)
		_count("hit_number")
	# Numbers are fire-and-forget: they animate on their own layer and must not
	# hold up the attacker's action track.
	completion.call()
	return true


func _play_death(victim_uid: String, completion: Callable, speed: float) -> bool:
	var played := bool(_host.call("slice_play_death", victim_uid))
	if played:
		_count("death")
	return _finish_after(DEATH_SEC / speed, completion, "death")


func _finish_after(seconds: float, completion: Callable, label: String) -> bool:
	var tree := _host.get_tree()
	if tree == null:
		completion.call()
		return true
	if seconds <= 0.0:
		completion.call()
		return true
	var timer := tree.create_timer(seconds)
	_pending_timers.append(timer)
	timer.timeout.connect(func() -> void:
		_pending_timers.erase(timer)
		completion.call())
	return true


func _first_target(event: Dictionary) -> String:
	var targets: Array = event.get("target_uids", [])
	if targets.is_empty():
		return str(event.get("target_uid", ""))
	return str(targets[0])


func _unit_id_for(sim_uid: String) -> String:
	if sim_uid.is_empty() or not _host_ready():
		return ""
	return str(_host.call("slice_unit_id_for", sim_uid))


func _host_ready() -> bool:
	return _host != null and is_instance_valid(_host) and _host.is_inside_tree()


func _count(event_type: String) -> void:
	_played_by_type[event_type] = int(_played_by_type.get(event_type, 0)) + 1
