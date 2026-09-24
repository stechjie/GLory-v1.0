extends Control

# 联动 / 套装激活的庆祝特效，约 1.5 秒，不挡操作（所有节点都不接收鼠标）。
#
#   0.00  组成这条联动的宝藏图标亮起，颜色按宝藏类别
#   0.12  每件宝藏射出一道光，汇到屏幕中央
#   0.52  中央爆开：闪光、冲击环、星光粒子；图标弹出，横幅显示名字，播联动音效
#   1.10  图标飞回宝藏栏里自己的格子
#   1.45  落位：格子亮一下并发 landed —— 调用方这时再把格子里的真图标显示出来
#   1.50  发 finished；格子上的余光淡掉后节点自己释放
#
# 减弱动态效果时没有光线、粒子和飞行，图标与横幅在中央淡入淡出。
# 闪光开关关着时不白闪；粒子数量走 VFXQualityBudget 的画质档。
# 不引入外部贴图：柔光点、星光、横幅底带都是运行时生成的程序纹理。

const PresentationSettings := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const SfxService := preload("res://ui/services/SfxService.gd")

signal landed
signal finished

const CATEGORY_COLORS := {
	"defense": Color(1.0, 1.0, 1.0),
	"control": Color(0.72, 0.40, 1.0),
	"element": Color(0.35, 0.66, 1.0),
	"money": Color(1.0, 0.80, 0.26),
	"attack": Color(1.0, 0.28, 0.26),
}

const BEAM_START := 0.12
const BURST_AT := 0.52
const FLY_AT := 1.10
const LAND_AT := 1.45
const LOGO_SIZE := 150.0
const BANNER_SIZE := Vector2(760.0, 60.0)
const BANNER_FONT_SIZE := 34

static var _soft_texture: Texture2D
static var _star_texture: Texture2D
static var _ribbon_texture: Texture2D
static var _add_material: CanvasItemMaterial

var _stage := Vector2.ZERO
var _logo_tex: Texture2D
var _title := ""
var _logo_rect: TextureRect
var _banner: Control
var _halo: Sprite2D
var _trail: CPUParticles2D


func _ready() -> void:
	set_process(false)


# sources：组成这条联动的宝藏在宝藏栏里的图标，[{"rect": Rect2（全局坐标）, "category": String}]。
# target：图标最后落进的格子（全局坐标）；给空 Rect2 时图标在中央淡出，不飞。
# options 只给预览场景用，覆盖玩家设置："reduced_motion"、"flash"、"particle_scale"、"sound"。
func play(sources: Array, logo: Texture2D, title: String, target: Rect2, options: Dictionary = {}) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var view := get_viewport_rect().size
	_stage = Vector2(view.x * 0.5, view.y * 0.42) - global_position
	_logo_tex = logo
	_title = title
	var reduced: bool = options.get("reduced_motion", Tokens.reduced_motion())
	var flash: bool = options.get("flash", PresentationSettings.flash_allowed())
	var particle_scale: float = options.get("particle_scale", 1.0)
	var sound: bool = options.get("sound", true)
	var slot := Rect2(target.position - global_position, target.size)
	if reduced:
		_play_reduced(slot, sound)
		return

	var colors: Array[Color] = []
	for raw in sources:
		var src: Dictionary = raw
		var icon: Rect2 = src.get("rect", Rect2())
		var color: Color = CATEGORY_COLORS.get(str(src.get("category", "")), Color.WHITE)
		colors.append(color)
		var origin := icon.get_center() - global_position
		_source_glow(origin, color)
		_beam(origin, _stage, color)

	var timeline := create_tween()
	timeline.tween_interval(BURST_AT)
	timeline.tween_callback(_burst.bind(colors, flash, particle_scale, sound))
	timeline.tween_interval(FLY_AT - BURST_AT)
	timeline.tween_callback(_fly.bind(slot))
	timeline.tween_interval(LAND_AT - FLY_AT)
	timeline.tween_callback(_land.bind(slot, true))
	timeline.tween_interval(0.05)
	timeline.tween_callback(finished.emit)
	timeline.tween_interval(2.2)
	timeline.tween_callback(queue_free)


func _process(_delta: float) -> void:
	if _trail != null and is_instance_valid(_logo_rect):
		_trail.position = _logo_rect.position + _logo_rect.size * 0.5


# --- 各段 ------------------------------------------------------------------------

func _source_glow(at: Vector2, color: Color) -> void:
	var halo := _sprite(_soft(), at, color, 120.0)
	halo.modulate.a = 0.0
	var base := halo.scale
	var t := halo.create_tween()
	t.tween_property(halo, "modulate:a", 0.95, 0.12)
	t.parallel().tween_property(halo, "scale", base * 1.3, 0.12)
	t.tween_property(halo, "modulate:a", 0.0, 0.5)
	t.tween_callback(halo.queue_free)


func _beam(origin: Vector2, dest: Vector2, color: Color) -> void:
	var line := Line2D.new()
	line.material = _add()
	line.width = 12.0
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	var grad := Gradient.new()
	grad.set_color(0, Color(color, 0.0))
	grad.set_color(1, Color(color.lightened(0.35), 1.0))
	line.gradient = grad
	var taper := Curve.new()
	taper.add_point(Vector2(0.0, 0.15))
	taper.add_point(Vector2(1.0, 1.0))
	line.width_curve = taper
	line.points = PackedVector2Array([origin, origin])
	add_child(line)
	var head := _sprite(_star(), origin, color.lightened(0.45), 52.0)
	head.modulate.a = 0.0
	var travel := func(progress: float) -> void:
		var at := origin.lerp(dest, progress)
		line.set_point_position(1, at)
		head.position = at
		head.modulate.a = 1.0
	var t := line.create_tween()
	t.tween_interval(BEAM_START)
	t.tween_method(travel, 0.0, 1.0, BURST_AT - BEAM_START).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	t.tween_callback(head.queue_free)
	t.tween_property(line, "modulate:a", 0.0, 0.25)
	t.tween_callback(line.queue_free)


func _burst(colors: Array[Color], flash: bool, particle_scale: float, sound: bool) -> void:
	if flash:
		var glare := _sprite(_soft(), _stage, Color(1.0, 0.97, 0.88), 300.0)
		glare.modulate.a = 0.9
		var g := glare.create_tween()
		g.tween_property(glare, "scale", glare.scale * 2.2, 0.32).set_ease(Tween.EASE_OUT)
		g.parallel().tween_property(glare, "modulate:a", 0.0, 0.32)
		g.tween_callback(glare.queue_free)
	_ring(_stage, Tokens.GOLD_EDGE, 40.0, 230.0, 0.5, 7.0)
	_ring(_stage, Color(1.0, 1.0, 1.0, 0.8), 30.0, 150.0, 0.35, 3.0)
	_sparkles(_stage, colors, particle_scale)

	_halo = _sprite(_soft(), _stage, Tokens.GOLD, LOGO_SIZE * 2.1)
	_halo.modulate.a = 0.75
	var breathe := _halo.create_tween().set_loops()
	breathe.tween_property(_halo, "scale", _halo.scale * 1.08, 0.35).set_trans(Tween.TRANS_SINE)
	breathe.tween_property(_halo, "scale", _halo.scale, 0.35).set_trans(Tween.TRANS_SINE)

	_logo_rect = _make_logo()
	_logo_rect.scale = Vector2.ONE * 0.2
	_logo_rect.modulate.a = 0.0
	var pop := _logo_rect.create_tween()
	pop.tween_property(_logo_rect, "scale", Vector2.ONE * 1.12, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	pop.parallel().tween_property(_logo_rect, "modulate:a", 1.0, 0.12)
	pop.tween_property(_logo_rect, "scale", Vector2.ONE, 0.14)

	_banner = _make_banner()
	_banner.modulate.a = 0.0
	var rest := _banner.position
	_banner.position = rest + Vector2(0.0, 14.0)
	var slide := _banner.create_tween()
	slide.tween_interval(0.08)
	slide.tween_property(_banner, "modulate:a", 1.0, 0.18)
	slide.parallel().tween_property(_banner, "position", rest, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	if sound:
		SfxService.play(SfxService.CUE_TREASURE_LINKAGE)


func _fly(slot: Rect2) -> void:
	var dur := LAND_AT - FLY_AT
	var fade_banner := _banner.create_tween()
	fade_banner.tween_property(_banner, "modulate:a", 0.0, 0.25)
	fade_banner.tween_callback(_banner.queue_free)
	var fade_halo := _halo.create_tween()
	fade_halo.tween_property(_halo, "modulate:a", 0.0, 0.2)
	fade_halo.tween_callback(_halo.queue_free)
	if slot.size.x <= 0.0:
		var fade_logo := _logo_rect.create_tween()
		fade_logo.tween_property(_logo_rect, "modulate:a", 0.0, dur)
		return
	_trail = _make_trail()
	set_process(true)
	var end_scale := Vector2.ONE * (minf(slot.size.x, slot.size.y) / LOGO_SIZE)
	var end_pos := slot.get_center() - _logo_rect.size * 0.5
	var t := _logo_rect.create_tween()
	t.tween_property(_logo_rect, "position", end_pos, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t.parallel().tween_property(_logo_rect, "scale", end_scale, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)


func _land(slot: Rect2, with_ring: bool) -> void:
	set_process(false)
	if _trail != null:
		_trail.emitting = false
	if is_instance_valid(_logo_rect):
		_logo_rect.queue_free()
	if slot.size.x > 0.0:
		var at := slot.get_center()
		if with_ring:
			_ring(at, Tokens.GOLD_EDGE, 16.0, 64.0, 0.35, 4.0)
		var glow := _sprite(_soft(), at, Tokens.GOLD, slot.size.x * 2.0)
		glow.modulate.a = 0.95
		var t := glow.create_tween()
		t.tween_property(glow, "modulate:a", 0.35, 0.25)
		t.tween_property(glow, "modulate:a", 0.0, 1.8)
		t.tween_callback(glow.queue_free)
	landed.emit()


func _play_reduced(slot: Rect2, sound: bool) -> void:
	_logo_rect = _make_logo()
	_banner = _make_banner()
	_logo_rect.modulate.a = 0.0
	_banner.modulate.a = 0.0
	var t := create_tween()
	t.tween_property(_logo_rect, "modulate:a", 1.0, 0.2)
	t.parallel().tween_property(_banner, "modulate:a", 1.0, 0.2)
	if sound:
		t.tween_callback(func() -> void: SfxService.play(SfxService.CUE_TREASURE_LINKAGE))
	t.tween_interval(0.9)
	t.tween_property(_logo_rect, "modulate:a", 0.0, 0.3)
	t.parallel().tween_property(_banner, "modulate:a", 0.0, 0.3)
	t.tween_callback(_land.bind(slot, false))
	t.tween_callback(finished.emit)
	t.tween_interval(2.2)
	t.tween_callback(queue_free)


# --- 部件 ------------------------------------------------------------------------

func _ring(at: Vector2, color: Color, r0: float, r1: float, duration: float, line_width: float) -> void:
	var ring := Line2D.new()
	ring.material = _add()
	ring.closed = true
	ring.width = line_width
	ring.default_color = color
	ring.position = at
	ring.points = _circle(r0)
	add_child(ring)
	var t := ring.create_tween()
	t.tween_property(ring, "points", _circle(r1), duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(ring, "width", line_width * 0.3, duration)
	t.parallel().tween_property(ring, "modulate:a", 0.0, duration * 0.7).set_delay(duration * 0.3)
	t.tween_callback(ring.queue_free)


func _sparkles(at: Vector2, colors: Array[Color], particle_scale: float) -> void:
	var p := CPUParticles2D.new()
	p.texture = _star()
	p.material = _add()
	p.position = at
	p.amount = maxi(6, int(round(float(QUALITY.particle_count(44)) * particle_scale)))
	p.lifetime = 0.95
	p.one_shot = true
	p.explosiveness = 0.92
	p.direction = Vector2.UP
	p.spread = 180.0
	p.initial_velocity_min = 170.0
	p.initial_velocity_max = 400.0
	p.damping_min = 220.0
	p.damping_max = 320.0
	p.gravity = Vector2(0.0, 140.0)
	p.angle_min = 0.0
	p.angle_max = 90.0
	p.scale_amount_min = 0.22
	p.scale_amount_max = 0.62
	p.color_initial_ramp = _palette(colors)
	p.color_ramp = _fade_ramp()
	add_child(p)
	p.emitting = true
	var t := p.create_tween()
	t.tween_interval(p.lifetime + 0.2)
	t.tween_callback(p.queue_free)


func _make_trail() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.texture = _star()
	p.material = _add()
	p.local_coords = false
	p.amount = maxi(4, QUALITY.particle_count(18))
	p.lifetime = 0.35
	p.spread = 180.0
	p.initial_velocity_min = 10.0
	p.initial_velocity_max = 40.0
	p.scale_amount_min = 0.12
	p.scale_amount_max = 0.3
	p.color = Tokens.GOLD_HOVER
	p.color_ramp = _fade_ramp()
	p.position = _logo_rect.position + _logo_rect.size * 0.5
	add_child(p)
	p.emitting = true
	var t := p.create_tween()
	t.tween_interval((LAND_AT - FLY_AT) + p.lifetime + 0.2)
	t.tween_callback(p.queue_free)
	return p


func _make_logo() -> TextureRect:
	var r := TextureRect.new()
	r.texture = _logo_tex
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	r.size = Vector2(LOGO_SIZE, LOGO_SIZE)
	r.pivot_offset = r.size * 0.5
	r.position = _stage - r.size * 0.5
	add_child(r)
	return r


func _make_banner() -> Control:
	var box := Control.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.size = BANNER_SIZE
	box.position = Vector2(_stage.x - BANNER_SIZE.x * 0.5, _stage.y + LOGO_SIZE * 0.5 + 14.0)
	var ribbon := TextureRect.new()
	ribbon.texture = _ribbon()
	ribbon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ribbon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ribbon.stretch_mode = TextureRect.STRETCH_SCALE
	ribbon.size = BANNER_SIZE
	box.add_child(ribbon)
	var label := Label.new()
	label.text = _title
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size = BANNER_SIZE
	label.add_theme_font_size_override("font_size", BANNER_FONT_SIZE)
	label.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	label.add_theme_color_override("font_outline_color", Color(0.10, 0.06, 0.02, 0.95))
	label.add_theme_constant_override("outline_size", 9)
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.55))
	label.add_theme_constant_override("shadow_offset_y", 3)
	box.add_child(label)
	add_child(box)
	return box


func _sprite(tex: Texture2D, at: Vector2, color: Color, px: float) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = tex
	s.material = _add()
	s.modulate = color
	s.position = at
	s.scale = Vector2.ONE * (px / float(tex.get_width()))
	add_child(s)
	return s


static func _circle(radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in 48:
		var a := TAU * float(i) / 48.0
		points.append(Vector2(cos(a), sin(a)) * radius)
	return points


# --- 程序纹理（首次用到时生成一次） --------------------------------------------------

static func _add() -> CanvasItemMaterial:
	if _add_material == null:
		_add_material = CanvasItemMaterial.new()
		_add_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return _add_material


static func _soft() -> Texture2D:
	if _soft_texture == null:
		var g := Gradient.new()
		g.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
		g.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
		g.add_point(0.35, Color(1.0, 1.0, 1.0, 0.45))
		var tex := GradientTexture2D.new()
		tex.gradient = g
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(0.5, 0.0)
		tex.width = 128
		tex.height = 128
		_soft_texture = tex
	return _soft_texture


# 四角星：两条细长的高斯光带交叉，再叠一个小亮核。
static func _star() -> Texture2D:
	if _star_texture == null:
		var n := 64
		var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
		var c := float(n - 1) * 0.5
		for y in n:
			for x in n:
				var dx := (float(x) - c) / c
				var dy := (float(y) - c) / c
				var arm := maxf(exp(-dx * dx / 0.18 - dy * dy / 0.004), exp(-dy * dy / 0.18 - dx * dx / 0.004))
				var core := exp(-(dx * dx + dy * dy) / 0.02)
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(arm * 0.9 + core, 0.0, 1.0)))
		_star_texture = ImageTexture.create_from_image(img)
	return _star_texture


static func _ribbon() -> Texture2D:
	if _ribbon_texture == null:
		var g := Gradient.new()
		g.set_color(0, Color(0.06, 0.04, 0.02, 0.0))
		g.set_color(1, Color(0.06, 0.04, 0.02, 0.0))
		g.add_point(0.22, Color(0.06, 0.04, 0.02, 0.72))
		g.add_point(0.78, Color(0.06, 0.04, 0.02, 0.72))
		var tex := GradientTexture2D.new()
		tex.gradient = g
		tex.width = 256
		tex.height = 8
		_ribbon_texture = tex
	return _ribbon_texture


static func _palette(colors: Array[Color]) -> Gradient:
	var unique: Array[Color] = [Tokens.GOLD_HOVER]
	for c in colors:
		if not unique.has(c):
			unique.append(c)
	var offsets := PackedFloat32Array()
	var packed := PackedColorArray()
	for i in unique.size():
		offsets.append(float(i) / float(unique.size()))
		packed.append(unique[i])
	var g := Gradient.new()
	g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	g.offsets = offsets
	g.colors = packed
	return g


static func _fade_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	g.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	g.add_point(0.6, Color(1.0, 1.0, 1.0, 0.85))
	return g
