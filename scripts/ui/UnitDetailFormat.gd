class_name UnitDetailFormat
extends RefCounted
# 单位详情 / 技能文案格式化（纯静态，无实例状态）。
# 原本只存在于备战链（PrepDetails），但战斗链（BattleScreen -> officetest）继承不到，
# 于是抽到这里两边共用：PrepDetails 保留原方法名改为薄委托，officetest 直接调用。
# 只依赖参数 + 全局单例（LocaleManager / GameState / RaceRelationService）。

static func is_en() -> bool:
	return LocaleManager.get_locale() == "en"

static func localized_name(d: Dictionary) -> String:
	return DataRegistry.unit_display_name(d, is_en())


# 「棋盘唯一」标记。unique_on_board 的棋子（大天使/神王/末日守卫/黑龙/母灵/人王）
# 实测只能上场一只，但图鉴与棋子描述都没写，玩家只能靠试放才发现（9.13 测试反馈）。
# 统一渲染成「名称 N星（唯一）」，图鉴与详情共用这一份文案。
static func unique_suffix(d: Dictionary) -> String:
	if not bool(d.get("unique_on_board", false)):
		return ""
	return " (Unique)" if is_en() else "（唯一）"

static func purchase_price_text(d: Dictionary) -> String:
	if d.has("carrot_cost") and not GameState.tutorial_mode:
		return ("%d carrots" if is_en() else "%d萝卜") % int(d.get("carrot_cost", 0))
	return ("%d G" if is_en() else "%d金") % int(d.get("cost", 0))

static func format_unit_def(d: Dictionary, star: int = 1, cell: Dictionary = {}) -> String:
	if d.is_empty():
		return "No details" if is_en() else "无详情"
	var mul := GameState.star_stat_multiplier(star, d) if not bool(d.get("is_mercenary", false)) else 1.0
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
		detail = "%s ★%d%s\nRace: %s  Element: %s  Tier: %d  Cost: %s\nHP: %d  ATK: %d  DEF: %d\nAS: %.2f  Crit: %.0f%%  CritDmg: %.0f%%\nRange: %s  Speed: %s\n\n[b]Skill[/b]\n%s" % [
			uname, star, uniq,
			race, elem, int(d.get("tier", 0)), purchase_price_text(d),
			int(round(float(d.get("hp", 0)) * mul)), int(skill_def.get("atk", 0)), int(round(float(d.get("def", 0)) * mul)),
			float(d.get("attack_speed", 1.0)), float(d.get("crit", 0.0)) * 100.0, float(d.get("crit_dmg", 1.5)) * 100.0,
			str(d.get("range", 1)), str(d.get("move_speed", 3.0)), skill_text,
		]
	else:
		detail = "%s %d星%s\n种族：%s  属性：%s  阶级：%d  价格：%s\n生命：%d  攻击：%d  防御：%d\n攻速：%.2f  暴击：%.0f%%  暴伤：%.0f%%\n射程：%s  移速：%s\n\n[b]技能效果[/b]\n%s" % [
			uname, star, uniq,
			race, elem, int(d.get("tier", 0)), purchase_price_text(d),
			int(round(float(d.get("hp", 0)) * mul)), int(skill_def.get("atk", 0)), int(round(float(d.get("def", 0)) * mul)),
			float(d.get("attack_speed", 1.0)), float(d.get("crit", 0.0)) * 100.0, float(d.get("crit_dmg", 1.5)) * 100.0,
			str(d.get("range", 1)), str(d.get("move_speed", 3.0)), skill_text,
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
			"mercenary": return "Mercenary"
			"-", "":     return "None"
		return "Unknown"
	match race:
		"god":       return "神"
		"dark":      return "暗"
		"undead":    return "灵"
		"human":     return "人"
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
	var sid := str(d.get("skill_id", "none"))
	var cd := skill_cd_text(d)
	match sid:
		"none":
			return "无主动技能。"
		"lowest_ally_heal":
			return "星辉祈愿%s：治疗生命比例最低的友军，回复其最大生命%s；有%s概率清除负面状态。" % [cd, pct(float(d.get("heal_pct", 0.06))), pct(float(d.get("cleanse_chance", 0.25)))]
		"nearest_ally_bless":
			return "神赐祝福%s：强化最近友军，攻击+%s、攻速+%.2f，并清除负面状态。" % [cd, pct(float(d.get("atk_bonus", 0.12))), float(d.get("aspd_bonus", 0.15))]
		"guardian_shield_taunt":
			return "守护嘲讽：战斗开始获得最大生命%s护盾，并让周围敌人优先攻击自己。" % pct(float(d.get("start_shield_pct", 0.20)))
		"true_damage_attack":
			return "圣枪裁决：普通攻击额外造成自身攻击%s真实伤害。" % pct(float(d.get("true_damage_pct", 0.18)))
		"nearby_ally_heal_buff":
			return "光环治疗%s：治疗自身周围友军最大生命%s，并给攻击+%s、攻速+%.2f，同时清除负面状态；开场冷却%.1f秒。" % [cd, pct(float(d.get("heal_pct", 0.15))), pct(float(d.get("atk_bonus", 0.10))), float(d.get("aspd_bonus", 0.15)), float(d.get("opening_cd", 0.0))]
		"judgement_strike":
			return "审判打击%s：对最近敌人造成自身攻击%s伤害；每次释放自身防御叠加+%s，最多%d层。" % [cd, pct(float(d.get("damage_atk_pct", 2.2))), pct(float(d.get("def_stack_pct", 0.06))), int(d.get("max_stacks", 5))]
		"random_ally_damage_reduction":
			return "天使庇护%s：随机友军获得%s减伤，持续%.1f秒。" % [cd, pct(float(d.get("damage_reduction", 0.50))), float(d.get("duration", 6.0))]
		"global_divine_blast":
			return "神王裁决%s：攻击全场敌人，造成自身攻击%s加目标最大生命%s的伤害。" % [cd, pct(float(d.get("damage_atk_pct", 1.6))), pct(float(d.get("max_hp_bonus_pct", 0.08)))]
		"curse_attack":
			return "诅咒攻击：普通攻击附带减攻%s与攻速降低%s，持续%.1f秒；暗5/暗7会增强。" % [pct(float(d.get("attack_down", 0.08))), pct(float(d.get("aspd_down", 0.08))), float(d.get("duration", 4.0))]
		"silence_bolt":
			return "沉默箭%s：沉默最近敌人%.1f秒，并造成自身攻击%s伤害；暗7会延长持续时间。" % [cd, float(d.get("silence_sec", 1.2)), pct(float(d.get("damage_atk_pct", 1.7)))]
		"fear":
			return "恐惧%s：使最近敌人恐惧/眩晕%.1f秒并推离；暗7会延长持续时间。" % [cd, float(d.get("fear_sec", 1.5))]
		"same_target_damage_stack":
			return "痛苦凝视：持续攻击同一目标时，每层伤害+%s，最多%d层；换目标重置。" % [pct(float(d.get("stack_damage", 0.06))), int(d.get("max_stacks", 5))]
		"blink_low_def_backline":
			return "暗影突袭%s：瞬移到低防后排敌人身边，造成自身攻击%s伤害；击杀后刷新冷却。" % [cd, pct(float(d.get("damage_atk_pct", 2.0)))]
		"stun":
			return "暗影击晕%s：眩晕最近敌人%.1f秒；暗7会延长持续时间。" % [cd, float(d.get("stun_sec", 1.0))]
		"shared_hp_link":
			# 9.14 反馈：4 星连接期间会按每秒 3% 最大生命回血，但文案没写。link_regen_pct
			# 只在 4 星的 star4 覆写里有，1~3 星回血为 0，文案自然不带那句。
			var link_regen := float(d.get("link_regen_pct", 0.0))
			var regen_clause := "；连接期间每秒回%s最大生命" % pct(link_regen) if link_regen > 0.0 else ""
			return "血链%s：连接最近非Boss敌人并使其变为我方棋子；双方共享受到的生命损失%s。任一方死亡后清除连接，本回合不再释放。Boss免疫。" % [cd, regen_clause]
		"black_hole":
			return "黑洞%s：牵引周围敌人，眩晕%.1f秒，并造成自身攻击%s伤害；暗7会延长控制。" % [cd, float(d.get("pull_sec", 2.0)), pct(float(d.get("damage_atk_pct", 2.2)))]
		"poison_attack":
			return "毒击：普通攻击附带中毒，每秒造成目标最大生命%s伤害，持续%.1f秒；灵4毒伤x2。" % [pct(float(d.get("poison_pct_max_hp", 0.03))), float(d.get("poison_duration", 4.0))]
		"parasite_on_kill":
			return "寄生：普攻标记目标；标记目标死亡时召唤该敌人的分身，生命为原目标%s，攻防为原目标%s。" % [pct(float(d.get("clone_hp_pct", 0.10))), pct(float(d.get("clone_atk_def_pct", 0.50)))]
		"defense_down_attack":
			return "腐蚀攻击：普通攻击降低目标防御%s，持续%.1f秒；暗5/暗7会增强。" % [pct(float(d.get("def_down_pct", 0.10))), float(d.get("duration", 5.0))]
		"death_poison_explosion":
			return "死亡毒爆：死亡时对周围敌人造成自身攻击%s真实伤害，并施加中毒。" % pct(float(d.get("damage_atk_pct", 2.5)))
		"poison_reflect_armor_stack":
			return "毒甲：受伤后反弹本次伤害%s真实伤害并使攻击者中毒；自身防御每次+%s，最多%d层。" % [pct(float(d.get("reflect_taken_damage_pct", 0.12))), pct(float(d.get("armor_per_hit_pct", 0.14))), int(d.get("max_stacks", 10))]
		"unique_death_execute":
			# 9.14：文案把所有可调数值都改成读 def，1~3 星与 4 星自动显示各自那一份。
			# 灵7 的阈值 = ceil(阈值 × 0.75)（SynergyService.undead_threshold_mul），
			# 所以 1~3 星 5 死→4 死、4 星 4 死→3 死，与实测一致。
			var m_th := int(d.get("death_threshold", 5))
			var m_t1 := float(d.get("tier1_or_merc_chance", 0.5))
			var m_t2 := float(d.get("tier2_chance", 0.35))
			var m_t3 := float(d.get("tier3_chance", 0.1))
			var m_boss := float(d.get("boss_max_hp_damage", 0.2))
			var m_u7 := int(ceil(float(m_th) * 0.75))
			return "母灵：每名玩家最多1只；3v3中多个玩家的母灵可同时生效且各自独立计数。每%d个非母灵处决造成的敌军死亡触发一次；1阶/佣兵%s、2阶%s、3阶%s即死，Boss改为%s最大生命伤害。灵7改为每%d个死亡触发。" % [m_th, pct(m_t1), pct(m_t2), pct(m_t3), pct(m_boss), m_u7]
		"attack_interrupt":
			# 9.14：4 星把「打断」（锁普攻 1 秒）换成「眩晕」0.5 秒 —— stun_sec 只写在
			# 4 星 star4 覆写里。文案按有无 stun_sec 分两支，与 BattleSimulator 的实现同源。
			var militia_stun := float(d.get("stun_sec", 0.0))
			if militia_stun > 0.0:
				return "缴械攻击：普通攻击有%s概率眩晕目标%.1f秒。" % [pct(float(d.get("interrupt_chance", 0.12))), militia_stun]
			return "缴械攻击：普通攻击有%s概率缴械目标（1 秒内无法普攻）。" % pct(float(d.get("interrupt_chance", 0.12)))
		"post_battle_gold_by_star":
			return "战后经商：参与战斗后，按星级获得金币。1星+10，2星+20，3星+30，4星+40。"
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
				return "死侍契约：周围一圈友军防御+%s持续%.1f秒；战斗开始绑定左右两侧棋子，其中先死亡的棋子首次阵亡时由死侍代替其死亡并使其满血复活（死侍仅能牺牲一次）。" % [pct(ds_pct), ds_dur]
			return "死侍契约：周围一圈友军防御+%d持续%.1f秒；战斗开始绑定左侧棋子，该棋子首次死亡时死侍代替其死亡并使其满血复活。" % [int(d.get("ally_def_bonus", 3)), ds_dur]
		"unique_king_growth":
			# 9.14：1~3 星成长 ×1.2、上限 5 层；4 星 ×1.3、上限 8 层。两者都写进文案，
			# 数值全部读 def（apply_star_stats 会把 star4 的 0.3 / 8 覆盖上来）。
			var king_growth := float(d.get("post_battle_all_stat_growth", 0.20))
			var king_cap := int(d.get("max_stacks", 5))
			return "人王唯一技：棋盘上只能存在一只人王。若参战且战后仍存活，全属性永久x%.1f（上限%d层）；若死亡则从棋盘移除；升星继承三只材料中成长最高的人王数值。" % [1.0 + king_growth, king_cap]
		"balance_judge":
			return "均衡裁决：攻击当前生命高于自己的目标时，伤害+%s。" % pct(float(d.get("bonus_vs_higher_hp", 0.40)))
		"bubble_dream":
			return "泡沫梦境%s：治疗最低血友军%d点，并使最近敌人减速%s、受到%d点真实伤害。" % [cd, int(d.get("heal", 80)), pct(float(d.get("slow_pct", 0.30))), int(d.get("burst_damage", 70))]
		"shell_guard":
			return "甲壳守护：获得%s减伤，持续%.1f秒。" % [pct(float(d.get("reduction", 0.50))), float(d.get("duration", 5.0))]
		"gold_charge":
			return "黄金冲锋%s：冲向最近敌人，造成%d点真实伤害并眩晕%.1f秒。" % [cd, int(d.get("skill_damage", 120)), float(d.get("stun_sec", 1.2))]
		"holy_song":
			return "圣歌%s：治疗全体友军最大生命%s，并清除控制类负面状态。" % [cd, pct(float(d.get("heal_pct", 0.15)))]
		"twin_strike":
			return "镜像突袭%s：召唤自身镜像，镜像生命%s、攻击%s。" % [cd, pct(float(d.get("clone_hp_pct", 0.30))), pct(float(d.get("clone_atk_pct", 0.40)))]
		"king_aura":
			return "王者光环：每2秒强化周围友军，攻速+%s、暴击+%s。" % [pct(float(d.get("ally_aspd_bonus", 0.25))), pct(float(d.get("ally_crit_bonus", 0.15)))]
		"arrow_rain":
			return "箭雨%s：攻击最近%d名敌人，每个目标受到自身攻击85%%伤害。" % [cd, int(d.get("targets", 5))]
		"blood_rampage":
			return "血怒：每损失%s最大生命，攻速+%s、吸血+%s，并获得少量伤害提升。" % [pct(float(d.get("hp_step", 0.10))), pct(float(d.get("aspd_per_step", 0.10))), pct(float(d.get("lifesteal_per_step", 0.05)))]
		"steel_order":
			return "钢铁号令%s：强化最近%d名友军，减伤%s、攻速+%s、控制时间降低%s，持续%.1f秒。" % [cd, int(d.get("buff_targets", 3)), pct(float(d.get("damage_reduction", 0.20))), pct(float(d.get("aspd_bonus", 0.20))), pct(float(d.get("control_time_reduction", 0.30))), float(d.get("duration", 8.0))]
		"time_slow":
			return "时空迟缓%s：自身短暂闪避提高，并使全体敌人减速%s，持续%.1f秒。" % [cd, pct(float(d.get("slow_pct", 0.35))), float(d.get("duration", 5.0))]
		"death_hunt":
			return "冥界处决：优先攻击低血目标；击杀回复最大生命%s。普攻破甲%d并降低治疗%s，持续%.1f秒。" % [pct(float(d.get("kill_heal_pct", 0.15))), int(d.get("armor_break", 8)), pct(float(d.get("heal_reduction", 0.50))), float(d.get("duration", 4.0))]
		# --- Boss ---
		"element_meteor":
			return "陨星轰击%s：召唤陨星砸向最近的敌人，对其与周围敌人造成 %d 点真实伤害，并附加自身属性效果。" % [cd, int(d.get("skill_damage", 240))]
		"overload_counter":
			return "过载反击：每承受 %d 次攻击后释放一次过载，对攻击者造成 %d 点真实伤害，并有 %s 概率打断其攻击。" % [int(d.get("hit_threshold", 8)), int(d.get("skill_damage", 300)), pct(float(d.get("interrupt_chance", 0.25)))]
		"mirror_clone":
			return "镜像分裂：自身每损失 %s 最大生命就分裂出一个镜像；镜像生命为本体最大生命 %s、攻击为本体 %s，且不会释放技能。" % [pct(float(d.get("clone_per_missing_hp_pct", 0.25))), pct(float(d.get("clone_hp_pct", 0.30))), pct(float(d.get("clone_atk_pct", 0.40)))]
		"holy_purify":
			return "圣愈净化%s：清除全体友军身上的所有状态，治疗其最大生命 %s，并给予最大生命 %s 的护盾。" % [cd, pct(float(d.get("heal_pct", 0.12))), pct(float(d.get("shield_pct", 0.10)))]
		"rage_stack":
			return "狂怒叠加：每次普通攻击命中后攻击 +%s、攻速 +%.2f，最多叠加 %d 层。" % [pct(float(d.get("atk_per_hit", 0.03))), float(d.get("aspd_per_hit", 0.03)), int(d.get("max_stacks", 20))]
		"blood_rage":
			return "血怒暴走：生命降至 %s 以下时永久进入暴走，攻击 +%s、攻速 +%.2f，并获得 %s 吸血。" % [pct(float(d.get("trigger_hp_pct", 0.35))), pct(float(d.get("atk_bonus", 0.40))), float(d.get("aspd_bonus", 0.30)), pct(float(d.get("lifesteal", 0.10)))]
		"soul_devour":
			return "噬魂：每击杀一个目标，回复自身最大生命 %s，并永久提升攻击 %s。" % [pct(float(d.get("kill_heal_pct", 0.15))), pct(float(d.get("atk_stack", 0.10)))]
		"twin_revive":
			return "双生复活：双子同时登场。任一方死亡后 %.1f 秒以 %s 生命复活，每只最多复活 %d 次；若同伴已全部阵亡则不再复活。" % [float(d.get("revive_delay", 5.0)), pct(float(d.get("revive_hp_pct", 0.30))), int(d.get("revives_per_twin", 1))]
		"apocalypse_charge":
			return "灭世蓄力%s：先获得最大生命 %s 的护盾并蓄力 %.1f 秒，随后对全场敌人造成自身攻击 %s 的伤害%s；蓄力期间护盾被打破则中断。" % [cd, pct(float(d.get("charge_shield_pct", 0.10))), float(d.get("charge_sec", 2.0)), pct(float(d.get("damage_atk_pct", 2.5))), "（无视防御）" if bool(d.get("ignore_def", true)) else ""]
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
		"none":
			return "No active skill."
		"lowest_ally_heal":
			return "Starlight Prayer%s: Heal the ally with the lowest HP ratio by %s of their max HP; %s chance to cleanse debuffs." % [cd, pct(float(d.get("heal_pct", 0.06))), pct(float(d.get("cleanse_chance", 0.25)))]
		"nearest_ally_bless":
			return "Divine Blessing%s: Buff the nearest ally — ATK +%s, AS +%.2f — and cleanse their debuffs." % [cd, pct(float(d.get("atk_bonus", 0.12))), float(d.get("aspd_bonus", 0.15))]
		"guardian_shield_taunt":
			return "Guardian Taunt: Gain a shield equal to %s max HP at battle start; force nearby enemies to target this unit." % pct(float(d.get("start_shield_pct", 0.20)))
		"true_damage_attack":
			return "Holy Lance: Normal attacks deal bonus true damage equal to %s ATK." % pct(float(d.get("true_damage_pct", 0.18)))
		"nearby_ally_heal_buff":
			return "Halo Heal%s: Heal nearby allies for %s max HP; grant ATK +%s and AS +%.2f and cleanse debuffs; initial cooldown %.1fs." % [cd, pct(float(d.get("heal_pct", 0.15))), pct(float(d.get("atk_bonus", 0.10))), float(d.get("aspd_bonus", 0.15)), float(d.get("opening_cd", 0.0))]
		"judgement_strike":
			return "Judgement Strike%s: Deal %s ATK damage to the nearest enemy; each cast permanently stacks own DEF +%s (max %d stacks)." % [cd, pct(float(d.get("damage_atk_pct", 2.2))), pct(float(d.get("def_stack_pct", 0.06))), int(d.get("max_stacks", 5))]
		"random_ally_damage_reduction":
			return "Angel's Guard%s: Grant a random ally %s damage reduction for %.1fs." % [cd, pct(float(d.get("damage_reduction", 0.50))), float(d.get("duration", 6.0))]
		"global_divine_blast":
			return "Divine Judgement%s: Strike all enemies for %s ATK + %s of their max HP as damage." % [cd, pct(float(d.get("damage_atk_pct", 1.6))), pct(float(d.get("max_hp_bonus_pct", 0.08)))]
		"curse_attack":
			return "Curse Strike: Normal attacks reduce target ATK by %s and AS by %s for %.1fs. Dark 5/7 amplify these debuffs." % [pct(float(d.get("attack_down", 0.08))), pct(float(d.get("aspd_down", 0.08))), float(d.get("duration", 4.0))]
		"silence_bolt":
			return "Silence Bolt%s: Silence the nearest enemy for %.1fs and deal %s ATK damage. Dark 7 extends duration." % [cd, float(d.get("silence_sec", 1.2)), pct(float(d.get("damage_atk_pct", 1.7)))]
		"fear":
			return "Fear%s: Frighten/stun the nearest enemy for %.1fs and knock them back. Dark 7 extends duration." % [cd, float(d.get("fear_sec", 1.5))]
		"same_target_damage_stack":
			return "Agonizing Gaze: Consecutive attacks on the same target deal +%s damage per stack (max %d stacks). Resets on target switch." % [pct(float(d.get("stack_damage", 0.06))), int(d.get("max_stacks", 5))]
		"blink_low_def_backline":
			return "Shadow Ambush%s: Blink to the lowest-DEF backline enemy and deal %s ATK damage. Cooldown resets on kill." % [cd, pct(float(d.get("damage_atk_pct", 2.0)))]
		"stun":
			return "Shadow Stun%s: Stun the nearest enemy for %.1fs. Dark 7 extends duration." % [cd, float(d.get("stun_sec", 1.0))]
		"shared_hp_link":
			# 9.14: 4-star regenerates 3% max HP/s while linked; only 4-star sets
			# link_regen_pct, so 1-3 star text stays without the clause.
			var link_regen := float(d.get("link_regen_pct", 0.0))
			var regen_clause := "; regenerate %s max HP per second while linked" % pct(link_regen) if link_regen > 0.0 else ""
			return "Blood Chain%s: Link to the nearest non-Boss enemy and convert them to your side. Both share HP loss%s. Link breaks on either death and will not reactivate this round. Boss immune." % [cd, regen_clause]
		"black_hole":
			return "Black Hole%s: Pull surrounding enemies, stun for %.1fs, and deal %s ATK damage. Dark 7 extends the stun." % [cd, float(d.get("pull_sec", 2.0)), pct(float(d.get("damage_atk_pct", 2.2)))]
		"poison_attack":
			return "Poison Strike: Normal attacks apply poison — %s max HP per second for %.1fs. Undead 4 doubles poison damage." % [pct(float(d.get("poison_pct_max_hp", 0.03))), float(d.get("poison_duration", 4.0))]
		"parasite_on_kill":
			return "Parasite: Mark targets with normal attacks. When a marked target dies, summon its clone at %s HP and %s ATK/DEF." % [pct(float(d.get("clone_hp_pct", 0.10))), pct(float(d.get("clone_atk_def_pct", 0.50)))]
		"defense_down_attack":
			return "Corrosive Strike: Normal attacks reduce target DEF by %s for %.1fs. Dark 5/7 amplify this effect." % [pct(float(d.get("def_down_pct", 0.10))), float(d.get("duration", 5.0))]
		"death_poison_explosion":
			return "Death Poison Burst: On death, deal %s ATK true damage to surrounding enemies and apply poison." % pct(float(d.get("damage_atk_pct", 2.5)))
		"poison_reflect_armor_stack":
			return "Toxic Armor: On taking damage, reflect %s as true damage and poison the attacker. Own DEF stacks +%s per hit (max %d stacks)." % [pct(float(d.get("reflect_taken_damage_pct", 0.12))), pct(float(d.get("armor_per_hit_pct", 0.14))), int(d.get("max_stacks", 10))]
		"unique_death_execute":
			var m_th := int(d.get("death_threshold", 5))
			var m_t1 := float(d.get("tier1_or_merc_chance", 0.5))
			var m_t2 := float(d.get("tier2_chance", 0.35))
			var m_t3 := float(d.get("tier3_chance", 0.1))
			var m_boss := float(d.get("boss_max_hp_damage", 0.2))
			var m_u7 := int(ceil(float(m_th) * 0.75))
			return "Matron: each player can field 1; in 3v3, each player's Matron works at the same time and counts independently. Every %d enemy deaths not caused by Matron execute: Tier 1/Merc %s, Tier 2 %s, Tier 3 %s; vs Boss deal %s max HP instead. Undead 7: every %d deaths." % [m_th, pct(m_t1), pct(m_t2), pct(m_t3), pct(m_boss), m_u7]
		"attack_interrupt":
			var militia_stun := float(d.get("stun_sec", 0.0))
			if militia_stun > 0.0:
				return "Disarm Strike: Normal attacks have a %s chance to stun the target for %.1fs." % [pct(float(d.get("interrupt_chance", 0.12))), militia_stun]
			return "Disarm Strike: Normal attacks have a %s chance to disarm the target (cannot use normal attacks for 1s)." % pct(float(d.get("interrupt_chance", 0.12)))
		"post_battle_gold_by_star":
			return "Trade: After each battle, gain gold by star level (★1 → +10G, ★2 → +20G, ★3 → +30G, ★4 → +40G)."
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
				return "Death Pact: Grant surrounding allies DEF +%s for %.1fs. At battle start, bind to both neighbours — whichever of them dies first is revived at full HP by this unit sacrificing itself (it can only sacrifice once)." % [pct(ds_pct), ds_dur]
			return "Death Pact: Grant surrounding allies DEF +%d for %.1fs. At battle start, bind to the left neighbour — when that unit first dies, this unit sacrifices itself in their place, reviving them at full HP." % [int(d.get("ally_def_bonus", 3)), ds_dur]
		"unique_king_growth":
			var king_growth := float(d.get("post_battle_all_stat_growth", 0.20))
			var king_cap := int(d.get("max_stacks", 5))
			return "Human King Unique (one on board): If this unit survives a battle, all stats permanently ×%.1f (cap %d stacks). If it dies, it is removed from the board. On upgrade, inherit the highest growth value from the three materials." % [1.0 + king_growth, king_cap]
		"balance_judge":
			return "Balance Judgement: Deal +%s damage against targets with more current HP than this unit." % pct(float(d.get("bonus_vs_higher_hp", 0.40)))
		"bubble_dream":
			return "Bubble Dream%s: Heal the lowest-HP ally for %d HP; slow the nearest enemy by %s and deal %d true damage." % [cd, int(d.get("heal", 80)), pct(float(d.get("slow_pct", 0.30))), int(d.get("burst_damage", 70))]
		"shell_guard":
			return "Shell Guard: Gain %s damage reduction for %.1fs." % [pct(float(d.get("reduction", 0.50))), float(d.get("duration", 5.0))]
		"gold_charge":
			return "Gold Charge%s: Rush the nearest enemy, deal %d true damage and stun for %.1fs." % [cd, int(d.get("skill_damage", 120)), float(d.get("stun_sec", 1.2))]
		"holy_song":
			return "Holy Song%s: Heal all allies for %s max HP and cleanse all crowd-control debuffs." % [cd, pct(float(d.get("heal_pct", 0.15)))]
		"twin_strike":
			return "Mirror Ambush%s: Summon a mirror clone with %s HP and %s ATK." % [cd, pct(float(d.get("clone_hp_pct", 0.30))), pct(float(d.get("clone_atk_pct", 0.40)))]
		"king_aura":
			return "King's Aura: Every 2s, buff nearby allies — AS +%s, Crit +%s." % [pct(float(d.get("ally_aspd_bonus", 0.25))), pct(float(d.get("ally_crit_bonus", 0.15)))]
		"arrow_rain":
			return "Arrow Rain%s: Strike the nearest %d enemies, each taking 85%% ATK damage." % [cd, int(d.get("targets", 5))]
		"blood_rampage":
			return "Blood Rage: For every %s max HP lost, gain AS +%s and Lifesteal +%s plus a small damage boost." % [pct(float(d.get("hp_step", 0.10))), pct(float(d.get("aspd_per_step", 0.10))), pct(float(d.get("lifesteal_per_step", 0.05)))]
		"steel_order":
			return "Steel Order%s: Buff the nearest %d allies — DMG Reduce %s, AS +%s, CC Duration -%s for %.1fs." % [cd, int(d.get("buff_targets", 3)), pct(float(d.get("damage_reduction", 0.20))), pct(float(d.get("aspd_bonus", 0.20))), pct(float(d.get("control_time_reduction", 0.30))), float(d.get("duration", 8.0))]
		"time_slow":
			return "Time Warp%s: Briefly boost own dodge; slow all enemies by %s for %.1fs." % [cd, pct(float(d.get("slow_pct", 0.35))), float(d.get("duration", 5.0))]
		"death_hunt":
			return "Death Hunt: Prioritizes low-HP targets; kills restore %s max HP. Normal attacks break %d armor and reduce healing by %s for %.1fs." % [pct(float(d.get("kill_heal_pct", 0.15))), int(d.get("armor_break", 8)), pct(float(d.get("heal_reduction", 0.50))), float(d.get("duration", 4.0))]
		# --- Boss ---
		"element_meteor":
			return "Meteor Strike%s: Call a meteor down on the nearest enemy, dealing %d true damage to it and nearby enemies plus this unit's element effect." % [cd, int(d.get("skill_damage", 240))]
		"overload_counter":
			return "Overload Counter: After taking %d hits, discharge for %d true damage to the attacker with a %s chance to interrupt them." % [int(d.get("hit_threshold", 8)), int(d.get("skill_damage", 300)), pct(float(d.get("interrupt_chance", 0.25)))]
		"mirror_clone":
			return "Mirror Split: For every %s of max HP lost, split off a mirror image with %s of max HP and %s ATK. Clones cannot cast skills." % [pct(float(d.get("clone_per_missing_hp_pct", 0.25))), pct(float(d.get("clone_hp_pct", 0.30))), pct(float(d.get("clone_atk_pct", 0.40)))]
		"holy_purify":
			return "Holy Purify%s: Cleanse all statuses from every ally, heal them for %s max HP and grant a shield worth %s max HP." % [cd, pct(float(d.get("heal_pct", 0.12))), pct(float(d.get("shield_pct", 0.10)))]
		"rage_stack":
			return "Rage Stacks: Each landed normal attack grants ATK +%s and AS +%.2f, up to %d stacks." % [pct(float(d.get("atk_per_hit", 0.03))), float(d.get("aspd_per_hit", 0.03)), int(d.get("max_stacks", 20))]
		"blood_rage":
			return "Blood Frenzy: Below %s HP, permanently enrage — ATK +%s, AS +%.2f, and %s lifesteal." % [pct(float(d.get("trigger_hp_pct", 0.35))), pct(float(d.get("atk_bonus", 0.40))), float(d.get("aspd_bonus", 0.30)), pct(float(d.get("lifesteal", 0.10)))]
		"soul_devour":
			return "Soul Devour: Each kill restores %s max HP and permanently raises ATK by %s." % [pct(float(d.get("kill_heal_pct", 0.15))), pct(float(d.get("atk_stack", 0.10)))]
		"twin_revive":
			return "Twin Revival: The twins enter together. When one dies it revives after %.1fs at %s HP, up to %d time(s); no revival happens once every twin is dead." % [float(d.get("revive_delay", 5.0)), pct(float(d.get("revive_hp_pct", 0.30))), int(d.get("revives_per_twin", 1))]
		"apocalypse_charge":
			return "Apocalypse Charge%s: Gain a shield worth %s max HP and charge for %.1fs, then hit all enemies for %s ATK%s. Breaking the shield before it lands interrupts the cast." % [cd, pct(float(d.get("charge_shield_pct", 0.10))), float(d.get("charge_sec", 2.0)), pct(float(d.get("damage_atk_pct", 2.5))), " (ignores DEF)" if bool(d.get("ignore_def", true)) else ""]
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


static func skill_cd_text(d: Dictionary) -> String:
	if str(d.get("skill_id", "")) == "black_hole" and not d.has("skill_cd"):
		return " (CD 8.0s)" if is_en() else "（冷却8.0秒）"
	if d.has("skill_cd"):
		if is_en():
			return " (CD %.1fs)" % float(d.get("skill_cd", 0.0))
		return "（冷却%.1f秒）" % float(d.get("skill_cd", 0.0))
	return ""

static func pct(value: float) -> String:
	return "%.0f%%" % (value * 100.0)
