extends Node
const H := preload("res://tools/CheckHarness.gd")
const Handover := preload("res://scripts/economy/AiHandover.gd")
const Live := preload("res://scripts/economy/LiveBotEconomy.gd")
const Bot := preload("res://scripts/economy/BotPlayer.gd")
const Voice := preload("res://ui/components/VoiceControls.gd")
const Lobby := preload("res://scenes/menu/PartyLobby.gd")
const Choice := preload("res://scenes/menu/PartyChoiceDialog.gd")
const Deadline := preload("res://scripts/rounds/PrepDeadline.gd")
class BattleProbe extends "res://scenes/battle/BattleScreen.gd":
	func _ready() -> void: pass
class ServerProbe extends "res://scripts/autoload/NetworkService.gd":
	func _ready() -> void: pass
	func _peer_connected(_peer: int) -> bool: return false
	func _room_reconnecting_slots(room: Dictionary) -> Array[int]:
		var slots: Array[int] = []
		for slot in room.get("reserved", {}): slots.append(int(slot))
		return slots
var h: RefCounted
var definition: Dictionary
class DetailProbe extends RefCounted:
	func show_text(_text: String) -> void: pass
func _ready() -> void:
	NetworkService.set_process(false)
	h = H.new("regression_1030")
	definition = DataRegistry.canonical_unit_def("human_militia")
	if definition.is_empty(): definition = DataRegistry.get_table("race_units").units[0]
	_handover()
	_bot_economy()
	_entry_disconnect()
	await _ui()
	await _synergy_grid()
	h.finish(get_tree())
func _synergy_grid() -> void:
	var original: Array = GameState.board_slots
	GameState.board_slots = []; GameState.board_slots.resize(16); GameState.board_slots.fill(null)
	var races := []
	for unit in DataRegistry.get_table("race_units").get("units", []):
		if races.has(str(unit.race)): continue
		GameState.board_slots[races.size()] = {"def": unit, "id": unit.id, "star": 1}
		races.append(str(unit.race))
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		var panel = load("res://scenes/prep/panels/SynergyPanel.gd").new()
		panel.setup(DetailProbe.new())
		panel._left_panel = VBoxContainer.new(); panel._left_panel.size = Vector2(220,400)
		add_child(panel); panel.add_child(panel._left_panel)
		panel._add_synergy_widgets()
		await get_tree().process_frame
		await get_tree().process_frame
		var grid := panel._left_panel.get_node("SynergyGrid") as GridContainer
		h.expect(grid.columns == 2 and grid.get_child_count() == races.size(), "synergy_two_columns", "All races retained in two columns in " + locale)
		if grid.get_child_count() >= 3:
			var a := grid.get_child(0) as Control; var b := grid.get_child(1) as Control; var c := grid.get_child(2) as Control
			h.expect(is_equal_approx(a.position.y,b.position.y) and b.position.x > a.position.x and c.position.y > a.position.y, "synergy_row_order", "Left-to-right then top-to-bottom")
		panel.free()
	GameState.board_slots = original
func count(slots: Array) -> int:
	return slots.filter(func(x): return x != null).size()
func _handover() -> void:
	var roster := {}
	for i in 15:
		roster["u%02d" % i] = {"unit_id": definition.id, "star": 1, "slot": i if i < 7 else -1}
	var result := Handover.build_slots(roster)
	h.expect(count(result.board) == 7 and count(result.bench) == 8, "handover_cap", "15 owned units remain 7 deployed + 8 bench")
	for i in 7:
		h.expect(str(result.board[i].uid) == "u%02d" % i, "handover_positions", "Actual deployed positions survive")
	for cap in [7, 8, 9]:
		for entry in roster.values(): entry.erase("slot")
		result = Handover.build_slots(roster, cap)
		h.expect(count(result.board) == cap, "legacy_cap", "Legacy roster respects treasure deployment capacity")
	for i in 15: roster["u%02d" % i]["slot"] = i
	result = Handover.build_slots(roster)
	h.expect(count(result.board) == 7 and count(result.bench) == 8, "corrupt_overcap", "Even an invalid 15 deployed roster is clamped")
	h.expect(Handover.board_cap([]) == 7 and Handover.board_cap(["atk_fury_roster"]) == 8, "treasure_cap", "Legitimate deployment bonus is preserved")
	var saved := [GameState.board_slots, GameState.bench_slots, GameState.mercenary_slots, GameState.gold]
	h.expect(Handover.apply({"roster": {}, "gold": 0}), "empty_authority", "Empty authoritative roster clears stale local units")
	h.expect(count(GameState.board_slots) == 0 and GameState.gold == 0, "empty_no_free_units", "No old local army or starting gold is restored")
	GameState.board_slots = saved[0]; GameState.bench_slots = saved[1]; GameState.mercenary_slots = saved[2]; GameState.gold = saved[3]
func _bot_economy() -> void:
	var bot := Bot.new_state("1030", 0)
	bot.roster = [{"id": definition.id, "def": definition, "star": 1, "uid": "original", "cost_basis": 20}]
	Bot.prioritize_owned_races(bot)
	h.expect(bot.main_race == str(definition.race), "inherited_race", "Human's actual roster chooses AI's preferred race")
	var duplicate := definition.duplicate(true)
	var other := definition.duplicate(true); other.id = "other_fixture"; other.race = "different"
	bot.gold = EconomyLedger.unit_cost(duplicate, [])
	bot["shop"] = {"round": 1, "offers": [other, duplicate], "sold": [false, false], "refresh_uses": 8}
	var rng := RandomNumberGenerator.new(); rng.seed = 123
	Bot._prep_round(bot, 1, rng, [duplicate])
	h.expect(bot.roster.size() == 1 and int(bot.roster[0].star) == 2, "buy_existing_first", "With limited gold, duplicate upgrade precedes random new units")
	h.expect(int(bot.gold) == 0 and bool(bot.shop.sold[1]) and not bool(bot.shop.sold[0]), "exact_purchase", "Only the paid shop cell is consumed")
	var refresh := Bot.new_state("1030", 0)
	refresh.gold = 85
	refresh["shop"] = {"round": 1, "offers": [other], "sold": [true], "refresh_uses": 7}
	Bot._prep_round(refresh, 1, rng, [duplicate])
	h.expect(int(refresh.shop.refresh_uses) == 7 and int(refresh.gold) == 85, "refresh_no_reset", "Inherited refresh price is not reset to zero")
	var prep := EconomyLedger.new_prep(0)
	prep.last_harvest_round = 5
	prep["roster"] = {"original": {"unit_id": definition.id, "star": 1, "kind": "unit", "cost_basis": 20}}
	prep["shop"] = {"offers": [duplicate], "sold": [true], "refresh_uses": 8}
	var room := {"round_index": 5, "shared_seed": "1030", "slot_states": ["dummy"], "initial_seats": ["player"], "prep": {0: prep}, "slot_gold": [9999], "ruleset": "normal", "seat_races": {0: [str(definition.race)]}}
	Live.prepare(room)
	var inherited: Dictionary = room.bot_states[0]
	h.expect(int(inherited.gold) == 0 and int(inherited.carrots) == 0, "real_balance", "Stale slot cache cannot create money; this round is not harvested twice")
	var before := inherited.duplicate(true)
	Live.prepare(room)
	h.expect(before == room.bot_states[0], "idempotent_prepare", "Repeated prepare adds no money, harvest, draw or purchases")
	room.bot_states.clear()
	Live.prepare(room)
	h.expect(int(room.bot_states[0].gold) == 0 and int(room.bot_states[0].carrots) == 0, "repeat_takeover", "Repeated takeover preserves actual balances")
	var desired := ""
	for link in DataRegistry.get_table("treasures").get("linkages", []):
		var req: Array = link.get("requires", [])
		if req.size() >= 2:
			desired = str(req[1]); inherited.treasures = [str(req[0])]; break
	if not desired.is_empty():
		h.expect(Bot.preferred_treasure(inherited, [desired]) == desired, "treasure_link", "AI chooses from the actual server offer")
		rm_treasure(room, inherited, desired)
func rm_treasure(room: Dictionary, bot: Dictionary, desired: String) -> void:
	room.owned_treasures = {0: bot.treasures.duplicate()}
	room.treasure_offer = {0: {"round": 4, "candidates": [desired], "remaining": 1}}
	NetworkService._bot_choose_pending_treasures(room, 0, bot)
	h.expect(bot.treasures.has(desired) and not room.treasure_offer.has(0), "server_treasure_grant", "AI consumes the same validated human grant and candidate")
func _entry_disconnect() -> void:
	var server := ServerProbe.new(); add_child(server); server.set_process(false)
	for mode in ["casual", "ranked"]:
		var room: Dictionary = server._matched_room_for(("a" if mode == "casual" else "b").repeat(32), mode)
		room.slot_states = ["player", "player", "player", "player", "player", "player"]
		room.ready = [false, false, false, false, false, false]
		room.peer_slot = {100: 0}
		room.seat_pid = {0: "retained-human"}
		room.seat_tokens = {0: "retained-token"}
		server._token_seat["retained-token"] = {"room_id": int(room.id), "slot": 0}
		server._room_reserve_peer(room, 100)
		h.expect(str(room.slot_states[0]) == "dummy" and str(room.state) == "prep", "entry_disconnect_starts", "A disconnected entrant never blocks remaining players: " + mode)
		h.expect(server._token_seat.has("retained-token") and room.seat_tokens[0] == "retained-token", "entry_keeps_token", "AI takeover retains reconnect credentials")
		h.expect(room.initial_seats[0] == "player", "human_identity", "Disconnected entrant remains a human in settlement identity")
		server._rooms.erase(int(room.id))
	server.free()
func _ui() -> void:
	for locale in ["zh", "en"]:
		LocaleManager.set_locale(locale)
		var lobby := Lobby.new(); lobby.configure_preview("host"); add_child(lobby)
		await get_tree().process_frame
		for mic_host in lobby._seat_frames.values():
			var badge := mic_host.get_node("SpeakingMic") as Control
			h.expect(mic_host.size == Vector2(100, 100) and badge.size.is_equal_approx(Vector2(30,30)), "mic_same_size", "Microphone uses portrait disc, independent of frame art")
		for mode in ["casual", "casual_normal", "ranked"]:
			lobby._update_mode_display(mode)
			var expected := "13" if mode == "casual" else "21"
			h.expect(lobby._mode_hint.text.contains(expected) and not lobby._mode_hint.text.contains("Forest"), "mode_description", "Localized mode duration and requirements")
		await get_tree().process_frame
		await get_tree().process_frame
		lobby.free()
	var holder := Control.new(); holder.size = Vector2(150, 90); add_child(holder)
	var badge := Voice.attach_speaking_mic(holder, 0.3)
	h.expect(badge.size.is_equal_approx(Vector2(27,27)), "non_square_badge", "A non-square parent cannot stretch a speaking badge")
	holder.size = Vector2(200, 100)
	h.expect(badge.size.is_equal_approx(Vector2(30,30)), "badge_resize", "Resize keeps the badge round")
	holder.free()
	NetworkService.team_active = true
	NetworkService.spectating = false
	var battle := BattleProbe.new(); add_child(battle); battle._setup_voice_controls()
	h.expect(battle.get_node_or_null("SpeakingList") == null and battle._speaking_list == null, "battle_no_mic_indicator", "Battle hides the speaking list while retaining voice buttons")
	h.expect(battle._voice_controls.voice_button != null, "battle_voice_available", "Microphone and speaker controls still work")
	battle.free()
	for r in range(1, 22):
		h.expect(Deadline.duration(r, "normal", "ranked") == (60.0 if r in [6,12,18,21] else 45.0), "ranked_timing", "21-round ranked PVE/PVP timing")
	for r in range(1, 14):
		h.expect(Deadline.duration(r, "seedling", "casual") == 60.0, "seedling_timing", "All Seedling rounds last 60s")
