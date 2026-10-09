class_name DamageService
extends RefCounted

const MIN_HP_DAMAGE := 1
const BattleFrenzy := preload("res://scripts/battle/BattleFrenzyService.gd")

static var _stat_state: Dictionary = {}
static var _stat_source_uid := ""
# 10.09 bug 文档第 4 条（元素伤害没进结算面板）：结算面板的「本回合总造成伤害」是按
# owner_slot 汇总 `unit_stats[uid].damage_dealt` 得来的。可有些伤害根本没有「棋子身份」——
# 自爆灵阵亡后的死亡爆炸（连同它挂上的毒）、寄生灵分身打出的伤害。它们既不是这一击的
# 攻击者、也不在 `unit_stats` 里，谁都认领不到，于是直接从总伤害里消失（实测见
# work/_qa_1009/probe_attr_paths.gd：爆炸 250 + 毒 850 全没被计入）。
#
# `_element_owner_slot >= 0` 时开一条旁路：本次伤害只记进 `state.element_damage_by_slot`，
# 不写任何棋子的 `damage_dealt`。用户明确要求「把这类伤害计入本回合总造成伤害里，
# 但不计入棋子的个人伤害里」，这条旁路就是那个口径的落点。
static var _element_owner_slot := -1
# 「无归属来源」的 fighter 用这个字段声明自己的输出该记在哪个 owner_slot 名下。
# 目前只有寄生灵分身带它（见 BattleSimulator._maybe_spawn_parasite_clone）。
const UNATTRIBUTED_OWNER_KEY := "unattributed_owner_slot"
# 9.24 神7：StatusEffectService._apply_dot_damage 结算中毒 / 流血 / 灼烧期间置 true。
# 带 dot_pass 的无敌（神族每 5 秒那 1 秒）只挡普攻与技能，这类持续伤害照样打进来。
static var _dot_damage_active := false

# Floating hit-number context. Callers tag the current damage so the central
# emit in apply_damage can decide whether it surfaces a number. Only crit basics
# and skill hits are shown; normal basics, DoT ticks and every unclassified path
# stay silent (default kind = "").
static var _hit_kind := ""
static var _hit_is_crit := false
# Attacker race ("god"/"dark"/"undead"/"human"/...), used to color normal-attack
# numbers on the renderer side.
static var _hit_source_race := ""
static var _hit_skill_id := ""


static func current_battle_elapsed() -> float:
	return float(_stat_state.get("elapsed", 0.0))

static func set_hit_context(kind: String, is_crit: bool = false, source_race: String = "", skill_id: String = "") -> void:
	_hit_kind = kind
	_hit_is_crit = is_crit
	_hit_source_race = source_race
	_hit_skill_id = skill_id

static func clear_hit_context() -> void:
	_hit_kind = ""
	_hit_is_crit = false
	_hit_source_race = ""
	_hit_skill_id = ""

# Central damage-number emit. Rides the same state.visual_events channel the
# renderer already consumes (and that the replay records per frame), so numbers
# work identically in live play and playback. Only crit basics and skill hits
# surface — everything else is filtered out by the tag set at the call site.
static func _maybe_emit_hit_number(target: Dictionary, hp_damage: int) -> void:
	if hp_damage <= 0 or _stat_state.is_empty():
		return
	# Basic attacks (crit or not) and skill hits surface; DoT ticks, treasure
	# reactions and other unclassified paths stay silent (kind == "").
	var show := _hit_kind == "skill" or _hit_kind == "basic"
	if not show:
		return
	_append_presentation_event({
		"type": "hit_number",
		"kind": "dmg",
		"crit": _hit_is_crit,
		"skill": _hit_kind == "skill",
		"race": _hit_source_race,
		"source_uid": _stat_source_uid,
		"target_uid": str(target.get("uid", "")),
		"target_uids": [str(target.get("uid", ""))],
		"skill_id": _hit_skill_id,
		"amount": hp_damage,
		"is_crit": _hit_is_crit,
		"is_lethal": not bool(target.get("alive", true)),
	})

# A successful dodge has no HP damage, so it needs its own presentation cue.
# Keep the existing RNG roll and gameplay result untouched.
static func _emit_dodge_miss(target: Dictionary) -> void:
	if _stat_state.is_empty() or not _hit_kind in ["basic", "skill"]:
		return
	var uid := str(target.get("uid", ""))
	if uid.is_empty():
		return
	_append_presentation_event({
		"type": "hit_number",
		"kind": "miss",
		"source_uid": _stat_source_uid,
		"target_uid": uid,
		"target_uids": [uid],
		"skill_id": _hit_skill_id,
		"skill": _hit_kind == "skill",
		"race": _hit_source_race,
		"amount": 0,
		"is_crit": false,
		"is_lethal": false,
		"visibility_priority": "important",
	})

# 赤卫（block_guard）格挡成功：本次伤害整段归零，没有任何数字可以表现它。
# 补一条纯表现事件给 BattleVfx 画格挡壁；格挡的随机判定在上面已经掷完，
# 这里不读写战斗状态、不消耗 RngService。source = 格挡者，target = 被挡的攻击者。
static func _emit_block(target: Dictionary) -> void:
	if _stat_state.is_empty():
		return
	var uid := str(target.get("uid", ""))
	if uid.is_empty():
		return
	var attacker_uids: Array = [] if _stat_source_uid.is_empty() else [_stat_source_uid]
	_append_presentation_event({
		"type": "unit_skill_proc",
		"skill_id": "block_guard",
		"source_uid": uid,
		"target_uid": _stat_source_uid,
		"target_uids": attacker_uids,
		"amount": 0,
		"is_crit": false,
		"is_lethal": false,
	})

# Heal numbers always surface (they are far rarer than attacks). Called from
# _heal_unit with the real post-clamp amount.
static func emit_heal_number(target: Dictionary, amount: int) -> void:
	if amount <= 0 or _stat_state.is_empty():
		return
	_append_presentation_event({
		"type": "hit_number",
		"kind": "heal",
		"source_uid": _stat_source_uid if not _stat_source_uid.is_empty() else str(target.get("uid", "")),
		"target_uid": str(target.get("uid", "")),
		"target_uids": [str(target.get("uid", ""))],
		"skill_id": _hit_skill_id if not _hit_skill_id.is_empty() else "heal",
		"amount": amount,
		"is_crit": false,
		"is_lethal": false,
	})

# --- D4: four-beat basic attack chain -----------------------------------------
# Emission order per attack is attack_start -> [projectile_spawn] -> impact ->
# hit_number -> death, which is also the order the Director plays them back on
# the attacker's action track. These are pure-data appends on the same
# state.visual_events channel hit_number already rides, so replay capture records
# them unchanged. None of them read or write combat state or consume RngService.

static func emit_attack_start(attacker: Dictionary, target: Dictionary, skill_id: String, ranged: bool) -> void:
	var attacker_uid := str(attacker.get("uid", ""))
	if attacker_uid.is_empty():
		return
	var target_uid := str(target.get("uid", ""))
	var target_uids: Array = [target_uid] if not target_uid.is_empty() else []
	_append_presentation_event({
		"type": "attack_start",
		"source_uid": attacker_uid,
		"target_uid": target_uid,
		"target_uids": target_uids,
		"skill_id": skill_id,
		"amount": 0,
		"is_crit": false,
		"is_lethal": false,
	})
	if not ranged:
		return
	_append_presentation_event({
		"type": "projectile_spawn",
		"source_uid": attacker_uid,
		"target_uid": target_uid,
		"target_uids": target_uids,
		"skill_id": skill_id,
		"amount": 0,
		"is_crit": false,
		"is_lethal": false,
	})


# Contact beat. The damage number is a separate event, so this one deliberately
# carries no amount: it only has to say "this body was struck, and how hard".
static func emit_impact(attacker: Dictionary, target: Dictionary, skill_id: String, is_crit: bool) -> void:
	var attacker_uid := str(attacker.get("uid", ""))
	var target_uid := str(target.get("uid", ""))
	if attacker_uid.is_empty() or target_uid.is_empty():
		return
	_append_presentation_event({
		"type": "impact",
		"source_uid": attacker_uid,
		"target_uid": target_uid,
		"target_uids": [target_uid],
		"skill_id": skill_id,
		"amount": 0,
		"is_crit": is_crit,
		"is_lethal": false,
	})


# source_uid is the unit that dies, not the killer: the Director cancels the
# remaining actions on that uid's own track when it sees this event.
static func emit_death(victim: Dictionary) -> void:
	var uid := str(victim.get("uid", ""))
	if uid.is_empty():
		return
	_append_presentation_event({
		"type": "death",
		"source_uid": uid,
		"target_uids": [],
		"skill_id": "death",
		"amount": 0,
		"is_crit": false,
		"is_lethal": true,
		"killer_uid": str(victim.get("killer_uid", "")),
	})


static func _append_presentation_event(event: Dictionary) -> void:
	# Opening-phase (elapsed == 0) effects fire before the renderer seeds; skip them
	# so battle start doesn't flash a burst of numbers.
	if float(_stat_state.get("elapsed", 0.0)) <= 0.0:
		return
	if not _stat_state.has("visual_events") or typeof(_stat_state.visual_events) != TYPE_ARRAY:
		_stat_state.visual_events = []
	event["time"] = float(_stat_state.get("elapsed", 0.0))
	_stat_state.visual_events.append(event)

static func begin_stat_context(state: Dictionary, source: Dictionary) -> void:
	_stat_state = state
	_stat_source_uid = str(source.get("uid", ""))
	# 10.09 第 4 条：无归属来源（寄生灵分身等）在 fighter 上带 UNATTRIBUTED_OWNER_KEY，
	# 它的输出照常按 owner_slot 入账，只是不进任何棋子的 damage_dealt。
	_element_owner_slot = int(source.get(UNATTRIBUTED_OWNER_KEY, -1))

static func begin_stat_source_uid(state: Dictionary, source_uid: String) -> void:
	_stat_state = state
	_stat_source_uid = source_uid
	_element_owner_slot = -1

static func set_stat_state(state: Dictionary) -> void:
	_stat_state = state

static func set_stat_source_uid(source_uid: String) -> void:
	_stat_source_uid = source_uid

static func clear_stat_context() -> void:
	_stat_source_uid = ""
	_element_owner_slot = -1
	# Reset the hit tag too: this is called at every attack/skill/status boundary,
	# so it doubles as a safety net that keeps a "basic"/"skill" tag from leaking
	# into later damage (treasure reactions, DoT ticks, etc.).
	_hit_kind = ""
	_hit_is_crit = false
	_hit_source_race = ""
	_hit_skill_id = ""

static func current_stat_source_uid() -> String:
	return _stat_source_uid

# 当前是否处在「元素伤害旁路」里；>= 0 表示这份伤害进 state.element_damage_by_slot。
static func current_element_owner_slot() -> int:
	return _element_owner_slot

static func set_element_owner_slot(slot: int) -> void:
	_element_owner_slot = slot

static func record_heal(target: Dictionary, amount: int) -> void:
	if amount <= 0 or _stat_state.is_empty():
		return
	var source_uid := _stat_source_uid
	if source_uid.is_empty():
		source_uid = str(target.get("uid", ""))
	_add_stat_value(source_uid, "healing_done", amount)

static func record_forced_hp_loss(target: Dictionary, amount: int = -1, count_source: bool = true) -> void:
	if _stat_state.is_empty():
		return
	var loss := amount
	if loss < 0:
		loss = int(target.get("hp", 0))
	if loss <= 0:
		return
	var previous_source := _stat_source_uid
	if not count_source:
		_stat_source_uid = ""
	_record_damage(target, loss)
	_stat_source_uid = previous_source

static func record_status_applied(kind: String, duration: float, is_negative: bool) -> void:
	if duration <= 0.0 or _stat_state.is_empty() or _stat_source_uid.is_empty():
		return
	var bucket_key := "debuffs" if is_negative else "buffs"
	if not _stat_state.has("unit_stats") or typeof(_stat_state.unit_stats) != TYPE_DICTIONARY:
		return
	if not _stat_state.unit_stats.has(_stat_source_uid):
		return
	var entry: Dictionary = _stat_state.unit_stats[_stat_source_uid]
	if not entry.has(bucket_key) or typeof(entry[bucket_key]) != TYPE_DICTIONARY:
		entry[bucket_key] = {}
	var bucket: Dictionary = entry[bucket_key]
	bucket[kind] = float(bucket.get(kind, 0.0)) + duration
	entry[bucket_key] = bucket
	_stat_state.unit_stats[_stat_source_uid] = entry

static func damage_reduction(defense: int) -> float:
	var d := maxi(0, defense)
	return float(d) / float(100 + d)

static func status_damage_taken_multiplier(target: Dictionary) -> float:
	StatusEffectService.ensure_status(target)
	var mul := 1.0
	if target.statuses.has("damage_reduction"):
		mul *= maxf(0.0, 1.0 - float(target.statuses.damage_reduction.get("pct", 0.0)))
	if target.statuses.has("ice_vulnerable"):
		mul *= 1.0 + float(target.statuses.ice_vulnerable.get("pct", 0.15))
	return mul

static func source_damage_multiplier() -> float:
	if _stat_source_uid.is_empty():
		return 1.0
	for side in ["player", "enemy"]:
		for source in _stat_state.get(side, []):
			if str(source.get("uid", "")) != _stat_source_uid:
				continue
			StatusEffectService.ensure_status(source)
			if source.statuses.has("damage_down"):
				return maxf(0.0, 1.0 - float(source.statuses.damage_down.get("pct", 0.0)))
			return 1.0
	return 1.0

static func effective_defense(target: Dictionary) -> int:
	var base := float(target.get("defense", target.get("def", 0)))
	StatusEffectService.ensure_status(target)
	if target.statuses.has("defense_flat_up"):
		base += float(target.statuses.defense_flat_up.get("amount", 0))
	if target.statuses.has("defense_flat_down"):
		base -= float(target.statuses.defense_flat_down.get("amount", 0))
	base -= float(target.get("crimson_def_break", 0))
	return maxi(0, int(round(base * StatusEffectService.defense_multiplier(target))))

static func skill_hit_lands(target: Dictionary) -> bool:
	if not bool(target.get("alive", true)):
		return false
	StatusEffectService.ensure_status(target)
	if target.statuses.has("invulnerable"):
		return false
	var dodge_chance := float(target.get("dodge", 0.0))
	if target.statuses.has("dodge_bonus"):
		dodge_chance += float(target.statuses.dodge_bonus.get("pct", 0.0))
	var landed := RngService.rng.randf() >= dodge_chance
	if not landed:
		_emit_dodge_miss(target)
	return landed


# skip_dodge is reserved for a multi-pulse hit that already rolled its one dodge
# check when the cast landed. Invulnerability, defense, shields and damage-taken
# modifiers are still evaluated independently for every pulse.
static func apply_damage(target: Dictionary, amount: int, ignore_defense: bool = false, skip_dodge: bool = false) -> int:
	if amount <= 0 or not bool(target.get("alive", true)):
		return 0

	StatusEffectService.ensure_status(target)
	if target.statuses.has("invulnerable"):
		if not (_dot_damage_active and bool(target.statuses.invulnerable.get("dot_pass", false))):
			return 0
	if not _dot_damage_active and _hit_kind in ["basic", "skill"] and str(target.get("def", {}).get("skill_id", "")) == "block_guard":
		if RngService.rng.randf() < float(target.get("def", {}).get("block_chance", 0.10)):
			_emit_block(target)
			return 0
	if not skip_dodge:
		var dodge_chance := float(target.get("dodge", 0.0))
		if target.statuses.has("dodge_bonus"):
			dodge_chance += float(target.statuses.dodge_bonus.get("pct", 0.0))
		if RngService.rng.randf() < dodge_chance:
			_emit_dodge_miss(target)
			return 0
	var remaining := amount
	if not _stat_source_uid.is_empty() and _stat_source_uid != str(target.get("uid", "")):
		remaining = maxi(MIN_HP_DAMAGE, int(ceil(float(remaining) * source_damage_multiplier())))
	# Frenzy amplifies damage caused by a unit. Environmental sudden-death
	# damage has no source uid and uses apply_sudden_death_damage().
	if not _stat_source_uid.is_empty():
		remaining = maxi(MIN_HP_DAMAGE, int(round(float(remaining) * BattleFrenzy.damage_multiplier(current_battle_elapsed()))))
	if not ignore_defense:
		remaining = int(ceil(float(remaining) * (1.0 - damage_reduction(effective_defense(target)))))
	remaining = maxi(MIN_HP_DAMAGE, int(ceil(float(remaining) * status_damage_taken_multiplier(target))))
	if int(target.get("shield", 0)) > 0:
		var absorbed := mini(int(target.shield), remaining)
		target.shield = int(target.shield) - absorbed
		remaining -= absorbed
	if remaining <= 0:
		return 0
	var hp_before := int(target.hp)
	var lethal := hp_before - remaining <= 0
	if lethal and _try_sacrifice_revive(target):
		_record_damage(target, hp_before)
		return hp_before
	target.hp = maxi(0, hp_before - remaining)
	var died_now := false
	if int(target.hp) <= 0:
		target.alive = false
		died_now = true
		# 记下致死来源，供 BattleSimulator._process_pending_kill_rewards 补结算击杀金：
		# 普攻走 _handle_attack_kill 即时结算，技能/AOE 等路径不走那条线。
		# 中毒/失血/衰减没有来源上下文（_tick_statuses 会 clear_stat_context），
		# 这里会是空串——那类死亡不结算击杀金。
		target["killer_uid"] = _stat_source_uid
	_record_damage(target, mini(hp_before, remaining))
	_maybe_emit_hit_number(target, mini(hp_before, remaining))
	if died_now:
		emit_death(target)
	return remaining


# 65s sudden death: unavoidable field true damage. It ignores defense, dodge,
# damage reduction and invulnerability, while shields still absorb it first.
# With no attacker it cannot grant kill gold, lifesteal, reflect, or dealt-damage
# credit. Sacrifice/revive mechanics remain valid.
static func apply_sudden_death_damage(target: Dictionary, amount: int) -> int:
	if amount <= 0 or not bool(target.get("alive", true)):
		return 0
	StatusEffectService.ensure_status(target)
	var remaining := amount
	if int(target.get("shield", 0)) > 0:
		var absorbed := mini(int(target.shield), remaining)
		target.shield = int(target.shield) - absorbed
		remaining -= absorbed
	if remaining <= 0:
		return 0
	var hp_before := int(target.hp)
	var previous_source_uid := _stat_source_uid
	var previous_element_slot := _element_owner_slot
	_stat_source_uid = ""
	# 环境伤害（65 秒衰减）没有主人，绝不能因为外面恰好开着元素旁路就被记到某个席位上。
	_element_owner_slot = -1
	if hp_before - remaining <= 0 and _try_sacrifice_revive(target):
		_record_damage(target, hp_before)
		_stat_source_uid = previous_source_uid
		_element_owner_slot = previous_element_slot
		return hp_before
	target.hp = maxi(0, hp_before - remaining)
	var hp_damage := mini(hp_before, remaining)
	if int(target.hp) <= 0:
		target.alive = false
		target.erase("killer_uid")
	_record_damage(target, hp_damage)
	if not bool(target.get("alive", true)):
		emit_death(target)
	_stat_source_uid = previous_source_uid
	_element_owner_slot = previous_element_slot
	return hp_damage

static func _record_damage(target: Dictionary, amount: int) -> void:
	if amount <= 0 or _stat_state.is_empty():
		return
	var target_uid := str(target.get("uid", ""))
	_add_stat_value(target_uid, "damage_taken", amount)
	# 10.09 第 4 条：处在元素旁路里时，这份伤害只进 `element_damage_by_slot`，
	# 不进任何棋子的 damage_dealt（用户口径：算进总伤害、不算进个人伤害）。
	if _element_owner_slot >= 0:
		_add_element_damage(_element_owner_slot, amount)
		return
	if not _stat_source_uid.is_empty() and _stat_source_uid != target_uid:
		_add_stat_value(_stat_source_uid, "damage_dealt", amount)


# 元素伤害旁路账本：按 owner_slot 累加。结算面板（FinalSettlementData.build）
# 会把它并进每个席位的「本回合总造成伤害」。
static func _add_element_damage(owner_slot: int, amount: int) -> void:
	if owner_slot < 0 or amount <= 0 or _stat_state.is_empty():
		return
	var bucket: Variant = _stat_state.get("element_damage_by_slot", {})
	if typeof(bucket) != TYPE_DICTIONARY:
		bucket = {}
	(bucket as Dictionary)[owner_slot] = int((bucket as Dictionary).get(owner_slot, 0)) + amount
	_stat_state["element_damage_by_slot"] = bucket

static func _add_stat_value(uid: String, key: String, amount: int) -> void:
	if uid.is_empty() or amount <= 0:
		return
	if not _stat_state.has("unit_stats") or typeof(_stat_state.unit_stats) != TYPE_DICTIONARY:
		return
	if not _stat_state.unit_stats.has(uid):
		return
	var entry: Dictionary = _stat_state.unit_stats[uid]
	entry[key] = int(entry.get(key, 0)) + amount
	_stat_state.unit_stats[uid] = entry

static func _try_sacrifice_revive(target: Dictionary) -> bool:
	if bool(target.get("sacrifice_revive_used", false)) or not target.has("sacrifice_guardian"):
		return false
	var guard_value = target.get("sacrifice_guardian", {})
	if typeof(guard_value) != TYPE_DICTIONARY:
		return false
	var guard: Dictionary = guard_value
	if not bool(guard.get("alive", false)):
		return false
	target.sacrifice_revive_used = true
	target.erase("sacrifice_guardian")
	target.hp = maxi(1, int(target.get("max_hp", target.get("hp", 1))))
	target.alive = true
	record_forced_hp_loss(guard)
	guard.hp = 0
	guard.alive = false
	emit_death(guard)
	guard.erase("guard_target_uid")
	return true

