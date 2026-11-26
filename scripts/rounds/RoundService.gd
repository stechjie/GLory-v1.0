class_name RoundService
extends RefCounted

static func schedule_kind_for_round(round_index: int) -> String:
	if _is_final_round(round_index):
		return "final"
	var schedule := active_schedule()
	if _array_has_round(schedule.get("boss_rounds", []), round_index):
		return "boss"
	if _array_has_round(schedule.get("pvp_rounds", []), round_index):
		return "pvp"
	return "pve"

static func _is_final_round(round_index: int) -> bool:
	# 血量归零的话对局早在到达 FINAL_ROUND 前就结束了，走不到这里，所以不再检查
	# 血量（原先读的是单人 player/enemy_formation_hp，组队模式下是脱节的错误变量）。
	return int(round_index) == GameState.FINAL_ROUND and not GameState.final_round_played

static func is_treasure_round(round_index: int) -> bool:
	var schedule := active_schedule()
	return _array_has_round(schedule.get("treasure_after_battle_rounds", []), round_index)

static func is_pvp_schedule_round(round_index: int) -> bool:
	var schedule := active_schedule()
	return _array_has_round(schedule.get("pvp_rounds", []), round_index)

static func active_schedule() -> Dictionary:
	return schedule_for(GameState.FINAL_ROUND)

# 指定赛程（21 / 13 回合）的那一份表。战斗服务器一个进程里开着很多房间，只能按房间的赛程问，
# 不能读 GameState.FINAL_ROUND（那是本机这一局的）。
static func schedule_for(final_round: int) -> Dictionary:
	var all_rounds: Dictionary = DataRegistry.get_table("rounds")
	if final_round == 13:
		return all_rounds.get("seedling", {}) as Dictionary
	return all_rounds

# 赛程表里排在 round_index **之前**的 PvP 回合有几个（第 6 回合是 PvP ⇒ 第 7 回合起算 1 个）。
# 只按赛程表数，不看那一回合有没有匹配到真人对手。猴子的复制成功率按它涨
# （PetService.first_buy_copy_rate）。
static func pvp_rounds_before(round_index: int, final_round: int) -> int:
	var pvp_rounds: Variant = schedule_for(final_round).get("pvp_rounds", [])
	if typeof(pvp_rounds) != TYPE_ARRAY:
		return 0
	var count := 0
	for value in pvp_rounds:
		if int(value) < int(round_index):
			count += 1
	return count

static func treasure_pick_count(round_index: int) -> int:
	var schedule := active_schedule()
	if not _array_has_round(schedule.get("treasure_after_battle_rounds", []), round_index):
		return 0
	var counts: Dictionary = schedule.get("treasure_pick_counts", {})
	return maxi(1, int(counts.get(str(round_index), 1)))

static func _array_has_round(values: Variant, round_index: int) -> bool:
	if typeof(values) != TYPE_ARRAY:
		return false
	var wanted := int(round_index)
	for value in values:
		if int(value) == wanted:
			return true
	return false
