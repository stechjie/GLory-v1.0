extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Job := preload("res://scripts/multiplayer/BattleReplayJob.gd")
const Sim := preload("res://scripts/battle/BattleSimulator.gd")
const PerfFixture := preload("res://tools/battle_perf_check_node.gd")
const Bot := preload("res://scripts/economy/BotPlayer.gd")
var _h := Harness.new("server_battle_scheduler")
var _baseline_compute_usec: Dictionary = {}
# A bounded diagnostic wall-clock allowance, using the project's existing
# 180-second battle safety limit as the maximum. Simulated time is NOT CPU time:
# derive the requested allowance from this machine's measured synchronous work.
const SCHEDULER_WATCHDOG_MAX_SEC := Sim.HARD_TIMEOUT_SEC


func _ready() -> void:
	NetworkService.set_process(false)
	NetworkService.enter_test_server_mode()
	DataRegistry.load_all()
	Engine.max_fps = 60
	_check_watchdog_budget()
	var rooms: Array = [_fixture(700001, 5, true), _fixture(700002, 21, false)]
	var expected: Array = []
	for room in rooms:
		expected.append(_baseline(room))
	await _check_interleaved(rooms, expected)
	# PVP reuse must remain exact across different seeds, factions, summons,
	# resurrection synergies and the final round's formation allies.
	var varied: Array = []
	for index in 4:
		var room := _fixture(701001 + index, [6, 12, 18, 21][index], false)
		_varied_boards(room, index)
		varied.append(room)
	var varied_expected: Array = []
	for room in varied:
		varied_expected.append(_baseline(room))
	await _check_interleaved(varied, varied_expected)
	await _check_mixed_bots()
	await _check_scheduler(1, true)
	await _check_scheduler(4, true)
	await _check_scheduler(16, true)
	await _check_scheduler(1, false)
	await _check_scheduler(16, true, 8000, 30)
	await _check_cancelled()
	await _check_cancelled_packing()
	await _check_queued_inputs()
	await _check_reset_packing()
	_check_heartbeat_observation()
	_h.finish(get_tree())


func _fixture(id: int, round_index: int, two_vs_two: bool) -> Dictionary:
	var fixture := PerfFixture.new()
	fixture._build_worst_case(7, 8, round_index)
	fixture.free()
	var slots: Array = ["player", "player", "empty", "player", "player", "empty"] if two_vs_two else ["player", "player", "player", "player", "player", "player"]
	var boards: Dictionary = NetworkService.team_boards.duplicate(true)
	if two_vs_two:
		boards.erase(2)
		boards.erase(5)
	return {
		"id": id, "round_index": round_index, "state": NetworkService.ROOM_RESULT,
		"battle_id": "%d:%d:1" % [id, round_index], "slot_states": slots,
		"ready": [false, false, false, false, false, false], "boards": boards,
		"shared_seed": 987654321 + id, "team_hp": [50, 42], "pve_completed": 3,
		"boss_completed": 1, "run_over": false, "peer_slot": {},
	}


# Independent oracle: this is the original synchronous server setup and compute
# path, deliberately not expressed through Job.enter_context or Job.advance.
func _baseline(room: Dictionary) -> Array:
	GameState.team_mode = true
	GameState.team_slot_states = room.slot_states.duplicate()
	GameState.round_index = room.round_index
	GameState.pve_completed = room.pve_completed
	GameState.boss_completed = room.boss_completed
	GameState.final_round_played = room.run_over
	GameState.team_hp = room.team_hp[0]
	GameState.enemy_team_hp = room.team_hp[1]
	NetworkService.team_active = true
	NetworkService.team_slot_states = room.slot_states.duplicate()
	NetworkService.team_ready = room.ready.duplicate()
	NetworkService.team_boards = room.boards.duplicate(true)
	NetworkService.shared_seed = room.shared_seed
	var started := Time.get_ticks_usec()
	var a := Sim.compute_team_replay(0, room.battle_id)
	var b := Sim.compute_team_replay(1, room.battle_id)
	Sim.stamp_team_round_damages(a, b)
	var elapsed := Time.get_ticks_usec() - started
	_baseline_compute_usec[int(room.id)] = elapsed
	var hashes := [_hash(var_to_bytes(a)), _hash(var_to_bytes(b))]
	_h.note("baseline room=%d round=%d compute_usec=%d hashes=%s" % [room.id, room.round_index, elapsed, str(hashes)])
	_h.expect(_plain_data(a) and _plain_data(b), "worker_input_objects", "Replay contains Object/Resource references")
	return hashes


func _check_interleaved(rooms: Array, expected: Array, check_cold_bots: bool = false) -> void:
	var jobs: Array = []
	for room in rooms:
		jobs.append(Job.new(room))
	var sentinel_state := {"sentinel": true}
	var sentinel_rng := RandomNumberGenerator.new()
	sentinel_rng.seed = 773399
	RngService.rng = sentinel_rng
	var sentinel_rng_state := sentinel_rng.state
	GameState.round_index = 777
	NetworkService.shared_seed = 888
	DamageService._stat_state = sentinel_state
	DamageService._stat_source_uid = "sentinel-source"
	DamageService._dot_damage_active = true
	DamageService.set_hit_context("sentinel", true, "sentinel-race", "sentinel-skill")
	var context_ok := true
	var frame_work: Array = []
	var deadline := Time.get_ticks_msec() + 20000
	while not _all_jobs_completed(jobs) and Time.get_ticks_msec() < deadline:
		var frame_started := Time.get_ticks_usec()
		for job in jobs:
			job.advance(2000)
			context_ok = context_ok and GameState.round_index == 777 and NetworkService.shared_seed == 888 \
				and RngService.rng == sentinel_rng and sentinel_rng.state == sentinel_rng_state \
				and DamageService._stat_state == sentinel_state and DamageService._stat_source_uid == "sentinel-source" \
				and DamageService._dot_damage_active and DamageService._hit_kind == "sentinel" \
				and DamageService._hit_is_crit and DamageService._hit_source_race == "sentinel-race" \
				and DamageService._hit_skill_id == "sentinel-skill"
		frame_work.append(Time.get_ticks_usec() - frame_started)
		await get_tree().process_frame
	_h.expect(context_ok, "global_context_leak", "A job changed another room's global simulation context")
	for index in jobs.size():
		var job: RefCounted = jobs[index]
		if not _h.expect(job.completed, "job_timeout", "Interleaved job did not complete"):
			job.cancel()
			continue
		for team in 2:
			var packed: PackedByteArray = job.result.packed_a if team == 0 else job.result.packed_b
			var replay: Dictionary = NetworkService._unpack_replay(packed)
			replay.erase("battle_id") # Transport metadata is outside the simulator contract.
			_h.expect(_hash(var_to_bytes(replay)) == expected[index][team], "interleaved_result_changed", "room=%d team=%d differs from synchronous baseline" % [job.room_id, team])
			if check_cold_bots:
				var owners := {}
				for fighter in (replay.get("roster", {}) as Dictionary).values():
					owners[int(fighter.get("owner_slot", -1))] = true
				var bot_slots: Array = [1, 4] if str(replay.get("kind", "")) == "pvp" else [1 if team == 0 else 4]
				for slot in bot_slots:
					_h.expect(owners.has(slot), "dummy_not_simulated", "room=%d team=%d has no fighters from dummy slot=%d" % [job.room_id, team, slot])
				_h.expect(not owners.has(2) and not owners.has(5), "empty_slot_spawned", "Empty slots unexpectedly acquired a board")
		_h.expect(job.advances > 2, "no_yield", "Full battle executed in one slice")
		_h.note("interleaved room=%d advances=%d max_slice_usec=%d prepare_usec=%d compute_usec=%d worker_pack_usec=%d" % [job.room_id, job.advances, job.max_slice_usec, job.prepare_usec, job.compute_usec, int(job.result.pack_usec)])
		if check_cold_bots:
			_h.expect(job.max_slice_usec < 100000, "cold_bot_slice_blocked", "Cold AI preparation/tick kept one slice over 100 ms: room=%d prepare_usec=%d max_slice_usec=%d" % [job.room_id, job.prepare_usec, job.max_slice_usec])
	if check_cold_bots:
		# This loop deliberately advances both jobs to stress context isolation;
		# it has no global frame budget. Measure production frames separately via
		# NetworkService._drain_finalize_queue below, retaining the 100ms ceiling.
		_h.note("cold-bot direct interleave (no frame budget) combined_max_usec=%d cache_entries=%d" % [_percentile(frame_work, 1.0), Bot._cache.size()])
	DamageService.clear_stat_context()
	DamageService._dot_damage_active = false
	DamageService._stat_state = {}


func _check_mixed_bots() -> void:
	# A board missing from a real player's snapshot is deliberately empty; only
	# an explicit dummy seat invokes BotPlayer. Exercise its cold path in both
	# independent Boss perspectives and the shared final-PvP simulation.
	var rooms: Array = []
	for index in 2:
		var room := _fixture(702001 + index, 20 + index, true)
		room.slot_states = ["player", "dummy", "empty", "player", "dummy", "empty"]
		room.boards.erase(1)
		room.boards.erase(4)
		room.shared_seed = 20260925 # Same seed, distinct seats and rounds.
		rooms.append(room)
	var expected: Array = []
	for room in rooms:
		Bot.clear_cache()
		expected.append(_baseline(room))
	# Do not let the oracle prewarm the path under test. Bot cache hits can hide
	# the indivisible round-1-to-21 economy simulation inside prepare_team_state.
	Bot.clear_cache()
	_h.expect(Bot._cache.is_empty(), "bot_cache_not_cold", "Cold scheduler started with cached bot boards")
	await _check_interleaved(rooms, expected, true)
	var cached_hashes := {}
	for key in Bot._cache:
		cached_hashes[key] = _hash(var_to_bytes(Bot._cache[key]))
	Bot.clear_cache()
	for room in rooms:
		for slot in [1, 4]:
			var key := "%s/%d/%d" % [str(room.shared_seed), slot, room.round_index]
			var fresh := Bot.state_for(room.shared_seed, slot, room.round_index)
			_h.expect(cached_hashes.get(key, "") == _hash(var_to_bytes(fresh)), "bot_cached_state_mutated", "Battle simulation mutated a cached bot board, treasure or synergy: %s" % key)
	Bot.clear_cache()
	await _check_bot_cache_eviction(rooms[0])
	Bot.clear_cache()
	# Same independent cold oracles, now driven by the actual production budget.
	await _check_scheduler(rooms.size(), true, 12000, 60, rooms, expected)
	Bot.clear_cache()


func _check_bot_cache_eviction(room: Dictionary) -> void:
	var job := Job.new(room)
	# Validate one-slot work units without requiring a fast machine to take more
	# than 2ms per bot. The production scheduler below checks the wall-time budget.
	_h.expect(_warm_bot_for_test(job) and job.bot_warmup_calls == 1 and not job._prepared,
		"bot_warmup_not_sliced", "One warmup operation must generate only one cold dummy seat")
	_h.expect(job._bot_slots == [1, 4] and Bot._cache.size() == 1,
		"bot_warmup_wrong_seats", "Human/missing/empty boards must not create bot cache entries")
	# Exercise state_for's REAL full-cache clear between two slices; filler keys
	# are never consumed as bot data. The job must notice its earlier key vanished.
	while Bot._cache.size() < Bot.CACHE_LIMIT:
		Bot._cache["unused-fixture/%d" % Bot._cache.size()] = {}
	Bot.state_for(room.shared_seed, 0, 1)
	_h.expect(Bot._cache.size() == 1, "bot_cache_churn_fixture", "Bot state_for no longer cleared its full cache")
	_h.expect(_warm_bot_for_test(job) and job.bot_warmup_calls == 2 and not job._prepared,
		"bot_warmup_evicted_key", "An evicted earlier seat must be regenerated before preparing")
	_h.expect(_warm_bot_for_test(job) and job.bot_warmup_calls == 3 and not job._prepared,
		"bot_warmup_remaining_seat", "The second cold seat must get its own budget check")
	var warm_calls: int = job.bot_warmup_calls
	job.advance(2000)
	_h.expect(job._prepared and job.bot_warmup_calls == warm_calls,
		"bot_warmup_prepare_not_hot", "Preparation must begin only after all required seats are cached")
	_h.note("cold-bot eviction warmup_calls=%d bot_total_usec=%d bot_max_usec=%d hot_prepare_usec=%d" % [
		job.bot_warmup_calls, job.bot_warmup_usec, job.max_bot_warmup_usec, job.prepare_usec])
	job.cancel()
	var deadline := Time.get_ticks_msec() + 10000
	while not job.poll_worker() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_h.expect(job.completed and job.result.is_empty(), "bot_warmup_cancelled", "Cancelled warmup must be reaped without publication")


func _warm_bot_for_test(job: RefCounted) -> bool:
	var previous: Dictionary = job.enter_context()
	var warmed: bool = job._warm_one_missing_bot()
	job.exit_context(previous)
	return warmed


func _varied_boards(room: Dictionary, variant: int) -> void:
	var definitions: Array = DataRegistry.get_table("race_units").get("units", [])
	var undead: Array = []
	var other: Array = []
	for definition in definitions:
		if str(definition.id).begins_with("undead_"):
			undead.append(definition)
		else:
			other.append(definition)
	for slot in 6:
		var pool: Array = undead if slot < 3 else other
		var board: Array = []
		board.resize(GameConstants.CELL_COUNT)
		for cell in 7:
			var definition: Dictionary = pool[(cell + variant + slot) % pool.size()]
			board[cell] = {"id": definition.id, "star": 3 + (1 if cell == 0 else 0), "def": definition.duplicate(true)}
		room.boards[slot].board = board
		room.boards[slot].syn = NetProtocol.rebuild_syn_from_board(board)
		room.boards[slot].treasures = ["def_iron_wall", "def_life_monument", "def_soul_counter", "def_phantom_step", "elem_flame_shatter"]


func _all_jobs_completed(jobs: Array) -> bool:
	for job in jobs:
		if not job.completed:
			return false
	return true


static func _scheduler_watchdog_msec(measured_cpu_usec: int, budget_usec: int, fps: int) -> int:
	var nominal_cpu_share := clampf(float(maxi(1, budget_usec)) * maxi(1, fps) / 1000000.0, 0.001, 1.0)
	var expected_sec := float(measured_cpu_usec) / 1000000.0 / nominal_cpu_share
	# 2x covers cooperative bookkeeping, scheduling jitter and VM contention;
	# 10s covers final worker serialization/publication. Retain the original 60s
	# minimum and fail even a very slow machine after the fixed 180s upper bound.
	return ceili(clampf(expected_sec * 2.0 + 10.0, 60.0, SCHEDULER_WATCHDOG_MAX_SEC) * 1000.0)


func _check_watchdog_budget() -> void:
	_h.expect(_scheduler_watchdog_msec(1000000, 12000, 60) == 60000,
		"watchdog_fast_floor", "Normal local workloads retain the existing 60-second floor")
	var linux_measured := 16129803 # Original e2-standard-2 sixteen-room oracle log.
	var slow := _scheduler_watchdog_msec(linux_measured, 8000, 30)
	_h.expect(slow > 140000 and slow < 150000, "watchdog_weak_cpu",
		"16.13s measured CPU at 24% duty gets finite headroom beyond its 67.21s ideal duration")
	_h.expect(slow > _scheduler_watchdog_msec(linux_measured, 12000, 60),
		"watchdog_budget_scaling", "Lower configured throughput gets more diagnostic wall time")
	_h.expect(_scheduler_watchdog_msec(999999999, 1000, 30) == 180000,
		"watchdog_hard_ceiling", "No measured slowdown can raise the 180-second cap")


func _check_scheduler(count: int, two_vs_two: bool, budget: int = 12000, fps: int = 60, fixtures: Array = [], baselines: Array = []) -> void:
	Engine.max_fps = fps
	NetworkService._simulation_budget_usec = budget
	NetworkService._simulation_jobs.clear()
	NetworkService._finalize_queue.clear()
	NetworkService._rooms.clear()
	var ids: Array = []
	var expected := {}
	var scheduled_jobs := {}
	var measured_cpu_usec := 0
	for index in count:
		var room: Dictionary = _fixture(710000 + index, 21 if not two_vs_two else 5, two_vs_two) if fixtures.is_empty() else fixtures[index].duplicate(true)
		expected[room.id] = _baseline(room) if baselines.is_empty() else baselines[index]
		measured_cpu_usec += int(_baseline_compute_usec[room.id])
		NetworkService._rooms[room.id] = room
		ids.append(room.id)
	for id in ids:
		NetworkService._enqueue_finalize(NetworkService._rooms[id])
	var started := Time.get_ticks_usec()
	var watchdog_msec := _scheduler_watchdog_msec(measured_cpu_usec, budget, fps)
	var deadline := Time.get_ticks_msec() + watchdog_msec
	_h.note("scheduler watchdog rooms=%d fps=%d budget_usec=%d baseline_compute_ms=%.1f deadline_ms=%d" % [
		count, fps, budget, measured_cpu_usec / 1000.0, watchdog_msec])
	var frame_times: Array = []
	var frame_gaps: Array = []
	var ready_times: Array = []
	var ready := {}
	var seen_progress := {}
	var queue_times: Array = []
	var previous_frame := started
	while ready.size() < count and Time.get_ticks_msec() < deadline:
		var now := Time.get_ticks_usec()
		frame_gaps.append(now - previous_frame)
		previous_frame = now
		NetworkService._drain_finalize_queue()
		frame_times.append(NetworkService._simulation_last_frame_usec)
		for job in NetworkService._simulation_jobs:
			scheduled_jobs[job.room_id] = job
			if job.advances > 0 and not seen_progress.has(job.room_id):
				seen_progress[job.room_id] = true
				queue_times.append(job.started_at_usec - job.enqueued_at_usec)
		for id in ids:
			var room: Dictionary = NetworkService._rooms[id]
			if not ready.has(id) and not (room.get("last_match_state", {}) as Dictionary).is_empty():
				ready[id] = true
				ready_times.append(Time.get_ticks_usec() - started)
		await get_tree().process_frame
	_h.expect(ready.size() == count, "scheduler_incomplete", "%d of %d rooms completed" % [ready.size(), count])
	if ready.size() < count:
		var unfinished: Array = []
		for id in ids:
			if not ready.has(id):
				unfinished.append(id)
		_h.note("scheduler deadline reached incomplete_room_ids=%s active=%d queued=%d watchdog_ms=%d" % [
			str(unfinished), NetworkService._simulation_jobs.size(), NetworkService._finalize_queue.size(), watchdog_msec])
	_h.expect(seen_progress.size() == count, "starved_room", "A scheduled room never received a simulation slice")
	# A physical tick/initial roster setup is indivisible. This guards against
	# accidentally returning to hundreds of milliseconds per battle on the loop.
	_h.expect(_percentile(frame_times, 1.0) < 100000, "network_loop_blocked", "Simulation kept the main thread over 100 ms")
	_h.note("scheduler rooms=%d mode=%s fps=%d budget_usec=%d wall_ms=%.1f frame_p95_usec=%d frame_max_usec=%d gap_p95_usec=%d queue_p95_ms=%.1f ready_p95_ms=%.1f enqueue_max_usec=%d" % [
		count, ("2v2" if two_vs_two else "3v3-full") if fixtures.is_empty() else "mixed-cold-bot", Engine.max_fps, NetworkService._simulation_budget_usec,
		(Time.get_ticks_usec() - started) / 1000.0, _percentile(frame_times, 0.95), _percentile(frame_times, 1.0),
		_percentile(frame_gaps, 0.95), _percentile(queue_times, 0.95) / 1000.0, _percentile(ready_times, 0.95) / 1000.0, NetworkService._simulation_max_enqueue_usec])
	for id in ids:
		if not fixtures.is_empty() and scheduled_jobs.has(id):
			var job: RefCounted = scheduled_jobs[id]
			_h.expect(job.bot_warmup_calls >= 2, "scheduler_bot_cache_warm", "Production cold fixture did not generate both dummy seats")
			_h.note("cold-bot scheduled room=%d warmup_calls=%d bot_total_usec=%d bot_max_usec=%d hot_prepare_usec=%d max_slice_usec=%d" % [
				id, job.bot_warmup_calls, job.bot_warmup_usec, job.max_bot_warmup_usec, job.prepare_usec, job.max_slice_usec])
		# An unfinished room already fails scheduler_incomplete. Its absent output
		# is not a corrupt replay: keep exact identity/SHA checks for every result
		# that actually exists, without reporting four misleading hash failures.
		if not ready.has(id):
			continue
		var room: Dictionary = NetworkService._rooms[id]
		var packed: Dictionary = room.get("replay_packed", {})
		for team in 2:
			var replay: Dictionary = NetworkService._unpack_replay(packed.get("a" if team == 0 else "b", PackedByteArray()))
			_h.expect(str(replay.get("battle_id", "")) == str(room.battle_id), "missing_transport_identity", "Packed replay has the wrong battle identity")
			replay.erase("battle_id")
			_h.expect(_hash(var_to_bytes(replay)) == expected[id][team], "scheduled_result_changed", "Scheduled room=%d team=%d differs from synchronous baseline" % [id, team])
	if ready.size() < count:
		NetworkService._cancel_pending_simulations()
		var cleanup_deadline := Time.get_ticks_msec() + 10000
		while not NetworkService._retired_simulation_jobs.is_empty() and Time.get_ticks_msec() < cleanup_deadline:
			NetworkService._poll_retired_simulations()
			await get_tree().process_frame
		_h.expect(NetworkService._retired_simulation_jobs.is_empty(), "watchdog_cleanup_incomplete",
			"Timed-out workload failed to release its cancelled workers before the next fixture")
	NetworkService._rooms.clear()
	Engine.max_fps = 60
	NetworkService._simulation_budget_usec = NetworkService.SIMULATION_BUDGET_USEC


func _check_cancelled() -> void:
	var room := _fixture(720000, 21, false)
	NetworkService._rooms[room.id] = room
	NetworkService._enqueue_finalize(room)
	NetworkService._drain_finalize_queue()
	_h.expect((room.last_match_state as Dictionary).is_empty(), "settled_before_ready", "Result exists while simulation is still running")
	_h.expect(not NetworkService._room_result_acks_complete(room), "pending_result_acked", "Pending simulation allowed next round")
	room.battle_id = "720000:22:2"
	room.state = NetworkService.ROOM_PREP
	var deadline := Time.get_ticks_msec() + 10000
	while not NetworkService._simulation_jobs.is_empty() and Time.get_ticks_msec() < deadline:
		NetworkService._drain_finalize_queue()
		await get_tree().process_frame
	_h.expect(NetworkService._simulation_jobs.is_empty(), "cancel_worker_not_reaped", "Cancelled job kept a worker alive")
	_h.expect((room.last_match_state as Dictionary).is_empty() and room.round_index == 21, "stale_result_applied", "A cancelled job published into another battle")
	NetworkService._rooms.clear()


func _check_cancelled_packing() -> void:
	var job := Job.new(_fixture(720001, 21, false))
	var deadline := Time.get_ticks_msec() + 20000
	while not job.is_packing() and Time.get_ticks_msec() < deadline:
		job.advance(12000)
		await get_tree().process_frame
	_h.expect(job.is_packing(), "packing_not_started", "Packing cancellation did not reach the worker phase")
	var started := Time.get_ticks_usec()
	job.cancel()
	job.poll_worker()
	_h.expect(Time.get_ticks_usec() - started < 10000, "cancel_join_blocked", "Cancellation waited on an unfinished serialization worker")
	while not job.completed and Time.get_ticks_msec() < deadline:
		job.poll_worker()
		await get_tree().process_frame
	_h.expect(job.completed and job.result.is_empty(), "cancel_packing_published", "Cancelled packing published a result or leaked a worker")


func _check_queued_inputs() -> void:
	var room := _fixture(720002, 5, true)
	var expected := _baseline(room)
	NetworkService._rooms[room.id] = room
	NetworkService._enqueue_finalize(room)
	# A seat reconnect/expiry after boards lock must not change this battle.
	room.slot_states[0] = "dummy"
	room.slot_states[1] = "empty"
	room.shared_seed = 111
	var deadline := Time.get_ticks_msec() + 10000
	while (room.last_match_state as Dictionary).is_empty() and Time.get_ticks_msec() < deadline:
		NetworkService._drain_finalize_queue()
		await get_tree().process_frame
	_h.expect(not (room.last_match_state as Dictionary).is_empty(), "locked_input_timeout", "Frozen-input room did not complete")
	for team in 2:
		var replay: Dictionary = NetworkService._unpack_replay(room.replay_packed.get("a" if team == 0 else "b", PackedByteArray()))
		replay.erase("battle_id")
		_h.expect(_hash(var_to_bytes(replay)) == expected[team], "queued_inputs_changed", "A queued room used changed seat/seed data")
	_h.expect(NetworkService._simulation_max_enqueue_usec < 10000, "enqueue_blocked", "Copying locked room inputs blocked the network loop")
	NetworkService._rooms.clear()


func _check_reset_packing() -> void:
	var room := _fixture(720003, 21, false)
	NetworkService._rooms[room.id] = room
	NetworkService._enqueue_finalize(room)
	var deadline := Time.get_ticks_msec() + 20000
	var job: RefCounted
	while Time.get_ticks_msec() < deadline:
		NetworkService._drain_finalize_queue()
		if not NetworkService._simulation_jobs.is_empty():
			job = NetworkService._simulation_jobs[0]
			if job.is_packing():
				break
		await get_tree().process_frame
	if not _h.expect(job != null and job.is_packing(), "reset_worker_not_started", "Reset test did not reach running serialization"):
		return
	var started := Time.get_ticks_usec()
	NetworkService.reset()
	_h.expect(Time.get_ticks_usec() - started < 10000, "reset_worker_blocked", "Reset waited on a serialization worker")
	NetworkService._dedicated_server = false
	while not NetworkService._retired_simulation_jobs.is_empty() and Time.get_ticks_msec() < deadline:
		NetworkService._process(1.0 / 60.0)
		await get_tree().process_frame
	_h.expect(NetworkService._retired_simulation_jobs.is_empty() and job.completed, "reset_worker_not_reaped", "Client-mode processing failed to reap a cancelled server worker")
	_h.expect(job.cancelled and job.result.is_empty() and room.last_match_state.is_empty(), "reset_worker_published", "A reset battle published stale settlement")
	NetworkService._rooms.clear()
	NetworkService.enter_test_server_mode()


func _check_heartbeat_observation() -> void:
	# A ping at time=100 was still alive when transport last polled at 119.
	# Later work in that frame must not judge it using a later wall-clock sample.
	NetworkService._peer_last_ping[900123] = 100.0
	NetworkService._tick_heartbeat_timeouts(119.0)
	_h.expect(NetworkService._peer_last_ping.has(900123), "frame_work_caused_timeout", "Heartbeat timed out using time after local work")
	NetworkService._last_process_at = 100.0
	NetworkService._forgive_process_stall(125.0)
	_h.expect(float(NetworkService._peer_last_ping[900123]) == 125.0, "stall_grace", "Process stall was charged to a remote peer")
	NetworkService._peer_last_ping.erase(900123)


func _hash(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


func _plain_data(value: Variant) -> bool:
	if value is Object:
		return false
	if value is Dictionary:
		for key in value:
			if not _plain_data(key) or not _plain_data(value[key]):
				return false
	elif value is Array:
		for item in value:
			if not _plain_data(item):
				return false
	return true


func _percentile(values: Array, fraction: float) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return int(sorted[clampi(int(ceil(sorted.size() * fraction)) - 1, 0, sorted.size() - 1)])
