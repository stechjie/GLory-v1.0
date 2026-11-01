extends MultiMeshInstance3D

# 摆放界面满场飘落的樱花瓣（皮肤 ambient = "petal" 时代替萤火虫，见 PrepSkin.ambient）。
#
# 不用 CPUParticles3D：它没有左右摆和「翻面」，落下来像一串直线下坠的纸片。
# 这里每片自己算运动，一个 MultiMesh 一次画完：
#   - 慢慢往下落，带一点往右的风；
#   - 左右正弦摆（每片频率、相位不同）；
#   - 平面内自转，宽度按 |cos| 缩放模拟翻面；
#   - 出生淡入，快落到地面淡出，然后回到顶上重新落。
# 面朝相机自己算（_process 里取相机 basis），不靠材质 billboard，翻面的缩放才对。
#
# 定位：调用方给棋盘地面的中心、半宽、半深与地面高度（PrepBoardModels 用棋盘常量填）。

const PetalTexture := preload("res://scenes/prep/effects/PrepPetalTexture.gd")

# 「淡一点」：棋子名字和星级在棋盘中间，落花不能抢。
const COUNT := 30
const PETAL_SIZE := Vector2(0.13, 0.17)     # 截图实测 0.085 在屏幕上只有 8px、看不见；这个约 16px
const FALL_SPEED := Vector2(0.09, 0.15)      # 每秒下落
const WIND := Vector2(0.03, 0.08)            # 每秒往 +X 漂
const SWAY_AMP := Vector2(0.05, 0.11)
const SWAY_FREQ := Vector2(0.9, 1.6)
const SPIN_SPEED := Vector2(0.5, 1.4)        # 弧度/秒，正负随机
const FLIP_SPEED := Vector2(1.2, 2.6)
const TOP_HEIGHT := 1.35                     # 离地多高出生
const FADE_IN_SEC := 0.8
const FADE_OUT_HEIGHT := 0.18                # 离地这么高开始淡出
const MAX_ALPHA := 0.92

var _center := Vector3.ZERO
var _half_extents := Vector2(3.6, 2.0)
var _ground_y := 0.0
var _rng := RandomNumberGenerator.new()
var _petals: Array[Dictionary] = []


func setup(center: Vector3, half_extents: Vector2, ground_y: float) -> void:
	_center = center
	_half_extents = half_extents
	_ground_y = ground_y
	_rng.randomize()
	name = "PrepPetalFall"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE   # 真实大小放在每片的 transform 里
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = PetalTexture.get_texture()
	mat.vertex_color_use_as_albedo = true
	mat.render_priority = 8
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = COUNT
	multimesh = mm
	# 花瓣每帧都在动，给一个固定的大盒子，免得被视锥剔掉
	custom_aabb = AABB(
		Vector3(_center.x - _half_extents.x * 1.5, _ground_y - 0.2, _center.z - _half_extents.y - 0.5) - position,
		Vector3(_half_extents.x * 3.0, TOP_HEIGHT + 0.6, _half_extents.y * 2.0 + 1.0))
	_petals.clear()
	for i in COUNT:
		var p := {}
		_respawn(p)
		# 开局就是「已经飘了一会儿」：高度均匀铺开，不要一进来全挤在顶上
		p.y = _ground_y + _rng.randf_range(FADE_OUT_HEIGHT, TOP_HEIGHT)
		p.age = FADE_IN_SEC
		_petals.append(p)
	set_active(visible)


# 皮肤换掉时由 PrepUI.reapply_prep_skin 调：不显示就不跑 _process。
func set_active(on: bool) -> void:
	visible = on
	set_process(on)


func _respawn(p: Dictionary) -> void:
	# 风往 +X 吹，出生点整体偏左一点，免得左半边越飘越空
	p.x = _center.x + _rng.randf_range(-_half_extents.x * 1.15, _half_extents.x * 0.9)
	p.z = _center.z + _rng.randf_range(-_half_extents.y, _half_extents.y)
	p.y = _ground_y + TOP_HEIGHT + _rng.randf_range(0.0, 0.25)
	p.age = 0.0
	p.fall = _rng.randf_range(FALL_SPEED.x, FALL_SPEED.y)
	p.wind = _rng.randf_range(WIND.x, WIND.y)
	p.sway_amp = _rng.randf_range(SWAY_AMP.x, SWAY_AMP.y)
	p.sway_freq = _rng.randf_range(SWAY_FREQ.x, SWAY_FREQ.y)
	p.phase = _rng.randf_range(0.0, TAU)
	p.angle = _rng.randf_range(0.0, TAU)
	p.spin = _rng.randf_range(SPIN_SPEED.x, SPIN_SPEED.y) * (1.0 if _rng.randf() < 0.5 else -1.0)
	p.flip_speed = _rng.randf_range(FLIP_SPEED.x, FLIP_SPEED.y)
	p.size = _rng.randf_range(0.8, 1.15)
	# 每片一点色差：浅粉到粉。太白在亮黄绿草地上会被吃掉
	p.tint = Color(1.0, 0.95, 0.97).lerp(Color(1.0, 0.80, 0.88), _rng.randf())


func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or multimesh == null:
		return
	var cam_basis := cam.global_basis.orthonormalized()
	# 转到本节点的局部空间（本节点一般不旋转，这样稳妥）
	var face := global_basis.orthonormalized().inverse() * cam_basis
	for i in _petals.size():
		var p: Dictionary = _petals[i]
		p.age += delta
		var swing: float = p.age * p.sway_freq + p.phase
		# 摆到两头时下落变慢、摆过中间时快，像真的花瓣在空气里「荡」
		p.y -= p.fall * delta * (0.55 + 0.65 * absf(cos(swing)))
		p.x += p.wind * delta
		p.angle += p.spin * delta
		if p.y <= _ground_y or p.x > _center.x + _half_extents.x * 1.25:
			_respawn(p)
			swing = p.age * p.sway_freq + p.phase
		var sway: float = sin(swing) * p.sway_amp
		var flip: float = absf(cos(p.age * p.flip_speed + p.phase))
		var width: float = lerpf(0.25, 1.0, flip)
		var alpha := MAX_ALPHA
		if p.age < FADE_IN_SEC:
			alpha *= p.age / FADE_IN_SEC
		var height: float = p.y - _ground_y
		if height < FADE_OUT_HEIGHT:
			alpha *= clampf(height / FADE_OUT_HEIGHT, 0.0, 1.0)
		var scale := Vector3(PETAL_SIZE.x * width * p.size, PETAL_SIZE.y * p.size, 1.0)
		var b := face * Basis(Vector3.BACK, p.angle) * Basis.from_scale(scale)
		var pos := Vector3(p.x + sway, p.y, p.z) - position
		multimesh.set_instance_transform(i, Transform3D(b, pos))
		var tint: Color = p.tint
		# 翻到侧面时稍暗一点，看得出是在翻
		var shade := lerpf(0.82, 1.0, flip)
		multimesh.set_instance_color(i, Color(tint.r * shade, tint.g * shade, tint.b * shade, alpha))
