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
#   * Since D6 it plays for every unit: the snapshot-diff path it used to share
#     the work with has been deleted, so this is the only route for basic attacks,
#     damage numbers and deaths.
#   * It holds no NodePath across battles: the host node is re-checked every call.

# Beat lengths in seconds. Section B3 of the README asks for a 0.08-0.16s windup,
# a visible travel/contact beat and a short settle; these are the low end of that
# range so a 4.5s fixed round does not stretch into a much longer playback.
const WINDUP_SEC := 0.12
const PROJECTILE_SEC := 0.10
const IMPACT_SEC := 0.08
const DEATH_SEC := 0.35

# D5: the Director attaches the resolved profile under this key. The constants
# above stay as the fallback for a cue that has no profile yet, and for the D4
# tests that drive the adapter without a resolver.
const CUE_PROFILE_KEY := "_cue_profile"

# B4: the spawn path below runs through several composer layers that have no
# reason to know about presentation priority, so it is handed over as ambient
# context around the call, the same shape DamageService.set_hit_context() uses.
const QualityBudget := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

# Which profile field drives each beat of the four-beat chain.
const BEAT_FIELD := {
	"attack_start": "windup_ms",
	"projectile_spawn": "impact_ms",
	"impact": "recovery_ms",
	"death": "recovery_ms",
}

var _host: Node = null
var _pending_timers: Array[SceneTreeTimer] = []
var _played_by_type: Dictionary = {}
var _profiles_seen: Dictionary = {}


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
	var profile_value = event.get(CUE_PROFILE_KEY, {})
	if typeof(profile_value) == TYPE_DICTIONARY and not (profile_value as Dictionary).is_empty():
		_profiles_seen[str((profile_value as Dictionary).get("id", "?"))] = true
	var speed := maxf(0.01, playback_speed)
	match event_type:
		"attack_start":
			return _play_attack_start(event, source_uid, completion, speed)
		"projectile_spawn":
			return _play_projectile(event, source_uid, completion, speed)
		"impact":
			return _finish_after(_beat_seconds(event, IMPACT_SEC) / speed, completion, "impact")
		"hit_number":
			return _play_hit_number(event, completion)
		"death":
			return _play_death(event, source_uid, completion, speed)
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
		"profiles_seen": profile_ids_seen(),
		"pending_timers": _pending_timers.size(),
	}


func reset_stats() -> void:
	_played_by_type.clear()
	_profiles_seen.clear()


func _play_attack_start(event: Dictionary, source_uid: String, completion: Callable, speed: float) -> bool:
	var ranged := str(event.get("skill_id", "")) == "basic_ranged"
	if not ranged:
		# Melee draws its slash on the windup beat; ranged waits for the projectile
		# event so the bolt and the swing never both fire for one attack.
		_with_cue_priority(event, func() -> void:
			_host.call("cue_play_basic_attack", source_uid, _first_target(event), false))
		_count("attack_start")
	return _finish_after(_beat_seconds(event, WINDUP_SEC) / speed, completion, "attack_start")


func _play_projectile(event: Dictionary, source_uid: String, completion: Callable, speed: float) -> bool:
	_with_cue_priority(event, func() -> void:
		_host.call("cue_play_basic_attack", source_uid, _first_target(event), true))
	_count("projectile_spawn")
	return _finish_after(_beat_seconds(event, PROJECTILE_SEC) / speed, completion, "projectile_spawn")


func _play_hit_number(event: Dictionary, completion: Callable) -> bool:
	var target_uid := _first_target(event)
	if not target_uid.is_empty():
		_host.call(
			"cue_spawn_hit_number",
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


func _play_death(event: Dictionary, victim_uid: String, completion: Callable, speed: float) -> bool:
	var seconds := _beat_seconds(event, DEATH_SEC)
	var played := bool(_host.call("cue_play_death", victim_uid, seconds))
	if played:
		_count("death")
	return _finish_after(seconds / speed, completion, "death")


# Reads this beat's length from the profile the Director resolved. Falls back to
# the constant when no profile is attached, so D4 behaviour is unchanged for any
# cue the resolver does not cover yet.
func _beat_seconds(event: Dictionary, fallback_sec: float) -> float:
	var profile_value = event.get(CUE_PROFILE_KEY, {})
	if typeof(profile_value) != TYPE_DICTIONARY:
		return fallback_sec
	var profile: Dictionary = profile_value
	if profile.is_empty():
		return fallback_sec
	var field := str(BEAT_FIELD.get(str(event.get("type", "")), ""))
	if field.is_empty() or not profile.has(field):
		return fallback_sec
	return maxf(0.0, float(int(profile[field])) / 1000.0)


func profile_ids_seen() -> Array:
	var out: Array = _profiles_seen.keys()
	out.sort()
	return out


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


# Runs `body` with this cue's priority installed, and always clears it again:
# a leaked priority would starve or over-spend the next, unrelated cue.
func _with_cue_priority(event: Dictionary, body: Callable) -> void:
	QualityBudget.begin_cue_priority(str(event.get("visibility_priority", "important")))
	body.call()
	QualityBudget.clear_cue_priority()


func _first_target(event: Dictionary) -> String:
	var targets: Array = event.get("target_uids", [])
	if targets.is_empty():
		return str(event.get("target_uid", ""))
	return str(targets[0])


func _host_ready() -> bool:
	return _host != null and is_instance_valid(_host) and _host.is_inside_tree()


func _count(event_type: String) -> void:
	_played_by_type[event_type] = int(_played_by_type.get(event_type, 0)) + 1
