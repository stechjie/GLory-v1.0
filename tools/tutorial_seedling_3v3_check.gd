extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Bot := preload("res://scripts/economy/BotPlayer.gd")
const QueuePanel := preload("res://scenes/menu/MatchQueuePanel.gd")
const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")

func _ready() -> void:
	var h := Harness.new("tutorial_seedling_3v3")
	DataRegistry.load_all()
	GameState.reset_run()
	var normal_treasures: Array[int] = []
	for round_index in range(1, 22):
		if RoundService.is_treasure_round(round_index):
			normal_treasures.append(round_index)
		h.expect(RoundService.treasure_pick_count(round_index) ==
			(1 if round_index in [4, 8, 12, 16, 20] else 0),
			"normal_picks_%d" % round_index, "21-round treasure count")
	h.expect(normal_treasures == [4, 8, 12, 16, 20], "normal_schedule", "21-round schedule")

	TutorialMode.start()
	h.expect(GameState.team_mode and not NetworkService.team_active,
		"local_team", "Tutorial uses local 3v3")
	h.expect(GameState.team_slot_states == ["player", "dummy", "dummy", "dummy", "dummy", "dummy"],
		"six_seats", "One player and five AI")
	var queue := QueuePanel.new()
	queue.configure_tutorial_ai()
	var seats: Array = queue._tutorial_ai_seats(false)
	h.expect(seats.size() == 6 and not bool(seats[0].accepted),
		"queue_six_seats", "Match confirmation shows six seats")
	h.expect(bool(seats[1].accepted) and bool(seats[5].accepted),
		"ai_confirmed", "AI teammates and opponents auto-confirm")
	queue.free()

	var expected: Array[String] = ["pve", "pve", "pve", "pve", "boss", "pvp",
		"pve", "pve", "pve", "boss", "pvp", "pve", "final"]
	var treasure_rounds: Array[int] = []
	for round_index in range(1, 14):
		GameState.round_index = round_index
		h.expect(TutorialMode.battle_kind() == expected[round_index - 1],
			"kind_%d" % round_index, "13-round battle kind")
		if RoundService.is_treasure_round(round_index):
			treasure_rounds.append(round_index)
		h.expect(RoundService.treasure_pick_count(round_index) ==
			(2 if round_index in [4, 8] else 1 if round_index == 12 else 0),
			"seedling_picks_%d" % round_index, "13-round treasure count")
	h.expect(treasure_rounds == [4, 8, 12], "seedling_schedule", "13-round schedule")

	GameState.round_index = 6
	var bot := Bot.state_for(NetworkService.shared_seed, 3, 6)
	var bot_board: Array = bot.get("board", [])
	var human_count := 0
	for cell in bot_board:
		if cell is Dictionary:
			h.expect(str(cell.get("def", {}).get("race", "")) == "human",
				"ai_human_%d" % human_count, "Tutorial AI only has human units")
			human_count += 1
	h.expect(human_count > 0, "ai_board_nonempty", "AI participates in round 6")
	var state := BattleSim.prepare_team_state(0)
	h.expect(str(state.get("kind", "")) == "pvp", "round6_pvp", "Round 6 is actual team PvP")
	h.expect(state.get("ally_slots", []) == [0, 1, 2] and
		state.get("rival_slots", []) == [3, 4, 5],
		"team_lanes", "Three allied lanes against three rival lanes")
	h.expect(not (state.get("player", []) as Array).is_empty() and
		not (state.get("enemy", []) as Array).is_empty(),
		"six_player_battle", "Both sides have fighters")
	TutorialMode.finish()
	h.expect(not GameState.team_mode and GameState.team_slot_states.is_empty(),
		"tutorial_cleanup", "Local team state clears after tutorial")
	h.finish(get_tree())
