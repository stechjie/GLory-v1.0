extends RefCounted

# Credit controls the average rate independently of wire block size. Protocol
# 32 receivers reserve total * 48 KiB, even for smaller encrypted blocks: at
# most 85 blocks fit their 4 MiB limit. Keep small DTLS bursts where possible.
const PEER_BYTES_PER_FRAME := 16 * 1024
const MAX_CHUNK_BYTES := 48 * 1024
const LEGACY_MAX_CHUNKS := 85
const GLOBAL_BYTES_PER_FRAME := 64 * 1024
const CPU_BUDGET_USEC := 2000
const MAX_PEERS := 512
const MAX_CACHED_BYTES := 64 * 1024 * 1024
const MAX_PAYLOAD_BYTES := LEGACY_MAX_CHUNKS * MAX_CHUNK_BYTES
const PEER_INFLIGHT_BYTES := 32 * 1024
const GLOBAL_INFLIGHT_BYTES := 256 * 1024
const RECEIPT_STALL_USEC := 20000000

var _peers: Dictionary = {}
var _order: Array[int] = []
# Payload byte arrays are shared per room; charge each battle once, not once
# for every seat holding a reference to the same arrays.
var _battles: Dictionary = {}
var _cached_bytes := 0
var _frame := 0
var _inflight_bytes := 0


func clear() -> void:
	_peers.clear()
	_order.clear()
	_battles.clear()
	_cached_bytes = 0
	_frame = 0
	_inflight_bytes = 0


func begin(peer_id: int, battle_id: String, payloads: Dictionary, flow_control: bool = false) -> String:
	forget(peer_id)
	if peer_id <= 0 or battle_id.is_empty() or payloads.is_empty() or payloads.size() > 2:
		return "invalid_transfer"
	var bytes := 0
	for kind in payloads:
		var data: PackedByteArray = payloads[kind]
		if str(kind) not in ["own", "rival"] or data.is_empty():
			return "invalid_payload"
		if data.size() > MAX_PAYLOAD_BYTES:
			return "legacy_p32_packed_limit"
		bytes += data.size()
	if _peers.size() >= MAX_PEERS:
		return "peer_limit"
	if not _battles.has(battle_id) and _cached_bytes + bytes > MAX_CACHED_BYTES:
		return "cache_limit"
	var charge: Dictionary = _battles.get(battle_id, {"bytes": bytes, "refs": 0, "payloads": payloads})
	if _battles.has(battle_id):
		# Seats may swap own/rival, but a battle ID may never refer to new bytes.
		var existing: Array = (charge.payloads as Dictionary).values()
		if bytes != int(charge.bytes) or payloads.size() != existing.size():
			return "battle_payload_changed"
		for data in payloads.values():
			if data not in existing:
				return "battle_payload_changed"
	if not _battles.has(battle_id):
		_cached_bytes += bytes
	charge.refs = int(charge.refs) + 1
	_battles[battle_id] = charge
	var streams := {}
	for kind in payloads:
		var data: PackedByteArray = payloads[kind]
		var block_bytes := PEER_BYTES_PER_FRAME
		while not flow_control and int(ceil(float(data.size()) / block_bytes)) > LEGACY_MAX_CHUNKS:
			block_bytes += PEER_BYTES_PER_FRAME
		streams[kind] = {"data": data, "block_bytes": block_bytes, "pending": {}, "flight": {}, "done": false}
	_peers[peer_id] = {"battle_id": battle_id, "streams": streams,
		"kinds": payloads.size(), "kind_cursor": 0, "credit": 0, "credit_frame": _frame,
		"flow_control": flow_control, "flight_bytes": 0, "progress_usec": 0}
	_order.append(peer_id)
	return ""


func enqueue(peer_id: int, kind: String = "", missing: PackedInt32Array = PackedInt32Array()) -> void:
	var peer: Dictionary = _peers.get(peer_id, {})
	if peer.is_empty():
		return
	for name in (peer.streams as Dictionary):
		if not kind.is_empty() and str(name) != kind:
			continue
		var stream: Dictionary = peer.streams[name]
		if bool(stream.done):
			continue
		var data: PackedByteArray = stream.data
		var total := int(ceil(float(data.size()) / int(stream.block_bytes)))
		if missing.is_empty():
			for idx in total:
				if not stream.flight.has(idx):
					stream.pending[idx] = true
		else:
			for idx in missing:
				if idx >= 0 and idx < total and not stream.flight.has(idx):
					stream.pending[idx] = true


func complete_kind(peer_id: int, kind: String) -> void:
	var peer: Dictionary = _peers.get(peer_id, {})
	if peer.is_empty() or not (peer.streams as Dictionary).has(kind):
		return
	peer.streams[kind].done = true
	(peer.streams[kind].pending as Dictionary).clear()
	for bytes in (peer.streams[kind].flight as Dictionary).values():
		peer.flight_bytes -= int(bytes)
		_inflight_bytes -= int(bytes)
	(peer.streams[kind].flight as Dictionary).clear()


# Receipt credit is separate from the validated whole-replay ACK. A stale,
# duplicate or invented receipt cannot release another transfer's window.
func acknowledge_chunk(peer_id: int, battle_id: String, kind: String, idx: int) -> bool:
	var peer: Dictionary = _peers.get(peer_id, {})
	if peer.is_empty() or not bool(peer.flow_control) or str(peer.battle_id) != battle_id:
		return false
	var stream: Dictionary = (peer.streams as Dictionary).get(kind, {})
	if stream.is_empty() or not (stream.flight as Dictionary).has(idx):
		return false
	var bytes := int(stream.flight[idx])
	stream.flight.erase(idx)
	peer.flight_bytes -= bytes
	_inflight_bytes -= bytes
	peer.progress_usec = Time.get_ticks_usec()
	return true


# Heartbeats alone cannot reserve the shared bulk window forever. Expiring a
# stalled transfer releases other clients without disconnecting its player.
func stalled_peers(now_usec: int) -> Array[int]:
	var stale: Array[int] = []
	for peer_id in _peers:
		var peer: Dictionary = _peers[peer_id]
		if bool(peer.flow_control) and int(peer.flight_bytes) > 0 \
				and now_usec - int(peer.progress_usec) >= RECEIPT_STALL_USEC:
			stale.append(int(peer_id))
	return stale


func has_queued(peer_id: int) -> bool:
	var peer: Dictionary = _peers.get(peer_id, {})
	for stream in (peer.get("streams", {}) as Dictionary).values():
		if not (stream.pending as Dictionary).is_empty() or not (stream.flight as Dictionary).is_empty():
			return true
	return false


func pending_count(peer_id: int) -> int:
	var total := 0
	var peer: Dictionary = _peers.get(peer_id, {})
	for stream in (peer.get("streams", {}) as Dictionary).values():
		total += (stream.pending as Dictionary).size()
	return total


func forget(peer_id: int) -> void:
	var peer: Dictionary = _peers.get(peer_id, {})
	if peer.is_empty():
		return
	var battle_id := str(peer.battle_id)
	_inflight_bytes -= int(peer.flight_bytes)
	var charge: Dictionary = _battles[battle_id]
	charge.refs = int(charge.refs) - 1
	if int(charge.refs) == 0:
		_cached_bytes -= int(charge.bytes)
		_battles.erase(battle_id)
	_peers.erase(peer_id)
	_order.erase(peer_id)


# send_fn receives a bounded chunk and returns whether RPC accepted it.
# Lazy slicing avoids duplicating every full replay into thousands of queued
# blocks. Sets of indices make repeated NACK/retry requests idempotent.
func drain(send_fn: Callable, global_budget: int = GLOBAL_BYTES_PER_FRAME,
		cpu_budget_usec: int = CPU_BUDGET_USEC) -> Dictionary:
	var started := Time.get_ticks_usec()
	var result := {"bytes": 0, "chunks": 0, "peers": []}
	_frame += 1
	# A caller-supplied cap below one legacy block cannot service all streams.
	# Report that configuration error rather than silently starving large blocks.
	if global_budget < MAX_CHUNK_BYTES:
		result.error = "global_budget_below_max_chunk"
		return result
	var visits := _order.size()
	var visited := 0
	while visits > 0 and not _order.is_empty() and int(result.bytes) < global_budget:
		if visited > 0 and Time.get_ticks_usec() - started >= cpu_budget_usec:
			break
		visits -= 1
		visited += 1
		var peer_id: int = _order.pop_front()
		_order.append(peer_id)
		var peer: Dictionary = _peers.get(peer_id, {})
		if peer.is_empty():
			continue
		peer.credit = mini(MAX_CHUNK_BYTES, int(peer.credit) + (_frame - int(peer.credit_frame)) * PEER_BYTES_PER_FRAME)
		peer.credit_frame = _frame
		var names: Array = (peer.streams as Dictionary).keys()
		for offset in names.size():
			var k := (int(peer.kind_cursor) + offset) % names.size()
			var kind: String = names[k]
			var stream: Dictionary = peer.streams[kind]
			var pending: Dictionary = stream.pending
			if pending.is_empty() or bool(stream.done):
				continue
			var idx: int = pending.keys()[0]
			var packed: PackedByteArray = stream.data
			var block_bytes := int(stream.block_bytes)
			var begin_at := idx * block_bytes
			var byte_count := mini(block_bytes, packed.size() - begin_at)
			if bool(peer.flow_control) and (int(peer.flight_bytes) + byte_count > PEER_INFLIGHT_BYTES \
					or _inflight_bytes + byte_count > GLOBAL_INFLIGHT_BYTES):
				break
			if byte_count > int(peer.credit):
				break
			if int(result.bytes) + byte_count > global_budget:
				# Preserve the next ready peer when a partial global budget cannot
				# fit it. Rotating every skipped peer would restart at the same
				# early peers each frame and starve the tail with 48 KiB blocks.
				_order.erase(peer_id)
				_order.push_front(peer_id)
				visits = 0
				break
			var data := packed.slice(begin_at, begin_at + byte_count)
			var item := {"peer_id": peer_id, "battle_id": str(peer.battle_id),
				"kind": kind, "idx": idx, "total": int(ceil(float(packed.size()) / block_bytes)),
				"kinds": int(peer.kinds), "data": data}
			if bool(send_fn.call(item)):
				pending.erase(idx)
				if bool(peer.flow_control):
					if int(peer.flight_bytes) == 0:
						peer.progress_usec = Time.get_ticks_usec()
					stream.flight[idx] = data.size()
					peer.flight_bytes += data.size()
					_inflight_bytes += data.size()
				peer.credit = int(peer.credit) - data.size()
				peer.kind_cursor = (k + 1) % names.size()
				result.bytes = int(result.bytes) + data.size()
				result.chunks = int(result.chunks) + 1
				(result.peers as Array).append(peer_id)
			break # Never send a second chunk to this connection in the same poll.
	return result
