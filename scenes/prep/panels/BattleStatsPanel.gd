extends Control

# 备战界面的**战力与战报面板** —— D2 步骤 4′。
#
# 两个弹窗：
#   * 战力推荐 —— 我方当前战力 vs 下一场敌方的估算
#   * 上一场战报 —— 逐单位的伤害/承伤/治疗表
#
# 这个面板**只读不写**：它不改任何游戏状态，只把 GameState 与 battle_history
# 里已经有的数字算出来、排好、显示出来。所以它一条信号都不需要 ——
# 与 ShopPanel 形成对照：需要信号的是「会改状态的动作」，纯显示不需要。
#
# 战力公式本身在 PrepPowerEstimate，数字格式化在 PrepPowerFormat；
# 这里只负责「问谁、算几个、怎么排版」。

const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")
const PrepRules := preload("res://scenes/prep/PrepRules.gd")
const PrepPowerFormat := preload("res://scenes/prep/PrepPowerFormat.gd")
const PrepPowerEstimate := preload("res://scenes/prep/PrepPowerEstimate.gd")

var overlay: RefCounted


func setup(p_overlay: RefCounted) -> void:
	overlay = p_overlay


# --- 搬过来的成员 ---
var _stats_popup: PopupPanel
var _stats_text: RichTextLabel
var _stats_group := "player"


# 原 _show_last_battle_stats（PrepDetails.gd）

# ─── battle stats ─────────────────────────────────────────────────────────────

func show_last_battle() -> void:
	if _stats_popup == null or _stats_text == null:
		return
	if GameState.battle_history.is_empty():
		_stats_text.text = "[b]%s[/b]\n\n%s" % [tr("stats_title"), tr("stats_no_history")]
		_stats_popup.popup_centered(Vector2i(960, 500))
		return
	_stats_group = "player"
	_refresh_popup()
	_stats_popup.popup_centered(Vector2i(960, 500))



# 原 _show_power_recommendation（PrepDetails.gd）

# ─── power recommendation ─────────────────────────────────────────────────────

func show_power_recommendation() -> void:
	if overlay == null or not overlay.is_ready():
		return
	overlay.text_label.custom_minimum_size = Vector2(400, 210)
	if PrepWidgets.is_en():
		overlay.text_label.text = "[b]Power Rating[/b]\n[b]Next battle: %s[/b]\n\n%s\nYours: %s\n\nFormula: Effective HP + 10s damage output" % [
			next_round_kind_label(),
			next_enemy_power_text(),
			PrepPowerFormat.format_power(current_player_power(), PrepWidgets.is_en()),
		]
	else:
		overlay.text_label.text = "[b]战力推荐[/b]\n[b]下一战：%s[/b]\n\n%s\n己方当前：%s\n\n计算：有效生命 + 10秒输出" % [
			next_round_kind_label(),
			next_enemy_power_text(),
			PrepPowerFormat.format_power(current_player_power(), PrepWidgets.is_en()),
		]
	overlay.show_power(overlay.text_label.text)


# 原 _refresh_stats_popup（PrepDetails.gd）

func _refresh_popup() -> void:
	if _stats_text == null:
		return
	var result := _last_result()
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
		if _entry_group(entry) == _stats_group:
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
	lines.append("[b]%s - %s[/b]" % [tr("stats_last_battle"), _group_label(_stats_group)])
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
				_display_name(row),
				_display_position(row),
				int(row.get("damage_dealt", 0)),
				int(row.get("damage_taken", 0)),
				int(row.get("healing_done", 0)),
				_sanitize_cell(_format_status_bucket(row.get("debuffs", {}))),
				_sanitize_cell(_format_status_bucket(row.get("buffs", {}))),
			]:
				lines.append("[cell]%s[/cell]" % _color_cell(row, str(value)))
	lines.append("[/table]")
	_stats_text.text = "\n".join(lines)



# 原 _last_battle_result_for_stats（PrepDetails.gd）
func _last_result() -> Dictionary:
	if GameState.battle_history.is_empty():
		return {}
	var last = GameState.battle_history.back()
	return last if typeof(last) == TYPE_DICTIONARY else {}



# 原 _stats_group_label（PrepDetails.gd）
func _group_label(group: String) -> String:
	if PrepWidgets.is_en():
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



# 原 _entry_stats_group（PrepShared.gd）
func _entry_group(entry: Dictionary) -> String:
	return ""



# 原 _sanitize_stats_cell（PrepShared.gd）
func _sanitize_cell(text: String) -> String:
	return ""



# 原 _format_status_bucket（PrepShared.gd）
func _format_status_bucket(value: Variant) -> String:
	return ""



# 原 _current_player_power（PrepDetails.gd）

# ─── power / enemy estimate ───────────────────────────────────────────────────

func current_player_power() -> float:
	var total := 0.0
	for cell in GameState.board_slots:
		if cell == null or typeof(cell) != TYPE_DICTIONARY:
			continue
		var dict: Dictionary = cell
		var d: Dictionary = dict.get("def", {}).duplicate(true)
		if d.is_empty():
			continue
		d = UnitFactory.apply_star_stats(d, int(dict.get("star", 1)))
		total += PrepPowerEstimate.unit_power_from_def(d)
	return total


# 原 _next_enemy_power_text（PrepDetails.gd）

func next_enemy_power_text() -> String:
	var kind := PrepRules.next_round_kind()
	if PrepWidgets.is_en():
		match kind:
			"pvp":   return "Next: PVP — opponent power hidden"
			"final": return "Next: Final PVP — opponent power hidden"
			"boss":
				return "Next Boss ~%s" % PrepPowerFormat.format_power(_estimated_boss_power(), PrepWidgets.is_en())
			_:
				var count_by_round: Dictionary = DataRegistry.get_table("pve_monsters").get("enemy_count_by_round", {})
				var count := int(count_by_round.get(str(GameState.round_index), 3))
				return "Next wave ~%s (%d units)" % [PrepPowerFormat.format_power(_estimated_pve_power(count), PrepWidgets.is_en()), count]
	match kind:
		"pvp":   return "下一战：PVP，不显示对方战力"
		"final": return "下一战：最终PVP，不显示对方战力"
		"boss":  return "下一战Boss约：%s" % PrepPowerFormat.format_power(_estimated_boss_power(), PrepWidgets.is_en())
		_:
			var count_by_round: Dictionary = DataRegistry.get_table("pve_monsters").get("enemy_count_by_round", {})
			var count := int(count_by_round.get(str(GameState.round_index), 3))
			return "下一波小怪约：%s（%d只）" % [PrepPowerFormat.format_power(_estimated_pve_power(count), PrepWidgets.is_en()), count]



# 原 _estimated_pve_power（PrepDetails.gd）
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
		total += PrepPowerEstimate.unit_power_from_def(d) * float(count)
	return total / float(monsters.size())



# 原 _estimated_boss_power（PrepDetails.gd）
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
		var unit_total := PrepPowerEstimate.unit_power_from_def(d)
		if bool(d.get("is_twin", false)):
			unit_total *= 2.0
		total += unit_total
		counted += 1
	return 0.0 if counted <= 0 else total / float(counted)



# 原 _stats_display_name（PrepDetails.gd）
func _display_name(row: Dictionary) -> String:
	return BattleStatsFormat.stats_display_name(row)



# 原 _stats_display_position（PrepDetails.gd）
func _display_position(row: Dictionary) -> String:
	return BattleStatsFormat.stats_display_position(row)



# 原 _stats_color_cell（PrepDetails.gd）
func _color_cell(row: Dictionary, text: String) -> String:
	return BattleStatsFormat.stats_color_cell(row, text)


# 原 _next_round_kind_label（PrepDetails.gd）
func next_round_kind_label() -> String:
	var kind := PrepRules.next_round_kind()
	if PrepWidgets.is_en():
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
