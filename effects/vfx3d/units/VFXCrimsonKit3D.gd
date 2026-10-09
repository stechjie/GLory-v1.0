extends VFXBlockRoot
class_name VFXCrimsonKit3D

# 赤律族特效的公共底座：两张共享 shader、几块静态网格和一条按时间轴推进的轨道。
#
# 设计约束（docs/CODEX_VFX_WORKFLOW.md §4）：
#   * 全族只有两个 shader 程序（加色光层 / 半透明实体层），各层只改 uniform，
#     所以预热任意一个赤律特效就把整族的管线都编好了；
#   * 几何按「世界单位 × 单位身高」直接写，不走旧 1.7 单位体系的 vfx_size()；
#   * 每块效果 ≤ 12 个节点，碎片走 MultiMesh，数量走 VFXQualityBudget；
#   * 所有层都乘 vfx_alpha，stop_vfx() 的淡出与回收沿用 VFXBlockRoot。

const GLOW_SHADER := preload("res://effects/vfx3d/shaders/crimson_vfx_glow.gdshader")
const BODY_SHADER := preload("res://effects/vfx3d/shaders/crimson_vfx_body.gdshader")
const CATALOG := preload("res://effects/vfx3d/units/CrimsonVFXCatalog.gd")

const SHAPE_GLOW := 0
const SHAPE_STREAK := 1
const SHAPE_RING := 2
const SHAPE_FLARE := 3
const SHAPE_SEAL := 4
const SHAPE_VERTEX := 5

const STYLE_FACET := 0
const STYLE_PANEL := 1
const STYLE_CRACK := 2
const STYLE_VERTEX := 3

const UNIT_HEIGHT := 0.98
# 屏幕「上」方向在世界里的投影（相机 (0,7.4,7) 看原点；与 CAMERA_DIR 正交）。
const SCREEN_UP := Vector3(0.0, 0.687, -0.727)
const GRAVITY := 3.2

static var _quad: QuadMesh
static var _ground_quad: ArrayMesh
static var _strip: ArrayMesh
static var _crystal: ArrayMesh
static var _shard: ArrayMesh

var _clock := 0.0
var _tracks: Array[Dictionary] = []
var _end_time := 0.0
var _rng := RandomNumberGenerator.new()


# ── 生命周期 ─────────────────────────────────────────────────────────────

func begin_kit(seed_value: int = 0) -> void:
	begin()
	_ensure_meshes()
	_clock = 0.0
	_tracks.clear()
	_end_time = 0.0
	# 纯装饰随机：独立 RNG，种子来自位置/实例，绝不触碰 RngService。
	_rng.seed = seed_value if seed_value != 0 else int(get_instance_id())
	set_process(true)


# start/duration 以秒计；fn(x) 在 x∈[0,1] 每帧调用一次，结束时以 x=1 收尾一次。
func track(start: float, duration: float, fn: Callable) -> void:
	_tracks.append({"s": maxf(0.0, start), "d": maxf(duration, 0.001), "f": fn, "done": false})
	_end_time = maxf(_end_time, start + duration)


func keep_alive_until(seconds: float) -> void:
	_end_time = maxf(_end_time, seconds)


func elapsed() -> float:
	return _clock


func _process(delta: float) -> void:
	if _finished:
		return
	_clock += delta
	_advance_custom(delta)
	for entry in _tracks:
		if bool(entry["done"]) or _clock < float(entry["s"]):
			continue
		var x := clampf((_clock - float(entry["s"])) / float(entry["d"]), 0.0, 1.0)
		(entry["f"] as Callable).call(x)
		if x >= 1.0:
			entry["done"] = true
	if _clock >= _end_time + 0.02 and _custom_done():
		finish()


# 子类钩子：投射物飞行这类「时长不固定」的过程放这里。
func _advance_custom(_delta: float) -> void:
	pass


func _custom_done() -> bool:
	return true


func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)


# ── 层构造 ───────────────────────────────────────────────────────────────

func glow_material(params: Dictionary = {}) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = GLOW_SHADER
	material.render_priority = 1
	material.set_shader_parameter("edge", CATALOG.DARK)
	material.set_shader_parameter("tint", CATALOG.MAIN)
	material.set_shader_parameter("hot", CATALOG.CORE)
	material.set_shader_parameter("white_hot", CATALOG.WHITE_HOT)
	material.set_shader_parameter("opacity", 0.0)
	for key in params:
		material.set_shader_parameter(str(key), params[key])
	return material


func body_material(params: Dictionary = {}) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = BODY_SHADER
	material.render_priority = 0
	material.set_shader_parameter("dark_color", CATALOG.DARK)
	material.set_shader_parameter("main_color", CATALOG.MAIN)
	material.set_shader_parameter("core_color", CATALOG.CORE)
	material.set_shader_parameter("highlight", CATALOG.WHITE_HOT)
	material.set_shader_parameter("opacity", 0.0)
	for key in params:
		material.set_shader_parameter(str(key), params[key])
	return material


func _mesh_node(label: String, mesh: Mesh, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = mesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.visible = false
	add_child(node)
	return node


# 面向镜头的发光片。size = 世界直径。
func glow_sprite(label: String, at: Vector3, size: float, params: Dictionary = {}) -> MeshInstance3D:
	var p := {"billboard": 1.0, "shape": SHAPE_GLOW}
	p.merge(params, true)
	var node := _mesh_node(label, _quad, glow_material(p))
	node.global_position = at
	node.scale = Vector3(size, size, 1.0)
	return node


# 贴地的圆环 / 法阵 / 印记。radii = 世界 X/Z 半径（可以是椭圆）。
func ground_decal(label: String, center: Vector3, radii: Vector2, params: Dictionary = {}) -> MeshInstance3D:
	var p := {"billboard": 0.0, "shape": SHAPE_RING}
	p.merge(params, true)
	var material := glow_material(p)
	material.render_priority = -1
	var node := _mesh_node(label, _ground_quad, material)
	node.global_position = center
	node.scale = Vector3(radii.x * 2.0, 1.0, radii.y * 2.0)
	return node


# 两点之间、正对镜头的条带。每帧可用 place_streak() 重新摆放。
func streak(label: String, params: Dictionary = {}) -> MeshInstance3D:
	var p := {"billboard": 0.0, "shape": SHAPE_STREAK}
	p.merge(params, true)
	return _mesh_node(label, _strip, glow_material(p))


func place_streak(node: Node3D, from: Vector3, to: Vector3, width: float) -> void:
	var along := to - from
	if along.length_squared() < 0.000001:
		along = Vector3.RIGHT * 0.001
	var side := along.cross(CAMERA_DIR)
	if side.length_squared() < 0.000001:
		side = Vector3.UP
	side = side.normalized() * width
	var normal := along.normalized().cross(side.normalized())
	node.global_transform = Transform3D(Basis(along, side, normal), from)


func solid(label: String, mesh: Mesh, params: Dictionary = {}) -> MeshInstance3D:
	return _mesh_node(label, mesh, body_material(params))


func shard_cloud(label: String, count: int, params: Dictionary = {}) -> MultiMeshInstance3D:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.mesh = _shard
	multi.instance_count = maxi(1, count)
	var node := MultiMeshInstance3D.new()
	node.name = label
	node.multimesh = multi
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var p := {"style": STYLE_FACET}
	p.merge(params, true)
	node.material_override = body_material(p)
	node.visible = false
	add_child(node)
	return node


static func set_param(node: GeometryInstance3D, key: String, value: Variant) -> void:
	if node == null or not is_instance_valid(node):
		return
	var material := node.material_override as ShaderMaterial
	if material != null:
		material.set_shader_parameter(key, value)


func show_with(node: GeometryInstance3D, opacity: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var value := clampf(opacity, 0.0, 1.0) * vfx_alpha
	node.visible = value > 0.002
	set_param(node, "opacity", value)


# 把沿 +Y 的网格（crystal_mesh 等）摆成沿 dir、长 length、粗 radius，宽面朝镜头。
func orient_along(node: Node3D, at: Vector3, dir: Vector3, length: float, radius: float, roll: float = 0.0) -> void:
	var up := dir
	var side := up.cross(CAMERA_DIR)
	if side.length_squared() < 0.000001:
		side = Vector3.RIGHT
	side = side.normalized()
	var fwd := side.cross(up).normalized()
	var basis := Basis(side, up, fwd)
	if roll != 0.0:
		basis = basis * Basis(Vector3.UP, roll)
	node.global_transform = Transform3D(basis * Basis.from_scale(Vector3(radius, length, radius)), at)


# ── 常用动画 ─────────────────────────────────────────────────────────────

# 起 → 峰 → 收 的标准包络。rise/fall 为 0..1 的比例。
static func envelope(x: float, rise: float = 0.15, fall: float = 0.45) -> float:
	if x < rise:
		return smoothstep(0.0, rise, x)
	if x > 1.0 - fall:
		return 1.0 - smoothstep(1.0 - fall, 1.0, x)
	return 1.0


static func ease_out(x: float, power: float = 3.0) -> float:
	return 1.0 - pow(1.0 - clampf(x, 0.0, 1.0), power)


# 世界方向 -> 屏幕角（弧度，0 = 屏幕右，逆时针为正）。
static func screen_angle(from: Vector3, to: Vector3) -> float:
	var d := to - from
	return atan2(d.dot(SCREEN_UP), d.x)


static func flat_dir(from: Vector3, to: Vector3) -> Vector3:
	var d := Vector3(to.x - from.x, 0.0, to.z - from.z)
	if d.length_squared() < 0.000001:
		return Vector3.RIGHT
	return d.normalized()


static func toward_camera(at: Vector3, distance: float) -> Vector3:
	return at + CAMERA_DIR * distance


static func node_position(ref: WeakRef, fallback: Vector3) -> Vector3:
	if ref == null:
		return fallback
	var node: Variant = ref.get_ref()
	if is_instance_valid(node) and node is Node3D and (node as Node3D).is_inside_tree():
		return (node as Node3D).global_position
	return fallback


static func weak_node(value: Variant) -> WeakRef:
	if is_instance_valid(value) and value is Node3D:
		return weakref(value)
	return null


static func height_of(context: Dictionary, key: String) -> float:
	var h := float(context.get(key, 0.0))
	return h if h > 0.2 else UNIT_HEIGHT


# 一团碎片的初速度/角速度，按装饰 RNG 生成。spread 为水平扩散半径。
func scatter(count: int, center: Vector3, toward: Vector3, speed: float, lift: float, spread: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in count:
		var angle := _rng.randf() * TAU
		var radial := Vector3(cos(angle), 0.0, sin(angle)) * spread
		var velocity := (toward * speed * _rng.randf_range(0.55, 1.0)) + radial * speed + Vector3.UP * lift * _rng.randf_range(0.6, 1.2)
		out.append({
			"p": center,
			"v": velocity,
			"axis": Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)).normalized(),
			"w": _rng.randf_range(6.0, 14.0),
			"s": _rng.randf_range(0.7, 1.25),
		})
	return out


func drive_shards(node: MultiMeshInstance3D, shards: Array[Dictionary], x: float, life: float, size: float, gravity_scale: float = 1.0) -> void:
	if node == null or not is_instance_valid(node):
		return
	var t := x * life
	var fade := 1.0 - smoothstep(0.55, 1.0, x)
	for i in shards.size():
		var s: Dictionary = shards[i]
		var v: Vector3 = s["v"]
		var p: Vector3 = (s["p"] as Vector3) + v * t + Vector3.DOWN * GRAVITY * gravity_scale * t * t * 0.5
		var basis := Basis((s["axis"] as Vector3), float(s["w"]) * t).scaled(Vector3.ONE * size * float(s["s"]) * (1.0 - x * 0.35))
		node.multimesh.set_instance_transform(i, Transform3D(basis, node.to_local(p)))
		node.multimesh.set_instance_color(i, Color(0.55 + 0.45 * (1.0 - x), 1.0, 1.0, fade))
	show_with(node, 1.0)


# ── 静态网格 ─────────────────────────────────────────────────────────────

static func _ensure_meshes() -> void:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2.ONE
	if _ground_quad == null:
		_ground_quad = _make_ground_quad()
	if _strip == null:
		_strip = _make_strip()
	if _crystal == null:
		_crystal = make_bipyramid(6, 1.0, 1.0, 0.42)
	if _shard == null:
		_shard = make_bipyramid(3, 1.0, 0.45, 0.5)


static func crystal_mesh() -> ArrayMesh:
	_ensure_meshes()
	return _crystal


static func _make_ground_quad() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]
	for c: Vector2 in corners:
		st.set_normal(Vector3.UP)
		st.set_uv(c)
		st.add_vertex(Vector3(c.x - 0.5, 0.0, c.y - 0.5))
	return st.commit()


static func _make_strip() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]
	for c: Vector2 in corners:
		st.set_normal(Vector3.BACK)
		st.set_uv(c)
		st.add_vertex(Vector3(c.x, c.y - 0.5, 0.0))
	return st.commit()


# 沿 +Y 的双锥：sides 条棱，长 length，半径 radius；mid 为最粗处所在比例。
# 顶点色 r = 「核心度」：棱线 1、两端 0，给实体 shader 的三值结构用。
static func make_bipyramid(sides: int, length: float, radius: float, mid: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top := Vector3(0.0, length * (1.0 - mid), 0.0)
	var bottom := Vector3(0.0, -length * mid, 0.0)
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var p0 := Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		for tri in [[top, p0, p1], [bottom, p1, p0]]:
			var n := ((tri[1] as Vector3) - (tri[0] as Vector3)).cross((tri[2] as Vector3) - (tri[0] as Vector3)).normalized()
			for k in 3:
				var v: Vector3 = tri[k]
				st.set_normal(n)
				st.set_color(Color(0.25 if k == 0 else 0.85, 1.0, 1.0, 1.0))
				st.set_uv(Vector2(float(k) * 0.5, 0.0))
				st.add_vertex(v)
	return st.commit()
