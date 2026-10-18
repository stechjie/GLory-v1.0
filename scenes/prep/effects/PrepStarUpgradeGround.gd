extends Node3D

# 升星（1→2★ / 2→3★）的地面效果：一圈外扩的软边光环 + 一批向上的光尘。
#
# ## 为什么不是 VFXShockwave
#
# Leno 10.18：「不要用现在的 VFXShockwave，你要设计过」。两条实打实的理由：
#   ① **尺度对不上**。VFXShockwave 是按战斗场画的，那边名义身高 0.98
#      （BattleRenderer.NOMINAL_UNIT_HEIGHT）；备战棋子只有 0.32 高、格子站位圈半径
#      0.20（见 PrepBoardModels 里 FOUR_STAR_AURA.fit_to_actor(aura, actor, 0.32, 0.20)），
#      差三倍。原样搬过来一圈能盖掉相邻两格。
#   ② **语义反了**。硬边 + 匀速外扩 = 冲击 =「这里被打了一下」；升星是「获得」。
#
# ## 这一版的形态（Leno 10.18 定稿）
#
# 外扩，但靠三件事躲开冲击感：**软边**（shader 里 smoothstep 的平方衰减）、
# **边扩边淡**、**ease-out**（起步快、收尾慢，不是匀速）。
#
# 环最亮的那一帧**卡在 PEAK_RADIUS = 0.20**，也就是格子站位圈上 —— 2★ / 3★ 的峰值、
# 4★ 常驻的 FourStarAuraV2、以及「可升 4★」的提示环，四档落在同一个半径上，
# 玩家看到的是「同一个圈越来越强」，而不是四种互不相干的特效。
#
# 3★ 比 2★ 重在**双环**（第二圈延迟 0.12s 跟上），不是靠在环上加小亮点 —— 半径 0.20
# 在手机屏上整圈周长才百来像素，小点只会读成锯齿。
#
# 备战阶段**不做顿帧**：Engine.time_scale 会把备战倒计时一起拖慢。

const RING_SHADER := preload("res://shaders/prep_star_upgrade_ring.gdshader")

# quad 世界边长固定 1.0 —— shader 里 UV 的 0..0.5 就等于世界的 0..0.5，
# 半径参数可以当世界半径直接读，不用再乘来乘去。
const QUAD_SIZE := 1.0
# 抬离地面：站位图在 0.005（PREP_CELL_MARK_Y_LIFT），环要压在它之上。
const Y_LIFT := 0.012
# 峰值半径 = 格子站位圈。四档特效共用这一个数，别各写各的。
const PEAK_RADIUS := 0.20
# 峰值亮度的「宽容带」：半径离 PEAK_RADIUS 多远之内还算在高光里。
const PEAK_SIGMA := 0.045

# 两档的全部参数。改手感就改这张表，别散到函数里。
const PRESETS := {
	2: {
		"color": Color(0.72, 0.86, 1.0),      # 银蓝
		"r_from": 0.11, "r_to": 0.24,
		"duration": 0.35,
		"second_ring_delay": -1.0,            # < 0 = 不要第二圈
		"dust_count": 8, "dust_rise": 0.18, "dust_duration": 0.5,
		"base_alpha": 0.70,
	},
	3: {
		"color": Color(1.0, 0.86, 0.42),      # 金
		"r_from": 0.12, "r_to": 0.28,
		"duration": 0.45,
		"second_ring_delay": 0.12,
		"dust_count": 14, "dust_rise": 0.26, "dust_duration": 0.7,
		"base_alpha": 0.85,
	},
}

# 光尘：贴地起、向上飘、到顶淡没。用一批固定的小面片而不是 GPUParticles3D ——
# 粒子系统的推进跟渲染帧绑死，没法 seek 到任意时刻，截帧预览和门禁都量不了。
const DUST_SIZE := 0.018
const DUST_RING_RADIUS := 0.13
# 光尘贴图的边长。纯色面片在屏幕上就是一个**硬边方块**（第一轮预览里 14 粒金方块
# 绕着棋子转了一圈，像像素马赛克），必须给一张中心亮、边缘到 0 的径向渐变。
const DUST_TEX_SIZE := 48

var _star := 0
var _elapsed := 0.0
var _playing := false
var _rings: Array[MeshInstance3D] = []
var _dust: Array[MeshInstance3D] = []
var _dust_seeds: Array[float] = []
var _dust_texture: ImageTexture


func play(star: int) -> void:
	_star = star if PRESETS.has(star) else 3
	_elapsed = 0.0
	_playing = true
	_rebuild()
	_apply()
	visible = true


# 跳到播放中的任意时刻。截帧预览（tools/star_upgrade_preview）和门禁靠它取样 ——
# 等真实帧率去推进的话，抓出来的图每次都不一样，也就没法拿来挑方案。
func seek(t: float) -> void:
	if _rings.is_empty():
		_rebuild()
	_elapsed = maxf(0.0, t)
	_apply()


func total_duration() -> float:
	var preset: Dictionary = PRESETS[_star if PRESETS.has(_star) else 3]
	var ring_end := float(preset["duration"])
	var second: float = preset["second_ring_delay"]
	if second > 0.0:
		ring_end += second
	return maxf(ring_end, float(preset["dust_duration"]))


func _process(delta: float) -> void:
	if not _playing:
		return
	_elapsed += delta
	_apply()
	if _elapsed >= total_duration():
		_playing = false
		queue_free()


func _rebuild() -> void:
	for node in _rings + _dust:
		if is_instance_valid(node):
			node.queue_free()
	_rings.clear()
	_dust.clear()
	_dust_seeds.clear()
	var preset: Dictionary = PRESETS[_star if PRESETS.has(_star) else 3]
	var ring_count := 2 if float(preset["second_ring_delay"]) > 0.0 else 1
	for i in ring_count:
		_rings.append(_make_ring(preset["color"]))
	var dust_count := int(preset["dust_count"])
	# 种子固定按序号推，不用 randf() —— 同一档每次播出来都一样，截图才可比。
	for i in dust_count:
		var around := TAU * float(i) / float(dust_count)
		_dust_seeds.append(around)
		_dust.append(_make_dust(preset["color"], around))


func _make_ring(color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * QUAD_SIZE
	node.mesh = quad
	# QuadMesh 默认立着（面向 +Z），转 -90° 让它平躺在棋盘上。
	node.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	node.position = Vector3(0.0, Y_LIFT, 0.0)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = RING_SHADER
	mat.set_shader_parameter("ring_color", color)
	node.material_override = mat
	add_child(node)
	return node


# 一张中心 1、边缘 0 的径向渐变，整段只生成一次。没有它，光尘就是硬边方块。
func _dust_tex() -> ImageTexture:
	if _dust_texture != null:
		return _dust_texture
	var image := Image.create(DUST_TEX_SIZE, DUST_TEX_SIZE, false, Image.FORMAT_RGBA8)
	var half := float(DUST_TEX_SIZE) * 0.5
	for y in DUST_TEX_SIZE:
		for x in DUST_TEX_SIZE:
			var d := Vector2(float(x) - half + 0.5, float(y) - half + 0.5).length() / half
			# 平方衰减：线性的边缘还是看得出一个圆盘，平方才读成「一点光」。
			var a := pow(clampf(1.0 - d, 0.0, 1.0), 2.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	_dust_texture = ImageTexture.create_from_image(image)
	return _dust_texture


func _make_dust(color: Color, around: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * DUST_SIZE
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	# 公告板：俯视相机下，不转向相机的小面片会被压成一条线。
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = color
	mat.albedo_texture = _dust_tex()
	mat.disable_receive_shadows = true
	node.material_override = mat
	node.position = Vector3(cos(around) * DUST_RING_RADIUS, Y_LIFT, sin(around) * DUST_RING_RADIUS)
	add_child(node)
	return node


func _apply() -> void:
	var preset: Dictionary = PRESETS[_star if PRESETS.has(_star) else 3]
	var duration := float(preset["duration"])
	var r_from := float(preset["r_from"])
	var r_to := float(preset["r_to"])
	var base_alpha := float(preset["base_alpha"])
	for i in _rings.size():
		# 第二圈整体延后 second_ring_delay 起跳，亮度压到七成 —— 它是「重量」，不是主角。
		var delay := 0.0 if i == 0 else float(preset["second_ring_delay"])
		var gain := 1.0 if i == 0 else 0.7
		_apply_ring(_rings[i], (_elapsed - delay) / duration, r_from, r_to, base_alpha * gain)
	var dust_duration := float(preset["dust_duration"])
	var rise := float(preset["dust_rise"])
	for i in _dust.size():
		# 光尘错峰起跳，整批铺开占前三成时长；一起冒会糊成一团。
		var offset := 0.3 * float(i) / float(maxi(1, _dust.size()))
		_apply_dust(_dust[i], _dust_seeds[i], (_elapsed / dust_duration) - offset, rise)


func _apply_ring(node: MeshInstance3D, t: float, r_from: float, r_to: float, base_alpha: float) -> void:
	if not is_instance_valid(node):
		return
	if t < 0.0 or t > 1.0:
		node.visible = false
		return
	node.visible = true
	# ease-out：起步快、收尾慢。匀速正是 shockwave 那种「砸下去」的感觉。
	var grow := 1.0 - pow(1.0 - t, 2.0)
	var radius := lerpf(r_from, r_to, grow)
	# 边扩边淡：起头 0.12 内淡入（不要凭空冒出来），0.35 之后一路淡到没。
	var fade := smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(0.35, 1.0, t))
	# 高光：半径扫过 PEAK_RADIUS（格子站位圈）那一瞬最亮。
	var highlight := exp(-pow((radius - PEAK_RADIUS) / PEAK_SIGMA, 2.0))
	var mat := node.material_override as ShaderMaterial
	mat.set_shader_parameter("radius", radius)
	# 线宽随外扩略增并变软 —— 扩开了还保持细线会显脏。
	# ⚠️ 这个数是 UV 单位（quad 边长 1.0），0.075 在半径 0.20 上差不多跟半径一样粗，
	#    第一轮预览里就糊成了一个甜甜圈。真正读起来像「一道光」的量级是 0.012~0.03。
	mat.set_shader_parameter("thickness", lerpf(0.012, 0.028, t))
	mat.set_shader_parameter("alpha", base_alpha * fade * (0.55 + 0.45 * highlight))


func _apply_dust(node: MeshInstance3D, around: float, t: float, rise: float) -> void:
	if not is_instance_valid(node):
		return
	if t < 0.0 or t > 1.0:
		node.visible = false
		return
	node.visible = true
	var climb := 1.0 - pow(1.0 - t, 2.0)
	node.position = Vector3(cos(around) * DUST_RING_RADIUS, Y_LIFT + rise * climb,
		sin(around) * DUST_RING_RADIUS)
	var mat := node.material_override as StandardMaterial3D
	var color: Color = mat.albedo_color
	# 升到顶之前就开始淡：到顶那一刻正好没，不要「啪」地消失。
	color.a = (1.0 - smoothstep(0.45, 1.0, t)) * smoothstep(0.0, 0.1, t)
	mat.albedo_color = color
