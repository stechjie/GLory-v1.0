class_name UnitDetailFormat
extends RefCounted
# 单位详情 / 技能文案格式化（纯静态，无实例状态）。
# 原本只存在于备战链（PrepDetails），但战斗链（BattleScreen -> officetest）继承不到，
# 于是抽到这里两边共用：PrepDetails 保留原方法名改为薄委托，officetest 直接调用。
# 只依赖参数 + 全局单例（LocaleManager / GameState / RaceRelationService）。

const UnitGrowth := preload("res://scripts/units/UnitGrowth.gd")

static func is_en() -> bool:
	return LocaleManager.get_locale() == "en"

static func localized_name(d: Dictionary) -> String:
	return DataRegistry.unit_display_name(d, is_en())


# 「棋盘唯一」标记。unique_on_board 的棋子实测只能上场一只，但图鉴与棋子描述都没写，
# 玩家只能靠试放才发现（9.13 测试反馈）。统一渲染成「名称 N星（唯一）」，图鉴与详情
# 共用这一份文案。
#
# ★ 这份名单**不是**手写的判据，只是给后来的人一眼看清范围：判据永远是
# `def.unique_on_board`，上面这句注释不参与任何判断。10.15 的反馈（穿云弩手是 T3
# 却漏标、能上两只）就是栽在"逐单位手写清单"上 —— 所以全表 tier 3 与带该字段的
# 集合**必须一一对应**，门禁 `_qa_t3unique/check.tscn` 正反两个方向都钉住这一点。
# 当前 tier 3 共 8 枚，全部唯一：大天使 god_archangel / 神王 god_king / 末日守卫
# dark_doom / 黑龙 dark_dragon / 母灵 undead_mother / 人王 human_king /
# 赤灯使 lattern / 穿云弩手 skypierce。
static func unique_suffix(d: Dictionary) -> String:
	if not bool(d.get("unique_on_board", false)):
		return ""
	return " (Unique)" if is_en() else "（唯一）"

static func purchase_price_text(d: Dictionary) -> String:
	# 9.25：教学也用萝卜雇佣兵，佣兵详情统一按萝卜标价。
	if d.has("carrot_cost"):
		return ("%d carrots" if is_en() else "%d萝卜") % int(d.get("carrot_cost", 0))
	return ("%d G" if is_en() else "%d金") % int(d.get("cost", 0))

# 棋子自己的成长倍率（人王活过的场数、老虎层数，见 UnitGrowth）。cell 为空（商店卡、图鉴）= 1。
# 老虎按**本机**出战宠物算 —— 只给自己的棋盘 / 待命区用；层数按升星次数截，联机时那个次数跟
# 服务器账本走（NetworkService._apply_carrot_state），所以这里的数就是实战里乘上去的数。
static func growth_multiplier(cell: Dictionary) -> float:
	if cell.is_empty():
		return 1.0
	return UnitGrowth.stat_multiplier(cell, _local_tiger_rate(), GameState.tiger_starup_count)


static func _local_tiger_rate() -> float:
	return PetService.tier1_growth_rate(PlayerProfile.get_active())


# 摆放界面上「这枚棋子现在的生命 / 攻击 / 防御」：按星级缩放 + 自己的成长。
# 战斗里还会再乘种族关系、宝物、羁绊（这些详情里另有一段写）。
static func grown_def(d: Dictionary, star: int, cell: Dictionary = {}) -> Dictionary:
	if bool(d.get("is_mercenary", false)):
		return d.duplicate(true)
	var out := UnitFactory.apply_star_stats(d, star)
	UnitGrowth.apply_to_def(out, growth_multiplier(cell))
	UnitGrowth.apply_king_attack_speed_to_def(out, cell)
	return out


# 成长那几行（人王层数 / 老虎层数）。star 用详情里显示的星级 —— 四星预览时上限按四星算。
static func format_growth_detail(cell: Dictionary, star: int) -> String:
	if cell.is_empty():
		return ""
	var probe := cell.duplicate()
	probe["star"] = star
	var lines: Array[String] = []
	if UnitGrowth.is_king(probe):
		var stacks := UnitGrowth.king_stacks(probe)
		var cap := UnitGrowth.king_cap(probe)
		var layers := ("%d/%d" % [stacks, cap]) if cap > 0 else str(stacks)
		if is_en():
			lines.append("King growth: %s stacks (HP/ATK/DEF/AS ×%.2f; AS cap 2.5/s)" % [layers, UnitGrowth.king_mult(probe)])
		else:
			lines.append("人王成长：%s 层（生命、攻击、防御、攻速 ×%.2f；攻速上限 2.5 次/秒）" % [layers, UnitGrowth.king_mult(probe)])
	var rate := _local_tiger_rate()
	if rate > 0.0 and UnitGrowth.tiger_eligible(probe):
		var tiger := mini(UnitGrowth.tiger_stacks(probe), GameState.tiger_starup_count)
		var pct_text := int(round(rate * float(tiger) * 100.0))
		if is_en():
			lines.append("Tiger growth: HP/ATK/DEF +%d%% (%d stacks)" % [pct_text, tiger])
		else:
			lines.append("老虎成长：生命、攻击、防御 +%d%%（%d 层）" % [pct_text, tiger])
	return "\n".join(lines)


static func format_unit_def(d: Dictionary, star: int = 1, cell: Dictionary = {}) -> String:
	if d.is_empty():
		return "No details" if is_en() else "无详情"
	# 生命 / 攻击 / 防御显示**成长之后**的数（人王、老虎），和战斗里乘的同一份（UnitGrowth）。
	var shown := grown_def(d, star, cell)
	var growth_text := format_growth_detail(cell, star)
	if not growth_text.is_empty():
		growth_text = "\n" + growth_text
	var uname := localized_name(d)
	var uniq := unique_suffix(d)
	var race := unit_race_name(str(d.get("race", "-")))
	var elem := unit_element_name(str(d.get("element", "-")))
	# 技能文案必须读**按星级缩放后**的 def：4 星的技能数值在 `star4` 子对象里，
	# 而 format_skill_detail() 是直接 d.get(key, 默认值) 的。不先过一遍
	# apply_star_stats()，四星棋子的技能说明会显示三星的数字 —— 那是第二份
	# 数值真相，而且是玩家唯一看得到的那一份。
	var skill_def := UnitFactory.apply_star_stats(d, star) if not bool(d.get("is_mercenary", false)) else d
	var skill_text := format_skill_detail(skill_def)
	var detail: String
	if is_en():
		detail = "%s ★%d%s\nRace: %s  Element: %s  Tier: %d  Cost: %s\nHP: %d  ATK: %d  DEF: %d  MR: %d\nAS: %.2f  Crit: %.0f%%  CritDmg: %.0f%%\nRange: %s  Speed: %s%s\n\n[b]Skill[/b]\n%s" % [
			uname, star, uniq,
			race, elem, int(d.get("tier", 0)), purchase_price_text(d),
			int(shown.get("hp", 0)), int(shown.get("atk", 0)), int(shown.get("def", 0)), int(shown.get("mres", shown.get("def", 0))),
			float(shown.get("attack_speed", 1.0)), float(d.get("crit", 0.0)) * 100.0, float(d.get("crit_dmg", 1.5)) * 100.0,
			str(d.get("range", 1)), str(d.get("move_speed", 3.0)), growth_text, skill_text,
		]
	else:
		detail = "%s %d星%s\n种族：%s  属性：%s  阶级：%d  价格：%s\n生命：%d  攻击：%d  防御：%d  魔抗：%d\n攻速：%.2f  暴击：%.0f%%  暴伤：%.0f%%\n射程：%s  移速：%s%s\n\n[b]技能效果[/b]\n%s" % [
			uname, star, uniq,
			race, elem, int(d.get("tier", 0)), purchase_price_text(d),
			int(shown.get("hp", 0)), int(shown.get("atk", 0)), int(shown.get("def", 0)), int(shown.get("mres", shown.get("def", 0))),
			float(shown.get("attack_speed", 1.0)), float(d.get("crit", 0.0)) * 100.0, float(d.get("crit_dmg", 1.5)) * 100.0,
			str(d.get("range", 1)), str(d.get("move_speed", 3.0)), growth_text, skill_text,
		]
	var relation_detail := format_unit_relation_detail(cell, str(d.get("race", "")))
	if not relation_detail.is_empty():
		if is_en():
			detail += "\n\n[b]Race Relations[/b]\n%s" % relation_detail
		else:
			detail += "\n\n[b]种族关系[/b]\n%s" % relation_detail
	return detail

static func format_unit_relation_detail(cell: Dictionary, unit_race: String) -> String:
	if cell.is_empty():
		return ""
	var lines: Array[String] = []
	for state_value in RaceRelationService.visual_states_for_cell(cell):
		if typeof(state_value) != TYPE_DICTIONARY:
			continue
		var state: Dictionary = state_value
		var pair := str(state.get("pair", ""))
		var parts := pair.split("|")
		if parts.size() != 2:
			continue
		var other_race := str(parts[1]) if str(parts[0]) == unit_race else str(parts[0])
		if other_race == unit_race:
			continue
		var progress := clampi(int(state.get("progress", 0)), 1, RaceRelationService.MAX_PROGRESS)
		var active := bool(state.get("active", false))
		var percent := 33 if progress == 1 else 67 if progress == 2 else 100
		var kind_str := str(state.get("kind", ""))
		if is_en():
			var rel := "Friendly" if kind_str == "friendly" else "Hostile"
			var stage := "Active" if active else "" if progress >= 3 else "Stage %d" % progress
			lines.append("vs %s — %s: %d%% (%s)" % [unit_race_name(other_race), rel, percent, stage])
			if active:
				lines.append("HP/ATK/DEF %s15%%" % ["+" if kind_str == "friendly" else "-"])
		else:
			var rel := "友好" if kind_str == "friendly" else "敌对"
			var stage := "已生效" if active else "" if progress >= 3 else "第%d阶" % progress
			lines.append("与%s族%s：%d%%（%s）" % [unit_race_name(other_race), rel, percent, stage])
			if active:
				lines.append("生命、攻击、防御 %s15%%" % ["+" if rel == "友好" else "-"])
	return "\n".join(lines)

static func unit_race_name(race: String) -> String:
	if is_en():
		match race:
			"god":       return "God"
			"dark":      return "Dark"
			"undead":    return "Undead"
			"human":     return "Human"
			"crimson":   return "Crimson"
			"mercenary": return "Mercenary"
			"-", "":     return "None"
		return "Unknown"
	match race:
		"god":       return "神"
		"dark":      return "暗"
		"undead":    return "灵"
		"human":     return "人"
		"crimson":   return "赤律"
		"mercenary": return "佣兵"
		"-", "":     return "无"
	return "未知"

static func unit_element_name(element: String) -> String:
	if is_en():
		match element:
			"fire":    return "Fire"
			"ice":     return "Ice"
			"thunder": return "Thunder"
			"poison":  return "Poison"
			"sky":     return "Sky"
			"land":    return "Land"
			"ren":     return "Human"
			"-", "":   return "None"
		return "Unknown"
	match element:
		"fire":    return "火"
		"ice":     return "冰"
		"thunder": return "雷"
		"poison":  return "毒"
		"sky":     return "天"
		"land":    return "地"
		"ren":     return "人"
		"-", "":   return "无"
	return "未知"

static func format_skill_detail(d: Dictionary) -> String:
	if is_en():
		return format_skill_detail_en(d)
	var approved := FinalStatusCatalog.unit_skill_cn(str(d.get("id", "")), int(d.get("star", 1)))
	if not approved.is_empty():
		return approved
	return format_skill_template_cn(d)


# 代码里的中文模板（不读数值总表）。棋子的中文以 Excel「02_棋子技能」G/M 列为准，这里是兜底；
# 11.05 起两边是同一套短句：一句话写「触发 → 效果 → 数值」，通用规则（Boss 减半、分路、
# 伤害类型、按开战值计算等）不写进单个技能。Excel 的 G/M 列就是用本函数生成后写回去的。
static func format_skill_template_cn(d: Dictionary) -> String:
	var sid := str(d.get("skill_id", "none"))
	var cd := skill_cd_text(d)
	match sid:
		"block_guard":
			return "赤卫格挡：受到普攻或技能命中时，有%s概率完全格挡（持续伤害不触发）。" % pct(float(d.get("block_chance", 0.20)))
		"random_ally_buff":
			return "赤舞祝福%s：随机%d名友军各获得一种增益：技能冷却-2秒、攻击+%s或攻速+%s（%.1f秒）。" % [cd, int(d.get("ally_count", 1)), pct(float(d.get("buff_pct", 0.20))), pct(float(d.get("buff_pct", 0.20))), float(d.get("buff_duration", 3.0))]
		"team_random_stack":
			return "战鼓共振：普攻命中时，友军攻击、攻速各+%s（最多%d层，持续%.1f秒）；1/3概率为友军回复%s最大生命。" % [pct(float(d.get("stack_pct", 0.05))), int(d.get("max_stacks", 15)), float(d.get("stack_duration", 3.0)), pct(float(d.get("heal_pct", 0.05)))]
		"current_hp_strike":
			var text := "血猎：普攻额外造成目标当前生命%s的伤害（Boss为%s）" % [pct(float(d.get("current_hp_pct", 0.10))), pct(float(d.get("boss_hp_pct", 0.05)))]
			if float(d.get("execute_atk_pct", 0.0)) > 0.0:
				text += "；目标生命低于%s时，再造成攻击%s伤害" % [pct(float(d.get("execute_threshold", 0.30))), pct(float(d.get("execute_atk_pct", 0.50)))]
			return text + "。"
		"stacking_def_break":
			return ("破甲：普攻使目标防御永久-%d（最低为0）。" % int(d.get("break_amount", 2))) if float(d.get("break_chance", 0.50)) >= 1.0 else ("破甲：普攻有%s概率使目标防御永久-%d（最低为0）。" % [pct(float(d.get("break_chance", 0.50))), int(d.get("break_amount", 2))])
		"frost_status":
			return "霜印%s：对目标周围2格的敌人造成攻击%s伤害，并使其受到的伤害+%s（%.1f秒）。" % [cd, pct(float(d.get("damage_atk_pct", 1.70))), pct(float(d.get("ice_vulnerable_pct", 0.25))), float(d.get("ice_duration", 3.0))]
		"line_pierce":
			return "穿云：普攻穿透一线最多%d个敌人，伤害依次为攻击的100%%/%s/%s/%s。" % [int(d.get("pierce_targets", 4)), pct(1.0 - float(d.get("pierce_falloff", 0.20))), pct(1.0 - float(d.get("pierce_falloff", 0.20)) * 2.0), pct(1.0 - float(d.get("pierce_falloff", 0.20)) * 3.0)]
		"aoe_silence":
			return "赤灯禁言%s：开战立刻沉默敌人%.1f秒，期间无法释放技能、攻速-30%%。" % [cd, float(d.get("silence_duration", 3.0))]
		"none":
			return "无主动技能。"
		"lowest_ally_heal":
			return "星辉祈愿%s：治疗生命比例最低的友军，回复其最大生命%s；有%s概率清除负面状态。" % [cd, pct(float(d.get("heal_pct", 0.06))), pct(float(d.get("cleanse_chance", 0.25)))]
		"nearest_ally_bless":
			return "神赐祝福%s：最近友军攻击+%s、攻速+%s，并清除负面状态（同一目标最多%d层）。" % [cd, pct(float(d.get("atk_bonus", 0.12))), pct(float(d.get("aspd_bonus", 0.15))), BattleSimSkills.BLESS_MAX_STACKS]
		"guardian_shield_taunt":
			return "守护嘲讽：战斗开始获得最大生命%s护盾，并让周围敌人优先攻击自己。" % pct(float(d.get("start_shield_pct", 0.20)))
		"true_damage_attack":
			return "圣枪裁决：普通攻击额外造成自身攻击%s真实伤害。" % pct(float(d.get("true_damage_pct", 0.18)))
		"nearby_ally_heal_buff":
			return "光环治疗%s：周围友军回复%s最大生命、攻击+%s、攻速+%s，并清除负面状态（同一目标最多%d层）；开场冷却%.1f秒。" % [cd, pct(float(d.get("heal_pct", 0.15))), pct(float(d.get("atk_bonus", 0.10))), pct(float(d.get("aspd_bonus", 0.15))), BattleSimSkills.BLESS_MAX_STACKS, float(d.get("opening_cd", 0.0))]
		"judgement_strike":
			return "审判打击%s：对最近敌人造成攻击%s伤害，每次释放自身防御+%s（最多%d层）。" % [cd, pct(float(d.get("damage_atk_pct", 2.2))), pct(float(d.get("def_stack_pct", 0.06))), int(d.get("max_stacks", 5))]
		"random_ally_damage_reduction":
			return "天使庇护%s：随机友军获得%s减伤，持续%.1f秒。" % [cd, pct(float(d.get("damage_reduction", 0.50))), float(d.get("duration", 6.0))]
		"global_divine_blast":
			var tick_count := maxi(1, int(d.get("damage_tick_count", 5)))
			var tick_duration := float(tick_count - 1) * maxf(0.0, float(d.get("damage_tick_interval", 0.5)))
			return "神王裁决%s：%.1f秒内分%d次，对本路所有敌人共造成攻击%s+最大生命%s的伤害。" % [cd, tick_duration, tick_count, pct(float(d.get("damage_atk_pct", 1.6))), pct(float(d.get("max_hp_bonus_pct", 0.08)))]
		"curse_attack":
			return "诅咒攻击：普通攻击附带减攻%s与攻速降低%s，持续%.1f秒。" % [pct(float(d.get("attack_down", 0.08))), pct(float(d.get("aspd_down", 0.08))), float(d.get("duration", 4.0))]
		"silence_bolt":
			return "沉默箭%s：沉默最近敌人%.1f秒，并造成自身攻击%s伤害。" % [cd, float(d.get("silence_sec", 1.2)), pct(float(d.get("damage_atk_pct", 1.7)))]
		"fear":
			return "恐惧%s：使最近敌人逃跑%.1f秒。" % [cd, float(d.get("fear_sec", 2.0))]
		"same_target_damage_stack":
			return "痛苦凝视：持续攻击同一目标时，每层伤害+%s，最多%d层；换目标重置。" % [pct(float(d.get("stack_damage", 0.06))), int(d.get("max_stacks", 5))]
		"blink_low_def_backline":
			return "暗影突袭（冷却时间5.0秒）：瞬移到低防后排敌人身边，造成自身攻击%s伤害；击杀后刷新冷却。" % [pct(float(d.get("damage_atk_pct", 2.0)))]
		"stun":
			return "暗影击晕%s：眩晕最近敌人%.1f秒，并造成自身攻击%s伤害。" % [cd, float(d.get("stun_sec", 1.0)), pct(float(d.get("damage_atk_pct", 1.5)))]
		"shared_hp_link":
			# 9.14 反馈：4 星连接期间会按每秒 3% 最大生命回血，但文案没写。link_regen_pct
			# 只在 4 星的 star4 覆写里有，1~3 星回血为 0，文案自然不带那句。
			# 9.25 反馈第 2 条：目标口径补上「非唯一棋子」（唯一棋子是隐藏限制，见
			# BattleSimulator._is_unique_fighter），并去掉尾部「Boss免疫。」——
			# Boss 免疫改由「非Boss」这一处表述承担，不再重复声明。
			# 9.27 bug 文档第 1 条：再加「星级不高于自身」，与
			# BattleSimulator._link_targets_without_doom 的 star 过滤同步（zh/en 同源）。
			var link_regen := float(d.get("link_regen_pct", 0.0))
			var regen_clause := "，连接期间每秒回复%s最大生命" % pct(link_regen) if link_regen > 0.0 else ""
			return "血链%s：把最近一个星级不高于自己的敌人（Boss与唯一棋子除外）变成我方，双方共享伤害%s；一方死亡即断开，本回合不再释放。" % [cd, regen_clause]
		"black_hole":
			return "黑洞%s：牵引周围敌人，眩晕%.1f秒，并造成自身攻击%s伤害。" % [cd, float(d.get("pull_sec", 2.0)), pct(float(d.get("damage_atk_pct", 2.2)))]
		"poison_attack":
			var description := "毒击：普通攻击附带中毒，每秒造成目标最大生命%s伤害，持续%.1f秒。" % [pct(float(d.get("poison_pct_max_hp", 0.03))), float(d.get("poison_duration", 4.0))]
			return description.trim_suffix("。") + "；最多2层，分别扣血。" if _show_poison_stack_detail(d) else description
		"parasite_on_kill":
			return "寄生：自身普攻击杀非 Boss 敌人时，召唤该敌人的分身，生命为原目标%s，攻防为原目标%s。" % [pct(float(d.get("clone_hp_pct", 0.10))), pct(float(d.get("clone_atk_def_pct", 0.50)))]
		"defense_down_attack":
			return "腐蚀攻击：普通攻击降低目标防御%s，持续%.1f秒。" % [pct(float(d.get("def_down_pct", 0.10))), float(d.get("duration", 5.0))]
		"death_poison_explosion":
			if d.has("poisoned_damage_atk_pct"):
				return "死亡毒爆：死亡时对周围敌人造成攻击%s伤害（已中毒的目标%s），并使其中毒。" % [pct(float(d.get("damage_atk_pct", 3.0))), pct(float(d.poisoned_damage_atk_pct))]
			return "死亡毒爆：死亡时对周围敌人造成攻击%s伤害，并使其中毒。" % pct(float(d.get("damage_atk_pct", 2.5)))
		"poison_reflect_armor_stack":
			return "毒甲：受伤时反弹本次伤害%s的真实伤害并使攻击者中毒；自身防御每次+%s（最多%d层）。" % [pct(float(d.get("reflect_taken_damage_pct", 0.12))), pct(float(d.get("armor_per_hit_pct", 0.14))), int(d.get("max_stacks", 10))]
		"unique_death_execute":
			# 9.14：文案把所有可调数值都改成读 def，1~3 星与 4 星自动显示各自那一份。
			# 9.24：灵7 已改为「普攻中毒目标回血」，不再降低母灵阈值。
			var m_th := int(d.get("death_threshold", 5))
			var m_t1 := float(d.get("tier1_or_merc_chance", 0.5))
			var m_t2 := float(d.get("tier2_chance", 0.35))
			var m_t3 := float(d.get("tier3_chance", 0.1))
			var m_boss := float(d.get("boss_max_hp_damage", 0.2))
			return "母灵（每人限1只）：每有%d个敌人死亡，处决一名敌人（1阶/佣兵%s、2阶%s、3阶%s）；对Boss或法阵守护者改为造成%s最大生命伤害。" % [m_th, pct(m_t1), pct(m_t2), pct(m_t3), pct(m_boss)]
		"attack_interrupt":
			# 9.14：4 星把「打断」（锁普攻 1 秒）换成「眩晕」0.5 秒 —— stun_sec 只写在
			# 4 星 star4 覆写里。文案按有无 stun_sec 分两支，与 BattleSimulator 的实现同源。
			var militia_stun := float(d.get("stun_sec", 0.0))
			if militia_stun > 0.0:
				return "缴械攻击：普通攻击有%s概率眩晕目标%.1f秒。" % [pct(float(d.get("interrupt_chance", 0.12))), militia_stun]
			return "缴械攻击：普通攻击有%s概率缴械目标（1 秒内无法普攻）。" % pct(float(d.get("interrupt_chance", 0.12)))
		"post_battle_gold_by_star":
			if d.has("attack_gold_chance"):
				return "战场经商：每次普通攻击有%s概率获得%d金币，战斗结束后结算。" % [pct(float(d.attack_gold_chance)), int(d.attack_gold_amount)]
			return "战后经商：参与战斗后，按星级获得金币。1星+10，2星+20，3星+30。"
		"every_fourth_combo":
			return "连射：每第%d次普通攻击额外造成自身攻击%s伤害。" % [int(d.get("every", 4)), pct(float(d.get("combo_atk_pct", 0.70)))]
		"front_cone_stun":
			return "盾击%s：攻击最近敌人，造成自身攻击%s伤害并眩晕%.1f秒。" % [cd, pct(float(d.get("damage_atk_pct", 1.5))), float(d.get("stun_sec", 1.0))]
		"random_attribute_attack":
			return "属性乱击：普通攻击随机附带火/冰/雷/毒属性效果。"
		"random_attribute_bolt":
			# 9.14：文案原来把 2.5 秒 / 300% 硬写死。改成读 def —— 4 星 star4 给的是
			# 冷却 2 秒、600%、20% 双重施法，1~3 星仍是 2.5 秒 / 300%。
			var mage_cd := float(d.get("skill_cd", 2.5))
			var mage_dmg := float(d.get("damage_atk_pct", 3.0))
			var mage_dbl := float(d.get("double_element_chance", 0.0))
			var mage_tail := "，并有%s概率触发双重施法" % pct(mage_dbl) if mage_dbl > 0.0 else ""
			return "随机法术：无普攻，每%.1f秒对随机敌人造成攻击%s的随机属性伤害%s。" % [mage_cd, pct(mage_dmg), mage_tail]
		"every_fifth_group_heal":
			return "战歌：每第%d次普通攻击治疗周围友军最大生命%s。" % [int(d.get("every", 5)), pct(float(d.get("heal_pct", 0.05)))]
		"left_neighbor_sacrifice":
			# 9.14：1~3 星 +3 防 / 5 秒 / 只绑左邻；4 星 +30% 防 / 8 秒 / 左右各绑一个
			# （但死侍只能牺牲一次，先死的那一侧用掉之后另一侧自然失效）。文案按
			# ally_def_pct 是否存在分两支。
			var ds_dur := float(d.get("ally_def_duration", 5.0))
			var ds_pct := float(d.get("ally_def_pct", 0.0))
			if ds_pct > 0.0:
				return "死侍契约：周围友军防御+%s（%.1f秒）；开战绑定左右两侧棋子，先阵亡的那个由死侍替死并满血复活（仅一次）。" % [pct(ds_pct), ds_dur]
			return "死侍契约：周围友军防御+%d（%.1f秒）；开战绑定左侧棋子，它首次阵亡时由死侍替死并满血复活。" % [int(d.get("ally_def_bonus", 3)), ds_dur]
		"unique_king_growth":
			# 9.14：1~3 星成长 ×1.2、上限 5 层；4 星 ×1.3、上限 8 层。两者都写进文案，
			# 数值全部读 def（apply_star_stats 会把 star4 的 0.3 / 8 覆盖上来）。
			var king_growth := float(d.get("post_battle_all_stat_growth", 0.20))
			var king_cap := int(d.get("max_stacks", 5))
			return "人王（棋盘限1只）：每活过一场，生命、攻击、防御、攻速永久×%.1f（最多%d层）；阵亡则移出棋盘，升星保留最高成长。" % [1.0 + king_growth, king_cap]
		"balance_judge":
			return "均衡裁决：攻击当前生命高于自己的目标时，伤害+%s。" % pct(float(d.get("bonus_vs_higher_hp", 0.40)))
		"bubble_dream":
			return "泡沫梦境%s：治疗最低血友军%d点，并使最近敌人减速%s、受到%d点真实伤害。" % [cd, int(d.get("heal", 80)), pct(float(d.get("slow_pct", 0.30))), int(d.get("burst_damage", 70))]
		"shell_guard":
			# 9.20 bug 文档第 4 条：补上冷却。cd 走 skill_cd_text()，取的是
			# IMPLICIT_SKILL_CD 里的 6.0（佣兵 JSON 无 skill_cd，见那份常量的注释）。
			return "甲壳守护%s：获得%s减伤，持续%.1f秒。" % [cd, pct(float(d.get("reduction", 0.50))), float(d.get("duration", 5.0))]
		"gold_charge":
			return "黄金冲锋%s：冲向最近敌人，造成%d点真实伤害并眩晕%.1f秒。" % [cd, int(d.get("skill_damage", 120)), float(d.get("stun_sec", 1.2))]
		"holy_song":
			return "圣歌%s：治疗全体友军最大生命%s，并从带控制类负面状态的存活友军中随机净化1名。" % [cd, pct(float(d.get("heal_pct", 0.15)))]
		"twin_strike":
			return "镜像突袭%s：召唤自身镜像，镜像生命%s、攻击%s。" % [cd, pct(float(d.get("clone_hp_pct", 0.30))), pct(float(d.get("clone_atk_pct", 0.40)))]
		"king_aura":
			return "王者光环：每2秒强化周围友军，攻速+%s、暴击+%s，持续2.2秒。" % [pct(float(d.get("ally_aspd_bonus", 0.25))), pct(float(d.get("ally_crit_bonus", 0.15)))]
		"arrow_rain":
			return "箭雨%s：攻击最近%d名敌人，每个目标受到自身攻击85%%伤害。" % [cd, int(d.get("targets", 5))]
		"blood_rampage":
			return "血怒：每损失%s最大生命，攻速+%s、吸血+%s、伤害+3%%。" % [pct(float(d.get("hp_step", 0.10))), pct(float(d.get("aspd_per_step", 0.10))), pct(float(d.get("lifesteal_per_step", 0.05)))]
		"steel_order":
			return "钢铁号令%s：强化最近%d名友军，减伤%s、攻速+%s、控制时间降低%s，持续%.1f秒。" % [cd, int(d.get("buff_targets", 3)), pct(float(d.get("damage_reduction", 0.20))), pct(float(d.get("aspd_bonus", 0.20))), pct(float(d.get("control_time_reduction", 0.30))), float(d.get("duration", 8.0))]
		"time_slow":
			return "时空迟缓%s：自身短暂闪避提高，并使全体敌人减速%s，持续%.1f秒。" % [cd, pct(float(d.get("slow_pct", 0.35))), float(d.get("duration", 5.0))]
		"death_hunt":
			return "冥界处决：优先攻击低血目标；击杀回复最大生命%s。普攻破甲%d并降低治疗%s，持续%.1f秒。" % [pct(float(d.get("kill_heal_pct", 0.15))), int(d.get("armor_break", 8)), pct(float(d.get("heal_reduction", 0.50))), float(d.get("duration", 4.0))]
		# --- Boss ---
		"element_meteor":
			return "陨星轰击%s：砸向最近的敌人，对落点周围 %.0f 像素内的敌人造成 %d 点真实伤害。" % [cd, float(d.get("aoe_radius", 250.0)), int(d.get("skill_damage", 240))]
		"overload_counter":
			return "过载反击：每挨%d下，对攻击者造成%d真实伤害、周围敌人%d真实伤害，%s概率打断攻击者。" % [int(d.get("hit_threshold", 8)), int(d.get("skill_damage", 300)), int(d.get("splash_damage", 200)), pct(float(d.get("interrupt_chance", 0.25)))]
		"mirror_clone":
			return "镜像分裂：每损失%s生命，分裂出一个镜像（%s生命、%s攻击，不放技能）。" % [pct(float(d.get("clone_per_missing_hp_pct", 0.25))), pct(float(d.get("clone_hp_pct", 0.30))), pct(float(d.get("clone_atk_pct", 1.00)))]
		"holy_purify":
			return "圣愈净化%s：清除自身和周围友军的状态；周围友军回复%s最大生命，所有人获得%s最大生命的护盾（不叠加）。" % [cd, pct(float(d.get("heal_pct", 0.20))), pct(float(d.get("shield_pct", 0.15)))]
		"rage_stack":
			return "狂怒叠加：每次普攻后攻击+%s、攻速+%s（最多%d层）。" % [pct(float(d.get("atk_per_hit", 0.05))), pct(float(d.get("aspd_per_hit", 0.03))), int(d.get("max_stacks", 50))]
		"blood_rage":
			return "血怒暴走：生命降到%s时进入暴走，攻击+%s、攻速+%s，并获得%s吸血。" % [pct(float(d.get("trigger_hp_pct", 0.50))), pct(float(d.get("atk_bonus", 1.00))), pct(float(d.get("aspd_bonus", 0.50))), pct(float(d.get("lifesteal", 0.20)))]
		"soul_devour":
			return "噬魂：本路每死亡一名己方小怪或敌方棋子，回复%s最大生命、攻击+%s、攻速+%s（最多%d层）。" % [pct(float(d.get("kill_heal_pct", 0.20))), pct(float(d.get("atk_stack", 0.20))), pct(float(d.get("aspd_stack", 0.20))), int(d.get("max_stacks", 10))]
		"twin_revive":
			return "双生：普攻对主目标身后扇形的敌人造成攻击%s伤害；一只阵亡后%.1f秒以%s生命复活（每只限%d次）。" % [pct(float(d.get("cleave_atk_pct", 0.50))), float(d.get("revive_delay", 5.0)), pct(float(d.get("revive_hp_pct", 0.60))), int(d.get("revives_per_twin", 1))]
		"apocalypse_charge":
			return "灭世蓄力%s：获得%s最大生命护盾并蓄力%.1f秒，然后对全场敌人造成攻击%s的%s；护盾被打破则中断。" % [cd, pct(float(d.get("charge_shield_pct", 0.10))), float(d.get("charge_sec", 2.0)), pct(float(d.get("damage_atk_pct", 2.5))), "真实伤害" if bool(d.get("ignore_def", true)) else "伤害"]
		# --- 法阵守护者 ---
		"burn_claw":
			return "焰爪%s：回复自身 %d 点生命并叠加 %d 点护盾（上限 %d）；普通攻击附带中毒与灼烧，每秒 %d 点伤害，持续 %.1f 秒。" % [cd, int(d.get("self_heal", 200)), int(d.get("self_shield", 100)), int(d.get("shield_cap", 300)), int(d.get("burn_dps", 36)), float(d.get("burn_duration", 3.0))]
		"soul_chain":
			return "锁魂%s：眩晕全场敌人 %.1f 秒，并使其攻速降低 %s，持续 %.1f 秒。" % [cd, float(d.get("stun_sec", 1.5)), pct(float(d.get("aspd_down_pct", 0.50))), float(d.get("aspd_down_duration", 3.0))]
		"devour_bite":
			return "噬咬%s：沉默全场敌人 %.1f 秒，期间无法释放技能；普通攻击回复自身攻击 %s 的生命。" % [cd, float(d.get("silence_sec", 3.5)), pct(float(d.get("lifesteal", 0.18)))]
		"hell_burst":
			return "炼狱焚界%s：使全场敌人灼烧，每秒 %d 点伤害持续 %.1f 秒，并降低攻击 %s，持续 %.1f 秒。" % [cd, int(d.get("burn_dps", 100)), float(d.get("burn_duration", 5.0)), pct(float(d.get("attack_down_pct", 0.25))), float(d.get("attack_down_duration", 5.0))]
		"eternal_night":
			return "厄夜流星%s：召唤流星雨覆盖全场，对每个敌人造成 %d 点真实伤害（无视防御）。" % [cd, int(d.get("meteor_damage", 800))]
		# 野怪技能目前只有数据与特效，战斗结算里没有对应分支（BattleSimulator 的技能
		# match 查不到这些 id），所以这里不写效果说明。图鉴宁可写「无」，也不该承诺一个
		# 打不出来的技能。实现补上后，把对应 id 从这一行挪出去写正式文案即可。
		"dive_backline", "chain_lightning", "heal_allies", "holy_shield_burst", "wind_bleed", "slow_aura", "stun_impact", "entangle", "burrow_ambush", "lava_burst", "nature_heal", "earth_slam", "backstab", "curse", "counter_slash":
			return "无主动技能。"
	return "该技能暂未写入详细说明。"

static func format_skill_detail_en(d: Dictionary) -> String:
	var sid := str(d.get("skill_id", "none"))
	var cd := skill_cd_text(d)
	match sid:
		"block_guard":
			return "Crimson Guard: %s chance to fully block a basic or skill hit (not damage over time)." % pct(float(d.get("block_chance", 0.20)))
		"random_ally_buff":
			return "Crimson Dance%s: %d random allies each gain one buff: -2s skill cooldown, +%s ATK, or +%s AS (%.1fs)." % [cd, int(d.get("ally_count", 1)), pct(float(d.get("buff_pct", 0.20))), pct(float(d.get("buff_pct", 0.20))), float(d.get("buff_duration", 3.0))]
		"team_random_stack":
			return "War Drum: Each basic hit gives allies +%s ATK and +%s AS (up to %d stacks, %.1fs); 1-in-3 chance to heal allies for %s max HP." % [pct(float(d.get("stack_pct", 0.05))), pct(float(d.get("stack_pct", 0.05))), int(d.get("max_stacks", 15)), float(d.get("stack_duration", 3.0)), pct(float(d.get("heal_pct", 0.05)))]
		"current_hp_strike":
			var text := "Blood Hunt: Basics deal extra damage equal to %s of the target's current HP (%s vs Bosses)" % [pct(float(d.get("current_hp_pct", 0.10))), pct(float(d.get("boss_hp_pct", 0.05)))]
			if float(d.get("execute_atk_pct", 0.0)) > 0.0:
				text += "; below %s HP, deal another %s ATK damage" % [pct(float(d.get("execute_threshold", 0.30))), pct(float(d.get("execute_atk_pct", 0.50)))]
			return text + "."
		"stacking_def_break":
			return ("Armor Break: Basics permanently reduce target DEF by %d (down to 0)." % int(d.get("break_amount", 2))) if float(d.get("break_chance", 0.50)) >= 1.0 else ("Armor Break: Basics have a %s chance to permanently reduce target DEF by %d (down to 0)." % [pct(float(d.get("break_chance", 0.50))), int(d.get("break_amount", 2))])
		"frost_status":
			return "Frost Mark%s: Deal %s ATK damage to enemies within 2 cells of the target and make them take +%s damage for %.1fs." % [cd, pct(float(d.get("damage_atk_pct", 1.70))), pct(float(d.get("ice_vulnerable_pct", 0.25))), float(d.get("ice_duration", 3.0))]
		"line_pierce":
			return "Skypierce: Basics pierce up to %d enemies in a line for 100%%/%s/%s/%s ATK damage." % [int(d.get("pierce_targets", 4)), pct(1.0 - float(d.get("pierce_falloff", 0.20))), pct(1.0 - float(d.get("pierce_falloff", 0.20)) * 2.0), pct(1.0 - float(d.get("pierce_falloff", 0.20)) * 3.0)]
		"aoe_silence":
			return "Crimson Lantern%s: At battle start, silence enemies for %.1fs: no skills and -30%% AS." % [cd, float(d.get("silence_duration", 3.0))]
		"none":
			return "No active skill."
		"lowest_ally_heal":
			return "Starlight Prayer%s: Heal the ally with the lowest HP ratio by %s of their max HP; %s chance to cleanse debuffs." % [cd, pct(float(d.get("heal_pct", 0.06))), pct(float(d.get("cleanse_chance", 0.25)))]
		"nearest_ally_bless":
			return "Divine Blessing%s: The nearest ally gains +%s ATK and +%s AS and is cleansed (up to %d stacks per ally)." % [cd, pct(float(d.get("atk_bonus", 0.12))), pct(float(d.get("aspd_bonus", 0.15))), BattleSimSkills.BLESS_MAX_STACKS]
		"guardian_shield_taunt":
			return "Guardian Taunt: Gain a shield equal to %s max HP at battle start; force nearby enemies to target this unit." % pct(float(d.get("start_shield_pct", 0.20)))
		"true_damage_attack":
			return "Holy Lance: Normal attacks deal bonus true damage equal to %s ATK." % pct(float(d.get("true_damage_pct", 0.18)))
		"nearby_ally_heal_buff":
			return "Halo Heal%s: Nearby allies heal %s max HP, gain +%s ATK and +%s AS, and are cleansed (up to %d stacks per ally); first cast after %.1fs." % [cd, pct(float(d.get("heal_pct", 0.15))), pct(float(d.get("atk_bonus", 0.10))), pct(float(d.get("aspd_bonus", 0.15))), BattleSimSkills.BLESS_MAX_STACKS, float(d.get("opening_cd", 0.0))]
		"judgement_strike":
			return "Judgement Strike%s: Deal %s ATK damage to the nearest enemy; each cast grants +%s DEF (up to %d stacks)." % [cd, pct(float(d.get("damage_atk_pct", 2.2))), pct(float(d.get("def_stack_pct", 0.06))), int(d.get("max_stacks", 5))]
		"random_ally_damage_reduction":
			return "Angel's Guard%s: Grant a random ally %s damage reduction for %.1fs." % [cd, pct(float(d.get("damage_reduction", 0.50))), float(d.get("duration", 6.0))]
		"global_divine_blast":
			var tick_count := maxi(1, int(d.get("damage_tick_count", 5)))
			var tick_duration := float(tick_count - 1) * maxf(0.0, float(d.get("damage_tick_interval", 0.5)))
			return "Divine Judgement%s: Over %.1fs, hit every enemy in this lane %d times for %s ATK + %s max HP in total." % [cd, tick_duration, tick_count, pct(float(d.get("damage_atk_pct", 1.6))), pct(float(d.get("max_hp_bonus_pct", 0.08)))]
		"curse_attack":
			return "Curse Strike: Normal attacks reduce target ATK by %s and AS by %s for %.1fs." % [pct(float(d.get("attack_down", 0.08))), pct(float(d.get("aspd_down", 0.08))), float(d.get("duration", 4.0))]
		"silence_bolt":
			return "Silence Bolt%s: Silence the nearest enemy for %.1fs and deal %s ATK damage." % [cd, float(d.get("silence_sec", 1.2)), pct(float(d.get("damage_atk_pct", 1.7)))]
		"fear":
			return "Fear%s: Make the nearest enemy flee for %.1fs." % [cd, float(d.get("fear_sec", 2.0))]
		"same_target_damage_stack":
			return "Agonizing Gaze: Consecutive attacks on the same target deal +%s damage per stack (max %d stacks). Resets on target switch." % [pct(float(d.get("stack_damage", 0.06))), int(d.get("max_stacks", 5))]
		"blink_low_def_backline":
			return "Shadow Ambush%s: Blink to the lowest-DEF backline enemy and deal %s ATK damage. Cooldown resets on kill." % [cd, pct(float(d.get("damage_atk_pct", 2.0)))]
		"stun":
			return "Shadow Stun%s: Stun the nearest enemy for %.1fs and deal %s ATK damage." % [cd, float(d.get("stun_sec", 1.0)), pct(float(d.get("damage_atk_pct", 1.5)))]
		"shared_hp_link":
			# 9.14: 4-star regenerates 3% max HP/s while linked; only 4-star sets
			# link_regen_pct, so 1-3 star text stays without the clause.
			# 9.25 (#2): add "non-unique" to the target wording (unique units are a
			# hidden limit, see BattleSimulator._is_unique_fighter) and drop the
			# trailing "Boss immune." — immunity is now carried solely by
			# "nearest non-Boss". Kept in lockstep with the zh branch above.
			# 9.27 (#1): also add "no higher star than itself", mirroring the star
			# filter in BattleSimulator._link_targets_without_doom.
			var link_regen := float(d.get("link_regen_pct", 0.0))
			var regen_clause := ", regenerating %s max HP per second while linked" % pct(link_regen) if link_regen > 0.0 else ""
			return "Blood Chain%s: Turn the nearest enemy of equal or lower star (not Bosses or unique units) to your side; both share damage taken%s. Breaks when either dies; not recast this round." % [cd, regen_clause]
		"black_hole":
			return "Black Hole%s: Pull surrounding enemies, stun for %.1fs, and deal %s ATK damage." % [cd, float(d.get("pull_sec", 2.0)), pct(float(d.get("damage_atk_pct", 2.2)))]
		"poison_attack":
			var description := "Poison Strike: Normal attacks apply poison — %s max HP per second for %.1fs." % [pct(float(d.get("poison_pct_max_hp", 0.03))), float(d.get("poison_duration", 4.0))]
			return description + " Up to 2 stacks tick separately." if _show_poison_stack_detail(d) else description
		"parasite_on_kill":
			return "Parasite: When this unit kills a non-Boss enemy with a basic attack, summon its clone at %s HP and %s ATK/DEF." % [pct(float(d.get("clone_hp_pct", 0.10))), pct(float(d.get("clone_atk_def_pct", 0.50)))]
		"defense_down_attack":
			return "Corrosive Strike: Normal attacks reduce target DEF by %s for %.1fs." % [pct(float(d.get("def_down_pct", 0.10))), float(d.get("duration", 5.0))]
		"death_poison_explosion":
			if d.has("poisoned_damage_atk_pct"):
				return "Death Burst: On death, deal %s ATK damage to nearby enemies (%s to poisoned ones) and poison them." % [pct(float(d.get("damage_atk_pct", 3.0))), pct(float(d.poisoned_damage_atk_pct))]
			return "Death Burst: On death, deal %s ATK damage to nearby enemies and poison them." % pct(float(d.get("damage_atk_pct", 2.5)))
		"poison_reflect_armor_stack":
			return "Toxic Armor: When hit, reflect %s of the damage as true damage and poison the attacker; gain +%s DEF per hit (up to %d stacks)." % [pct(float(d.get("reflect_taken_damage_pct", 0.12))), pct(float(d.get("armor_per_hit_pct", 0.14))), int(d.get("max_stacks", 10))]
		"unique_death_execute":
			var m_th := int(d.get("death_threshold", 5))
			var m_t1 := float(d.get("tier1_or_merc_chance", 0.5))
			var m_t2 := float(d.get("tier2_chance", 0.35))
			var m_t3 := float(d.get("tier3_chance", 0.1))
			var m_boss := float(d.get("boss_max_hp_damage", 0.2))
			return "Matron (one per player): Every %d enemy deaths, execute an enemy (Tier 1/Merc %s, Tier 2 %s, Tier 3 %s); against a Boss or Formation Guardian, deal %s of its max HP instead." % [m_th, pct(m_t1), pct(m_t2), pct(m_t3), pct(m_boss)]
		"attack_interrupt":
			var militia_stun := float(d.get("stun_sec", 0.0))
			if militia_stun > 0.0:
				return "Disarm Strike: Normal attacks have a %s chance to stun the target for %.1fs." % [pct(float(d.get("interrupt_chance", 0.12))), militia_stun]
			return "Disarm Strike: Normal attacks have a %s chance to disarm the target (cannot use normal attacks for 1s)." % pct(float(d.get("interrupt_chance", 0.12)))
		"post_battle_gold_by_star":
			if d.has("attack_gold_chance"):
				return "Battle Trade: Each normal attack has a %s chance to earn %d gold, paid after battle." % [pct(float(d.attack_gold_chance)), int(d.attack_gold_amount)]
			return "Trade: After each battle, gain gold by star level (★1 → +10G, ★2 → +20G, ★3 → +30G)."
		"every_fourth_combo":
			return "Rapid Fire: Every %d attacks, deal bonus %s ATK damage." % [int(d.get("every", 4)), pct(float(d.get("combo_atk_pct", 0.70)))]
		"front_cone_stun":
			return "Shield Bash%s: Strike the nearest enemy for %s ATK damage and stun for %.1fs." % [cd, pct(float(d.get("damage_atk_pct", 1.5))), float(d.get("stun_sec", 1.0))]
		"random_attribute_attack":
			return "Elemental Strike: Normal attacks randomly apply fire / ice / thunder / poison."
		"random_attribute_bolt":
			var mage_cd := float(d.get("skill_cd", 2.5))
			var mage_dmg := float(d.get("damage_atk_pct", 3.0))
			var mage_dbl := float(d.get("double_element_chance", 0.0))
			var mage_tail := ", with a %s chance to double-cast" % pct(mage_dbl) if mage_dbl > 0.0 else ""
			return "Random Spell: No basic attack. Every %.1fs, deal %s ATK random-element damage to a random enemy%s." % [mage_cd, pct(mage_dmg), mage_tail]
		"every_fifth_group_heal":
			return "War Song: Every %d attacks, heal nearby allies for %s of their max HP." % [int(d.get("every", 5)), pct(float(d.get("heal_pct", 0.05)))]
		"left_neighbor_sacrifice":
			var ds_dur := float(d.get("ally_def_duration", 5.0))
			var ds_pct := float(d.get("ally_def_pct", 0.0))
			if ds_pct > 0.0:
				return "Death Pact: Nearby allies gain +%s DEF (%.1fs). At battle start, bind both neighbours; whichever dies first is revived at full HP as this unit dies in its place (once)." % [pct(ds_pct), ds_dur]
			return "Death Pact: Nearby allies gain +%d DEF (%.1fs). At battle start, bind the left neighbour; when it first dies, this unit dies in its place and revives it at full HP." % [int(d.get("ally_def_bonus", 3)), ds_dur]
		"unique_king_growth":
			var king_growth := float(d.get("post_battle_all_stat_growth", 0.20))
			var king_cap := int(d.get("max_stacks", 5))
			return "Human King (one per board): Each battle survived permanently multiplies HP/ATK/DEF/AS by %.1f (up to %d stacks). If it dies it leaves the board; upgrading keeps the highest growth." % [1.0 + king_growth, king_cap]
		"balance_judge":
			return "Balance Judgement: Deal +%s damage against targets with more current HP than this unit." % pct(float(d.get("bonus_vs_higher_hp", 0.40)))
		"bubble_dream":
			return "Bubble Dream%s: Heal the lowest-HP ally for %d HP; slow the nearest enemy by %s and deal %d true damage." % [cd, int(d.get("heal", 80)), pct(float(d.get("slow_pct", 0.30))), int(d.get("burst_damage", 70))]
		"shell_guard":
			return "Shell Guard: Gain %s damage reduction for %.1fs." % [pct(float(d.get("reduction", 0.50))), float(d.get("duration", 5.0))]
		"gold_charge":
			return "Gold Charge%s: Rush the nearest enemy, deal %d true damage and stun for %.1fs." % [cd, int(d.get("skill_damage", 120)), float(d.get("stun_sec", 1.2))]
		"holy_song":
			return "Holy Song%s: Heal all allies for %s max HP, then cleanse one random living ally with a crowd-control debuff." % [cd, pct(float(d.get("heal_pct", 0.15)))]
		"twin_strike":
			return "Mirror Ambush%s: Summon a mirror clone with %s HP and %s ATK." % [cd, pct(float(d.get("clone_hp_pct", 0.30))), pct(float(d.get("clone_atk_pct", 0.40)))]
		"king_aura":
			return "King's Aura: Every 2s, buff nearby allies — AS +%s, Crit +%s for 2.2s." % [pct(float(d.get("ally_aspd_bonus", 0.25))), pct(float(d.get("ally_crit_bonus", 0.15)))]
		"arrow_rain":
			return "Arrow Rain%s: Strike the nearest %d enemies, each taking 85%% ATK damage." % [cd, int(d.get("targets", 5))]
		"blood_rampage":
			return "Blood Rage: For every %s max HP lost, gain +%s AS, +%s lifesteal and +3%% damage." % [pct(float(d.get("hp_step", 0.10))), pct(float(d.get("aspd_per_step", 0.10))), pct(float(d.get("lifesteal_per_step", 0.05)))]
		"steel_order":
			return "Steel Order%s: Buff the nearest %d allies — DMG Reduce %s, AS +%s, CC Duration -%s for %.1fs." % [cd, int(d.get("buff_targets", 3)), pct(float(d.get("damage_reduction", 0.20))), pct(float(d.get("aspd_bonus", 0.20))), pct(float(d.get("control_time_reduction", 0.30))), float(d.get("duration", 8.0))]
		"time_slow":
			return "Time Warp%s: Briefly boost own dodge; slow all enemies by %s for %.1fs." % [cd, pct(float(d.get("slow_pct", 0.35))), float(d.get("duration", 5.0))]
		"death_hunt":
			return "Death Hunt: Prioritizes low-HP targets; kills restore %s max HP. Normal attacks break %d armor and reduce healing by %s for %.1fs." % [pct(float(d.get("kill_heal_pct", 0.15))), int(d.get("armor_break", 8)), pct(float(d.get("heal_reduction", 0.50))), float(d.get("duration", 4.0))]
		# --- Boss ---
		"element_meteor":
			return "Meteor Strike%s: Hit the nearest enemy and other enemies within %.0f pixels of the impact for %d true damage." % [cd, float(d.get("aoe_radius", 250.0)), int(d.get("skill_damage", 240))]
		"overload_counter":
			return "Overload Counter: Every %d hits taken, deal %d true damage to the attacker and %d true damage to nearby enemies; %s chance to interrupt the attacker." % [int(d.get("hit_threshold", 8)), int(d.get("skill_damage", 300)), int(d.get("splash_damage", 200)), pct(float(d.get("interrupt_chance", 0.25)))]
		"mirror_clone":
			return "Mirror Split: Every %s HP lost, split off a mirror image (%s HP, %s ATK, no skills)." % [pct(float(d.get("clone_per_missing_hp_pct", 0.25))), pct(float(d.get("clone_hp_pct", 0.30))), pct(float(d.get("clone_atk_pct", 1.00)))]
		"holy_purify":
			return "Holy Purify%s: Cleanse itself and nearby allies; nearby allies heal %s max HP and everyone gains a %s max HP shield (no stacking)." % [cd, pct(float(d.get("heal_pct", 0.20))), pct(float(d.get("shield_pct", 0.15)))]
		"rage_stack":
			return "Rage Stacks: Each basic attack grants +%s ATK and +%s AS (up to %d stacks)." % [pct(float(d.get("atk_per_hit", 0.05))), pct(float(d.get("aspd_per_hit", 0.03))), int(d.get("max_stacks", 50))]
		"blood_rage":
			return "Blood Frenzy: At %s HP, enrage: +%s ATK, +%s AS and %s lifesteal." % [pct(float(d.get("trigger_hp_pct", 0.50))), pct(float(d.get("atk_bonus", 1.00))), pct(float(d.get("aspd_bonus", 0.50))), pct(float(d.get("lifesteal", 0.20)))]
		"soul_devour":
			return "Soul Devour: Each friendly monster or enemy piece death in this lane restores %s max HP and grants +%s ATK and +%s AS (up to %d stacks)." % [pct(float(d.get("kill_heal_pct", 0.20))), pct(float(d.get("atk_stack", 0.20))), pct(float(d.get("aspd_stack", 0.20))), int(d.get("max_stacks", 10))]
		"twin_revive":
			return "Twins: Basics deal %s ATK damage in a cone behind the primary target; a fallen twin revives after %.1fs at %s HP (up to %d times each)." % [pct(float(d.get("cleave_atk_pct", 0.50))), float(d.get("revive_delay", 5.0)), pct(float(d.get("revive_hp_pct", 0.60))), int(d.get("revives_per_twin", 1))]
		"apocalypse_charge":
			return "Apocalypse Charge%s: Gain a %s max HP shield and charge for %.1fs, then hit all enemies for %s ATK %s; breaking the shield interrupts it." % [cd, pct(float(d.get("charge_shield_pct", 0.10))), float(d.get("charge_sec", 2.0)), pct(float(d.get("damage_atk_pct", 2.5))), "true damage" if bool(d.get("ignore_def", true)) else "damage"]
		# --- Formation guardians ---
		"burn_claw":
			return "Flame Claw%s: Heal self for %d HP and stack %d shield (cap %d). Normal attacks apply poison and burn for %d damage per second over %.1fs." % [cd, int(d.get("self_heal", 200)), int(d.get("self_shield", 100)), int(d.get("shield_cap", 300)), int(d.get("burn_dps", 36)), float(d.get("burn_duration", 3.0))]
		"soul_chain":
			return "Soul Chain%s: Stun every enemy for %.1fs and cut their attack speed by %s for %.1fs." % [cd, float(d.get("stun_sec", 1.5)), pct(float(d.get("aspd_down_pct", 0.50))), float(d.get("aspd_down_duration", 3.0))]
		"devour_bite":
			return "Devour Bite%s: Silence every enemy for %.1fs, blocking all their skills. Normal attacks heal this unit for %s of its ATK." % [cd, float(d.get("silence_sec", 3.5)), pct(float(d.get("lifesteal", 0.18)))]
		"hell_burst":
			return "Hell Burst%s: Burn every enemy for %d damage per second over %.1fs and reduce their ATK by %s for %.1fs." % [cd, int(d.get("burn_dps", 100)), float(d.get("burn_duration", 5.0)), pct(float(d.get("attack_down_pct", 0.25))), float(d.get("attack_down_duration", 5.0))]
		"eternal_night":
			return "Eternal Night%s: Rain meteors across the field, dealing %d true damage to every enemy (ignores DEF)." % [cd, int(d.get("meteor_damage", 800))]
		# Monster skills: data and VFX only — the simulator has no branch for these
		# ids, so the codex says nothing rather than promising an effect that never
		# fires. Move an id out of this line once it is actually implemented.
		"dive_backline", "chain_lightning", "heal_allies", "holy_shield_burst", "wind_bleed", "slow_aura", "stun_impact", "entangle", "burrow_ambush", "lava_burst", "nature_heal", "earth_slam", "backstab", "curse", "counter_slash":
			return "No active skill."
	return "Skill description not yet available."


# 数据表不带 `skill_cd`、但实现确实有冷却的技能，在这里登记它们的缺省值。
#
# 数值必须与 `BattleSimulator._tick_skills` 里同名分支的
# `d.get("skill_cd", X)` 缺省值**逐字一致** —— 文案写 5 秒、实现跑 8 秒
# 是最难被玩家发现、也最难被门禁抓到的一类错。
#
# 9.19 反馈（bug 文档第 1 条）：「剑士技能未显示冷却时间，在『盾击』后面增加
# 冷却时间描述，『盾击（冷却5.0秒）：』」。`front_cone_stun` 在模拟器里是
# `elapsed + float(d.get("skill_cd", 5.0))`（BattleSimulator.gd `_tick_skills`），
# 而 `data/units/race_units.json` 里这只棋子根本不带 `skill_cd` 字段 →
# `skill_cd_text()` 返回空串 → 文案少了一整句冷却说明。
const IMPLICIT_SKILL_CD := {
	"black_hole": 8.0,
	"front_cone_stun": 5.0,
	# 9.20 bug 文档第 4 条：佣兵「甲壳守卫」的冷却没写进详情。
	# 与 front_cone_stun 同一种情况 —— 模拟器里是硬编码的常数
	# （BattleSimulator._tick_skills: `caster.skill_ready = float(state.elapsed) + 6.0`），
	# 而 data/mercenary/mercenaries.json 的 merc_cancer_shell 不带 skill_cd 字段，
	# 于是 skill_cd_text() 返回空串、文案少了一整句冷却说明。
	"shell_guard": 6.0,
	# 9.20 bug 文档第 4 条：佣兵「黄金重骑」同上，硬编码 `+ 7.0`、JSON 无 skill_cd。
	"gold_charge": 7.0,
}


static func _show_poison_stack_detail(d: Dictionary) -> bool:
	return int(d.get("star", 1)) >= 4 or str(d.get("id", "")) not in ["undead_poison", "undead_fly"]


static func skill_cd_text(d: Dictionary) -> String:
	var sid := str(d.get("skill_id", ""))
	if not d.has("skill_cd") and IMPLICIT_SKILL_CD.has(sid):
		var implicit_cd := float(IMPLICIT_SKILL_CD[sid])
		return " (CD %.1fs)" % implicit_cd if is_en() else "（冷却%.1f秒）" % implicit_cd
	if d.has("skill_cd"):
		if is_en():
			return " (CD %.1fs)" % float(d.get("skill_cd", 0.0))
		return "（冷却%.1f秒）" % float(d.get("skill_cd", 0.0))
	return ""

static func pct(value: float) -> String:
	return "%.0f%%" % (value * 100.0)
