extends Node

const H := preload("res://tools/CheckHarness.gd")
class Preview:
	extends "res://scenes/battle/BattleScreen.gd"
	func _ready() -> void:
		set_process(false)

func _ready() -> void:
	var h := H.new("battle_loading_layout")
	var screen := Preview.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(screen)
	var hud := Label.new()
	hud.text = "第 3 回合 · 战斗信息"
	hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	hud.add_theme_font_size_override("font_size", 24)
	screen.add_child(hud)
	var bar := screen._make_battle_prepare_bar()
	bar.value = 60
	var label: Label = bar.get_node("StageText")
	label.text = "正在预热战斗特效 · 12/20"
	await get_tree().process_frame
	h.expect(not label.get_global_rect().intersects(hud.get_global_rect()), "hud_overlap", "Loading text must not overlap the top HUD")
	h.expect(not label.get_global_rect().intersects(bar.get_global_rect()), "bar_overlap", "Stage text must sit above progress")
	var panel: Panel = bar.get_node("LoadingBackdrop")
	h.expect(panel.get_global_rect().encloses(label.get_global_rect()), "text_outside_card", "Loading card must contain all stage text")
	h.expect(is_equal_approx(panel.get_theme_stylebox("panel").bg_color.a, 1.0), "transparent_card", "Background text must not bleed through")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		image.save_png("res://reports/reconnect-loading-20260927/battle-loading.png")
	bar.queue_free()
	await get_tree().process_frame
	h.expect(not is_instance_valid(bar), "card_cleanup", "Progress and card must disappear together")
	screen.queue_free()
	h.finish(get_tree())
