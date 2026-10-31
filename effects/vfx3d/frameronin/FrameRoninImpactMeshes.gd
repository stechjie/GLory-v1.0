extends RefCounted
class_name FrameRoninImpactMeshes
## Adapted selected FrameRonin presets 81 and 85. See third_party/frameronin_vfx/SOURCE.md.
## Shared growth poses keep the source geometry without per-death mesh rebuilding.
const POSES := 12
static var _cache: Dictionary = {}
var primary := Color("ffb12f")
var secondary := Color("fff3c6")
var strength := 1.0
var fx_time := 0.0
var _origin := Vector3.ZERO
var _ring_layer := 0.0
var _surface: SurfaceTool

static func frames(preset: int) -> Array[ArrayMesh]:
	assert(preset in [81,85])
	if not _cache.has(preset):
		var builder := FrameRoninImpactMeshes.new()
		var baked: Array[ArrayMesh] = []
		for pose in POSES:
			baked.append(builder._pose(preset,float(pose)/float(POSES-1)))
		_cache[preset] = baked
	var result: Array[ArrayMesh] = _cache[preset]
	return result

func _pose(preset: int, growth: float) -> ArrayMesh:
	# Skip the demo's looping windup: the fatal hit has already occurred.
	fx_time = lerpf(0.405,0.535,growth)
	_origin = Vector3(0.36,-0.02,1.44) if preset == 81 else Vector3(0.30,0.18,1.47)
	_surface = SurfaceTool.new()
	_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	if preset == 81:
		_draw_combat_blunt_impact()
	else:
		_draw_combat_critical_break()
	var mesh := _surface.commit()
	mesh.set_meta("frameronin_preset",preset)
	return mesh

func _vertex(point: Vector3, color: Color) -> void:
	_surface.set_color(color)
	_surface.set_uv(Vector2(_ring_layer,0.0))
	_surface.add_vertex(point-_origin)

func _draw_combat_blunt_impact() -> void:
	var local_time := fposmod(fx_time, 1.60)
	var compression := smoothstep(0.03, 0.34, local_time)
	var impact := smoothstep(0.25, 0.53, local_time)
	var front_plane := Basis(Vector3.RIGHT, PI * 0.5)
	var center := Vector3(0.36, -0.02, 1.44)
	# Contracting rings establish compression before the square-edged release.
	for ring_index in 3:
		var radius := lerpf(1.34 + float(ring_index) * 0.22, 0.30 + float(ring_index) * 0.05, compression)
		_ring(center, radius, 0.034, 30, float(ring_index) * 0.22, TAU, _with_alpha(primary.lerp(secondary, float(ring_index) * 0.24), (1.0 - compression * 0.44) * 0.46), front_plane)
	_soft_disc(center, 0.18 + impact * 0.46, primary, 0.34 * impact, front_plane, 24)
	# Short wide rays and block chips prevent the silhouette from reading as a
	# blade or elemental flower.
	for ray_index in 12:
		var angle := float(ray_index) * TAU / 12.0 + 0.12
		var direction := Vector3(cos(angle), sin(angle), 0.0)
		var tangent := Vector3(-direction.y, direction.x, 0.0)
		var base := center + direction * 0.16
		var tip := center + direction * (0.48 + impact * (0.56 + float(ray_index % 3) * 0.12))
		_triangle(base - tangent * 0.065, base + tangent * 0.065, tip, _with_alpha(primary, 0.42 * impact), _with_alpha(secondary, 0.46 * impact), _with_alpha(primary, 0.10))
	for chip_index in 9:
		var angle := float(chip_index) * TAU / 9.0 + 0.28
		var distance := (0.54 + float(chip_index % 3) * 0.24) * impact
		var point := center + Vector3(cos(angle) * distance, sin(angle) * distance, 0.025)
		_diamond(point, Vector3.UP, Vector3.RIGHT, 0.09 + float(chip_index % 2) * 0.05, 0.055, _with_alpha(primary.lerp(secondary, float(chip_index % 2)), 0.68 * impact))
	_ring(center, 0.30 + impact * 0.78, 0.050, 32, 0.0, TAU, _with_alpha(Color.WHITE, 0.62 * impact), front_plane)
	_star(center, 0.13 + impact * 0.21, _with_alpha(Color.WHITE, 0.95 * impact), Basis.IDENTITY)

func _draw_combat_critical_break() -> void:
	var local_time := fposmod(fx_time, 1.60)
	var lock := smoothstep(0.03, 0.32, local_time)
	var impact := smoothstep(0.27, 0.53, local_time)
	var front_plane := Basis(Vector3.RIGHT, PI * 0.5)
	var center := Vector3(0.30, 0.18, 1.47)
	for ring_index in 3:
		var radius := lerpf(1.12 + float(ring_index) * 0.18, 0.28 + float(ring_index) * 0.06, lock)
		_ring(center, radius, 0.026 + float(ring_index) * 0.006, 4, PI * 0.25 + float(ring_index) * 0.14, TAU, _with_alpha(primary.lerp(secondary, float(ring_index) * 0.34), (1.0 - lock * 0.36) * 0.54), front_plane)
	_soft_disc(center, 0.18 + impact * 0.48, primary, 0.36 * impact, front_plane, 24)
	# Two crossed cuts plus uneven rays create a high-priority punctuation mark
	# without relying on text, numbers, or a copied game UI glyph.
	_segment(center + Vector3(-0.92, -0.78, 0.0) * impact, center + Vector3(0.96, 0.82, 0.0) * impact, 0.072, _with_alpha(primary, 0.08), _with_alpha(Color.WHITE, 0.90 * impact))
	_segment(center + Vector3(-0.62, 0.94, 0.0) * impact, center + Vector3(0.72, -1.08, 0.0) * impact, 0.055, _with_alpha(secondary, 0.12), _with_alpha(Color.WHITE, 0.82 * impact))
	for ray_index in 16:
		var angle := float(ray_index) * TAU / 16.0 + 0.08
		var direction := Vector3(cos(angle), sin(angle), 0.0)
		var length := (0.58 + float((ray_index * 5) % 4) * 0.22) * impact
		_segment(center + direction * 0.16, center + direction * length, 0.026 + float(ray_index % 2) * 0.012, _with_alpha(Color.WHITE, 0.82 * impact), _with_alpha(primary, 0.06))
	for accent_index in 4:
		var angle := PI * 0.25 + float(accent_index) * PI * 0.5
		var point := center + Vector3(cos(angle), sin(angle), 0.0) * (0.74 + float(accent_index % 2) * 0.20) * impact
		_diamond(point, Vector3.UP, Vector3.RIGHT, 0.13, 0.055, _with_alpha(secondary, 0.76 * impact))
	_star(center, 0.14 + impact * 0.24, _with_alpha(Color.WHITE, 0.98 * impact), Basis.IDENTITY)

func _triangle(a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	_vertex(a, ca)
	_vertex(b, cb)
	_vertex(c, cc)

func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, ca: Color, cb: Color, cc: Color, cd: Color) -> void:
	_triangle(a, b, c, ca, cb, cc)
	_triangle(a, c, d, ca, cc, cd)

func _segment(a: Vector3, b: Vector3, width: float, color_a: Color, color_b: Color) -> void:
	var direction := b - a
	if direction.length_squared() < 0.000001:
		return
	direction = direction.normalized()
	var side := direction.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = Vector3.RIGHT
	side = side.normalized() * width
	var cross_side := direction.cross(side).normalized() * width * 0.72
	_quad(a - side, a + side, b + side, b - side, color_a, color_a, color_b, color_b)
	_quad(a - cross_side, a + cross_side, b + cross_side, b - cross_side, color_a, color_a, color_b, color_b)

func _ring(center: Vector3, radius: float, width: float, segments: int, start_angle: float, arc: float, color: Color, basis := Basis.IDENTITY) -> void:
	_ring_layer = 1.0
	width *= 0.55
	for index in segments:
		var a0 := start_angle + arc * float(index) / float(segments)
		var a1 := start_angle + arc * float(index + 1) / float(segments)
		var inner0 := basis * Vector3(cos(a0) * (radius - width), 0.0, sin(a0) * (radius - width)) + center
		var outer0 := basis * Vector3(cos(a0) * (radius + width), 0.0, sin(a0) * (radius + width)) + center
		var inner1 := basis * Vector3(cos(a1) * (radius - width), 0.0, sin(a1) * (radius - width)) + center
		var outer1 := basis * Vector3(cos(a1) * (radius + width), 0.0, sin(a1) * (radius + width)) + center
		_quad(inner0, outer0, outer1, inner1, color, color, color, color)
	_ring_layer = 0.0

func _soft_disc(center: Vector3, radius: float, color: Color, alpha: float, basis := Basis.IDENTITY, segments := 24) -> void:
	var core := _with_alpha(color, alpha)
	var edge := _with_alpha(color, 0.0)
	for segment_index in segments:
		var a0 := float(segment_index) * TAU / float(segments)
		var a1 := float(segment_index + 1) * TAU / float(segments)
		var p0 := basis * Vector3(cos(a0) * radius, 0.0, sin(a0) * radius) + center
		var p1 := basis * Vector3(cos(a1) * radius, 0.0, sin(a1) * radius) + center
		_triangle(center, p0, p1, core, edge, edge)

func _diamond(center: Vector3, up_axis: Vector3, side_axis: Vector3, height: float, width: float, color: Color) -> void:
	var up := up_axis.normalized() * height
	var side := side_axis.normalized() * width
	var transparent := Color(color.r, color.g, color.b, 0.0)
	_triangle(center + up, center + side, center - up, transparent, color, transparent)
	_triangle(center + up, center - up, center - side, transparent, transparent, color)

func _star(center: Vector3, radius: float, color: Color, basis := Basis.IDENTITY) -> void:
	for point in 10:
		var a0 := -PI * 0.5 + float(point) * TAU / 10.0
		var a1 := -PI * 0.5 + float(point + 1) * TAU / 10.0
		var r0 := radius if point % 2 == 0 else radius * 0.43
		var r1 := radius if (point + 1) % 2 == 0 else radius * 0.43
		var p0 := basis * Vector3(cos(a0) * r0, sin(a0) * r0, 0.0) + center
		var p1 := basis * Vector3(cos(a1) * r1, sin(a1) * r1, 0.0) + center
		_triangle(center, p0, p1, color, color, color)

func _with_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha * strength)
