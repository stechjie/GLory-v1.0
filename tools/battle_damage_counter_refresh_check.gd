extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Hud := preload("res://effects/runtime/presentation/BattleCombatFeedback.gd")
const Plate := preload("res://effects/runtime/presentation/DamageCounterPlate.gd")

class DrawProbe extends Plate:
	var draw_count := 0
	func _draw() -> void:
		draw_count += 1
		super._draw()

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

	var hud := Hud.new()
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
	hud.free()
	h.finish(get_tree())
