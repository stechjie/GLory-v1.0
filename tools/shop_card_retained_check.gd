extends Node

const Harness := preload("res://tools/CheckHarness.gd")
const Card := preload("res://scenes/prep/panels/ShopCardFrame.gd")
# Frozen pre-split artwork: independent of the new painter helpers, so render
# equivalence catches accidental geometry, color, order or animation changes.
const Legacy := preload("res://tools/fixtures/shop_card_frame_legacy.gd")

class CardProbe extends Card:
	var static_draws := 0
	func _draw() -> void:
		static_draws += 1
		super._draw()

var _h: RefCounted
var _output := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join("output/perf_20261113_live/shop_card_split")

func _ready() -> void:
	call_deferred("_run")

func _settle(frames := 3) -> void:
	for _i in frames:
		await get_tree().process_frame

func _run() -> void:
	_h = Harness.new("shop_card_retained")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			_output = arg.trim_prefix("--output=")
	await _check_retention()
	if "--render-equivalence" in OS.get_cmdline_user_args():
		if DisplayServer.get_name() == "headless":
			_h.fail("render_backend", "pixel comparison requires a real renderer; run this scene without --headless")
		else:
			await _check_pixels()
	_h.finish(get_tree())

func _check_retention() -> void:
	var host := Control.new()
	add_child(host)
	var card := CardProbe.new()
	card.size = Vector2(200, 200)
	host.add_child(card)
	card.configure(3, false, true)
	var dynamic_draws := [0, 0]
	card._glow_layer.draw.connect(func() -> void: dynamic_draws[0] += 1)
	card._upgrade_layer.draw.connect(func() -> void: dynamic_draws[1] += 1)
	await _settle()
	var baseline := card.static_draws
	var glow_before: int = dynamic_draws[0]
	var upgrade_before: int = dynamic_draws[1]
	var time_before := card.anim_time
	await _settle(12)
	print("SHOP_CARD_RETAINED static_before=%d static_after=%d glow_before=%d glow_after=%d upgrade_before=%d upgrade_after=%d" % [
		baseline, card.static_draws, glow_before, dynamic_draws[0], upgrade_before, dynamic_draws[1]])
	_h.expect(card.static_draws == baseline, "animated_static_redraw", "animated rare/epic cards must retain the static frame's Canvas commands")
	_h.expect(dynamic_draws[0] == glow_before and dynamic_draws[1] > upgrade_before and card.anim_time > time_before,
		"dynamic_layers", "breathing must retain its glow geometry while upgrade stars continue on their own canvas")
	_h.expect(card._glow_layer.show_behind_parent and not card._upgrade_layer.show_behind_parent,
		"layer_order", "glow must remain behind the static frame and upgrade stars in front")
	_h.expect(card._glow_layer.mouse_filter == Control.MOUSE_FILTER_IGNORE and card._upgrade_layer.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"layer_input", "the new effect layers must not intercept shop input")
	card.configure(3, false, true)
	await _settle()
	_h.expect(card.static_draws == baseline, "same_config_redraw", "an identical shop refresh must not rebuild the static frame")
	card.configure(3, true, true)
	await _settle()
	_h.expect(card.static_draws == baseline + 1, "role_changed", "changing the ranged badge must redraw the static frame once")
	baseline = card.static_draws
	card.configure(3, true, false)
	await _settle()
	_h.expect(card.static_draws == baseline and not card._upgrade_layer.visible and card._glow_layer.visible,
		"upgrade_only_change", "upgrade availability must affect its layer without rebuilding static artwork")
	card.size = Vector2(260, 170)
	await _settle()
	_h.expect(card.static_draws == baseline + 1 and card._glow_layer.size == card.size,
		"resize", "resizing must repaint the static frame and keep effect coordinates aligned")
	card.animated = false
	await _settle()
	time_before = card.anim_time
	glow_before = dynamic_draws[0]
	await _settle(6)
	_h.expect(not card.is_processing() and card.anim_time == time_before and dynamic_draws[0] == glow_before and card._glow_layer.self_modulate.a == 1.0,
		"direct_reduced_motion", "direct animated=false assignment must freeze the approved still artwork and stop future updates")
	card.animated = true
	await _settle()
	_h.expect(card.is_processing() and card.anim_time > time_before,
		"direct_animation_resume", "direct animated=true assignment must resume from the retained animation phase")
	host.hide()
	await _settle()
	time_before = card.anim_time
	glow_before = dynamic_draws[0]
	await _settle(6)
	_h.expect(not card.is_processing() and card.anim_time == time_before and dynamic_draws[0] == glow_before,
		"hidden_effects", "hidden cards must not advance time or redraw invisible effects")
	host.show()
	_h.expect(card.is_processing() and card.anim_time == time_before,
		"visible_phase", "showing a card must restore its activity without resetting or skipping its phase")
	await _settle()
	_h.expect(card.anim_time > time_before and dynamic_draws[0] > glow_before,
		"visible_animation", "visible cards must continue animating after a hidden interval")
	card.configure(1, false, false)
	await _settle()
	_h.expect(not card.is_processing() and not card._glow_layer.visible and not card._upgrade_layer.visible,
		"ordinary_idle", "ordinary cards without upgrade prompts must remain completely static")
	card.configure(1, false, true)
	await _settle()
	_h.expect(card.is_processing() and not card._glow_layer.visible and card._upgrade_layer.visible,
		"ordinary_upgrade", "an ordinary card's upgrade prompt must animate without adding a tier glow")
	host.free()

func _make_view(card: Control) -> SubViewport:
	var view := SubViewport.new()
	view.size = Vector2i(440, 480)
	view.disable_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(view)
	var background := ColorRect.new()
	background.color = Color(0.11, 0.15, 0.2, 1.0)
	background.size = Vector2(view.size)
	view.add_child(background)
	view.add_child(card)
	card.position = Vector2(90, 180)
	return view

func _set_case(card: Control, data: Dictionary) -> void:
	card.modulate = data.modulate
	card.animated = data.animated
	card.anim_phase = data.phase
	card.size = data.size
	card.configure(data.tier, data.ranged, data.upgrade)
	card.set_process(false)
	card.anim_time = data.time
	card.queue_redraw()

func _hash(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()

func _check_pixels() -> void:
	var before := Legacy.new()
	var after := Card.new()
	var old_view := _make_view(before)
	var new_view := _make_view(after)
	var output := ProjectSettings.globalize_path(_output)
	DirAccess.make_dir_recursive_absolute(output)
	var results: Array = []
	var matches := 0
	var index := 0
	for tier in [1, 2, 3]:
		for ranged in [false, true]:
			for upgrade in [false, true]:
				for animated in [false, true]:
					for size in [Vector2(200, 200), Vector2(260, 170), Vector2(144, 240)]:
						for phase in [0.0, 1.7]:
							for time in [0.13, 3.4]:
								var data := {"tier": tier, "ranged": ranged, "upgrade": upgrade, "animated": animated,
									"size": size, "phase": phase, "time": time,
									"modulate": Color(0.52, 0.64, 0.72, 0.92) if phase > 0.0 else Color.WHITE}
								_set_case(before, data)
								_set_case(after, data)
								await _settle(2)
								await RenderingServer.frame_post_draw
								var old_image := old_view.get_texture().get_image()
								var new_image := new_view.get_texture().get_image()
								var old_bytes := old_image.get_data()
								var new_bytes := new_image.get_data()
								var same := old_bytes == new_bytes
								_h.expect(same, "pixels_%d" % index, "legacy/new pixels differ for %s" % str(data))
								if same:
									matches += 1
								results.append({"case": index, "tier": tier, "ranged": ranged, "upgrade": upgrade,
									"animated": animated, "size": [size.x, size.y], "phase": phase, "time": time,
									"modulate": [data.modulate.r, data.modulate.g, data.modulate.b, data.modulate.a],
									"same_pixels": same, "legacy_sha256": _hash(old_bytes), "retained_sha256": _hash(new_bytes)})
								if not same or index in [0, 47, 95, 143, 191, 287]:
									old_image.save_png(output.path_join("case_%03d_legacy.png" % index))
									new_image.save_png(output.path_join("case_%03d_retained.png" % index))
								index += 1
	var file := FileAccess.open(output.path_join("pixel_equivalence.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"cases": results.size(), "pixel_matches": matches,
		"renderer": RenderingServer.get_current_rendering_method(), "scope": "isolated shop card artwork, not whole-game/mobile performance",
		"results": results}, "\t") + "\n")
	file.close()
	print("SHOP_CARD_PIXELS cases=%d exact_matches=%d output=%s" % [results.size(), matches, output])
	old_view.free()
	new_view.free()
