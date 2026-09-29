extends Node

# 门禁：离线自测「实时数值面板」的攻速 / 防御 / 暴击口径（officetest/OfficeTestScreen.gd）。
#
# ## 9.29 bug 文档第 3 条（这条门禁就是为它写的）
#
# 玩家反馈：离线自测战斗里点棋子弹出的面板，「攻击 / 攻速」等属性**未实时同步**。
#
# ## 根因（分两轮，第二轮是订正）
#
# **第一轮**：面板（_refresh_stat_panel）原来对攻速/防御/暴击读的是**星级缩放后的 def
# 基准值**，不随 buff 变。当时的理由「回放帧只记录 13 列位置元组」说的是**联机回放**；
# 离线自测跑的是本地实时模拟（OfficeTestSim.build_test_state + step_state），
# _frame_fighter_by_id 里存的就是**活的 fighter 字典本身**。于是改成「读活字段」。
#
# **第二轮（用户复报「攻速还是没更新」）**：第一轮只做到「读活字段」，但战斗真正用的
# 攻速**不是裸字段**（BattleSimulator.gd:730）：
#     aspd = clamp(f.attack_speed * StatusEffectService.attack_speed_multiplier(f)
#                                 * _dynamic_attack_speed_multiplier(f), 0.25, 2.5)
# speed_bonus / slow / frenzy_stacks / blood_rampage **全都只活在乘数里，不写回
# f.attack_speed**。所以「读裸值」恒等于基准值 —— 截图里「状态：攻速提升 1.1秒」
# 在生效、面板攻速却纹丝不动，就是这个。
# ★ 口径铁律：**面板必须调用战斗同一个函数**，不许自己再拼一遍公式。拼一遍就会漏项，
#   漏的就是 speed_bonus / frenzy / blood_rampage，也就是这次复发的直接原因。
#
# ## 这条门禁验什么（行为 + 结构）
#
#   行为 A（第一轮）：live 字段优先于 def 基准值。
#   行为 B（第一轮）：缺 live 字段 / def 类型异常时兜底，不许崩。
#   行为 C（第二轮）：**speed_bonus / slow / frenzy_stacks / blood_rampage 必须进面板**，
#                     且数值与战斗式子逐位相同 —— 这是复发的正面判据。
#   行为 D（第二轮）：防御走 DamageService.effective_defense（含 flat_up / flat_down / 乘数）。
#   行为 E（第二轮）：暴击 = def.crit + crit_bonus，人类的「每3下一暴」显示 100%。
#   结构 F：_refresh_stat_panel 三行必须调 live_*，且**不许**内联拼乘数公式。
#   结构 G：射程仍读 def（战斗过程不改它），别当漏网之鱼一起改。
#
# ## 跑
#   godot --headless --path <项目> tools/officetest_stat_panel_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
# 只 preload 脚本、不实例化（OfficeTestScreen 继承重型战斗场景，headless new() 会挂死）。
const ScreenScript := preload("res://officetest/OfficeTestScreen.gd")
const SimScript := preload("res://scripts/battle/BattleSimulator.gd")
const EffectScript := preload("res://scripts/battle/StatusEffectService.gd")
const DamageScript := preload("res://scripts/battle/DamageService.gd")

const CHECK_NAME := "officetest_stat_panel"
const SCREEN_PATH := "res://officetest/OfficeTestScreen.gd"

# 体检下界：本文件所有用例的 expect 数之和（写少一个就等于漏跑一整段）。
const MIN_EXPECTS := 40

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_live_wins_over_base()
	_case_def_fallback()
	_case_crit_includes_bonus()
	_case_attack_speed_matches_battle_formula()
	_case_defense_matches_effective_defense()
	_case_crit_matches_hit_judgement()
	_case_panel_reads_live_fields()
	_case_range_still_from_def()
	_case_all_cases_executed()
	_h.finish(get_tree())


# 一具「基准 fighter」：炎阳王者 merc_leo_sun 的真实数值（用户截图里那只）。
# 用它当夹具，是为了让判据落在真实数据上，而不是编出来的数字。
func _leo() -> Dictionary:
	return {
		"uid": "leo", "name": "炎阳王者",
		"hp": 1678, "max_hp": 1734, "atk": 74, "defense": 11,
		"attack_speed": 0.95, "base_attack_speed": 0.95,
		"crit_bonus": 0.0, "attack_count": 2, "statuses": {}, "frenzy_stacks": 0,
		"def": {"attack_speed": 0.95, "crit": 0.05, "crit_dmg": 1.5,
			"def": 11, "range": 1, "skill_id": "king_aura", "race": ""},
	}


# 组一组「base 与 live 不一致」的 fighter：live 必须赢（第一轮判据）。
func _fighter_live_ahead() -> Dictionary:
	return {
		"attack_speed": 1.85, "defense": 9, "crit_bonus": 0.20, "statuses": {},
		"def": {"attack_speed": 1.0, "def": 3, "crit": 0.05},
	}


# 「战斗真正用的攻速」—— 独立复刻 BattleSimulator.gd:730 那一行，用来当对照组。
# 这不是抄实现：它就是被判对象要复现的那个式子，写在这里是刻意的「第二实现」。
func _battle_aspd(f: Dictionary) -> float:
	return clampf(float(f.attack_speed) * EffectScript.attack_speed_multiplier(f)
		* SimScript._dynamic_attack_speed_multiplier(f), 0.25, 2.5)


# --- 1. live 优先（第一轮） -------------------------------------------------------

func _case_live_wins_over_base() -> void:
	var f := _fighter_live_ahead()
	var as_val := ScreenScript.base_attack_speed(f)
	_h.expect(is_equal_approx(as_val, 1.85), "as_reads_base_not_live",
		"攻速读的是 def 基准值而不是活 fighter 的实时值：得到 %s，期望 1.85" % str(as_val))
	var def_val := ScreenScript.live_defense(f)
	_h.expect(def_val == 9, "defense_reads_base_not_live",
		"防御读的是 def 基准值而不是实时值：得到 %d，期望 9" % def_val)
	var crit_val := ScreenScript.live_crit(f)
	_h.expect(is_equal_approx(crit_val, 0.25), "crit_missing_bonus",
		"暴击没算上 crit_bonus：得到 %s，期望 0.25（0.05 基础 + 0.20 增益）" % str(crit_val))


# --- 2. 兜底 -------------------------------------------------------------------

func _case_def_fallback() -> void:
	# 没有 live 字段（旧数据 / 识别不到）：退回 def。
	var g := {"def": {"attack_speed": 1.2, "def": 5, "crit": 0.10}, "statuses": {}}
	_h.expect(is_equal_approx(ScreenScript.base_attack_speed(g), 1.2), "as_fallback_broken",
		"攻速缺 live 字段时没兜底到 def.attack_speed")
	_h.expect(ScreenScript.live_defense(g) == 5, "defense_fallback_broken",
		"防御缺 live 字段时没兜底到 def.def")
	_h.expect(is_equal_approx(ScreenScript.live_crit(g), 0.10), "crit_fallback_broken",
		"暴击缺 crit_bonus 时应等于 def.crit")
	# 无状态、无 frenzy 时，面板攻速必须等于裸基准值（不能被乘数改坏）。
	_h.expect(is_equal_approx(ScreenScript.live_attack_speed(g), 1.2), "as_clean_multiplied",
		"没有任何 buff 时攻速被改了：得到 %s，期望 1.2" % str(ScreenScript.live_attack_speed(g)))
	# 连 def 都没有：不许崩，给中性默认。
	var empty := {"statuses": {}}
	_h.expect(is_equal_approx(ScreenScript.base_attack_speed(empty), 1.0), "as_empty_default",
		"空 fighter 的攻速兜底不是 1.0")
	_h.expect(ScreenScript.live_defense(empty) == 0, "defense_empty_default",
		"空 fighter 的防御兜底不是 0")
	_h.expect(is_equal_approx(ScreenScript.live_crit(empty), 0.0), "crit_empty_default",
		"空 fighter 的暴击兜底不是 0")
	# def 是错的类型（不是字典）：也不许崩。
	var bad := {"def": "not_a_dict", "attack_speed": 2.0, "statuses": {}}
	_h.expect(is_equal_approx(ScreenScript.base_attack_speed(bad), 2.0), "as_bad_def_type",
		"def 类型异常时应仍读 live 值")
	_h.expect(is_equal_approx(ScreenScript.live_crit(bad), 0.0), "crit_bad_def_type",
		"def 类型异常时暴击应兜底 0")


# --- 3. 暴击 = base + bonus ------------------------------------------------------

func _case_crit_includes_bonus() -> void:
	# 纯增益：base=0，bonus=0.35 → 0.35（人王/集结等只会加 crit_bonus）。
	var f := {"crit_bonus": 0.35, "def": {"crit": 0.0}, "statuses": {}}
	_h.expect(is_equal_approx(ScreenScript.live_crit(f), 0.35), "crit_bonus_only",
		"只带 crit_bonus 时应显示 bonus 本身")
	# 纯基础：无 bonus → base。
	var g := {"def": {"crit": 0.12}, "statuses": {}}
	_h.expect(is_equal_approx(ScreenScript.live_crit(g), 0.12), "crit_base_only",
		"无 crit_bonus 时应等于 base crit")


# --- 4. ★★ 第二轮核心：攻速必须与战斗式子逐位相同 --------------------------------

func _case_attack_speed_matches_battle_formula() -> void:
	# ① 裸身：面板 == 基准值 == 战斗式子（截图里那个 0.95）。
	var bare := _leo()
	var bare_panel := ScreenScript.live_attack_speed(bare)
	_h.expect(is_equal_approx(bare_panel, 0.95), "bare_as_not_base",
		"无 buff 时面板攻速应为 0.95，得到 %s" % str(bare_panel))
	_h.expect(is_equal_approx(bare_panel, _battle_aspd(bare)), "bare_as_mismatch",
		"无 buff 时面板与战斗式子不一致")

	# ② ★ 用户截图那条：「状态：攻速提升 1.1秒」= speed_bonus(king_aura 的 0.25)。
	#    这正是「面板不动」的现场。必须反映出来，且与战斗式子逐位相同。
	var f := _leo()
	EffectScript.add_status(f, "speed_bonus", 1.1, {"pct": 0.25})
	var panel := ScreenScript.live_attack_speed(f)
	var battle := _battle_aspd(f)
	_h.expect(not is_equal_approx(panel, 0.95), "speed_bonus_ignored",
		"★ 吃了 speed_bonus 后面板攻速还是基准值 0.95 —— 「面板不实时」复发")
	_h.expect(is_equal_approx(panel, battle), "speed_bonus_mismatch",
		"speed_bonus 生效时面板 %s 与战斗 %s 不一致" % [str(panel), str(battle)])
	_h.expect(panel > 0.95, "speed_bonus_direction",
		"攻速提升应让面板数字变大，实际 %s" % str(panel))

	# ③ 减速：面板必须变小（不能只有增益才算）。
	var s := _leo()
	EffectScript.add_status(s, "slow", 3.0, {"attack_speed_pct": 0.35, "move_pct": 0.35})
	_h.expect(ScreenScript.live_attack_speed(s) < 0.95, "slow_ignored",
		"被减速后面板攻速没变小 —— 只算了增益漏了减益")
	_h.expect(is_equal_approx(ScreenScript.live_attack_speed(s), _battle_aspd(s)),
		"slow_mismatch", "减速时面板与战斗式子不一致")

	# ④ 狂暴层数 frenzy_stacks = pow(1.15, n)，纯乘数、不写回字段。
	var z := _leo()
	z["frenzy_stacks"] = 3
	_h.expect(not is_equal_approx(ScreenScript.live_attack_speed(z), 0.95), "frenzy_ignored",
		"★ frenzy_stacks 没进面板攻速 —— 又一个只有乘数里的项")
	_h.expect(is_equal_approx(ScreenScript.live_attack_speed(z), _battle_aspd(z)),
		"frenzy_mismatch", "frenzy_stacks 生效时面板与战斗式子不一致")

	# ⑤ blood_rampage 残血动态乘数（由 hp 推导，连状态都没有）。
	var b := _leo()
	b["def"]["skill_id"] = "blood_rampage"
	b["def"]["hp_step"] = 0.10
	b["def"]["aspd_per_step"] = 0.10
	b["hp"] = 1000
	_h.expect(not is_equal_approx(ScreenScript.live_attack_speed(b), 0.95), "blood_rampage_ignored",
		"★ blood_rampage 动态乘数没进面板攻速")
	_h.expect(is_equal_approx(ScreenScript.live_attack_speed(b), _battle_aspd(b)),
		"blood_rampage_mismatch", "blood_rampage 生效时面板与战斗式子不一致")

	# ⑥ 上界：战斗式子夹在 [0.25, 2.5]，面板必须同夹（别显示 9.9 这种数）。
	var huge := _leo()
	huge["frenzy_stacks"] = 40
	_h.expect(ScreenScript.live_attack_speed(huge) <= 2.5, "as_upper_clamp",
		"面板攻速没按战斗口径夹上界 2.5，得到 %s" % str(ScreenScript.live_attack_speed(huge)))


# --- 5. 防御走 effective_defense ------------------------------------------------

func _case_defense_matches_effective_defense() -> void:
	# 削防 30% → 战斗承伤用的就是 effective_defense。
	var f := _leo()
	EffectScript.add_status(f, "defense_down", 4.0, {"pct": 0.30})
	var panel := ScreenScript.live_defense(f)
	_h.expect(panel < 11, "defense_down_ignored",
		"被削防后面板防御没变小，得到 %d" % panel)
	_h.expect(panel == DamageScript.effective_defense(f), "defense_down_mismatch",
		"削防时面板防御与 effective_defense 不一致")
	# 固定加防。
	var g := _leo()
	EffectScript.add_status(g, "defense_flat_up", 4.0, {"amount": 10})
	_h.expect(ScreenScript.live_defense(g) > 11, "defense_flat_up_ignored",
		"固定加防后面板防御没变大，得到 %d" % ScreenScript.live_defense(g))
	_h.expect(ScreenScript.live_defense(g) == DamageScript.effective_defense(g),
		"defense_flat_up_mismatch", "固定加防时面板与 effective_defense 不一致")
	# 无 buff：等于活字段本身。
	_h.expect(ScreenScript.live_defense(_leo()) == 11, "defense_bare_changed",
		"无 buff 时面板防御应等于 11")


# --- 6. 暴击与命中判定同源 ------------------------------------------------------

func _case_crit_matches_hit_judgement() -> void:
	# 人类「每 3 下一暴」是**确定性必暴**，不是概率 —— 面板要如实显示 100%。
	var f := _leo()
	f["def"]["race"] = "human"
	f["attack_count"] = 2  # 下一击是第 3 下
	_h.expect(is_equal_approx(ScreenScript.live_crit(f), 1.0), "human_combo_not_certain",
		"人类第 3 下必暴，面板应显示 100%%，得到 %s" % str(ScreenScript.live_crit(f)))
	# 非必暴回合：回到 base + bonus。
	var g := _leo()
	g["def"]["race"] = "human"
	g["attack_count"] = 1
	_h.expect(is_equal_approx(ScreenScript.live_crit(g), 0.05), "human_combo_off_by_one",
		"非必暴回合面板暴击应回到基准 5%%，实际应为 0.05，得到 %s" % str(ScreenScript.live_crit(g)))
	# 概率部分被封顶在 1.0（别显示 130%）。
	var h := _leo()
	h["crit_bonus"] = 1.20
	_h.expect(ScreenScript.live_crit(h) <= 1.0, "crit_not_clamped",
		"暴击没夹上界 1.0，得到 %s" % str(ScreenScript.live_crit(h)))


# --- 7. 结构：面板那三行不许再读 def 基准值、不许内联拼公式 -----------------------

# 精确切出 `_refresh_stat_panel` 的函数体。
# ★ 两个坑：
#   ① 不能图省事写成 `.split("\nfunc ")[0]` —— 新加的 live_* 函数紧跟在它后面，
#      那样会把它们的正文一起切进来，「内联乘数」判据就会命中**实现本体**而非面板。
#   ② 紧随其后的那几个是 **`static func`**，行首是 `\nstatic func ` 而**不是**
#      `\nfunc ` —— 只按 `\nfunc ` 切根本截不断，会一路吃到下一个非 static 函数。
#      这是记忆里「`contains` 必须限作用域」那坑的变体：锚点本身选错了。
func _refresh_stat_panel_body() -> String:
	var src := _code(SCREEN_PATH)
	var head := src.split("func _refresh_stat_panel(")
	if head.size() < 2:
		return ""
	var tail := head[1]
	for sep in ["\nfunc ", "\nstatic func ", "\n# ---"]:
		tail = tail.split(sep)[0]
	return tail


func _case_panel_reads_live_fields() -> void:
	var body := _refresh_stat_panel_body()
	_h.expect(not body.is_empty(), "panel_body_not_found",
		"没切出 _refresh_stat_panel 的函数体（切片锚点失效）")
	# 攻速/防御/暴击三行必须走 live_* 纯函数。
	for fn in ["live_attack_speed(", "live_defense(", "live_crit("]:
		_h.expect(body.contains(fn), "panel_missing_live_call",
			"_refresh_stat_panel 没调用 %s —— 攻速/防御/暴击没接到实时值" % fn)
	# 不许再直接读这三项 def 基准值（bug 的原始写法）。
	for bad in ['def.get("attack_speed"', 'def.get("crit"', 'def.get("def"']:
		_h.expect(not body.contains(bad), "panel_reads_def_base",
			"_refresh_stat_panel 里还有 %s —— 那是静态基准值，不实时（bug 复发）" % bad)
	# ★★ 不许在面板里**内联拼乘数公式** —— 口径必须单点（live_attack_speed 内部）。
	#    拼在面板里就会只拼一部分，这正是第二轮复发的形态。
	for inline_bad in ["attack_speed_multiplier(", "_dynamic_attack_speed_multiplier("]:
		_h.expect(not body.contains(inline_bad), "panel_inlines_multiplier",
			"★ _refresh_stat_panel 里内联了 %s —— 口径必须走 live_attack_speed，"
			% inline_bad + "内联就会漏项（这就是第二轮复发的原因）")


# --- 8. 射程仍来自 def -----------------------------------------------------------

func _case_range_still_from_def() -> void:
	# 射程没有战斗中的修改机制，保持 def 基准值；别当漏网之鱼乱改。
	var body := _refresh_stat_panel_body()
	_h.expect(body.contains('def.get("range"'), "range_no_longer_from_def",
		"射程应仍取自 def.range（战斗不修改它）")


# --- 9. 体检：确认所有用例真的跑了 ------------------------------------------------
#
# ★ 本轮教训：`_ready` 里若把某个 `_case_x()` 漏成不 await（或函数体在挂起点返回），
#   那个用例的断言**一条都不跑**，门禁照样打印 PASS。所以加一条下界断言兜底。

func _case_all_cases_executed() -> void:
	_h.expect(_h.checked_count() >= MIN_EXPECTS, "cases_not_executed",
		"用例没跑全：已执行 %d 条断言，下界 %d（有用例在挂起点返回/漏调用）"
		% [_h.checked_count(), MIN_EXPECTS])


# --- 小工具 ---------------------------------------------------------------------

func _code(path: String) -> String:
	var kept: Array[String] = []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if not str(line).strip_edges().begins_with("#"):
			kept.append(str(line))
	return "\n".join(kept)
