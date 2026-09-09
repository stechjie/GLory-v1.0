extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const StatsPanel := preload("res://scenes/prep/panels/BattleStatsPanel.gd")
const PrepScreen := preload("res://scenes/prep/PrepScreen.gd")
const Warmup := preload("res://effects/vfx3d/VFXWarmup.gd")
var h: RefCounted

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	h = Harness.new("bug_0909_regression")
	var state := {"unit_stats": {"caster": {"name": "caster", "group": "player", "debuffs": {}, "buffs": {}}}}
	var target := {"def": {}, "statuses": {}}
	DamageService.begin_stat_context(state, {"uid": "caster"})
	StatusEffectService.add_status(target, "poison", 4.0)
	StatusEffectService.add_status(target, "speed_bonus", 3.0)
	var entry: Dictionary = state.unit_stats.caster
	h.expect(entry.debuffs.get("poison", 0.0) == 4.0, "debuff", "Applied debuff duration not recorded for caster")
	h.expect(entry.buffs.get("speed_bonus", 0.0) == 3.0, "buff", "Applied buff duration not recorded for caster")
	StatusEffectService.add_status(target, "poison", 4.0)
	h.expect(entry.debuffs.poison == 4.0, "refresh", "Refresh counted existing time twice")
	target.statuses.poison.remaining = 2.0
	StatusEffectService.add_status(target, "poison", 4.0)
	h.expect(entry.debuffs.poison == 6.0, "extension", "Extended duration missing")
	var boss := {"def": {"is_boss": true}, "statuses": {}}
	StatusEffectService.add_status(boss, "stun", 4.0)
	h.expect(entry.debuffs.get("stun", 0.0) == 2.0, "boss_resistance", "Duration did not account for boss resistance")
	var reduced := {"def": {}, "statuses": {"control_time_reduction": {"remaining": 5.0, "pct": 0.5}}}
	StatusEffectService.add_status(reduced, "silence", 4.0)
	h.expect(entry.debuffs.get("silence", 0.0) == 2.0, "control_resistance", "Duration did not account for control resistance")
	DamageService.clear_stat_context()
	StatusEffectService.add_status(target, "burn", 2.0)
	h.expect(not entry.debuffs.has("burn"), "source_isolation", "Unattributed status leaked into previous caster")
	var saved := GameState.battle_history.duplicate(true)
	GameState.battle_history.clear()
	GameState.battle_history.append(state.duplicate(true))
	var panel := StatsPanel.new()
	var label := RichTextLabel.new()
	panel.add_child(label)
	panel._stats_text = label
	panel._refresh_popup()
	h.expect(label.text.contains(BattleStatsFormat.status_display_name("poison")) and label.text.contains("6"), "display_debuff", "Real status data absent from stats popup")
	h.expect(label.text.contains(BattleStatsFormat.status_display_name("speed_bonus")), "display_buff", "Real buff absent from stats popup")
	panel.free()
	GameState.battle_history.assign(saved)
	DamageService.set_stat_state({})
	var warm := Warmup.new()
	warm._build_label()
	h.expect(warm.get_child_count() == 0, "warmup_hidden", "Default debug build still creates warmup HUD")
	warm.free()
	var camp: Script = PrepScreen._carrot_camp_panel_script()
	h.expect(camp != null and camp.can_instantiate(), "missing_art_fallback", "Missing optional art prevents preparation panel from loading")
	h.finish(get_tree())
