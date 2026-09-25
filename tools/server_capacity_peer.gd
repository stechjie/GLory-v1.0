extends "res://tools/replay_test_peer.gd"

# Test-only RPCs. This class never enters a production bundle's startup path.
var registrations: Dictionary = {}
var reports: Dictionary = {}
var phase_name := ""
var phase_started := 0

@rpc("any_peer", "call_remote", "reliable", 0)
func capacity_register(index: int) -> void:
	registrations[multiplayer.get_remote_sender_id()] = index

@rpc("authority", "call_remote", "reliable", 0)
func capacity_begin(label: String) -> void:
	phase_name = label
	phase_started = Time.get_ticks_usec()
	pongs.clear()
	received_count = 0
	failed_count = 0
	completed_usec = 0

@rpc("authority", "call_remote", "reliable", 0)
func capacity_collect(label: String) -> void:
	capacity_report.rpc_id(1, label, {"pongs": pongs.duplicate(), "received": received_count,
		"failed": failed_count, "delivery_ms": (completed_usec - phase_started) / 1000.0 if completed_usec > 0 else 0.0})

@rpc("any_peer", "call_remote", "reliable", 0)
func capacity_report(label: String, data: Dictionary) -> void:
	reports["%s/%d" % [label, multiplayer.get_remote_sender_id()]] = data

@rpc("authority", "call_remote", "reliable", 0)
func capacity_done() -> void:
	phase_name = "done"
