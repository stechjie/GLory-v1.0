class_name RoundService
extends RefCounted

static func kind_for_round(round_index: int, has_online_opponent: bool) -> String:
	if _is_final_round(round_index) and has_online_opponent:
		return "final"
	var schedule: Dictionary = DataRegistry.get_table("rounds")
	if _array_has_round(schedule.get("boss_rounds", []), round_index):
		return "boss"
	if _array_has_round(schedule.get("pvp_rounds", []), round_index) and has_online_opponent:
		return "pvp"
	return "pve"

static func schedule_kind_for_round(round_index: int) -> String:
	if _is_final_round(round_index):
		return "final"
	var schedule: Dictionary = DataRegistry.get_table("rounds")
	if _array_has_round(schedule.get("boss_rounds", []), round_index):
		return "boss"
	if _array_has_round(schedule.get("pvp_rounds", []), round_index):
		return "pvp"
	return "pve"

static func _is_final_round(round_index: int) -> bool:
	# 血量归零的话对局早在到达 FINAL_ROUND 前就结束了，走不到这里，所以不再检查
	# 血量（原先读的是单人 player/enemy_formation_hp，组队模式下是脱节的错误变量）。
	return int(round_index) == GameState.FINAL_ROUND and not GameState.final_battle_complete

static func is_treasure_round(round_index: int) -> bool:
	var schedule: Dictionary = DataRegistry.get_table("rounds")
	return _array_has_round(schedule.get("treasure_after_battle_rounds", []), round_index)

static func is_pvp_schedule_round(round_index: int) -> bool:
	var schedule: Dictionary = DataRegistry.get_table("rounds")
	return _array_has_round(schedule.get("pvp_rounds", []), round_index)

static func _array_has_round(values: Variant, round_index: int) -> bool:
	if typeof(values) != TYPE_ARRAY:
		return false
	var wanted := int(round_index)
	for value in values:
		if int(value) == wanted:
			return true
	return false
