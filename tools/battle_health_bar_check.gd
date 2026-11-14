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
	h.expect(is_equal_approx(shield.position.x, hp.position.x + hp.size.x * hp.scale.x), "shield_gap", "Blue must join the HP fill with no gap")
	h.expect(not track.has_node("ShieldBg"), "separate_shield_slot", "Shield must share the HP background")
	var previous_width := shield.size.x
	# Both colors share the original slot. Full HP plus shield fills it without
	# introducing an empty extension; only their internal proportions change.
	for remaining in [1000, 750, 250, 1, 0]:
		Renderer._sync_health_segments(hp, {"hp": 1000, "max_hp": 1000, "shield": remaining})
		h.expect(is_equal_approx(hp.size.x * hp.scale.x + shield.size.x, 66.0), "full_health_black_tail", "Full health with shield left an artificial empty tail")
		h.expect(bg.size == Vector2(72, 11), "background_extended", "Shield extended the original background")
		h.expect(shield.size.x <= previous_width, "shield_grew_on_hit", "Blue bar grew while shield was consumed")
		h.expect(shield.visible == (remaining > 0) and track.visible == (remaining > 0), "shield_visibility", "Shield and icon must disappear together at zero")
		h.expect(icon.global_position == icon_position, "icon_drift", "Shield icon moved while the shield was consumed")
		previous_width = shield.size.x
	Renderer._sync_health_segments(hp, {"hp": 600, "max_hp": 1000, "shield": 0})
	h.expect(is_equal_approx(hp.size.x * hp.scale.x, 39.6), "hp_after_break", "After shield breaks, HP must use its original fixed scale")
	for shield_amount in [1, 500, 1000, 100000]:
		Renderer._sync_health_segments(hp, {"hp": 600, "max_hp": 1000, "shield": shield_amount})
		h.expect(bg.size.x == 72.0 and shield.position.x + shield.size.x <= hp.position.x + 66.001, "shield_outside_slot", "Stacked shield extended beyond the original slot")
		h.expect(is_equal_approx(shield.position.x, hp.position.x + hp.size.x * hp.scale.x), "partial_hp_gap", "Blue must join partially depleted HP too")
		h.expect((host.get_node("HpEmpty") as Control).position.x >= shield.position.x + shield.size.x - 0.001, "outline_covers_shield", "Empty segment must not cover the blue tail")
		h.expect(shield.size.x >= 3.0 and shield.size.x <= 66.0, "shield_bounds", "Positive shield must remain visible and bounded")
		h.expect((icon.get_node("Overflow") as Control).visible == (shield_amount > 1000), "overflow_marker", "Overflow marker disagrees with shield exceeding max HP")
	Renderer._sync_health_segments(hp, {"hp": 600, "max_hp": 1000, "shield": 1000})
	var before_hit_width := shield.size.x
	Renderer._sync_health_segments(hp, {"hp": 600, "max_hp": 1000, "shield": 250}, 0.016)
	h.expect(shield.size.x < before_hit_width and shield.size.x > 16.5, "drain_not_smoothed", "Absorbed hits should visibly drain toward the new shield value")
	for i in range(12):
		Renderer._sync_health_segments(hp, {"hp": 600, "max_hp": 1000, "shield": 250}, 0.016)
	h.expect(is_equal_approx(shield.size.x, 16.5) and is_equal_approx(hp.scale.x, 0.6), "drain_not_settled", "Shield drain must settle at the remaining shield value")
	Renderer._sync_health_segments(hp, {"hp": 400, "max_hp": 1000, "shield": 0}, 0.016)
	h.expect(not shield.visible and not track.visible and is_equal_approx(hp.scale.x, 0.4), "break_lag", "A hit breaking the shield must show its HP damage immediately")
	Renderer._sync_health_segments(hp, {"hp": 100, "max_hp": 1000, "shield": 3000})
	h.expect(is_equal_approx(hp.size.x * hp.scale.x, float(bg.get_meta("hp_max_width")) * 0.1), "execute_threshold", "10% HP no longer aligns with the execute marker's display scale")
	h.expect(track.position.x <= bg.position.x + bg.size.x, "detached_shield_icon", "Shield icon must stay against the original slot")
	# The common 8% shield must produce a visible blue tail rather than 2px
	# of blue followed by the previously reserved 24px black extension.
	Renderer._sync_health_segments(hp, {"hp": 1000, "max_hp": 1000, "shield": 80})
	h.expect(shield.size.x >= 4.0 and not (host.get_node("HpEmpty") as Control).visible, "small_shield_black_tail", "8% shield is too small or leaves an empty extension")
	var small_shield_width := shield.size.x
	Renderer._sync_health_segments(hp, {"hp": 1000, "max_hp": 1000, "shield": 40}, 0.016)
	h.expect(shield.size.x < small_shield_width and shield.size.x > 3.0, "small_shield_drain", "Small absorbed hits should also animate rather than snap")
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
	# 11.14：同队队友的血条是白色，自己的仍是绿色（颜色只看 teammate 参数，敌方永远红）。
	var mate := Control.new()
	add_child(mate)
	Renderer._add_health_bar(mate, {"hp": 500, "max_hp": 1000, "shield": 0}, "player", true)
	h.expect((mate.get_node("HpFill") as ColorRect).color == Renderer.HP_TEAMMATE_COLOR, "teammate_color", "Teammate HP must be white")
	h.expect(Renderer.hp_color_for_display_team("enemy", true) == Color(1.0, 0.18, 0.12), "enemy_never_white", "Enemy HP must stay red even if flagged teammate")
	h.expect(Renderer.is_teammate_owner(1, 0) and Renderer.is_teammate_owner(2, 0), "same_team_mates", "Slots 1/2 are slot 0's teammates")
	h.expect(not Renderer.is_teammate_owner(0, 0), "self_not_mate", "Own slot is not a teammate")
	h.expect(not Renderer.is_teammate_owner(3, 0), "converted_not_mate", "Opposing-team owner (converted unit) is not a teammate")
	h.expect(not Renderer.is_teammate_owner(1, -1), "solo_no_mates", "Without a viewer slot nobody is a teammate")
	h.expect(Renderer.is_teammate_owner(4, 3), "blue_team_mates", "Blue team slots 3/4 are teammates")
	# 外观：底框圆角材质、填充加厚到 5px、亮线/暗线跟着填充缩放。
	var mate_bg := mate.get_node("HpBg") as ColorRect
	var mate_hp := mate.get_node("HpFill") as ColorRect
	h.expect(mate_bg.material is ShaderMaterial, "bg_not_rounded", "HP background must use the rounded-corner material")
	h.expect(is_equal_approx(mate_hp.size.y, 5.0), "fill_not_thick", "HP fill must be 5px tall")
	h.expect(mate_hp.has_node("Highlight") and mate_hp.has_node("Shade"), "bevel_missing", "HP fill must carry highlight and shade lines")
	h.expect(mate_hp.get_node("Highlight").get_parent() == mate_hp, "bevel_not_child", "Bevel must scale with the fill")
	# 掉血残影：掉血后先停住，再缩回；回血、死亡、无帧间隔立即对齐。
	var trail := mate.get_node("HpTrail") as ColorRect
	h.expect(not trail.visible, "trail_idle_visible", "Trail must be hidden before any damage")
	Renderer._sync_health_segments(mate_hp, {"hp": 1000, "max_hp": 1000, "shield": 0}, 0.016)
	Renderer._sync_health_segments(mate_hp, {"hp": 500, "max_hp": 1000, "shield": 0}, 0.016)
	h.expect(trail.visible and is_equal_approx(trail.size.x, 66.0), "trail_not_held", "Trail must hold the lost segment right after a hit")
	for i in 10:
		Renderer._sync_health_segments(mate_hp, {"hp": 500, "max_hp": 1000, "shield": 0}, 0.016)
	h.expect(trail.visible and is_equal_approx(trail.size.x, 66.0), "trail_hold_too_short", "Trail must stay put during the hold window")
	for i in 30:
		Renderer._sync_health_segments(mate_hp, {"hp": 500, "max_hp": 1000, "shield": 0}, 0.016)
	h.expect(trail.size.x < 66.0, "trail_never_shrinks", "Trail must shrink after the hold window")
	for i in 60:
		Renderer._sync_health_segments(mate_hp, {"hp": 500, "max_hp": 1000, "shield": 0}, 0.016)
	h.expect(not trail.visible and is_equal_approx(trail.size.x, 33.0), "trail_not_settled", "Trail must settle onto the current HP")
	Renderer._sync_health_segments(mate_hp, {"hp": 200, "max_hp": 1000, "shield": 0}, 0.016)
	Renderer._sync_health_segments(mate_hp, {"hp": 900, "max_hp": 1000, "shield": 0}, 0.016)
	h.expect(not trail.visible, "trail_on_heal", "Healing must snap the trail away")
	Renderer._sync_health_segments(mate_hp, {"hp": 300, "max_hp": 1000, "shield": 0}, 0.016)
	Renderer._sync_health_segments(mate_hp, {"hp": 0, "max_hp": 1000, "shield": 0})
	h.expect(not trail.visible, "trail_after_death", "Death must hide the trail")
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
	_text(canvas, "FIXED LENGTH / HP + BLUE SHIELD", Vector2(28, 16), 24)
	_text(canvas, "Actual controls / 1x", Vector2(340, 57), 16)
	_text(canvas, "3x detail", Vector2(566, 57), 16)
	var cases := [
		["Full health / no shield", 1000, 0, "player"],
		["Full health / common 8% shield", 1000, 80, "player"],
		["Shield hit / 250 shield left", 1000, 250, "player"],
		["Shield broken / HP unchanged", 1000, 0, "player"],
		["Next hit / 600 HP", 600, 0, "player"],
		["600 HP / 500 shield - joined", 600, 500, "enemy"],
		["Low HP / overflowing shield (+)", 100, 3000, "enemy"],
		["Last shield point", 600, 1, "player"],
		["Dead / stale shield hidden", 0, 1000, "enemy"],
	]
	for i in cases.size():
		var item: Array = cases[i]
		var y := 94.0 + i * 42.0
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
	var output := "res://artifacts/battle_health_shield_20261104/preview_fixed.png"
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var result := get_viewport().get_texture().get_image().save_png(output)
	print("HEALTH_BAR_PREVIEW ", result, " ", output)
	get_tree().quit(result)
