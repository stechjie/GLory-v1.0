extends Control

# 主菜单背景的动态层（11.10 换成 main_menu_v2 森林空地背景）：
#   草地风 → 河面 / 瀑布 / 泡沫 → 灯笼光 → 随风飘的叶子与花瓣。
# 所有遮罩都是按 main_menu_v2/background.png 抠出来的，换背景就要重抠。
# 背景本身是 STRETCH_KEEP_ASPECT_COVERED 铺满，这里的点位也按同一种「覆盖」换算，
# 非 16:9 屏上才不会跟背景错开。

const REF_SIZE := Vector2(1672.0, 941.0)
const TEX_BACKGROUND := preload("res://assets/ui/main_menu_v2/background.png")
const TEX_RIVER_MASK := preload("res://assets/ui/main_menu_v2/river_mask.png")
const TEX_WATERFALL_MASK := preload("res://assets/ui/main_menu_v2/waterfall_mask.png")
const TEX_FOAM_MASK := preload("res://assets/ui/main_menu_v2/foam_mask.png")
const TEX_GRASS_MASK := preload("res://assets/ui/main_menu_v2/grass_mask.png")
const TEX_NOISE := preload("res://assets/ui/main_menu_v2/noise_tile.png")
const TEX_WARM_GLOW := preload("res://assets/ui/main_menu_v2/glow_warm.png")
const TEX_GOLD_PARTICLE := preload("res://assets/ui/main_menu_v2/particle_gold.png")
const WATER_SHADER := preload("res://shaders/main_menu_water_toon.gdshader")
const GRASS_SHADER := preload("res://shaders/main_menu_grass_wind.gdshader")

# 风向：从左往右、略微往下。草地风痕与飘叶共用。
const WIND_DIR := Vector2(1.0, 0.22)
const DRIFT_COUNT := 20
const LEAF_COLORS := [Color("c8d94a"), Color("e3c454"), Color("9ccc4c")]
const PETAL_COLORS := [Color("f4a6c6"), Color("fbe3ee"), Color("c9a8e8"), Color("ffffff")]

var _glows: Array[Dictionary] = []
var _particles: Array[Dictionary] = []
var _drifts: Array[Dictionary] = []
var _grass_material: ShaderMaterial
var _drift_layer: Control
var _elapsed := 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rng.seed = 1110
	_grass_material = _build_layer("GrassWind", GRASS_SHADER, {
		"mask_texture": TEX_GRASS_MASK,
	})
	_build_layer("RiverSurface", WATER_SHADER, {
		"mode": 0, "mask_texture": TEX_RIVER_MASK, "flow_direction": Vector2(1.0, 0.05),
		"speed": 0.045, "distortion": 0.0012, "line_strength": 0.22, "sparkle_strength": 0.35,
	})
	_build_layer("WaterfallFlow", WATER_SHADER, {
		"mode": 1, "mask_texture": TEX_WATERFALL_MASK, "speed": 0.85,
		"distortion": 0.0025, "line_strength": 0.35,
	})
	_build_layer("WaterfallFoam", WATER_SHADER, {
		"mode": 2, "mask_texture": TEX_FOAM_MASK, "speed": 0.07, "line_strength": 0.4,
	})
	_add_glow("LampLeft", Vector2(248, 198), Vector2(96, 96), 0.30, 3.9, 1.5)
	_add_glow("LampBottom", Vector2(234, 724), Vector2(100, 100), 0.30, 4.1, 0.2)
	_add_glow("LampTreeTop", Vector2(1279, 149), Vector2(80, 80), 0.28, 3.6, 2.4)
	_add_glow("LampTreeBottom", Vector2(1314, 305), Vector2(80, 80), 0.28, 3.8, 0.9)
	_add_glow("HouseWindows", Vector2(1425, 195), Vector2(210, 150), 0.18, 4.6, 0.8)
	_build_fireflies()
	_drift_layer = Control.new()
	_drift_layer.name = "WindDrift"
	_drift_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drift_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_drift_layer.draw.connect(_draw_drifts)
	add_child(_drift_layer)
	for i in DRIFT_COUNT:
		_drifts.append(_new_drift(true))
	get_viewport().size_changed.connect(_layout_effects)
	_layout_effects()

# 阵风曲线 0~1：两条慢正弦叠出来，一阵强一阵弱，不会有规律感。
static func gust_at(t: float) -> float:
	return clampf(0.5 + 0.32 * sin(t * 0.37) + 0.22 * sin(t * 0.91 + 1.3), 0.0, 1.0)

func _process(delta: float) -> void:
	_elapsed += delta
	var gust := gust_at(_elapsed)
	_grass_material.set_shader_parameter("gust", gust)
	for item in _glows:
		var node := item.node as TextureRect
		var pulse := 0.5 + 0.5 * sin((_elapsed + float(item.phase)) * TAU / float(item.period))
		node.modulate.a = float(item.alpha) * lerpf(0.7, 1.0, pulse)
		_apply_rect(node, item.center, item.size * lerpf(0.95, 1.05, pulse))
	for item in _particles:
		var node := item.node as TextureRect
		var life := fmod(_elapsed * float(item.speed) + float(item.phase), 1.0)
		var pos := item.origin as Vector2
		pos += Vector2(sin(life * TAU + float(item.phase) * 5.0) * float(item.drift), -life * float(item.rise))
		node.modulate.a = sin(life * PI) * float(item.alpha)
		_apply_rect(node, pos, item.size)
	var wind := WIND_DIR.normalized()
	for i in _drifts.size():
		var d: Dictionary = _drifts[i]
		var spd: float = float(d.speed) * lerpf(0.55, 1.6, gust)
		d.pos += wind * spd * delta
		d.phase += delta * float(d.flutter_hz) * TAU
		d.spin += delta * float(d.spin_speed) * lerpf(0.7, 1.5, gust)
		var p: Vector2 = d.pos
		if p.x > REF_SIZE.x + 40.0 or p.y > REF_SIZE.y + 40.0:
			_drifts[i] = _new_drift(false)
	_drift_layer.queue_redraw()

func _build_layer(node_name: String, shader: Shader, params: Dictionary) -> ShaderMaterial:
	var rect := TextureRect.new()
	rect.name = node_name
	rect.texture = TEX_BACKGROUND
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("noise_texture", TEX_NOISE)
	for key in params:
		material.set_shader_parameter(key, params[key])
	rect.material = material
	add_child(rect)
	return material

func _add_glow(node_name: String, center: Vector2, size: Vector2, alpha: float, period: float, phase: float) -> void:
	var glow := TextureRect.new()
	glow.name = node_name
	glow.texture = TEX_WARM_GLOW
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.modulate = Color(1, 1, 1, alpha)
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow.material = add
	add_child(glow)
	_glows.append({"node": glow, "center": center, "size": size, "alpha": alpha, "period": period, "phase": phase})

# 灯笼附近几点萤火，慢慢往上飘。
func _build_fireflies() -> void:
	var origins := [Vector2(262, 240), Vector2(300, 700), Vector2(1300, 200), Vector2(1340, 340),
		Vector2(1180, 560), Vector2(470, 520)]
	for i in origins.size():
		var particle := TextureRect.new()
		particle.name = "Firefly%d" % i
		particle.texture = TEX_GOLD_PARTICLE
		particle.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		particle.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(particle)
		_particles.append({
			"node": particle, "origin": origins[i], "size": Vector2(16, 16), "alpha": 0.55,
			"speed": 0.07 + i * 0.006, "phase": float(i) / float(origins.size()),
			"rise": 60.0 + (i % 3) * 18.0, "drift": 10.0 + (i % 4) * 4.0,
		})

# 一片叶子 / 花瓣。initial=true 时撒在中间草地一带，否则从左边（多数）或上边入场。
# 入场范围刻意避开底部按钮和右侧面板 —— 撒满全屏时大半会被 UI 盖住。
func _new_drift(initial: bool) -> Dictionary:
	var pos: Vector2
	if initial:
		pos = Vector2(_rng.randf_range(0.0, REF_SIZE.x * 0.85), _rng.randf_range(130.0, 640.0))
	elif _rng.randf() < 0.8:
		pos = Vector2(-30.0, _rng.randf_range(90.0, 560.0))
	else:
		pos = Vector2(_rng.randf_range(150.0, REF_SIZE.x * 0.6), -30.0)
	var leaf := _rng.randf() < 0.45
	var palette: Array = LEAF_COLORS if leaf else PETAL_COLORS
	return {
		"pos": pos, "leaf": leaf, "color": palette[_rng.randi() % palette.size()],
		"size": _rng.randf_range(11.0, 15.0) if leaf else _rng.randf_range(11.0, 15.0),
		"speed": _rng.randf_range(55.0, 95.0),
		"phase": _rng.randf() * TAU, "flutter_hz": _rng.randf_range(0.35, 0.7),
		"flutter_amp": _rng.randf_range(10.0, 22.0),
		"spin": _rng.randf() * TAU, "spin_speed": _rng.randf_range(-2.4, 2.4),
		"tumble_hz": _rng.randf_range(0.6, 1.3),
	}

func _draw_drifts() -> void:
	var xf := _cover_transform()
	var scale_factor: float = xf.size.x
	for d in _drifts:
		var flutter := sin(float(d.phase)) * float(d.flutter_amp)
		var p: Vector2 = d.pos + Vector2(0.0, flutter)
		var screen := xf.position + p * scale_factor
		var s: float = float(d.size) * scale_factor
		# 翻面：宽度随 cos 缩放，看起来是在空中打滚
		var tumble := absf(cos(float(d.phase) * float(d.tumble_hz) * 2.0))
		var col: Color = d.color
		col = col.darkened(0.25 * (1.0 - tumble))
		_drift_layer.draw_set_transform(screen, float(d.spin), Vector2(maxf(0.18, tumble), 1.0))
		if bool(d.leaf):
			var pts := PackedVector2Array([
				Vector2(0, -s), Vector2(s * 0.45, -s * 0.3), Vector2(s * 0.35, s * 0.5),
				Vector2(0, s), Vector2(-s * 0.35, s * 0.5), Vector2(-s * 0.45, -s * 0.3)])
			_drift_layer.draw_colored_polygon(pts, col)
			var outline := pts.duplicate()
			outline.append(pts[0])
			_drift_layer.draw_polyline(outline, col.darkened(0.45), maxf(1.0, s * 0.1), true)
			_drift_layer.draw_line(Vector2(0, -s * 0.8), Vector2(0, s * 0.9), col.darkened(0.3), maxf(1.0, s * 0.08))
		else:
			_drift_layer.draw_circle(Vector2.ZERO, s * 0.55, col)
			_drift_layer.draw_circle(Vector2(0, -s * 0.35), s * 0.4, col.lightened(0.15))
	_drift_layer.draw_set_transform(Vector2.ZERO)

func _layout_effects() -> void:
	for item in _glows:
		_apply_rect(item.node, item.center, item.size)
	for item in _particles:
		_apply_rect(item.node, item.origin, item.size)

# 与背景 STRETCH_KEEP_ASPECT_COVERED 一致的换算：返回 (原点, 缩放) —— size.x 是缩放。
func _cover_transform() -> Rect2:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return Rect2(Vector2.ZERO, Vector2.ONE)
	var k := maxf(viewport_size.x / REF_SIZE.x, viewport_size.y / REF_SIZE.y)
	return Rect2((viewport_size - REF_SIZE * k) * 0.5, Vector2(k, k))

func _apply_rect(node: Control, center: Vector2, ref_size: Vector2) -> void:
	var xf := _cover_transform()
	var k := xf.size.x
	var scaled_size := ref_size * k
	node.position = xf.position + center * k - scaled_size * 0.5
	node.size = scaled_size
