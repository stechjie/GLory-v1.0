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
# 另外守两条机制：
#   * star4 的值在 4 星时确实生效（apply_star_stats 是唯一解析点）
#   * star4 的值**不会**泄漏到 1~3 星，且 def 上不残留 star4 键
#     —— 残留就意味着任何直接读 def 的地方（尤其是玩家看得到的技能文案）
#     可能拿到第二份数值真相
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/four_star_values_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

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
	_case_star4_does_not_leak_to_three()
	_case_caps_respected()
	_case_cooldown_only_shortens()
	_case_defense_shred_capped()
	_case_detail_text_reads_star4()
	_case_star4_fields_are_read()
	_case_control_immunity()
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
