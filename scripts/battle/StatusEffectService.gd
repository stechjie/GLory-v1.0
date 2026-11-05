class_name StatusEffectService
extends RefCounted

const DEBUFF_POOL := ["slow", "attack_down", "silence", "stun", "poison", "interrupt", "bleed", "fear"]
const POISON_TICK_SEC := 1.0
const BLEED_TICK_SEC := 1.0

# 11.01 叠加规则统一（参考 Dota 2：同类相加、不同类相乘）。
# 带数值的同名状态不再「后来的覆盖前面的」：每次施加记成一个实例，生效值取各字段最强的
# 那个，时长各算各的。于是 25% 的光环顶不掉 60% 的雷霆，诅咒的「只减攻速」也抹不掉
# 冰冻的移速减速（两者同在 slow 里，按字段分别取最大）。
const MERGE_KINDS := ["slow", "attack_down", "damage_down", "defense_down", "defense_flat_down", "defense_flat_up", "heal_reduction", "ice_vulnerable", "speed_bonus", "attack_set_speed_bonus", "damage_reduction", "dodge_bonus", "control_time_reduction", "crimson_attack", "crimson_speed"]
const MAX_STATUS_INSTANCES := 4
# 攻速百分比总和的上下限（所有加速、减速、永久攻速加成相加后再夹）。
const ASPD_PCT_MIN := -0.60
const ASPD_PCT_MAX := 1.50
# 攻击百分比总和的下限：最多降到 10%。
const ATK_PCT_MIN := -0.90

static func ensure_status(fighter: Dictionary) -> void:
	if not fighter.has("statuses") or typeof(fighter.statuses) != TYPE_DICTIONARY:
		fighter.statuses = {}

# 控制类状态。恐惧是独立状态，黑洞仍使用 stun。
static func _is_control_status(kind: String) -> bool:
	return kind in ["stun", "silence", "interrupt", "fear"]


# 控制免疫。两个来源都只在 4 星才有对应字段（走 race_units.json 的 star4 覆写），
# 所以 1~3 星的行为一字不变：
#   * 天使 control_immune_sec  -> 开场挂一个 control_immune 状态
#   * 光之卫士 shield_control_immune -> 护盾还在时免疫
static func is_control_immune(fighter: Dictionary) -> bool:
	ensure_status(fighter)
	if fighter.statuses.has("control_immune"):
		return true
	var d: Dictionary = fighter.get("def", {})
	return bool(d.get("shield_control_immune", false)) and int(fighter.get("shield", 0)) > 0


static func add_status(fighter: Dictionary, kind: String, duration: float, params: Dictionary = {}, stack_poison: bool = false) -> void:
	ensure_status(fighter)
	if _is_control_status(kind) and is_control_immune(fighter):
		return
	var existing: Dictionary = fighter.statuses.get(kind, {})
	# 不变量：params 必须是扁平字典（标量值，无嵌套容器）——所有调用方目前都传
	# 现场构造的字面量。浅拷足以隔离，热路径上省去逐 tick 的深拷开销。
	var next := params.duplicate()
	var adjusted_duration := duration
	var source := _status_source_fighter()
	if not source.is_empty() and str(source.get("team", "")) != str(fighter.get("team", "")) and _is_negative_status(kind):
		var syn: Dictionary = source.get("owner_syn", DamageService._stat_state.get("player_syn", {}) if str(source.get("team", "")) == "player" else DamageService._stat_state.get("enemy_syn", {}))
		var dark_bonus := SynergyService.safe_factor(syn, "dark_debuff_strength") if str(source.get("def", {}).get("race", "")) == "dark" else 0.0
		if dark_bonus > 0.0:
			if kind in ["slow", "attack_down", "damage_down", "defense_down", "defense_flat_down", "heal_reduction", "ice_vulnerable", "poison", "bleed", "bleed_nonlethal", "burn"]:
				for key in next.keys():
					if str(key) in ["tick_left", "source_uid", "antiheal_pct", "element_owner_slot"]:
						continue
					if typeof(next[key]) == TYPE_INT or typeof(next[key]) == TYPE_FLOAT:
						next[key] = float(next[key]) * (1.0 + dark_bonus)
			else:
				adjusted_duration *= 1.0 + dark_bonus
	adjusted_duration = _duration_after_control_reduction(fighter, kind, adjusted_duration)
	if _is_boss(fighter) and _is_negative_status(kind):
		next = _boss_reduced_params(kind, next)
		if _boss_reduces_duration(kind):
			adjusted_duration *= 0.5
	if kind == "poison" and stack_poison:
		var stacks: Array = []
		if existing.has("stacks"):
			for old_stack in existing.get("stacks", []):
				if typeof(old_stack) == TYPE_DICTIONARY and float(old_stack.get("remaining", 0.0)) > 0.0:
					stacks.append(old_stack.duplicate())
		elif float(existing.get("remaining", 0.0)) > 0.0:
			stacks.append(existing.duplicate())
		next["remaining"] = adjusted_duration
		next["tick_left"] = 0.0
		var added_stack_duration := adjusted_duration
		if stacks.size() >= 2:
			var replace_idx := 1 if float(stacks[1].get("remaining", 0.0)) < float(stacks[0].get("remaining", 0.0)) else 0
			added_stack_duration = maxf(0.0, adjusted_duration - float(stacks[replace_idx].get("remaining", 0.0)))
			stacks[replace_idx] = next
		else:
			stacks.append(next)
		fighter.statuses[kind] = _poison_status_from_stacks(stacks)
		DamageService.record_status_applied(kind, added_stack_duration, true)
		_note_crimson_self_status(source, fighter, kind)
		return
	if kind in MERGE_KINDS:
		next["remaining"] = adjusted_duration
		var instances := _push_status_instance(_status_instances(existing), next)
		var merged := _merge_status_instances(instances)
		fighter.statuses[kind] = merged
		var merged_added := maxf(0.0, float(merged.remaining) - maxf(0.0, float(existing.get("remaining", 0.0))))
		DamageService.record_status_applied(kind, merged_added, _is_negative_status(kind))
		_note_crimson_self_status(source, fighter, kind)
		return
	next["remaining"] = maxf(float(existing.get("remaining", 0.0)), adjusted_duration)
	if kind == "silence":
		# Keep Lantern's attack-speed penalty on its own timer if another
		# silence refreshes the control duration.
		var lantern_time := float(existing.get("lantern_slow_remaining", 0.0))
		if next.has("lantern_slow_pct"):
			lantern_time = maxf(lantern_time, adjusted_duration)
		if lantern_time > 0.0:
			next["lantern_slow_remaining"] = lantern_time
			next["lantern_slow_pct"] = float(existing.get("lantern_slow_pct", next.get("lantern_slow_pct", 0.0)))
	if kind in ["poison", "bleed", "bleed_nonlethal", "burn"]:
		next["tick_left"] = minf(float(existing.get("tick_left", 0.0)), float(next.get("tick_left", 0.0))) if existing.has("tick_left") else 0.0
	fighter.statuses[kind] = next
	# Record the effective duration added by this application. Refreshing a status
	# must not count its already remaining time again. The damage context supplies
	# the caster, so buffs on allies and debuffs on enemies belong to that caster.
	var added_duration := maxf(0.0, float(next.remaining) - maxf(0.0, float(existing.get("remaining", 0.0))))
	DamageService.record_status_applied(kind, added_duration, _is_negative_status(kind))
	_note_crimson_self_status(source, fighter, kind)


static func _note_crimson_self_status(source: Dictionary, fighter: Dictionary, kind: String) -> void:
	if source.is_empty() or str(source.get("uid", "")) != str(fighter.get("uid", "")):
		return
	if float(fighter.get("statuses", {}).get(kind, {}).get("remaining", 0.0)) <= 0.0:
		return
	CrimsonRuneService.note_self_effect(source, DamageService._stat_state)

# 同名状态的实例表。只有一个实例时状态字典就是它本身（不带 instances 键），
# 与改版前的结构一致，读 statuses.<kind>.pct 的老代码不用改。
static func _status_instances(existing: Dictionary) -> Array:
	var out: Array = []
	if existing.has("instances"):
		for raw in existing.get("instances", []):
			if typeof(raw) == TYPE_DICTIONARY and float(raw.get("remaining", 0.0)) > 0.0:
				out.append((raw as Dictionary).duplicate())
	elif float(existing.get("remaining", 0.0)) > 0.0:
		out.append(existing.duplicate())
	return out


static func _same_instance_values(a: Dictionary, b: Dictionary) -> bool:
	for key in a.keys():
		if str(key) == "remaining":
			continue
		if not b.has(key) or b[key] != a[key]:
			return false
	for key in b.keys():
		if str(key) != "remaining" and not a.has(key):
			return false
	return true


# 数值完全相同的再次施加只刷新时长（Dota 的「同来源只刷新」）；实例数封顶，
# 超出时丢掉剩余时间最短的那个，顺序确定、不消耗随机数。
static func _push_status_instance(instances: Array, next: Dictionary) -> Array:
	for inst in instances:
		if _same_instance_values(inst, next):
			inst["remaining"] = maxf(float(inst.get("remaining", 0.0)), float(next.get("remaining", 0.0)))
			return instances
	instances.append(next)
	while instances.size() > MAX_STATUS_INSTANCES:
		var drop := 0
		for i in instances.size():
			if float(instances[i].get("remaining", 0.0)) < float(instances[drop].get("remaining", 0.0)):
				drop = i
		instances.remove_at(drop)
	return instances


# 生效值：每个数值字段取所有实例里的最大值，remaining 取最长；非数值字段取第一个实例的。
static func _merge_status_instances(instances: Array) -> Dictionary:
	if instances.size() == 1:
		return (instances[0] as Dictionary).duplicate()
	var merged := {}
	for raw in instances:
		var inst: Dictionary = raw
		for key in inst.keys():
			var v = inst[key]
			if (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT) and merged.has(key):
				merged[key] = maxf(float(merged[key]), float(v))
			elif not merged.has(key):
				merged[key] = v
	var copies: Array = []
	for raw in instances:
		copies.append((raw as Dictionary).duplicate())
	merged["instances"] = copies
	return merged


# Keep top-level poison fields for healing, VFX and replay readers.
# Each nested stack retains its own duration, tick timer, strength and caster.
static func _poison_status_from_stacks(stacks: Array) -> Dictionary:
	if stacks.size() == 1:
		return (stacks[0] as Dictionary).duplicate()
	var first: Dictionary = stacks[0]
	var second: Dictionary = stacks[1]
	var primary: Dictionary = first if float(first.get("remaining", 0.0)) >= float(second.get("remaining", 0.0)) else second
	var status := primary.duplicate()
	status["stacks"] = stacks
	status["antiheal_pct"] = maxf(float(first.get("antiheal_pct", 0.0)), float(second.get("antiheal_pct", 0.0)))
	return status


static func _status_source_fighter() -> Dictionary:
	var source_uid := DamageService.current_stat_source_uid()
	if source_uid.is_empty():
		return {}
	var state: Dictionary = DamageService._stat_state
	for f in (state.get("player", []) + state.get("enemy", [])):
		if str(f.get("uid", "")) == source_uid:
			return f
	return {}


static func _is_boss(fighter: Dictionary) -> bool:
	var d: Dictionary = fighter.get("def", {})
	var id := str(fighter.get("id", d.get("id", "")))
	return bool(d.get("is_boss", false)) or id.begins_with("boss_")

static func _is_negative_status(kind: String) -> bool:
	return kind in ["slow", "attack_down", "damage_down", "silence", "stun", "fear", "interrupt", "defense_down", "defense_flat_down", "heal_reduction", "ice_vulnerable", "ice_affected", "poison", "bleed", "bleed_nonlethal", "burn"]

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
	return kind in ["silence", "stun", "fear", "interrupt", "ice_affected"]

static func _boss_reduced_params(kind: String, params: Dictionary) -> Dictionary:
	# 不变量：唯一调用方（add_status）传入的已是私有拷贝，可就地修改。
	var next := params
	if kind in ["slow", "attack_down", "damage_down", "defense_down", "defense_flat_down", "heal_reduction", "ice_vulnerable", "poison", "bleed", "bleed_nonlethal", "burn"]:
		for key in next.keys():
			# element_owner_slot 是对账用的下标，不是数值型效果参数 —— 不豁免它
			# 会被「对 boss 减半」当成 3 → 1.5 就地改坏，毒伤就会记错席位。
			if str(key) in ["tick_left", "antiheal_pct", "element_owner_slot"]:
				continue
			if typeof(next[key]) == TYPE_INT or typeof(next[key]) == TYPE_FLOAT:
				next[key] = float(next[key]) * 0.5
	return next

# Damage-over-time effects remember who applied them.
#
# The caster is read from the damage context rather than passed in by every call
# site: whoever applies the effect (basic attack, skill dispatch, treasure
# reaction) has already opened that context, so this is correct for all ten
# existing call sites and for any added later. _boss_reduced_params only halves
# int/float params, so the uid string passes through untouched.
#
# Without it a DoT kill leaves killer_uid empty and
# BattleSimulator._process_pending_kill_rewards skips the victim: the kill gold
# is not misattributed, it is lost outright, and the stats panel credits nobody.
static func add_poison(fighter: Dictionary, duration: float = 4.0, pct_max_hp: float = 0.03, bonus: float = 0.0, force_undead_stack: bool = false) -> void:
	var source := _status_source_fighter()
	var source_syn: Dictionary = source.get("owner_syn", DamageService._stat_state.get("player_syn", {}) if str(source.get("team", "")) == "player" else DamageService._stat_state.get("enemy_syn", {}))
	var antiheal := SynergyService.safe_factor(source_syn, "undead_poison_antiheal") if str(source.get("def", {}).get("race", "")) == "undead" else 0.0
	add_status(fighter, "poison", duration, {
		"pct_max_hp": pct_max_hp * (1.0 + bonus),
		"tick_left": 0.0,
		"source_uid": DamageService.current_stat_source_uid(),
		# 10.09 第 4 条：挂毒时若处在元素旁路里（自爆灵爆炸 / 寄生灵分身），
		# 把 owner_slot 一起存下来 —— 这些毒后续跳的每一跳都该进「总伤害」而非某个棋子。
		"element_owner_slot": DamageService.current_element_owner_slot(),
		"antiheal_pct": antiheal,
	}, pct_max_hp > 0.0 and (force_undead_stack or str(source.get("def", {}).get("race", "")) == "undead"))

static func add_bleed(fighter: Dictionary, duration: float = 3.0, pct_current_hp: float = 0.06, nonlethal: bool = false) -> void:
	# Offensive bleed is lethal. Blood Pact uses a separate status key so its
	# permanent self-bleed can retain the 1 HP floor without being merged with,
	# or stealing attribution from, an enemy-applied bleed.
	var kind := "bleed_nonlethal" if nonlethal else "bleed"
	add_status(fighter, kind, duration, {
		"pct_current_hp": pct_current_hp,
		"tick_left": 0.0,
		"source_uid": DamageService.current_stat_source_uid(),
		"element_owner_slot": DamageService.current_element_owner_slot(),
	})


# _tick_statuses clears the damage context before every fighter, so the caster
# recorded above has to be put back for the duration of the tick. 10.09 第 4 条
# 新增的元素旁路（element_owner_slot）与 source_uid 同样要一起还原 —— 它决定了
# 这一跳是记进某个棋子的 damage_dealt，还是记进席位级的「元素伤害」账本。
static func _apply_dot_damage(fighter: Dictionary, amount: int, params: Dictionary) -> void:
	var previous := DamageService.current_stat_source_uid()
	var previous_slot := DamageService.current_element_owner_slot()
	var source := str(params.get("source_uid", ""))
	if not source.is_empty():
		DamageService.set_stat_source_uid(source)
	DamageService.set_element_owner_slot(int(params.get("element_owner_slot", -1)))
	DamageService._dot_damage_active = true
	DamageService.apply_damage(fighter, amount, true)
	DamageService._dot_damage_active = false
	DamageService.set_stat_source_uid(previous)
	DamageService.set_element_owner_slot(previous_slot)

static func interrupt(fighter: Dictionary, duration: float = 1.0) -> void:
	# 缴械：1 秒内无法进行普通攻击（普攻在 _perform_attack 处被 has_status("interrupt") 拦下）。
	add_status(fighter, "interrupt", duration, {})

static func tick(fighter: Dictionary, delta: float) -> Array[int]:
	ensure_status(fighter)
	var damages: Array[int] = []
	var remove_keys: Array[String] = []
	for key in fighter.statuses.keys():
		var s: Dictionary = fighter.statuses[key]
		if key == "poison" and s.has("stacks"):
			var active_stacks: Array = []
			for raw_stack in s.get("stacks", []):
				var stack: Dictionary = raw_stack
				stack.remaining = float(stack.get("remaining", 0.0)) - delta
				stack.tick_left = float(stack.get("tick_left", 0.0)) - delta
				if float(stack.tick_left) <= 0.0 and bool(fighter.get("alive", false)):
					stack.tick_left = POISON_TICK_SEC
					var stack_dmg := maxi(1, int(floor(float(fighter.max_hp) * float(stack.get("pct_max_hp", 0.03)))))
					_apply_dot_damage(fighter, stack_dmg, stack)
					damages.append(stack_dmg)
				if float(stack.remaining) > 0.0:
					active_stacks.append(stack)
			if active_stacks.is_empty():
				remove_keys.append(str(key))
			else:
				fighter.statuses[key] = _poison_status_from_stacks(active_stacks)
			continue
		if s.has("instances"):
			var alive_instances: Array = []
			for raw_inst in s.get("instances", []):
				var inst: Dictionary = raw_inst
				inst.remaining = float(inst.get("remaining", 0.0)) - delta
				if float(inst.remaining) > 0.0:
					alive_instances.append(inst)
			if alive_instances.is_empty():
				remove_keys.append(str(key))
			else:
				fighter.statuses[key] = _merge_status_instances(alive_instances)
			continue
		s.remaining = float(s.get("remaining", 0.0)) - delta
		if key == "silence" and s.has("lantern_slow_remaining"):
			s.lantern_slow_remaining = maxf(0.0, float(s.lantern_slow_remaining) - delta)
		if key == "poison":
			s.tick_left = float(s.get("tick_left", 0.0)) - delta
			if float(s.tick_left) <= 0.0:
				s.tick_left = POISON_TICK_SEC
				var dmg := maxi(1, int(floor(float(fighter.max_hp) * float(s.get("pct_max_hp", 0.03)))))
				_apply_dot_damage(fighter, dmg, s)
				damages.append(dmg)
		elif key == "burn":
			s.tick_left = float(s.get("tick_left", 0.0)) - delta
			if float(s.tick_left) <= 0.0:
				s.tick_left = 1.0
				var burn_dmg := maxi(1, int(round(float(s.get("dps", 1.0)))))
				_apply_dot_damage(fighter, burn_dmg, s)
				damages.append(burn_dmg)
		elif key == "bleed" or key == "bleed_nonlethal":
			s.tick_left = float(s.get("tick_left", 0.0)) - delta
			if float(s.tick_left) <= 0.0:
				s.tick_left = BLEED_TICK_SEC
				var dmg2 := bleed_damage(
					int(fighter.hp),
					float(s.get("pct_current_hp", 0.06)),
					key == "bleed_nonlethal")
				if dmg2 > 0:
					_apply_dot_damage(fighter, dmg2, s)
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

# 11.01：战斗中的攻击百分比全部相加后再乘一次（不再互相复利），最低 10%。
static func attack_multiplier(fighter: Dictionary) -> float:
	ensure_status(fighter)
	var pct := 0.0
	if fighter.statuses.has("attack_down"):
		pct -= float(fighter.statuses.attack_down.get("pct", 0.0))
	if fighter.statuses.has("crimson_attack"):
		pct += float(fighter.statuses.crimson_attack.get("pct", 0.0))
	pct += 0.10 * float(fighter.get("crimson_pulse_stacks", 0))
	for layer in fighter.get("crimson_drum_atk", []):
		pct += float((layer as Dictionary).get("pct", 0.0))
	pct += 0.05 * float(fighter.get("crimson_resonance_stacks", 0))
	return 1.0 + maxf(ATK_PCT_MIN, pct)

# 11.01：攻速改成 Dota 式——所有加速、减速和永久攻速加成（aspd_bonus_pct）按百分比相加，
# 夹在 [-60%, +150%] 后乘一次面板攻速。extra_pct 留给按血量变化的血怒这类动态加成。
static func attack_speed_multiplier(fighter: Dictionary, extra_pct: float = 0.0) -> float:
	ensure_status(fighter)
	var pct := extra_pct + float(fighter.get("aspd_bonus_pct", 0.0))
	if fighter.statuses.has("slow"):
		pct -= float(fighter.statuses.slow.get("attack_speed_pct", 0.0))
	if fighter.statuses.has("silence") and float(fighter.statuses.silence.get("lantern_slow_remaining", 0.0)) > 0.0:
		pct -= float(fighter.statuses.silence.get("lantern_slow_pct", 0.0))
	if fighter.statuses.has("speed_bonus"):
		pct += float(fighter.statuses.speed_bonus.get("pct", fighter.statuses.speed_bonus.get("attack_speed_pct", 0.0)))
	if fighter.statuses.has("attack_set_speed_bonus"):
		pct += float(fighter.statuses.attack_set_speed_bonus.get("pct", 0.0))
	if fighter.statuses.has("crimson_speed"):
		pct += float(fighter.statuses.crimson_speed.get("pct", 0.0))
	pct += 0.10 * float(fighter.get("crimson_pulse_stacks", 0))
	for layer in fighter.get("crimson_drum_speed", []):
		pct += float((layer as Dictionary).get("pct", 0.0))
	pct += 0.05 * float(fighter.get("crimson_resonance_stacks", 0))
	pct += CrimsonRuneService.attack_speed_multiplier(fighter) - 1.0
	return (1.0 + clampf(pct, ASPD_PCT_MIN, ASPD_PCT_MAX)) * frenzy_multiplier(fighter)

static func frenzy_multiplier(fighter: Dictionary) -> float:
	return maxf(1.0, float(fighter.get("frenzy_speed_multiplier", 1.0)))

# Apply the existing ordinary-speed cap before the treasure's persistent gain.
static func effective_attack_speed(fighter: Dictionary, extra_pct: float = 0.0) -> float:
	var frenzy := frenzy_multiplier(fighter)
	var ordinary := float(fighter.get("attack_speed", 1.0)) * attack_speed_multiplier(fighter, extra_pct) / frenzy
	return clampf(ordinary, 0.25, 2.5) * frenzy


# 王者光环的暴击跟着它的加速状态走，光环断了暴击也没了（以前写在 crit_bonus 上，永久保留）。
static func status_crit_bonus(fighter: Dictionary) -> float:
	ensure_status(fighter)
	if not fighter.statuses.has("speed_bonus"):
		return 0.0
	return float(fighter.statuses.speed_bonus.get("crit_pct", 0.0))

static func move_speed_multiplier(fighter: Dictionary) -> float:
	ensure_status(fighter)
	var mul := 1.0
	if fighter.statuses.has("slow"):
		mul *= maxf(0.1, 1.0 - float(fighter.statuses.slow.get("move_pct", 0.0)))
	return mul

static func bleed_damage(current_hp: int, pct: float = 0.06, nonlethal: bool = false) -> int:
	if current_hp <= 0 or (nonlethal and current_hp <= 1):
		return 0
	var amount := maxi(1, int(floor(float(current_hp) * pct)))
	if nonlethal:
		amount = mini(amount, current_hp - 1)
	return amount

static func silence_blocks_skill() -> bool:
	return true

static func _duration_after_control_reduction(fighter: Dictionary, kind: String, duration: float) -> float:
	ensure_status(fighter)
	if not fighter.statuses.has("control_time_reduction"):
		return duration
	# 11.01：只缩短负面效果。以前列表里混着加速、减伤、无敌、闪避这些正面状态，
	# 钢铁号令的「控制减免 30%」会把神 7 的无敌、天使庇护也一起砍短 30%。
	# 中毒、流血、灼烧这类持续伤害本来就不在列表里，保持不变。
	if kind in ["slow", "attack_down", "damage_down", "silence", "stun", "fear", "interrupt", "defense_down", "defense_flat_down", "heal_reduction", "ice_vulnerable", "ice_affected"]:
		return duration * maxf(0.0, 1.0 - float(fighter.statuses.control_time_reduction.get("pct", 0.0)))
	return duration


