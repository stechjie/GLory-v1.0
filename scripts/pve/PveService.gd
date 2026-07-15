class_name PveService
extends RefCounted

static func growth_for_completed(completed: int) -> Dictionary:
	return {"hp": pow(1.10, completed), "atk": pow(1.08, completed), "def": pow(1.05, completed), "skill_damage": pow(1.08, completed)}
