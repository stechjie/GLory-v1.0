extends RefCounted

# SubViewportContainer.stretch overrides a child's requested size. Display the
# viewport texture instead, so its pixel budget can be independent of the UI.
const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

static func mobile_limit(tier: int, mobile: bool) -> Vector2i:
	if not mobile or tier == QUALITY.Tier.HIGH:
		return Vector2i.ZERO
	return Vector2i(960, 540) if tier == QUALITY.Tier.LOW else Vector2i(1280, 720)

static func battle_limit(tier: int, mobile: bool, ios: bool) -> Vector2i:
	# The iOS medium preset needs more samples for small model details and
	# outlines. Keep a fixed cap so Retina displays don't multiply the 3D cost.
	if mobile and ios and tier == QUALITY.Tier.MEDIUM:
		return Vector2i(1536, 864)
	return mobile_limit(tier, mobile)

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
	var resize := _resize.bind(layer, viewport, limit, continuous)
	layer.resized.connect(resize)
	layer.visibility_changed.connect(_sync_visibility.bind(layer, viewport, continuous))
	# 窗口等比缩放（canvas_items 拉伸）时逻辑尺寸不变、resized 不会发，要单独跟窗口。
	layer.tree_entered.connect(func() -> void:
		var window := layer.get_window()
		if window != null and not window.size_changed.is_connected(resize):
			window.size_changed.connect(resize)
		resize.call())
	layer.tree_exiting.connect(func() -> void:
		var window := layer.get_window()
		if window != null and window.size_changed.is_connected(resize):
			window.size_changed.disconnect(resize))
	parent.add_child(layer)
	_resize(layer, viewport, limit, continuous)
	return viewport

# 出图倍数上限：面积按平方涨，4K 屏不再往上跟。
const MAX_PIXEL_SCALE := 2.0

## 一个逻辑像素合多少屏幕像素。layer.size 是 720 高画布上的逻辑尺寸，直接拿来出图的话
## 1080p 全屏就是 1.5 倍拉伸，模型发糊。只在电脑上按真实像素出图；手机发热预算没实测，不动。
static func pixel_scale(layer: Control) -> float:
	if OS.has_feature("mobile") or not layer.is_inside_tree():
		return 1.0
	var window := layer.get_window()
	if window == null or layer.get_viewport() != window:
		return 1.0
	var logical := layer.get_viewport_rect().size
	if logical.x <= 0.0 or logical.y <= 0.0:
		return 1.0
	var physical := Vector2(window.size)
	return clampf(minf(physical.x / logical.x, physical.y / logical.y), 1.0, MAX_PIXEL_SCALE)

static func _resize(layer: Control, viewport: SubViewport, limit: Vector2i, continuous: bool) -> void:
	var target := raster_size(layer.size * pixel_scale(layer), limit)
	if viewport.size != target:
		viewport.size = target
	_sync_visibility(layer, viewport, continuous)

static func _sync_visibility(layer: Control, viewport: SubViewport, continuous: bool) -> void:
	if not layer.is_visible_in_tree():
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	else:
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if continuous else SubViewport.UPDATE_ONCE
