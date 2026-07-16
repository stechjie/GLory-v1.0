class_name StatusEffectService
extends RefCounted

const DEBUFF_POOL := ["slow", "attack_down", "silence", "stun", "poison", "interrupt", "bleed"]
const POISON_TICK_SEC := 1.0
const BLEED_TICK_SEC := 1.0

static func ensure_status(fighter: Dictionary) -> void:
	if not fighter.has("statuses") or typeof(fighter.statuses) != TYPE_DICTIONARY:
		fighter.statuses = {}

static func add_status(fighter: Dictionary, kind: String, duration: float, params: Dictionary = {}) -> void:
	ensure_status(fighter)
	var existing: Dictionary = fighter.statuses.get(kind, {})
	# 不变量：params 必须是扁平字典（标量值，无嵌套容器）——所有调用方目前都传
	# 现场构造的字面量。浅拷足以隔离，热路径上省去逐 tick 的深拷开销。
	var next := params.duplicate()
	var adjusted_duration := _duration_after_control_reduction(fighter, kind, duration)
	if _is_boss(fighter) and _is_negative_status(kind):
		next = _boss_reduced_params(kind, next)
		if _boss_reduces_duration(kind):
			adjusted_duration *= 0.5
	next["remaining"] = maxf(float(existing.get("remaining", 0.0)), adjusted_duration)
	if kind == "poison" or kind == "bleed" or kind == "burn":
		next["tick_left"] = minf(float(existing.get("tick_left", 0.0)), float(next.get("tick_left", 0.0))) if existing.has("tick_left") else 0.0
	fighter.statuses[kind] = next

static func _is_boss(fighter: Dictionary) -> bool:
	var d: Dictionary = fighter.get("def", {})
	var id := str(fighter.get("id", d.get("id", "")))
	return bool(d.get("is_boss", false)) or id.begins_with("boss_")

static func _is_negative_status(kind: String) -> bool:
	return kind in ["slow", "attack_down", "silence", "stun", "interrupt", "defense_down", "defense_flat_down", "heal_reduction", "ice_vulnerable", "ice_affected", "poison", "bleed", "burn"]

static func clear_negative_statuses(fighter: Dictionary) -> int:
	ensure_status(fighter)
	var remove_keys: Array[String] = []
	for kind in fighter.statuses.keys():
		if _is_negative_status(str(kind)):
			remove_keys.append(str(kind))
	for kind in remove_keys:
		fighter.statuses.erase(kind)
	return remove_keys.size()

static func _boss_reduces_duration(kind: String) -> bool:
	return kind in ["silence", "stun", "interrupt", "ice_affected"]

static func _boss_reduced_params(kind: String, params: Dictionary) -> Dictionary:
	# 不变量：唯一调用方（add_status）传入的已是私有拷贝，可就地修改。
	var next := params
	if kind in ["slow", "attack_down", "defense_down", "defense_flat_down", "heal_reduction", "ice_vulnerable", "poison", "bleed", "burn"]:
		for key in next.keys():
			if str(key) == "tick_left":
				continue
			if typeof(next[key]) == TYPE_INT or typeof(next[key]) == TYPE_FLOAT:
				next[key] = float(next[key]) * 0.5
	return next

static func add_poison(fighter: Dictionary, duration: float = 4.0, pct_max_hp: float = 0.03, bonus: float = 0.0) -> void:
	add_status(fighter, "poison", duration, {"pct_max_hp": pct_max_hp * (1.0 + bonus), "tick_left": 0.0})

static func add_bleed(fighter: Dictionary, duration: float = 3.0, pct_current_hp: float = 0.06) -> void:
	add_status(fighter, "bleed", duration, {"pct_current_hp": pct_current_hp, "tick_left": 0.0})

static func interrupt(fighter: Dictionary) -> void:
	# 缴械：1 秒内无法进行普通攻击（普攻在 _perform_attack 处被 has_status("interrupt") 拦下）。
	add_status(fighter, "interrupt", 1.0, {})

static func tick(fighter: Dictionary, delta: float) -> Array[int]:
	ensure_status(fighter)
	var damages: Array[int] = []
	var remove_keys: Array[String] = []
	for key in fighter.statuses.keys():
		var s: Dictionary = fighter.statuses[key]
		s.remaining = float(s.get("remaining", 0.0)) - delta
		if key == "poison":
			s.tick_left = float(s.get("tick_left", 0.0)) - delta
			if float(s.tick_left) <= 0.0:
				s.tick_left = POISON_TICK_SEC
				var dmg := maxi(1, int(floor(float(fighter.max_hp) * float(s.get("pct_max_hp", 0.03)))))
				DamageService.apply_damage(fighter, dmg, true)
				damages.append(dmg)
		elif key == "burn":
			s.tick_left = float(s.get("tick_left", 0.0)) - delta
			if float(s.tick_left) <= 0.0:
				s.tick_left = 1.0
				var burn_dmg := maxi(1, int(round(float(s.get("dps", 1.0)))))
				DamageService.apply_damage(fighter, burn_dmg, true)
				damages.append(burn_dmg)
		elif key == "bleed":
			s.tick_left = float(s.get("tick_left", 0.0)) - delta
			if float(s.tick_left) <= 0.0:
				s.tick_left = BLEED_TICK_SEC
				var dmg2 := bleed_damage(int(fighter.hp), float(s.get("pct_current_hp", 0.06)))
				if dmg2 > 0:
					DamageService.apply_damage(fighter, dmg2, true)
					damages.append(dmg2)
		if float(s.remaining) <= 0.0:
			remove_keys.append(str(key))
		else:
			fighter.statuses[key] = s
	for k in remove_keys:
		fighter.statuses.erase(k)
	return damages

static func has_status(fighter: Dictionary, kind: String) -> bool:
	ensure_status(fighter)
	return fighter.statuses.has(kind) and float(fighter.statuses[kind].get("remaining", 0.0)) > 0.0

static func is_stunned(fighter: Dictionary) -> bool:
	return has_status(fighter, "stun")

static func defense_multiplier(fighter: Dictionary) -> float:
	ensure_status(fighter)
	var mul := 1.0
	if fighter.statuses.has("defense_down"):
		mul *= maxf(0.1, 1.0 - float(fighter.statuses.defense_down.get("pct", 0.0)))
	return mul

static func attack_multiplier(fighter: Dictionary) -> float:
	ensure_status(fighter)
	var mul := 1.0
	if fighter.statuses.has("attack_down"):
		mul *= maxf(0.1, 1.0 - float(fighter.statuses.attack_down.get("pct", 0.0)))
	return mul

static func attack_speed_multiplier(fighter: Dictionary) -> float:
	ensure_status(fighter)
	var mul := 1.0
	if fighter.statuses.has("slow"):
		mul *= maxf(0.1, 1.0 - float(fighter.statuses.slow.get("attack_speed_pct", 0.0)))
	if fighter.statuses.has("speed_bonus"):
		mul *= 1.0 + float(fighter.statuses.speed_bonus.get("pct", fighter.statuses.speed_bonus.get("attack_speed_pct", 0.0)))
	return mul

static func move_speed_multiplier(fighter: Dictionary) -> float:
	ensure_status(fighter)
	var mul := 1.0
	if fighter.statuses.has("slow"):
		mul *= maxf(0.1, 1.0 - float(fighter.statuses.slow.get("move_pct", 0.0)))
	return mul

static func bleed_damage(current_hp: int, pct: float = 0.06) -> int:
	if current_hp <= 1:
		return 0
	return maxi(1, int(floor(float(current_hp) * pct)))

static func silence_blocks_skill() -> bool:
	return true

static func _duration_after_control_reduction(fighter: Dictionary, kind: String, duration: float) -> float:
	ensure_status(fighter)
	if not fighter.statuses.has("control_time_reduction"):
		return duration
	if kind in ["slow", "attack_down", "silence", "stun", "interrupt", "defense_down", "defense_flat_down", "heal_reduction", "ice_vulnerable", "ice_affected", "dodge_bonus", "speed_bonus", "damage_reduction", "defense_flat_up", "invulnerable", "control_time_reduction"]:
		return duration * maxf(0.0, 1.0 - float(fighter.statuses.control_time_reduction.get("pct", 0.0)))
	return duration



