extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Director := preload("res://effects/runtime/presentation/BattlePresentationDirector.gd")
const Adapter := preload("res://effects/runtime/presentation/adapters/LegacyBattleVfxAdapter.gd")
const Resolver := preload("res://effects/runtime/presentation/VfxProfileResolver.gd")
const Recovery := preload("res://scripts/battle/BattlePlaybackRecovery.gd")
const Config := preload("res://scripts/multiplayer/NetworkConfig.gd")

class Host:
	extends Node
	var shots: Dictionary = {}
	var hits: Dictionary = {}
	var impacts: Dictionary = {}
	var deaths: Dictionary = {}
	var numbers: Array = []
	var melee_count := 0
	func cue_play_basic_attack(_source: String, target: String, ranged: bool) -> bool:
		if ranged: shots[target] = Time.get_ticks_usec()
		else: melee_count += 1
		return true
	func cue_play_attack_lunge(_source: String, _target: String, _ranged: bool) -> bool:
		return true
	func cue_ranged_flight_time(_source: String, _target: String) -> float:
		return 0.80
	func cue_play_impact_feedback(target: String, _crit: bool) -> void:
		impacts[target] = Time.get_ticks_usec()
	func cue_spawn_hit_number(target: String, _amount: int, _kind: String, _crit: bool, _skill: bool, _race: String) -> void:
		hits[target] = Time.get_ticks_usec()
		numbers.append(_amount)
	func cue_play_death(uid: String, _duration: float) -> bool:
		deaths[uid] = Time.get_ticks_usec()
		return true

# Replace only GPU/resource work; run the production _start_replay/_process guards.
class SetupProbe:
	extends "res://scenes/battle/BattleScreen.gd"
	var music_resolved := false
	func _ready() -> void:
		set_process(false)
	func _exit_tree() -> void:
		_presentation_director.dispose()
	func _prefetch_battle_assets() -> void:
		pass
	func _build() -> void:
		pass
	func _setup_view_toggle() -> void:
		pass
	func _start_battle_music() -> void:
		pass
	func _begin_presentation_replay(_data: Dictionary) -> void:
		pass
	func _load_replay_roster(_data: Dictionary) -> void:
		var living: Array = []
		for i in MODELS_PER_FRAME:
			living.append({"uid": "setup_%d" % i, "alive": true})
		_state = {"kind": "pve", "player": living, "enemy": []}
	func _sync_3d_model_nodes(_fighters: Array, _facing_delta: float, _prune: bool = true) -> void:
		pass
	func _apply_replay_frame(_frame: int) -> void:
		pass
	func _resolve_pending_battle_music() -> void:
		# Model the real Boss audio wait independently of model setup.
		for i in 8:
			await get_tree().process_frame
		music_resolved = true
	func _compute_readable_speed() -> float:
		return 1.0
	func _refresh_visuals() -> void:
		pass
	func _update_vfx_camera_shake() -> void:
		pass
	func _update_crystal_demo(_delta: float) -> void:
		pass

class ResourceProbe:
	extends SetupProbe
	var asset_failure := ""
	func _fail_team_replay(reason: String) -> void:
		asset_failure = reason
		_finished = true

class DrainProbe:
	extends RefCounted
	var blocked := true
	var skipped := false
	func has_blocking_cues() -> bool:
		return blocked
	func dispose() -> void:
		pass
	func skip_to_result() -> void:
		blocked = false
		skipped = true

var _h: RefCounted

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	_h = Harness.new("battle_playback_stability")
	await _check_overlapping_flights()
	await _check_qa2_source_death_tails()
	await _check_cancel_and_timer_release()
	await _check_resource_gate()
	await _check_setup_guard()
	await _check_slow_drain_preserves_attacks()
	await _check_recovery()
	_h.finish(get_tree())

func _events(tick: int, target: String) -> Array:
	var events: Array = []
	for kind in ["attack_start", "projectile_spawn", "impact", "hit_number"]:
		events.append({"type": kind, "source_uid": "archer", "target_uid": target,
			"skill_id": "basic_ranged", "amount": 1})
	return events

func _check_overlapping_flights() -> void:
	var host := Host.new()
	add_child(host)
	var adapter := Adapter.new(host)
	var director := Director.new()
	var resolver := Resolver.new()
	_h.expect(resolver.load_profiles() == 5, "profiles", "real cue profiles must load")
	director.configure(null, resolver, null, adapter)
	director.begin_battle({"battle_id": "stability"})
	# Legal max attack speed from BattleSimulator: 2.5/s, every four 100ms ticks.
	for tick in 80:
		director.enqueue_tick(tick, _events(tick, "target_%d" % tick) if tick % 4 == 0 else [])
		await get_tree().create_timer(0.1).timeout
	_h.expect(host.shots.size() == 20, "fire_rate", "8s must emit all 20 shots, got %d" % host.shots.size())
	_h.expect(director.pending_cue_count() == 0, "no_queue_backlog", "flight time must not accumulate caster actions")
	_h.expect(director.has_blocking_cues(), "airborne_blocks_result", "last airborne shots must hold the result")
	director.begin_draining()
	await get_tree().create_timer(1.2).timeout
	_h.expect(host.hits.size() == 20, "all_hits_presented", "every projectile must retain its corresponding hit")
	_h.expect(not director.has_blocking_cues(), "bounded_drain", "flight tails must finish within 1.2s")
	for target in host.hits:
		_h.expect(int(host.hits[target]) - int(host.shots[target]) >= 780000,
			"hit_after_flight", "hit occurred before its 0.8s projectile: %s" % target)
	_h.note("8s at 2.5/s: shots=%d hits=%d pending=%d" % [host.shots.size(), host.hits.size(), director.pending_cue_count()])
	director.dispose()
	host.queue_free()

func _check_qa2_source_death_tails() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://tools/fixtures/battle_source_death_qa2.json"))
	var probes: Array = []
	for sample in fixture.cases:
		var host := Host.new()
		add_child(host)
		var director := Director.new()
		director.configure(null, null, null, Adapter.new(host))
		var events: Array = sample.events
		director.begin_battle({"battle_id": events[0].battle_id})
		var probe := {"host": host, "director": director, "sample": sample,
			"started": [], "drops": []}
		director.cue_started.connect(func(key: String) -> void: probe.started.append(key))
		director.cue_dropped.connect(func(key: String, reason: String) -> void:
			probe.drops.append({"key": key, "reason": reason}))
		var first: Array = []
		for event in events:
			if int(event.tick) == int(events[0].tick): first.append(event)
		director.enqueue_tick(int(events[0].tick), first)
		probes.append(probe)
	# The real death tick is 100ms later, inside the adapter's 120ms windup.
	# Use 50ms to keep that ordering deterministic on slow headless runners.
	await get_tree().create_timer(0.05).timeout
	for probe in probes:
		var events: Array = probe.sample.events
		var death: Dictionary = events.back()
		var director: RefCounted = probe.director
		if int(death.tick) != int(events[0].tick):
			director.enqueue_tick(int(death.tick), [death])
		# Duplicate delivery must not replay any accepted pre-death cue.
		for event in events:
			director.enqueue_tick(int(event.tick), [event])
		# This is a genuinely new attack after the source died; keep rejecting it.
		director.enqueue_tick(int(death.tick) + 1, [{"type": "attack_start",
			"source_uid": probe.sample.source_uid, "target_uid": "invalid_after_death",
			"skill_id": "basic_ranged"}])
		director.begin_draining()
		_h.expect(director.has_blocking_cues(), "death_tail_blocks_result",
			"result must wait for accepted pre-death work: %s" % probe.sample.source_uid)
	await get_tree().create_timer(1.15).timeout
	for probe in probes:
		var host: Host = probe.host
		var director: RefCounted = probe.director
		var expected: Array = []
		var amounts: Array = []
		for event in probe.sample.events:
			expected.append(event.event_key)
			if event.type == "hit_number": amounts.append(int(event.amount))
		var label := "round %d %s" % [probe.sample.round, probe.sample.source_uid]
		_h.expect(probe.started == expected, "qa2_tail_order", label + " lost or reordered accepted cues")
		var dead_drops := 0
		for drop in probe.drops:
			if drop.reason == "source_dead": dead_drops += 1
		_h.expect(dead_drops == 1,
			"only_new_dead_attack_rejected", label + " cancelled pre-death tails or replayed new attack")
		_h.expect(host.numbers == amounts, "qa2_damage_unchanged", label + " lost or duplicated damage numbers")
		_h.expect(not director.has_blocking_cues(), "qa2_tail_drained", label + " did not finish")
		for target in host.shots:
			_h.expect(int(host.deaths[probe.sample.source_uid]) >= int(host.shots[target]),
				"death_after_launch", label + " died before its accepted projectile launched")
			_h.expect(int(host.impacts.get(target, 0)) - int(host.shots[target]) >= 780000,
				"death_impact_after_flight", label + " impact did not wait for the original flight")
			if host.hits.has(target):
				_h.expect(int(host.hits[target]) - int(host.shots[target]) >= 780000,
					"death_number_after_flight", label + " damage number did not wait for the original flight")
		director.dispose()
		host.queue_free()
	_h.note("QA2 source-death tails: %d exact device event chains" % probes.size())

func _check_cancel_and_timer_release() -> void:
	var host := Host.new()
	add_child(host)
	var adapter := Adapter.new(host)
	adapter.call("_finish_after", 0.02, func() -> void: pass, "weakref_test")
	var timers: Array = adapter.get("_pending_timers")
	var timer_ref: WeakRef = weakref(timers[0])
	timers = []
	await get_tree().create_timer(0.1).timeout
	_h.expect(timer_ref.get_ref() == null, "timer_released", "completed timer retained its lambda/adapter cycle")
	var director := Director.new()
	director.configure(null, null, null, adapter)
	director.begin_battle({"battle_id": "skip"})
	director.enqueue_tick(0, _events(0, "cancelled"))
	await get_tree().create_timer(0.2).timeout
	_h.expect(host.shots.size() == 1 and host.hits.is_empty(), "skip_airborne_fixture", "fixture must reach the airborne phase")
	director.skip_to_result()
	await get_tree().create_timer(0.9).timeout
	_h.expect(host.hits.is_empty() and not adapter.has_pending_cues(), "skip_cancels_flight_tail", "old flight callbacks survived skip")
	director.dispose()
	host.queue_free()

func _fixture_replay(id: String) -> Dictionary:
	var frames: Array = []
	for i in 30:
		frames.append([["u", 0, 0, 10, true]])
	return {"battle_id": id, "kind": "pve", "roster": {"u": {}}, "frames": frames,
		"frame_events": [[{"battle_id": id + ":team0"}]], "result": {"kind": "pve"}}

func _finish_drain(probe: Control, done: Array) -> void:
	await probe.call("_await_presentation_drained")
	done[0] = true

func _check_slow_drain_preserves_attacks() -> void:
	var probe := SetupProbe.new()
	add_child(probe)
	var director := DrainProbe.new()
	probe.set("_presentation_director", director)
	var done: Array = [false]
	_finish_drain(probe, done)
	await get_tree().create_timer(3.1).timeout
	_h.expect(not bool(done[0]), "no_result_at_wall_clock_cap", "result bypassed an unfinished valid attack after 3s")
	probe.set("_replay_mode", true)
	probe.set("_return_emitted", true)
	probe.call("_skip_animation")
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(bool(done[0]) and director.skipped, "explicit_skip_releases_stuck_drain", "explicit skip failed to cancel an uncompleted adapter")
	probe.queue_free()
	await get_tree().process_frame

func _check_resource_gate() -> void:
	var probe := ResourceProbe.new()
	add_child(probe)
	var model_path := "res://tools/battle_playback_stability_check.tscn"
	# A later summon still belongs to the full replay roster, even before it is
	# present in frame zero or the living unit array used by the renderer.
	probe.set("_replay_own", {"roster": {"later_summon": {"def": {"model": model_path}}}})
	_h.expect(await probe.call("_prepare_replay_assets"), "direct_entry_assets_ready",
		"cold battle entry failed to finish its exact roster resource request")
	_h.expect(BattleAssetService.ready_count([model_path]) == 1,
		"future_summon_resource_prepared", "a later roster summon would still cold-load during combat")
	probe.set("_replay_own", {"roster": {"missing": {"def": {"model": "res://missing_stability_model.tscn"}}}})
	_h.expect(not await probe.call("_prepare_replay_assets") and probe.asset_failure == "battle_assets_missing",
		"missing_asset_fails_explicitly", "missing resources must not wait forever or silently enter combat")
	BattleAssetService.release_owner(BattleAssetService.OWNER_BATTLE)
	probe.queue_free()
	await get_tree().process_frame

func _check_setup_guard() -> void:
	var probe := SetupProbe.new()
	add_child(probe)
	probe.set("_battle_setup_ready", true) # fallback waiting path before replay arrives
	probe.set("_sim_accumulator", 0.2)
	probe.call("_start_replay", _fixture_replay("room:1:2"))
	_h.expect(not bool(probe.get("_battle_setup_ready")), "setup_gates_playback", "fallback ready flag survived start_replay")
	probe.set("_replay_rival", _fixture_replay("room:1:2"))
	probe.call("_on_view_toggle_pressed")
	_h.expect(not bool(probe.get("_watching_rival")), "no_view_switch_during_prepare", "view toggle bypassed preparation and rebuilt the live roster")
	probe.call("_process", 0.25)
	_h.expect(int(probe.get("_replay_frame")) == 0 and is_zero_approx(float(probe.get("_sim_accumulator"))),
		"no_hidden_catchup", "timeline advanced while models were hidden/building")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	probe.call("_process", 0.1)
	_h.expect(int(probe.get("_replay_frame")) == 1, "starts_after_setup", "playback failed to start once model setup completed")
	_h.expect(not probe.music_resolved, "music_wait_does_not_gate_combat",
		"the timeline waited for the intro audio instead of starting with its Director")
	for stall in [0.5, 2.0, 5.0]:
		probe.set("_sim_accumulator", 0.0)
		probe.set("_replay_frame", 1)
		probe.call("_process", stall)
		var advanced := int(probe.get("_replay_frame"))
		_h.expect(advanced <= 4, "stall_steps_bounded", "one stalled render frame replayed more than 3 ticks")
		probe.call("_process", 0.0)
		_h.expect(int(probe.get("_replay_frame")) == advanced,
			"no_permanent_catchup", "discarded wall-clock debt continued to replay on a zero-delta frame")
	for i in 8:
		await get_tree().process_frame
	probe.queue_free()
	await get_tree().process_frame
	var expired := ResourceProbe.new()
	add_child(expired)
	expired.set("_battle_prepare_deadline_msec", Time.get_ticks_msec() - 1)
	_h.expect(bool(expired.call("_prepare_deadline_expired")) and expired.asset_failure == "battle_prepare_timeout",
		"preparation_total_deadline", "resource/model/draw preparation has one explicit failure boundary")
	expired.queue_free()
	await get_tree().process_frame

func _check_recovery() -> void:
	var replay := _fixture_replay("room:4:7")
	var state := {"battle_id": "room:4:7", "completed_round": 4, "round_index": 5, "run_over": false, "protocol": Config.NETWORK_PROTOCOL_VERSION}
	_h.expect(Recovery.ready("room:4:7", 4, "room:4:7", replay, state), "paired_recovery", "matching replay/result rejected")
	_h.expect(not Recovery.ready("room:4:7", 4, "old:4:7", replay, state), "stale_replay", "stale transfer accepted")
	_h.expect(not Recovery.ready("room:4:7", 5, "room:4:7", replay, state), "wrong_round", "cross-round result accepted")
	_h.expect(Recovery.needs_replay({"phase": "result", "replay_available": false, "replay_pending": true}),
		"pending_is_not_missing", "server computation pending must not skip the replay")
	_h.expect(not Recovery.needs_replay({"phase": "result", "replay_available": false}),
		"explicitly_unavailable", "missing server cache should have explicit fallback")
	_h.expect(Recovery.resolve_resume({"phase": "result", "round_id": 5}, {}).is_empty(),
		"legacy_waits_for_identity", "legacy snapshot guessed identity before authoritative result")
	_h.expect(Recovery.resolve_resume({"phase": "result", "round_id": 6}, state).is_empty(),
		"legacy_rejects_old_result", "previous completed round matched a later recovery")
	var final_payload := {"phase": "result", "round_id": 21, "run_over": true}
	_h.expect(Recovery.resolve_resume(final_payload, {"battle_id": "room:20:9", "completed_round": 20,
		"round_index": 21, "run_over": false}).is_empty(), "legacy_final_rejects_penultimate",
		"next-round clamp paired final recovery with previous boss result")
	_h.expect(int(Recovery.resolve_resume(final_payload, {"battle_id": "room:21:10", "completed_round": 21,
		"round_index": 21, "run_over": true}).get("battle_round", -1)) == 21,
		"legacy_final_matches_completed_round", "final recovery could not resolve its actual completed round")
	var main: Control = load("res://tools/battle_playback_main_probe.gd").new()
	add_child(main)
	var battle := SetupProbe.new()
	main.add_child(battle)
	battle.set("_replay_mode", true)
	battle.set("_replay_own", replay)
	battle.set("_replay_round", 4)
	battle.set("_replay_frame", 17)
	main.set("_battle", battle)
	GameState.round_index = 4
	main.call("_on_resume_completed", {"battle_id": "room:4:7", "round_id": 5, "battle_round": 4, "phase": "result"})
	_h.expect(main.get("_battle") == battle and int(battle.get("_replay_frame")) == 17 and main.prep_shown == 0,
		"live_resume_preserves_cursor", "live reconnect discarded the in-progress battle")
	NetworkService.team_active = true
	NetworkService.state = NetworkService.SessionState.READY
	NetworkService.latest_match_state = {}
	main.call("_on_resume_completed", {"round_id": 5, "phase": "result", "run_over": false})
	_h.expect(main.get("_battle") == battle and int(battle.get("_replay_frame")) == 17,
		"legacy_resume_wait_keeps_live_scene", "legacy room_state discarded playback before authoritative identity arrived")
	NetworkService.latest_match_state = state
	main.call("_on_network_match_state_received", state)
	await get_tree().create_timer(0.15).timeout
	_h.expect(main.get("_battle") == battle and int(battle.get("_replay_frame")) == 17
		and main.prep_shown == 0 and main.get("_resume_replay_pending").is_empty(),
		"legacy_resume_keeps_cursor", "legacy RESULT used the next prep round instead of completed_round")
	# Exercise production asynchronous cold recovery with result arriving first.
	NetworkService.team_active = true
	NetworkService.state = NetworkService.SessionState.READY
	NetworkService.latest_match_state = {}
	NetworkService.team_replay = _fixture_replay("old:3:6")
	NetworkService.set("team_replay_battle_id", "old:3:6")
	main.call("_begin_resume_replay", {"battle_id": "room:4:7", "round_id": 5, "battle_round": 4})
	NetworkService.latest_match_state = state
	main.call("_on_network_match_state_received", state)
	await get_tree().create_timer(0.15).timeout
	_h.expect(main.battle_shown == 0 and GameState.round_index == 4, "result_waits_for_replay", "early result skipped playback")
	NetworkService.team_replay = replay
	NetworkService.set("team_replay_battle_id", "room:4:7")
	await get_tree().create_timer(0.15).timeout
	_h.expect(main.battle_shown == 1 and not GameState.take_pending_battle_package().is_empty(),
		"cold_resume_starts_complete_replay", "complete matching replay failed to launch")
	# Cold legacy restore likewise obtains the completed round from match_state.
	NetworkService.latest_match_state = {}
	NetworkService.team_replay = {}
	main.call("_clear")
	GameState.round_index = 1
	main.call("_on_resume_completed", {"round_id": 5, "phase": "result", "run_over": false})
	NetworkService.latest_match_state = state
	main.call("_on_network_match_state_received", state)
	await get_tree().create_timer(0.15).timeout
	_h.expect(main.battle_shown == 1 and GameState.round_index == 4, "legacy_cold_waits_round_four",
		"cold legacy resume used next round or skipped before complete replay")
	NetworkService.team_replay = replay
	await get_tree().create_timer(0.15).timeout
	_h.expect(main.battle_shown == 2 and not GameState.take_pending_battle_package().is_empty(),
		"legacy_cold_starts_replay", "legacy cold recovery never launched its matching replay")
	NetworkService.current_battle_id = "room:4:7"
	NetworkService.team_replay = {}
	main.call("_begin_resume_replay", {"battle_id": "room:4:7", "battle_round": 4})
	main.call("_on_team_replay_failed", "old:3:6", "stale_failure")
	_h.expect(main.replay_failures.is_empty(), "stale_failure_ignored", "old transfer cancelled the current recovery")
	main.call("_on_team_replay_failed", "room:4:7", "replay_send_timeout")
	await get_tree().create_timer(0.15).timeout
	_h.expect(main.replay_failures == ["replay_send_timeout"] and main.battle_shown == 2 and main.prep_shown == 0,
		"failed_transfer_does_not_skip", "send failure must surface recovery failure, never settlement")
	main.call("_on_resume_completed", {"battle_id": "room:4:7", "battle_round": 4,
		"phase": "result", "replay_available": false, "replay_error": "replay_pack_failed"})
	_h.expect(main.replay_failures.size() == 2 and main.prep_shown == 0,
		"failed_resume_does_not_skip", "explicit replay error was treated as successful unavailable-cache fallback")
	NetworkService.team_active = false
	NetworkService.state = NetworkService.SessionState.OFFLINE
	main.queue_free()
	await get_tree().process_frame
