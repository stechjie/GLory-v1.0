class_name BattleSimSkills
extends BattleSimShared

static func _mark_vfx_target(caster: Dictionary, target: Dictionary) -> void:
	# Visual metadata only. Combat selection and damage remain unchanged.
	caster.vfx_skill_target_uid = str(target.get("uid", ""))

static func _apply_death_servant_aura(servant: Dictionary, team_units: Array, d: Dictionary) -> void:
	var duration := float(d.get("ally_def_duration", 5.0))
	if duration <= 0.0:
		return
	# 4 星把「+3 防」换成「+30% 防」（设计文档 §5.7）。绝对值不随星级缩放，
	# 4 星和 1 星效果完全一样 —— 那正是这一条要改的理由。
	# ally_def_pct 只在 4 星的 star4 覆写里有，1~3 星仍走绝对值那一支。
	var pct := float(d.get("ally_def_pct", 0.0))
	var amount := int(d.get("ally_def_bonus", 3))
	if pct <= 0.0 and amount <= 0:
		return
	var slot := int(servant.get("slot", -99))
	for a in team_units:
		if not bool(a.get("alive", false)) or a == servant:
			continue
		if abs(int(a.get("slot", -99)) - slot) > 1:
			continue
		if pct > 0.0:
			StatusEffectService.add_status(a, "defense_flat_up", duration,
				{"amount": maxi(1, int(round(float(a.get("def", 0)) * pct)))})
		else:
			StatusEffectService.add_status(a, "defense_flat_up", duration, {"amount": amount})

static func _skill_lowest_ally_heal(caster: Dictionary, allies: Array, d: Dictionary) -> void:
	var target := _lowest_hp_ratio(allies)
	if target.is_empty(): return
	_mark_vfx_target(caster, target)
	var heal := maxi(1, int(float(target.max_hp) * float(d.get("heal_pct", 0.06))))
	_heal_unit(target, heal)
	if RngService.rng.randf() < float(d.get("cleanse_chance", 0.25)):
		StatusEffectService.clear_negative_statuses(target)


static func _skill_nearest_ally_bless(caster: Dictionary, allies: Array, d: Dictionary) -> void:
	var target := _nearest(caster, allies.filter(func(a): return a != caster and bool(a.get("alive", false))))
	if target.is_empty(): return
	_mark_vfx_target(caster, target)
	target.atk = maxi(1, int(round(float(target.atk) * (1.0 + float(d.get("atk_bonus", 0.12))))))
	target.attack_speed = clampf(float(target.attack_speed) + float(d.get("aspd_bonus", 0.15)), 0.25, 2.5)
	StatusEffectService.clear_negative_statuses(target)


static func _skill_nearby_ally_heal_buff(caster: Dictionary, allies: Array, d: Dictionary) -> void:
	for a in allies:
		if not bool(a.get("alive", false)) or caster.pos.distance_to(a.pos) > 180.0: continue
		_heal_unit(a, maxi(1, int(float(a.max_hp) * float(d.get("heal_pct", 0.08)))))
		a.atk = maxi(1, int(round(float(a.atk) * (1.0 + float(d.get("atk_bonus", 0.10))))))
		a.attack_speed = clampf(float(a.attack_speed) + float(d.get("aspd_bonus", 0.15)), 0.25, 2.5)
		StatusEffectService.clear_negative_statuses(a)


static func _skill_random_attribute_bolt(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	var alive := opponents.filter(func(o): return bool(o.get("alive", false)) and _can_target(caster, o, opponents))
	if alive.is_empty():
		return
	var target: Dictionary = alive[RngService.rng.randi() % alive.size()]
	_mark_vfx_target(caster, target)
	DamageService.apply_damage(target, maxi(1, int(round(float(caster.atk) * float(d.get("damage_atk_pct", 3.0))))), false)
	_apply_attribute_effect(["fire", "ice", "thunder", "poison"][RngService.rng.randi() % 4], caster, target)
	# 4 星：有概率再触发一次随机属性效果。
	# ⚠️ 这里多摇一次随机数会改变确定性流的位置，所以**必须**先判字段再摇 ——
	# double_element_chance 只在 4 星的 star4 覆写里有，1~3 星一次 randf 都不多摇，
	# 回放哈希才不会漂。
	var double_chance := float(d.get("double_element_chance", 0.0))
	if double_chance > 0.0 and RngService.rng.randf() < double_chance:
		_apply_attribute_effect(["fire", "ice", "thunder", "poison"][RngService.rng.randi() % 4], caster, target)


static func _skill_judgement(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty(): return
	_mark_vfx_target(caster, target)
	DamageService.apply_damage(target, maxi(1, int(float(caster.atk) * float(d.get("damage_atk_pct", 2.2)))), false)
	caster.skill_stacks = mini(int(d.get("max_stacks", 5)), int(caster.get("skill_stacks", 0)) + 1)
	caster.defense = int(round(float(caster.defense) * (1.0 + float(d.get("def_stack_pct", 0.06)))))


static func _skill_archangel(caster: Dictionary, allies: Array, d: Dictionary) -> void:
	var alive := _alive(allies)
	if alive.is_empty(): return
	var target: Dictionary = alive[RngService.rng.randi() % alive.size()]
	_mark_vfx_target(caster, target)
	StatusEffectService.add_status(target, "damage_reduction", float(d.get("duration", 6.0)), {"pct": float(d.get("damage_reduction", 0.5))})


static func _skill_god_king(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	for o in opponents:
		if not bool(o.get("alive", false)) or not _can_target(caster, o, opponents): continue
		var dmg := int(float(caster.atk) * float(d.get("damage_atk_pct", 1.6))) + int(float(o.max_hp) * float(d.get("max_hp_bonus_pct", 0.08)))
		DamageService.apply_damage(o, maxi(1, dmg), false)


static func _skill_silence_bolt(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty(): return
	_mark_vfx_target(caster, target)
	var dur := _dark_duration(float(d.get("silence_sec", 1.2)), caster, state)
	StatusEffectService.add_status(target, "silence", dur, {})
	DamageService.apply_damage(target, maxi(1, int(float(caster.atk) * float(d.get("damage_atk_pct", 1.7)))), false)


static func _skill_fear(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty(): return
	_mark_vfx_target(caster, target)
	var dur := _dark_duration(float(d.get("fear_sec", 1.5)), caster, state)
	StatusEffectService.add_status(target, "stun", dur, {})
	var away: Vector2 = (target.pos - caster.pos).normalized()
	target.pos += away * 90.0


static func _skill_stun(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty(): return
	_mark_vfx_target(caster, target)
	StatusEffectService.add_status(target, "stun", _dark_duration(float(d.get("stun_sec", 1.0)), caster, state), {})


static func _skill_black_hole(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var dur := _dark_duration(float(d.get("pull_sec", 2.0)), caster, state)
	for o in opponents:
		if not bool(o.get("alive", false)) or not _can_target(caster, o, opponents) or caster.pos.distance_to(o.pos) > 220.0: continue
		StatusEffectService.add_status(o, "stun", dur, {})
		o.pos = o.pos.lerp(caster.pos, 0.45)
		DamageService.apply_damage(o, maxi(1, int(float(caster.atk) * float(d.get("damage_atk_pct", 2.2)))), false)


static func _skill_blink_low_def_backline(caster: Dictionary, allies: Array, opponents: Array, d: Dictionary, state: Dictionary) -> bool:
	var target := BattleSimulator._lowest_def_backline(caster, opponents)
	if target.is_empty():
		return false
	_mark_vfx_target(caster, target)
	var side := -1.0 if str(caster.get("team", "")) == "player" else 1.0
	caster.pos = target.pos + Vector2(28.0 * side, 0.0)
	var was_alive := bool(target.get("alive", false))
	# 4 星：突进同时给目标挂减防。原稿写的是「降低 5 点防御」的绝对值，
	# 绝对值不随星级缩放，改成百分比（设计文档 §5.7）。
	# def_down_pct 只在 4 星的 star4 覆写里有，1~3 星不挂这个状态。
	var shred := float(d.get("def_down_pct", 0.0))
	if shred > 0.0:
		StatusEffectService.add_status(target, "defense_down",
			float(d.get("duration", 5.0)), {"pct": shred})
	DamageService.apply_damage(target, maxi(1, int(round(float(caster.atk) * float(d.get("damage_atk_pct", 2.0))))), false)
	BattleSimulator._handle_attack_kill(caster, target, state, allies, opponents, was_alive)
	return was_alive and not bool(target.get("alive", false))


static func _skill_front_cone_stun(caster: Dictionary, opponents: Array, d: Dictionary, state: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty():
		return
	_mark_vfx_target(caster, target)
	DamageService.apply_damage(target, maxi(1, int(round(float(caster.atk) * float(d.get("damage_atk_pct", 1.5))))), false)
	StatusEffectService.add_status(target, "stun", _dark_duration(float(d.get("stun_sec", 1.0)), caster, state), {})

static func _skill_element_meteor(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty():
		return
	_mark_vfx_target(caster, target)
	for o in opponents:
		if bool(o.get("alive", false)) and _can_target(caster, o, opponents) and target.pos.distance_to(o.pos) <= 180.0:
			DamageService.apply_damage(o, maxi(1, int(d.get("skill_damage", 240))), true)
			_apply_attribute_effect(str(d.get("element", "fire")), caster, o)


static func _skill_holy_purify(_caster: Dictionary, allies: Array, d: Dictionary) -> void:
	for a in allies:
		if not bool(a.get("alive", false)):
			continue
		a.statuses = {}
		_heal_unit(a, maxi(1, int(round(float(a.max_hp) * float(d.get("heal_pct", 0.12))))))
		a.shield = int(a.get("shield", 0)) + maxi(1, int(round(float(a.max_hp) * float(d.get("shield_pct", 0.10)))))


static func _skill_apocalypse_charge(caster: Dictionary, state: Dictionary, d: Dictionary) -> void:
	if caster.has("apocalypse_due"):
		return
	var shield := maxi(1, int(round(float(caster.max_hp) * float(d.get("charge_shield_pct", 0.10)))))
	caster.shield = int(caster.get("shield", 0)) + shield
	caster.apocalypse_due = float(state.elapsed) + float(d.get("charge_sec", 2.0))
	caster.apocalypse_damage_atk_pct = float(d.get("damage_atk_pct", 2.5))
	caster.apocalypse_ignore_def = bool(d.get("ignore_def", true))
	state.log.append(TranslationServer.translate("log_arbiter_charging"))


static func _skill_mirror_clone(caster: Dictionary, state: Dictionary, d: Dictionary) -> void:
	var missing := 1.0 - (float(caster.hp) / float(maxi(1, int(caster.max_hp))))
	var should_have := int(floor(missing / float(d.get("clone_per_missing_hp_pct", 0.25))))
	var have := int(caster.get("mirror_clones_spawned", 0))
	if should_have <= have:
		return
	for idx in range(have + 1, should_have + 1):
		var clone := caster.duplicate(true)
		clone.uid = "%s_mirror_%d" % [str(caster.team), idx]
		clone.hp = maxi(1, int(round(float(caster.max_hp) * float(d.get("clone_hp_pct", 0.30)))))
		clone.max_hp = clone.hp
		clone.atk = maxi(1, int(round(float(caster.atk) * float(d.get("clone_atk_pct", 0.40)))))
		clone.defense = int(d.get("clone_def", 0))
		clone.alive = true
		clone.statuses = {}
		clone.skill_ready = 9999.0
		if str(caster.team) == "enemy":
			state.enemy.append(clone)
		else:
			state.player.append(clone)
	caster.mirror_clones_spawned = should_have


static func _skill_bubble_dream(caster: Dictionary, allies: Array, opponents: Array, d: Dictionary) -> void:
	var ally := _lowest_hp_ratio(allies)
	if not ally.is_empty():
		_heal_unit(ally, int(d.get("heal", 160)))
	var target := _nearest(caster, opponents)
	if not target.is_empty():
		StatusEffectService.add_status(target, "slow", 3.0, {"move_pct": float(d.get("slow_pct", 0.30)), "attack_speed_pct": float(d.get("slow_pct", 0.30))})
		DamageService.apply_damage(target, int(d.get("burst_damage", 140)), true)


static func _skill_holy_song(_caster: Dictionary, allies: Array, d: Dictionary) -> void:
	for a in allies:
		if not bool(a.get("alive", false)):
			continue
		_heal_unit(a, maxi(1, int(round(float(a.max_hp) * float(d.get("heal_pct", 0.15))))))
		if bool(d.get("cleanse_control", true)):
			for key in ["slow", "attack_down", "silence", "stun", "interrupt", "defense_down", "defense_flat_down", "heal_reduction"]:
				if a.has("statuses") and typeof(a.statuses) == TYPE_DICTIONARY:
					a.statuses.erase(key)


static func _skill_twin_strike(caster: Dictionary, state: Dictionary, d: Dictionary) -> void:
	var clone := caster.duplicate(true)
	clone.uid = "%s_twin_%d" % [str(caster.uid), int(state.get("total_deaths", 0))]
	clone.hp = maxi(1, int(round(float(caster.max_hp) * float(d.get("clone_hp_pct", 0.30)))))
	clone.max_hp = clone.hp
	clone.atk = maxi(1, int(round(float(caster.atk) * float(d.get("clone_atk_pct", 0.40)))))
	clone.statuses = {}
	clone.skill_ready = 9999.0
	if str(caster.team) == "player": state.player.append(clone)
	else: state.enemy.append(clone)


static func _skill_arrow_rain(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	var targets := _nearest_n(caster, opponents, int(d.get("targets", 5)))
	for o in targets:
		DamageService.apply_damage(o, maxi(1, int(round(float(caster.atk) * 0.85))), false)


static func _skill_steel_order(caster: Dictionary, allies: Array, d: Dictionary) -> void:
	var targets := _nearest_n(caster, allies, int(d.get("buff_targets", 3)))
	for a in targets:
		if not bool(a.get("alive", false)):
			continue
		StatusEffectService.add_status(a, "damage_reduction", float(d.get("duration", 8.0)), {"pct": float(d.get("damage_reduction", 0.20))})
		StatusEffectService.add_status(a, "speed_bonus", float(d.get("duration", 8.0)), {"pct": float(d.get("aspd_bonus", 0.20))})
		StatusEffectService.add_status(a, "control_time_reduction", float(d.get("duration", 8.0)), {"pct": float(d.get("control_time_reduction", 0.30))})


static func _skill_time_slow(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	StatusEffectService.add_status(caster, "dodge_bonus", 1.2, {"pct": 0.50})
	for o in opponents:
		if bool(o.get("alive", false)) and _can_target(caster, o, opponents):
			StatusEffectService.add_status(o, "slow", float(d.get("duration", 5.0)), {"move_pct": float(d.get("slow_pct", 0.35)), "attack_speed_pct": float(d.get("slow_pct", 0.35))})


static func _skill_gold_charge(caster: Dictionary, opponents: Array, d: Dictionary) -> void:
	var target := _nearest(caster, opponents)
	if target.is_empty(): return
	caster.pos = target.pos + Vector2(-24, 0) if str(caster.team) == "player" else target.pos + Vector2(24, 0)
	DamageService.apply_damage(target, int(d.get("skill_damage", 240)), true)
	StatusEffectService.add_status(target, "stun", float(d.get("stun_sec", 1.2)), {})


static func _skill_king_aura(caster: Dictionary, allies: Array, d: Dictionary) -> void:
	var radius := float(d.get("aura_radius", 2)) * ATTACK_RANGE_SCALE
	for a in allies:
		if bool(a.get("alive", false)) and caster.pos.distance_to(a.pos) <= radius:
			StatusEffectService.add_status(a, "speed_bonus", 2.2, {"pct": float(d.get("ally_aspd_bonus", 0.25))})
			a.crit_bonus = maxf(float(a.get("crit_bonus", 0.0)), float(d.get("ally_crit_bonus", 0.15)))


static func _skill_shell_guard(caster: Dictionary, d: Dictionary) -> void:
	StatusEffectService.add_status(caster, "damage_reduction", float(d.get("duration", 5.0)), {"pct": float(d.get("reduction", 0.50))})


# --- 法阵友军（终局守护者）---------------------------------------------------
# 五档按玩家自己的法阵血量发放（FormationAllyService.ally_id_for_hp），每边一只。
# 除焰爪外全是全场技，靠 skill_global 跳过 _skill_target_in_range 的射程判定 ——
# 近战体型也能从后排放全场大招；首发时间由 opening_cd 控制。
# 每只只活 10~20 秒，所以首发时间比冷却更决定它能不能放出来。

# 全场技的目标集合。空数组 = 场上没有可打的敌人，调用方据此不消耗冷却。
static func _living_targets(caster: Dictionary, opponents: Array) -> Array:
	var out := []
	for o in opponents:
		if bool(o.get("alive", false)) and _can_target(caster, o, opponents):
			out.append(o)
	return out


# 焰爪魔灵（1-10 血）：唯一的自保型守护者，只回自己。护盾不会自然衰减、只被伤害
# 吃掉，所以必须封顶，否则打满一场能叠出十几层。
static func _skill_ally_self_sustain(caster: Dictionary, d: Dictionary) -> void:
	_heal_unit(caster, maxi(0, int(d.get("self_heal", 200))))
	var cap := maxi(0, int(d.get("shield_cap", 300)))
	var gain := maxi(0, int(d.get("self_shield", 100)))
	caster.shield = mini(cap, int(caster.get("shield", 0)) + gain)


# 暗狱锁魂者（11-20 血）：全体眩晕 + 减攻速。只降攻速不降移速——移速降了会让敌人
# 卡在半路上，视觉上像卡顿而不像被控。
static func _skill_ally_mass_stun(caster: Dictionary, opponents: Array, d: Dictionary) -> bool:
	var targets := _living_targets(caster, opponents)
	if targets.is_empty():
		return false
	for o in targets:
		StatusEffectService.add_status(o, "stun", float(d.get("stun_sec", 1.5)), {})
		StatusEffectService.add_status(o, "slow", float(d.get("aspd_down_duration", 3.0)), {
			"attack_speed_pct": float(d.get("aspd_down_pct", 0.50)), "move_pct": 0.0,
		})
	return true


# 深渊噬兽（21-30 血）：全体沉默。silence 在 _tick_skills 开头直接 continue，是全游戏
# 最硬的 debuff——对面所有奶妈和核弹在这几秒里一个都放不出来。Boss 时长减半。
static func _skill_ally_mass_silence(caster: Dictionary, opponents: Array, d: Dictionary) -> bool:
	var targets := _living_targets(caster, opponents)
	if targets.is_empty():
		return false
	for o in targets:
		StatusEffectService.add_status(o, "silence", float(d.get("silence_sec", 3.5)), {})
	return true


# 炼狱焚界者（31-40 血）：全场灼烧 + 减攻。价值在减攻，伤害是附赠。
# burn 是每秒结算的固定 dps（不同于按最大生命百分比的中毒），所以血量基准一变
# 就必须跟着调——见 data/formation/formation_allies.json 的 burn_dps。
static func _skill_ally_inferno(caster: Dictionary, opponents: Array, d: Dictionary) -> bool:
	var targets := _living_targets(caster, opponents)
	if targets.is_empty():
		return false
	var dur := float(d.get("burn_duration", 5.0))
	for o in targets:
		StatusEffectService.add_status(o, "burn", dur, {"dps": float(d.get("burn_dps", 100.0)), "tick_left": 0.0})
		StatusEffectService.add_status(o, "attack_down", float(d.get("attack_down_duration", 5.0)), {
			"pct": float(d.get("attack_down_pct", 0.25)),
		})
	return true


# 深渊魔君·厄夜（41-50 血）：全场流星雨，无视防御。终局的一锤子买卖——它大概只活得
# 到放一到两发，所以 opening_cd 比 skill_cd 更决定这个技能存不存在。
static func _skill_ally_meteor(caster: Dictionary, opponents: Array, d: Dictionary) -> bool:
	var targets := _living_targets(caster, opponents)
	if targets.is_empty():
		return false
	var dmg := maxi(1, int(d.get("meteor_damage", 800)))
	for o in targets:
		DamageService.apply_damage(o, dmg, true)
	return true
