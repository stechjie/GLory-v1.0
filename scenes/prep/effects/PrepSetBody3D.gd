extends Node3D

# 攻击 / 控制 / 金钱 / 元素 四个套装在备战棋子**身上**的常驻表现（11.04；防卫套是 PrepDefenseShell3D）。
#
# 两层：
#   1. 贴身光：给棋子模型每个网格叠一层 material_overlay（shaders/prep_set_overlay.gdshader），
#      按菲涅尔画一圈贴着身形的光边 —— 和四星光环 four_star_rim 同一做法。已经有 overlay 的网格
#      （四星的轮廓光）不动：四星优先，两层叠在一起会糊。
#   2. 背后虚影（只有攻击 / 控制）：一张朝相机的面片（shaders/prep_set_emblem.gdshader），
#      放在棋子头顶偏后（离相机更远），棋子模型在它前面、深度测试把下半截挡住 —— 看起来在背后。
#
# Leno 11.04 定的方案 + 照各自 logo 修正：
#   攻击：红轮廓光（轻轻脉动）+ 背后交叉双斧虚影，轮流劈砍、劈下时红光一闪（Leno：长剑太难看 → 斧头 → 双斧交叉一直砍 + 红光）
#   控制：淡紫轮廓光 + 背后紫色钟盘（指针在走、中心紫色菱形水晶，logo 4控制）
#   金钱：棋子周围下金币雨，档位（每 1000 金一档，10 档）越高下得越密，升档时迸出一撮；身上不上色
#   元素：两条环绕棋子旋转上爬的四色螺旋光带（火→冰→雷→毒 轮换，各有样子）+ 四色轮廓光呼应
#         （只有轮廓光「很差」→ 水晶球 → 平面光柱（挡住棋子）→ Leno：「要围着棋子环绕着转」）
#
# 接口与 PrepDefenseShell3D 相同（宿主 PrepBoardModels._sync_prep_set_body 用）：
#   category（setup 之前设）、setup(follow, strength, height)、retarget、set_strength、set_start、stop。
# height 是棋子统一渲染身高（父节点坐标），由宿主给。

const OVERLAY_SHADER := preload("res://shaders/prep_set_overlay.gdshader")
const EMBLEM_SHADER := preload("res://shaders/prep_set_emblem.gdshader")
const VORTEX_SHADER := preload("res://shaders/prep_set_vortex.gdshader")
const COIN_SHADER := preload("res://shaders/prep_coin_rain.gdshader")
# 金币雨（金钱套）：档位 = 开战时金钱套加成（每 1000 金 +10%，封顶 10 档），档位越高下得越密
const COIN_MAX := 40
const COIN_RATE_BASE := 0.8      # 0 档：每秒约 0.8 枚（稀稀拉拉，但看得出套装在生效）
const COIN_RATE_PER_TIER := 1.8  # 每升一档每秒多 1.8 枚（10 档约 19 枚 / 秒）
const COIN_LEVELUP_BURST := 6    # 升档那一下额外迸出几枚
const FADE_IN_SEC := 0.35
const FADE_OUT_SEC := 0.25
const SKIP_MESHES := ["ContactShadow3D", "GroundShadow3D", "TeamGlow3D"]

const STYLES := {
	"attack": {"mode": 0, "main": Color(0.95, 0.15, 0.12), "hot": Color(1.0, 0.62, 0.52),
		# 双斧要正红（参考图）：备战 3D 的 Filmic 会把红压成橙，这里往深红多给一点
		"emblem": 0, "edge": Color(0.25, 0.0, 0.02), "e_main": Color(0.80, 0.02, 0.05),
		"e_lit": Color(1.0, 0.18, 0.16), "e_white": Color(1.0, 0.92, 0.90)},
	"control": {"mode": 1, "main": Color(0.62, 0.32, 1.0), "hot": Color(0.90, 0.78, 1.0),
		"emblem": 1, "edge": Color(0.14, 0.04, 0.28), "e_main": Color(0.55, 0.25, 0.92),
		"e_lit": Color(0.86, 0.72, 1.0), "e_white": Color(0.98, 0.94, 1.0)},
	# 11.04：金币在棋子周围往下落（Leno：「金币在棋子周围下，10 个档，金币随着档提升」）；有了金币雨，身上不再上色
	"money": {"mode": 2, "main": Color(1.0, 0.76, 0.22), "hot": Color(1.0, 0.92, 0.55), "emblem": -1,
		"coins": true, "overlay": false},
	# 11.04：只有四色轮廓光太弱（Leno：「元素的也是很差，再换」）→ 加四色水晶球（emblem 2），轮廓光留作呼应
	"element": {"mode": 3, "main": Color(1.0, 0.5, 0.2), "hot": Color(1.0, 1.0, 1.0),
		# 平面光柱挡在棋子前面、把棋子冲白 → 改成围住棋子的 3D 螺旋光带（Leno：「要围着棋子环绕着转」）
		# 有了光柱，棋子身上不再上色（Leno：「有了光柱，棋子身上就不用再弄颜色了」）
		"emblem": -1, "vortex": true, "overlay": false},
}

var category := "attack"
var _follow: Node3D
var _height := 0.1
var _strength := 1.0
var _age := 0.0
var _stopping := false
var _stop_age := 0.0
var _overlay: ShaderMaterial
var _overlaid: Array[MeshInstance3D] = []
var _emblem: MeshInstance3D
var _emblem_mat: ShaderMaterial
var _recheck := 0.0
var _vortex: MeshInstance3D
var _vortex_mat: ShaderMaterial
var _coin_mm: MultiMesh
var _coin_node: MultiMeshInstance3D
var _coin_mat: ShaderMaterial
var _coins: Array[Dictionary] = []
var _coin_acc := 0.0
var _coin_tier := -1
var _rng := RandomNumberGenerator.new()


func setup(follow: Node3D, strength: float, height: float) -> void:
	name = "PrepSetBody_" + category
	_follow = follow
	_strength = strength
	_height = height
	var style: Dictionary = STYLES.get(category, STYLES["attack"])
	_overlay = ShaderMaterial.new()
	_overlay.shader = OVERLAY_SHADER
	# 和四星轮廓光同一档（备战地面 / 待命区透明层在 0~7）
	_overlay.render_priority = 10
	_overlay.set_shader_parameter("mode", int(style["mode"]))
	_overlay.set_shader_parameter("c_main", style["main"])
	_overlay.set_shader_parameter("c_hot", style["hot"])
	_overlay.set_shader_parameter("fade", 0.0)
	_overlay.set_shader_parameter("strength", strength)
	if int(style["emblem"]) >= 0:
		_emblem_mat = ShaderMaterial.new()
		_emblem_mat.shader = EMBLEM_SHADER
		_emblem_mat.render_priority = 9
		_emblem_mat.set_shader_parameter("mode", int(style["emblem"]))
		_emblem_mat.set_shader_parameter("c_edge", style["edge"])
		_emblem_mat.set_shader_parameter("c_main", style["e_main"])
		_emblem_mat.set_shader_parameter("c_lit", style["e_lit"])
		_emblem_mat.set_shader_parameter("c_white", style["e_white"])
		_emblem_mat.set_shader_parameter("fade", 0.0)
		_emblem = MeshInstance3D.new()
		_emblem.name = "Emblem"
		_emblem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var quad := QuadMesh.new()
		# 长剑竖长，钟盘方
		# 交叉双斧：两把斧往两侧举起 / 劈下，面片要宽
		match int(style["emblem"]):
			0: quad.size = Vector2(_height * 1.95, _height * 1.80)
			2: quad.size = Vector2(_height * 1.45, _height * 1.45)   # 水晶球（旧方案）
			3: quad.size = Vector2(_height * 1.70, _height * 2.60)   # 光柱：从脚下到头顶上方（加宽）
			_: quad.size = Vector2(_height * 1.25, _height * 1.25)
		_emblem.mesh = quad
		_emblem.material_override = _emblem_mat
		add_child(_emblem)
	if bool(style.get("vortex", false)):
		# 围住棋子的无盖圆筒，螺旋光带画在筒壁上（shaders/prep_set_vortex.gdshader）
		_vortex_mat = ShaderMaterial.new()
		_vortex_mat.shader = VORTEX_SHADER
		_vortex_mat.render_priority = 9
		_vortex_mat.set_shader_parameter("fade", 0.0)
		var cyl := CylinderMesh.new()
		# 加高加粗：第一版只包住半个身子、光带贴着身体看不出来，要像一根绕着棋子的光柱
		cyl.top_radius = _height * 0.46
		cyl.bottom_radius = _height * 0.52
		cyl.height = _height * 2.1
		cyl.cap_top = false
		cyl.cap_bottom = false
		cyl.radial_segments = 40
		cyl.rings = 6
		_vortex = MeshInstance3D.new()
		_vortex.name = "ElementVortex"
		_vortex.mesh = cyl
		_vortex.material_override = _vortex_mat
		_vortex.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_vortex.position = Vector3(0.0, _height * 2.1 * 0.5, 0.0)
		add_child(_vortex)
	if bool(style.get("coins", false)):
		_coin_mat = ShaderMaterial.new()
		_coin_mat.shader = COIN_SHADER
		_coin_mat.render_priority = 9
		_coin_mat.set_shader_parameter("fade", 0.0)
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		_coin_mm = MultiMesh.new()
		_coin_mm.transform_format = MultiMesh.TRANSFORM_3D
		_coin_mm.use_custom_data = true
		_coin_mm.mesh = quad
		_coin_mm.instance_count = COIN_MAX
		_coin_mm.visible_instance_count = 0
		_coin_node = MultiMeshInstance3D.new()
		_coin_node.name = "CoinRain"
		_coin_node.multimesh = _coin_mm
		_coin_node.material_override = _coin_mat
		_coin_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_coin_node)
		_rng.seed = hash(str(follow.get_instance_id()))
	_attach()
	_snap()


# 当前档位 0~10（与战斗里金钱套实际吃到的加成同一个公式）
func coin_tier() -> int:
	return clampi(roundi(TreasureService.money_set_bonus_for_gold(GameState.gold) * 10.0), 0, 10)


func _spawn_coin(burst: bool) -> void:
	if _coins.size() >= COIN_MAX:
		return
	var ang := _rng.randf() * TAU
	var rad := _height * _rng.randf_range(0.18, 0.62)
	var top := _height * _rng.randf_range(1.35, 1.9)
	var vel := Vector3.ZERO
	if burst:
		# 升档迸发：从棋子头顶往外抛（ease-out 往外、再自由落体）
		top = _height * 1.1
		rad = _height * 0.05
		vel = Vector3(cos(ang), 0.0, sin(ang)) * _height * _rng.randf_range(1.2, 2.0) + Vector3.UP * _height * 2.2
	_coins.append({"p": Vector3(cos(ang) * rad, top, sin(ang) * rad), "v": vel, "age": 0.0,
		"spin": _rng.randf() * TAU, "spin_v": _rng.randf_range(7.0, 13.0), "landed": -1.0,
		# 第一版 0.17~0.22 身高：实拍只是一个个白色小圈，看不出是金币
		"size": _height * _rng.randf_range(0.30, 0.38)})


# 金币：自由落体（越落越快）、边落边翻；落地后弹一下、闪一下、淡掉。
func _update_coins(delta: float, fade: float) -> void:
	if _coin_mm == null:
		return
	_coin_mat.set_shader_parameter("fade", fade)
	var tier := coin_tier()
	if _coin_tier >= 0 and tier > _coin_tier and not _stopping:
		for i in COIN_LEVELUP_BURST:
			_spawn_coin(true)
	_coin_tier = tier
	if not _stopping and _age > 0.0:
		_coin_acc += delta * (COIN_RATE_BASE + COIN_RATE_PER_TIER * float(tier))
		while _coin_acc >= 1.0:
			_coin_acc -= 1.0
			_spawn_coin(false)
	var g := _height * 9.0
	for i in range(_coins.size() - 1, -1, -1):
		var c: Dictionary = _coins[i]
		c["age"] = float(c["age"]) + delta
		var p: Vector3 = c["p"]
		var v: Vector3 = c["v"]
		if float(c["landed"]) < 0.0:
			v.y -= g * delta
			p += v * delta
			if p.y <= 0.0:
				p.y = 0.0
				v = Vector3(v.x * 0.3, -v.y * 0.28, v.z * 0.3)   # 落地弹一下
				c["landed"] = 0.0
		else:
			c["landed"] = float(c["landed"]) + delta
			v.y -= g * delta
			p += v * delta
			if p.y < 0.0:
				p.y = 0.0
				v = Vector3.ZERO
		c["p"] = p
		c["v"] = v
		c["spin"] = float(c["spin"]) + float(c["spin_v"]) * delta * (0.25 if float(c["landed"]) >= 0.0 else 1.0)
		if float(c["landed"]) > 0.45:
			_coins.remove_at(i)
	var n := mini(_coins.size(), COIN_MAX)
	_coin_mm.visible_instance_count = n
	for i in n:
		var c: Dictionary = _coins[i]
		var sz := float(c["size"])
		var p: Vector3 = c["p"]
		_coin_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * sz), p + Vector3.UP * sz * 0.5))
		var landed := float(c["landed"])
		var a := clampf(float(c["age"]) / 0.12, 0.0, 1.0) * (1.0 - clampf(landed / 0.45, 0.0, 1.0) if landed >= 0.0 else 1.0)
		_coin_mm.set_instance_custom_data(i, Color(float(c["spin"]), a, 0.0, 0.0))


func retarget(follow: Node3D) -> void:
	if follow != _follow:
		_detach()
		_follow = follow
		_attach()
	_snap()


func set_strength(strength: float) -> void:
	_strength = strength


func set_start(delay: float, skip_fade: bool) -> void:
	_age = FADE_IN_SEC if skip_fade else -maxf(0.0, delay)


func stop() -> void:
	if _stopping:
		return
	_stopping = true
	_stop_age = _age


func _exit_tree() -> void:
	_detach()


# 给棋子模型的网格叠贴身光。模型是异步换上来的，所以 _process 里隔一会儿再补一次。
func _attach() -> void:
	if _follow == null or not is_instance_valid(_follow):
		return
	if not bool((STYLES.get(category, {}) as Dictionary).get("overlay", true)):
		return
	for node in _follow.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh == null or mesh.name in SKIP_MESHES or _overlaid.has(mesh) or _under_fx(mesh):
			continue
		if mesh.material_overlay != null and mesh.material_overlay != _overlay:
			continue          # 四星轮廓光优先
		mesh.material_overlay = _overlay
		_overlaid.append(mesh)


# 挂在棋子下面的特效节点（四星光环的地环 / 光柱、可升四星光幕…）不是模型本身，不上色。
# 第一版没跳过：4★ 棋子旁边被染出一块亮白长方块（金钱套实拍），四星地环也被染成套装色。
func _under_fx(mesh: Node) -> bool:
	var n := mesh.get_parent()
	while n != null and n != _follow:
		var nm := String(n.name)
		if nm.contains("Aura") or nm.contains("Glow") or nm.contains("Shell") or nm.contains("Sigil"):
			# 不能按「带脚本」判：棋子模型包装节点自己就带脚本，那样会把模型也跳过（门禁抓到攻击 / 控制贴身光全没了）
			return true
		n = n.get_parent()
	return false


func _detach() -> void:
	for mesh in _overlaid:
		if is_instance_valid(mesh) and mesh.material_overlay == _overlay:
			mesh.material_overlay = null
	_overlaid.clear()


func _process(delta: float) -> void:
	if _follow == null or not is_instance_valid(_follow) or not _follow.is_inside_tree():
		queue_free()
		return
	_age += delta
	_recheck -= delta
	if _recheck <= 0.0:
		_recheck = 0.5
		_attach()
	_snap()
	var fade := clampf(_age / FADE_IN_SEC, 0.0, 1.0)
	if _stopping:
		fade *= 1.0 - clampf((_age - _stop_age) / FADE_OUT_SEC, 0.0, 1.0)
		if _age - _stop_age >= FADE_OUT_SEC:
			queue_free()
			return
	var world_h := _height * _follow.get_parent_node_3d().global_transform.basis.get_scale().y if _follow.get_parent_node_3d() != null else _height
	_overlay.set_shader_parameter("fade", fade)
	_overlay.set_shader_parameter("strength", _strength)
	_overlay.set_shader_parameter("center_world", _follow.global_position)
	_overlay.set_shader_parameter("height_world", world_h)
	if _vortex_mat != null:
		_vortex_mat.set_shader_parameter("fade", fade)
	_update_coins(delta, fade)
	if _emblem_mat != null:
		# 虚影：斧缓慢摆动（两组正弦叠加，不是匀速摆）；进场时和贴身光一起淡入
		_emblem_mat.set_shader_parameter("fade", fade * _strength)
		_emblem_mat.set_shader_parameter("sway", 0.10 * sin(_age * 1.3) + 0.04 * sin(_age * 2.9 + 1.0))


# 跟着棋子走；虚影放在头顶偏后（往离相机远的方向挪一点），棋子挡住它的下半截
func _snap() -> void:
	if _follow == null or not is_instance_valid(_follow):
		return
	position = _follow.position
	if _emblem == null:
		return
	# 斧头放低、往后：棋子挡住斧柄下半截，像背着斧（长剑第一版插在头顶上方，看着像根棍子）
	# 光柱的面片底边要贴在脚下：中心抬半个柱高
	var up := _height * (0.62 if category == "attack" else (1.25 if category == "element" else 0.80))
	var back := Vector3.ZERO
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var parent := get_parent_node_3d()
	if cam != null and parent != null:
		var away_world := -cam.global_transform.basis.z           # 相机看过去的方向 = 离相机越来越远
		away_world.y = 0.0
		if away_world.length() > 0.001:
			var away_local := (parent.global_transform.basis.inverse() * away_world.normalized()).normalized()
			back = away_local * _height * (0.70 if category == "attack" else (0.12 if category == "element" else 0.45))
	_emblem.position = Vector3(0.0, up, 0.0) + back
