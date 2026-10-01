extends Node
const H = preload("res://tools/CheckHarness.gd")
const Peer = preload("res://tools/replay_test_peer.gd")
const Transfer = preload("res://scripts/multiplayer/ReplayTransferService.gd")
const Validation = preload("res://scripts/battle/BattleReplayUtil.gd")
const Sim = preload("res://scripts/battle/BattleSimulator.gd")

func _ready() -> void:
	var h = H.new("empty_team_replay")
	var state := {"kind": "pve", "finished": true, "player": [], "enemy": [], "elapsed": 0.0,
		"forced_result": {"reason": "no_player_units", "player_wins": false}}
	var generated := Sim._team_replay_payload(state, {}, [], [])
	h.expect(generated.frames == [[]] and generated.frame_events == [[]], "terminal_frame", "Immediate settlement has a presentation endpoint")
	h.expect(Validation.valid_team_replay(generated), "empty_roster", "Both empty boards remain a valid authoritative result")
	var transfer := Transfer.new()
	for chunked in [false, true]:
		var peer := Peer.new()
		add_child(peer)
		peer.suppress_acks = true
		peer.team_room_id = 977696
		peer.server_round_index = 2
		peer._set_current_replay_battle("977696:1:22")
		var legacy := generated.duplicate(true)
		legacy.frames = []
		legacy.frame_events = []
		var packed := transfer.pack(legacy, "977696:1:22")
		if chunked:
			peer._rpc_team_replay_chunk("977696:1:22", "own", 0, 1, 1, packed)
		else:
			peer._rpc_team_replay(packed)
		h.expect(peer.received_count == 1 and peer.failed_count == 0, "legacy_received", "Zero-frame stored replay completes without reconnecting")
		h.expect(peer.team_replay.frames == [[]] and peer.team_replay.result == generated.result, "result_preserved", "Presentation normalization never changes server settlement")
		peer._rpc_team_replay(packed)
		h.expect(peer.received_count == 1 and peer.failed_count == 0, "duplicate", "Resend does not settle or fail twice")
		peer.free()
	# Android's actual failure was the rival perspective; own playback was valid.
	for chunked in [false, true]:
		var peer := Peer.new()
		add_child(peer)
		peer.suppress_acks = true
		peer.team_room_id = 977696
		peer.server_round_index = 2
		peer._set_current_replay_battle("977696:1:22")
		var own := generated.duplicate(true)
		own.roster = {"unit": {}}
		own.result.reason = "wipeout"
		var rival := generated.duplicate(true)
		rival.frames = []
		rival.frame_events = []
		var own_packed := transfer.pack(own, "977696:1:22")
		var rival_packed := transfer.pack(rival, "977696:1:22")
		if chunked:
			peer._rpc_team_replay_chunk("977696:1:22", "own", 0, 1, 2, own_packed)
			peer._rpc_team_replay_chunk("977696:1:22", "rival", 0, 1, 2, rival_packed)
		else:
			peer._rpc_team_replay(own_packed, rival_packed)
		h.expect(peer.received_count == 1 and peer.failed_count == 0,
			"empty_rival_received", "An empty rival replay must not fail a valid own replay")
		h.expect(peer.team_replay_rival.frames == [[]] and peer.team_replay_rival.result == rival.result,
			"rival_result_preserved", "Both transport modes preserve rival settlement")
		peer.free()
	for mutation in [{"reason": "wipeout"}, {"player_wins": true}, {"player_alive": 1}, {"player_alive": "0"}]:
		var invalid := generated.duplicate(true)
		invalid.frames = []
		invalid.result.merge(mutation, true)
		Validation.normalize_terminal_replay(invalid)
		h.expect(not Validation.valid_team_replay(invalid), "malformed_rejected", "Only explicit consistent no-unit results qualify")
	var peer := Peer.new()
	add_child(peer)
	var room := {"slot_states": ["player", "empty", "empty", "player", "empty", "empty"],
		"ready": [true, false, false, false, false, false]}
	h.expect(not peer._room_all_ready(room), "unready_player", "Other player must explicitly ready before battle")
	room.ready[3] = true
	h.expect(peer._room_all_ready(room), "both_ready", "Ready players on both sides may start")
	peer.free()
	h.finish(get_tree())
