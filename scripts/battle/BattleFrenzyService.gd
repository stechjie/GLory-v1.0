class_name BattleFrenzyService
extends RefCounted

const FRENZY_I_SEC := 35.0
const FRENZY_II_SEC := 45.0
const FRENZY_III_SEC := 55.0
const SUDDEN_DEATH_SEC := 65.0
const SUDDEN_DEATH_INTERVAL_SEC := 1.0
const SUDDEN_DEATH_MAX_HP_PCT := 0.05


static func stage_for_elapsed(elapsed: float) -> int:
	if elapsed >= SUDDEN_DEATH_SEC:
		return 4
	if elapsed >= FRENZY_III_SEC:
		return 3
	if elapsed >= FRENZY_II_SEC:
		return 2
	if elapsed >= FRENZY_I_SEC:
		return 1
	return 0


static func damage_multiplier(elapsed: float) -> float:
	match stage_for_elapsed(elapsed):
		1: return 1.20
		2: return 1.50
		3, 4: return 2.00
	return 1.0


static func healing_multiplier(elapsed: float) -> float:
	match stage_for_elapsed(elapsed):
		1: return 0.80
		2: return 0.50
		3, 4: return 0.20
	return 1.0


static func shield_multiplier(elapsed: float) -> float:
	match stage_for_elapsed(elapsed):
		2: return 0.70
		3, 4: return 0.40
	return 1.0
