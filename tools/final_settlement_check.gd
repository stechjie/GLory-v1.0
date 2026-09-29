extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Data := preload("res://scripts/multiplayer/FinalSettlementData.gd")
const Ledger := preload("res://scripts/multiplayer/EconomyLedger.gd")
const SettlementPanel :=  preload("res://scenes/menu/FinalSettlementPanel.gd")
var h := Harness.new("final_settlement")

# Exercise the real server state transitions with transport replaced by a sink.
class TestServer extends "res://scripts/autoload/NetworkService.gd":
	var live := {11: true, 12: true, 13: true, 14: true}
	func _ready() -> void:
		_reconnect_service.configure(_now, _net_log, {})
		_room_service.configure(_now, _wall_now, _net_log, func(): return 0, {}, _reconnect_service)
		_match_state.configure(_now)
	func _process(_delta: float) -> void:
		pass
	func _peer_connected(pid: int) -> bool:
		return live.has(pid)
	func _broadcast_room_lobby(room: Dictionary) -> void:
		_bump_room_seq(room)
	func _send_room_state(_room: Dictionary, _peer: int, _seq: int) -> void:
		pass
	func _room_sign_report(_room: Dictionary, _rounds: int, _outcome: int, _hp_a: int, _hp_b: int, _final_data: Dictionary) -> String:
		return ""
	func _voice_seat_released(_room: Dictionary, _slot: int, _identity: String) -> void:
		pass

# Keep the real lobby drawing/interaction, omit unrelated background asset preloads.
class TestLobby extends "res://scenes/menu/Team3v3Lobby.gd":
	func _setup_asset_loader() -> void:
		pass
	func _process(_delta: float) -> void:
		pass
	func _reload_online_friends() -> void:
		pass
	func _start_menu_music() -> void:
		pass

func _ready() -> void:
	call_deferred("_run")

func _expect(value: bool, description: String) -> void:
	h.expect(value, description, description)

func _run() -> void:
	if OS.get_cmdline_user_args().has("--compact"):
		get_window().content_scale_size = Vector2i(1280, 720)
	var server := TestServer.new()
	add_child(server)
	var old: Dictionary = server._new_room()
	old["state"] = "result"
	old["run_over"] = true
	old["peer_slot"] = {11: 0, 12: 1, 13: 3, 14: 4}
	old["slot_states"] = ["player", "player", "dummy", "player", "player", "empty"]
	old["initial_seats"] = old.slot_states.duplicate()
	old["initial_leader"] = 0
	old["seat_profiles"] = {0: {"player_name": "原房主", "friend_code": "HOST1234"}, 1: {"player_name": "队友", "friend_code": "ALLY1234"}}
	old["join_seq"] = {0: 0, 1: 1, 3: 2, 4: 3}
	for pid in old.peer_slot:
		server._peer_room[pid] = int(old.id)
	var target: Dictionary = server._return_to_settlement_room(12)
	_expect(not target.is_empty() and int(target.id) != int(old.id), "creates_new_room_id")
	_expect(int(target.leader_slot) == 0, "pending_original_host_keeps_leadership")
	_expect(target.slot_states == ["settling", "player", "dummy", "settling", "settling", "empty"], "seats_and_ai_preserved")
	_expect(server._peer_room[11] == int(old.id), "pending_viewer_stays_on_old_replay")
	_expect(not server._room_all_ready(target), "pending_seats_block_start")
	_expect(server._return_to_settlement_room(12).id == target.id and server._rooms.size() == 2, "repeated_return_idempotent")
	_expect(server._room_online_count(target) == 4, "pending_viewers_keep_room_alive")
	server._room_kick_slot(target, 3)
	_expect(target.slot_states[3] == "empty" and server._peer_room[13] == old.id, "kick_only_releases_reservation")
	_expect(server._return_to_settlement_room(13).is_empty(), "kicked_viewer_return_denied")
	server._apply_peer_leave(old, 11)
	_expect(target.slot_states[0] == "empty" and target.leader_slot == 1, "host_menu_leave_transfers_leadership")
	server.live.erase(14)
	server._room_reserve_peer(old, 14)
	_expect(target.slot_states[4] == "empty", "disconnected_pending_seat_released")
	_expect(target.seat_profiles.get(1, {}).get("player_name", "") == "队友", "return_keeps_identity")
	var live_room: Dictionary = server._new_room()
	live_room.peer_slot[90] = 0
	server._peer_room[90] = int(live_room.id)
	_expect(server._return_to_settlement_room(90).is_empty(), "unfinished_match_cannot_return")
	_expect(server._return_to_settlement_room(999).is_empty(), "foreign_peer_cannot_claim_seat")
	var matched: Dictionary = server._new_room()
	matched["run_over"] = true
	matched["mode"] = "ranked"
	matched.peer_slot[91] = 0
	server._peer_room[91] = int(matched.id)
	_expect(server._return_to_settlement_room(91).is_empty(), "ranked_return_not_supported")
	# Economy: rewards once; spend doesn't lower cumulative gross; failed actions don't count.
	var prep := Ledger.new_prep(100)
	var grant: Dictionary = Ledger.apply(prep, "altar_grant", {}, {"altar_gold": 100})
	if bool(grant.get("ok", false)):
		_expect(int(prep.get("prep_income_total", 0)) == maxi(0, int(grant.delta)), "ledger_tracks_positive_delta")
	var before := int(prep.get("prep_income_total", 0))
	Ledger.apply(prep, "unknown", {}, {})
	_expect(int(prep.get("prep_income_total", 0)) == before, "failed_action_no_income")
	var breakdown := EconomyService.settle_post_battle_breakdown({"gold_before": 100, "kind": "pve", "player_wins": true, "round_index": 1, "kill_gold": 10, "merchant_gold": 20, "camp_income": 10})
	var sum := 0
	for value in breakdown.income_by_reason.values():
		sum += int(value)
	_expect(int(breakdown.gold_after) == 100 + sum and int(breakdown.income_total) == sum, "reward_breakdown_balances")
	var stone_prep := Ledger.new_prep(100)
	stone_prep["carrots"] = 100
	stone_prep["merc_carrots_spent_total"] = 10000
	var stones := {"sky": 0, "land": 0, "ren": 0}
	var stone_receipt := Ledger.apply(stone_prep, "draw_upgrade_stone", {}, {"round_index": 1, "stone_roll": 0.1, "team_stones": stones})
	_expect(bool(stone_receipt.get("ok", false)), "stone_draw_success")
	var gained_before: Dictionary = stone_prep.get("stones_gained", {}).duplicate()
	Ledger.apply(stone_prep, "draw_upgrade_stone", {}, {"round_index": 1, "stone_roll": 0.1, "team_stones": stones})
	_expect(stone_prep.get("stones_gained", {}) == gained_before, "rejected_draw_does_not_count")
	var room := _data_fixture()
	var replay := {"result": {"unit_stats": {"a": {"id": "human_king", "name": "人王", "star": 4, "skill_stacks": 6, "slot": 0, "owner_slot": 0, "damage_dealt": 100, "damage_taken": 30, "healing_done": 4}, "b": {"owner_slot": 3, "name": "对手", "damage_dealt": 200}, "boss": {"owner_slot": -1, "group": "boss", "damage_dealt": 9999}}}, "roster": {}}
	var final_room: Dictionary = server._new_room()
	final_room["round_index"] = 21
	final_room["boards"] = room.boards.duplicate(true)
	final_room["slot_states"] = ["player", "empty", "empty", "player", "empty", "empty"]
	var final_a: Dictionary = replay.duplicate(true)
	final_a["kind"] = "final"
	final_a.result["player_wins"] = true
	var final_b: Dictionary = replay.duplicate(true)
	final_b["kind"] = "final"
	final_b.result["player_wins"] = false
	var official: Dictionary = server._room_build_match_states(final_room, final_a, final_b)
	_expect(official.size() == 6 and official[0].has("final_settlement"), "official_final_payload_contains_details")
	_expect(official[0].final_settlement == official[3].final_settlement, "both_sides_receive_same_final_details")
	_expect(final_room.prep[0].has("income_by_reason"), "server_records_actual_reward_breakdown")
	var model := Data.build(room, [replay, replay], 0, false)
	_expect(model.seats.size() == 6, "six_seats")
	_expect(model.seats[0].total_gold == 670, "gross_income_not_final_balance")
	_expect(model.stats.size() == 2 and model.stats[0].damage_dealt == 200, "stats_sorted_no_duplicate_or_boss")
	_expect(model.seats[0].stones.sky == 2, "gained_stones_independent_of_inventory")
	_expect(not str(model).contains("private-token"), "no_private_token_in_payload")
	_expect(Data.build(room, [replay, replay], 0, true).seats[0].total_gold == 680, "authoritative_ledger_selected")
	# Render the same public panel used by Main; a wide fixture stresses wrapping/scrolling.
	for i in 6:
		model.seats[i].board = []
		for j in 7:
			model.seats[i].board.append({"id": "human_king" if j % 2 == 0 else "god_angel", "star": 4, "slot": j})
		model.seats[i].mercenaries = [{"id": "merc_pisces_bubble"}]
		model.seats[i].treasures = ["ctrl_interrupt_chain", "ctrl_corrosive_needle"]
		model.seats[i].stones = {"sky": 2, "land": 1, "ren": 3}
		model.seats[i].name = "测试玩家%d#ABCDEFGH" % i
	model.allies = ["焰爪魔灵", "暗狱锁魂者"]
	for i in 24:
		model.stats.append({"name": "人王", "id": "human_king", "star": 4, "skill_stacks": 6, "owner_slot": i % 6, "damage_dealt": 100, "damage_taken": 30, "healing_done": 0})
	var panel := SettlementPanel.new()
	panel.data = model
	add_child(panel)
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(panel.size.x > 0, "panel_instantiates")
	_check_alignment(panel)
	_check_icon_bounds(panel)
	if OS.get_cmdline_user_args().has("--render"):
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://work/final_settlement_20260929/panel_top.png")
		var icons := panel.find_children("*", "TextureRect", true, false)
		var icon := icons[0] as Control
		var click := InputEventMouseButton.new()
		click.position = icon.get_global_rect().get_center()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		Input.parse_input_event(click)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		_expect(panel._bubble.visible, "icon_click_opens_overlay_bubble")
		get_viewport().get_texture().get_image().save_png("res://work/final_settlement_20260929/panel_bubble.png")
		var scroll := panel.get_child(1) as ScrollContainer
		scroll.scroll_vertical = 10000
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://work/final_settlement_20260929/panel_bottom.png")
	panel.queue_free()
	await get_tree().process_frame
	NetworkService.team_active = true
	NetworkService.is_host = false
	NetworkService.team_local_slot = 1
	NetworkService.team_leader_slot = 0
	NetworkService.team_room_id = 123456
	NetworkService.team_slot_states = ["settling", "player", "dummy", "settling", "empty", "empty"]
	NetworkService.team_ready = [false, false, true, false, false, false]
	NetworkService.team_seat_profiles = {0: {"player_name": "原房主", "friend_code": "HOST1234"}, 3: {"player_name": "结算玩家", "friend_code": "VIEW1234"}}
	var lobby := TestLobby.new()
	lobby.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(lobby)
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(lobby._slot_status_lbls[0].text == "结算中" and lobby._slot_avatars[0].modulate.a < 0.5, "pending_lobby_avatar_and_label")
	_expect(not lobby._start_block_reason(true).is_empty(), "lobby_explains_pending_start_block")
	if OS.get_cmdline_user_args().has("--render"):
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://work/final_settlement_20260929/lobby_pending.png")
	lobby.queue_free()
	await get_tree().process_frame
	var battle_path := "res://scenes/battle/BattleScreen.tscn"
	while ResourceLoader.load_threaded_get_status(battle_path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
	if ResourceLoader.load_threaded_get_status(battle_path) == ResourceLoader.THREAD_LOAD_LOADED:
		ResourceLoader.load_threaded_get(battle_path)
	h.finish(get_tree())

func _data_fixture() -> Dictionary:
	return {"boards": {0: {"gold": 3, "prep_income_total": 70, "board": [{"id": "human_king", "star": 4}, {"id": "god_angel", "star": 3}]}}, "prep": {0: {"battle_income_total": 500, "prep_income_total": 80, "stones_gained": {"sky": 2}}}, "seat_profiles": {}, "seat_tokens": {0: "private-token"}}

func _check_alignment(panel: Control) -> void:
	var labels := panel.find_children("*", "Label", true, false)
	for side in 2:
		var right := -1.0
		var aligned := true
		var count := 0
		for label in labels:
			if int(label.get_meta("settlement_column", -1)) != 5 or int(label.get_meta("settlement_team", -1)) != side:
				continue
			var edge: float = label.get_global_rect().end.x
			if right < 0:
				right = edge
			aligned = aligned and absf(edge - right) <= 1.0 and label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT
			count += 1
		_expect(aligned and count == 4, "gold_header_values_share_right_edge_team_%d" % side)
	for col in range(2, 5):
		var right := -1.0
		var aligned := true
		var count := 0
		for label in labels:
			if int(label.get_meta("stats_column", -1)) != col:
				continue
			var edge: float = label.get_global_rect().end.x
			if right < 0:
				right = edge
			aligned = aligned and absf(edge - right) <= 1.0 and label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT
			count += 1
		_expect(aligned and count > 1, "stats_header_values_share_right_edge_%d" % col)

func _check_icon_bounds(panel: Control) -> void:
	var okay := true
	var checked := 0
	for icon in panel.find_children("*", "TextureRect", true, false):
		var ancestor: Node = icon.get_parent()
		while ancestor != null and not ancestor is SettlementPanel.TableRow:
			ancestor = ancestor.get_parent()
		if ancestor != null:
			okay = okay and icon.get_global_rect().end.y <= ancestor.get_global_rect().end.y + 1
			checked += 1
	_expect(okay and checked > 0, "wrapped_icons_stay_inside_their_rows")
