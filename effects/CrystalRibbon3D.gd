extends MeshInstance3D

# 结算演出用的飘带：头部从棋子飞向水晶，身体拖在后面波动、边飞边扭，命中瞬间发出
# hit 信号（调用方据此扣 1 点血、闪光、震水晶），之后尾巴追上来并淡出。
#
# 网格每帧重建（ImmediateMesh）。同屏最多一两条，重建开销可以忽略。

signal hit

const SEGMENTS := 28
# 尾巴占整条路径的比例。头部飞到 1.0 时，尾巴还在 1.0 - TAIL_SPAN 处。
const TAIL_SPAN := 0.78
const WAVE_COUNT := 1.6
const WAVE_SPEED := 6.5
const TWIST_SPEED := 4.2

var start_point := Vector3.ZERO
var end_point := Vector3.ZERO
var ribbon_color := Color.WHITE
var ribbon_width := 0.34
var flight_sec := 0.34
var fade_sec := 0.26
# 路径中间向上拱起的高度，让弹道有一点弧线而不是一条直线。
var arc_height := 0.55
var wave_amplitude := 0.34

var _immediate_mesh := ImmediateMesh.new()
var _elapsed := 0.0
var _hit_emitted := false
var _side := Vector3.RIGHT
var _up := Vector3.UP

func _ready() -> void:
	mesh = _immediate_mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	# 飘带是单面几何而且会自己扭转，背面剔除会让扭过去的那半截凭空消失。
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	material_override = mat
	# 顶点已经是世界坐标，节点本身必须留在原点。
	global_transform = Transform3D.IDENTITY
	var direction := end_point - start_point
	if direction.length() < 0.0001:
		direction = Vector3.FORWARD
	var forward := direction.normalized()
	_side = forward.cross(Vector3.UP)
	if _side.length() < 0.001:
		_side = Vector3.RIGHT
	_side = _side.normalized()
	_up = _side.cross(forward).normalized()
	_rebuild(0.0)

func _process(delta: float) -> void:
	_elapsed += delta
	var head: float = clampf(_elapsed / maxf(flight_sec, 0.0001), 0.0, 1.0)
	if not _hit_emitted and head >= 1.0:
		_hit_emitted = true
		hit.emit()
	if _elapsed >= flight_sec + fade_sec:
		queue_free()
		return
	_rebuild(head)

# 路径上 t∈[0,1] 处的中心点：直线 + 向上的弧 + 侧向正弦波。
func _path_point(t: float, wave_phase: float) -> Vector3:
	var base := start_point.lerp(end_point, t)
	base += Vector3.UP * sin(t * PI) * arc_height
	# 两端收敛到 0，波动只发生在中段，头尾才不会跟棋子/水晶脱节。
	var envelope := sin(t * PI)
	base += _side * sin(t * WAVE_COUNT * TAU + wave_phase) * wave_amplitude * envelope
	return base

func _rebuild(head: float) -> void:
	_immediate_mesh.clear_surfaces()
	var tail: float = maxf(0.0, head - TAIL_SPAN)
	if head - tail < 0.0001:
		return
	var wave_phase := _elapsed * WAVE_SPEED
	# 头部到达后整条渐隐，同时尾巴继续追上来。
	var life_fade := 1.0
	if _elapsed > flight_sec:
		life_fade = clampf(1.0 - (_elapsed - flight_sec) / maxf(fade_sec, 0.0001), 0.0, 1.0)
	_immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in SEGMENTS + 1:
		var along := float(i) / float(SEGMENTS)
		var t: float = lerp(tail, head, along)
		var center := _path_point(t, wave_phase)
		# 越靠尾巴越窄越淡，头部最实。
		var taper: float = 0.18 + 0.82 * along
		var alpha: float = ribbon_color.a * life_fade * (0.35 + 0.65 * along)
		# 沿着长度扭转，读起来才像一条彩带而不是一条平板。
		var twist := t * WAVE_COUNT * TAU + _elapsed * TWIST_SPEED
		var edge := (_side * cos(twist) + _up * sin(twist)) * ribbon_width * 0.5 * taper
		var vertex_color := Color(ribbon_color.r, ribbon_color.g, ribbon_color.b, alpha)
		_immediate_mesh.surface_set_color(vertex_color)
		_immediate_mesh.surface_add_vertex(center - edge)
		_immediate_mesh.surface_set_color(vertex_color)
		_immediate_mesh.surface_add_vertex(center + edge)
	_immediate_mesh.surface_end()
