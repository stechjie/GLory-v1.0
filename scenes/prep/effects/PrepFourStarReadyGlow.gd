extends Node3D

# 「这枚三星现在就能升 4★」的提示：脚下一片金色光晕 + 一圈从脚下**往上照过头顶**的光幕，
# 慢慢呼吸；再有稀疏的金色光点顺着光幕往上飘。
#
# ## 这一版替换了什么（Leno 10.18）
#
# 之前这枚棋子身上叠着两层：旧的 FourStarAura3D（state 1）撒了一身金色四角星 + 一圈
# 金色描边 —— Leno 的评价是「全是金色的，很难看」；再加上一版脚下旋转的细线金环，
# 被那一身星点淹得几乎看不见。现在两层都拿掉，只留「从地上往上照」的光：
#   · 棋子本身**不染色**（光幕只画背面），还是原来的样子；
#   · 金色只在脚下和身后，方向是往上的。
#
# ## 和已经升好的 4★ 怎么分
#
# 已升 = FourStarAuraV3：**属性色**（蓝 / 橙 / 红）地环 + 光柱 + 属性粒子。
# 可升 = 这里：**金色**、往上照、呼吸。看颜色就能分开。
#
# ## 单位
#
# 挂在 actor 下面，尺度由 PrepBoardModels._prep_effect_scale(actor) 折算：这里的数按
# 「一格 = 0.6、棋子约 0.32 高」写，和升星迸发、旧版旋转环是同一套口径。

const CURTAIN_SHADER := preload("res://shaders/prep_four_star_ready_curtain.gdshader")
const StarBurst := preload("res://scenes/prep/effects/PrepStarUpgradeBurst.gd")

const GLOW_COLOR := Color(1.0, 0.80, 0.32)
# 地面光晕：半径略大于格子站位圈（0.20），中心亮、往外淡到 0。
const GROUND_RADIUS := 0.24
const GROUND_Y_LIFT := 0.013
const GROUND_TEX_SIZE := 128
# 光幕：围住棋子（棋子半径约 0.07），**超过头顶**（Leno 定的：照过头顶，不是半身）。
const CURTAIN_RADIUS := 0.13
const CURTAIN_HEIGHT := 0.56   # 约 1.75 个身高
# 呼吸：约 2.6 秒一次，最暗保留六成 —— 提醒「这里能升」，但不闪。
const BREATH_SEC := 2.6
const BREATH_FLOOR := 0.6
const GROUND_ALPHA := 0.85
const CURTAIN_ALPHA := 0.9
# 光点：稀疏地顺着光幕往上飘，强化「往上照」的方向。
const MOTE_INTERVAL_SEC := 1.4
const MOTE_LIFE_SEC := 1.3
const MOTE_SIZE := 0.05
const MOTE_RISE := 0.62

static var _ground_texture: ImageTexture

var _phase := 0.0
var _ground_mat: StandardMaterial3D
var _curtain_mat: ShaderMaterial
var _since_mote := 0.0
var _motes: Array[Dictionary] = []


func _ready() -> void:
	var ground := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * GROUND_RADIUS * 2.0
	ground.mesh = quad
	ground.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	ground.position = Vector3(0.0, GROUND_Y_LIFT, 0.0)
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ground_mat = StandardMaterial3D.new()
	_ground_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ground_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ground_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_ground_mat.albedo_texture = _ground_tex()
	_ground_mat.albedo_color = GLOW_COLOR
	_ground_mat.disable_receive_shadows = true
	ground.material_override = _ground_mat
	add_child(ground)

	var curtain := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	# 上口略收：完全等粗读起来像管子，收一点才像光往上散开后变淡。
	cyl.top_radius = CURTAIN_RADIUS * 0.85
	cyl.bottom_radius = CURTAIN_RADIUS
	cyl.height = CURTAIN_HEIGHT
	cyl.radial_segments = 28
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	curtain.mesh = cyl
	curtain.position = Vector3(0.0, GROUND_Y_LIFT + CURTAIN_HEIGHT * 0.5, 0.0)
	curtain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_curtain_mat = ShaderMaterial.new()
	_curtain_mat.shader = CURTAIN_SHADER
	_curtain_mat.set_shader_parameter("glow_color", GLOW_COLOR)
	_curtain_mat.set_shader_parameter("height", CURTAIN_HEIGHT)
	curtain.material_override = _curtain_mat
	add_child(curtain)
	_apply_breath()


# 中心 1、边缘 0 的径向渐变（平方衰减，读成一片光，不是一个圆盘）。
static func _ground_tex() -> ImageTexture:
	if _ground_texture != null:
		return _ground_texture
	var image := Image.create(GROUND_TEX_SIZE, GROUND_TEX_SIZE, false, Image.FORMAT_RGBA8)
	var half := float(GROUND_TEX_SIZE) * 0.5
	for y in GROUND_TEX_SIZE:
		for x in GROUND_TEX_SIZE:
			var r := Vector2(float(x) + 0.5 - half, float(y) + 0.5 - half).length() / half
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, pow(clampf(1.0 - r, 0.0, 1.0), 1.8)))
	_ground_texture = ImageTexture.create_from_image(image)
	return _ground_texture


func _process(delta: float) -> void:
	if not visible:
		return
	_phase += delta * TAU / BREATH_SEC
	if _phase > TAU:
		_phase -= TAU
	_apply_breath()
	_since_mote += delta
	if _since_mote >= MOTE_INTERVAL_SEC:
		_since_mote -= MOTE_INTERVAL_SEC
		_spawn_mote()
	_advance_motes(delta)


func _breath() -> float:
	return BREATH_FLOOR + (1.0 - BREATH_FLOOR) * (0.5 + 0.5 * sin(_phase))


func _apply_breath() -> void:
	var b := _breath()
	if _ground_mat != null:
		var c := GLOW_COLOR
		c.a = GROUND_ALPHA * b
		_ground_mat.albedo_color = c
	if _curtain_mat != null:
		_curtain_mat.set_shader_parameter("alpha", CURTAIN_ALPHA * b)


func _spawn_mote() -> void:
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * MOTE_SIZE
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_texture = StarBurst._star_tex()
	mat.albedo_color = GLOW_COLOR
	mat.disable_receive_shadows = true
	node.material_override = mat
	# 起点贴着光幕：光点是被这道光「带上去」的。
	var angle := randf() * TAU
	node.position = Vector3(cos(angle) * CURTAIN_RADIUS, GROUND_Y_LIFT, sin(angle) * CURTAIN_RADIUS)
	add_child(node)
	_motes.append({"node": node, "t": 0.0, "angle": angle})


func _advance_motes(delta: float) -> void:
	var alive: Array[Dictionary] = []
	for entry in _motes:
		var node: MeshInstance3D = entry["node"]
		if node == null or not is_instance_valid(node):
			continue
		var t := float(entry["t"]) + delta / MOTE_LIFE_SEC
		if t >= 1.0:
			node.queue_free()
			continue
		entry["t"] = t
		var climb := 1.0 - pow(1.0 - t, 1.6)
		var r := CURTAIN_RADIUS * lerpf(1.0, 0.85, t)
		node.position = Vector3(cos(float(entry["angle"])) * r, GROUND_Y_LIFT + MOTE_RISE * climb,
			sin(float(entry["angle"])) * r)
		var mat := node.material_override as StandardMaterial3D
		var color: Color = mat.albedo_color
		color.a = smoothstep(0.0, 0.15, t) * (1.0 - smoothstep(0.55, 1.0, t))
		mat.albedo_color = color
		alive.append(entry)
	_motes = alive
