extends Control
class_name PrepShopRefreshBurn

const TOTAL_DURATION := 0.50
const COMMIT_TIME := 0.25

# 商店刷新：卷轴从右往左消失（prep_scroll_burn.gdshader），0.25 秒提交刷新，新卷轴淡入。
# 消失边上的东西按皮肤 refresh_fx 换，全部是代码粒子（不再用火焰序列图）：
#   fire  （默认）烧掉：写实柔光火 —— 暖光、软火舌、热芯、带拖尾的火星四层，贴着消失边走。
#   petal （樱花）化成花瓣吹散：边上喷花瓣往左吹，上下沿飘花瓣。
#   wisp  （夜荧光）化成荧光：纸边染夜紫、亮暖黄，一路飞出一群黄色荧光往上飘、打着旋散开；
#                     没烧到的上下沿冒点点荧光。
#   frost （冰雪）冻碎：纸面先冻成冰蓝、边是白霜，边上崩出冰碴往外掉，闪几下冰光；
#                     没冻到的上下沿冒细碎冰晶。
# 三种的时间轴一样，只换 shader 的三圈颜色、粒子和按钮按下的染色。
# 刷新是常用操作，粒子量按「小」档给，别喧宾夺主。
const PrepSkin := preload("res://scenes/prep/PrepSkin.gd")
const PetalTexture := preload("res://scenes/prep/effects/PrepPetalTexture.gd")
const FxTextures := preload("res://scenes/prep/effects/PrepRefreshFxTextures.gd")

# shader 三圈：char 最外最宽 → ember 中间 → hot 贴着消失边
const EDGE_COLORS := {
	"fire": {
		"char_color": Color(0.10, 0.018, 0.004, 1.0),
		"ember_color": Color(0.82, 0.09, 0.015, 1.0),
		"hot_color": Color(1.0, 0.68, 0.10, 1.0),
	},
	"petal": {
		"char_color": Color(1.0, 0.82, 0.89, 1.0),
		"ember_color": Color(1.0, 0.62, 0.78, 1.0),
		"hot_color": Color(1.0, 0.97, 0.98, 1.0),
	},
	"frost": {
		# 冰雪皮肤的卷轴本身就是淡蓝白，颜色要够深才看得出「冻上了」
		"char_color": Color(0.55, 0.80, 1.0, 1.0),   # 先冻上一层冰蓝
		"ember_color": Color(0.16, 0.46, 0.92, 1.0),  # 深冰芯
		"hot_color": Color(0.96, 1.0, 1.0, 1.0),      # 白霜边
	},
	"wisp": {
		# 夜荧光：纸面先染上一层夜紫，边上是暖黄的荧光，贴边一线近白
		"char_color": Color(0.36, 0.22, 0.62, 1.0),
		"ember_color": Color(1.0, 0.76, 0.30, 1.0),
		"hot_color": Color(1.0, 0.97, 0.82, 1.0),
	},
}
const BUTTON_TINTS := {
	"fire": Color(1.0, 0.42, 0.12),
	"petal": Color(1.0, 0.62, 0.80),
	"frost": Color(0.55, 0.84, 1.0),
	"wisp": Color(1.0, 0.82, 0.40),
}
const FRONT_STOP := 0.27   # 消失边走完（0.04 起步 + 0.21）就停喷
const EDGE_STOP := 0.40
# 消失边头 0.09 秒几乎停在最右端（front 从 1.06 夹到 1，再加 ease-in 起步慢），
# 这时就喷会在卷轴右头堆成一根火柱。边真正动起来（front 过了这里）才开始喷。
const FRONT_EMIT_START_U := 0.97
const EDGE_POINTS := 24    # 上下沿各这么多个发射点

var _shop_background: TextureRect
var _refresh_button: BaseButton
var _burn_material: ShaderMaterial
var _elapsed := 0.0
var _busy := false
var _visual_tweens: Array[Tween] = []
var _mode := "fire"
var _committed := false
# mode -> [{node, place, stop}]；place: front 跟着消失边 / edges 上下沿全程 / edges_ahead 只在还没消失的纸面上下沿
var _emitters := {}


func setup(shop_background: TextureRect, refresh_button: BaseButton, burn_shader: Shader) -> void:
	_shop_background = shop_background
	_refresh_button = refresh_button
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 43
	visible = false

	_burn_material = ShaderMaterial.new()
	_burn_material.shader = burn_shader
	_burn_material.set_shader_parameter("burn_progress", 0.0)
	_shop_background.material = _burn_material

	var host := _shop_background.get_parent() as Control
	_emitters = {
		"fire": [
			# 先加的画在下面：暖光垫底，火身，热芯，火星最上
			{"node": _make_fire_glow(host), "place": "front", "stop": FRONT_STOP, "fade_on_commit": true},
			{"node": _make_fire_body(host), "place": "front", "stop": FRONT_STOP, "fade_on_commit": true},
			{"node": _make_fire_core(host), "place": "front", "stop": FRONT_STOP, "fade_on_commit": true},
			{"node": _make_fire_sparks(host), "place": "front", "stop": FRONT_STOP + 0.03},
		],
		"petal": [
			{"node": _make_front_petals(host), "place": "front", "stop": FRONT_STOP},
			{"node": _make_edge_petals(host), "place": "edges", "stop": EDGE_STOP},
		],
		"frost": [
			{"node": _make_frost_spikes(host), "place": "front", "stop": FRONT_STOP, "fade_on_commit": true},
			{"node": _make_frost_shards(host), "place": "front", "stop": FRONT_STOP},
			{"node": _make_frost_glints(host), "place": "front", "stop": FRONT_STOP + 0.03},
			{"node": _make_frost_edges(host), "place": "edges_ahead", "stop": FRONT_STOP},
		],
		"wisp": [
			{"node": _make_wisp_glow(host), "place": "front", "stop": FRONT_STOP, "fade_on_commit": true},
			{"node": _make_wisp_swarm(host), "place": "front", "stop": FRONT_STOP},
			{"node": _make_wisp_edges(host), "place": "edges_ahead", "stop": FRONT_STOP},
		],
	}
	set_process(false)


func is_playing() -> bool:
	return _busy


func play(commit_refresh: Callable) -> void:
	if _busy or not commit_refresh.is_valid():
		return
	_busy = true
	_elapsed = 0.0
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	# 每次点刷新现问皮肤：皮肤晚到也不用另外通知这里。
	_committed = false
	_mode = PrepSkin.refresh_fx()
	if not _emitters.has(_mode):
		_mode = "fire"
	var colors: Dictionary = EDGE_COLORS[_mode]
	for key in colors:
		_burn_material.set_shader_parameter(key, colors[key])
	_burn_material.set_shader_parameter("burn_progress", 0.0)
	_start_emitters()
	_start_visual_tweens()

	await get_tree().create_timer(COMMIT_TIME).timeout
	if not _busy:
		return
	commit_refresh.call()
	# 新卷轴开始淡入：跟着消失边的全部停喷，不然会在新卷轴左头再喷一撮
	_committed = true
	for e in _emitters[_mode]:
		if e.place != "edges":
			(e.node as CPUParticles2D).emitting = false
		# 火墙 / 冰刺墙是「长在纸上」的，纸换了它们也得马上没；飞出去的花瓣、冰碴、火星让它飞完
		if e.get("fade_on_commit", false):
			var fade := create_tween()
			_visual_tweens.append(fade)
			fade.tween_property(e.node, "modulate:a", 0.0, 0.10)
	_burn_material.set_shader_parameter("burn_progress", 0.0)
	_shop_background.modulate = Color(1.0, 1.0, 1.0, 0.0)
	var reveal := create_tween()
	_visual_tweens.append(reveal)
	reveal.tween_property(_shop_background, "modulate", Color.WHITE, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	await get_tree().create_timer(TOTAL_DURATION - COMMIT_TIME).timeout
	_finish()


func _process(delta: float) -> void:
	if not _busy:
		return
	_elapsed = minf(_elapsed + delta, TOTAL_DURATION)
	_update_emitters()


# ── 通用：发射点跟着消失边 ──────────────────────────────────────

func _bg_rect() -> Rect2:
	return Rect2(_shop_background.position, _shop_background.size)


# 和 prep_scroll_burn.gdshader 同一条消失边：front = 1.06 - progress * 1.12（UV.x），左边是还在的纸
func _front_u() -> float:
	var progress := float(_burn_material.get_shader_parameter("burn_progress"))
	return clampf(1.06 - progress * 1.12, 0.0, 1.0)


# 上下沿的发射点（卷轴图上下有木轴，点放在纸面边上）。max_u 以右的不要。
func _edge_points(rect: Rect2, max_u: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in EDGE_POINTS:
		var u := 0.06 + 0.88 * float(i) / float(EDGE_POINTS - 1)
		if u > max_u:
			break
		points.append(Vector2(rect.size.x * u, rect.size.y * 0.10))
		points.append(Vector2(rect.size.x * u, rect.size.y * 0.90))
	return points


func _start_emitters() -> void:
	if not is_instance_valid(_shop_background):
		return
	var rect := _bg_rect()
	for e in _emitters[_mode]:
		var p: CPUParticles2D = e.node
		match e.place:
			"front":
				p.emission_rect_extents = Vector2(6.0, rect.size.y * 0.42)
				p.position = rect.position + Vector2(rect.size.x, rect.size.y * 0.5)
			_:
				p.emission_points = _edge_points(rect, 1.0)
				p.position = rect.position
		p.restart()
		p.modulate = Color.WHITE
		# 跟边走的等边动起来再开（_update_emitters）
		e.started = e.place != "front"
		p.emitting = e.started


func _update_emitters() -> void:
	if not is_instance_valid(_shop_background):
		return
	var rect := _bg_rect()
	var front := _front_u()
	for e in _emitters[_mode]:
		var p: CPUParticles2D = e.node
		if not e.get("started", false) and not _committed and front < FRONT_EMIT_START_U:
			e.started = true
			e.last_x = rect.size.x * front
			p.position = rect.position + Vector2(rect.size.x * front, rect.size.y * 0.5)
			p.emitting = true
		if not p.emitting:
			continue
		if _elapsed >= float(e.stop):
			p.emitting = false
			continue
		match e.place:
			"front":
				# 边后半程一帧能走几十像素：发射范围铺满这一帧扫过的整段，不然粒子一团团断开
				var x := rect.size.x * front
				var last_x := float(e.get("last_x", x))
				e.last_x = x
				p.position = rect.position + Vector2((x + last_x) * 0.5, rect.size.y * 0.5)
				p.emission_rect_extents.x = 6.0 + absf(last_x - x) * 0.5
			"edges_ahead":
				# 只在还没消失的那段纸上：火往前蔓延 / 冰往前冻
				var points := _edge_points(rect, front - 0.02)
				if points.is_empty():
					p.emitting = false
				else:
					p.emission_points = points


# anim_frames > 0：贴图是横排这么多格，每颗粒子随机取一格（不播动画）。
func _base_emitter(host: Control, node_name: String, texture: Texture2D, additive := false, anim_frames := 0) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.name = node_name
	p.texture = texture
	p.emitting = false
	p.local_coords = false   # 发射点跟着消失边走，喷出去的粒子留在原地自己飞
	# 刷新石框挂在商店面板外（z=41），面板本身 z=40；+4 才盖得过石框
	p.z_index = 4
	if additive or anim_frames > 0:
		var mat := CanvasItemMaterial.new()
		if additive:
			mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		if anim_frames > 0:
			mat.particles_animation = true
			mat.particles_anim_h_frames = anim_frames
			mat.particles_anim_v_frames = 1
			p.anim_speed_min = 0.0
			p.anim_speed_max = 0.0
			p.anim_offset_min = 0.0
			p.anim_offset_max = 1.0
		p.material = mat
	host.add_child(p)
	return p


static func _ramp(offsets: Array, colors: Array) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	return g


static func _curve(points: Array) -> Curve:
	var c := Curve.new()
	for pt in points:
		c.add_point(pt)
	return c


# ── 火 ──────────────────────────────────────────────────────────

# 写实柔光火，四层叠：
#   暖光（加亮）  大团橙光跟着边走，把纸和卡牌照热一下 —— 「热」主要靠它；
#   火身（普通）  一堆半透明软火舌叠出体积，往上走越拉越长、越来越红、散成暗红；
#   热芯（加亮）  贴着纸边一小撮白黄高亮，只活一下；
#   火星（加亮）  细长带拖尾，沿飞行方向拉长，往上蹦、被热气托着打旋。
# 火身用普通混合不用加亮：卷轴纸是浅米色，全加亮会冲成一片白，看不出火的红。

func _make_fire_glow(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollFireGlow", FxTextures.glow(), true)
	p.amount = 12
	p.lifetime = 0.20
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.0, -1.0)
	p.spread = 30.0
	p.initial_velocity_min = 0.0
	p.initial_velocity_max = 30.0
	p.gravity = Vector2.ZERO
	p.scale_amount_min = 2.6
	p.scale_amount_max = 3.6
	p.scale_amount_curve = _curve([Vector2(0.0, 0.6), Vector2(0.3, 1.0), Vector2(1.0, 0.8)])
	p.color_ramp = _ramp([0.0, 0.25, 1.0], [
		Color(1.0, 0.55, 0.15, 0.0), Color(1.0, 0.50, 0.12, 0.38), Color(0.9, 0.25, 0.05, 0.0)])
	return p


func _make_fire_body(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollFireBody", FxTextures.flame_atlas(), false, FxTextures.FLAME_FRAMES)
	# 边真正扫过去只有约 0.12 秒；数量按「每秒喷多少」给（amount / lifetime ≈ 1000/秒）。
	# 写实火靠「很多小而透明的火团叠成一片」，单颗大而实就会一颗颗分开、像子弹。
	p.amount = 220
	p.lifetime = 0.22
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.0, -1.0)
	p.spread = 22.0
	p.initial_velocity_min = 40.0
	p.initial_velocity_max = 110.0
	p.gravity = Vector2(0.0, -560.0)     # 热气越往上越快
	p.tangential_accel_min = -170.0     # 打旋：火舌左右摆，不会排成一根根竖直的光柱
	p.tangential_accel_max = 170.0
	p.angle_min = -18.0
	p.angle_max = 18.0
	p.scale_amount_min = 0.45
	p.scale_amount_max = 0.85
	# 往上走：先蹿高一点，再整团缩小熄掉（竖向比横向收得慢，火舌略被拔高；不能横向缩太狠，会变成一根根细条）
	p.split_scale = true
	p.scale_curve_x = _curve([Vector2(0.0, 0.75), Vector2(0.25, 1.15), Vector2(1.0, 0.65)])
	p.scale_curve_y = _curve([Vector2(0.0, 0.55), Vector2(0.3, 1.0), Vector2(1.0, 0.70)])
	# 颜色：亮黄 → 橙 → 红 → 暗红散掉
	p.color_ramp = _ramp([0.0, 0.08, 0.35, 0.7, 1.0], [
		Color(1.0, 0.86, 0.45, 0.0), Color(1.0, 0.74, 0.30, 0.55),
		Color(1.0, 0.46, 0.10, 0.45), Color(0.80, 0.18, 0.04, 0.28), Color(0.32, 0.06, 0.03, 0.0)])
	# 每团一点色差：有的偏黄有的偏红，叠起来才有明暗变化
	p.color_initial_ramp = _ramp([0.0, 1.0], [Color(1.0, 1.0, 0.9), Color(1.0, 0.78, 0.7)])
	return p


func _make_fire_core(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollFireCore", FxTextures.flame_atlas(), true, FxTextures.FLAME_FRAMES)
	p.amount = 110
	p.lifetime = 0.14
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.0, -1.0)
	p.spread = 8.0
	p.initial_velocity_min = 20.0
	p.initial_velocity_max = 60.0
	p.gravity = Vector2(0.0, -400.0)
	p.scale_amount_min = 0.45
	p.scale_amount_max = 0.80
	p.scale_amount_curve = _curve([Vector2(0.0, 0.6), Vector2(0.3, 1.0), Vector2(1.0, 0.3)])
	p.color_ramp = _ramp([0.0, 0.15, 0.6, 1.0], [
		Color(1.0, 0.95, 0.75, 0.0), Color(1.0, 0.85, 0.45, 0.70),
		Color(1.0, 0.55, 0.15, 0.40), Color(1.0, 0.30, 0.05, 0.0)])
	return p


func _make_fire_sparks(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollFireSparks", FxTextures.streak(), true)
	p.amount = 40
	p.lifetime = 0.55
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(-0.25, -1.0)
	p.spread = 35.0
	p.initial_velocity_min = 160.0
	p.initial_velocity_max = 340.0
	p.damping_min = 160.0
	p.damping_max = 260.0
	p.gravity = Vector2(0.0, -120.0)
	p.tangential_accel_min = -180.0
	p.tangential_accel_max = 180.0
	p.particle_flag_align_y = true      # 亮条顺着飞的方向，像拖尾
	p.scale_amount_min = 0.45
	p.scale_amount_max = 0.85
	p.scale_amount_curve = _curve([Vector2(0.0, 1.0), Vector2(1.0, 0.25)])
	p.color_ramp = _ramp([0.0, 0.08, 0.5, 1.0], [
		Color(1.0, 0.95, 0.7, 0.0), Color(1.0, 0.88, 0.45, 1.0),
		Color(1.0, 0.50, 0.10, 0.85), Color(0.8, 0.18, 0.03, 0.0)])
	return p


# ── 樱花 ────────────────────────────────────────────────────────

func _petal_base(host: Control, node_name: String) -> CPUParticles2D:
	var p := _base_emitter(host, node_name, PetalTexture.get_texture())
	p.angle_min = 0.0
	p.angle_max = 360.0
	p.angular_velocity_min = -320.0
	p.angular_velocity_max = 320.0
	p.color_ramp = _ramp([0.0, 0.12, 0.7, 1.0], [
		Color(1, 1, 1, 0.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.9), Color(1, 1, 1, 0.0)])
	# 一点色差：有的白一点，有的粉一点
	p.color_initial_ramp = _ramp([0.0, 1.0], [Color(1.0, 1.0, 1.0), Color(1.0, 0.84, 0.91)])
	return p


func _make_front_petals(host: Control) -> CPUParticles2D:
	var p := _petal_base(host, "ScrollPetalFront")
	p.amount = 60
	p.lifetime = 0.75
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(-1.0, -0.35)
	p.spread = 38.0
	p.initial_velocity_min = 170.0
	p.initial_velocity_max = 330.0
	p.damping_min = 140.0
	p.damping_max = 220.0
	p.gravity = Vector2(0.0, 240.0)
	p.tangential_accel_min = -90.0
	p.tangential_accel_max = 90.0
	p.scale_amount_min = 0.30
	p.scale_amount_max = 0.50
	return p


func _make_edge_petals(host: Control) -> CPUParticles2D:
	var p := _petal_base(host, "ScrollPetalEdges")
	p.amount = 22
	p.lifetime = 0.6
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_POINTS
	p.direction = Vector2(0.0, -1.0)
	p.spread = 180.0
	p.initial_velocity_min = 30.0
	p.initial_velocity_max = 90.0
	p.gravity = Vector2(-40.0, 110.0)
	p.scale_amount_min = 0.22
	p.scale_amount_max = 0.38
	return p


# ── 冰霜 ────────────────────────────────────────────────────────

# 冰刺墙：消失边上一路「长」出直立的冰晶，不飞，弹出来再缩没。相当于火版的火墙。
# 冰雪卷轴中间大半是透明的（卡牌盖着），shader 那圈颜色只在上下边框上看得见，主要靠这道墙。
func _make_frost_spikes(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollFrostSpikes", FxTextures.shard())
	p.amount = 70
	p.lifetime = 0.22
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.0, -1.0)
	p.spread = 0.0
	p.initial_velocity_min = 0.0
	p.initial_velocity_max = 12.0
	p.gravity = Vector2.ZERO
	p.angle_min = -28.0
	p.angle_max = 28.0
	p.scale_amount_min = 0.8
	p.scale_amount_max = 1.4
	# 「咔」一下冒出来（过冲），停一会儿再缩没
	p.scale_amount_curve = _curve([Vector2(0.0, 0.2), Vector2(0.18, 1.1), Vector2(0.3, 1.0), Vector2(1.0, 0.0)])
	p.color_ramp = _ramp([0.0, 0.1, 0.8, 1.0], [
		Color(1, 1, 1, 0.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.0)])
	return p


# 冰碴：从消失边崩出去，往右（已经没了的那一侧）飞、转着掉下去。有分量，重力比花瓣大得多。
func _make_frost_shards(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollFrostShards", FxTextures.shard())
	p.amount = 80
	p.lifetime = 0.6
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(1.0, -0.45)
	p.spread = 42.0
	p.initial_velocity_min = 140.0
	p.initial_velocity_max = 300.0
	p.damping_min = 40.0
	p.damping_max = 90.0
	p.gravity = Vector2(0.0, 820.0)
	p.angle_min = 0.0
	p.angle_max = 360.0
	p.angular_velocity_min = -540.0
	p.angular_velocity_max = 540.0
	p.scale_amount_min = 0.55
	p.scale_amount_max = 1.05
	p.color_ramp = _ramp([0.0, 0.06, 0.75, 1.0], [
		Color(1, 1, 1, 0.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.95), Color(1, 1, 1, 0.0)])
	p.color_initial_ramp = _ramp([0.0, 1.0], [Color(1.0, 1.0, 1.0), Color(0.80, 0.92, 1.0)])
	return p


# 冰光：消失边上一闪一闪的星芒，放大一下就缩没
func _make_frost_glints(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollFrostGlints", FxTextures.glint())
	p.amount = 30
	p.lifetime = 0.28
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(1.0, 0.0)
	p.spread = 180.0
	p.initial_velocity_min = 0.0
	p.initial_velocity_max = 25.0
	p.gravity = Vector2.ZERO
	p.angle_min = -12.0
	p.angle_max = 12.0
	p.scale_amount_min = 1.2
	p.scale_amount_max = 2.0
	p.scale_amount_curve = _curve([Vector2(0.0, 0.1), Vector2(0.3, 1.0), Vector2(1.0, 0.0)])
	p.color_ramp = _ramp([0.0, 0.3, 1.0], [Color(1, 1, 1, 1.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.0)])
	return p


# 还没冻到的上下沿冒细碎冰晶：往外慢慢飘一点就化
func _make_frost_edges(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollFrostEdges", FxTextures.glint())
	p.amount = 26
	p.lifetime = 0.34
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_POINTS
	p.direction = Vector2(0.0, -1.0)
	p.spread = 180.0
	p.initial_velocity_min = 10.0
	p.initial_velocity_max = 40.0
	p.gravity = Vector2(0.0, 30.0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.0
	p.scale_amount_curve = _curve([Vector2(0.0, 0.2), Vector2(0.35, 1.0), Vector2(1.0, 0.0)])
	p.color_ramp = _ramp([0.0, 0.4, 1.0], [Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.9), Color(1, 1, 1, 0.0)])
	return p


# ── 夜荧光 ──────────────────────────────────────────────────────

# 荧光颜色：近白的芯 → 暖黄 → 金橙淡出。加亮混合：叠在亮蓝河面上会冲成发白的亮光点，
# 用户要的就是这个「发光」的感觉（10.31 看过两版定的，别改成普通混合的浓黄）。
static func _wisp_ramp() -> Gradient:
	return _ramp([0.0, 0.1, 0.55, 1.0], [
		Color(1.0, 0.98, 0.85, 0.0), Color(1.0, 0.92, 0.55, 1.0),
		Color(1.0, 0.76, 0.28, 0.85), Color(1.0, 0.55, 0.12, 0.0)])


# 暖黄柔光跟着边走：和火的暖光同一个做法，颜色换成荧光黄
func _make_wisp_glow(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollWispGlow", FxTextures.glow(), true)
	p.amount = 12
	p.lifetime = 0.22
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.0, -1.0)
	p.spread = 30.0
	p.initial_velocity_min = 0.0
	p.initial_velocity_max = 25.0
	p.gravity = Vector2.ZERO
	p.scale_amount_min = 2.4
	p.scale_amount_max = 3.4
	p.scale_amount_curve = _curve([Vector2(0.0, 0.6), Vector2(0.3, 1.0), Vector2(1.0, 0.8)])
	p.color_ramp = _ramp([0.0, 0.25, 1.0], [
		Color(1.0, 0.85, 0.35, 0.0), Color(1.0, 0.80, 0.30, 0.34), Color(0.8, 0.5, 1.0, 0.0)])
	return p


# 一群荧光从消失边飞出：往右上飘、打旋、慢慢减速，像受惊散开的萤火虫
func _make_wisp_swarm(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollWispSwarm", FxTextures.spark(), true)
	# 光点贴图只有 16px：按 2.5～5 倍放大，在屏幕上才是一颗颗看得见的荧光
	p.amount = 110
	p.lifetime = 0.8
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.35, -1.0)
	p.spread = 55.0
	p.initial_velocity_min = 60.0
	p.initial_velocity_max = 190.0
	p.damping_min = 70.0
	p.damping_max = 140.0
	p.gravity = Vector2(0.0, -60.0)
	p.tangential_accel_min = -220.0
	p.tangential_accel_max = 220.0
	p.scale_amount_min = 2.5
	p.scale_amount_max = 5.0
	# 一闪一闪：先亮起来、中段收一下、再亮一下就熄
	p.scale_amount_curve = _curve([Vector2(0.0, 0.3), Vector2(0.15, 1.0), Vector2(0.45, 0.65),
		Vector2(0.65, 1.0), Vector2(1.0, 0.0)])
	p.color_ramp = _wisp_ramp()
	p.color_initial_ramp = _ramp([0.0, 1.0], [Color(1.0, 1.0, 0.9), Color(1.0, 0.86, 0.6)])
	return p


# 还没烧到的上下沿：点点荧光冒出来往上飘
func _make_wisp_edges(host: Control) -> CPUParticles2D:
	var p := _base_emitter(host, "ScrollWispEdges", FxTextures.spark(), true)
	p.amount = 40
	p.lifetime = 0.45
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_POINTS
	p.direction = Vector2(0.0, -1.0)
	p.spread = 40.0
	p.initial_velocity_min = 15.0
	p.initial_velocity_max = 50.0
	p.gravity = Vector2(0.0, -40.0)
	p.scale_amount_min = 1.8
	p.scale_amount_max = 3.2
	p.scale_amount_curve = _curve([Vector2(0.0, 0.2), Vector2(0.35, 1.0), Vector2(1.0, 0.0)])
	p.color_ramp = _wisp_ramp()
	return p


# ── 按钮与消失进度 ────────────────────────────────────────────────

func _start_visual_tweens() -> void:
	if is_instance_valid(_refresh_button):
		_refresh_button.pivot_offset = _refresh_button.size * 0.5
		var button_tween := create_tween()
		_visual_tweens.append(button_tween)
		button_tween.tween_property(_refresh_button, "scale", Vector2(0.90, 0.90), 0.06).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		button_tween.parallel().tween_property(_refresh_button, "modulate", BUTTON_TINTS[_mode], 0.06)
		button_tween.tween_property(_refresh_button, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		button_tween.parallel().tween_property(_refresh_button, "modulate", Color.WHITE, 0.16)
	if is_instance_valid(_shop_background):
		var burn_tween := create_tween()
		_visual_tweens.append(burn_tween)
		burn_tween.tween_interval(0.04)
		burn_tween.tween_method(
			func(value: float) -> void: _burn_material.set_shader_parameter("burn_progress", value),
			0.0,
			1.0,
			0.21
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


func _finish() -> void:
	_busy = false
	set_process(false)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 粒子只停喷、不隐藏：已经喷出去的让它飞完（lifetime 比特效收尾长一点）。
	for mode in _emitters:
		for e in _emitters[mode]:
			if is_instance_valid(e.node):
				(e.node as CPUParticles2D).emitting = false
	if is_instance_valid(_shop_background):
		_shop_background.modulate = Color.WHITE
	if _burn_material != null:
		_burn_material.set_shader_parameter("burn_progress", 0.0)
	if is_instance_valid(_refresh_button):
		_refresh_button.scale = Vector2.ONE
		_refresh_button.modulate = Color.WHITE
	_visual_tweens.clear()


func _exit_tree() -> void:
	for tween in _visual_tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_finish()
