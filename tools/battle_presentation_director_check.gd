extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const DirectorScript := preload("res://effects/runtime/presentation/BattlePresentationDirector.gd")
const EventSchema := preload("res://scripts/battle/BattlePresentationEvent.gd")
const VisualResolver := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")


# Anchor-aware stand-in for UnitActorRegistry. It is permissive by default so the
# D2 assertions keep their original meaning while now exercising the real D3
# resolution path; allow()/drop_anchor() turn it into a strict fixture.
class FakeRegistry:
	extends RefCounted

	const ANCHORS := ["ActorRoot", "FootAnchor", "HeadAnchor", "CastAnchor", "HitAnchor", "Shadow"]
	# ActorRoot sits at the origin and every real anchor is offset, so a degraded
	# cue is distinguishable from a correctly resolved one by position alone.
	const ROOT_POSITION := Vector3.ZERO
	const ANCHOR_POSITION := Vector3(1.0, 2.0, 3.0)

	var cleared := 0
	var permissive := true
	var known_uids: Dictionary = {}
	var missing_anchors: Dictionary = {}
	var _owner: Node = null
	var _actors: Dictionary = {}

	func _init(p_owner: Node = null) -> void:
		_owner = p_owner

	# Restricts the registry to the uids that were explicitly allowed.
	func allow(uid: String) -> void:
		permissive = false
		known_uids[uid] = true

	func drop_anchor(uid: String, anchor_name: String) -> void:
		missing_anchors["%s|%s" % [uid, anchor_name]] = true

	func clear() -> void:
		cleared += 1
		permissive = false
		known_uids.clear()
		for actor in _actors.values():
			if is_instance_valid(actor):
				(actor as Node).queue_free()
		_actors.clear()

	func get_actor(uid: String) -> Node3D:
		if uid.is_empty():
			return null
		if not permissive and not known_uids.has(uid):
			return null
		var cached = _actors.get(uid)
		if cached != null and is_instance_valid(cached):
			return cached as Node3D
		var actor := Node3D.new()
		actor.name = "StubActor_%s" % uid
		for anchor_name in ANCHORS:
			if missing_anchors.has("%s|%s" % [uid, anchor_name]):
				continue
			var anchor := Node3D.new()
			anchor.name = str(anchor_name)
			anchor.position = ROOT_POSITION if anchor_name == "ActorRoot" else ANCHOR_POSITION
			actor.add_child(anchor)
		if _owner != null:
			_owner.add_child(actor)
		_actors[uid] = actor
		return actor

	func get_anchor(uid: String, anchor_name: String) -> Node3D:
		var actor := get_actor(uid)
		if actor == null:
			return null
		var node := actor.get_node_or_null(anchor_name)
		return node as Node3D if node is Node3D else null


class FakeAdapter:
	extends RefCounted
	var started: Array[Dictionary] = []
	var callbacks: Dictionary = {}
	var cancel_calls := 0

	func play_cue(event: Dictionary, completion: Callable, playback_speed: float) -> bool:
		started.append({
			"event_key": str(event.get("event_key", "")),
			"source_uid": str(event.get("source_uid", "")),
			"type": str(event.get("type", "")),
			"speed": playback_speed,
			"anchors": (event.get("_resolved_anchors", {}) as Dictionary).duplicate(true),
		})
		callbacks[str(event.get("event_key", ""))] = completion
		return true

	func complete(event_key: String) -> void:
		if not callbacks.has(event_key):
			return
		var completion: Callable = callbacks[event_key]
		callbacks.erase(event_key)
		completion.call()

	func cancel_all_transient() -> void:
		cancel_calls += 1
		callbacks.clear()


var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new("battle_presentation_director")
	_check_lifecycle_and_null_adapter()
	_check_serial_and_parallel_tracks()
	_check_death_cancels_unstarted_attacks()
	_check_invalid_and_duplicate_events()
	_check_pause_seek_skip_and_drain()
	_check_battle_restart_cleanup()
	_check_actor_resolution()
	_check_anchor_degradation_and_no_caching()
	_check_integration_loads()
	_h.finish(get_tree())


func _check_lifecycle_and_null_adapter() -> void:
	var director: RefCounted = DirectorScript.new()
	var registry := FakeRegistry.new(self)
	var started: Array[String] = []
	var completed: Array[String] = []
	var drained := [0]
	director.cue_started.connect(func(key: String) -> void: started.append(key))
	director.cue_completed.connect(func(key: String) -> void: completed.append(key))
	director.presentation_drained.connect(func() -> void: drained[0] += 1)
	_h.expect(director.get_lifecycle() == DirectorScript.Lifecycle.IDLE,
		"initial_state", "Director must start IDLE")
	director.configure(registry, null, null)
	director.begin_battle({"battle_id": "d2:lifecycle"})
	_h.expect(director.get_lifecycle() == DirectorScript.Lifecycle.RUNNING,
		"begin_state", "begin_battle must enter RUNNING")
	var event := _event("d2:lifecycle", 0, 0, "hit_number", "unit_a")
	director.enqueue_tick(0, [event])
	_h.expect(started == ["d2:lifecycle:0:0"],
		"null_started", "null adapter did not start the valid cue exactly once")
	_h.expect(completed == started and director.active_cue_count() == 0,
		"null_completed", "null adapter must complete immediately without leaving an active cue")
	director.begin_draining()
	_h.expect(director.get_lifecycle() == DirectorScript.Lifecycle.FINISHED,
		"finish_state", "empty drain must enter FINISHED")
	_h.expect(drained[0] == 1 and not director.has_blocking_cues(),
		"drain_signal", "presentation_drained must emit once after the queue is empty")
	director.begin_draining()
	_h.expect(drained[0] == 1, "drain_idempotent", "repeated drain emitted twice")
	director.dispose()
	director.dispose()
	_h.expect(director.get_lifecycle() == DirectorScript.Lifecycle.DISPOSED,
		"dispose_state", "dispose must be idempotent and terminal")


func _check_serial_and_parallel_tracks() -> void:
	var adapter := FakeAdapter.new()
	var director: RefCounted = DirectorScript.new()
	director.configure(FakeRegistry.new(self), null, null, adapter)
	director.begin_battle({"battle_id": "d2:serial"})
	var serial_events: Array = []
	for ordinal in 3:
		serial_events.append(_event("d2:serial", 0, ordinal, "attack_start", "unit_a", [], "important"))
	director.enqueue_tick(0, serial_events)
	_h.expect(adapter.started.size() == 1 and director.active_cue_count() == 1,
		"same_uid_first", "three actions from one uid must start only the first cue")
	_h.expect(director.pending_cue_count() == 2,
		"same_uid_pending", "remaining same-uid actions were not queued serially")
	adapter.complete("d2:serial:0:0")
	_h.expect(adapter.started.size() == 2 and str(adapter.started[1].event_key) == "d2:serial:0:1",
		"same_uid_second", "second same-uid action did not wait for first completion")
	adapter.complete("d2:serial:0:1")
	adapter.complete("d2:serial:0:2")
	_h.expect(adapter.started.size() == 3 and director.active_cue_count() == 0 and director.pending_cue_count() == 0,
		"same_uid_complete", "serial track did not fully drain in order")

	adapter = FakeAdapter.new()
	director = DirectorScript.new()
	director.configure(FakeRegistry.new(self), null, null, adapter)
	director.begin_battle({"battle_id": "d2:parallel"})
	director.enqueue_tick(0, [
		_event("d2:parallel", 0, 0, "attack_start", "unit_a", [], "important"),
		_event("d2:parallel", 0, 1, "attack_start", "unit_b", [], "important"),
	])
	_h.expect(adapter.started.size() == 2 and director.active_cue_count() == 2,
		"different_uid_parallel", "different source uids must be allowed to start in parallel")


func _check_death_cancels_unstarted_attacks() -> void:
	var adapter := FakeAdapter.new()
	var director: RefCounted = DirectorScript.new()
	var drops: Array[Dictionary] = []
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	director.configure(FakeRegistry.new(self), null, null, adapter)
	director.begin_battle({"battle_id": "d2:death"})
	director.enqueue_tick(0, [
		_event("d2:death", 0, 0, "attack_start", "unit_dead", [], "important"),
		_event("d2:death", 0, 1, "attack_start", "unit_dead", [], "important"),
		_event("d2:death", 0, 2, "impact", "unit_dead", [], "important"),
		_event("d2:death", 0, 3, "death", "unit_dead", [], "critical"),
	])
	_h.expect(adapter.started.size() == 1 and director.pending_cue_count() == 1,
		"death_cancel_queue", "death must keep the active action, cancel two unstarted attacks, and queue death")
	var source_dead_drops := 0
	for drop in drops:
		if str(drop.reason) == "source_dead":
			source_dead_drops += 1
	_h.expect(source_dead_drops == 2,
		"death_drop_count", "death must report each cancelled unstarted attack exactly once")
	adapter.complete("d2:death:0:0")
	_h.expect(adapter.started.size() == 2 and str(adapter.started[1].type) == "death",
		"death_after_active", "death cue must start after the already-active action completes")


func _check_invalid_and_duplicate_events() -> void:
	var director: RefCounted = DirectorScript.new()
	var drops: Array[Dictionary] = []
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	director.configure(FakeRegistry.new(self), null, null)
	director.begin_battle({"battle_id": "d2:invalid"})
	director.enqueue_tick(0, [{"type": "future_unknown_cue", "source_uid": "unit_a"}])
	director.enqueue_tick(0, [{"type": "future_unknown_cue", "source_uid": "unit_a"}])
	var unknown_drops := 0
	for drop in drops:
		if str(drop.reason).contains("unknown_type"):
			unknown_drops += 1
	_h.expect(unknown_drops == 1,
		"unknown_drop_once", "same unknown cue must be rejected and reported only once")

	director = DirectorScript.new()
	drops.clear()
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	director.configure(FakeRegistry.new(self), null, null)
	director.begin_battle({"battle_id": "d2:duplicate"})
	var event := _event("d2:duplicate", 1, 0, "hit_number", "unit_a")
	director.enqueue_tick(1, [event])
	director.enqueue_tick(1, [event])
	director.enqueue_tick(1, [event])
	var duplicate_drops := 0
	for drop in drops:
		if str(drop.reason) == "duplicate_event_key":
			duplicate_drops += 1
	_h.expect(duplicate_drops == 1,
		"duplicate_drop_once", "repeated duplicate event_key must only report one drop")
	director.enqueue_tick(-1, [])
	_h.expect(drops.any(func(drop: Dictionary) -> bool: return str(drop.reason) == "invalid_tick"),
		"invalid_tick", "negative replay ticks must be rejected safely")


func _check_pause_seek_skip_and_drain() -> void:
	var adapter := FakeAdapter.new()
	var director: RefCounted = DirectorScript.new()
	director.configure(FakeRegistry.new(self), null, null, adapter)
	director.begin_battle({"battle_id": "d2:seek"})
	director.set_playback_speed(-2.0)
	_h.expect(is_zero_approx(director.get_playback_speed()),
		"speed_clamp_low", "negative playback speed was not clamped to pause")
	var paused_event := _event("d2:seek", 1, 0, "attack_start", "unit_a", [], "important")
	director.enqueue_tick(1, [paused_event])
	_h.expect(adapter.started.is_empty() and director.pending_cue_count() == 1,
		"pause_queue", "paused Director must queue without starting cues")
	director.set_playback_speed(9.0)
	_h.expect(is_equal_approx(director.get_playback_speed(), 4.0) and adapter.started.size() == 1,
		"speed_clamp_high", "resume did not clamp to 4x and pump queued cues")
	director.seek_to_tick(1)
	_h.expect(adapter.cancel_calls == 1 and director.active_cue_count() == 0 and director.pending_cue_count() == 0,
		"seek_cancels", "seek must cancel all transient work and clear action tracks")
	director.enqueue_tick(1, [paused_event])
	_h.expect(adapter.started.size() == 1,
		"seek_no_replay", "backward/current seek replayed an already consumed transient cue")
	var future_event := _event("d2:seek", 2, 0, "attack_start", "unit_b", [], "important")
	director.enqueue_tick(2, [future_event])
	_h.expect(adapter.started.size() == 2 and director.get_current_tick() == 2,
		"seek_future", "events after the seek floor must resume normally")
	var drained := [0]
	director.presentation_drained.connect(func() -> void: drained[0] += 1)
	director.skip_to_result()
	_h.expect(director.get_lifecycle() == DirectorScript.Lifecycle.SKIPPED,
		"skip_state", "skip_to_result must enter SKIPPED")
	_h.expect(director.active_cue_count() == 0 and director.pending_cue_count() == 0 and drained[0] == 1,
		"skip_cleanup", "skip must clear all cues and emit one drained signal")
	director.skip_to_result()
	_h.expect(drained[0] == 1, "skip_idempotent", "repeated skip emitted drained twice")

	adapter = FakeAdapter.new()
	director = DirectorScript.new()
	drained = [0]
	director.presentation_drained.connect(func() -> void: drained[0] += 1)
	director.configure(FakeRegistry.new(self), null, null, adapter)
	director.begin_battle({"battle_id": "d2:drain"})
	director.enqueue_tick(0, [
		_event("d2:drain", 0, 0, "attack_start", "unit_a", [], "important"),
		_event("d2:drain", 0, 1, "hit_number", "unit_b", [], "ambient"),
	])
	director.begin_draining()
	_h.expect(director.get_lifecycle() == DirectorScript.Lifecycle.DRAINING and director.has_blocking_cues(),
		"draining_waits", "DRAINING must wait for critical/important cues")
	adapter.complete("d2:drain:0:0")
	_h.expect(director.get_lifecycle() == DirectorScript.Lifecycle.FINISHED and drained[0] == 1,
		"draining_finished", "Director did not finish after its final blocking cue")
	_h.expect(director.active_cue_count() == 0 and director.pending_cue_count() == 0,
		"draining_cleanup", "non-blocking transient cues remained after drain")


func _check_battle_restart_cleanup() -> void:
	var adapter := FakeAdapter.new()
	var director: RefCounted = DirectorScript.new()
	director.configure(FakeRegistry.new(self), null, null, adapter)
	director.begin_battle({"battle_id": "d2:old"})
	director.enqueue_tick(0, [
		_event("d2:old", 0, 0, "attack_start", "unit_a", [], "important"),
	])
	_h.expect(director.active_cue_count() == 1 and adapter.callbacks.size() == 1,
		"restart_fixture", "restart cleanup fixture did not create one active cue")
	director.begin_battle({"battle_id": "d2:new"})
	_h.expect(adapter.cancel_calls == 1 and adapter.callbacks.is_empty()
		and director.active_cue_count() == 0 and director.pending_cue_count() == 0
		and director.get_lifecycle() == DirectorScript.Lifecycle.RUNNING,
		"restart_cleanup", "new battle inherited adapter callbacks or action tracks from the old battle")


# D3 / checklist 5.2 and 4.1: a cue whose actor cannot be resolved is dropped
# exactly once with a classified reason and must not block the rest of the tick.
func _check_actor_resolution() -> void:
	var adapter := FakeAdapter.new()
	var director: RefCounted = DirectorScript.new()
	var drops: Array[Dictionary] = []
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	var registry := FakeRegistry.new(self)
	registry.allow("unit_live")
	director.configure(registry, null, null, adapter)
	director.begin_battle({"battle_id": "d3:actor"})
	director.enqueue_tick(0, [
		_event("d3:actor", 0, 0, "attack_start", "unit_ghost", [], "important"),
		_event("d3:actor", 0, 1, "attack_start", "unit_live", [], "important"),
	])
	var source_drops := drops.filter(func(d: Dictionary) -> bool:
		return str(d.reason) == "missing_actor:source")
	_h.expect(source_drops.size() == 1 and str(source_drops[0].key) == "d3:actor:0:0",
		"missing_source_actor", "unresolvable source actor was not dropped exactly once")
	_h.expect(adapter.started.size() == 1 and str(adapter.started[0].event_key) == "d3:actor:0:1",
		"missing_actor_isolation", "a dropped cue must not block the other uid in the same tick")
	_h.expect((adapter.started[0].anchors as Dictionary).get("source", Vector3.ONE) == FakeRegistry.ANCHOR_POSITION,
		"source_anchor_position", "attack_start did not resolve its CastAnchor world position")

	# Camera-only cues never touch an actor (checklist section 3), so a unit that is
	# still being built cannot suppress a screen shake.
	adapter = FakeAdapter.new()
	director = DirectorScript.new()
	drops.clear()
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	var shake_registry := FakeRegistry.new(self)
	shake_registry.allow("somebody_else")
	director.configure(shake_registry, null, null, adapter)
	director.begin_battle({"battle_id": "d3:shake"})
	director.enqueue_tick(0, [_event("d3:shake", 0, 0, "skill_shake", "unbuilt_unit", [], "important")])
	_h.expect(adapter.started.size() == 1 and drops.is_empty(),
		"actorless_cue", "skill_shake must play without requiring a registered actor")

	# Partial AoE loss degrades; total loss is a classified drop.
	adapter = FakeAdapter.new()
	director = DirectorScript.new()
	drops.clear()
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	var aoe_registry := FakeRegistry.new(self)
	aoe_registry.allow("caster")
	aoe_registry.allow("target_alive")
	director.configure(aoe_registry, null, null, adapter)
	director.begin_battle({"battle_id": "d3:aoe"})
	director.enqueue_tick(0, [
		_event("d3:aoe", 0, 0, "impact", "caster", ["target_alive", "target_gone"], "important"),
	])
	_h.expect(adapter.started.size() == 1 and drops.is_empty(),
		"partial_aoe_kept", "one vanished target must not swallow the whole AoE cue")
	var targets: Dictionary = (adapter.started[0].anchors as Dictionary).get("targets", {})
	_h.expect(targets.size() == 1 and targets.has("target_alive"),
		"partial_aoe_targets", "surviving targets were not resolved to HitAnchor positions")
	# The first impact still owns the caster track, so it must finish before the
	# next one can resolve (serial track rule from D2).
	adapter.complete("d3:aoe:0:0")
	director.enqueue_tick(1, [
		_event("d3:aoe", 1, 0, "impact", "caster", ["target_gone", "another_ghost"], "important"),
	])
	_h.expect(drops.any(func(d: Dictionary) -> bool: return str(d.reason) == "missing_actor:target"),
		"missing_all_targets", "a cue whose every target is unresolvable must be dropped")


# D3 / checklist 4.2, 7 D3 and 5.4: a missing anchor degrades and is reported
# instead of dropping, and nothing about a resolution survives into the next battle.
func _check_anchor_degradation_and_no_caching() -> void:
	VisualResolver.reset_failure_report()
	var adapter := FakeAdapter.new()
	var director: RefCounted = DirectorScript.new()
	var drops: Array[Dictionary] = []
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	var registry := FakeRegistry.new(self)
	registry.allow("broken_actor")
	registry.drop_anchor("broken_actor", "CastAnchor")
	director.configure(registry, null, null, adapter)
	director.begin_battle({"battle_id": "d3:anchor"})
	director.enqueue_tick(0, [_event("d3:anchor", 0, 0, "attack_start", "broken_actor", [], "important")])
	_h.expect(adapter.started.size() == 1 and drops.is_empty(),
		"anchor_degrades", "a missing anchor must degrade to ActorRoot, not drop the cue")
	_h.expect((adapter.started[0].anchors as Dictionary).get("source", Vector3.ONE) == FakeRegistry.ROOT_POSITION,
		"anchor_fallback_position", "degraded cue did not fall back to the ActorRoot position")
	var director_rows := VisualResolver.failure_rows().filter(func(row: Dictionary) -> bool:
		return str(row.get("consumer", "")) == "director")
	_h.expect(director_rows.size() == 1 and str(director_rows[0].get("unit_id", "")) == "broken_actor",
		"anchor_failure_reported", "a missing anchor must be reported once through the shared aggregate")
	VisualResolver.reset_failure_report()

	# Checklist 5.4: the Director may only store sim uids. Clearing the registry
	# between battles must force a fresh resolution rather than reuse a stale node.
	adapter = FakeAdapter.new()
	director = DirectorScript.new()
	drops.clear()
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	var reused := FakeRegistry.new(self)
	reused.allow("veteran")
	director.configure(reused, null, null, adapter)
	director.begin_battle({"battle_id": "d3:old"})
	director.enqueue_tick(0, [_event("d3:old", 0, 0, "attack_start", "veteran", [], "important")])
	_h.expect(adapter.started.size() == 1,
		"cache_fixture", "no-caching fixture did not resolve its first cue")
	reused.clear()
	director.begin_battle({"battle_id": "d3:new"})
	director.enqueue_tick(0, [_event("d3:new", 0, 0, "attack_start", "veteran", [], "important")])
	_h.expect(adapter.started.size() == 1,
		"no_actor_cache", "Director replayed a cue against an actor the registry had already released")
	_h.expect(drops.any(func(d: Dictionary) -> bool: return str(d.reason) == "missing_actor:source"),
		"no_actor_cache_reason", "a released actor must produce a fresh missing_actor drop")


func _check_integration_loads() -> void:
	_h.expect(load("res://effects/runtime/presentation/BattleActionTrack.gd") != null,
		"track_load", "BattleActionTrack.gd failed to load")
	_h.expect(load("res://effects/runtime/presentation/BattlePresentationDirector.gd") != null,
		"director_load", "BattlePresentationDirector.gd failed to load")
	_h.expect(load("res://scenes/battle/BattleScreen.gd") != null,
		"battle_screen_load", "BattleScreen.gd failed to parse after Director integration")


func _event(
	battle_id: String,
	tick: int,
	ordinal: int,
	event_type: String,
	source_uid: String,
	target_uids: Array = [],
	priority: String = "ambient"
) -> Dictionary:
	return EventSchema.normalize({
		"type": event_type,
		"source_uid": source_uid,
		"target_uids": target_uids,
		"visibility_priority": priority,
	}, battle_id, tick, ordinal)
