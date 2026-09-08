extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const StatsPanel := preload("res://scenes/prep/panels/BattleStatsPanel.gd")
var h: RefCounted

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	h = Harness.new("bug_0908_regression")
	_check_stats()
	h.finish(get_tree())

func _check_stats() -> void:
	var saved := GameState.battle_history.duplicate(true)
	var panel := StatsPanel.new()
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	panel.add_child(label)
	panel._stats_text = label
	var entries := {}
	for group in ["player", "enemy", "boss", "mercenary"]:
		entries[group] = {"name": "unit_" + group, "name_en": "unit_" + group,
			"group": group, "team": "player", "position": "[1]", "damage_dealt": 123,
			"damage_taken": 45, "healing_done": 6, "debuffs": {"poison": 2.5}, "buffs": {}}
	entries["enemy_merc"] = entries.mercenary.duplicate(true)
	entries.enemy_merc.team = "enemy"
	entries.enemy_merc.name = "enemy_merc"
	entries.enemy_merc.name_en = "enemy_merc"
	GameState.battle_history.clear()
	GameState.battle_history.append({"unit_stats": entries})
	for group in ["player", "enemy", "boss"]:
		panel._stats_group = group
		panel._refresh_popup()
		var text: String = label.text
		h.expect(text.contains("unit_" + group), "stats_" + group, "Expected unit missing from stats tab")
		h.expect(text.contains("123") and text.contains("45") and text.contains("2.5"), "stats_values_" + group, "Damage/status values missing")
		h.expect(text.contains("unit_mercenary") == (group == "player"), "ally_merc_" + group, "Allied mercenary in wrong tab")
		h.expect(text.contains("enemy_merc") == (group == "enemy"), "enemy_merc_" + group, "Enemy mercenary in wrong tab")
	h.expect(panel._sanitize_cell("[b]Name[/b]") == "bName/b", "sanitize", "BBCode must be escaped consistently")
	GameState.battle_history.clear()
	GameState.battle_history.append({})
	panel._refresh_popup()
	h.expect(not label.text.contains("unit_boss"), "empty_stats", "Empty result retained previous rows")
	GameState.battle_history.assign(saved)
	panel.free()
