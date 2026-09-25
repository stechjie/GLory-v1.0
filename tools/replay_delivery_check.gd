extends Node
const H := preload("res://tools/CheckHarness.gd")
const Q := preload("res://scripts/multiplayer/ReplaySendQueue.gd")
const T := preload("res://scripts/multiplayer/ReplayTransferService.gd")
const OldT := preload("res://tools/fixtures/ReplayTransferProtocol32.gd")
const Peer := preload("res://tools/replay_test_peer.gd")
var h: RefCounted

func _ready() -> void:
	call_deferred("run")

func sample(battle: String) -> Dictionary:
	return {"battle_id": battle, "roster": {"u": {"id": "human_militia"}},
		"frames": [[["u", 1.0, 2.0, 100, true]]], "result": {"player_wins": true}}

func run() -> void:
	h = H.new("replay_delivery")
	check_queue()
	check_new_sender_old_receiver()
	check_codec()
	check_receive()
	check_legacy_protocol()
	check_ack_pacing()
	h.finish(get_tree())

func check_queue() -> void:
	var q := Q.new()
	var blob := PackedByteArray()
	blob.resize(64 * 1024)
	for peer in range(1, 21):
		h.expect(q.begin(peer, "room", {"own": blob, "rival": blob}) == "", "begin", "Peer accepted")
		q.enqueue(peer)
	var sent: Array[Dictionary] = []
	var fn := func(item: Dictionary) -> bool: sent.append(item); return true
	var first: Dictionary = q.drain(fn, Q.GLOBAL_BYTES_PER_FRAME, 1000000)
	h.expect(int(first.bytes) == 256 * 1024 and int(first.chunks) == 16, "global_budget", "Exactly 16 peers served under 256 KiB cap")
	var seen := {}
	for item in sent:
		seen[item.peer_id] = int(seen.get(item.peer_id, 0)) + item.data.size()
	h.expect(seen.size() == 16, "parallel_peers", "16 distinct connections progress in one frame")
	for bytes in seen.values():
		h.expect(bytes <= 16 * 1024, "peer_budget", "Each connection capped at 16 KiB")
	sent.clear()
	q.drain(fn, 64 * 1024, 1000000)
	h.expect(sent.size() == 4 and int(sent[0].peer_id) == 17, "rotation", "Next frame starts at next peer")
	q.enqueue(1, "own", PackedInt32Array([0, 0, 1, 1]))
	var count := q.pending_count(1)
	for i in 50:
		q.enqueue(1, "own", PackedInt32Array([0, 0, 1, 1]))
	h.expect(q.pending_count(1) == count, "nack_dedup", "Duplicate requests do not enlarge pending queue")
	q.complete_kind(1, "own")
	h.expect(q.pending_count(1) == 4, "ack_cancels_kind", "ACK removes every queued block of that kind")
	h.expect(q.begin(1, "replacement", {"own": blob}) == "", "replace", "New battle replaces previous peer transfer")
	q.enqueue(1)
	sent.clear()
	q.drain(fn, 1024 * 1024, 1000000)
	for item in sent:
		if item.peer_id == 1:
			h.expect(item.battle_id == "replacement", "stale_send", "Old battle never leaves queue after replacement")
	var changed := blob.duplicate()
	changed[0] = 1
	h.expect(q.begin(100, "room", {"own": changed, "rival": blob}) == "battle_payload_changed", "cache_identity", "Shared cache cannot hide unrelated payloads under same battle ID")
	q.clear()
	h.expect(q._cached_bytes == 0 and q._peers.is_empty(), "clear", "All payload references and charges cleared")

func check_codec() -> void:
	var t := T.new()
	t.set_transport_encrypted(true)
	for size in [2 * 1024 * 1024, T.MAX_TRANSFER_BYTES]:
		var blob := PackedByteArray()
		blob.resize(size)
		blob[size - 1] = 79
		var chunks: Array = t.split(blob, "boundary", "own")
		var out := {}
		for chunk in chunks:
			out = t.accept_chunk(chunk)
		h.expect(bool(out.get("complete", false)) and out.get("packed") == blob, "dtls_boundary", "Legal %d-byte / %d-chunk encrypted replay reassembles" % [size, chunks.size()])
	var metrics: Dictionary = t.pack_with_metrics(sample("x"), "identity")
	h.expect(metrics.error == "" and metrics.raw_bytes > 0 and t.unpack(metrics.packed).battle_id == "identity", "pack_identity", "Worker pack stamps identity and returns metrics")
	var big := PackedByteArray()
	big.resize(T.MAX_UNCOMPRESSED_BYTES)
	metrics = t.pack_with_metrics({"big": big})
	h.expect(metrics.error == "raw_limit" and metrics.packed.is_empty(), "raw_limit_visible", "Oversize raw replay returns explicit error rather than unsendable bytes")
	var rng := RandomNumberGenerator.new()
	rng.seed = 932
	big.resize(T.MAX_TRANSFER_BYTES + 4096)
	for i in range(0, big.size(), 4):
		big.encode_u32(i, rng.randi())
	metrics = t.pack_with_metrics({"big": big})
	h.expect(metrics.error == "packed_limit" and metrics.packed.is_empty(), "packed_limit_visible", "Incompressible oversized replay returns explicit error")

func check_new_sender_old_receiver() -> void:
	# Run the actual frozen old implementation, including its incorrect declared
	# size guard. Merely feeding old envelopes into the new decoder misses this.
	for size in [128, 85 * 16384, 85 * 16384 + 1, 2 * 1024 * 1024, 85 * 32768, 85 * 32768 + 1, Q.MAX_PAYLOAD_BYTES]:
		var q := Q.new()
		var receiver := OldT.new()
		var blob := PackedByteArray()
		blob.resize(size)
		blob[size - 1] = 87
		h.expect(q.begin(7, "legacy", {"own": blob}) == "", "old_receive_begin", "Legacy-compatible size accepted")
		q.enqueue(7)
		var received := {}
		var stats := {"bytes": 0, "max_chunk": 0, "errors": 0}
		var send := func(item: Dictionary) -> bool:
			received.merge(receiver.accept_chunk(item), true)
			stats.bytes += item.data.size()
			stats.max_chunk = maxi(stats.max_chunk, item.data.size())
			stats.errors += int(not str(received.get("error", "")).is_empty())
			return true
		var frames := 0
		var rate_ok := true
		while q.has_queued(7) and frames < 300:
			frames += 1
			var progress: Dictionary = q.drain(send, Q.GLOBAL_BYTES_PER_FRAME, 1000000)
			rate_ok = rate_ok and int(stats.bytes) <= frames * Q.PEER_BYTES_PER_FRAME \
				and int(progress.bytes) <= Q.GLOBAL_BYTES_PER_FRAME
		h.expect(bool(received.get("complete", false)) and received.get("packed") == blob and stats.errors == 0,
			"new_to_old_bytes", "%d-byte new transfer is byte-exact through frozen old receiver" % size)
		h.expect(rate_ok and stats.max_chunk <= Q.MAX_CHUNK_BYTES and frames < 300,
			"legacy_credit", "Large chunks progress without exceeding average peer/global budget")
	var rejected := PackedByteArray()
	rejected.resize(Q.MAX_PAYLOAD_BYTES + 1)
	var q := Q.new()
	h.expect(q.begin(1, "too_big", {"own": rejected}) == "legacy_p32_packed_limit" and q._peers.is_empty(),
		"legacy_limit", "Unreceivable 86th legacy block fails explicitly before queueing")
	# Fairness when all peers need credit and the global budget fits only one block.
	var big := PackedByteArray()
	big.resize(85 * 32768 + 1)
	for peer in range(1, 5):
		q.begin(peer, "fair", {"own": big})
		q.enqueue(peer)
	var seen := {}
	var totals := {}
	for frame in 20:
		var progress: Dictionary = q.drain(func(item):
			seen[item.peer_id] = true
			totals[item.peer_id] = int(totals.get(item.peer_id, 0)) + item.data.size()
			return true, Q.MAX_CHUNK_BYTES, 1000000)
		h.expect(int(progress.bytes) <= Q.MAX_CHUNK_BYTES, "legacy_global_cap", "Strict per-call global cap includes large block")
	h.expect(seen.size() == 4, "legacy_fairness", "All credited peers advance even with one-block global cap")
	var amounts: Array = totals.values()
	amounts.sort()
	h.expect(int(amounts.back()) - int(amounts.front()) <= Q.MAX_CHUNK_BYTES, "legacy_fair_share", "Round robin never starves another large stream")
	h.expect(q.drain(func(_item): return true, 16384).get("error") == "global_budget_below_max_chunk",
		"invalid_global_cap", "Impossible caller budget is explicit rather than indefinite starvation")
	q.clear()
	totals.clear()
	for peer in range(1, 21):
		q.begin(peer, "remainder", {"own": big})
		q.enqueue(peer)
	for frame in 23:
		q.drain(func(item):
			totals[item.peer_id] = int(totals.get(item.peer_id, 0)) + item.data.size()
			return true, Q.GLOBAL_BYTES_PER_FRAME, 1000000)
	amounts = totals.values()
	amounts.sort()
	h.expect(totals.size() == 20 and int(amounts.back()) - int(amounts.front()) <= Q.MAX_CHUNK_BYTES,
		"partial_budget_fairness", "A 16 KiB remainder never restarts at early peers and starves the tail")

func check_receive() -> void:
	var p := Peer.new()
	add_child(p)
	p.suppress_acks = true
	p.team_room_id = 100001
	p.server_round_index = 1
	p._set_current_replay_battle("100001:1:10")
	var t := T.new()
	p._rpc_team_replay(t.pack({"battle_id": "100001:1:10", "frames": []}))
	h.expect(p.received_count == 0 and p.failed_count == 1, "invalid_single", "Empty malformed replay never emits success")
	var valid := t.pack(sample("100001:1:10"))
	p._rpc_team_replay_chunk("100001:1:10", "own", 0, 1, 1, t.pack({"battle_id": "100001:1:10"}))
	h.expect(p.ack_calls == 0 and p.received_count == 0, "invalid_chunk_no_ack", "Decode/schema failure never ACKs")
	p._rpc_team_replay_chunk("100001:1:10", "own", 0, 1, 1, valid)
	p._rpc_team_replay_chunk("100001:1:10", "own", 0, 1, 1, valid)
	p._rpc_team_replay(valid)
	h.expect(p.received_count == 1 and p.ack_calls == 2 and p._replay_in.is_empty(), "complete_once", "Lost ACK causes only ACK repeat, no duplicate decode/apply or retained copy")
	var future := t.pack(sample("100001:2:20"))
	p._rpc_team_replay(future)
	h.expect(p.received_count == 1 and p._replay_in.has("100001:2:20"), "bulk_before_control", "Plausible next-round bulk waits for control")
	p._set_current_replay_battle("100001:2:20")
	h.expect(p.received_count == 2 and p.team_replay_battle_id == "100001:2:20", "control_applies", "Authoritative current identity applies waiting valid replay")
	p._rpc_team_replay(valid)
	p._rpc_team_replay_chunk("100001:1:10", "own", 0, 1, 1, valid)
	h.expect(p.received_count == 2 and p.team_replay_battle_id == "100001:2:20", "old_battle_ignored", "Late old battle cannot pollute current replay")
	# RESULT room_state advertises next PREP round; settlement belongs to the battle just completed.
	p.server_round_index = 3
	p._rpc_receive_match_state({"completed_round": 2, "battle_id": "100001:2:20"})
	h.expect(int(p.latest_match_state.get("completed_round", 0)) == 2, "result_next_prep", "Valid settlement is accepted when room round already advanced")
	p._replay_out[7] = {"battle_id": "x", "kinds": 2, "payloads": {"own": valid, "rival": valid}, "done": {}, "deadline": 0.0, "tries": 0}
	p._replay_send_queue.begin(7, "x", {"own": valid, "rival": valid})
	p._replay_send_queue.enqueue(7)
	p._tick_replay_retry(100.0)
	h.expect(p._replay_out[7].tries == 0 and p._replay_out[7].deadline == 0.0, "queued_no_retry", "ACK timer remains stopped while queued")
	p._replay_send_queue.drain(func(_item): return true, Q.MAX_CHUNK_BYTES, 1000000)
	p._replay_send_queue.drain(func(_item): return true, Q.MAX_CHUNK_BYTES, 1000000)
	p._replay_mark_queue_drained(7)
	h.expect(p._replay_out[7].deadline > p._now(), "drained_timer", "ACK timeout starts only after final queued block")
	p._handle_replay_ack(7, "old", "own", PackedInt32Array())
	h.expect(p._replay_out[7].done.is_empty(), "old_ack", "Old battle ACK cannot complete a new transfer")
	p.free()


func check_legacy_protocol() -> void:
	var t := T.new()
	for chunked in [false, true]:
		for order in [["bulk", "match", "room"], ["match", "bulk", "room"], ["room", "bulk", "match"], ["room", "match", "bulk"], ["bulk", "room", "match"], ["match", "room", "bulk"]]:
			var p := Peer.new()
			add_child(p)
			p.suppress_acks = true
			p.team_active = true
			p.team_room_id = 100001
			p.server_round_index = 1
			var legacy := sample("100001:1:10")
			legacy.erase("battle_id")
			legacy.frame_events = [[{"battle_id": "100001:1:10:team0"}], [{"battle_id": "100001:1:10:team0"}]]
			var packed: PackedByteArray = t.pack(legacy)
			var deliver := func():
				if chunked:
					p._rpc_team_replay_chunk("100001:1:10", "own", 0, 1, 1, packed)
				else:
					p._rpc_team_replay(packed)
			var result := {"completed_round": 1, "battle_id": "100001:1:10"}
			for action in order:
				if action == "bulk":
					deliver.call()
				elif action == "match":
					p._rpc_receive_match_state(result)
				else:
					p._rpc_room_state({"server_epoch": 1, "state_seq": 1, "room_id": 100001,
						"payload": {"phase": "result", "round_id": 2, "my_slot": 0, "run_over": true}})
			h.expect(p.received_count == 1 and p.team_replay_battle_id == "100001:1:10" and p.current_battle_id == "100001:1:10", "legacy_round_trip", "Protocol 32 legacy identity survives later room snapshot without battle_id")
			p.free()
	var host := Peer.new()
	add_child(host)
	host.suppress_acks = true
	host.team_active = true
	host.team_room_id = 0
	var host_id := "host:%d" % GameState.round_index
	host._rpc_team_replay(t.pack(sample(host_id)))
	h.expect(host.received_count == 1 and host.team_replay_battle_id == host_id, "host_replay", "Local host round identity accepted without dedicated-room envelope")
	host._set_current_replay_battle("")
	var legacy_host := sample(host_id)
	legacy_host.erase("battle_id")
	legacy_host.frame_events = [[{"battle_id": "local:%d:%d:pve:team0" % [host.shared_seed, GameState.round_index]}]]
	host._rpc_team_replay(t.pack(legacy_host))
	h.expect(host.received_count == 2 and host.team_replay_battle_id == host_id, "legacy_host_replay", "Legacy local-host event binds to the same shared seed and round")
	host.free()


func check_ack_pacing() -> void:
	var branch := Node.new()
	add_child(branch)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, branch.get_path())
	api.multiplayer_peer = null
	var p := Peer.new()
	branch.add_child(p)
	p._ack_valid_replay_kind("battle", "own")
	var first: float = p._replay_ack_times.get("battle|own", -1.0)
	for i in 30:
		p._ack_valid_replay_kind("battle", "own")
	h.expect(first >= 0 and p._replay_ack_times["battle|own"] == first, "duplicate_ack_throttle", "A burst of repeated blocks emits at most one ACK per kind")
	p._replay_ack_times["battle|own"] = first - 1.3
	p._ack_valid_replay_kind("battle", "own")
	h.expect(p._replay_ack_times["battle|own"] >= first, "ack_retry_available", "Valid repeated block can re-ACK after throttle window")
	get_tree().set_multiplayer(null, branch.get_path())
	branch.free()
