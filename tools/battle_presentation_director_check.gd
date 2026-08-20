extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const DirectorScript := preload("res://effects/runtime/presentation/BattlePresentationDirector.gd")
const EventSchema := preload("res://scripts/battle/BattlePresentationEvent.gd")
const VisualResolver := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const RealRegistry := preload("res://effects/runtime/presentation/UnitActorRegistry.gd")


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
			"profile": (event.get("_cue_profile", {}) as Dictionary).duplicate(true),
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


# A deliberately tiny budget so overflow is reachable in a unit test.
class TinyBudget:
	extends RefCounted

	func max_cues_per_tick(priority: String) -> int:
		return -1 if priority == "critical" else 1

	func max_live_cues(priority: String) -> int:
		return -1 if priority == "critical" else 1

	func ambient_merge_window_ms() -> int:
		return 1000

	func may_merge(priority: String) -> bool:
		return priority == "ambient"

	func recovery_scale_when_over_budget(priority: String) -> float:
		return 1.0 if priority == "critical" else 0.5


# Hands back fixed profile fields so budget degradation is observable.
class FakeResolver:
	extends RefCounted
	var calls := 0

	func resolve_fields(event: Dictionary) -> Dictionary:
		calls += 1
		return {
			"id": "test_%s" % str(event.get("type", "")),
			"priority": str(event.get("visibility_priority", "ambient")),
			"windup_ms": 100,
			"impact_ms": 50,
			"recovery_ms": 200,
			"max_concurrent": 8,
		}


# Completes through a real SceneTreeTimer, which is what section 8 asks the
# seek/skip test to exercise: the D2 pass used an adapter that finished inline and
# therefore could never leave a pending timer behind.
class TimerAdapter:
	extends RefCounted
	var tree: SceneTree = null
	var started: Array[String] = []
	var completed: Array[String] = []
	var cancel_calls := 0
	var timers: Array[SceneTreeTimer] = []

	func play_cue(event: Dictionary, completion: Callable, playback_speed: float) -> bool:
		var key := str(event.get("event_key", ""))
		started.append(key)
		if tree == null:
			completion.call()
			return true
		var timer := tree.create_timer(0.05 / maxf(0.01, playback_speed))
		timers.append(timer)
		timer.timeout.connect(func() -> void:
			timers.erase(timer)
			completed.append(key)
			completion.call())
		return true

	func cancel_all_transient() -> void:
		cancel_calls += 1
		for timer in timers:
			if timer != null and is_instance_valid(timer):
				for connection in timer.timeout.get_connections():
					timer.timeout.disconnect(connection.callable)
		timers.clear()


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
	_check_respawned_uid_keeps_its_actor()
	_check_budget_priorities()
	await _check_real_timer_seek_and_skip()
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
	# Corrected in D4: a vanished target degrades instead of dropping, because the
	# renderer prunes a dead actor while the killer's number cue is still queued.
	_h.expect(adapter.started.size() == 2 and not drops.any(func(d: Dictionary) -> bool:
			return str(d.reason) == "missing_actor:target"),
		"missing_all_targets", "a cue whose targets all vanished must still play, without target anchors")
	_h.expect(not (adapter.started[1].anchors as Dictionary).has("targets"),
		"missing_all_targets_anchors", "a degraded cue must not report target anchors it never resolved")


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


# D5 / checklist 4.4 and 7 D5: an overflow may only degrade. Critical cues are
# never merged, never shortened and never dropped.
func _check_budget_priorities() -> void:
	var adapter := FakeAdapter.new()
	var director: RefCounted = DirectorScript.new()
	var drops: Array[Dictionary] = []
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	director.configure(FakeRegistry.new(self), FakeResolver.new(), TinyBudget.new(), adapter)
	director.begin_battle({"battle_id": "d5:critical"})
	var critical_events: Array = []
	for ordinal in 4:
		critical_events.append(_event("d5:critical", 0, ordinal, "death", "unit_%d" % ordinal, [], "critical"))
	director.enqueue_tick(0, critical_events)
	_h.expect(adapter.started.size() == 4 and drops.is_empty(),
		"critical_uncapped", "critical cue 超出微型预算时仍必须全部播放")
	for entry in adapter.started:
		var profile: Dictionary = (entry.anchors as Dictionary) if false else {}
		profile = entry.get("profile", {})
		_h.expect(int(profile.get("recovery_ms", 0)) == 200,
			"critical_no_degrade", "critical cue 的收招被缩短了")
	var stats: Dictionary = director.budget_stats()
	_h.expect(int(stats.get("merged", 0)) == 0 and int(stats.get("degraded", 0)) == 0,
		"critical_untouched", "critical cue 不应产生任何合并或降级记录")

	# important overflows: it still plays, but gives up most of its recovery tail.
	adapter = FakeAdapter.new()
	director = DirectorScript.new()
	drops.clear()
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	director.configure(FakeRegistry.new(self), FakeResolver.new(), TinyBudget.new(), adapter)
	director.begin_battle({"battle_id": "d5:important"})
	director.enqueue_tick(0, [
		_event("d5:important", 0, 0, "attack_start", "unit_a", [], "important"),
		_event("d5:important", 0, 1, "attack_start", "unit_b", [], "important"),
	])
	_h.expect(adapter.started.size() == 2 and drops.is_empty(),
		"important_still_plays", "important cue 超预算时必须降级而不是丢弃")
	_h.expect(int((adapter.started[0].get("profile", {}) as Dictionary).get("recovery_ms", 0)) == 200,
		"important_first_full", "预算内的第一条 important cue 不应被降级")
	_h.expect(int((adapter.started[1].get("profile", {}) as Dictionary).get("recovery_ms", 0)) == 100,
		"important_degraded", "超预算的 important cue 收招未按 0.5 缩短")

	# ambient merges only on overflow, and only for a repeat on the same target.
	adapter = FakeAdapter.new()
	director = DirectorScript.new()
	drops.clear()
	director.cue_dropped.connect(func(key: String, reason: String) -> void:
		drops.append({"key": key, "reason": reason}))
	director.configure(FakeRegistry.new(self), FakeResolver.new(), TinyBudget.new(), adapter)
	director.begin_battle({"battle_id": "d5:ambient"})
	director.enqueue_tick(0, [
		_event("d5:ambient", 0, 0, "hit_number", "unit_a", ["victim"], "ambient"),
		_event("d5:ambient", 0, 1, "hit_number", "unit_b", ["victim"], "ambient"),
		_event("d5:ambient", 0, 2, "hit_number", "unit_c", ["other_victim"], "ambient"),
	])
	_h.expect(drops.any(func(d: Dictionary) -> bool: return str(d.reason) == "budget_merged_ambient"),
		"ambient_merged", "同一目标的重复 ambient cue 在超预算时应被合并")
	_h.expect(adapter.started.size() == 2,
		"ambient_other_target_kept", "不同目标的 ambient cue 不能被合并掉")
	_h.expect(int(director.budget_stats().get("merged", 0)) == 1,
		"ambient_merge_count", "合并计数不正确")


# D5 / checklist 8: the D2 seek/skip pass ran on an adapter that finished inline,
# so it could not prove anything about real timers. This one completes through a
# SceneTreeTimer and asserts nothing survives a seek or a skip.
func _check_real_timer_seek_and_skip() -> void:
	var adapter := TimerAdapter.new()
	adapter.tree = get_tree()
	var director: RefCounted = DirectorScript.new()
	director.configure(FakeRegistry.new(self), FakeResolver.new(), null, adapter)
	director.begin_battle({"battle_id": "d5:timer"})
	director.enqueue_tick(1, [
		_event("d5:timer", 1, 0, "attack_start", "unit_a", [], "important"),
		_event("d5:timer", 1, 1, "attack_start", "unit_b", [], "important"),
	])
	_h.expect(adapter.started.size() == 2 and adapter.completed.is_empty(),
		"timer_pending", "真实计时器 adapter 不应立即完成 cue")
	_h.expect(adapter.timers.size() == 2, "timer_count", "两条 cue 应各留一个待触发计时器")

	director.seek_to_tick(1)
	_h.expect(adapter.cancel_calls == 1 and adapter.timers.is_empty(),
		"seek_kills_timers", "seek 之后不得留下任何待触发计时器")
	var completed_before := adapter.completed.size()
	await get_tree().create_timer(0.15).timeout
	_h.expect(adapter.completed.size() == completed_before,
		"seek_no_late_completion", "seek 之后旧计时器仍然回调了 cue")
	_h.expect(director.active_cue_count() == 0 and director.pending_cue_count() == 0,
		"seek_cleared", "seek 之后仍有残留 cue")

	# Skipping mid-flight must clear everything too, and drain immediately after.
	director.enqueue_tick(2, [_event("d5:timer", 2, 0, "attack_start", "unit_c", [], "important")])
	_h.expect(adapter.timers.size() == 1, "skip_fixture", "跳过用例没有建立待触发计时器")
	var drained := [0]
	director.presentation_drained.connect(func() -> void: drained[0] += 1)
	director.skip_to_result()
	_h.expect(adapter.timers.is_empty() and drained[0] == 1 and not director.has_blocking_cues(),
		"skip_kills_timers", "跳过后必须清空计时器并立即进入结算")
	var completed_after_skip := adapter.completed.size()
	await get_tree().create_timer(0.15).timeout
	_h.expect(adapter.completed.size() == completed_after_skip,
		"skip_no_late_completion", "跳过之后旧计时器仍然回调了 cue")


func _check_integration_loads() -> void:
	_h.expect(load("res://effects/runtime/presentation/BattleActionTrack.gd") != null,
		"track_load", "BattleActionTrack.gd failed to load")
	_h.expect(load("res://effects/runtime/presentation/BattlePresentationDirector.gd") != null,
		"director_load", "BattlePresentationDirector.gd failed to load")
	_h.expect(load("res://scenes/battle/BattleScreen.gd") != null,
		"battle_screen_load", "BattleScreen.gd failed to parse after Director integration")

	# D6: the snapshot-diff route for basic attacks and damage numbers must be gone,
	# not merely bypassed. A bypassed branch is one flag away from double playback.
	var vfx_source := FileAccess.get_file_as_string("res://scenes/battle/BattleVfx.gd")
	_h.expect(not vfx_source.is_empty(), "vfx_source_read", "无法读取 BattleVfx.gd 源码做 D6 断言")
	for removed in ["_collect_attack_events", "_play_melee_slashes", "_play_ranged_projectiles"]:
		_h.expect(not vfx_source.contains(removed),
			"diff_branch_left", "D6 应删除的快照 diff 分支仍在：%s" % removed)
	_h.expect(not vfx_source.contains("PresentationSlice"),
		"slice_left", "迁移期白名单仍被 BattleVfx 引用")
	# 反向断言：这个路径必须**不**存在，因此不是资产引用。
	_h.expect(not ResourceLoader.exists("res://effects/runtime/presentation/BattlePresentationSlice.gd"),  # asset-manifest-ignore
		"slice_file_left", "BattlePresentationSlice.gd 应在 D6 删除")
	# The cue route that replaced it must still be there.
	for kept in ["cue_play_basic_attack", "cue_spawn_hit_number", "cue_play_death"]:
		_h.expect(vfx_source.contains(kept), "cue_entry_missing", "cue 入口缺失：%s" % kept)
	# Unmigrated routes stay until their own stage migrates them.
	for kept in ["mother_execute", "unit_skill_proc", "skill_shake"]:
		_h.expect(vfx_source.contains(kept), "legacy_route_lost", "尚未迁移的旧路由被误删：%s" % kept)


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


# 召唤物用同一个 uid 反复重生，所以"交还尸体"和"注销 uid"不是一回事。
#
# 真实的失败长这样（固定第 20 回合，镜像领主）：mirror_1 死了，死亡动画开始播；动画
# 还没播完，mirror_1 已被重新召唤，新 actor 注册到同一个 uid 上；这时旧尸体播完调
# unregister_actor(uid)，抹掉的是**活着的那一个**。它随后的死亡就被 Director 判成
# missing_actor:source 丢弃 —— 玩家看到镜像凭空消失，而清单第 6 节禁止单位就这么不见。
#
# 直接测 UnitActorRegistry 而不是绕 Director：规则就在注册表里，测它才测到根。
func _check_respawned_uid_keeps_its_actor() -> void:
	var registry := RealRegistry.new()
	var old_actor := _contract_actor()
	var new_actor := _contract_actor()
	add_child(old_actor)
	add_child(new_actor)

	_h.expect(registry.register_actor("summon_1", old_actor), "respawn_register_old", "第一具 actor 没能注册")
	# 单位重生：同一个 uid 换成新 actor。
	_h.expect(registry.register_actor("summon_1", new_actor), "respawn_register_new", "重生后的 actor 没能注册")

	# 旧尸体播完才来交还 —— 它已经不是注册表里那一个，不能动。
	_h.expect(not registry.unregister_if_holds("summon_1", old_actor),
		"respawn_release_stale", "交还旧尸体时不应注销 uid：注册表里存的已经是重生后的 actor")
	_h.expect(registry.get_actor("summon_1") == new_actor,
		"respawn_actor_evicted", "重生后的 actor 被旧尸体的交还挤掉了 —— 它随后的死亡会被丢弃")

	# 交还当前这一具则必须真的注销，否则死掉的单位会一直留在注册表里。
	_h.expect(registry.unregister_if_holds("summon_1", new_actor),
		"respawn_release_current", "交还当前 actor 时应当注销")
	_h.expect(registry.get_actor("summon_1") == null, "respawn_not_cleared", "注销后仍能取到 actor")
	_h.expect(not registry.unregister_if_holds("summon_1", null), "respawn_null_guard", "传 null 不应算作注销成功")

	old_actor.queue_free()
	new_actor.queue_free()


# 满足 UnitActorRegistry 六节点契约的最小 actor。
func _contract_actor() -> Node3D:
	var root := Node3D.new()
	for node_name in RealRegistry.REQUIRED_NODES:
		var child := Node3D.new()
		child.name = str(node_name)
		root.add_child(child)
	return root
