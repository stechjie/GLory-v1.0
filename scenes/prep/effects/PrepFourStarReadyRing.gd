extends Node3D

# 「这枚三星现在就能升 4★」的提示：脚下一圈**缓慢旋转**的金环 + 周期性上升的金色光点。
#
# ## 为什么不是把现有的全身金光调亮
#
# 现在的提示是 FourStarAura3D（state == 1）给模型罩一层金色 rim。问题在于：备战棋子
# 只有 0.32 高、相机又是 45° 俯视，贴着轮廓的 rim 在屏幕上只有几像素宽的一道边 ——
# Leno 的原话是「不明显」。俯视角下面积最大的是**脚下**和**头顶**那两块，所以提示挪到
# 那里；rim 保留当辅助。
#
# ## 为什么一定要转
#
# 一屏 16 格、背景是亮草坪，**静止**的亮度会被背景吃掉。动起来才抓眼。而且「转 vs 不转」
# 正好拿来和**已经是 4★** 的 FourStarAuraV2（常驻厚金环、不转）区分 —— 比调颜色深浅
# 可靠得多，玩家一眼能分出「可以升」和「已经升了」。
#
# 环本身要有**角向亮度梯度**（一边亮一边暗），否则完全对称的圆环转起来跟没转一样。

const StarBurst := preload("res://scenes/prep/effects/PrepStarUpgradeBurst.gd")

# 环贴图：峰值落在 UV 半径 0.4 处，所以 quad 边长 = 2 × 世界半径 / 0.8。
const RING_TEX_SIZE := 192
const RING_UV_RADIUS := 0.40
const RING_UV_WIDTH := 0.055
# 世界半径 0.20 = 格子站位圈。与 4★ 完成态的 FourStarAuraV2（fit_to_actor 的第四参）
# 以及升星迸发的峰值半径是同一个数 —— 四档提示落在同一个圈上。
const RING_WORLD_RADIUS := 0.20
const RING_Y_LIFT := 0.014
const RING_COLOR := Color(1.0, 0.84, 0.38)
# 6 秒一圈：「安静地转」。3 秒就开始抢戏了。
const SPIN_SEC := 6.0

# 上升光点：每 0.8 秒一粒，升到约一个身高之上再淡没。单粒、不密集，不会糊。
const MOTE_INTERVAL_SEC := 0.8
const MOTE_RISE := 0.34
const MOTE_LIFE_SEC := 1.1
const MOTE_SIZE := 0.055
const MOTE_START_RADIUS := 0.12

static var _ring_texture: ImageTexture

var _ring: MeshInstance3D
var _spin := 0.0
var _since_mote := 0.0
var _motes: Array[Dictionary] = []


func _ready() -> void:
	_ring = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * (RING_WORLD_RADIUS * 2.0 / RING_UV_RADIUS * 0.5)
	_ring.mesh = quad
	# QuadMesh 默认立着（面向 +Z），转 -90° 让它平躺在棋盘上。
	_ring.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_ring.position = Vector3(0.0, RING_Y_LIFT, 0.0)
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_texture = _ring_tex()
	mat.albedo_color = RING_COLOR
	mat.disable_receive_shadows = true
	_ring.material_override = mat
	add_child(_ring)


# 中心空、峰值在 RING_UV_RADIUS 的一圈，并带**角向亮度梯度**（转起来才看得出在转）。
static func _ring_tex() -> ImageTexture:
	if _ring_texture != null:
		return _ring_texture
	var image := Image.create(RING_TEX_SIZE, RING_TEX_SIZE, false, Image.FORMAT_RGBA8)
	var half := float(RING_TEX_SIZE) * 0.5
	for y in RING_TEX_SIZE:
		for x in RING_TEX_SIZE:
			var nx := (float(x) + 0.5 - half) / half * 0.5
			var ny := (float(y) + 0.5 - half) / half * 0.5
			var r := sqrt(nx * nx + ny * ny)
			var band := 1.0 - smoothstep(0.0, RING_UV_WIDTH, absf(r - RING_UV_RADIUS))
			# 角向梯度：一侧满亮、对侧压到三成。
			var angle := atan2(ny, nx)
			var sweep := 0.30 + 0.70 * (0.5 + 0.5 * cos(angle))
			var a := clampf(band * band * sweep, 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	_ring_texture = ImageTexture.create_from_image(image)
	return _ring_texture


func _process(delta: float) -> void:
	if not visible:
		return
	_spin += delta * TAU / SPIN_SEC
	if _spin > TAU:
		_spin -= TAU
	if _ring != null and is_instance_valid(_ring):
		# 环平躺着，绕自身法线转 = 绕本地 Z 轴（已经被 -90° 摆平了）。
		_ring.rotation_degrees = Vector3(-90.0, 0.0, rad_to_deg(_spin))
	_since_mote += delta
	if _since_mote >= MOTE_INTERVAL_SEC:
		_since_mote -= MOTE_INTERVAL_SEC
		_spawn_mote()
	_advance_motes(delta)


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
	# 和升星迸发共用同一张四角星贴图：两处提示看起来才是一套东西。
	mat.albedo_texture = StarBurst._star_tex()
	mat.albedo_color = RING_COLOR
	mat.disable_receive_shadows = true
	node.material_override = mat
	var angle := randf() * TAU
	node.position = Vector3(cos(angle) * MOTE_START_RADIUS, RING_Y_LIFT, sin(angle) * MOTE_START_RADIUS)
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
		var climb := 1.0 - pow(1.0 - t, 2.0)
		node.position = Vector3(
			cos(float(entry["angle"])) * MOTE_START_RADIUS,
			RING_Y_LIFT + MOTE_RISE * climb,
			sin(float(entry["angle"])) * MOTE_START_RADIUS)
		var mat := node.material_override as StandardMaterial3D
		var color: Color = mat.albedo_color
		# 升到顶之前就开始淡，到顶那一刻正好没 —— 不要「啪」地消失。
		color.a = smoothstep(0.0, 0.15, t) * (1.0 - smoothstep(0.55, 1.0, t))
		mat.albedo_color = color
		alive.append(entry)
	_motes = alive
