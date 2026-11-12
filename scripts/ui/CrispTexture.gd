extends RefCounted

# 大图缩小显示变清晰（11.12）。
#
# 1254×1254 的宠物立绘画在 150px 左右的框里：直接缩会起锯齿颗粒，开 mipmap 又会整张发软。
# 这里按「屏幕上实际的像素大小」用 Lanczos 预先缩好一张，GPU 只需 1:1 画出来 —— 又清楚又没颗粒。
# 按 (原图, 目标像素) 缓存，同一张图同一个尺寸只缩一次。

static var _cache: Dictionary = {}


# box_logical：显示框的逻辑尺寸；node：用来换算屏幕缩放（手机上逻辑像素 × 1.5 左右才是真实像素）
static func fit(texture: Texture2D, box_logical: Vector2, node: CanvasItem, cover := false) -> Texture2D:
	if texture == null or box_logical.x <= 0.0 or box_logical.y <= 0.0:
		return texture
	var scale := 1.0
	if node != null and node.is_inside_tree():
		scale = node.get_viewport().get_final_transform().get_scale().x
	var src := texture.get_size()
	var ratios := box_logical * scale / src
	var k := maxf(ratios.x, ratios.y) if cover else minf(ratios.x, ratios.y)
	if k >= 0.9:
		return texture
	var target := Vector2i(maxi(1, roundi(src.x * k)), maxi(1, roundi(src.y * k)))
	var logical_size := Vector2i(roundi(target.x / scale), roundi(target.y / scale))
	var source_key := texture.resource_path
	if source_key.is_empty():
		source_key = str(texture.get_instance_id())
	var key := "%s:%s:%s" % [source_key, target, logical_size]
	if _cache.has(key):
		return _cache[key]
	var image := texture.get_image()
	if image == null:
		return texture
	if image.is_compressed():
		image.decompress()
	image = image.duplicate()
	image.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)
	var out := ImageTexture.create_from_image(image)
	# 显示时还是按逻辑尺寸摆放，只是像素密度刚好等于屏幕
	out.set_size_override(logical_size)
	_cache[key] = out
	return out
