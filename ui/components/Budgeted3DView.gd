extends RefCounted

# SubViewportContainer.stretch overrides a child's requested size. Display the
# viewport texture instead, so its pixel budget can be independent of the UI.
const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

static func mobile_limit(tier: int, mobile: bool) -> Vector2i:
	if not mobile or tier == QUALITY.Tier.HIGH:
		return Vector2i.ZERO
	return Vector2i(960, 540) if tier == QUALITY.Tier.LOW else Vector2i(1280, 720)

static func raster_size(display_size: Vector2, limit: Vector2i) -> Vector2i:
	var display := display_size.max(Vector2(2.0, 2.0))
	var ratio := 1.0
	if limit.x > 0 and limit.y > 0:
		ratio = minf(1.0, minf(float(limit.x) / display.x, float(limit.y) / display.y))
	return Vector2i(maxi(2, int(roundf(display.x * ratio))), maxi(2, int(roundf(display.y * ratio))))

static func create(parent: Control, layer_name: String, z: int, limit: Vector2i, continuous: bool) -> SubViewport:
	var layer := TextureRect.new()
	layer.name = layer_name
	layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	layer.stretch_mode = TextureRect.STRETCH_SCALE
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.z_index = z
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.handle_input_locally = false
	layer.add_child(viewport)
	layer.texture = viewport.get_texture()
	layer.resized.connect(_resize.bind(layer, viewport, limit, continuous))
	layer.visibility_changed.connect(_sync_visibility.bind(layer, viewport, continuous))
	parent.add_child(layer)
	_resize(layer, viewport, limit, continuous)
	return viewport

static func _resize(layer: Control, viewport: SubViewport, limit: Vector2i, continuous: bool) -> void:
	var target := raster_size(layer.size, limit)
	if viewport.size != target:
		viewport.size = target
	_sync_visibility(layer, viewport, continuous)

static func _sync_visibility(layer: Control, viewport: SubViewport, continuous: bool) -> void:
	if not layer.is_visible_in_tree():
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	else:
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if continuous else SubViewport.UPDATE_ONCE
