extends Node

# 四星技能数值：`star4` 数据块的机制与**配平封顶**。
#
# 为什么要有这一条：docs/四星技能与数值设计规格.md §2 定了一张封顶表
# （治疗 ≤ 40%、减伤 ≤ 65%、攻速 ≤ 45%、控制 ≤ 3 秒、概率 ≤ 50%、
# 减防总量 ≤ 100%、伤害倍率 ≤ 基准 ×2）。那张表在**文档里**，而数值在
# race_units.json 里 —— 以后有人调一个数字时，不会有人回去对表。
#
# 这条检查就是那张表的机器可读版本。它不断言「某只单位应该是多少」
# （那是策划的事，改数值不该让检查变红），只断言「不管改成多少，都不许越过封顶」。
#
# 另外守三条机制：
#   * star4 的值在 4 星时确实生效（apply_star_stats 是唯一解析点）
#   * star4 的值**真的进到战斗里**（_fighter_from_cell 是棋盘格变战斗单位的唯一
#     入口，单机与联机共用）—— 解析点对了不等于战斗读得到，见 §1b
#   * star4 的值**不会**泄漏到 1~3 星，且 def 上不残留 star4 键
#     —— 残留就意味着任何直接读 def 的地方（尤其是玩家看得到的技能文案）
#     可能拿到第二份数值真相
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/four_star_values_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
# BattleSimTreasures has no class_name, so preload it to reach the skill hook.
const BattleSimTreasures := preload("res://scripts/battle/BattleSimTreasures.gd")

const CHECK_NAME := "four_star_values"

# docs/四星技能与数值设计规格.md §2 的封顶表，逐字段。
# 值是**绝对上限**；单位没有这个字段就跳过。
const ABSOLUTE_CAPS := {
	# 治疗 / 护盾（占最大生命的比例）
	"heal_pct": 0.40,
	"start_shield_pct": 0.40,
	"link_regen_pct": 0.40,
	# 减伤
	"damage_reduction": 0.65,
	# 攻速加成
	"aspd_bonus": 0.45,
	# 控制时长（秒）
	"stun_sec": 3.0,
	"fear_sec": 3.0,
	"silence_sec": 3.0,
	"control_immune_sec": 3.0,
	# 概率
	"cleanse_chance": 0.50,
	"dodge": 0.50,
	"double_element_chance": 0.50,
	"interrupt_chance": 0.50,
	"clone_chance": 0.50,
	"crit": 0.50,
}

# 相对封顶：4★ 值不得超过基准（3★ 那份）的这个倍数。
const RELATIVE_CAPS := {
	"damage_atk_pct": 2.0,
}

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_star4_block_applied()
	_case_star4_reaches_the_fighter()
	_case_star4_does_not_leak_to_three()
	_case_caps_respected()
	_case_cooldown_only_shortens()
	_case_defense_shred_capped()
	_case_detail_text_reads_star4()
	_case_star4_fields_are_read()
	_case_control_immunity()
	_case_star4_moves_in_the_right_direction()
	_case_growth_ceiling_exists_at_every_star()
	_case_execute_epic_band_not_reduced()
	_case_titan_armor_scales_with_star()
	_h.finish(get_tree())


func _units() -> Array:
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if not _h.expect(not units.is_empty(), "units_empty", "race_units 表为空"):
		return []
	return units


# --- 1. star4 在 4 星时生效 -------------------------------------------------------
func _case_star4_block_applied() -> void:
	var covered := 0
	for row in _units():
		var d: Dictionary = row
		var block: Variant = d.get("star4", null)
		if typeof(block) != TYPE_DICTIONARY:
			continue
		covered += 1
		var scaled := UnitFactory.apply_star_stats(d, GameConstants.MAX_STAR)
		for key in (block as Dictionary):
			var want: Variant = (block as Dictionary)[key]
			var got: Variant = scaled.get(key, null)
			if str(got) != str(want):
				_h.fail("star4_not_applied",
					"%s 的 %s：4 星应为 %s，apply_star_stats 给出 %s"
						% [str(d.get("id", "?")), key, str(want), str(got)])
			else:
				_h.item()
	_h.note("带 star4 覆写的单位：%d 只" % covered)


# --- 1b. star4 必须真的到达战斗里的 fighter ---------------------------------------
# 上一条只证明了 apply_star_stats() 本身是对的。但战斗代码读的不是它的返回值，
# 而是 fighter["def"] —— 中间隔着 _fighter_from_cell()，那是「棋盘格 -> 战斗单位」
# 的唯一入口，单机与联机共用（联机侧的快照经 NetProtocol 用数据表重建 def 之后
# 也走这里）。
#
# 实测踩过：_fighter_from_cell 只把缩放后的 hp/atk/def 三个字段抄回**原始** def，
# 于是四星属性生效、技能数值全部停留在三星，而 `star4` 子对象还原封不动挂在
# fighter.def 上。当时上面那条、tools/four_star_upgrade_check、tools/carrot_online_check
# 全是绿的 —— 因为没有任何一条走过这个入口。
func _case_star4_reaches_the_fighter() -> void:
	for row in _units():
		var d: Dictionary = row
		var block: Variant = d.get("star4", null)
		if typeof(block) != TYPE_DICTIONARY:
			continue
		var id := str(d.get("id", "?"))
		var fd := _battle_def(d, GameConstants.MAX_STAR)
		if fd.has("star4"):
			_h.fail("star4_key_reached_battle",
				"%s 的战斗 def 上还挂着 star4 子对象 —— 战斗代码可能读到第二份数值" % id)
		for key in (block as Dictionary):
			var want: Variant = (block as Dictionary)[key]
			var got: Variant = fd.get(key, null)
			if str(got) != str(want):
				_h.fail("star4_not_in_fighter",
					"%s 的 %s：四星战斗里应为 %s，fighter.def 给出 %s —— 数值填了但打不出来"
						% [id, key, str(want), str(got)])
			else:
				_h.item()
		# 属性也要按四星系数到位：这条同时盯着「只抄了技能、忘了属性」的反向写法。
		var scaled := UnitFactory.apply_star_stats(d, GameConstants.MAX_STAR)
		for stat in ["hp", "atk", "def"]:
			if int(fd.get(stat, 0)) != int(scaled.get(stat, 0)):
				_h.fail("star4_stat_not_in_fighter",
					"%s 的四星 %s：应为 %d，fighter.def 给出 %d"
						% [id, stat, int(scaled.get(stat, 0)), int(fd.get(stat, 0))])
			else:
				_h.item()
		# 反向：三星的 fighter 不许拿到四星数值（判据写成 star >= 3 时这里红）。
		var fd3 := _battle_def(d, GameConstants.MAX_MERGE_STAR)
		for key3 in (block as Dictionary):
			var base: Variant = d.get(key3, null)
			if base == null:
				continue   # 4★ 才有的新字段，低星没有基准可比
			if str(fd3.get(key3, null)) != str(base):
				_h.fail("star4_leaked_to_fighter",
					"%s 的三星战斗 %s 是 %s，应保持基准值 %s"
						% [id, key3, str(fd3.get(key3, null)), str(base)])
			else:
				_h.item()


# 把一张数据表行按指定星级送过战斗的建单位入口，取回战斗真正会读的那份 def。
# race_relations 留空 -> 种族关系系数为 1.0，这条只想量星级这一个变量。
func _battle_def(row: Dictionary, star: int) -> Dictionary:
	var cell := {
		"id": str(row.get("id", "")),
		"uid": "check-%s-%d" % [str(row.get("id", "")), star],
		"star": star,
		"def": row.duplicate(true),
		"is_mercenary": false,
		"race_relations": {},
	}
	return BattleSimShared._fighter_from_cell(cell, 0, "player").get("def", {})


# --- 2. 不许泄漏到 1~3 星 ---------------------------------------------------------
# 最容易写出的错法是把判据写成 `star >= 3`，或者忘了 erase("star4")。
# 前者让三星白拿四星数值，后者在 def 上留下第二份数值真相。
func _case_star4_does_not_leak_to_three() -> void:
	for row in _units():
		var d: Dictionary = row
		var block: Variant = d.get("star4", null)
		if typeof(block) != TYPE_DICTIONARY:
			continue
		for star in [1, 2, GameConstants.MAX_MERGE_STAR]:
			var scaled := UnitFactory.apply_star_stats(d, star)
			if scaled.has("star4"):
				_h.fail("star4_key_leaked",
					"%s 的 %d 星 def 上还挂着 star4 子对象 —— 任何直接读 def 的地方都可能拿错那一份"
						% [str(d.get("id", "?")), star])
				continue
			for key in (block as Dictionary):
				var base: Variant = d.get(key, null)
				if base == null:
					continue   # 4★ 才有的新字段，低星没有基准可比
				if str(scaled.get(key, null)) != str(base):
					_h.fail("star4_leaked_to_low_star",
						"%s 的 %d 星 %s 是 %s，应保持基准值 %s —— 四星数值泄漏到了低星"
							% [str(d.get("id", "?")), star, key, str(scaled.get(key, null)), str(base)])
				else:
					_h.item()


# --- 3. 封顶（本检查的核心）-------------------------------------------------------
func _case_caps_respected() -> void:
	for row in _units():
		var d: Dictionary = row
		if typeof(d.get("star4", null)) != TYPE_DICTIONARY:
			continue
		var uid := str(d.get("id", "?"))
		var scaled := UnitFactory.apply_star_stats(d, GameConstants.MAX_STAR)
		for key in ABSOLUTE_CAPS:
			if not scaled.has(key):
				continue
			var value := float(scaled[key])
			var cap := float(ABSOLUTE_CAPS[key])
			if value > cap + 0.0001:
				_h.fail("cap_exceeded",
					"%s 的 4 星 %s = %s，超过配平封顶 %s（docs/四星技能与数值设计规格.md §2）"
						% [uid, key, str(value), str(cap)])
			else:
				_h.item()
		for key in RELATIVE_CAPS:
			if not scaled.has(key) or not d.has(key):
				continue
			var base := float(d[key])
			if base <= 0.0:
				continue
			var ratio := float(scaled[key]) / base
			var limit := float(RELATIVE_CAPS[key])
			if ratio > limit + 0.0001:
				_h.fail("relative_cap_exceeded",
					"%s 的 4 星 %s 是基准的 %.2f 倍（%s -> %s），封顶 %s 倍"
						% [uid, key, ratio, str(base), str(scaled[key]), str(limit)])
			else:
				_h.item()


# --- 4. 冷却只能变短 --------------------------------------------------------------
# §2：冷却「缩短 25~35%」。写成变长不会报错，只会让四星比三星更弱。
func _case_cooldown_only_shortens() -> void:
	for row in _units():
		var d: Dictionary = row
		if typeof(d.get("star4", null)) != TYPE_DICTIONARY:
			continue
		if not d.has("skill_cd"):
			continue
		var scaled := UnitFactory.apply_star_stats(d, GameConstants.MAX_STAR)
		var before := float(d.get("skill_cd", 0.0))
		var after := float(scaled.get("skill_cd", before))
		if after > before + 0.0001:
			_h.fail("cooldown_grew",
				"%s 的技能冷却从 %s 涨到了 %s —— 四星不该比三星更弱"
					% [str(d.get("id", "?")), str(before), str(after)])
		else:
			_h.item()


# --- 5. 减防总量不得打出负防御 -----------------------------------------------------
# §2：每层减防 × 最大层数 ≤ 100%。
func _case_defense_shred_capped() -> void:
	for row in _units():
		var d: Dictionary = row
		var scaled := UnitFactory.apply_star_stats(d, GameConstants.MAX_STAR)
		if not scaled.has("def_down_pct"):
			continue
		var per_stack := float(scaled.get("def_down_pct", 0.0))
		var stacks := maxi(1, int(scaled.get("max_stacks", 1)))
		var total := per_stack * float(stacks)
		if total > 1.0 + 0.0001:
			_h.fail("defense_shred_uncapped",
				"%s 的减防总量 %.2f × %d 层 = %.2f，超过 100%% —— 会打出负防御"
					% [str(d.get("id", "?")), per_stack, stacks, total])
		else:
			_h.item()


# --- 6. 玩家看到的技能文案必须是四星那一份 -----------------------------------------
# format_skill_detail() 是直接读 def 的。format_unit_def() 不先过一遍
# apply_star_stats()，四星棋子的技能说明就会显示三星数字。
func _case_detail_text_reads_star4() -> void:
	var probe: Dictionary = {}
	for row in _units():
		var d: Dictionary = row
		var block: Variant = d.get("star4", null)
		if typeof(block) != TYPE_DICTIONARY or (block as Dictionary).is_empty():
			continue
		probe = d
		break
	if probe.is_empty():
		_h.note("还没有任何单位带 star4 覆写，技能文案这条暂时无从验证")
		return
	var three := UnitDetailFormat.format_unit_def(probe, GameConstants.MAX_MERGE_STAR)
	var four := UnitDetailFormat.format_unit_def(probe, GameConstants.MAX_STAR)
	_h.expect(three != four, "detail_text_identical",
		"%s 的三星与四星详情文案一字不差 —— 技能说明没读四星数值" % str(probe.get("id", "?")))


# --- 7. star4 里的每个字段都必须真的被读 ------------------------------------------
# 这条是「死数据」探测器。
#
# 实测踩过：母灵的 death_threshold / boss_max_hp_damage / tier1_or_merc_chance 三个
# 字段填进 star4 之后完全没生效 —— 因为处决技能里那三个值是硬编码的（5.0 / 0.20 /
# 0.50），根本不读数据表。数值填了、检查绿了、玩家那边一点变化都没有，而且没有任何
# 报错。
#
# 判据是「这个键名在代码里出现过」。它挡不住「读了但用错」，但能挡住整类最隐蔽的
# 情形：字段名拼错、机制没接线、或者实现里写死了值。
func _case_star4_fields_are_read() -> void:
	var keys := {}
	for row in _units():
		var block: Variant = (row as Dictionary).get("star4", null)
		if typeof(block) != TYPE_DICTIONARY:
			continue
		for key in (block as Dictionary):
			keys[str(key)] = true
	if keys.is_empty():
		_h.note("没有任何 star4 字段可查")
		return
	var sources := _gd_sources("res://scripts") + _gd_sources("res://scenes")
	var haystack := ""
	for path in sources:
		haystack += FileAccess.get_file_as_string(path)
	for key in keys:
		if haystack.find('"%s"' % key) < 0:
			_h.fail("star4_field_never_read",
				"star4 里的 %s 在 scripts/ 与 scenes/ 里一次都没出现 —— 填了不生效的死数据"
					% key)
		else:
			_h.item()


func _gd_sources(root: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var path := root + "/" + name
		if dir.current_is_dir():
			if not name.begins_with("."):
				out += _gd_sources(path)
		elif name.ends_with(".gd"):
			out.append(path)
		name = dir.get_next()
	dir.list_dir_end()
	return out


# --- 8. 控制免疫两个来源都得管用 ---------------------------------------------------
# 天使的 control_immune_sec 与光之卫士的 shield_control_immune 都只在 4 星有。
# 免疫必须只挡控制（眩晕/沉默/打断），不能顺手把减防、中毒之类也挡掉 ——
# 那会让这两只顺带获得一堆没设计过的免疫。
func _case_control_immunity() -> void:
	# a. 没有免疫时照常被控
	var plain := {"def": {}, "statuses": {}}
	StatusEffectService.add_status(plain, "stun", 2.0)
	_h.expect(StatusEffectService.has_status(plain, "stun"), "control_blocked_without_immunity",
		"没有任何免疫来源的单位也被挡下了眩晕 —— 免疫判据写反了")

	# b. control_immune 状态（天使）
	var angel := {"def": {}, "statuses": {}}
	StatusEffectService.add_status(angel, "control_immune", 2.0)
	for kind in ["stun", "silence", "interrupt"]:
		StatusEffectService.add_status(angel, kind, 2.0)
		_h.expect(not StatusEffectService.has_status(angel, kind), "control_immune_leaks",
			"挂着 control_immune 还是被 %s 了" % kind)

	# c. 护盾免疫（光之卫士）：护盾在时免疫，护盾没了就不免疫
	var guard := {"def": {"shield_control_immune": true}, "statuses": {}, "shield": 100}
	StatusEffectService.add_status(guard, "stun", 2.0)
	_h.expect(not StatusEffectService.has_status(guard, "stun"), "shield_immunity_not_applied",
		"护盾还在（100）却被眩晕了 —— shield_control_immune 没生效")
	guard["shield"] = 0
	StatusEffectService.add_status(guard, "stun", 2.0)
	_h.expect(StatusEffectService.has_status(guard, "stun"), "shield_immunity_never_expires",
		"护盾已经打光了还在免疫控制 —— 免疫应当跟着护盾走")

	# d. 免疫不能溢出到非控制状态
	var immune := {"def": {}, "statuses": {}}
	StatusEffectService.add_status(immune, "control_immune", 2.0)
	for kind in ["defense_down", "poison", "attack_down"]:
		StatusEffectService.add_status(immune, kind, 2.0, {"pct": 0.1})
		_h.expect(StatusEffectService.has_status(immune, kind), "immunity_over_blocks",
			"控制免疫把 %s 也挡掉了 —— 那不是控制，会让这只单位白拿一堆免疫" % kind)


# --- 9. A 4-star override must move the value the right way ------------------
# The cap table (case 3) only asks "is it too strong". It says nothing about
# direction, so a 4-star value that is *weaker* than the 3-star one sails
# through. Two real regressions got in that way:
#
#   * human_king had max_stacks only inside star4, so 1-3 star kings grew with
#     no ceiling at all and overtook the capped 4-star one after ~10 rounds.
#   * undead_mother raised tier1_or_merc_chance, which silently pushed the
#     epic-execute tier from 15% down to 10% (case 10 covers that one).
#
# Fields are split by which way "better" points. Anything not listed is skipped
# rather than guessed at: a wrong entry here would be worse than no entry.
const HIGHER_IS_BETTER := [
	"heal_pct", "damage_atk_pct", "atk_bonus", "aspd_bonus", "cleanse_chance",
	"start_shield_pct", "taunt_radius", "true_damage_pct", "def_stack_pct",
	"damage_reduction", "duration", "max_hp_bonus_pct", "attack_down", "aspd_down",
	"fear_sec", "stun_sec", "silence_sec", "stack_damage", "clone_hp_pct",
	"clone_atk_def_pct", "def_down_pct", "dodge", "reflect_taken_damage_pct",
	"armor_per_hit_pct", "boss_max_hp_damage", "interrupt_chance", "combo_atk_pct",
	"pull_sec", "ally_def_duration", "ally_def_pct", "post_battle_all_stat_growth",
	"control_immune_sec", "double_element_chance", "link_regen_pct",
	"poison_pct_max_hp", "poison_duration",
]
const LOWER_IS_BETTER := ["skill_cd", "every", "death_threshold"]


func _case_star4_moves_in_the_right_direction() -> void:
	for row in _units():
		var d: Dictionary = row
		var block: Variant = d.get("star4", null)
		if typeof(block) != TYPE_DICTIONARY:
			continue
		var uid := str(d.get("id", "?"))
		for key in (block as Dictionary):
			if not d.has(key):
				continue   # new 4-star-only field, no baseline to compare against
			var base := float(d[key])
			var four := float((block as Dictionary)[key])
			if HIGHER_IS_BETTER.has(key) and four < base:
				_h.fail("star4_moved_backwards",
					"%s 的 4 星 %s 从 %s 降到了 %s —— 这个字段越大越好，4 星比 3 星弱"
						% [uid, key, str(base), str(four)])
			elif LOWER_IS_BETTER.has(key) and four > base:
				_h.fail("star4_moved_backwards",
					"%s 的 4 星 %s 从 %s 涨到了 %s —— 这个字段越小越好，4 星比 3 星弱"
						% [uid, key, str(base), str(four)])
			else:
				_h.item()


# --- 10. Ceilings must exist at every star, not just at 4 star ---------------
# unique_king_growth compounds every surviving round, so its stack ceiling is
# what keeps it finite. Putting the ceiling only in star4 does not just fail to
# cap the lower stars, it inverts the tiers: an uncapped 3-star king passes the
# capped 4-star one and never comes back.
func _case_growth_ceiling_exists_at_every_star() -> void:
	for row in _units():
		var d: Dictionary = row
		if str(d.get("skill_id", "")) != "unique_king_growth":
			continue
		var uid := str(d.get("id", "?"))
		if not _h.expect(d.has("max_stacks"), "growth_ceiling_missing",
				"%s 是复利成长单位，但 max_stacks 只在 star4 里 —— 1~3 星不封顶，"
					% uid
				+ "撑得够久就会反超 4 星"):
			continue
		var base_cap := int(d.get("max_stacks", 0))
		var block: Dictionary = d.get("star4", {})
		var four_cap := int(block.get("max_stacks", base_cap))
		_h.expect(four_cap >= base_cap, "growth_ceiling_inverted",
			"%s 的 4 星层数上限 %d 低于 3 星的 %d" % [uid, four_cap, base_cap])
		# A compounding stat with no ceiling at all is the failure this guards.
		_h.expect(base_cap > 0, "growth_ceiling_zero",
			"%s 的 max_stacks 是 %d —— 0 在 _grow_human_king 里等于不封顶" % [uid, base_cap])


# --- 11. The epic band must be explicit, and must not shrink at 4 star ------
#
# 9.14 反馈之前，unique_death_execute 只摇一次并把三段当成累积带：
# tier1 < t1、tier2 < t1+t2、**其余全算 tier3（史诗档）**。于是数据表里那个
# tier3_chance 是从未被读的死字段，1~3 星实测史诗率恒为 1-t1-t2（=15%），而文案
# 承诺的是 10%。母灵的 4★ 又抬高了 t1，把差额再从史诗档里抠走一段。
#
# 现在实现改成**三档各自读数据表**（BattleSimTreasures._mother_execute_on）：
# 史诗档就是 tier3_chance 本身，落在 t1+t2+t3 之外的那一段是设计文档 §3 的「空档」。
# 所以这条检查也换契约：史诗档直接读 tier3_chance，并守住两件事 ——
#   1. 4★ 的史诗档不得低于 1~3★（处决史诗是这个技能的最高价值输出）；
#   2. 三档之和不得超过 100%（超过会把最后一段压成负长度）。
func _case_execute_epic_band_not_reduced() -> void:
	for row in _units():
		var d: Dictionary = row
		if str(d.get("skill_id", "")) != "unique_death_execute":
			continue
		var uid := str(d.get("id", "?"))
		var block: Dictionary = d.get("star4", {})
		var base_epic := float(d.get("tier3_chance", 0.10))
		var four_epic := float(block.get("tier3_chance", base_epic))
		_h.expect(four_epic >= base_epic - 0.0001, "execute_epic_band_reduced",
			"%s 的 4 星处决史诗概率从 %.0f%% 降到 %.0f%% —— 处决史诗是这个技能的最高价值输出"
				% [uid, base_epic * 100.0, four_epic * 100.0])
		for star_label in [["1~3★", d], ["4★", block]]:
			var label: String = star_label[0]
			var src: Dictionary = star_label[1]
			if src.is_empty():
				src = d
			var total := float(src.get("tier1_or_merc_chance", d.get("tier1_or_merc_chance", 0.50))) \
				+ float(src.get("tier2_chance", d.get("tier2_chance", 0.35))) \
				+ float(src.get("tier3_chance", d.get("tier3_chance", 0.10)))
			_h.expect(total <= 1.0 + 0.0001, "execute_bands_overflow",
				"%s 的 %s 三档概率之和 %.2f 超过 100%%，最后一段会被压成负长度"
					% [uid, label, total])


# --- 12. Toxic Armor must scale with the wearer's own defense ----------------
# The armour gained per hit used to be a flat number from the data table. A flat
# +3 is x2.4 of a 1-star titan's base defense but only x1.8 of a 4-star one, so
# the higher the star the *less* the skill was worth in relative terms -- the
# case docs/四星技能与数值设计规格.md §2 rules out ("绝对值一律改成百分比").
#
# determinism_check does NOT cover this: its fixture lists undead_titan, but
# setting armor_per_hit_pct to 5.0 (a 3-star titan gaining +315 per hit) leaves
# every replay hash untouched, so that path is never exercised there. This case
# is the only automated evidence the skill works at all.
func _case_titan_armor_scales_with_star() -> void:
	var titan: Dictionary = {}
	for row in _units():
		if str((row as Dictionary).get("skill_id", "")) == "poison_reflect_armor_stack":
			titan = row
			break
	if titan.is_empty():
		_h.note("没有 poison_reflect_armor_stack 单位，跳过")
		return

	var gained := {}
	for star in [1, GameConstants.MAX_MERGE_STAR, GameConstants.MAX_STAR]:
		var scaled := UnitFactory.apply_star_stats(titan, star)
		var target := _fighter(scaled)
		var attacker := _fighter(UnitFactory.apply_star_stats(titan, 1))
		attacker["uid"] = "atk"
		var before := int(target.get("defense", 0))
		BattleSimTreasures._apply_defender_reaction(attacker, target, 100)
		gained[star] = int(target.get("defense", 0)) - before
		if gained[star] <= 0:
			_h.fail("titan_armor_not_applied",
				"%d 星毒甲被打了一下，防御一点没涨 —— 技能没接上" % star)
			return
		_h.item()

	# Relative worth must hold across stars: that is the whole point of moving
	# off an absolute value.
	var one := float(gained[1]) / float(int(UnitFactory.apply_star_stats(titan, 1).get("def", 1)))
	var four := float(gained[GameConstants.MAX_STAR]) \
		/ float(int(UnitFactory.apply_star_stats(titan, GameConstants.MAX_STAR).get("def", 1)))
	_h.expect(four >= one - 0.01, "titan_armor_worth_less_at_high_star",
		"毒甲每次加的护甲：1 星是自身防御的 %.0f%%，4 星只有 %.0f%% —— 绝对值不随星级缩放的老毛病"
			% [one * 100.0, four * 100.0])
	_h.expect(gained[GameConstants.MAX_STAR] > gained[GameConstants.MAX_MERGE_STAR],
		"titan_armor_flat_across_stars",
		"毒甲 4 星每次加 %d 点，3 星加 %d 点 —— 没有随星级变强"
			% [int(gained[GameConstants.MAX_STAR]), int(gained[GameConstants.MAX_MERGE_STAR])])
	_h.note("毒甲每次加护甲：1星 %d / 3星 %d / 4星 %d" % [
		int(gained[1]), int(gained[GameConstants.MAX_MERGE_STAR]),
		int(gained[GameConstants.MAX_STAR])])


# Minimal fighter shaped like BattleSimShared._fighter_from_def builds them.
func _fighter(scaled_def: Dictionary) -> Dictionary:
	var hp := int(scaled_def.get("hp", 1000))
	return {
		"uid": "probe", "id": str(scaled_def.get("id", "")), "team": "player",
		"def": scaled_def, "star": int(scaled_def.get("star", 1)),
		"hp": hp, "max_hp": hp, "atk": int(scaled_def.get("atk", 1)),
		"defense": int(scaled_def.get("def", 0)), "alive": true,
		"shield": 0, "skill_stacks": 0, "statuses": {},
	}
