extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Hud := preload("res://effects/runtime/presentation/BattleCombatFeedback.gd")
const Plate := preload("res://effects/runtime/presentation/DamageCounterPlate.gd")
const Vfx := preload("res://scenes/battle/BattleVfx.gd")
const Frenzy := preload("res://scripts/battle/BattleFrenzyService.gd")
const LaneBoard := preload("res://effects/runtime/presentation/LaneClearBoard.gd")

class DrawProbe extends Plate:
	var draw_count := 0
	func _draw() -> void:
		draw_count += 1
		super._draw()

class RibbonDrawProbe extends LaneBoard.Ribbon:
	var draw_count := 0
	func _draw() -> void:
		draw_count += 1
		super._draw()

class DamageHudProbe extends Hud:
	var show_calls := 0
	var last_animate := false
	var last_round := 0
	func show_damage(total: int, animate := true, round_index := 11) -> void:
		show_calls += 1
		last_animate = animate
		last_round = round_index
		super.show_damage(total, animate, round_index)

class DamageRendererProbe extends Vfx:
	var feedback: Control
	var ownership_checks := 0
	var uid_lookups := 0
	var damage_reads := 0
	func _ensure_combat_feedback() -> Control:
		return feedback
	func _owned_by_local_player(unit: Dictionary) -> bool:
		ownership_checks += 1
		return super._owned_by_local_player(unit)
	func _is_local_owned_unit(uid: String) -> bool:
		uid_lookups += 1
		return super._is_local_owned_unit(uid)
	func _fighter_damage_dealt(fighter: Dictionary) -> int:
		damage_reads += 1
		return super._fighter_damage_dealt(fighter)
	func reset_counts() -> void:
		ownership_checks = 0
		uid_lookups = 0
		damage_reads = 0

func _ready() -> void:
	call_deferred("_run")

func _settle() -> void:
	for _i in 3:
		await get_tree().process_frame

func _run() -> void:
	var h := Harness.new("battle_damage_counter_refresh")
	var plate := DrawProbe.new()
	plate.size = Vector2(286, 84)
	add_child(plate)
	await _settle()
	h.expect(plate.draw_count > 0, "initial_draw", "the actual Canvas redraw callback must run before comparing redraw counts")
	var before := plate.draw_count
	for _i in 120:
		plate.set_accent(plate.accent)
	await _settle()
	h.expect(plate.draw_count == before, "unchanged_accent_draw", "same-color damage updates must not rebuild the retained plate")
	var changed_color := Color("11aacc")
	plate.set_accent(changed_color)
	await _settle()
	h.expect(plate.accent == changed_color and plate.draw_count == before + 1,
		"changed_accent_draw", "a real accent change must retain its value and redraw once")
	before = plate.draw_count
	for _i in 120:
		plate.set_accent(changed_color)
	await _settle()
	h.expect(plate.draw_count == before, "changed_accent_stable", "repeating the new accent must become idle again")
	plate.free()

	var hud := DamageHudProbe.new()
	hud.size = Vector2(1600, 720)
	add_child(hud)
	await _settle()
	hud.show_damage(100, false, 1)
	await _settle()
	var font_size := hud._damage_label.get_theme_font_size("font_size")
	var changes := [0, 0]
	hud._damage_label.theme_changed.connect(func() -> void: changes[0] += 1)
	hud._damage_depth.theme_changed.connect(func() -> void: changes[1] += 1)
	for value in range(101, 200):
		hud.show_damage(value, false, 1)
	h.expect(changes == [0, 0], "same_size_theme_changes", "changing totals within the same fitted size must not dirty either label's font")
	h.expect(hud._damage_label.text == "× 199" and hud._damage_depth.text == "× 199",
		"damage_text", "front and depth totals must still update immediately")
	h.expect(hud._damage_label.get_theme_font_size("font_size") == font_size
		and hud._damage_depth.get_theme_font_size("font_size") == font_size,
		"same_size_preserved", "normal digit updates must retain their approved size")
	hud.show_damage(999999999999, false, 1)
	var fitted := hud._damage_label.get_theme_font_size("font_size")
	h.expect(fitted < font_size and changes == [1, 1], "real_font_size_change",
		"a larger total must still shrink both labels once when the fitted size changes")
	h.expect(hud._damage_label.text == "× 999,999,999,999" and hud._damage_depth.text == hud._damage_label.text,
		"grouped_total", "large authoritative damage totals must keep complete grouped text")
	for _i in 120:
		hud._refresh_text()
	h.expect(changes == [1, 1], "repeated_fitted_size", "refreshing a stable fitted value must not emit additional theme changes")
	hud.show_damage(200, false, 1)
	h.expect(hud._damage_label.get_theme_font_size("font_size") == font_size and changes == [2, 2],
		"restore_font_size", "a smaller total must restore the original size on both labels")
	hud.show_damage(1000, true, 1)
	h.expect(hud._damage_tween != null and hud._damage_tween.is_valid(),
		"damage_animation", "real damage changes must retain their damage animation")
	h.expect(hud._plate.accent == Hud.EARLY_DAMAGE_COLORS[1],
		"tier_accent", "crossing a damage tier must still apply the correct accent")
	hud.reset_feedback()
	h.expect(not hud._damage_label.visible and not hud._damage_depth.visible,
		"reset_visibility", "reset must still hide both damage layers")
	_check_renderer(h, hud)
	hud.free()
	_check_frenzy(h)
	await _check_ribbon(h)
	h.finish(get_tree())


func _check_renderer(h: RefCounted, hud: DamageHudProbe) -> void:
	var was_team_active := NetworkService.team_active
	var was_local_slot := NetworkService.team_local_slot
	var was_team_mode := GameState.team_mode
	var was_round := GameState.round_index
	NetworkService.team_active = false
	GameState.team_mode = false
	GameState.round_index = 11
	var renderer := DamageRendererProbe.new()
	renderer.feedback = hud
	renderer._state = {
		"player": [
			{"uid": "own", "team": "player", "owner_slot": 0, "damage_dealt": 10},
			{"uid": "stats", "team": "player", "owner_slot": 0},
			{"uid": "ally", "team": "player", "owner_slot": 1, "damage_dealt": 100},
			{"uid": "boss", "team": "player", "owner_slot": 0, "damage_dealt": 500},
			{"uid": "dead", "team": "player", "owner_slot": 0, "hp": 0, "damage_dealt": 5}],
		"enemy": [{"uid": "enemy", "team": "enemy", "owner_slot": -1, "damage_dealt": 100}],
		"unit_stats": {"stats": {"damage_dealt": 20}, "boss": {"group": "boss"}},
		"element_damage_by_slot": {"0": 7}}
	hud.show_calls = 0
	renderer._refresh_damage_counter()
	h.expect(hud.visible and hud._damage_total == 42 and hud.show_calls == 1,
		"renderer_legacy_total", "Fallback totals keep dead-unit damage, stats, boss exclusion and string-key elemental damage")
	h.expect(renderer.ownership_checks == 6 and renderer.damage_reads == 3 and renderer.uid_lookups == 0,
		"renderer_linear_ownership", "Fallback visits each fighter once and never resolves an existing dictionary by uid")
	h.expect(hud.last_animate and hud.last_round == 11,
		"renderer_animation_args", "Normal refresh keeps its animation and round arguments")
	renderer._state["presentation_slot_damage"] = [123]
	renderer._state["presentation_damage_silent"] = true
	GameState.round_index = 10
	renderer.reset_counts()
	renderer._refresh_damage_counter()
	h.expect(hud._damage_total == 123 and not hud.last_animate and hud.last_round == 10,
		"renderer_authoritative_snapshot", "Replay snapshot replaces unit and elemental totals and keeps silent-seek/round semantics")
	h.expect(renderer.ownership_checks == 1 and renderer.damage_reads == 0 and renderer.uid_lookups == 0,
		"renderer_snapshot_short_circuit", "An authoritative snapshot only searches until local-unit presence is known")
	renderer._state["presentation_slot_damage"] = [0]
	renderer._refresh_damage_counter()
	h.expect(hud.visible and hud._damage_total == 0, "renderer_zero_snapshot", "A zero snapshot is authoritative and still shows a local plate")
	renderer._state["presentation_slot_damage"] = []
	renderer._refresh_damage_counter()
	h.expect(hud._damage_total == 42, "renderer_missing_snapshot", "An absent slot falls back to complete legacy damage")

	NetworkService.team_active = true
	NetworkService.team_local_slot = 4
	renderer._state = {"player": [{"uid": "opponent", "team": "player", "owner_slot": 0, "damage_dealt": 100}],
		"enemy": [{"uid": "self", "team": "enemy", "owner_slot": 4, "damage_dealt": 33},
			{"uid": "mate", "team": "enemy", "owner_slot": 5, "damage_dealt": 100}],
		"element_damage_by_slot": {4: 9}}
	renderer._refresh_damage_counter()
	h.expect(hud.visible and hud._damage_total == 42, "renderer_blue_slot", "B-side ownership uses its seat, excludes teammates and accepts integer-key elemental damage")
	renderer._state["enemy"] = [{"uid": "mate", "team": "enemy", "owner_slot": 5}]
	renderer._state["presentation_slot_damage"] = [0, 0, 0, 0, 999]
	hud.show_calls = 0
	renderer._refresh_damage_counter()
	h.expect(not hud.visible and hud.show_calls == 0 and hud._damage_total == 42,
		"renderer_no_local_unit", "A snapshot cannot make a single plate appear when the local roster is empty")
	NetworkService.team_local_slot = -1
	renderer._state["enemy"] = [{"uid": "unowned", "team": "enemy", "owner_slot": -1}]
	renderer._refresh_damage_counter()
	h.expect(not hud.visible, "renderer_spectator", "A spectator must not own unassigned units")
	NetworkService.team_active = false
	GameState.team_mode = true
	renderer._state = {"player": [], "enemy": [{"uid": "converted", "team": "enemy", "owner_slot": 0, "damage_dealt": 17}]}
	renderer._refresh_damage_counter()
	h.expect(hud.visible and hud._damage_total == 17, "renderer_local_team_mode", "Local team mode keeps seat ownership across allegiance changes")

	var roster: Array = []
	for i in 64:
		roster.append({"uid": "own_%d" % i, "team": "player", "owner_slot": 0, "damage_dealt": 1})
	renderer._state = {"player": roster, "enemy": []}
	renderer.reset_counts()
	renderer._refresh_damage_counter()
	h.expect(hud._damage_total == 64 and renderer.ownership_checks == 64 and renderer.damage_reads == 64 and renderer.uid_lookups == 0,
		"renderer_large_roster_linear", "A 64-unit fallback performs 64 ownership checks instead of 64 full-roster uid scans")
	hud.set_single_plate_enabled(false)
	hud.visible = false
	var rank_child := Control.new()
	hud.add_child(rank_child)
	var prior_total := hud._damage_total
	var prior_tier := hud._current_tier
	var prior_round := hud._round_index
	hud.show_calls = 0
	renderer.reset_counts()
	for _i in 120:
		renderer._refresh_damage_counter()
	h.expect(hud.visible and rank_child.is_visible_in_tree(),
		"renderer_leaderboard_parent", "The feedback parent remains visible so the leaderboard, purse and other feedback keep displaying")
	h.expect(renderer.ownership_checks == 0 and renderer.damage_reads == 0 and renderer.uid_lookups == 0 and hud.show_calls == 0,
		"renderer_disabled_plate_idle", "120 leaderboard-only refreshes perform no single-plate ownership or damage work")
	h.expect(hud._damage_total == prior_total and hud._current_tier == prior_tier and hud._round_index == prior_round,
		"renderer_disabled_bookkeeping", "Disabled-plate internal totals and tier state remain unchanged, matching show_damage's early return")
	hud.set_single_plate_enabled(true)
	renderer._refresh_damage_counter()
	h.expect(hud.visible and hud._damage_label.visible and hud._damage_depth.visible and hud._damage_total == 64 and hud.show_calls == 1,
		"renderer_reenable", "Re-enabling the plate restores both damage layers even when the total has not changed")
	renderer.free()
	NetworkService.team_active = was_team_active
	NetworkService.team_local_slot = was_local_slot
	GameState.team_mode = was_team_mode
	GameState.round_index = was_round


func _check_frenzy(h: RefCounted) -> void:
	var renderer := DamageRendererProbe.new()
	var panel := Control.new()
	var label := Label.new()
	var warning_color := Color(1.0, 0.86, 0.34)
	# Matching inherited color must still acquire the explicit override once.
	var theme := Theme.new()
	theme.set_color("font_color", "Label", warning_color)
	label.theme = theme
	panel.add_child(label)
	add_child(panel)
	renderer._frenzy_lbl = label
	renderer._state = {"elapsed": 29.0}
	var changes := [0]
	label.theme_changed.connect(func() -> void: changes[0] += 1)
	renderer._refresh_frenzy_hud()
	h.expect(not panel.visible and changes[0] == 0, "frenzy_pre_warning", "Before 30 seconds the warning stays hidden without a theme update")
	renderer._state["elapsed"] = 30.0
	renderer._refresh_frenzy_hud()
	h.expect(panel.visible and label.has_theme_color_override("font_color") and changes[0] == 1,
		"frenzy_initial_override", "The first warning sets its explicit color even when the inherited color already matches")
	var first_text := label.text
	for _i in 120:
		renderer._refresh_frenzy_hud()
	renderer._state["elapsed"] = 31.0
	renderer._refresh_frenzy_hud()
	h.expect(changes[0] == 1 and label.text != first_text and label.get_theme_color("font_color") == warning_color,
		"frenzy_countdown_idle_theme", "Countdown text keeps advancing while 120 same-color frames cause no extra theme changes")
	var times := [Frenzy.FRENZY_I_SEC, Frenzy.FRENZY_II_SEC, Frenzy.FRENZY_III_SEC, Frenzy.SUDDEN_DEATH_SEC]
	var colors := [Color(1.0, 0.78, 0.24), Color(1.0, 0.52, 0.18), Color(1.0, 0.30, 0.18), Color(1.0, 0.18, 0.14)]
	var captions := ["battle_frenzy_i", "battle_frenzy_ii", "battle_frenzy_iii", "battle_sudden_death"]
	for i in times.size():
		renderer._state["elapsed"] = times[i]
		renderer._refresh_frenzy_hud()
		h.expect(changes[0] == i + 2 and label.get_theme_color("font_color") == colors[i] and label.text == tr(captions[i]),
			"frenzy_phase_%d" % i, "Each frenzy stage keeps its exact caption/color and emits one real theme change")
		for _j in 120:
			renderer._refresh_frenzy_hud()
		h.expect(changes[0] == i + 2, "frenzy_phase_idle_%d" % i, "A stable frenzy stage must not dirty the label theme again")
	renderer._finished = true
	renderer._refresh_frenzy_hud()
	h.expect(not panel.visible and changes[0] == 5, "frenzy_finish_hide", "Finishing hides the warning without changing its theme")
	panel.free()
	renderer.free()


func _check_ribbon(h: RefCounted) -> void:
	var ribbon := RibbonDrawProbe.new()
	ribbon.font = LaneBoard.DISPLAY_FONT
	ribbon.size = LaneBoard.RIBBON_SIZE
	add_child(ribbon)
	await _settle()
	var before := ribbon.draw_count
	h.expect(before > 0, "ribbon_initial_draw", "A new first-place ribbon must draw normally before rank updates")
	for _i in 120:
		ribbon.set_rank(0)
	await _settle()
	h.expect(ribbon.draw_count == before and ribbon._rank == 0,
		"ribbon_same_rank_idle", "120 unchanged first-place ticks must preserve the retained drawing")
	ribbon.set_rank(1)
	await _settle()
	h.expect(ribbon.draw_count == before + 1 and ribbon._rank == 1,
		"ribbon_real_rank_change", "A real rank change must redraw once with the new medal color and digits")
	ribbon.set_rank(99)
	await _settle()
	h.expect(ribbon.draw_count == before + 2 and ribbon._rank == 2,
		"ribbon_clamped_rank_change", "Out-of-range ranks still clamp to third place and redraw when it changes")
	for _i in 120:
		ribbon.set_rank(99)
		ribbon.set_rank(2)
	await _settle()
	h.expect(ribbon.draw_count == before + 2,
		"ribbon_clamped_same_idle", "Repeated values that clamp to the same rank must not redraw")
	ribbon.free()
