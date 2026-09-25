extends RefCounted

# Cooperative server simulation. A slice never awaits: globals are borrowed only
# for its duration, then restored before networking or another room can run.
# Only the completed, privately owned replay data crosses into the packing worker.
const Sim := preload("res://scripts/battle/BattleSimulator.gd")
const Transfer := preload("res://scripts/multiplayer/ReplayTransferService.gd")
const Event := preload("res://scripts/battle/BattlePresentationEvent.gd")
const Bot := preload("res://scripts/economy/BotPlayer.gd")
const GAME_FIELDS := [
	"team_mode", "team_slot_states", "round_index", "pve_completed", "boss_completed",
	"final_round_played", "team_hp", "enemy_team_hp", "player_formation_hp",
	"enemy_formation_hp", "owned_treasures", "board_slots", "mercenary_slots",
]
const NET_FIELDS := ["team_active", "team_local_slot", "team_slot_states", "team_ready", "team_boards", "shared_seed"]
const ROOM_INPUT_FIELDS := ["id", "battle_id", "round_index", "slot_states", "ready", "boards", "shared_seed", "team_hp", "pve_completed", "boss_completed", "run_over"]

var room_id := 0
var battle_id := ""
var round_index := 0
var cancelled := false
var completed := false
var advances := 0
var prepare_usec := 0
var bot_warmup_usec := 0
var max_bot_warmup_usec := 0
var bot_warmup_calls := 0
var max_slice_usec := 0
var compute_usec := 0
var enqueued_at_usec := 0
var started_at_usec := 0
var packing_queued_at_usec := 0
var result: Dictionary = {}

var _game: Dictionary = {}
var _net: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _damage: Dictionary = {}
var _team := 0
var _prepared := false
var _steps := 0
var _state: Dictionary = {}
var _roster: Dictionary = {}
var _frames: Array = []
var _events: Array = []
var _replays: Array = []
var _shared_pvp := false
var _bot_slots: Array[int] = []
var _worker_task := -1
var _worker_result: Dictionary = {}


static func snapshot_room_inputs(room: Dictionary) -> Dictionary:
	var inputs := {}
	for field in ROOM_INPUT_FIELDS:
		if room.has(field):
			inputs[field] = room[field]
	return inputs.duplicate(true)


func _init(room: Dictionary, queued_at: int = 0) -> void:
	room_id = int(room.get("id", 0))
	battle_id = str(room.get("battle_id", ""))
	round_index = int(room.get("round_index", 1))
	enqueued_at_usec = queued_at if queued_at > 0 else Time.get_ticks_usec()
	# Copy only the locked inputs; do not keep a live room reference across frames.
	_game = _capture_fields(GameState, GAME_FIELDS).duplicate(true)
	_game.team_mode = true
	_game.team_slot_states = (room.get("slot_states", []) as Array).duplicate()
	_game.round_index = round_index
	_game.pve_completed = int(room.get("pve_completed", 0))
	_game.boss_completed = int(room.get("boss_completed", 0))
	_game.final_round_played = bool(room.get("run_over", false))
	var hp: Array = room.get("team_hp", [GameState.START_FORMATION_HP, GameState.START_FORMATION_HP])
	_game.team_hp = int(hp[0])
	_game.enemy_team_hp = int(hp[1])
	_net = {
		"team_active": true, "team_local_slot": 0,
		"team_slot_states": (room.get("slot_states", []) as Array).duplicate(),
		"team_ready": (room.get("ready", []) as Array).duplicate(),
		"team_boards": (room.get("boards", {}) as Dictionary).duplicate(true),
		"shared_seed": int(room.get("shared_seed", 0)),
	}
	# prepare_team_state reads owner context for BOTH sides in every round kind.
	# Only explicit dummy seats use BotPlayer; a missing human board stays empty.
	for slot in mini(6, _net.team_slot_states.size()):
		if str(_net.team_slot_states[slot]) == "dummy":
			_bot_slots.append(slot)
	_damage = {"state": {}, "source": "", "dot": false, "kind": "", "crit": false, "race": "", "skill": ""}


func advance(budget_usec: int) -> void:
	if completed or _worker_task >= 0:
		poll_worker()
		return
	if cancelled:
		_start_worker(false)
		return
	var started := Time.get_ticks_usec()
	if started_at_usec == 0:
		started_at_usec = started
	advances += 1
	var previous := enter_context()
	while Time.get_ticks_usec() - started < maxi(1, budget_usec):
		if not _prepared:
			if _warm_one_missing_bot():
				# One cold economy simulation is indivisible. Recheck the slice
				# deadline before another seat or the remaining roster preparation.
				continue
			var preparation_started := Time.get_ticks_usec()
			_state = Sim.prepare_team_state(_team)
			_state["_presentation_battle_id"] = Sim._presentation_battle_id(_state, _team, battle_id)
			Sim._replay_capture_roster(_state, _roster)
			_prepared = true
			prepare_usec = maxi(prepare_usec, Time.get_ticks_usec() - preparation_started)
			# Preparation is an indivisible bounded operation. Account for it before
			# beginning the first tick, instead of hiding it outside the slice budget.
			continue
		if bool(_state.get("finished", false)) or _steps >= 4000:
			_replays.append(Sim._team_replay_payload(_state, _roster, _frames, _events))
			_team += 1
			if _team == 1 and str(_state.get("kind", "")) == "pvp":
				# Both perspectives use the same A-vs-B layout and RNG seed. Keep
				# their settlement dictionaries independent; the worker rekeys only
				# B's presentation events. Frames and roster remain immutable/shared.
				var rival: Dictionary = _replays[0].duplicate(false)
				rival.result = (_replays[0].result as Dictionary).duplicate(true)
				_replays.append(rival)
				_shared_pvp = true
				_team = 2
			if _team >= 2:
				Sim.stamp_team_round_damages(_replays[0], _replays[1])
				break
			_state = {}
			_roster = {}
			_frames = []
			_events = []
			_steps = 0
			_prepared = false
			continue
		Sim.step_state(_state)
		_steps += 1
		Sim._replay_capture_roster(_state, _roster)
		Sim._replay_capture_frame(_state, _frames, _events)
	exit_context(previous)
	var elapsed := Time.get_ticks_usec() - started
	compute_usec += elapsed
	max_slice_usec = maxi(max_slice_usec, elapsed)
	if _team >= 2:
		_start_worker(true)


func _warm_one_missing_bot() -> bool:
	# The shared cache clears at 64 entries. Recheck every required key before
	# each prepare, since another room can evict a previous slice's warmup. With
	# all keys present, prepare runs synchronously without another job intervening.
	# Keep BotPlayer.state_for's cache policy, inputs and independent RNG intact.
	for slot in _bot_slots:
		var key := "%s/%d/%d" % [str(_net.shared_seed), slot, round_index]
		if Bot._cache.has(key):
			continue
		var started := Time.get_ticks_usec()
		Bot.state_for(_net.shared_seed, slot, round_index)
		var elapsed := Time.get_ticks_usec() - started
		bot_warmup_usec += elapsed
		max_bot_warmup_usec = maxi(max_bot_warmup_usec, elapsed)
		bot_warmup_calls += 1
		return true
	return false


func cancel() -> void:
	cancelled = true
	# Large replay containers are also released away from the network thread.
	if _worker_task < 0 and not completed:
		_start_worker(false)


func poll_worker() -> bool:
	if _worker_task < 0 or not WorkerThreadPool.is_task_completed(_worker_task):
		return completed
	# Joining an already completed task supplies the publication barrier and
	# releases its pool bookkeeping; never wait on a running task in _process.
	WorkerThreadPool.wait_for_task_completion(_worker_task)
	_worker_task = -1
	completed = true
	if not cancelled:
		result = _worker_result
	_worker_result = {}
	return true


func is_packing() -> bool:
	return _worker_task >= 0


func enter_context() -> Dictionary:
	var previous := {
		"game": _capture_fields(GameState, GAME_FIELDS),
		"net": _capture_fields(NetworkService, NET_FIELDS),
		"rng": RngService.rng, "damage": _capture_damage(),
	}
	_apply_fields(GameState, _game)
	_apply_fields(NetworkService, _net)
	RngService.rng = _rng
	_apply_damage(_damage)
	return previous


func exit_context(previous: Dictionary) -> void:
	_damage = _capture_damage()
	_apply_fields(GameState, previous.game)
	_apply_fields(NetworkService, previous.net)
	RngService.rng = previous.rng
	_apply_damage(previous.damage)


static func _capture_fields(object: Object, fields: Array) -> Dictionary:
	var out := {}
	for field in fields:
		out[field] = object.get(field)
	return out


static func _apply_fields(object: Object, values: Dictionary) -> void:
	for field in values:
		object.set(field, values[field])


static func _capture_damage() -> Dictionary:
	return {
		"state": DamageService._stat_state, "source": DamageService._stat_source_uid,
		"dot": DamageService._dot_damage_active, "kind": DamageService._hit_kind,
		"crit": DamageService._hit_is_crit, "race": DamageService._hit_source_race,
		"skill": DamageService._hit_skill_id,
	}


static func _apply_damage(context: Dictionary) -> void:
	DamageService._stat_state = context.state
	DamageService._stat_source_uid = context.source
	DamageService._dot_damage_active = context.dot
	DamageService._hit_kind = context.kind
	DamageService._hit_is_crit = context.crit
	DamageService._hit_source_race = context.race
	DamageService._hit_skill_id = context.skill


func _start_worker(pack: bool) -> void:
	packing_queued_at_usec = Time.get_ticks_usec()
	_worker_task = WorkerThreadPool.add_task(_pack_and_release.bind(pack), false, "battle replay serialization")


func _pack_and_release(pack: bool) -> void:
	# No SceneTree, autoload, Resource, room mutation or simulator call here.
	# The simulation has ended; only this worker touches its replay containers.
	if pack:
		var started := Time.get_ticks_usec()
		if _shared_pvp:
			var rival_events: Array = []
			var rival_id := "%s:team1" % battle_id
			for frame in _replays[0].frame_events:
				var events: Array = []
				for original in frame:
					if original is Dictionary:
						var event: Dictionary = original.duplicate(false)
						event.battle_id = rival_id
						event.event_key = "%s:%d:%d" % [rival_id, int(event.tick), int(event.ordinal)]
						event.presentation_seed = Event._presentation_seed(event.event_key)
						events.append(event)
					else:
						events.append(original)
				rival_events.append(events)
			_replays[1].frame_events = rival_events
		var packed: Array = []
		var raw_sizes: Array = []
		var serialize_usec := 0
		var errors: Array[String] = []
		var transfer := Transfer.new()
		for replay in _replays:
			var metrics: Dictionary = transfer.pack_with_metrics(replay, battle_id)
			serialize_usec += int(metrics.serialize_usec)
			packed.append(metrics.packed)
			raw_sizes.append(int(metrics.raw_bytes))
			if not str(metrics.error).is_empty():
				errors.append(str(metrics.error))
		_worker_result = {
			"a": {"kind": _replays[0].kind, "result": _replays[0].result},
			"b": {"kind": _replays[1].kind, "result": _replays[1].result},
			"packed_a": packed[0], "packed_b": packed[1], "raw_sizes": raw_sizes,
			"frames_a": (_replays[0].frames as Array).size(),
			"frames_b": (_replays[1].frames as Array).size(),
			"serialize_usec": serialize_usec, "pack_usec": Time.get_ticks_usec() - started,
			"pack_started_at_usec": started, "pack_finished_at_usec": Time.get_ticks_usec(),
			"error": ",".join(errors),
		}
	_replays.clear()
	_state = {}
	_roster = {}
	_frames = []
	_events = []
	_damage = {}
