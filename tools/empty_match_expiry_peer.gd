extends "res://tools/mobile_reconnect_peer.gd"

var test_time := 1000.0

func _now() -> float:
	return test_time

# This check exercises room lifetime and real RPC transport, not simulation.
func _room_try_finalize_boards(_room: Dictionary) -> void:
	pass
