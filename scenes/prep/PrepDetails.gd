extends "res://scenes/prep/PrepBoardController.gd"

const RACE_LOGO_PATHS := {
	"god": "res://assets/ui/race_logos/god.png",
	"dark": "res://assets/ui/race_logos/dark.png",
	"undead": "res://assets/ui/race_logos/undead.png",
	"human": "res://assets/ui/race_logos/human.png",
}

# ─── locale helpers ───────────────────────────────────────────────────────────

func _is_en() -> bool:
	return LocaleManager.get_locale() == "en"

func _localized_name(d: Dictionary) -> String:
	if _is_en():
		var en := str(d.get("name_en", ""))
		if not en.is_empty():
			return en
	return str(d.get("name", str(d.get("id", "?"))))

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
	var group := str(entry.get("group", ""))
	if group == "mercenary":
		return "enemy" if str(entry.get("team", "")) == "enemy" else "player"
	return group

func _stats_display_name(row: Dictionary) -> String:
	if _is_en():
		var en := str(row.get("name_en", ""))
		if not en.is_empty():
			return _sanitize_stats_cell(en)
	return _sanitize_stats_cell(str(row.get("name", "?")))

func _stats_display_position(row: Dictionary) -> String:
	if not _is_en():
		return _sanitize_stats_cell(str(row.get("position", "?")))
	var slot := int(row.get("slot", -1))
	if _entry_stats_group(row) == "boss":
		return "Boss %d" % maxi(1, slot + 1)
	if bool(row.get("is_mercenary", false)):
		return "%s Merc %d" % ["Enemy" if str(row.get("team", "")) == "enemy" else "Ally", maxi(1, slot - 24)]
	if slot >= 0 and slot < GameConstants.CELL_COUNT:
		return "Board %d" % (slot + 1)
	return "%s %d" % ["Enemy" if str(row.get("team", "")) == "enemy" else "Ally", maxi(1, slot + 1)]

func _stats_color_cell(row: Dictionary, text: String) -> String:
	var owner_slot := int(row.get("owner_slot", -1))
	if owner_slot < 0:
		return text
	return "[color=#%s]%s[/color]" % [GameConstants.team_slot_color(owner_slot).to_html(false), text]

func _sanitize_stats_cell(text: String) -> String:
	return text.replace("[", "").replace("]", "")

func _format_status_bucket(value: Variant) -> String:
	if typeof(value) != TYPE_DICTIONARY:
		return "None" if _is_en() else "无"
	var bucket: Dictionary = value
	if bucket.is_empty():
		return "None" if _is_en() else "无"
	var keys := bucket.keys()
	keys.sort()
	var parts: Array[String] = []
	for key in keys:
		var seconds := float(bucket.get(key, 0.0))
		if seconds <= 0.05:
			continue
		if _is_en():
			parts.append("%s %.1fs" % [_status_display_name(str(key)), seconds])
		else:
			parts.append("%s %s秒" % [_status_display_name(str(key)), _format_seconds(seconds)])
	if _is_en():
		return " + ".join(parts) if not parts.is_empty() else "None"
	return " + ".join(parts) if not parts.is_empty() else "无"

func _format_seconds(seconds: float) -> String:
	if is_equal_approx(seconds, round(seconds)):
		return str(int(round(seconds)))
	return "%.1f" % seconds

func _status_display_name(kind: String) -> String:
	var key := "status_" + kind
	var text := tr(key)
	return text if text != key else kind

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
	if d.is_empty():
		return "No details" if _is_en() else "无详情"
	var mul := GameState.star_stat_multiplier(star) if not bool(d.get("is_mercenary", false)) else 1.0
	var uname := _localized_name(d)
	var race := _unit_race_name(str(d.get("race", "-")))
	var elem := _unit_element_name(str(d.get("element", "-")))
	var skill_text := _format_skill_detail(d)
	var detail: String
	if _is_en():
		detail = "%s ★%d\nRace: %s  Element: %s  Tier: %d  Cost: %d G\nHP: %d  ATK: %d  DEF: %d\nAS: %.2f  Crit: %.0f%%  CritDmg: %.0f%%\nRange: %s  Speed: %s\n\n[b]Skill[/b]\n%s" % [
			uname, star,
			race, elem, int(d.get("tier", 0)), int(d.get("cost", 0)),
			int(round(float(d.get("hp", 0)) * mul)), int(round(float(d.get("atk", 0)) * mul)), int(round(float(d.get("def", 0)) * mul)),
			float(d.get("attack_speed", 1.0)), float(d.get("crit", 0.0)) * 100.0, float(d.get("crit_dmg", 1.5)) * 100.0,
			str(d.get("range", 1)), str(d.get("move_speed", 3.0)), skill_text,
		]
	else:
		detail = "%s %d星\n种族：%s  属性：%s  阶级：%d  价格：%d金\n生命：%d  攻击：%d  防御：%d\n攻速：%.2f  暴击：%.0f%%  暴伤：%.0f%%\n射程：%s  移速：%s\n\n[b]技能效果[/b]\n%s" % [
			uname, star,
			race, elem, int(d.get("tier", 0)), int(d.get("cost", 0)),
			int(round(float(d.get("hp", 0)) * mul)), int(round(float(d.get("atk", 0)) * mul)), int(round(float(d.get("def", 0)) * mul)),
			float(d.get("attack_speed", 1.0)), float(d.get("crit", 0.0)) * 100.0, float(d.get("crit_dmg", 1.5)) * 100.0,
			str(d.get("range", 1)), str(d.get("move_speed", 3.0)), skill_text,
		]
	var relation_detail := _format_unit_relation_detail(cell, str(d.get("race", "")))
	if not relation_detail.is_empty():
		if _is_en():
			detail += "\n\n[b]Race Relations[/b]\n%s" % relation_detail
		else:
			detail += "\n\n[b]种族关系[/b]\n%s" % relation_detail
	return detail

func _format_unit_relation_detail(cell: Dictionary, unit_race: String) -> String:
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
		if _is_en():
			var rel := "Friendly" if kind_str == "friendly" else "Hostile"
			var stage := "Active" if active else "" if progress >= 3 else "Stage %d" % progress
			lines.append("vs %s — %s: %d%% (%s)" % [_unit_race_name(other_race), rel, percent, stage])
			if active:
				lines.append("HP/ATK/DEF %s15%%" % ["+" if kind_str == "friendly" else "-"])
		else:
			var rel := "友好" if kind_str == "friendly" else "敌对"
			var stage := "已生效" if active else "" if progress >= 3 else "第%d阶" % progress
			lines.append("与%s族%s：%d%%（%s）" % [_unit_race_name(other_race), rel, percent, stage])
			if active:
				lines.append("生命、攻击、防御 %s15%%" % ["+" if rel == "友好" else "-"])
	return "\n".join(lines)

func _unit_race_name(race: String) -> String:
	if _is_en():
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

func _unit_element_name(element: String) -> String:
	if _is_en():
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

func _strip_bbcode(text: String) -> String:
	return text.replace("[b]", "").replace("[/b]", "").replace("[color=white]", "").replace("[color=#777777]", "").replace("[/color]", "")

# ─── skill detail ─────────────────────────────────────────────────────────────

func _format_skill_detail(d: Dictionary) -> String:
	if _is_en():
		return _format_skill_detail_en(d)
	var sid := str(d.get("skill_id", "none"))
	var cd := _skill_cd_text(d)
	match sid:
		"none":
			return "无主动技能。"
		"lowest_ally_heal":
			return "星辉祈愿%s：治疗生命比例最低的友军，回复其最大生命%s；有%s概率清除负面状态。" % [cd, _pct(float(d.get("heal_pct", 0.06))), _pct(float(d.get("cleanse_chance", 0.25)))]
		"nearest_ally_bless":
			return "神赐祝福%s：强化最近友军，攻击+%s、攻速+%.2f，并清除负面状态。" % [cd, _pct(float(d.get("atk_bonus", 0.12))), float(d.get("aspd_bonus", 0.15))]
		"guardian_shield_taunt":
			return "守护嘲讽：战斗开始获得最大生命%s护盾，并让周围敌人优先攻击自己。" % _pct(float(d.get("start_shield_pct", 0.20)))
		"true_damage_attack":
			return "圣枪裁决：普通攻击额外造成自身攻击%s真实伤害。" % _pct(float(d.get("true_damage_pct", 0.18)))
		"nearby_ally_heal_buff":
			return "光环治疗%s：治疗自身周围友军最大生命%s，并给攻击+%s、攻速+%.2f，同时清除负面状态；开场冷却%.1f秒。" % [cd, _pct(float(d.get("heal_pct", 0.15))), _pct(float(d.get("atk_bonus", 0.10))), float(d.get("aspd_bonus", 0.15)), float(d.get("opening_cd", 0.0))]
		"judgement_strike":
			return "审判打击%s：对最近敌人造成自身攻击%s伤害；每次释放自身防御叠加+%s，最多%d层。" % [cd, _pct(float(d.get("damage_atk_pct", 2.2))), _pct(float(d.get("def_stack_pct", 0.06))), int(d.get("max_stacks", 5))]
		"random_ally_damage_reduction":
			return "天使庇护%s：随机友军获得%s减伤，持续%.1f秒。" % [cd, _pct(float(d.get("damage_reduction", 0.50))), float(d.get("duration", 6.0))]
		"global_divine_blast":
			return "神王裁决%s：攻击全场敌人，造成自身攻击%s加目标最大生命%s的伤害。" % [cd, _pct(float(d.get("damage_atk_pct", 1.6))), _pct(float(d.get("max_hp_bonus_pct", 0.08)))]
		"curse_attack":
			return "诅咒攻击：普通攻击附带减攻%s与攻速降低%s，持续%.1f秒；暗5/暗7会增强。" % [_pct(float(d.get("attack_down", 0.08))), _pct(float(d.get("aspd_down", 0.08))), float(d.get("duration", 4.0))]
		"silence_bolt":
			return "沉默箭%s：沉默最近敌人%.1f秒，并造成自身攻击%s伤害；暗7会延长持续时间。" % [cd, float(d.get("silence_sec", 1.2)), _pct(float(d.get("damage_atk_pct", 1.7)))]
		"fear":
			return "恐惧%s：使最近敌人恐惧/眩晕%.1f秒并推离；暗7会延长持续时间。" % [cd, float(d.get("fear_sec", 1.5))]
		"same_target_damage_stack":
			return "痛苦凝视：持续攻击同一目标时，每层伤害+%s，最多%d层；换目标重置。" % [_pct(float(d.get("stack_damage", 0.06))), int(d.get("max_stacks", 5))]
		"blink_low_def_backline":
			return "暗影突袭%s：瞬移到低防后排敌人身边，造成自身攻击%s伤害；击杀后刷新冷却。" % [cd, _pct(float(d.get("damage_atk_pct", 2.0)))]
		"stun":
			return "暗影击晕%s：眩晕最近敌人%.1f秒；暗7会延长持续时间。" % [cd, float(d.get("stun_sec", 1.0))]
		"shared_hp_link":
			return "血链%s：连接最近非Boss敌人并使其变为我方棋子；双方共享受到的生命损失，任一方死亡后清除连接，本回合不再释放。Boss免疫。" % cd
		"black_hole":
			return "黑洞%s：牵引周围敌人，眩晕%.1f秒，并造成自身攻击%s伤害；暗7会延长控制。" % [cd, float(d.get("pull_sec", 2.0)), _pct(float(d.get("damage_atk_pct", 2.2)))]
		"poison_attack":
			return "毒击：普通攻击附带中毒，每秒造成目标最大生命3%伤害，持续4秒；灵4毒伤x2。"
		"parasite_on_kill":
			return "寄生：普攻标记目标；标记目标死亡时召唤该敌人的分身，生命为原目标%s，攻防为原目标%s。" % [_pct(float(d.get("clone_hp_pct", 0.10))), _pct(float(d.get("clone_atk_def_pct", 0.50)))]
		"defense_down_attack":
			return "腐蚀攻击：普通攻击降低目标防御%s，持续%.1f秒；暗5/暗7会增强。" % [_pct(float(d.get("def_down_pct", 0.10))), float(d.get("duration", 5.0))]
		"death_poison_explosion":
			return "死亡毒爆：死亡时对周围敌人造成自身攻击%s真实伤害，并施加中毒。" % _pct(float(d.get("damage_atk_pct", 2.5)))
		"poison_reflect_armor_stack":
			return "毒甲：受伤后反弹本次伤害%s真实伤害并使攻击者中毒；自身防御每次+%d，最多%d层。" % [_pct(float(d.get("reflect_taken_damage_pct", 0.12))), int(d.get("armor_per_hit", 2)), int(d.get("max_stacks", 10))]
		"unique_death_execute":
			return "母灵：每名玩家最多1只；3v3中多个玩家的母灵可同时生效且各自独立计数。每5个非母灵处决造成的敌军死亡触发一次；1阶/佣兵50%、2阶35%、3阶10%即死，Boss改为20%最大生命伤害。灵7改为每4个死亡触发。"
		"attack_interrupt":
			return "打断攻击：普通攻击有%s概率打断目标。" % _pct(float(d.get("interrupt_chance", 0.12)))
		"post_battle_gold_by_star":
			return "战后经商：参与战斗后，按星级获得金币。1星+1，2星+2，3星+3。"
		"every_fourth_combo":
			return "连射：每第%d次普通攻击额外造成自身攻击%s伤害。" % [int(d.get("every", 4)), _pct(float(d.get("combo_atk_pct", 0.70)))]
		"front_cone_stun":
			return "盾击%s：攻击最近敌人，造成自身攻击%s伤害并眩晕%.1f秒。" % [cd, _pct(float(d.get("damage_atk_pct", 1.5))), float(d.get("stun_sec", 1.0))]
		"random_attribute_attack":
			return "属性乱击：普通攻击随机附带火/冰/雷/毒属性效果。"
		"random_attribute_bolt":
			return "随机法术：无普攻，每2.5秒对随机敌人造成攻击300%的随机属性伤害。"
		"every_fifth_group_heal":
			return "战歌：每第%d次普通攻击治疗周围友军最大生命%s。" % [int(d.get("every", 5)), _pct(float(d.get("heal_pct", 0.05)))]
		"left_neighbor_sacrifice":
			return "死侍契约：周围一圈友军防御+3持续5秒；战斗开始绑定左侧棋子，该棋子首次死亡时死侍代替其死亡并使其满血复活。"
		"unique_king_growth":
			return "人王唯一技：棋盘上只能存在一只人王。若参战且战后仍存活，全属性永久x%.1f；若死亡则从棋盘移除；升星继承三只材料中成长最高的人王数值。" % (1.0 + float(d.get("post_battle_all_stat_growth", 0.20)))
		"balance_judge":
			return "均衡裁决：攻击当前生命高于自己的目标时，伤害+%s。" % _pct(float(d.get("bonus_vs_higher_hp", 0.40)))
		"bubble_dream":
			return "泡沫梦境%s：治疗最低血友军%d点，并使最近敌人减速%s、受到%d点真实伤害。" % [cd, int(d.get("heal", 80)), _pct(float(d.get("slow_pct", 0.30))), int(d.get("burst_damage", 70))]
		"shell_guard":
			return "甲壳守护：获得%s减伤，持续%.1f秒。" % [_pct(float(d.get("reduction", 0.50))), float(d.get("duration", 5.0))]
		"gold_charge":
			return "黄金冲锋%s：冲向最近敌人，造成%d点真实伤害并眩晕%.1f秒。" % [cd, int(d.get("skill_damage", 120)), float(d.get("stun_sec", 1.2))]
		"holy_song":
			return "圣歌%s：治疗全体友军最大生命%s，并清除控制类负面状态。" % [cd, _pct(float(d.get("heal_pct", 0.15)))]
		"twin_strike":
			return "镜像突袭%s：召唤自身镜像，镜像生命%s、攻击%s。" % [cd, _pct(float(d.get("clone_hp_pct", 0.30))), _pct(float(d.get("clone_atk_pct", 0.40)))]
		"king_aura":
			return "王者光环：每2秒强化周围友军，攻速+%s、暴击+%s。" % [_pct(float(d.get("ally_aspd_bonus", 0.25))), _pct(float(d.get("ally_crit_bonus", 0.15)))]
		"arrow_rain":
			return "箭雨%s：攻击最近%d名敌人，每个目标受到自身攻击85%%伤害。" % [cd, int(d.get("targets", 5))]
		"blood_rampage":
			return "血怒：每损失%s最大生命，攻速+%s、吸血+%s，并获得少量伤害提升。" % [_pct(float(d.get("hp_step", 0.10))), _pct(float(d.get("aspd_per_step", 0.10))), _pct(float(d.get("lifesteal_per_step", 0.05)))]
		"steel_order":
			return "钢铁号令%s：强化最近%d名友军，减伤%s、攻速+%s、控制时间降低%s，持续%.1f秒。" % [cd, int(d.get("buff_targets", 3)), _pct(float(d.get("damage_reduction", 0.20))), _pct(float(d.get("aspd_bonus", 0.20))), _pct(float(d.get("control_time_reduction", 0.30))), float(d.get("duration", 8.0))]
		"time_slow":
			return "时空迟缓%s：自身短暂闪避提高，并使全体敌人减速%s，持续%.1f秒。" % [cd, _pct(float(d.get("slow_pct", 0.35))), float(d.get("duration", 5.0))]
		"death_hunt":
			return "冥界处决：优先攻击低血目标；击杀回复最大生命%s。普攻破甲%d并降低治疗%s，持续%.1f秒。" % [_pct(float(d.get("kill_heal_pct", 0.15))), int(d.get("armor_break", 8)), _pct(float(d.get("heal_reduction", 0.50))), float(d.get("duration", 4.0))]
	return "该技能暂未写入详细说明。"

func _format_skill_detail_en(d: Dictionary) -> String:
	var sid := str(d.get("skill_id", "none"))
	var cd := _skill_cd_text(d)
	match sid:
		"none":
			return "No active skill."
		"lowest_ally_heal":
			return "Starlight Prayer%s: Heal the ally with the lowest HP ratio by %s of their max HP; %s chance to cleanse debuffs." % [cd, _pct(float(d.get("heal_pct", 0.06))), _pct(float(d.get("cleanse_chance", 0.25)))]
		"nearest_ally_bless":
			return "Divine Blessing%s: Buff the nearest ally — ATK +%s, AS +%.2f — and cleanse their debuffs." % [cd, _pct(float(d.get("atk_bonus", 0.12))), float(d.get("aspd_bonus", 0.15))]
		"guardian_shield_taunt":
			return "Guardian Taunt: Gain a shield equal to %s max HP at battle start; force nearby enemies to target this unit." % _pct(float(d.get("start_shield_pct", 0.20)))
		"true_damage_attack":
			return "Holy Lance: Normal attacks deal bonus true damage equal to %s ATK." % _pct(float(d.get("true_damage_pct", 0.18)))
		"nearby_ally_heal_buff":
			return "Halo Heal%s: Heal nearby allies for %s max HP; grant ATK +%s and AS +%.2f and cleanse debuffs; initial cooldown %.1fs." % [cd, _pct(float(d.get("heal_pct", 0.15))), _pct(float(d.get("atk_bonus", 0.10))), float(d.get("aspd_bonus", 0.15)), float(d.get("opening_cd", 0.0))]
		"judgement_strike":
			return "Judgement Strike%s: Deal %s ATK damage to the nearest enemy; each cast permanently stacks own DEF +%s (max %d stacks)." % [cd, _pct(float(d.get("damage_atk_pct", 2.2))), _pct(float(d.get("def_stack_pct", 0.06))), int(d.get("max_stacks", 5))]
		"random_ally_damage_reduction":
			return "Angel's Guard%s: Grant a random ally %s damage reduction for %.1fs." % [cd, _pct(float(d.get("damage_reduction", 0.50))), float(d.get("duration", 6.0))]
		"global_divine_blast":
			return "Divine Judgement%s: Strike all enemies for %s ATK + %s of their max HP as damage." % [cd, _pct(float(d.get("damage_atk_pct", 1.6))), _pct(float(d.get("max_hp_bonus_pct", 0.08)))]
		"curse_attack":
			return "Curse Strike: Normal attacks reduce target ATK by %s and AS by %s for %.1fs. Dark 5/7 amplify these debuffs." % [_pct(float(d.get("attack_down", 0.08))), _pct(float(d.get("aspd_down", 0.08))), float(d.get("duration", 4.0))]
		"silence_bolt":
			return "Silence Bolt%s: Silence the nearest enemy for %.1fs and deal %s ATK damage. Dark 7 extends duration." % [cd, float(d.get("silence_sec", 1.2)), _pct(float(d.get("damage_atk_pct", 1.7)))]
		"fear":
			return "Fear%s: Frighten/stun the nearest enemy for %.1fs and knock them back. Dark 7 extends duration." % [cd, float(d.get("fear_sec", 1.5))]
		"same_target_damage_stack":
			return "Agonizing Gaze: Consecutive attacks on the same target deal +%s damage per stack (max %d stacks). Resets on target switch." % [_pct(float(d.get("stack_damage", 0.06))), int(d.get("max_stacks", 5))]
		"blink_low_def_backline":
			return "Shadow Ambush%s: Blink to the lowest-DEF backline enemy and deal %s ATK damage. Cooldown resets on kill." % [cd, _pct(float(d.get("damage_atk_pct", 2.0)))]
		"stun":
			return "Shadow Stun%s: Stun the nearest enemy for %.1fs. Dark 7 extends duration." % [cd, float(d.get("stun_sec", 1.0))]
		"shared_hp_link":
			return "Blood Chain%s: Link to the nearest non-Boss enemy and convert them to your side. Both share HP loss; link breaks on either death and will not reactivate this round. Boss immune." % cd
		"black_hole":
			return "Black Hole%s: Pull surrounding enemies, stun for %.1fs, and deal %s ATK damage. Dark 7 extends the stun." % [cd, float(d.get("pull_sec", 2.0)), _pct(float(d.get("damage_atk_pct", 2.2)))]
		"poison_attack":
			return "Poison Strike: Normal attacks apply poison — 3% max HP per second for 4s. Undead 4 doubles poison damage."
		"parasite_on_kill":
			return "Parasite: Mark targets with normal attacks. When a marked target dies, summon its clone at %s HP and %s ATK/DEF." % [_pct(float(d.get("clone_hp_pct", 0.10))), _pct(float(d.get("clone_atk_def_pct", 0.50)))]
		"defense_down_attack":
			return "Corrosive Strike: Normal attacks reduce target DEF by %s for %.1fs. Dark 5/7 amplify this effect." % [_pct(float(d.get("def_down_pct", 0.10))), float(d.get("duration", 5.0))]
		"death_poison_explosion":
			return "Death Poison Burst: On death, deal %s ATK true damage to surrounding enemies and apply poison." % _pct(float(d.get("damage_atk_pct", 2.5)))
		"poison_reflect_armor_stack":
			return "Toxic Armor: On taking damage, reflect %s as true damage and poison the attacker. Own DEF stacks +%d per hit (max %d stacks)." % [_pct(float(d.get("reflect_taken_damage_pct", 0.12))), int(d.get("armor_per_hit", 2)), int(d.get("max_stacks", 10))]
		"unique_death_execute":
			return "Mother Wisp: each player can field 1; in 3v3, each player's Mother Wisp works at the same time and counts independently. Every 5 enemy deaths not caused by Mother Wisp execute: Tier 1/Merc 50%, Tier 2 35%, Tier 3 10%; vs Boss deal 20% max HP instead. Undead 7: every 4 deaths."
		"attack_interrupt":
			return "Interrupt Strike: Normal attacks have a %s chance to interrupt the target." % _pct(float(d.get("interrupt_chance", 0.12)))
		"post_battle_gold_by_star":
			return "Trade: After each battle, gain gold equal to this unit's star level (★1 → +1G, ★2 → +2G, ★3 → +3G)."
		"every_fourth_combo":
			return "Rapid Fire: Every %d attacks, deal bonus %s ATK damage." % [int(d.get("every", 4)), _pct(float(d.get("combo_atk_pct", 0.70)))]
		"front_cone_stun":
			return "Shield Bash%s: Strike the nearest enemy for %s ATK damage and stun for %.1fs." % [cd, _pct(float(d.get("damage_atk_pct", 1.5))), float(d.get("stun_sec", 1.0))]
		"random_attribute_attack":
			return "Elemental Strike: Normal attacks randomly apply fire / ice / thunder / poison."
		"random_attribute_bolt":
			return "Random Spell: No basic attack. Every 2.5s, deal 300% ATK random-element damage to a random enemy."
		"every_fifth_group_heal":
			return "War Song: Every %d attacks, heal nearby allies for %s of their max HP." % [int(d.get("every", 5)), _pct(float(d.get("heal_pct", 0.05)))]
		"left_neighbor_sacrifice":
			return "Death Pact: Grant surrounding allies DEF +3 for 5s. At battle start, bind to the left neighbor — when that unit first dies, this unit sacrifices itself in their place, reviving them at full HP."
		"unique_king_growth":
			return "Human King Unique (one on board): If this unit survives a battle, all stats permanently ×%.1f. If it dies, it is removed from the board. On upgrade, inherit the highest growth value from the three materials." % (1.0 + float(d.get("post_battle_all_stat_growth", 0.20)))
		"balance_judge":
			return "Balance Judgement: Deal +%s damage against targets with more current HP than this unit." % _pct(float(d.get("bonus_vs_higher_hp", 0.40)))
		"bubble_dream":
			return "Bubble Dream%s: Heal the lowest-HP ally for %d HP; slow the nearest enemy by %s and deal %d true damage." % [cd, int(d.get("heal", 80)), _pct(float(d.get("slow_pct", 0.30))), int(d.get("burst_damage", 70))]
		"shell_guard":
			return "Shell Guard: Gain %s damage reduction for %.1fs." % [_pct(float(d.get("reduction", 0.50))), float(d.get("duration", 5.0))]
		"gold_charge":
			return "Gold Charge%s: Rush the nearest enemy, deal %d true damage and stun for %.1fs." % [cd, int(d.get("skill_damage", 120)), float(d.get("stun_sec", 1.2))]
		"holy_song":
			return "Holy Song%s: Heal all allies for %s max HP and cleanse all crowd-control debuffs." % [cd, _pct(float(d.get("heal_pct", 0.15)))]
		"twin_strike":
			return "Mirror Ambush%s: Summon a mirror clone with %s HP and %s ATK." % [cd, _pct(float(d.get("clone_hp_pct", 0.30))), _pct(float(d.get("clone_atk_pct", 0.40)))]
		"king_aura":
			return "King's Aura: Every 2s, buff nearby allies — AS +%s, Crit +%s." % [_pct(float(d.get("ally_aspd_bonus", 0.25))), _pct(float(d.get("ally_crit_bonus", 0.15)))]
		"arrow_rain":
			return "Arrow Rain%s: Strike the nearest %d enemies, each taking 85%% ATK damage." % [cd, int(d.get("targets", 5))]
		"blood_rampage":
			return "Blood Rage: For every %s max HP lost, gain AS +%s and Lifesteal +%s plus a small damage boost." % [_pct(float(d.get("hp_step", 0.10))), _pct(float(d.get("aspd_per_step", 0.10))), _pct(float(d.get("lifesteal_per_step", 0.05)))]
		"steel_order":
			return "Steel Order%s: Buff the nearest %d allies — DMG Reduce %s, AS +%s, CC Duration -%s for %.1fs." % [cd, int(d.get("buff_targets", 3)), _pct(float(d.get("damage_reduction", 0.20))), _pct(float(d.get("aspd_bonus", 0.20))), _pct(float(d.get("control_time_reduction", 0.30))), float(d.get("duration", 8.0))]
		"time_slow":
			return "Time Warp%s: Briefly boost own dodge; slow all enemies by %s for %.1fs." % [cd, _pct(float(d.get("slow_pct", 0.35))), float(d.get("duration", 5.0))]
		"death_hunt":
			return "Death Hunt: Prioritizes low-HP targets; kills restore %s max HP. Normal attacks break %d armor and reduce healing by %s for %.1fs." % [_pct(float(d.get("kill_heal_pct", 0.15))), int(d.get("armor_break", 8)), _pct(float(d.get("heal_reduction", 0.50))), float(d.get("duration", 4.0))]
	return "Skill description not yet available."

func _skill_cd_text(d: Dictionary) -> String:
	if d.has("skill_cd"):
		if _is_en():
			return " (CD %.1fs)" % float(d.get("skill_cd", 0.0))
		return "（冷却%.1f秒）" % float(d.get("skill_cd", 0.0))
	return ""

func _pct(value: float) -> String:
	return "%.0f%%" % (value * 100.0)

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
		"money_golden_altar":   return "准备阶段出现黄金祭坛按钮：-1 法阵 HP，+5 金，每回合最多 3 次，HP <=10 不可用；胡牌手激活后改为 +10 金。"
		"money_lucky_envelope": return "战后随机 +1~3 金；与时空压缩联动后额外随机 +5~7 金，10% 概率额外 +10 金。"
		"elem_flame_shatter":   return "攻击有 25% 概率额外造成 40% ATK 真实伤害；与吸血纹章联动后提高到 100%。"
		"elem_frost_blade":     return "攻击有 25% 概率使目标移动/攻速 -35%，持续 1.5 秒；与打断锁链联动后目标受伤 +15%。"
		"elem_thunder_haste":   return "攻击有 25% 概率使自身攻速 +60%，持续 3 秒，重复触发只刷新时间；与复利之道联动后造成伤害 10% 概率 +1 金。"
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
		"money_golden_altar":   return "Adds a Golden Altar button during prep: spend 1 Formation HP to gain +5G (max 3 times per round; unavailable at HP ≤10). With Hu Pai Master: +10G."
		"money_lucky_envelope": return "After battle, gain a random +1~3G. Synergy with Time Compress: +5~7G extra, with 10% chance of +10G."
		"elem_flame_shatter":   return "25% chance on attack to deal extra 40% ATK true damage. Synergy with Lifesteal Emblem: increases to 100%."
		"elem_frost_blade":     return "25% chance on attack to reduce target movement and AS by 35% for 1.5s. Synergy with Interrupt Chain: target takes +15% damage."
		"elem_thunder_haste":   return "25% chance on attack to grant own AS +60% for 3s (refreshes on re-trigger). Synergy with Compound Interest: 10% chance to gain +1G on damage."
		"elem_toxic_spread":    return "25% chance on attack to poison the target. Synergy with Burst Core: 50% chance to instantly resolve remaining poison damage."
	return "Description not yet available."

func _treasure_link_effect_text(link_id: String) -> String:
	if _is_en():
		match link_id:
			"link_phoenix":           return "Friendly normal units temporarily revive for 3s after dying, then die for real."
			"link_money_magic":       return "After battle, gain an extra random +5~7G, with a 10% chance of +10G."
			"link_blood_covenant":    return "Flame Shatter true damage increases from 40% ATK to 100% ATK."
			"link_paralysis_shackles":return "On successful interrupt, also apply ice effect; ice-affected targets take +15% damage."
			"link_oppression_counter":return "When a friendly normal unit is hit, apply ATK -20% to the attacker for 2s; also stacks Frenzy Assault AS logic on them."
			"link_fraud_fate":        return "Generous Fate becomes: 60% chance to double gold, 40% chance to lose 50% of gold."
			"link_iron_maiden":       return "When a friendly normal unit is hit, inflict bleed and armor break on the attacker (CD 5s)."
			"link_toxic_burst":       return "On dealing damage, 50% chance to instantly resolve remaining poison on poisoned targets."
			"link_rich_path":         return "10% chance to gain +1G on dealing damage."
			"link_clearance_sale":    return "Auto-activates when Fury Roster + Discount Token are both owned: shop prices -40%."
			"link_hu_pai_master":     return "Activates when Life Monument + Formation Heal + Shockwave + Blood Pact + Fury Roster are all owned: doubles the positive values of the first four treasures, and Fury Roster's unit cap gains +1 more (7 -> 9); cooldowns, chances, and costs unchanged."
		return "Synergy description not yet available."
	match link_id:
		"link_phoenix":           return "我方普通棋子死亡后临时复活 3 秒，之后强制死亡。"
		"link_money_magic":       return "战后额外随机 +5~7 金，10% 概率额外 +10 金。"
		"link_blood_covenant":    return "炎焰碎裂触发时，真实伤害从 ATK 40% 提高到 ATK 100%。"
		"link_paralysis_shackles":return "打断成功后额外触发冰效果，被冰影响目标受伤 +15%。"
		"link_oppression_counter":return "我方普通棋子被攻击时，对攻击者施加减攻 20%，持续 2 秒；攻击者也会被叠加狂暴进攻攻速逻辑。"
		"link_fraud_fate":        return "慷慨命运变为每回合手动赌博 1 次：60% 金币翻倍，40% 损失当前金币 50%。"
		"link_iron_maiden":       return "我方普通棋子受击时反施失血和破甲，冷却 5 秒。"
		"link_toxic_burst":       return "造成伤害时，中毒目标有 50% 概率提前结算剩余毒伤。"
		"link_rich_path":         return "造成伤害后 10% 概率 +1 金。"
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
