extends Node

const Renderer := preload("res://scenes/battle/BattleRenderer.gd")
const CheckHarness := preload("res://tools/CheckHarness.gd")

func _ready() -> void:
	if "--bar-preview" in OS.get_cmdline_user_args():
		call_deferred("_preview")
		return
	var h := CheckHarness.new("battle_health_bar")
	var host := Control.new()
	add_child(host)
	Renderer._add_health_bar(host, {"hp": 1000, "max_hp": 1000, "shield": 1000}, "player")
	var hp := host.get_node("HpFill") as ColorRect
	var shield := host.get_node("ShieldFill") as ColorRect
	var track := host.get_node("ShieldTrack") as Control
	var bg := host.get_node("HpBg") as ColorRect
	var icon := track.get_node("ShieldIcon") as Polygon2D
	var icon_position := icon.global_position
	var initial_count := host.get_child_count()
	h.expect(hp.color == Color(0.2, 0.9, 0.25), "friendly_color", "Friendly HP must remain green")
	h.expect(bg.self_modulate.a == 1.0, "hidden_background", "Execute warning background must remain visible")
	h.expect(shield.position.x > hp.position.x + hp.size.x, "shield_overlaps_hp", "Shield must start beyond the full HP slot")
	var previous_width := shield.size.x
	# Absorbed hits must shrink only the blue bar, never grow or shrink HP.
	for remaining in [1000, 750, 250, 1, 0]:
		Renderer._sync_health_segments(hp, {"hp": 1000, "max_hp": 1000, "shield": remaining})
		h.expect(is_equal_approx(hp.size.x * hp.scale.x, 66.0), "hp_moved_on_shield_hit", "Shield damage changed full HP width")
		h.expect(shield.size.x <= previous_width, "shield_grew_on_hit", "Blue bar grew while shield was consumed")
		h.expect(shield.visible == (remaining > 0) and track.visible == (remaining > 0), "shield_visibility", "Shield and icon must disappear together at zero")
		h.expect(icon.global_position == icon_position, "icon_drift", "Shield icon moved while the shield was consumed")
		previous_width = shield.size.x
	Renderer._sync_health_segments(hp, {"hp": 600, "max_hp": 1000, "shield": 0})
	h.expect(is_equal_approx(hp.size.x * hp.scale.x, 39.6), "hp_after_break", "After shield breaks, HP must use its original fixed scale")
	for shield_amount in [1, 500, 1000, 100000]:
		Renderer._sync_health_segments(hp, {"hp": 600, "max_hp": 1000, "shield": shield_amount})
		h.expect(is_equal_approx(hp.scale.x, 0.6), "shield_grant_changed_hp", "Adding or stacking shield changed HP percentage")
		h.expect(shield.size.x >= 1.0 and shield.size.x <= 24.0, "shield_bounds", "Positive shield must remain visible and bounded")
		h.expect((icon.get_node("Overflow") as Control).visible == (shield_amount > 1000), "overflow_marker", "Overflow marker disagrees with shield exceeding max HP")
	Renderer._sync_health_segments(hp, {"hp": 100, "max_hp": 1000, "shield": 3000})
	h.expect(is_equal_approx(hp.size.x * hp.scale.x, 6.6), "execute_threshold", "10% HP no longer aligns with the existing execute marker")
	Renderer._sync_health_segments(hp, {"hp": 0, "max_hp": 1000, "shield": 3000})
	h.expect(is_zero_approx(hp.scale.x) and not hp.visible and not shield.visible and not track.visible, "death_left_shield", "Death must hide HP and even stale shield values")
	h.expect(not (host.get_node("HpEmpty") as Control).visible, "death_empty_outline", "Death left the empty segment visible")
	h.expect(host.get_child_count() == initial_count, "node_churn", "Updates recreated health bar controls")
	# Death handoff also supports older/bare HP nodes without shield metadata.
	var bare_hp := ColorRect.new()
	Renderer._sync_health_segments(bare_hp, {"hp": 0, "max_hp": 1})
	h.expect(is_zero_approx(bare_hp.scale.x), "bare_death", "Bare HP death handoff failed")
	bare_hp.free()
	var enemy := Control.new()
	add_child(enemy)
	Renderer._add_health_bar(enemy, {"hp": 500, "max_hp": 1000, "shield": 200}, "enemy")
	h.expect((enemy.get_node("HpFill") as ColorRect).color == Color(1.0, 0.18, 0.12), "enemy_color", "Enemy HP must remain red")
	h.expect((enemy.get_node("ShieldFill") as ColorRect).color == shield.color, "shield_team_color", "Shield must be blue for both teams")
	h.finish(get_tree())


func _text(parent: Node, value: String, pos: Vector2, font_size := 18) -> void:
	var label := Label.new()
	label.text = value
	label.position = pos
	label.add_theme_font_size_override("font_size", font_size)
	parent.add_child(label)


func _preview() -> void:
	get_window().content_scale_size = Vector2i(960, 640)
	var canvas := Control.new()
	add_child(canvas)
	var bg := ColorRect.new()
	bg.color = Color("172328")
	bg.size = Vector2(960, 640)
	canvas.add_child(bg)
	_text(canvas, "BATTLE HP + RIGHT-SIDE SHIELD", Vector2(28, 16), 24)
	_text(canvas, "Actual controls / 1x", Vector2(340, 57), 16)
	_text(canvas, "3x detail", Vector2(566, 57), 16)
	var cases := [
		["Full health / no shield", 1000, 0, "player"],
		["Full health / 1000 shield", 1000, 1000, "player"],
		["Shield hit / 250 shield left", 1000, 250, "player"],
		["Shield broken / HP unchanged", 1000, 0, "player"],
		["Next hit / 600 HP", 600, 0, "player"],
		["Low HP / overflowing shield (+)", 100, 3000, "enemy"],
		["Last shield point", 600, 1, "player"],
		["Dead / stale shield hidden", 0, 1000, "enemy"],
	]
	for i in cases.size():
		var item: Array = cases[i]
		var y := 94.0 + i * 46.0
		_text(canvas, str(item[0]), Vector2(28, y), 16)
		for zoom in [1.0, 3.0]:
			var unit := Control.new()
			unit.position = Vector2(340 if zoom == 1.0 else 550, y - (14 if zoom == 3.0 else 0))
			unit.scale = Vector2.ONE * zoom
			canvas.add_child(unit)
			Renderer._add_health_bar(unit, {"hp": item[1], "max_hp": 1000, "shield": item[2]}, str(item[3]))
	_text(canvas, "Dense layout sample (1x) - not an in-battle capture", Vector2(28, 482), 17)
	for i in range(14):
		var unit := Control.new()
		unit.position = Vector2(28 + (i % 7) * 128, 520 + (i / 7) * 40)
		canvas.add_child(unit)
		Renderer._add_health_bar(unit, {"hp": 350 + (i % 4) * 200, "max_hp": 1000, "shield": (i % 5) * 300}, "player" if i < 7 else "enemy")
	for i in range(6):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var output := "res://artifacts/battle_health_shield_20261104/preview.png"
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var result := get_viewport().get_texture().get_image().save_png(output)
	print("HEALTH_BAR_PREVIEW ", result, " ", output)
	get_tree().quit(result)
