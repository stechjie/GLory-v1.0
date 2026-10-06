@tool
extends Node3D
## 魔法能量护栏的一段（EnergyBarrierSegment.tscn），可以重复实例化。
##
## 中间完全是空的：没有任何墙面、半透明平面或雾。一段由这几层组成：
##   BaseEnergyLine          地面能量线（呼吸 + 流动脉冲 + 偶发小电弧）
##   EnergyRibbon01~04       流动能量丝（显示几根 = 场景里开着眼睛图标的几根）
##   VerticalBeamParticles   随机冒出、升起、淡掉的竖向光柱
##   Rune                    段中央悬浮的菱形符文
##   SparkParticles          少量漂浮粒子（一部分上飘、一部分顺着光带流）
##   LeftAnchor / RightAnchor  两端的低模石柱 + 水晶（几何由本脚本生成，不存进场景文件）
##
## 规则：场景里存的是什么，预览和战斗里就是什么。
##   * 每层的颜色、亮度、速度、粗细都在各自节点的材质里改，改了就生效；
##     粒子数量直接改两个粒子节点的 Amount；水晶的颜色在根节点的 crystal_material 里改。
##   * 根节点上的参数只叠加、不覆盖：亮度 / 速度是乘在每层自己数值上的倍数；
##     颜色只有勾了 unify_color 才统一成根节点的 color（做红 / 金 / 紫版本用）。
##   * 材质里「Set By Root Node」那一组是根节点写进去的，别在那里改。
##   * 运行时只有两件事会改显示状态：低画质隐藏粒子和多余的光带、边界解除时整段消失。
##     其余（节点的眼睛图标）都按场景里的来。
##
## 段沿本地 Z 轴摆放、中心在原点，两根柱子在 z = ±barrier_length / 2。
## 纯表现：不碰碰撞、寻敌、回放、随机数。
## BattleArena 用 fit_between / play_loop / play_release / is_released / set_low_quality /
## set_preview_hidden 驱动它（每条分路边界上下两段，见 BattleArena._add_battle_3v3_dividers）。

signal release_finished

# 地面能量线（含光晕）的总宽度，米。
const LINE_WIDTH := 0.42
# 低画质：竖光和粒子全关，能量丝最多留 2 根；地面线、符文、柱子保留，边界照样看得清。
const LOW_QUALITY_RIBBONS := 2
# 开场强调：和旧符文墙同一个节奏（亮 0.4 秒，0.85 秒时落到常态）。
const EMPHASIS_HOLD_SEC := 0.4
const EMPHASIS_END_SEC := 0.85
const STONE_BASE := Color("3f4651")
const STONE_STEP := Color("4d5562")
const STONE_SHAFT := Color("5d6675")
const STONE_CAP := Color("727c8c")

## 勾上：所有发光层（地面线、光带、竖光、符文、粒子、水晶）都用下面的 color。
## 不勾：各层用自己材质里的颜色。做红 / 金 / 紫版本就勾上它再选颜色。
@export var unify_color := false:
	set(value):
		unify_color = value
		_apply_look()
@export var color := Color(0.30, 0.62, 1.0):
	set(value):
		color = value
		_apply_look()
## 整体亮度倍数，乘在每层自己的 energy_intensity 上。
@export_range(0.0, 3.0, 0.05) var energy_intensity := 1.0:
	set(value):
		energy_intensity = value
		_apply_look()
## 光带流动 / 摆动速度倍数（乘在每根光带的 speed_mul 上），顺流粒子也跟着它。
@export_range(0.0, 4.0, 0.05) var ribbon_speed := 1.0:
	set(value):
		ribbon_speed = value
		_apply_look()
## 地面线呼吸 / 脉冲 / 电弧、符文浮动、水晶脉动的速度倍数（乘在各层自己的 pulse_speed 上）。
@export_range(0.0, 4.0, 0.05) var pulse_speed := 1.0:
	set(value):
		pulse_speed = value
		_apply_look()
## 段长（两根柱子中心之间的距离），米。
@export_range(1.0, 20.0, 0.05, "suffix:m") var barrier_length := 6.0:
	set(value):
		if is_equal_approx(barrier_length, value):
			return
		barrier_length = value
		_apply_layout()
## 柱子高度，光带 / 竖光 / 符文的高度都按它的比例算，米。
@export_range(0.3, 2.5, 0.05, "suffix:m") var barrier_height := 0.7:
	set(value):
		if is_equal_approx(barrier_height, value):
			return
		barrier_height = value
		_apply_layout()
## 柱顶水晶和柱身发光槽的材质（水晶本身是脚本生成的，所以它的材质放在这里改）。
@export var crystal_material: ShaderMaterial:
	set(value):
		crystal_material = value
		if is_node_ready():
			_build_anchors()
			_apply_look()

static var _anchor_mesh_cache := {}
static var _stone_material: StandardMaterial3D

var _released := false
var _low_quality := false
# 加载过场按住（同旧符文墙）：BattleArena 摆位前这段还停在原点，先不显示。
var _preview_hidden := false
var _age := 0.0
var _anchor_parts: Array[MeshInstance3D] = []
var _anchor_height := -1.0
# 场景里各层原本的显示状态（眼睛图标）。低画质、重播都以它为准，不改场景的设定。
var _authored_visible := {}

@onready var _line: MeshInstance3D = $BaseEnergyLine
@onready var _ribbons: Array[MeshInstance3D] = [$EnergyRibbon01, $EnergyRibbon02, $EnergyRibbon03, $EnergyRibbon04]
@onready var _beams: GPUParticles3D = $VerticalBeamParticles
@onready var _rune: MeshInstance3D = $Rune
@onready var _sparks: GPUParticles3D = $SparkParticles
@onready var _left_anchor: Node3D = $LeftAnchor
@onready var _right_anchor: Node3D = $RightAnchor


func _ready() -> void:
	for node in _ribbons:
		_authored_visible[node] = node.visible
	for node in [_beams, _sparks]:
		_authored_visible[node] = node.visible
	_ensure_anchor_parts()
	_apply_layout()
	_apply_look()
	set_process(false)


# 端点取自真实边界：段中心放在两点中间，长度等于两点距离，并转到两点连线方向（只在水平面内）。
func fit_between(a: Vector3, b: Vector3) -> void:
	position = (a + b) * 0.5
	var span := b - a
	span.y = 0.0
	barrier_length = span.length()
	if span.length_squared() > 0.0001:
		rotation.y = atan2(span.x, span.z)


func set_low_quality(enabled: bool) -> void:
	_low_quality = enabled
	_apply_visibility()


func set_preview_hidden(enabled: bool) -> void:
	_preview_hidden = enabled
	visible = not _released and not enabled


# start_frame 只用来错开相位：同屏几段的脉冲、电弧、光带不会完全同步。
func play_loop(start_frame := 0) -> void:
	_released = false
	_age = 0.0
	visible = not _preview_hidden
	if not is_node_ready():
		return
	var offset := float(start_frame) * 1.37
	for mat in [_mat(_line), _mat(_rune)] + _ribbon_materials():
		mat.set_shader_parameter("time_offset", offset)
	_set_emphasis(1.0)
	_apply_visibility()
	if _beams.emitting:
		_beams.restart()
	if _sparks.emitting:
		_sparks.restart()
	set_process(not Engine.is_editor_hint())


# 边界解除的那一帧整段立即消失：不能留任何还像「墙」的东西让单位穿过去时看着别扭。
func play_release() -> void:
	if _released:
		return
	_released = true
	visible = false
	if is_node_ready():
		_beams.emitting = false
		_sparks.emitting = false
	set_process(false)
	release_finished.emit()


func is_released() -> bool:
	return _released


func _process(delta: float) -> void:
	_age += delta
	_set_emphasis(1.0 - smoothstep(EMPHASIS_HOLD_SEC, EMPHASIS_END_SEC, _age))
	if _age >= EMPHASIS_END_SEC:
		set_process(false)


func _set_emphasis(value: float) -> void:
	for mat in [_mat(_line), _mat(_rune)] + _ribbon_materials():
		mat.set_shader_parameter("emphasis", value)


func _apply_layout() -> void:
	if not is_node_ready():
		return
	var half := barrier_length * 0.5
	_line.position = Vector3(0.0, 0.012, 0.0)
	_line.scale = Vector3(LINE_WIDTH, 1.0, barrier_length)
	# 光带、粒子的形状在 shader 里算，网格本身的包围盒不准，按整段尺寸给一个。
	var bounds := AABB(Vector3(-0.45, -0.05, -half - 0.25), Vector3(0.9, barrier_height * 1.6 + 0.35, barrier_length + 0.5))
	for ribbon in _ribbons:
		ribbon.custom_aabb = bounds
	_beams.visibility_aabb = bounds
	_sparks.visibility_aabb = bounds
	_rune.position = Vector3(0.0, barrier_height * 0.62, 0.0)
	_rune.scale = Vector3.ONE * (0.36 + barrier_height * 0.3)
	_left_anchor.position = Vector3(0.0, 0.0, -half)
	_right_anchor.position = Vector3(0.0, 0.0, half)
	for mat in [_mat(_line), _proc(_beams), _proc(_sparks)] + _ribbon_materials():
		mat.set_shader_parameter("barrier_length", barrier_length)
	for mat in [_proc(_beams), _proc(_sparks)] + _ribbon_materials():
		mat.set_shader_parameter("barrier_height", barrier_height)
	_mat(_beams).set_shader_parameter("beam_height", barrier_height * 1.05)
	if not is_equal_approx(_anchor_height, barrier_height):
		_build_anchors()


# 只写「Set By Root Node」那一组，不碰各层自己的参数。
func _apply_look() -> void:
	if not is_node_ready():
		return
	var glow := [_mat(_line), _mat(_rune), _mat(_beams), _mat(_sparks)] + _ribbon_materials()
	var pulsing := [_mat(_line), _mat(_rune)]
	if crystal_material != null:
		glow.append(crystal_material)
		pulsing.append(crystal_material)
	for mat in glow:
		mat.set_shader_parameter("use_root_color", unify_color)
		mat.set_shader_parameter("root_color", color)
		mat.set_shader_parameter("root_intensity", energy_intensity)
	for mat in pulsing:
		mat.set_shader_parameter("root_pulse_speed", pulse_speed)
	for mat in [_proc(_sparks)] + _ribbon_materials():
		mat.set_shader_parameter("root_ribbon_speed", ribbon_speed)


# 只在运行时生效；编辑器里完全按眼睛图标显示。
func _apply_visibility() -> void:
	if not is_node_ready() or Engine.is_editor_hint():
		return
	var kept := 0
	for ribbon in _ribbons:
		var on: bool = _authored_visible[ribbon]
		if on and _low_quality:
			on = kept < LOW_QUALITY_RIBBONS
			kept += 1
		ribbon.visible = on
	for particles: GPUParticles3D in [_beams, _sparks]:
		var on: bool = _authored_visible[particles] and not _low_quality
		particles.visible = on
		particles.emitting = on and not _released


func _ribbon_materials() -> Array:
	var out := []
	for ribbon in _ribbons:
		out.append(_mat(ribbon))
	return out


func _mat(node: GeometryInstance3D) -> ShaderMaterial:
	return node.material_override as ShaderMaterial


func _proc(particles: GPUParticles3D) -> ShaderMaterial:
	return particles.process_material as ShaderMaterial


# ---- 两端柱子 ---------------------------------------------------------------
# 柱子和水晶是按高度生成的网格，挂成内部子节点（没有 owner），所以不会被存进 .tscn，
# 场景树面板里也看不到；同一高度的网格在所有实例之间共用。

func _ensure_anchor_parts() -> void:
	if not _anchor_parts.is_empty():
		return
	for anchor in [_left_anchor, _right_anchor]:
		for part_name in ["Pillar", "Crystal"]:
			var part := MeshInstance3D.new()
			part.name = part_name
			part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			anchor.add_child(part, false, Node.INTERNAL_MODE_BACK)
			_anchor_parts.append(part)


func _build_anchors() -> void:
	_anchor_height = barrier_height
	var key := snappedf(barrier_height, 0.01)
	if not _anchor_mesh_cache.has(key):
		_anchor_mesh_cache[key] = [_build_stone_mesh(barrier_height), _build_crystal_mesh(barrier_height)]
	if _stone_material == null:
		_stone_material = StandardMaterial3D.new()
		_stone_material.vertex_color_use_as_albedo = true
		_stone_material.roughness = 0.92
	var meshes: Array = _anchor_mesh_cache[key]
	for i in _anchor_parts.size():
		var is_crystal := i % 2 == 1
		_anchor_parts[i].mesh = meshes[1] if is_crystal else meshes[0]
		_anchor_parts[i].material_override = crystal_material if is_crystal else _stone_material


static func _build_stone_mesh(h: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# -1 = 不做平滑，每个面一个法线，保持低模的棱角。
	st.set_smooth_group(-1)
	var shaft_top := h * 0.86
	_add_frustum(st, 0.0, 0.07, 0.135, 0.125, STONE_BASE)
	_add_frustum(st, 0.07, 0.12, 0.10, 0.095, STONE_STEP)
	_add_frustum(st, 0.12, shaft_top, 0.075, 0.058, STONE_SHAFT)
	_add_frustum(st, shaft_top, shaft_top + 0.055, 0.088, 0.08, STONE_CAP)
	st.generate_normals()
	return st.commit()


# 水晶悬在柱顶上方（六棱双锥），柱身四面各一道发光细槽。
static func _build_crystal_mesh(h: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	var shaft_bottom := 0.12
	var shaft_top := h * 0.86
	var cy := shaft_top + 0.175
	var tip := Vector3(0.0, cy + 0.17, 0.0)
	var foot := Vector3(0.0, cy - 0.09, 0.0)
	var ring: Array[Vector3] = []
	for k in 6:
		var a := float(k) * TAU / 6.0
		ring.append(Vector3(cos(a) * 0.062, cy, sin(a) * 0.062))
	for k in 6:
		var n := (k + 1) % 6
		var shade := 0.95 if k % 2 == 0 else 0.62
		st.set_color(Color(shade, 0.0, 0.0, 1.0))
		for p in [tip, ring[k], ring[n]]:
			st.add_vertex(p)
		st.set_color(Color(shade * 0.55, 0.0, 0.0, 1.0))
		for p in [foot, ring[n], ring[k]]:
			st.add_vertex(p)
	var y0 := lerpf(shaft_bottom, shaft_top, 0.22)
	var y1 := lerpf(shaft_bottom, shaft_top, 0.78)
	var d0 := lerpf(0.075, 0.058, 0.22) + 0.003
	var d1 := lerpf(0.075, 0.058, 0.78) + 0.003
	st.set_color(Color(1.0, 0.0, 0.0, 0.0))
	for normal in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		var right: Vector3 = (-normal).cross(Vector3.UP) * 0.011
		var bl: Vector3 = normal * d0 - right + Vector3(0.0, y0, 0.0)
		var br: Vector3 = normal * d0 + right + Vector3(0.0, y0, 0.0)
		var tl: Vector3 = normal * d1 - right + Vector3(0.0, y1, 0.0)
		var tr: Vector3 = normal * d1 + right + Vector3(0.0, y1, 0.0)
		for p in [tl, tr, br, tl, br, bl]:
			st.add_vertex(p)
	st.generate_normals()
	return st.commit()


# 八角（切角方形）台体：底面半宽 hb、顶面半宽 ht，侧面 + 顶面。
static func _add_frustum(st: SurfaceTool, y0: float, y1: float, hb: float, ht: float, col: Color) -> void:
	var bottom := _octagon(hb, y0)
	var top := _octagon(ht, y1)
	var top_center := Vector3(0.0, y1, 0.0)
	st.set_color(col)
	for i in 8:
		var j := (i + 1) % 8
		for p in [bottom[i], bottom[j], top[j], bottom[i], top[j], top[i], top_center, top[i], top[j]]:
			st.add_vertex(p)


static func _octagon(half: float, y: float) -> Array[Vector3]:
	var b := half * 0.32
	return [
		Vector3(-half + b, y, -half), Vector3(half - b, y, -half),
		Vector3(half, y, -half + b), Vector3(half, y, half - b),
		Vector3(half - b, y, half), Vector3(-half + b, y, half),
		Vector3(-half, y, half - b), Vector3(-half, y, -half + b),
	]
