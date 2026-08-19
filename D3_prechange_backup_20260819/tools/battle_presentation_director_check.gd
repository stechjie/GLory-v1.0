extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const DirectorScript := preload("res://effects/runtime/presentation/BattlePresentationDirector.gd")
const EventSchema := preload("res://scripts/battle/BattlePresentationEvent.gd")


class FakeRegistry:
	extends RefCounted
	var cleared := 0

	func clear() -> void:
		cleared += 1


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
	_check_integration_loads()
	_h.finish(get_tree())


func _check_lifecycle_and_null_adapter() -> void:
	var director: RefCounted = DirectorScript.new()
	var registry := FakeRegistry.new()
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
	director.configure(FakeRegistry.new(), null, null, adapter)
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
	director.configure(FakeRegistry.new(), null, null, adapter)
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
	director.configure(FakeRegistry.new(), null, null, adapter)
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
	director.configure(FakeRegistry.new(), null, null)
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
	director.configure(FakeRegistry.new(), null, null)
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
	director.configure(FakeRegistry.new(), null, null, adapter)
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
	director.configure(FakeRegistry.new(), null, null, adapter)
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
	director.configure(FakeRegistry.new(), null, null, adapter)
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
