extends Control
class_name PrepGlintFx

# 底部卷轴 / 钱袋的「请点我」提示光（11.12 重做，替换原来那圈黄光框和描边脉冲）。
#
# 三层，都很克制：
#   1. 背后一团暖金色柔光，椭圆、边缘完全化开，慢慢呼吸（插在目标的最底下，不压图）；
#   2. 每隔几秒一道细细的高光从左下扫到右上，只在目标图的不透明处出现（用图的 alpha 当遮罩）；
#   3. 周围几颗小四角星，错开时间一闪一闪，慢慢转。
# 只画在目标自己的范围里，不改目标的位置 / 缩放，不吃点击。

const SWEEP_SHADER_CODE := """
shader_type canvas_item;
render_mode blend_add;
uniform float pos = -1.0;
uniform float width = 0.14;
uniform float strength = 1.1;
uniform vec4 tint : source_color = vec4(1.0, 0.94, 0.72, 1.0);
void fragment() {
	vec4 t = texture(TEXTURE, UV);
	float d = (UV.x * 0.8 - UV.y * 0.6) - pos;
	float band = smoothstep(width, 0.0, abs(d));
	float a = t.a * band * strength;
	COLOR = vec4(tint.rgb * a, a);
}
"""

static var _sweep_shader: Shader
static var _star_tex: Texture2D

var halo_color := Color(1.0, 0.88, 0.5)
var halo_alpha := Vector2(0.45, 0.8)     # 呼吸的最暗 / 最亮
var halo_grow := Vector2(1.25, 1.45)     # 光团相对目标的大小（横、竖）
var sweep_every := 3.6
var sparkle_count := 5

var _target: Control
var _halo: TextureRect
var _shine: TextureRect
var _shine_mat: ShaderMaterial
var _time := 0.0
var _sparkles: Array[Dictionary] = []
var _active := true


# texture = 目标上显示的那张图（高光按它的形状扫）；art_rect = 那张图在目标里实际画的位置（目标坐标）
func setup(target: Control, texture: Texture2D, art_rect := Rect2()) -> void:
	_target = target
	name = "GlintFx"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 1. 背后柔光：插到目标最底下
	_halo = TextureRect.new()
	_halo.name = "GlintHalo"
	_halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_halo.texture = _soft_disc()
	_halo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_halo.stretch_mode = TextureRect.STRETCH_SCALE
	_halo.modulate = Color(halo_color, halo_alpha.x)
	target.add_child(_halo)
	target.move_child(_halo, 0)
	# 2. 扫光：同一张图、同样的摆法，叠在最上面
	if _sweep_shader == null:
		_sweep_shader = Shader.new()
		_sweep_shader.code = SWEEP_SHADER_CODE
	_shine_mat = ShaderMaterial.new()
	_shine_mat.shader = _sweep_shader
	_shine = TextureRect.new()
	_shine.name = "GlintSweep"
	_shine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shine.texture = texture
	_shine.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_shine.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_shine.material = _shine_mat
	add_child(_shine)
	if art_rect.size == Vector2.ZERO:
		_shine.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		_shine.position = art_rect.position
		_shine.size = art_rect.size
	target.add_child(self)
	for i in sparkle_count:
		_sparkles.append({"phase": float(i) / sparkle_count + randf() * 0.1, "pos": Vector2.ZERO, "spin": randf() * TAU})
		_place_sparkle(_sparkles[i])
	target.resized.connect(_layout)
	_layout.call_deferred()


func set_art_texture(texture: Texture2D) -> void:
	_shine.texture = texture


func set_effect_active(value: bool) -> void:
	_active = value
	visible = value
	if is_instance_valid(_halo):
		_halo.visible = value
	set_process(value)


func _layout() -> void:
	if not is_instance_valid(_target) or not is_instance_valid(_halo):
		return
	var s := _target.size
	var hs := Vector2(s.x * halo_grow.x, s.y * halo_grow.y)
	_halo.size = hs
	_halo.position = (s - hs) * 0.5
	_halo.pivot_offset = hs * 0.5


func _process(delta: float) -> void:
	if not _active or not is_visible_in_tree():
		return
	_time += delta
	# 柔光呼吸（2.6 秒一个来回），带一点点缩放
	var breath := 0.5 + 0.5 * sin(_time * TAU / 2.6)
	_halo.modulate.a = lerpf(halo_alpha.x, halo_alpha.y, breath)
	_halo.scale = Vector2.ONE * (0.97 + breath * 0.05)
	# 扫光：每 sweep_every 秒扫一次，0.9 秒扫完（先快后慢）
	var cycle := fmod(_time, sweep_every)
	var t := clampf(cycle / 0.9, 0.0, 1.0)
	t = 1.0 - pow(1.0 - t, 2.0)
	_shine_mat.set_shader_parameter("pos", lerpf(-0.75, 1.0, t) if cycle < 0.9 else -2.0)
	# 小星星：每颗 1.8 秒一个生命周期，结束时换个位置
	for sp in _sparkles:
		var before := float(sp.phase)
		sp.phase = fmod(before + delta / 1.8, 1.0)
		if float(sp.phase) < before:
			_place_sparkle(sp)
		sp.spin = float(sp.spin) + delta * 1.2
	queue_redraw()


func _place_sparkle(sp: Dictionary) -> void:
	if not is_instance_valid(_target):
		return
	var s := _target.size
	# 落在目标外沿附近一圈（椭圆上随机一点，再往外一点）
	var ang := randf() * TAU
	var r := Vector2(s.x * 0.5, s.y * 0.5) * randf_range(0.78, 1.05)
	sp.pos = s * 0.5 + Vector2(cos(ang) * r.x, sin(ang) * r.y)


func _draw() -> void:
	if not _active:
		return
	for sp in _sparkles:
		var life := float(sp.phase)
		# 0 → 亮 → 0（中间最亮），只在前 70% 的时间出现，错开得更自然
		var k := clampf(sin(clampf(life / 0.7, 0.0, 1.0) * PI), 0.0, 1.0)
		if k <= 0.01:
			continue
		var size_px := 12.0 * (0.55 + 0.45 * k)
		_draw_star(sp.pos, size_px, float(sp.spin), Color(1.0, 0.95, 0.78, 0.9 * k))


# 四角星：细长的十字，中间一点柔光
func _draw_star(c: Vector2, r: float, spin: float, col: Color) -> void:
	draw_circle(c, r * 0.55, Color(1.0, 0.85, 0.45, col.a * 0.25), true, -1.0, true)
	var pts := PackedVector2Array()
	for i in 8:
		var a := spin + TAU * float(i) / 8.0
		var rr := r if i % 2 == 0 else r * 0.22
		pts.append(c + Vector2(cos(a), sin(a)) * rr)
	draw_colored_polygon(pts, col)


# 边缘完全化开的圆（径向渐变），做柔光
static func _soft_disc() -> Texture2D:
	if _star_tex != null:
		return _star_tex
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.35, 0.7, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0.22), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 256
	t.height = 256
	_star_tex = t
	return t
