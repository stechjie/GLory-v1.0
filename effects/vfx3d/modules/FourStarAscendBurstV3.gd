extends Node3D
## 4★ 升级那一瞬间的 3D 爆发。挂在 FourStarAuraV3（节点名 "FourStarAuraV2"）下面，
## 播完自己 queue_free —— 常驻光环那边仍然保持「全 GPU、零逐帧脚本」。
##
## ## 为什么要补这个
##
## V3 换掉 V2 时把升级爆发整段删了（V3 的 play_upgrade() 只剩 pass，注释写着
## 「V3 has no ascension burst by design」）。结果升 4★ 那一刻只有常驻光环**突然出现**，
## 升级本身是哑的 —— Leno 10.18 的原话是「4 星的升级弄得不是很好」。这里按 V3 的三种
## 属性风格把爆发补回来：天 = 羽毛、地 = 碎晶、人 = 雷电，颜色取 V3 自己的 _palette，
## 粒子贴图取 V3 自己的那几张程序生成图，风格天然一致，也不增加贴图内存。
##
## ## 单位
##
## 父节点（光环）已经按棋子身高缩放过了（configure → scale = world_height），所以这里
## 的数全是**棋子身高单位**：1.0 = 一个身高，footprint ≈ 脚下那个圈的半径。
## 这和升星迸发那边「要自己量格距」不同 —— 光环本来就挂在棋子身上。
##
## 只是表现：不读、不改任何战斗数值、技能或库存。

# 整段时长。全屏层那边的元素在 IMPACT_SEC 汇到棋子上，这里的爆发从 0 起播，
# 由调用方在冲击点那一刻才 play_upgrade()，所以这里不再自己等。
const DURATION := 0.62
const RING_FROM := 0.45     # × footprint
const RING_TO := 1.75       # × footprint
const RING_SEC := 0.48
const COLUMN_RISE_SEC := 0.16
const COLUMN_FADE_SEC := 0.34
const COLUMN_PEAK_HEIGHT := 1.9   # 冲到约两个身高
const BURST_AMOUNT := 26

var _age := 0.0
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _ring_color := Color.WHITE
var _column: MeshInstance3D
var _footprint := 0.82
var _z_squash := 0.86

static var _ring_texture: ImageTexture


## palette = [dark/outline, body, core]（V3._palette 的约定）。
## column_mesh / column_material 直接用 V3 缓存好的那一份，爆发柱与常驻柱同一套 shader。
func setup(palette: Array, footprint: float, z_squash: float, column_mesh: Mesh,
		column_material: Material, particle_parts: Dictionary) -> void:
	_footprint = footprint
	_z_squash = z_squash
	_ring_color = palette[2] if palette.size() > 2 else Color.WHITE
	_build_ring()
	_build_column(column_mesh, column_material)
	_build_particles(particle_parts)
	_apply()


func _process(delta: float) -> void:
	_age += delta
	_apply()
	if _age >= DURATION:
		queue_free()


# 对称的软环（不带角向梯度 —— 那是「可升 4★」旋转环要的，爆发不转）。
static func _ring_tex() -> ImageTexture:
	if _ring_texture != null:
		return _ring_texture
	var size := 128
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half := float(size) * 0.5
	for y in size:
		for x in size:
			var r := Vector2(float(x) + 0.5 - half, float(y) + 0.5 - half).length() / half
			# 峰值在 0.8，往内收得快、往外收得慢 —— 读起来是「光往外散」。
			var d := r - 0.8
			var a := exp(-d * d / (0.012 if d < 0.0 else 0.03))
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(a, 0.0, 1.0)))
	_ring_texture = ImageTexture.create_from_image(image)
	return _ring_texture


func _build_ring() -> void:
	_ring = MeshInstance3D.new()
	var quad := QuadMesh.new()
	# 贴图峰值在 UV 半径 0.8 处 ⇒ quad 边长 2 / 0.8 = 2.5 时，scale = 1 对应峰值半径 1.0。
	quad.size = Vector2.ONE * 2.5
	_ring.mesh = quad
	_ring.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_ring.position.y = 0.02
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_ring_mat.albedo_texture = _ring_tex()
	_ring_mat.albedo_color = _ring_color
	_ring_mat.disable_receive_shadows = true
	_ring.material_override = _ring_mat
	add_child(_ring)


func _build_column(mesh: Mesh, material: Material) -> void:
	if mesh == null or material == null:
		return
	_column = MeshInstance3D.new()
	_column.mesh = mesh
	_column.material_override = material
	_column.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_column)


# 一次性的属性粒子迸发。process material 是 V3 的**共享缓存**，常驻粒子也在用 ——
# 必须 duplicate 再改，否则改速度会把所有四星棋子的常驻粒子一起改掉。
func _build_particles(parts: Dictionary) -> void:
	if parts.is_empty():
		return
	var node := GPUParticles3D.new()
	node.local_coords = true
	node.one_shot = true
	node.explosiveness = 0.88
	node.amount = BURST_AMOUNT
	node.lifetime = 0.55
	node.randomness = 0.4
	node.draw_pass_1 = parts.get("mesh")
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_aabb = AABB(Vector3(-2.5, -0.2, -2.5), Vector3(5.0, 3.5, 5.0))
	var process: Material = parts.get("process")
	if process is ParticleProcessMaterial:
		var burst := (process as ParticleProcessMaterial).duplicate() as ParticleProcessMaterial
		burst.direction = Vector3(0.0, 1.0, 0.0)
		burst.spread = 70.0
		burst.initial_velocity_min = 1.6
		burst.initial_velocity_max = 2.8
		burst.gravity = Vector3(0.0, -2.2, 0.0)
		burst.damping_min = 1.5
		burst.damping_max = 2.5
		node.process_material = burst
	else:
		node.process_material = process
	add_child(node)
	node.emitting = true


func _apply() -> void:
	# 地面环：外扩 + 边扩边淡，ease-out（起步快、收尾慢）。
	if _ring != null:
		var t := clampf(_age / RING_SEC, 0.0, 1.0)
		var grow := 1.0 - pow(1.0 - t, 2.5)
		var r := lerpf(RING_FROM, RING_TO, grow) * _footprint
		_ring.scale = Vector3(r, r, r * _z_squash)
		var c := _ring_color
		c.a = (1.0 - smoothstep(0.25, 1.0, t)) * smoothstep(0.0, 0.08, t) * 1.4
		_ring_mat.albedo_color = c
		_ring.visible = t < 1.0
	# 光柱：先冲高（0.16s），再横向收窄到没（0.34s）。柱子的 shader 是共享缓存，
	# 改不了透明度，所以「淡」用收窄表达 —— 视觉上是一道光柱冲上去再收成一线。
	if _column != null:
		var fp := _footprint / 0.82
		if _age <= COLUMN_RISE_SEC:
			var u := 1.0 - pow(1.0 - _age / COLUMN_RISE_SEC, 2.0)
			_column.scale = Vector3(fp * 0.75, COLUMN_PEAK_HEIGHT / 0.95 * u, fp * 0.75 * _z_squash)
		else:
			var v := clampf((_age - COLUMN_RISE_SEC) / COLUMN_FADE_SEC, 0.0, 1.0)
			var w := (1.0 - v * v) * 0.75
			_column.scale = Vector3(fp * w, COLUMN_PEAK_HEIGHT / 0.95, fp * w * _z_squash)
			_column.visible = v < 1.0
