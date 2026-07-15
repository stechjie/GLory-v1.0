class_name BossService
extends RefCounted

const GLOBAL_STAT_MULTIPLIER := 1.5

static func growth_for_completed(completed: int) -> Dictionary:
	return {"hp": pow(1.45, completed), "atk": pow(1.35, completed), "def": pow(1.30, completed), "skill_damage": pow(1.45, completed)}
