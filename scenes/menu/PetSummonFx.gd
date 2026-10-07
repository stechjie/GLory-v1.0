extends Control

# Layered forest energy drawn in one small UI region. Rewards remain server-authoritative.
const Tokens := preload("res://ui/theme/GloryTokens.gd")

var energy := 0
var _time := 0.0
var _summon_time := -1.0
var _core_texture: GradientTexture2D
var _burst_texture: GradientTexture2D

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var radial := Gradient.new()
	var pearl := Tokens.TEXT_PRIMARY
	pearl.a = 0.96
	var honey := Tokens.GOLD_HOVER
	honey.a = 0.93
	var mint := Tokens.SUMMON_ENERGY_LIGHT
	mint.a = 0.86
	var jade := Tokens.SUMMON_ENERGY_GREEN
	jade.a = 0.72
	var dark_edge := Tokens.SUMMON_ENERGY_SHADOW
	dark_edge.a = 0.48
	var transparent := Tokens.SUMMON_ENERGY_GREEN
	transparent.a = 0.0
	radial.set_color(0, pearl)
	radial.set_color(1, transparent)
	radial.add_point(0.18, honey)
	radial.add_point(0.39, mint)
	radial.add_point(0.61, jade)
	radial.add_point(0.76, dark_edge)
	_core_texture = GradientTexture2D.new()
	_core_texture.width = 128
	_core_texture.height = 128
	_core_texture.fill = GradientTexture2D.FILL_RADIAL
	_core_texture.fill_from = Vector2(0.5, 0.5)
	_core_texture.fill_to = Vector2(1.0, 0.5)
	_core_texture.gradient = radial
	var burst := Gradient.new()
	var burst_center := Tokens.GOLD_HOVER
	burst_center.a = 0.43
	var burst_mid := Tokens.GOLD_EDGE
	burst_mid.a = 0.16
	var burst_clear := Tokens.GOLD_EDGE
	burst_clear.a = 0.0
	burst.set_color(0, burst_center)
	burst.set_color(1, burst_clear)
	burst.add_point(0.48, burst_mid)
	_burst_texture = GradientTexture2D.new()
	_burst_texture.width = 128
	_burst_texture.height = 128
	_burst_texture.fill = GradientTexture2D.FILL_RADIAL
	_burst_texture.fill_from = Vector2(0.5, 0.5)
	_burst_texture.fill_to = Vector2(1.0, 0.5)
	_burst_texture.gradient = burst
	set_process(true)

func set_energy(value: int) -> void:
	energy = clampi(value, 0, 9)
	queue_redraw()

func start_summon() -> void:
	_summon_time = 0.0
	queue_redraw()

func is_summoning() -> bool:
	return _summon_time >= 0.0

func _process(delta: float) -> void:
	_time += delta
	if _summon_time >= 0.0:
		_summon_time += delta
		if _summon_time >= Tokens.motion(0.82):
			_summon_time = -1.0
	queue_redraw()

func _draw() -> void:
	var center := Vector2(810, 324)
	var charge := clampf(_summon_time / 0.82, 0.0, 1.0) if is_summoning() else 0.0
	var gathering := smoothstep(0.14, 0.88, charge)
	var release := smoothstep(0.88, 1.0, charge)
	var scale_factor := (1.0 + 0.08 * sin(_time * 2.2)) * (1.0 - 0.54 * gathering)
	var spin := _time * 0.19 + (charge * charge * 11.0 if is_summoning() else 0.0)
	var shake_strength := 2.2 * charge * (1.0 - charge)
	center += Vector2(sin(_time * 73.0), cos(_time * 61.0)) * shake_strength
	var altar := Vector2(810, 359)
	var stem := Tokens.GOLD_HOVER
	stem.a = 0.17 + 0.19 * charge
	draw_line(altar, center + Vector2(0, 20 * scale_factor), stem, 10.0 * scale_factor, true)
	stem.a = 0.45 + 0.25 * charge
	draw_line(altar, center + Vector2(0, 20 * scale_factor), stem, 2.0 * scale_factor, true)
	var halo := Tokens.SUMMON_ENERGY_GREEN
	halo.a = 0.075 + 0.07 * charge
	draw_circle(center, 86.0 * scale_factor, halo)
	# Three open, asymmetric streams keep this a forest energy sphere rather than a portal ring.
	_wisp(center, Vector2(-82, 49), Vector2(-113, -44), Vector2(-8, -116),
		Vector2(59, -66), spin, 24.0 * scale_factor, scale_factor,
		Tokens.SUMMON_ENERGY_GREEN, 0.66)
	_wisp(center, Vector2(-71, 52), Vector2(-28, 93), Vector2(70, 64),
		Vector2(78, -31), -spin * 0.88, 26.0 * scale_factor, scale_factor,
		Tokens.GOLD_EDGE, 1.00)
	_wisp(center, Vector2(69, -42), Vector2(77, 25), Vector2(19, 64),
		Vector2(-41, 18), spin * 1.13, 20.0 * scale_factor, scale_factor,
		Tokens.SUMMON_ENERGY_LIGHT, 0.90)
	# The bright pearl reads as one levitating object in front of the distant landscape.
	var core_size := 99.0 * scale_factor
	draw_texture_rect(_core_texture,
		Rect2(center - Vector2.ONE * core_size * 0.5, Vector2.ONE * core_size), false)
	var shaded_edge := Tokens.SUMMON_ENERGY_SHADOW
	shaded_edge.a = 0.54
	draw_arc(center, 29.0 * scale_factor, 0.18 + spin * 0.08,
		2.10 + spin * 0.08, 28, shaded_edge, 3.3 * scale_factor, true)
	var highlight := Tokens.TEXT_PRIMARY
	highlight.a = 0.78
	draw_circle(center + Vector2(-8, -10) * scale_factor, 4.5 * scale_factor, highlight)
	var sparkle := Tokens.GOLD_HOVER
	sparkle.a = 0.78
	draw_circle(center + Vector2(10, 9) * scale_factor, 2.0 * scale_factor, sparkle)
	for i in 6:
		var angle := _time * (0.40 + float(i % 3) * 0.10) + float(i) * TAU / 6.0
		var distance := (91.0 + 6.0 * sin(_time * 1.3 + i)) * scale_factor
		var firefly := center + Vector2(cos(angle), sin(angle)) * distance
		var mote_halo := Tokens.GOLD_EDGE
		mote_halo.a = 0.10 + 0.08 * charge
		draw_circle(firefly, 7.0, mote_halo)
		var point := Tokens.GOLD_HOVER
		point.a = 0.74 + 0.16 * charge
		draw_circle(firefly, 2.2, point)
	if release > 0.0:
		var burst_size := 185.0 + 100.0 * release
		draw_texture_rect(_burst_texture,
			Rect2(center - Vector2.ONE * burst_size * 0.5, Vector2.ONE * burst_size),
			false, Color(1.0, 1.0, 1.0, release))

		for ray in 8:
			var direction := Vector2.from_angle(float(ray) * TAU / 8.0 + spin)
			var ray_color := Tokens.TEXT_PRIMARY
			ray_color.a = 0.66 * release
			draw_line(center + direction * 35.0,
				center + direction * (64.0 + 46.0 * release),
				ray_color, 3.0, true)
	_draw_progress()

func _wisp(center: Vector2, p0: Vector2, p1: Vector2, p2: Vector2,
	p3: Vector2, rotation: float, width: float, scale_factor: float,
	base_color: Color, opacity: float) -> void:
	for layer in 3:
		var outside := PackedVector2Array()
		var inside := PackedVector2Array()
		var layer_width: float = width * float([1.65, 1.0, 0.38][layer])
		for step in 29:
			var u := float(step) / 28.0
			var before := _bezier(p0, p1, p2, p3, maxf(0.0, u - 0.01))
			var after := _bezier(p0, p1, p2, p3, minf(1.0, u + 0.01))
			var point := _bezier(p0, p1, p2, p3, u)
			var normal := (after - before).normalized().orthogonal()
			var taper := pow(sin(u * PI), 0.82)
			var flutter := 1.0 + 0.075 * sin(_time * 1.4 + u * 9.0)
			var local_width := layer_width * taper * flutter
			outside.append(center + (point + normal * local_width * 0.5).rotated(rotation) * scale_factor)
			inside.append(center + (point - normal * local_width * 0.5).rotated(rotation) * scale_factor)
		var shape := outside
		for index in range(inside.size() - 1, -1, -1):
			shape.append(inside[index])
		var color := base_color
		color.a = opacity * [0.16, 0.37, 0.64][layer]
		draw_colored_polygon(shape, color)

func _bezier(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, u: float) -> Vector2:
	var v := 1.0 - u
	return p0 * (v * v * v) + p1 * (3.0 * v * v * u) + p2 * (3.0 * v * u * u) + p3 * (u * u * u)

func _blob(center: Vector2, radius: float, color: Color, phase: float) -> void:
	var shape := PackedVector2Array()
	for step in 33:
		var angle := float(step) * TAU / 32.0
		var distortion := 1.0 + 0.075 * sin(angle * 5.0 + phase) + 0.045 * cos(angle * 8.0 - phase)
		shape.append(center + Vector2(cos(angle), sin(angle)) * radius * distortion)
	draw_colored_polygon(shape, color)

func _draw_progress() -> void:
	for i in 10:
		var center := Vector2(1330 + (i % 2) * 90, 250 + (i / 2) * 58)
		var active := i < energy
		var halo := Tokens.SUMMON_ENERGY_GREEN
		halo.a = 0.18 if active else 0.08
		draw_circle(center, 23.0 + (1.3 * sin(_time * 2.0 + i) if active else 0.0), halo)
		var rim := Tokens.SUMMON_ENERGY_GREEN
		rim.a = 0.84 if active else 0.45
		draw_arc(center, 15.0, 0.0, TAU, 32, rim, 2.0, true)
		var body := Tokens.SUMMON_ENERGY_GREEN if active else Tokens.SUMMON_ENERGY_SHADOW
		body.a = 0.74 if active else 0.21
		_blob(center, 11.0 + (0.8 * sin(_time * 2.3 + i) if active else 0.0), body,
			_time * 1.2 + float(i))
		if active:
			var core := Tokens.SUMMON_ENERGY_LIGHT
			core.a = 0.88
			draw_circle(center + Vector2(-2, -2), 4.0, core)
