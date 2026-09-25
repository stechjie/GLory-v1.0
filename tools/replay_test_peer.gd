extends "res://scripts/autoload/NetworkService.gd"

# Isolated test endpoint: uses production replay RPCs, codec, ACK/retry and queue.
# Only authentication/account startup and unrelated game timers are bypassed.
var suppress_acks := false
var ack_calls := 0
var received_count := 0
var failed_count := 0
var first_chunk_usec := 0
var completed_usec := 0
var pongs: Array[int] = []
var sent_chunks: Array[Dictionary] = []
var production_process := false
var legacy_receiver := false
var legacy_codec := preload("res://tools/fixtures/ReplayTransferProtocol32.gd").new()
var legacy_errors: Array[String] = []

func _ready() -> void:
	set_process(false)
	_rate_limiter.configure(_now, _net_log, _disconnect_peer)
	_replay_transfer.configure(_net_log)
	team_replay_received.connect(func():
		received_count += 1
		completed_usec = Time.get_ticks_usec())
	team_replay_failed.connect(func(_battle, _reason): failed_count += 1)

func _process(delta: float) -> void:
	if production_process:
		super._process(delta)

func _net_log(message: String) -> void:
	print("[replay-test] %s" % message)

func _ack_valid_replay_kind(battle_id: String, kind: String) -> void:
	ack_calls += 1
	if not suppress_acks:
		super._ack_valid_replay_kind(battle_id, kind)

func _send_queued_replay_chunk(item: Dictionary) -> bool:
	sent_chunks.append({"peer_id": item.peer_id, "battle_id": item.battle_id,
		"kind": item.kind, "bytes": (item.data as PackedByteArray).size(), "at_usec": Time.get_ticks_usec()})
	return super._send_queued_replay_chunk(item)

@rpc("authority", "call_remote", "reliable", NetworkConfig.CH_BULK)
func _rpc_team_replay_chunk(battle_id: String, kind: String, idx: int, total: int,
		kinds: int, data: PackedByteArray) -> void:
	if not legacy_receiver:
		super._rpc_team_replay_chunk(battle_id, kind, idx, total, kinds, data)
		return
	# Protocol 32 NetworkService receive body from a8dbefce, using the frozen
	# codec. This endpoint receives real production RPCs, not synthetic envelopes.
	if battle_id.length() > MAX_TREASURE_ID_LEN or kinds <= 0 or kinds > 2:
		return
	var out: Dictionary = legacy_codec.accept_chunk({
		"battle_id": battle_id, "kind": kind, "idx": idx, "total": total, "data": data})
	if not str(out.get("error", "")).is_empty():
		legacy_errors.append(str(out.error))
		return
	if not bool(out.get("complete", false)):
		return
	var slot_in: Dictionary = _replay_in.get(battle_id, {"kinds": kinds, "done": {}})
	(slot_in["done"] as Dictionary)[kind] = out.get("packed", PackedByteArray())
	slot_in["kinds"] = kinds
	_replay_in[battle_id] = slot_in
	_rpc_replay_ack.rpc_id(1, battle_id, kind, PackedInt32Array())
	if (slot_in["done"] as Dictionary).size() < kinds:
		return
	var done_map: Dictionary = slot_in["done"]
	team_replay = legacy_codec.unpack(done_map.get("own", PackedByteArray()))
	team_replay_rival = legacy_codec.unpack(done_map.get("rival", PackedByteArray()))
	_replay_in.erase(battle_id)
	team_replay_received.emit()

@rpc("any_peer", "call_remote", "unreliable", 0)
func test_ping(sent_usec: int) -> void:
	test_pong.rpc_id(multiplayer.get_remote_sender_id(), sent_usec)

@rpc("authority", "call_remote", "unreliable", 0)
func test_pong(sent_usec: int) -> void:
	pongs.append(Time.get_ticks_usec() - sent_usec)
