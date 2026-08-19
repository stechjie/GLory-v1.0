class_name BattlePresentationDirector
extends RefCounted

# Presentation-only scheduler. It consumes immutable replay events and may call
# a rendering adapter, but it never owns or mutates BattleSimulator state.

signal cue_started(event_key: String)
signal cue_completed(event_key: String)
signal cue_dropped(event_key: String, reason: String)
signal presentation_drained()

const EventSchema := preload("res://scripts/battle/BattlePresentationEvent.gd")
const ActionTrack := preload("res://effects/runtime/presentation/BattleActionTrack.gd")
const VisualResolver := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const DefaultBudget := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

# D3 anchor contract. Values follow the per-type behaviour table in section 3 of
# the Director checklist: casters act from CastAnchor, bodies are struck at
# HitAnchor, numbers float from HeadAnchor and ground cues sit on FootAnchor.
const ANCHOR_ROOT := "ActorRoot"

# hit_number, impact, heal, shield and buff_apply deliberately have no source
# anchor. Section 3 forbids assuming an attacker for hit_number, and damage over
# time or healing ticks can outlive the caster actor; requiring a source there
# would swallow legitimate numbers.
const SOURCE_ANCHOR_BY_TYPE := {
	"attack_start": "CastAnchor",
	"projectile_spawn": "CastAnchor",
	"skill_cast": "CastAnchor",
	"unit_skill_proc": "CastAnchor",
	"mother_execute": "CastAnchor",
	"death": "FootAnchor",
	"summon": "FootAnchor",
}

const TARGET_ANCHOR_BY_TYPE := {
	"projectile_spawn": "HitAnchor",
	"impact": "HitAnchor",
	"shield": "HitAnchor",
	"buff_apply": "HitAnchor",
	"hit_number": "HeadAnchor",
	"heal": "HeadAnchor",
}

# Camera-only cues never touch an actor, so a unit that is still being built or
# already unregistered must not be able to suppress them.
const ACTORLESS_TYPES := {
	"skill_shake": true,
}

# Presentation-only key added to the adapter copy of an event. It never travels
# back into replay frame_events, so the frozen D0/D1 hashes stay untouched.
const RESOLVED_ANCHORS_KEY := "_resolved_anchors"

# Presentation-only too: the profile fields the adapter should honour for this
# cue, already folded through the quality tier and the budget's degradation.
const CUE_PROFILE_KEY := "_cue_profile"

enum Lifecycle {
	IDLE,
	RUNNING,
	DRAINING,
	FINISHED,
	SEEKING,
	SKIPPED,
	DISPOSED,
}

const MIN_PLAYBACK_SPEED := 0.0
const MAX_PLAYBACK_SPEED := 4.0

var _lifecycle: Lifecycle = Lifecycle.IDLE
var _playback_speed := 1.0
var _current_tick := -1
var _seek_floor_tick := -1
var _battle_context: Dictionary = {}

var _registry: Variant = null
var _resolver: Variant = null
var _budget: Variant = null
var _adapter: Variant = null

var _tracks: Dictionary = {}
var _seen_event_keys: Dictionary = {}
var _emitted_drop_keys: Dictionary = {}
var _drained_emitted := false
# Diagnostic only. A run that drops nothing proves nothing unless it also shows
# that anchors were actually resolved, so the evidence tools read these back.
var _resolution_stats: Dictionary = {"resolved_cues": 0, "resolved_anchors": 0, "degraded_anchors": 0}
# D5 budget accounting. The unit is the replay tick, not the render frame: it is
# the only clock that is identical between live play and playback.
var _tick_priority_counts: Dictionary = {}
var _live_priority_counts: Dictionary = {}
var _recent_ambient: Dictionary = {}
var _budget_stats: Dictionary = {"merged": 0, "degraded": 0, "over_budget_by_priority": {}}


func configure(registry: Variant, resolver: Variant, budget: Variant, adapter: Variant = null) -> void:
	if _lifecycle == Lifecycle.DISPOSED:
		return
	_registry = registry
	_resolver = resolver
	_budget = budget
	_adapter = adapter


func begin_battle(context: Dictionary) -> void:
	if _lifecycle == Lifecycle.DISPOSED:
		return
	# A new battle/view must not inherit callbacks, tweens, particles, or pooled
	# nodes from the previous timeline, even when the same Director is reused.
	if _lifecycle != Lifecycle.IDLE:
		_cancel_adapter_transients()
	_cancel_all_tracks("battle_reset", false)
	_tracks.clear()
	_seen_event_keys.clear()
	_emitted_drop_keys.clear()
	_battle_context = context.duplicate(true)
	_current_tick = -1
	_seek_floor_tick = -1
	_drained_emitted = false
	_resolution_stats = {"resolved_cues": 0, "resolved_anchors": 0, "degraded_anchors": 0}
	_tick_priority_counts.clear()
	_live_priority_counts.clear()
	_recent_ambient.clear()
	_budget_stats = {"merged": 0, "degraded": 0, "over_budget_by_priority": {}}
	_lifecycle = Lifecycle.RUNNING


func enqueue_tick(tick: int, raw_events: Array) -> void:
	if _lifecycle != Lifecycle.RUNNING and _lifecycle != Lifecycle.SEEKING:
		return
	if tick < 0:
		_emit_drop_once("tick:%d" % tick, "invalid_tick")
		return
	_current_tick = maxi(_current_tick, tick)
	# Each replay tick gets its own spawn allowance; the live counters persist.
	_tick_priority_counts.clear()
	for ordinal in raw_events.size():
		var raw: Variant = raw_events[ordinal]
		if not (raw is Dictionary):
			_emit_drop_once("tick:%d:%d" % [tick, ordinal], "invalid_event_type")
			continue
		var event := _normalized_event(raw as Dictionary, tick, ordinal)
		var event_key := str(event.get("event_key", "tick:%d:%d" % [tick, ordinal]))
		var errors := EventSchema.validate(event)
		if int(event.get("tick", -1)) != tick:
			errors.append("tick_bucket_mismatch")
		if not errors.is_empty():
			_emit_drop_once(event_key, "invalid_event:%s" % ",".join(errors))
			continue
		if _seen_event_keys.has(event_key):
			_emit_drop_once(event_key, "duplicate_event_key")
			continue
		_seen_event_keys[event_key] = true
		# Seeking consumes historical transient events without replaying numbers,
		# shake, or one-shot cues. Persistent actor reconstruction belongs to D3.
		if tick <= _seek_floor_tick:
			continue
		_enqueue_event(event)
	if _lifecycle == Lifecycle.DRAINING:
		_check_drained()


func set_playback_speed(speed: float) -> void:
	if _lifecycle == Lifecycle.DISPOSED:
		return
	_playback_speed = clampf(speed, MIN_PLAYBACK_SPEED, MAX_PLAYBACK_SPEED)
	if _playback_speed > 0.0:
		_pump_all_tracks()


func seek_to_tick(tick: int) -> void:
	if _lifecycle == Lifecycle.IDLE or _lifecycle == Lifecycle.DISPOSED or _lifecycle == Lifecycle.SKIPPED:
		return
	_lifecycle = Lifecycle.SEEKING
	_cancel_adapter_transients()
	for track_value in _tracks.values():
		var track: RefCounted = track_value
		track.call("reset_for_seek")
	_tracks.clear()
	_current_tick = maxi(-1, tick)
	_seek_floor_tick = maxi(-1, tick)
	_lifecycle = Lifecycle.RUNNING


func begin_draining() -> void:
	if _lifecycle == Lifecycle.FINISHED or _lifecycle == Lifecycle.SKIPPED or _lifecycle == Lifecycle.DISPOSED:
		return
	if _lifecycle == Lifecycle.IDLE:
		_lifecycle = Lifecycle.FINISHED
		_emit_drained_once()
		return
	_lifecycle = Lifecycle.DRAINING
	_pump_all_tracks()
	_check_drained()


func skip_to_result() -> void:
	if _lifecycle == Lifecycle.SKIPPED or _lifecycle == Lifecycle.DISPOSED:
		return
	_cancel_adapter_transients()
	_cancel_all_tracks("skipped", false)
	_tracks.clear()
	_lifecycle = Lifecycle.SKIPPED
	_emit_drained_once()


func has_blocking_cues() -> bool:
	for track_value in _tracks.values():
		var track: RefCounted = track_value
		var active: Dictionary = track.call("active_event")
		if _is_blocking(active):
			return true
		var pending: Array[Dictionary] = track.call("pending_events")
		for event in pending:
			if _is_blocking(event):
				return true
	return false


func dispose() -> void:
	if _lifecycle == Lifecycle.DISPOSED:
		return
	_cancel_adapter_transients()
	_cancel_all_tracks("disposed", false)
	_tracks.clear()
	_seen_event_keys.clear()
	_emitted_drop_keys.clear()
	_battle_context.clear()
	_registry = null
	_resolver = null
	_budget = null
	_adapter = null
	_lifecycle = Lifecycle.DISPOSED


func get_lifecycle() -> Lifecycle:
	return _lifecycle


func get_playback_speed() -> float:
	return _playback_speed


func get_current_tick() -> int:
	return _current_tick


func active_cue_count() -> int:
	var count := 0
	for track_value in _tracks.values():
		if bool((track_value as RefCounted).call("has_active")):
			count += 1
	return count


func pending_cue_count() -> int:
	var count := 0
	for track_value in _tracks.values():
		count += int((track_value as RefCounted).call("pending_count"))
	return count


func _normalized_event(raw: Dictionary, tick: int, ordinal: int) -> Dictionary:
	if raw.has("schema_version") and raw.has("event_key"):
		return raw.duplicate(true)
	var battle_id := str(raw.get("battle_id", _battle_context.get("battle_id", "presentation")))
	return EventSchema.normalize(raw, battle_id, tick, ordinal)


func _enqueue_event(event: Dictionary) -> void:
	var source_uid := str(event.get("source_uid", ""))
	var track := _track_for(source_uid)
	if str(event.get("type", "")) == "death":
		var cancelled: Array[Dictionary] = track.call("mark_source_dead")
		for cancelled_event in cancelled:
			_emit_drop_once(str(cancelled_event.get("event_key", "")), "source_dead")
	if not bool(track.call("enqueue", event)):
		_emit_drop_once(str(event.get("event_key", "")), "source_dead")
		return
	_pump_track(source_uid)


func _track_for(source_uid: String) -> RefCounted:
	if not _tracks.has(source_uid):
		_tracks[source_uid] = ActionTrack.new(source_uid)
	return _tracks[source_uid]


func _pump_all_tracks() -> void:
	if _playback_speed <= 0.0:
		return
	var ids: Array = _tracks.keys()
	ids.sort()
	for source_uid_value in ids:
		_pump_track(str(source_uid_value))


func _pump_track(source_uid: String) -> void:
	if _playback_speed <= 0.0 or not _tracks.has(source_uid):
		return
	var track: RefCounted = _tracks[source_uid]
	if bool(track.call("has_active")):
		return
	var event: Dictionary = track.call("take_next")
	while not event.is_empty():
		var event_key := str(event.get("event_key", ""))
		if _lifecycle == Lifecycle.DRAINING and not _is_blocking(event):
			track.call("complete_active", event_key)
			_emit_drop_once(event_key, "drain_nonblocking")
			event = track.call("take_next")
			continue
		# D3: anchors resolve at play time, never at enqueue time and never into a
		# cached NodePath, so a unit that died or was rebuilt between ticks cannot
		# leave a dangling reference behind (checklist 5.4).
		var resolution := _resolve_cue(event)
		if not bool(resolution.get("ok", true)):
			track.call("complete_active", event_key)
			_emit_drop_once(event_key, str(resolution.get("reason", "unresolved_actor")))
			event = track.call("take_next")
			continue
		var budget_decision := _budget_decision(event)
		if str(budget_decision.get("action", "")) == "merge":
			# Merging is not dropping: the identical ambient cue that is already on
			# screen for this target stands in for this one (checklist 4.4).
			track.call("complete_active", event_key)
			_budget_stats["merged"] = int(_budget_stats["merged"]) + 1
			_emit_drop_once(event_key, "budget_merged_ambient")
			event = track.call("take_next")
			continue
		_tally_resolution(resolution)
		_note_cue_started(event, budget_decision)
		cue_started.emit(event_key)
		if _adapter != null and _adapter.has_method("play_cue"):
			var completion := Callable(self, "_on_cue_completed").bind(source_uid, event_key)
			var accepted := bool(_adapter.call("play_cue", _adapter_payload(event, resolution, budget_decision), completion, _playback_speed))
			if not accepted:
				track.call("complete_active", event_key)
				_note_cue_finished(event)
				_emit_drop_once(event_key, "adapter_rejected")
				event = track.call("take_next")
				continue
		else:
			# The D2 null adapter completes inline. Keep it iterative so a dense
			# replay tick cannot grow the call stack with one recursion per cue.
			var completed: Dictionary = track.call("complete_active", event_key)
			if not completed.is_empty():
				_note_cue_finished(completed)
				cue_completed.emit(event_key)
			event = track.call("take_next")
			continue
		return
	if _lifecycle == Lifecycle.DRAINING:
		_check_drained()


# Resolves every anchor a cue needs through UnitActorRegistry only (checklist
# 5.2). Returns {ok, reason, anchors}; anchors hold plain Vector3 world
# positions so the Director never retains a Node or a NodePath.
func _resolve_cue(event: Dictionary) -> Dictionary:
	var out := {"ok": true, "reason": "", "anchors": {}}
	if not _registry_can_resolve():
		return out
	var event_type := str(event.get("type", ""))
	if ACTORLESS_TYPES.has(event_type):
		return out
	var anchors: Dictionary = out["anchors"]
	var source_anchor := str(SOURCE_ANCHOR_BY_TYPE.get(event_type, ""))
	if not source_anchor.is_empty():
		var source_uid := str(event.get("source_uid", ""))
		if _registry.call("get_actor", source_uid) == null:
			out["ok"] = false
			out["reason"] = "missing_actor:source"
			return out
		anchors["source"] = _anchor_position(source_uid, source_anchor, event_type)
	var target_anchor := str(TARGET_ANCHOR_BY_TYPE.get(event_type, ""))
	if target_anchor.is_empty():
		return out
	var target_uids: Array = event.get("target_uids", [])
	if target_uids.is_empty():
		return out
	var resolved: Dictionary = {}
	var missing: Array[String] = []
	for uid_value in target_uids:
		var uid := str(uid_value)
		if _registry.call("get_actor", uid) == null:
			missing.append(uid)
			continue
		resolved[uid] = _anchor_position(uid, target_anchor, event_type)
	# A target can legitimately vanish between enqueue and playback: the renderer
	# prunes a dead unit's actor on the next refresh, while the killer's impact and
	# damage-number cues are still queued behind its windup. Dropping here would
	# swallow exactly the killing blow the player most needs to read, so a missing
	# target degrades to "no target anchor" and is reported, following the same
	# degrade-don't-drop rule the checklist uses for a missing profile (4.2).
	# Only a missing *source* actor still drops: without the performer there is
	# nothing to play at all.
	if not resolved.is_empty():
		anchors["targets"] = resolved
	for uid in missing:
		_report_actor_failure(uid, "missing target actor for %s" % event_type)
	return out


func _anchor_position(uid: String, anchor_name: String, event_type: String) -> Vector3:
	var anchor: Variant = _registry.call("get_anchor", uid, anchor_name)
	if anchor is Node3D and (anchor as Node3D).is_inside_tree():
		return (anchor as Node3D).global_position
	# Checklist 5.2 requires every actor to expose this anchor, so a missing one is
	# a defect that must be reported. Degrading to ActorRoot keeps the cue playable
	# instead of silently dropping it (checklist 4.2 and section 7 D3).
	_resolution_stats["degraded_anchors"] = int(_resolution_stats["degraded_anchors"]) + 1
	_report_actor_failure(uid, "missing anchor %s for %s" % [anchor_name, event_type])
	var root: Variant = _registry.call("get_anchor", uid, ANCHOR_ROOT)
	if root is Node3D and (root as Node3D).is_inside_tree():
		return (root as Node3D).global_position
	var actor: Variant = _registry.call("get_actor", uid)
	if actor is Node3D and (actor as Node3D).is_inside_tree():
		return (actor as Node3D).global_position
	return Vector3.ZERO


# Decides whether this cue plays as authored, plays degraded, or is merged into an
# identical ambient cue that is already on screen. A critical cue always plays as
# authored: checklist 7 D5 allows an overflow to degrade but never to make a
# Boss/death/control cue disappear.
func _budget_decision(event: Dictionary) -> Dictionary:
	var priority := str(event.get("visibility_priority", EventSchema.VISIBILITY_AMBIENT))
	var profile := _profile_fields(event)
	var out := {"action": "play", "priority": priority, "profile": profile, "over_budget": false}
	var budget: Variant = _budget_source()
	if budget == null:
		return out
	if priority == EventSchema.VISIBILITY_CRITICAL:
		return out
	var per_tick: int = budget.max_cues_per_tick(priority)
	var live: int = budget.max_live_cues(priority)
	var started_this_tick := int(_tick_priority_counts.get(priority, 0))
	var live_now := int(_live_priority_counts.get(priority, 0))
	var over := (per_tick >= 0 and started_this_tick >= per_tick) or (live >= 0 and live_now >= live)
	if not over:
		return out
	# Merging is a budget measure, not a default. Checklist 4.4 allows ambient cues
	# on the same target inside a short window to be merged *when events overflow*;
	# doing it unconditionally would hide damage numbers while there is plenty of
	# budget left, which loses information the player needs.
	if budget.may_merge(priority) and _ambient_is_redundant(event, budget):
		out["action"] = "merge"
		return out
	out["over_budget"] = true
	var counts: Dictionary = _budget_stats["over_budget_by_priority"]
	counts[priority] = int(counts.get(priority, 0)) + 1
	_budget_stats["degraded"] = int(_budget_stats["degraded"]) + 1
	# Degrade rather than drop: the tail is the cheapest thing to give up.
	if not profile.is_empty():
		var scale: float = budget.recovery_scale_when_over_budget(priority)
		profile["recovery_ms"] = int(round(float(int(profile.get("recovery_ms", 0))) * scale))
		out["profile"] = profile
	return out


func _ambient_is_redundant(event: Dictionary, budget: Variant) -> bool:
	var key := _ambient_key(event)
	if key.is_empty():
		return false
	if not _recent_ambient.has(key):
		return false
	var last_ms := int(_recent_ambient[key])
	return _tick_ms() - last_ms < int(budget.ambient_merge_window_ms())


func _ambient_key(event: Dictionary) -> String:
	var targets: Array = event.get("target_uids", [])
	if targets.is_empty():
		return ""
	return "%s|%s" % [str(event.get("type", "")), str(targets[0])]


# Replay ticks are the presentation clock here: one tick is 100 ms of battle time.
func _tick_ms() -> int:
	return int(_current_tick) * 100


func _note_cue_started(event: Dictionary, decision: Dictionary) -> void:
	var priority := str(decision.get("priority", EventSchema.VISIBILITY_AMBIENT))
	if priority == EventSchema.VISIBILITY_AMBIENT:
		# Only a cue that really started counts as the one already on screen for
		# this target, so a later overflow can tell a repeat from a first sighting.
		var key := _ambient_key(event)
		if not key.is_empty():
			_recent_ambient[key] = _tick_ms()
	_tick_priority_counts[priority] = int(_tick_priority_counts.get(priority, 0)) + 1
	_live_priority_counts[priority] = int(_live_priority_counts.get(priority, 0)) + 1


func _note_cue_finished(event: Dictionary) -> void:
	var priority := str(event.get("visibility_priority", EventSchema.VISIBILITY_AMBIENT))
	var live_now := int(_live_priority_counts.get(priority, 0))
	_live_priority_counts[priority] = maxi(0, live_now - 1)


func _profile_fields(event: Dictionary) -> Dictionary:
	if _resolver == null or not _resolver.has_method("resolve_fields"):
		return {}
	return _resolver.call("resolve_fields", event)


# Tests inject their own budget; production leaves it null and uses the shared
# VFXQualityBudget so the tier set elsewhere in the game applies here too.
func _budget_source() -> Variant:
	if _budget != null and _budget.has_method("max_cues_per_tick"):
		return _budget
	return DefaultBudget


func budget_stats() -> Dictionary:
	return _budget_stats.duplicate(true)


func resolution_stats() -> Dictionary:
	return _resolution_stats.duplicate(true)


func _tally_resolution(resolution: Dictionary) -> void:
	var anchors: Dictionary = resolution.get("anchors", {})
	if anchors.is_empty():
		return
	_resolution_stats["resolved_cues"] = int(_resolution_stats["resolved_cues"]) + 1
	var count := 1 if anchors.has("source") else 0
	var targets: Dictionary = anchors.get("targets", {})
	count += targets.size()
	_resolution_stats["resolved_anchors"] = int(_resolution_stats["resolved_anchors"]) + count


func _registry_can_resolve() -> bool:
	return _registry != null and _registry.has_method("get_actor") and _registry.has_method("get_anchor")


# Reuses the existing one-shot aggregate (unit_id / resource_path / consumer)
# rather than opening a second warning channel (checklist 5.3 and 0.4).
func _report_actor_failure(uid: String, reason: String) -> void:
	VisualResolver.report_failure(uid, _actor_resource_path(uid), "director", reason)


func _actor_resource_path(uid: String) -> String:
	var actor: Variant = _registry.call("get_actor", uid)
	if not (actor is Node3D):
		return ""
	var node := actor as Node3D
	if not node.scene_file_path.is_empty():
		return node.scene_file_path
	# UnitActor3D is built in code, so the real resource path lives on the model
	# instance parented under ActorRoot.
	var root := node.get_node_or_null(ANCHOR_ROOT)
	if root != null:
		for child in root.get_children():
			if child is Node and not (child as Node).scene_file_path.is_empty():
				return (child as Node).scene_file_path
	return ""


# The adapter gets a copy plus resolved world positions. RESOLVED_ANCHORS_KEY is
# presentation-only and never written back into replay frame_events.
func _adapter_payload(event: Dictionary, resolution: Dictionary, budget_decision: Dictionary) -> Dictionary:
	var payload := event.duplicate(true)
	var anchors: Dictionary = resolution.get("anchors", {})
	if not anchors.is_empty():
		payload[RESOLVED_ANCHORS_KEY] = anchors
	var profile: Dictionary = budget_decision.get("profile", {})
	if not profile.is_empty():
		payload[CUE_PROFILE_KEY] = profile
	return payload


func _on_cue_completed(source_uid: String, event_key: String) -> void:
	if _lifecycle == Lifecycle.DISPOSED or not _tracks.has(source_uid):
		return
	var track: RefCounted = _tracks[source_uid]
	var completed: Dictionary = track.call("complete_active", event_key)
	if completed.is_empty():
		return
	_note_cue_finished(completed)
	cue_completed.emit(event_key)
	_pump_track(source_uid)
	if _lifecycle == Lifecycle.DRAINING:
		_check_drained()


func _check_drained() -> void:
	if _lifecycle != Lifecycle.DRAINING or has_blocking_cues():
		return
	_cancel_adapter_transients()
	_cancel_all_tracks("drain_nonblocking", false)
	_tracks.clear()
	_lifecycle = Lifecycle.FINISHED
	_emit_drained_once()


func _cancel_all_tracks(reason: String, emit_drops: bool) -> void:
	# Every track is going away, so no cue can still be occupying a live slot.
	_live_priority_counts.clear()
	for track_value in _tracks.values():
		var cancelled: Array[Dictionary] = (track_value as RefCounted).call("cancel_all")
		if emit_drops:
			for event in cancelled:
				_emit_drop_once(str(event.get("event_key", "")), reason)


func _cancel_adapter_transients() -> void:
	if _adapter != null and _adapter.has_method("cancel_all_transient"):
		_adapter.call("cancel_all_transient")


func _is_blocking(event: Dictionary) -> bool:
	if event.is_empty():
		return false
	var priority := str(event.get("visibility_priority", EventSchema.VISIBILITY_AMBIENT))
	return priority == EventSchema.VISIBILITY_CRITICAL or priority == EventSchema.VISIBILITY_IMPORTANT


func _emit_drop_once(event_key: String, reason: String) -> void:
	var stable_key := event_key if not event_key.is_empty() else "<missing_event_key>"
	var drop_key := "%s|%s" % [stable_key, reason]
	if _emitted_drop_keys.has(drop_key):
		return
	_emitted_drop_keys[drop_key] = true
	cue_dropped.emit(stable_key, reason)


func _emit_drained_once() -> void:
	if _drained_emitted:
		return
	_drained_emitted = true
	presentation_drained.emit()
