extends Node

signal request_received(peer_id: int, sent_at: int)
signal reply_received(kind: String, elapsed_usec: int, sent_at: int)

@rpc("any_peer", "call_remote", "unreliable", 0)
func heartbeat(sent_at: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	request_received.emit(sender, sent_at)
	heartbeat_reply.rpc_id(sender, sent_at)

@rpc("authority", "call_remote", "unreliable", 0)
func heartbeat_reply(sent_at: int) -> void:
	reply_received.emit("heartbeat", Time.get_ticks_usec() - sent_at, sent_at)

@rpc("any_peer", "call_remote", "reliable", 1)
func control(sent_at: int) -> void:
	control_reply.rpc_id(multiplayer.get_remote_sender_id(), sent_at)

@rpc("authority", "call_remote", "reliable", 1)
func control_reply(sent_at: int) -> void:
	reply_received.emit("control", Time.get_ticks_usec() - sent_at, sent_at)
