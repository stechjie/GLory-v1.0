extends Node
## 门禁：战斗排名奖励 + 钱袋（11-18，scripts/economy/BattleRankRewards.gd、scenes/battle/BattleRankHud.gd）。
##   1. 名次规则：PvP 按伤害、同伤害先到者在前、0 伤害不上榜；清路按帧号；第 21 回合不发。
##   2. 结算：排名奖励在利息之后加，不生利息。
##   3. 真模拟回放（打怪第 3 回合 / Boss 第 5 回合 / PvP 第 6 回合）：回放带上 lane_clear_ticks /
##      slot_kill_gold_events，击杀金事件的终值 = 结算用的 kill_gold_by_slot。
##   4. HUD：PvP 收起单人木牌换成伤害榜；钱袋最后 = 自己的击杀金 + 自己的排名奖励。
## 用法：Godot --headless --path . res://tools/battle_rank_rewards_check.tscn

const Harness := preload("res://tools/CheckHarness.gd")
const Rules := preload("res://scripts/economy/BattleRankRewards.gd")
const RankHud := preload("res://scenes/battle/BattleRankHud.gd")
const Feedback := preload("res://effects/runtime/presentation/BattleCombatFeedback.gd")

var _h: Harness


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = Harness.new("battle_rank_rewards")
	_check_rules()
	_check_settlement_order()
	var pve := _replays(3)
	_check_replay_fields(pve, "pve")
	var boss := _replays(5)
	_check_replay_fields(boss, "boss")
	var pvp := _replays(6)
	_check_replay_fields(pvp, "pvp")
	_check_final_round_guard(pvp)
	await _check_hud(pvp, "pvp")
	await _check_hud(pve, "pve")
	await _check_hud(boss, "boss")
	_h.finish(get_tree())


func _check_rules() -> void:
	# 2 号和 4 号同伤害：4 号第 1 帧就到了、2 号第 2 帧才到 → 4 号在前。1 号、5 号 0 伤害不上榜。
	var frames := [
		[0, 0, 100, 0, 300, 0],
		[50, 0, 300, 10, 300, 0],
		[900, 0, 300, 10, 300, 0],
	]
	var ranking := Rules.pvp_damage_ranking(frames)
	var slots: Array = ranking.map(func(r): return int(r.slot))
	_h.expect(slots == [0, 4, 2], "pvp_tiebreak", "PvP ranking must be damage desc, first-to-reach on ties: %s" % str(slots))
	var only_two := Rules.pvp_damage_ranking([[0, 5, 0, 0, 0, 7]])
	_h.expect(only_two.size() == 2, "pvp_zero_excluded", "seats without damage must not rank: %s" % str(only_two))
	var lane := Rules.lane_clear_ranking([40, -1, 12, 12, -1, 99])
	_h.expect(lane.map(func(r): return int(r.slot)) == [2, 3, 0], "lane_order", "lane ranking must be tick asc then slot: %s" % str(lane))
	_h.expect(Rules.lane_clear_ranking([40, -1, 12, 12, -1, 99], 20).size() == 2, "lane_live_cut",
		"live lane ranking must only include seats cleared by the current tick")
	var merged := Rules.merged_clear_ticks([{"lane_clear_ticks": [5, -1, 9, -1, -1, -1]}, {"lane_clear_ticks": [-1, -1, -1, 3, -1, 8]}])
	_h.expect(merged == [5, -1, 9, 3, -1, 8], "merge_ticks", "two team replays must merge into six seats: %s" % str(merged))
	var pvp_rewards := Rules.rewards_by_slot("pvp", [{"frame_slot_damage": frames}, {}])
	_h.expect(pvp_rewards == {0: 150, 4: 100, 2: 50}, "pvp_rewards", "PvP rewards 150/100/50: %s" % str(pvp_rewards))
	var lane_rewards := Rules.rewards_by_slot("boss", [{"lane_clear_ticks": [5, -1, 9, -1, -1, -1]}, {"lane_clear_ticks": [-1, -1, -1, 3, -1, -1]}])
	_h.expect(lane_rewards == {3: 50, 0: 30, 2: 10}, "lane_rewards", "lane rewards 50/30/10: %s" % str(lane_rewards))
	var single := Rules.rewards_by_slot("boss", [{"lane_clear_ticks": [-1, -1, 9, -1, -1, -1]}, {}])
	_h.expect(single == {2: 50}, "lane_single", "only one seat cleared → only first place is paid: %s" % str(single))
	_h.expect(Rules.rewards_by_slot("final", [{"frame_slot_damage": frames}]).is_empty(), "final_kind", "final round pays nothing")


func _check_settlement_order() -> void:
	var ctx := {"gold_before": 200, "kind": "pve", "player_wins": true, "round_index": 3, "kill_gold": 45,
		"treasures": [], "pet_id": "", "camp_income": 0}
	var base := EconomyService.settle_post_battle_breakdown(ctx.duplicate())
	var with_reward_ctx := ctx.duplicate()
	with_reward_ctx["rank_reward"] = 50
	var paid := EconomyService.settle_post_battle_breakdown(with_reward_ctx)
	_h.expect(int(paid.gold_after) == int(base.gold_after) + 50, "reward_added", "rank reward must be added on top: %s vs %s" % [paid.gold_after, base.gold_after])
	_h.expect(int(paid.income_by_reason.get("interest", -1)) == int(base.income_by_reason.get("interest", -2)),
		"no_interest_on_reward", "rank reward must come after interest")
	_h.expect(int(paid.income_by_reason.get("rank_reward", 0)) == 50 and not base.income_by_reason.has("rank_reward"),
		"reward_reason", "income_by_reason carries rank_reward only when paid")


## 打一场真的组队模拟：本地 0 号座位一块真棋盘，其余座位 AI。返回 [A 队回放, B 队回放]。
func _replays(round_index: int) -> Array:
	GameState.reset_run()
	DataRegistry.load_all()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for index in 8:
		var definition: Dictionary = (units[index % 4] as Dictionary).duplicate(true)
		GameState.board_slots[index] = {"id": definition.get("id", "unit"), "star": 2, "def": definition}
	GameState.team_mode = true
	GameState.round_index = round_index
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = 777000 + round_index
	NetworkService.team_slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	var snapshot: Dictionary = NetProtocol.team_board_submission(GameState.board_slots, GameState.mercenary_slots)
	snapshot["pet"] = ""
	NetworkService.team_boards = {0: snapshot}
	var replay_a: Dictionary = BattleSimulator.compute_team_replay(0, "rank-check:a:%d" % round_index)
	var replay_b: Dictionary = BattleSimulator.compute_team_replay(1, "rank-check:b:%d" % round_index)
	return [replay_a, replay_b]


func _check_replay_fields(replays: Array, kind: String) -> void:
	for t in 2:
		var replay: Dictionary = replays[t]
		_h.expect(str(replay.get("kind", "")) == kind, "%s_kind" % kind, "fixture round should be %s, got %s" % [kind, replay.get("kind", "")])
		var ticks: Variant = replay.get("lane_clear_ticks", null)
		_h.expect(ticks is Array and (ticks as Array).size() == 6, "%s_ticks_shape" % kind, "lane_clear_ticks must be six seats")
		var events: Array = replay.get("slot_kill_gold_events", [])
		var last := {}
		var last_tick := -1
		for e in events:
			_h.expect(int(e[0]) >= last_tick, "%s_events_ordered" % kind, "kill gold events must be in tick order")
			last_tick = int(e[0])
			last[int(e[1])] = int(e[2])
		var result: Dictionary = replay.get("result", {})
		for slot in 6:
			_h.expect(int(last.get(slot, 0)) == EconomyService.kill_gold_for_slot(result, slot), "%s_kill_gold_matches" % kind,
				"team %d slot %d: purse events end at %d but settlement pays %d" % [t, slot, int(last.get(slot, 0)), EconomyService.kill_gold_for_slot(result, slot)])
		if kind == "pvp":
			_h.expect((ticks as Array).all(func(v): return int(v) < 0), "pvp_no_ticks", "PvP must not record lane clears")
	var rewards := Rules.rewards_by_slot(kind, replays)
	_h.note("%s rewards=%s ticks_a=%s ticks_b=%s" % [kind, str(rewards), str(replays[0].get("lane_clear_ticks")), str(replays[1].get("lane_clear_ticks"))])
	if kind != "pvp":
		var a_ticks: Array = replays[0].get("lane_clear_ticks", [])
		_h.expect(a_ticks.slice(3).all(func(v): return int(v) < 0), "%s_team_a_own_slots" % kind, "team A replay may only fill slots 0-2")
		var won := bool((replays[0].get("result", {}) as Dictionary).get("player_wins", false))
		if won:
			_h.expect(int(a_ticks[0]) >= 0, "%s_winner_cleared" % kind, "team A won this fixture, slot 0's lane must have a clear tick")


func _check_final_round_guard(pvp: Array) -> void:
	GameState.round_index = GameState.FINAL_ROUND
	_h.expect(NetworkService.local_rank_rewards(pvp[0], pvp[1]).is_empty(), "final_round_guard",
		"round 21 must not pay rank rewards even though its replay kind is pvp")
	GameState.round_index = 6
	_h.expect(NetworkService.local_rank_rewards(pvp[0], pvp[1]) == Rules.rewards_by_slot("pvp", pvp), "local_matches_server",
		"local settlement must use the same ranking as the battle server")


func _check_hud(replays: Array, kind: String) -> void:
	var feedback: Control = Feedback.new()
	feedback.size = Vector2(1600, 720)
	add_child(feedback)
	await get_tree().process_frame
	var hud = RankHud.new()
	hud.setup(feedback, replays[0], replays[1], kind, 6 if kind == "pvp" else 3, 0, false)
	var frames: Array = replays[0].get("frames", [])
	for tick in range(0, frames.size(), 7):
		hud.refresh(tick, true, false)
	hud.finish(false)
	await get_tree().create_timer(1.6).timeout
	var purse: Control = feedback.get_node_or_null("BattlePurse")
	var kill := 0 if kind == "boss" else EconomyService.kill_gold_for_slot(replays[0].get("result", {}), 0)
	var reward := int(Rules.rewards_by_slot(kind, replays).get(0, 0))
	# 11.26：Boss 局钱袋结束时还要加上 Boss 奖励 / 补偿（和结算同一对函数），不能再停在 0。
	var boss_gold := 0
	if kind == "boss":
		var boss_result: Dictionary = replays[0].get("result", {})
		boss_gold = EconomyService.boss_win_reward(3) if bool(boss_result.get("player_wins", false)) \
			else EconomyService.boss_loss_reward(3, int(boss_result.get("enemy_hp_current", 0)), maxi(1, int(boss_result.get("enemy_hp_max", 1))))
		_h.expect(boss_gold > 0, "boss_purse_has_boss_gold", "this fixture must yield a boss reward so the purse case is not vacuous")
	_h.expect(purse != null and int(purse.call("total")) == kill + reward + boss_gold, "%s_purse_total" % kind,
		"purse must end at own kill gold %d + rank reward %d + boss gold %d, got %s" % [kill, reward, boss_gold, str(purse.call("total")) if purse != null else "none"])
	if kind == "pvp":
		_h.expect(feedback.get_node_or_null("DamageLeaderboard") != null and not bool(feedback.get("single_plate")),
			"pvp_board_replaces_plate", "PvP must show the damage board and hide the single plate")
	else:
		_h.expect(feedback.get_node_or_null("LaneClearBoard") != null and bool(feedback.get("single_plate")),
			"lane_board_present", "PvE/Boss must show the lane board and keep the single plate")
	hud.teardown()
	_h.expect(bool(feedback.get("single_plate")), "%s_teardown_restores" % kind, "teardown must restore the single plate")
	feedback.queue_free()
	await get_tree().process_frame
