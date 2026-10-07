extends Control

# Layered forest energy drawn in one small UI region. Rewards remain server-authoritative.
const Tokens := preload("res://ui/theme/GloryTokens.gd")

var energy := 0
var _time := 0.0
var _summon_time := -1.0
var _core_texture: GradientTexture2D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var radial := Gradient.new()
	var dark := Tokens.SUMMON_ENERGY_SHADOW
	dark.a = 0.90
	var green := Tokens.SUMMON_ENERGY_GREEN
	green.a = 0.67
	var edge := Tokens.SUMMON_ENERGY_LIGHT
	edge.a = 0.0
	radial.set_color(0, dark)
	radial.set_color(1, edge)
	radial.add_point(0.34, green)
	_core_texture = GradientTexture2D.new()
	_core_texture.width = 128
	_core_texture.height = 128
	_core_texture.fill = GradientTexture2D.FILL_RADIAL
	_core_texture.fill_from = Vector2(0.5, 0.5)
	_core_texture.fill_to = Vector2(1.0, 0.5)
	_core_texture.gradient = radial
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
	var contraction := smoothstep(0.10, 0.82, charge)
	var scale_factor := lerpf(1.0, 0.24, contraction * contraction)
	var pulse := 1.0 + 0.035 * sin(_time * 2.7)
	var spin := _time * (10.0 if is_summoning() else 0.30)
	var shake_strength := 3.0 * charge * (1.0 - charge)
	center += Vector2(sin(_time * 73.0), cos(_time * 61.0)) * shake_strength
	var glow := Tokens.SUMMON_ENERGY_GREEN
	glow.a = 0.09 + charge * 0.08
	draw_circle(center, 82.0 * scale_factor, glow)
	# Broad, uneven streams give the core a direction and painted silhouette.
	_ribbon(center, 80.0 * scale_factor, spin - 1.8, 4.18, 22.0 * scale_factor,
		Tokens.SUMMON_ENERGY_SHADOW, 0.45)
	_ribbon(center, 69.0 * scale_factor, -spin + 1.2, 3.90, 20.0 * scale_factor,
		Tokens.GOLD_EDGE, 0.56)
	_ribbon(center, 53.0 * scale_factor, spin + 2.2, 3.45, 13.0 * scale_factor,
		Tokens.SUMMON_ENERGY_LIGHT, 0.52)
	# A soft radial core avoids a flat, hard-edged disk on the bright altar.
	var core_size := 112.0 * pulse * scale_factor
	draw_texture_rect(_core_texture,
		Rect2(center - Vector2.ONE * core_size * 0.5, Vector2.ONE * core_size), false)
	var heart := Tokens.TEXT_PRIMARY
	heart.a = 0.78
	draw_circle(center + Vector2(-5, -7) * scale_factor, 4.0 * scale_factor, heart)
	for i in 6:
		var angle := _time * (0.42 + float(i % 3) * 0.10) + float(i) * TAU / 6.0
		var firefly := center + Vector2(cos(angle), sin(angle)) * (90.0 * scale_factor + 8.0 * sin(_time + i))
		var halo := Tokens.GOLD_EDGE
		halo.a = 0.11
		draw_circle(firefly, 8.0, halo)
		var point := Tokens.GOLD_HOVER
		point.a = 0.78
		draw_circle(firefly, 2.7, point)
	_draw_progress()


func _ribbon(center: Vector2, radius: float, angle: float, sweep: float,
	width: float, base_color: Color, opacity: float) -> void:
	for layer in 3:
		var outside := PackedVector2Array()
		var inside := PackedVector2Array()
		var layer_width: float = width * float([1.8, 1.0, 0.38][layer])
		for step in 41:
			var u := float(step) / 40.0
			var a := angle + sweep * u
			var wave := (sin(a * 3.2 + _time * 0.7) * 5.5 + cos(a * 6.1 - _time * 0.3) * 2.5)
			var radial := radius + wave
			var taper := pow(sin(u * PI), 0.72)
			var local_width := layer_width * taper * (0.88 + 0.12 * sin(a * 5.0))
			var direction := Vector2(cos(a), sin(a))
			outside.append(center + direction * (radial + local_width * 0.5))
			inside.append(center + direction * (radial - local_width * 0.5))
		var shape := outside
		for index in range(inside.size() - 1, -1, -1):
			shape.append(inside[index])
		var color := base_color
		color.a = opacity * [0.14, 0.34, 0.52][layer]
		draw_colored_polygon(shape, color)


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
