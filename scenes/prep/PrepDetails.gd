extends "res://scenes/prep/PrepBoardController.gd"

const RACE_LOGO_PATHS := {
	"god": "res://assets/ui/race_logos/god.png",
	"dark": "res://assets/ui/race_logos/dark.png",
	"undead": "res://assets/ui/race_logos/undead.png",
	"human": "res://assets/ui/race_logos/human.png",
}

# ─── locale helpers ───────────────────────────────────────────────────────────

func _is_en() -> bool:
	return UnitDetailFormat.is_en()

func _localized_name(d: Dictionary) -> String:
	return UnitDetailFormat.localized_name(d)

# ─── synergy widgets ──────────────────────────────────────────────────────────

func _add_current_synergy_widgets() -> void:
	var counts := SynergyService.count_races_from_board()
	var shown := false
	for race in ["god", "dark", "undead", "human"]:
		var count := int(counts.get(race, 0))
		if count <= 0:
			continue
		var max_threshold := _race_synergy_max_threshold(race)
		if max_threshold <= 0:
			continue
		shown = true
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(220, 58)
		row.add_theme_constant_override("separation", 12)
		_left_panel.add_child(row)

		var logo := Button.new()
		logo.custom_minimum_size = Vector2(54, 54)
		logo.focus_mode = Control.FOCUS_NONE
		logo.text = ""
		if _is_en():
			logo.tooltip_text = "%s Bond %d/%d" % [_race_name(race), count, max_threshold]
		else:
			logo.tooltip_text = "%s族羁绊 %d/%d" % [_race_name(race), count, max_threshold]
		_apply_empty_button_styles(logo)
		var effect_logo: Control = PrepShopRaceIcon.new()
		effect_logo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		effect_logo.call("set_race", race)
		logo.add_child(effect_logo)
		logo.pressed.connect(_show_text_detail.bind(_format_synergy_detail(race, count)))
		row.add_child(logo)

		var count_label := Label.new()
		count_label.text = "%d/%d" % [count, max_threshold]
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		count_label.add_theme_font_size_override("font_size", 18)
		count_label.add_theme_color_override("font_color", Color(0.94, 0.94, 0.90))
		count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(count_label)
	if not shown:
		var none := Label.new()
		none.text = "No units on board" if _is_en() else "棋盘上没有普通棋子"
		none.modulate = Color(0.55, 0.55, 0.55)
		_left_panel.add_child(none)

func _add_power_recommendation_widgets() -> void:
	pass

# ─── power recommendation ─────────────────────────────────────────────────────

func _show_power_recommendation() -> void:
	if _detail == null or _detail_text == null:
		return
	_gold_interest_detail_open = false
	_detail_text.custom_minimum_size = Vector2(400, 210)
	if _is_en():
		_detail_text.text = "[b]Power Rating[/b]\n[b]Next battle: %s[/b]\n\n%s\nYours: %s\n\nFormula: Effective HP + 10s damage output" % [
			_next_round_kind_label(),
			_next_enemy_power_text(),
			_format_power(_current_player_power()),
		]
	else:
		_detail_text.text = "[b]战力推荐[/b]\n[b]下一战：%s[/b]\n\n%s\n己方当前：%s\n\n计算：有效生命 + 10秒输出" % [
			_next_round_kind_label(),
			_next_enemy_power_text(),
			_format_power(_current_player_power()),
		]
	_detail_waiting_for_release = false
	_detail_release_seen_press = false
	_detail.popup_centered(Vector2i(440, 240))

# ─── battle stats ─────────────────────────────────────────────────────────────

func _show_last_battle_stats() -> void:
	if _stats_popup == null or _stats_text == null:
		return
	if GameState.battle_history.is_empty():
		_stats_text.text = "[b]%s[/b]\n\n%s" % [tr("stats_title"), tr("stats_no_history")]
		_stats_popup.popup_centered(Vector2i(960, 500))
		return
	_stats_group = "player"
	_refresh_stats_popup()
	_stats_popup.popup_centered(Vector2i(960, 500))

func _set_stats_group(group: String) -> void:
	_stats_group = group
	_refresh_stats_popup()

func _refresh_stats_popup() -> void:
	if _stats_text == null:
		return
	var result := _last_battle_result_for_stats()
	var stats_value = result.get("unit_stats", {})
	if typeof(stats_value) != TYPE_DICTIONARY or (stats_value as Dictionary).is_empty():
		_stats_text.text = "[b]%s[/b]\n\n%s" % [tr("stats_title"), tr("stats_no_data")]
		return
	var stats: Dictionary = stats_value
	var rows: Array[Dictionary] = []
	for uid in stats.keys():
		var entry_value = stats[uid]
		if typeof(entry_value) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_value
		if _entry_stats_group(entry) == _stats_group:
			rows.append(entry)
	# Highest damage dealt first; ties fall back to position/name for a stable order.
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da := int(a.get("damage_dealt", 0))
		var db := int(b.get("damage_dealt", 0))
		if da != db:
			return da > db
		return "%s%s" % [str(a.get("position", "")), str(a.get("name", ""))] < "%s%s" % [str(b.get("position", "")), str(b.get("name", ""))]
	)
	var lines: Array[String] = []
	var none_text := tr("none")
	lines.append("[b]%s - %s[/b]" % [tr("stats_last_battle"), _stats_group_label(_stats_group)])
	lines.append("")
	lines.append("[table=7]")
	for header in [tr("stats_h_unit"), tr("stats_h_pos"), tr("stats_h_dmg_dealt"), tr("stats_h_dmg_taken"), tr("stats_h_healing"), tr("stats_h_debuffs"), tr("stats_h_buffs")]:
		lines.append("[cell][b]%s[/b][/cell]" % header)
	if rows.is_empty():
		for value in [none_text, none_text, "0", "0", "0", none_text, none_text]:
			lines.append("[cell]%s[/cell]" % value)
	else:
		for row in rows:
			for value in [
				_stats_display_name(row),
				_stats_display_position(row),
				int(row.get("damage_dealt", 0)),
				int(row.get("damage_taken", 0)),
				int(row.get("healing_done", 0)),
				_sanitize_stats_cell(_format_status_bucket(row.get("debuffs", {}))),
				_sanitize_stats_cell(_format_status_bucket(row.get("buffs", {}))),
			]:
				lines.append("[cell]%s[/cell]" % _stats_color_cell(row, str(value)))
	lines.append("[/table]")
	_stats_text.text = "\n".join(lines)

func _last_battle_result_for_stats() -> Dictionary:
	if GameState.battle_history.is_empty():
		return {}
	var last = GameState.battle_history.back()
	return last if typeof(last) == TYPE_DICTIONARY else {}

func _stats_group_label(group: String) -> String:
	if _is_en():
		match group:
			"player": return "Player"
			"enemy":  return "Enemy"
			"boss":   return "Boss"
		return group
	match group:
		"player": return "我方"
		"enemy":  return "敌方"
		"boss":   return "Boss"
	return group

func _entry_stats_group(entry: Dictionary) -> String:
	return BattleStatsFormat.entry_stats_group(entry)

func _stats_display_name(row: Dictionary) -> String:
	return BattleStatsFormat.stats_display_name(row)

func _stats_display_position(row: Dictionary) -> String:
	return BattleStatsFormat.stats_display_position(row)

func _stats_color_cell(row: Dictionary, text: String) -> String:
	return BattleStatsFormat.stats_color_cell(row, text)

func _sanitize_stats_cell(text: String) -> String:
	return BattleStatsFormat.sanitize_stats_cell(text)

func _format_status_bucket(value: Variant) -> String:
	return BattleStatsFormat.format_status_bucket(value)

func _format_seconds(seconds: float) -> String:
	return BattleStatsFormat.format_seconds(seconds)

func _status_display_name(kind: String) -> String:
	return BattleStatsFormat.status_display_name(kind)

# ─── power / enemy estimate ───────────────────────────────────────────────────

func _current_player_power() -> float:
	var total := 0.0
	for cell in GameState.board_slots:
		if cell == null or typeof(cell) != TYPE_DICTIONARY:
			continue
		var dict: Dictionary = cell
		var d: Dictionary = dict.get("def", {}).duplicate(true)
		if d.is_empty():
			continue
		if not bool(dict.get("is_mercenary", false)):
			d = UnitFactory.apply_star_stats(d, int(dict.get("star", 1)))
		total += _unit_power_from_def(d)
	return total

func _next_round_kind() -> String:
	# Team mode follows the fixed schedule; solo turns unmatched PvP rounds into PvE.
	if GameState.team_mode:
		return RoundService.schedule_kind_for_round(GameState.round_index)
	return RoundService.kind_for_round(GameState.round_index, NetworkService.has_online_opponent())

func _next_round_kind_label() -> String:
	var kind := _next_round_kind()
	if _is_en():
		match kind:
			"pvp":   return "PVP"
			"final": return "Final PVP"
			"boss":  return "Boss"
			_:       return "PVE (minions)"
	match kind:
		"pvp":   return "PVP 对战"
		"final": return "最终 PVP"
		"boss":  return "Boss 战"
		_:       return "PVE 小怪"

func _next_enemy_power_text() -> String:
	var kind := _next_round_kind()
	if _is_en():
		match kind:
			"pvp":   return "Next: PVP — opponent power hidden"
			"final": return "Next: Final PVP — opponent power hidden"
			"boss":
				return "Next Boss ~%s" % _format_power(_estimated_boss_power())
			_:
				var count_by_round: Dictionary = DataRegistry.get_table("pve_monsters").get("enemy_count_by_round", {})
				var count := int(count_by_round.get(str(GameState.round_index), 3))
				return "Next wave ~%s (%d units)" % [_format_power(_estimated_pve_power(count)), count]
	match kind:
		"pvp":   return "下一战：PVP，不显示对方战力"
		"final": return "下一战：最终PVP，不显示对方战力"
		"boss":  return "下一战Boss约：%s" % _format_power(_estimated_boss_power())
		_:
			var count_by_round: Dictionary = DataRegistry.get_table("pve_monsters").get("enemy_count_by_round", {})
			var count := int(count_by_round.get(str(GameState.round_index), 3))
			return "下一波小怪约：%s（%d只）" % [_format_power(_estimated_pve_power(count)), count]

func _estimated_pve_power(count: int) -> float:
	var monsters: Array = DataRegistry.get_table("pve_monsters").get("monsters", [])
	if monsters.is_empty() or count <= 0:
		return 0.0
	var growth := PveService.growth_for_completed(GameState.pve_completed)
	var total := 0.0
	for monster in monsters:
		if typeof(monster) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (monster as Dictionary).duplicate(true)
		d.hp = maxi(1, int(round(float(d.get("hp", 1)) * float(growth.hp))))
		d.atk = maxi(1, int(round(float(d.get("atk", 1)) * float(growth.atk))))
		d.def = maxi(0, int(round(float(d.get("def", 0)) * float(growth.def))))
		if d.has("skill_damage"):
			d.skill_damage = maxi(1, int(round(float(d.get("skill_damage", 0)) * float(growth.skill_damage))))
		total += _unit_power_from_def(d) * float(count)
	return total / float(monsters.size())

func _estimated_boss_power() -> float:
	var bosses: Array = DataRegistry.get_table("bosses").get("bosses", [])
	if bosses.is_empty():
		return 0.0
	var growth := BossService.growth_for_completed(GameState.boss_completed)
	var boss_mul := BossService.GLOBAL_STAT_MULTIPLIER
	var total := 0.0
	var counted := 0
	for boss in bosses:
		if typeof(boss) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (boss as Dictionary).duplicate(true)
		d.hp = maxi(1, int(round(float(d.get("hp", 1)) * float(growth.hp) * boss_mul)))
		d.atk = maxi(1, int(round(float(d.get("atk", 1)) * float(growth.atk) * boss_mul)))
		d.def = maxi(0, int(round(float(d.get("def", 0)) * float(growth.def) * boss_mul)))
		var unit_total := _unit_power_from_def(d)
		if bool(d.get("is_twin", false)):
			unit_total *= 2.0
		total += unit_total
		counted += 1
	return 0.0 if counted <= 0 else total / float(counted)

func _unit_power_from_def(d: Dictionary) -> float:
	var hp := float(d.get("hp", 0))
	var atk := float(d.get("atk", 0))
	var defense := float(d.get("def", d.get("defense", 0)))
	var attack_speed := float(d.get("attack_speed", 1.0))
	var crit := float(d.get("crit", 0.0))
	var crit_dmg := float(d.get("crit_dmg", 1.5))
	var effective_hp := hp * (1.0 + defense / 50.0)
	var basic_dps := atk * attack_speed * (1.0 + crit * maxf(0.0, crit_dmg - 1.0))
	var skill_dps := _skill_dps_from_def(d, atk)
	return effective_hp + (basic_dps + skill_dps) * 10.0

func _skill_dps_from_def(d: Dictionary, atk: float) -> float:
	var cd := float(d.get("skill_cd", d.get("default_skill_cd", 8.0)))
	if cd <= 0.0:
		return 0.0
	if d.has("skill_damage"):
		return float(d.get("skill_damage", 0)) / cd
	if d.has("damage_atk_pct"):
		return atk * float(d.get("damage_atk_pct", 0.0)) / cd
	if d.has("skill_atk_pct"):
		return atk * float(d.get("skill_atk_pct", 0.0)) / cd
	return 0.0

func _format_power(value: float) -> String:
	var rounded := int(round(value))
	if _is_en():
		if rounded >= 100000000:
			return "%.2fB" % (float(rounded) / 100000000.0)
		if rounded >= 10000:
			return "%.2fK" % (float(rounded) / 1000.0)
		return str(rounded)
	if rounded >= 100000000:
		return "%.2f亿" % (float(rounded) / 100000000.0)
	if rounded >= 10000:
		return "%.2f万" % (float(rounded) / 10000.0)
	return str(rounded)

# ─── race names ───────────────────────────────────────────────────────────────

func _race_name(race: String) -> String:
	if _is_en():
		match race:
			"god":    return "God"
			"dark":   return "Dark"
			"undead": return "Undead"
			"human":  return "Human"
		return race
	match race:
		"god":    return "神"
		"dark":   return "暗"
		"undead": return "灵"
		"human":  return "人"
	return race

# ─── race synergy ─────────────────────────────────────────────────────────────

func _race_synergy_entries(race: String) -> Array:
	if _is_en():
		return _race_synergy_entries_en(race)
	match race:
		"god":
			return [
				{"threshold": 1, "name": "神族特性·净化", "detail": "友方单位死亡时，随机一名存活友军清除所有负面状态。"},
				{"threshold": 3, "name": "神3·吸血", "detail": "神族单位造成伤害时回复实际伤害 20% 生命。"},
				{"threshold": 7, "name": "神7·无敌", "detail": "神族单位开战时无敌 1.5 秒。"},
			]
		"dark":
			return [
				{"threshold": 1, "name": "暗族特性·击杀叠层", "detail": "每 3 个敌人死亡，暗族单位获得 1 层 +6% 伤害。"},
				{"threshold": 2, "name": "暗2·负面强化", "detail": "暗族负面效果（减攻、减速、破甲）强度 +25%。"},
				{"threshold": 5, "name": "暗5·伤害", "detail": "暗族单位伤害 +25%。"},
				{"threshold": 7, "name": "暗7·负面延时", "detail": "暗族负面效果持续时间 +50%。"},
			]
		"undead":
			return [
				{"threshold": 1, "name": "灵族特性·亡者召唤", "detail": "累计 30 次死亡时，每个灵族单位以 40% 属性召唤一个随机死亡单位的复制体。"},
				{"threshold": 4, "name": "灵4·剧毒", "detail": "灵族中毒伤害翻倍。"},
				{"threshold": 7, "name": "灵7·降低阈值", "detail": "灵族触发阈值降低：鬼母每 4 次死亡触发（原 5）；召唤在 23 次死亡（原 30）。"},
			]
		"human":
			return [
				{"threshold": 1, "name": "人族特性·三连暴击", "detail": "人族单位每第 3 次攻击必定暴击。"},
				{"threshold": 2, "name": "人2·护盾", "detail": "开战时普通棋子获得等于 8% 最大生命的护盾。"},
				{"threshold": 7, "name": "人7·狂战士", "detail": "仅剩 1 个普通棋子时触发一次：最大生命 ×2、防御 ×2、攻击 ×2、攻速 ×2、暴击 +100%、暴击伤害 +50%，并回复 50% 生命。"},
			]
	return []

func _race_synergy_entries_en(race: String) -> Array:
	match race:
		"god":
			return [
				{"threshold": 1, "name": "God Trait: Cleanse", "detail": "When a friendly unit dies, one random surviving ally removes all debuffs."},
				{"threshold": 3, "name": "God 3: Lifesteal", "detail": "God units restore 20% of actual damage dealt as HP."},
				{"threshold": 7, "name": "God 7: Invincible", "detail": "God units become invincible for 1.5s at battle start."},
			]
		"dark":
			return [
				{"threshold": 1, "name": "Dark Trait: Kill Stack", "detail": "Every 3 enemy deaths, Dark units gain 1 stack of +6% damage."},
				{"threshold": 2, "name": "Dark 2: Debuff Power", "detail": "Dark debuffs (ATK down, slow, DEF down) are 25% stronger."},
				{"threshold": 5, "name": "Dark 5: Damage", "detail": "Dark units deal +25% damage."},
				{"threshold": 7, "name": "Dark 7: Debuff Duration", "detail": "Dark debuffs last 50% longer."},
			]
		"undead":
			return [
				{"threshold": 1, "name": "Undead Trait: Death Summon", "detail": "At 30 total deaths, each of your Undead units summons a clone of a random dead unit at 40% stats."},
				{"threshold": 4, "name": "Undead 4: Poison", "detail": "Undead poison deals double damage."},
				{"threshold": 7, "name": "Undead 7: Lower Thresholds", "detail": "Undead trigger thresholds reduced: Mother Wisp triggers every 4 deaths (was 5); summon at 23 deaths (was 30)."},
			]
		"human":
			return [
				{"threshold": 1, "name": "Human Trait: Triple Crit", "detail": "Every 3rd attack from a Human unit is a guaranteed critical hit."},
				{"threshold": 2, "name": "Human 2: Shield", "detail": "At battle start, normal units gain a shield equal to 8% max HP."},
				{"threshold": 7, "name": "Human 7: Berserker", "detail": "Triggers once when only 1 normal unit remains: max HP ×2, DEF ×2, ATK ×2, AS ×2, Crit +100%, CritDmg +50%, and restore 50% HP."},
			]
	return []

func _format_synergy_detail(race: String, count: int) -> String:
	var lines: Array[String] = []
	var max_threshold := _race_synergy_max_threshold(race)
	if _is_en():
		lines.append("[b]%s Bond[/b]" % _race_name(race))
		lines.append("On board: %d/%d" % [count, max_threshold])
	else:
		lines.append("[b]%s族羁绊[/b]" % _race_name(race))
		lines.append("当前数量：%d/%d" % [count, max_threshold])
	for item in _race_synergy_entries(race):
		var active := count >= int(item.get("threshold", 0))
		var color := "#f4f4ee" if active else "#686868"
		lines.append("")
		lines.append("[color=%s][b]%s[/b]\n%s[/color]" % [
			color,
			str(item.get("name", "")),
			str(item.get("detail", "")),
		])
	return "\n".join(lines)

func _race_synergy_max_threshold(race: String) -> int:
	var max_threshold := 0
	# use zh entries for threshold values (same in both locales)
	var en_backup := _is_en()
	# temporarily query zh entries for thresholds
	var entries: Array
	match race:
		"god":    entries = [{"threshold":1},{"threshold":3},{"threshold":7}]
		"dark":   entries = [{"threshold":1},{"threshold":2},{"threshold":5},{"threshold":7}]
		"undead": entries = [{"threshold":1},{"threshold":4},{"threshold":7}]
		"human":  entries = [{"threshold":1},{"threshold":2},{"threshold":7}]
		_:        entries = []
	for item in entries:
		max_threshold = maxi(max_threshold, int(item.get("threshold", 0)))
	return max_threshold

# ─── unit detail popup ────────────────────────────────────────────────────────

func _show_shop_detail(index: int) -> void:
	if index >= 0 and index < GameState.shop_offers.size():
		_show_text_detail(_format_unit_def(GameState.shop_offers[index]))

func _show_board_detail(index: int) -> void:
	var cell = GameState.board_slots[index]
	if cell != null:
		_show_text_detail(_format_unit_def(cell.def, int(cell.star), cell))

func _show_bench_detail(index: int) -> void:
	if index < 0 or index >= GameState.bench_slots.size():
		return
	var cell = GameState.bench_slots[index]
	if cell != null:
		_show_text_detail(_format_unit_def(cell.def, int(cell.star)))

func _format_unit_def(d: Dictionary, star: int = 1, cell: Dictionary = {}) -> String:
	return UnitDetailFormat.format_unit_def(d, star, cell)

func _format_unit_relation_detail(cell: Dictionary, unit_race: String) -> String:
	return UnitDetailFormat.format_unit_relation_detail(cell, unit_race)

func _unit_race_name(race: String) -> String:
	return UnitDetailFormat.unit_race_name(race)

func _unit_element_name(element: String) -> String:
	return UnitDetailFormat.unit_element_name(element)

func _strip_bbcode(text: String) -> String:
	return text.replace("[b]", "").replace("[/b]", "").replace("[color=white]", "").replace("[color=#777777]", "").replace("[/color]", "")

# ─── skill detail ─────────────────────────────────────────────────────────────

func _format_skill_detail(d: Dictionary) -> String:
	return UnitDetailFormat.format_skill_detail(d)

func _format_skill_detail_en(d: Dictionary) -> String:
	return UnitDetailFormat.format_skill_detail_en(d)

func _skill_cd_text(d: Dictionary) -> String:
	return UnitDetailFormat.skill_cd_text(d)

func _pct(value: float) -> String:
	return UnitDetailFormat.pct(value)

# ─── treasure detail ──────────────────────────────────────────────────────────

func _show_treasure_detail(tid: String) -> void:
	_show_text_detail(_format_treasure_detail(TreasureService.treasure_by_id(tid)))

func _show_linkage_detail(link_id: String) -> void:
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	var link: Dictionary = {}
	for l in links:
		if str((l as Dictionary).get("id", "")) == link_id:
			link = l
			break
	if link.is_empty():
		return
	var names: Array[String] = []
	for req in link.get("requires", []):
		names.append(_localized_name(TreasureService.treasure_by_id(str(req))))
	var title := str(TREASURE_LINKAGE_LOGOS.get(link_id, link_id))
	var lines: Array[String] = [title]
	if _is_en():
		lines.append("Treasures: %s" % " + ".join(names))
		lines.append("Effect: %s" % _treasure_link_effect_text(link_id))
	else:
		lines.append("宝藏：%s" % " + ".join(names))
		lines.append("联动效果：%s" % _treasure_link_effect_text(link_id))
	_show_text_detail("\n".join(lines))

func _format_treasure_detail(t: Dictionary) -> String:
	var tid := str(t.get("id", ""))
	var category := str(t.get("category", ""))
	var tname := _localized_name(t)
	var lines: Array[String] = []
	lines.append(tname)
	if _is_en():
		lines.append("Effect: %s" % _treasure_effect_text(tid))
	else:
		lines.append("效果：%s" % _treasure_effect_text(tid))
	var set_status := _treasure_set_status(category)
	if not set_status.is_empty():
		lines.append(set_status)
	var link_lines := _treasure_linkage_status(tid)
	for line in link_lines:
		lines.append(line)
	return "\n".join(lines)

func _treasure_category_name(category: String) -> String:
	if _is_en():
		match category:
			"defense": return "Defense"
			"control": return "Control"
			"attack":  return "Attack"
			"money":   return "Money"
			"element": return "Element"
		return category
	match category:
		"defense": return "防御"
		"control": return "控制"
		"attack":  return "攻击"
		"money":   return "金钱"
		"element": return "元素"
	return category

func _treasure_set_status(category: String) -> String:
	if category.is_empty() or not TreasureService.has_set(category):
		return ""
	var names: Array[String] = []
	for tid in GameState.owned_treasures:
		var t := TreasureService.treasure_by_id(str(tid))
		if str(t.get("category", "")) == category:
			names.append(_localized_name(t))
	if _is_en():
		return "Set: %s\nSet Bonus: %s" % [" + ".join(names), _treasure_set_effect_text(category)]
	return "套装：%s\n套装效果：%s" % [" + ".join(names), _treasure_set_effect_text(category)]

func _treasure_linkage_status(tid: String) -> Array[String]:
	var lines: Array[String] = []
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	for link in links:
		var d: Dictionary = link
		var requires: Array = d.get("requires", [])
		if not requires.has(tid):
			continue
		var link_id := str(d.get("id", ""))
		if not TreasureService.has_linkage(link_id):
			continue
		var names: Array[String] = []
		for req in requires:
			var req_id := str(req)
			var req_t := TreasureService.treasure_by_id(req_id)
			names.append(_localized_name(req_t))
		if _is_en():
			lines.append("Synergy: %s\nSynergy Effect: %s" % [" + ".join(names), _treasure_link_effect_text(link_id)])
		else:
			lines.append("联动：%s\n联动效果：%s" % [" + ".join(names), _treasure_link_effect_text(link_id)])
	return lines

func _treasure_set_effect_text(category: String) -> String:
	if _is_en():
		match category:
			"defense": return "4 Defense: Normal units gain HP/DEF +30% and Dodge +15% at battle start."
			"control": return "4 Control: Each debuff application randomly triggers one of: slow / ATK down / silence / stun / poison / interrupt / bleed."
			"attack":  return "4 Attack: Normal units prioritize the lowest-HP enemy."
			"money":   return "4 Money: Shop refresh and treasure refresh are free."
			"element": return "4 Element: Normal units' attacks have a 20% chance to trigger an AoE (radius 180) elemental burst dealing 10% max HP true damage."
		return ""
	match category:
		"defense": return "4防御：普通棋子开战 HP/DEF +30%，闪避 +15%。"
		"control": return "4控制：每次触发负面效果，随机再触发减速/减攻/沉默/眩晕/中毒/打断/失血之一。"
		"attack":  return "4攻击：普通棋子优先攻击当前低血敌人。"
		"money":   return "4金钱：商店刷新和宝藏刷新免费。"
		"element": return "4元素：普通棋子攻击 20% 概率触发 180 范围元素爆发，对范围敌人造成最大生命 10% 真实伤害。"
	return ""

func _treasure_effect_text(tid: String) -> String:
	if _is_en():
		return _treasure_effect_text_en(tid)
	match tid:
		"def_iron_wall":        return "开战时我方普通棋子 DEF +10。"
		"def_life_monument":    return "开战时我方普通棋子最大生命 +20%，当前生命同步提高；胡牌手激活后改为 +40%。"
		"def_formation_heal":   return "每次战后我方法阵 HP +1，不超过初始上限；胡牌手激活后改为 +2。"
		"def_soul_counter":     return "我方普通棋子死亡时，对击杀者造成其最大生命 35% 真实伤害。"
		"def_lifesteal_emblem": return "我方普通棋子造成伤害后，回复实际伤害 20% 的生命。"
		"def_phantom_step":     return "开战时我方普通棋子闪避 +20%。"
		"ctrl_shockwave":       return "我方普通棋子攻击时触发，对当前目标眩晕 1 秒，冷却 5 秒；胡牌手激活后眩晕 2 秒。"
		"ctrl_corrosive_needle":return "我方普通棋子每第 4 次攻击使目标失血，冷却 5 秒。"
		"ctrl_interrupt_chain": return "我方普通棋子攻击时 25% 概率打断目标，冷却 5 秒。"
		"ctrl_time_compress":   return "我方普通棋子技能冷却缩短 25%，首次与后续冷却均乘以 0.75。"
		"ctrl_binding_weight":  return "我方普通棋子攻击时使目标移动 -25%、攻速 -20%，持续 2 秒，冷却 5 秒。"
		"atk_blood_pact":       return "开战时我方普通棋子 ATK x1.25，但自身永久失血；胡牌手激活后改为 ATK x1.50。"
		"atk_fury_roster":      return "普通棋子上限从 7 提高到 8。"
		"atk_burst_core":       return "开战时我方普通棋子暴击率 +25%。"
		"atk_wail_resonance":   return "击杀敌人时，对死亡目标周围 180 范围敌人造成其最大生命 10% 真实伤害。"
		"atk_frenzy_assault":   return "攻击同一目标时自身攻速 x1.15，可叠；换目标重置。"
		"money_compound":       return "单件战后利息额外 +5% 当前金币。与雷霆加速联动后造成伤害有概率获得金币。"
		"money_generous_fate":  return "准备阶段每回合可手动参与 1 次赌博：50% 概率胜利使当前金币翻倍；50% 概率失败并损失当前金币的 80%。与幻影步伐联动后变为 60% 翻倍、40% 损失当前金币 50%。"
		"money_discount":       return "棋子商店价格 -20%；与狂怒阵容联动后变为 -40%。"
		"money_golden_altar":   return "准备阶段出现黄金祭坛按钮：-1 法阵 HP，+50 金，每回合最多 3 次，HP <=10 不可用；胡牌手激活后改为 +100 金。"
		"money_lucky_envelope": return "战后随机 +10~30 金；与时空压缩联动后额外随机 +50~70 金，10% 概率额外 +100 金。"
		"elem_flame_shatter":   return "攻击有 25% 概率额外造成 40% ATK 真实伤害；与吸血纹章联动后提高到 100%。"
		"elem_frost_blade":     return "攻击有 25% 概率使目标移动/攻速 -35%，持续 1.5 秒；与打断锁链联动后目标受伤 +15%。"
		"elem_thunder_haste":   return "攻击有 25% 概率使自身攻速 +60%，持续 3 秒，重复触发只刷新时间；与复利之道联动后造成伤害 10% 概率 +10 金。"
		"elem_toxic_spread":    return "攻击有 25% 概率使目标中毒；与爆裂核心联动后，造成伤害时中毒目标有 50% 概率提前结算剩余毒伤。"
	return "暂未写入详细说明。"

func _treasure_effect_text_en(tid: String) -> String:
	match tid:
		"def_iron_wall":        return "At battle start, friendly normal units gain DEF +10."
		"def_life_monument":    return "At battle start, friendly normal units gain max HP +20% (current HP increases too). With Hu Pai Master: +40%."
		"def_formation_heal":   return "After each battle, restore 1 Formation HP (up to the starting cap). With Hu Pai Master: +2."
		"def_soul_counter":     return "When a friendly normal unit dies, deal 35% of the killer's max HP as true damage."
		"def_lifesteal_emblem": return "Friendly normal units restore 20% of actual damage dealt as HP."
		"def_phantom_step":     return "At battle start, friendly normal units gain Dodge +20%."
		"ctrl_shockwave":       return "On attack, stun the current target for 1s (CD 5s). With Hu Pai Master: stun 2s."
		"ctrl_corrosive_needle":return "Every 4th attack causes the target to bleed (CD 5s)."
		"ctrl_interrupt_chain": return "25% chance to interrupt the target on attack (CD 5s)."
		"ctrl_time_compress":   return "Friendly normal units' skill cooldowns are reduced by 25% (multiplied by 0.75)."
		"ctrl_binding_weight":  return "On attack, reduce target movement by 25% and AS by 20% for 2s (CD 5s)."
		"atk_blood_pact":       return "At battle start, friendly normal units gain ATK ×1.25 but permanently bleed. With Hu Pai Master: ATK ×1.50."
		"atk_fury_roster":      return "Normal unit board limit increased from 7 to 8."
		"atk_burst_core":       return "At battle start, friendly normal units gain Crit +25%."
		"atk_wail_resonance":   return "On kill, deal 10% of the target's max HP as true damage to all enemies within radius 180."
		"atk_frenzy_assault":   return "Attacking the same target stacks own AS ×1.15 (stackable); resets on target switch."
		"money_compound":       return "After battle, gain bonus interest equal to +5% of current gold. Synergy with Thunder Haste: chance to earn 1G on damage."
		"money_generous_fate":  return "Once per prep phase, gamble: 50% chance to double current gold; 50% chance to lose 80% of current gold. Synergy with Phantom Step: becomes 60%/40% with 50% loss."
		"money_discount":       return "Shop unit prices -20%. Synergy with Fury Roster: -40%."
		"money_golden_altar":   return "Adds a Golden Altar button during prep: spend 1 Formation HP to gain +50G (max 3 times per round; unavailable at HP ≤10). With Hu Pai Master: +100G."
		"money_lucky_envelope": return "After battle, gain a random +10~30G. Synergy with Time Compress: +50~70G extra, with 10% chance of +100G."
		"elem_flame_shatter":   return "25% chance on attack to deal extra 40% ATK true damage. Synergy with Lifesteal Emblem: increases to 100%."
		"elem_frost_blade":     return "25% chance on attack to reduce target movement and AS by 35% for 1.5s. Synergy with Interrupt Chain: target takes +15% damage."
		"elem_thunder_haste":   return "25% chance on attack to grant own AS +60% for 3s (refreshes on re-trigger). Synergy with Compound Interest: 10% chance to gain +10G on damage."
		"elem_toxic_spread":    return "25% chance on attack to poison the target. Synergy with Burst Core: 50% chance to instantly resolve remaining poison damage."
	return "Description not yet available."

func _treasure_link_effect_text(link_id: String) -> String:
	if _is_en():
		match link_id:
			"link_phoenix":           return "Friendly normal units temporarily revive for 3s after dying, then die for real."
			"link_money_magic":       return "After battle, gain an extra random +50~70G, with a 10% chance of +100G."
			"link_blood_covenant":    return "Flame Shatter true damage increases from 40% ATK to 100% ATK."
			"link_paralysis_shackles":return "On successful interrupt, also apply ice effect; ice-affected targets take +15% damage."
			"link_oppression_counter":return "When a friendly normal unit is hit, apply ATK -20% to the attacker for 2s; also stacks Frenzy Assault AS logic on them."
			"link_fraud_fate":        return "Generous Fate becomes: 60% chance to double gold, 40% chance to lose 50% of gold."
			"link_iron_maiden":       return "When a friendly normal unit is hit, inflict bleed and armor break on the attacker (CD 5s)."
			"link_toxic_burst":       return "On dealing damage, 50% chance to instantly resolve remaining poison on poisoned targets."
			"link_rich_path":         return "10% chance to gain +10G on dealing damage."
			"link_clearance_sale":    return "Auto-activates when Fury Roster + Discount Token are both owned: shop prices -40%."
			"link_hu_pai_master":     return "Activates when Life Monument + Formation Heal + Shockwave + Blood Pact + Fury Roster are all owned: doubles the positive values of the first four treasures, and Fury Roster's unit cap gains +1 more (7 -> 9); cooldowns, chances, and costs unchanged."
		return "Synergy description not yet available."
	match link_id:
		"link_phoenix":           return "我方普通棋子死亡后临时复活 3 秒，之后强制死亡。"
		"link_money_magic":       return "战后额外随机 +50~70 金，10% 概率额外 +100 金。"
		"link_blood_covenant":    return "炎焰碎裂触发时，真实伤害从 ATK 40% 提高到 ATK 100%。"
		"link_paralysis_shackles":return "打断成功后额外触发冰效果，被冰影响目标受伤 +15%。"
		"link_oppression_counter":return "我方普通棋子被攻击时，对攻击者施加减攻 20%，持续 2 秒；攻击者也会被叠加狂暴进攻攻速逻辑。"
		"link_fraud_fate":        return "慷慨命运变为每回合手动赌博 1 次：60% 金币翻倍，40% 损失当前金币 50%。"
		"link_iron_maiden":       return "我方普通棋子受击时反施失血和破甲，冷却 5 秒。"
		"link_toxic_burst":       return "造成伤害时，中毒目标有 50% 概率提前结算剩余毒伤。"
		"link_rich_path":         return "造成伤害后 10% 概率 +10 金。"
		"link_clearance_sale":    return "狂怒阵容与折扣令牌同时拥有时自动激活，棋子商店价格 -40%。"
		"link_hu_pai_master":     return "生命丰碑、法阵回春、震荡余波、血契之刃、狂怒阵容同时拥有时激活：前四件宝藏的正面数值翻倍，狂怒阵容棋子上限再 +1（7→9）；冷却、概率、次数和负面代价不变。"
	return "联动效果待说明。"

func _format_dict_detail(d: Dictionary) -> String:
	var lines: Array[String] = []
	for key in d.keys():
		lines.append("%s: %s" % [str(key), str(d[key])])
	return "\n".join(lines)

# ─── popup helpers ────────────────────────────────────────────────────────────

func _show_text_detail(text: String) -> void:
	_gold_interest_detail_open = false
	_detail_text.custom_minimum_size = Vector2(500, 360)
	_detail_text.text = text
	_detail_waiting_for_release = false
	_detail_release_seen_press = false
	_detail.popup_centered(Vector2i(540, 390))

func _hide_detail() -> void:
	if _detail != null and _detail.visible:
		_detail.hide()
	_gold_interest_detail_open = false
	_detail_waiting_for_release = false
	_detail_release_seen_press = false

func _update_detail_release_state() -> void:
	if _detail == null or not _detail.visible:
		_detail_waiting_for_release = false
		_detail_release_seen_press = false
		return
	if not _detail_waiting_for_release:
		return
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_detail_release_seen_press = true
	elif _detail_release_seen_press:
		_hide_detail()

func _attach_long_press(btn: BaseButton, cb: Callable) -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = 0.7
	btn.add_child(timer)
	btn.set_meta("long_press_timer", timer)
	timer.timeout.connect(func():
		if not bool(btn.get_meta("long_press_cancelled", false)) and not bool(btn.get_meta("dragging", false)):
			btn.set_meta("long_press_triggered", true)
			cb.call()
	)
	btn.button_down.connect(func():
		btn.set_meta("long_press_start", btn.get_local_mouse_position())
		btn.set_meta("long_press_cancelled", false)
		btn.set_meta("long_press_triggered", false)
		btn.set_meta("dragging", false)
		timer.start()
	)
	btn.button_up.connect(func():
		timer.stop()
		btn.set_meta("dragging", false)
		# 长按看属性「常驻」：松手后详情保留，靠点击弹窗外部/下一次操作关闭。
		# 若这次没触发长按（只是轻点），才顺手收起可能残留的详情。
		if not bool(btn.get_meta("long_press_triggered", false)):
			_hide_detail()
	)
	btn.gui_input.connect(func(event: InputEvent):
		if not timer.time_left > 0.0:
			return
		if event is InputEventMouseMotion or event is InputEventScreenDrag:
			var start: Vector2 = btn.get_meta("long_press_start", btn.get_local_mouse_position())
			if btn.get_local_mouse_position().distance_to(start) > 8.0:
				btn.set_meta("long_press_cancelled", true)
				timer.stop()
	)
