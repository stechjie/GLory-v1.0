extends Node3D
## 10.10 第 10 条：凤凰涅槃（联动宝藏 link_phoenix）复活体的「死灵气息」常驻标识。
##
## 为什么需要：模拟层把复活体写成**新 uid**（`<原 uid>_phoenix_<n>`）并置
## `phoenix_used = true`（BattleSimTreasures._queue_phoenix_revive），它只活 3 秒
## （`temporary_deaths` 到点强制真死，文案「以 40% 最大生命复活，获得 3 秒无敌，
## 之后强制死亡」）。这 3 秒里它在画面上和「正常活着的棋子」一模一样，玩家读不出
## 「这只是借尸还魂」。本模块就是那个区分。
##
## 设计口径（用户原话：「与游戏风格一致」「光环不遮挡棋子样子」「避开其他棋子的
## 特效和美术设计」）：
##   · 风格一致 → 配色直接取亡灵（undead）族普攻那套三色
##     （effects/vfx3d/profiles/examples/basic_attack_undead.tres 的
##     dark / main / core），不另起画风；几何是低面数的「纹章环 + 上浮魂屑
##     + 剪影边光」，与四星光环（大地面环 + 元素粒子 + 描边）不是一个形状。
##   · 不遮挡模型 → 三层全部避开模型正面：
##       ① 地面纹章环：平铺在脚下，半径收在队伍圈**以内**；
##       ② 上浮魂屑：粒子从脚下外圈升起，绕行到头顶以上，从不贴着身体；
##       ③ 剪影边光：给模型挂 `material_overlay`，复用 four_star_rim.gdshader
##          的 Fresnel 边光 —— 只有**剪影边缘**显色，正对镜头处 alpha≈0，
##          所以模型自己的贴图一点都没被盖住。
##     另有一条结构不变量兜底：本模块自己生成的**每一个面片都是加色混合**
##     （BLEND_MODE_ADD），加法永远不可能把模型压暗或遮死。
##   · 避开他人特效 → 地面环半径 0.34（队伍圈半径约 0.36），既不压四星光环也
##     不压队伍圈；只在 `piece.phoenix_used == true` 身上出现，普通棋子永不出现；
##     若该模型已被四星光环占用 `material_overlay`，本模块**主动让位**，
##     只留① ②（不顶掉玩家读了整局的招牌标识）。
##
## 纯表现层：不读也不改任何战斗数值（与 FourStarAuraV3_3D 同一条纪律）。
## 几何按「棋子身高 = 1.0」的相对单位画，再按实测身高整体缩放；
## 贴图在运行时生成一次并静态缓存，**不新增任何美术资源文件**。
##
## 注意：**刻意不声明 class_name**。本仓惯例是 preload 常量（见 BattleVfx.gd 顶部
## 9.19 那条注释），且新增全局类会让 `.godot/global_script_class_cache.cfg` 落后于
## 源码，连带让 cold_parse_chain_check 假红。

const SCRIPT_PATH := "res://effects/vfx3d/modules/UndeadNecrosisAura3D.gd"
const NODE_NAME := "UndeadNecrosisAura"
const QUALITY_BUDGET := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
# 复用四星光环的边光 shader：它本就是「只画剪影边、不画正面」的 Fresnel 边光，
# 换个 tint 就是死灵色。不新落 .gdshader —— 新 shader 要带 .uid，会牵动
# --import 与资产清单，为一个 3 秒的常驻光环不值当；而这条 shader 在战斗里被
# 四星棋子用着，绝大多数对局里早就是热的。
const RIM_SHADER := preload("res://effects/vfx3d/shaders/four_star_rim.gdshader")

# 亡灵（necrotic）三色族，取自 data 的 undead 普攻配色。
const DARK_COLOR := Color(0.012, 0.075, 0.052)
const BODY_COLOR := Color(0.16, 0.72, 0.38)
const CORE_COLOR := Color(0.68, 1.0, 0.72)

# 地面纹章环中心线半径（光环单位 = 棋子身高）。队伍圈世界半径约 0.36，
# 这里收在 0.24 且随身高等比缩放 —— 必须**明显小一圈**。
# 第一版定的是 0.34（≈ 队伍圈 0.36），实测截图里加色混合的纹章直接把队伍圈盖住了：
# 队伍色是玩家读「这是谁家的棋子」的第一标识，盖掉它就是踩用户那句
# 「避开其他棋子的特效和美术设计」。现在两个环同心可见，间距留得出来。
const SIGIL_RADIUS := 0.24
# 贴图按「UV 距离 = SIGIL_UV_RADIUS/2 处是环中心线」绘制，与下面
# _get_sigil_mesh() 的 half = SIGIL_RADIUS / SIGIL_UV_RADIUS 一一对应。
const SIGIL_UV_RADIUS := 0.80
# 略高于 TeamGlow3D 的 0.022（BattleRenderer._add_3d_unit_readability），
# 避免与队伍圈互相 z-fighting。
const SIGIL_Y := 0.026
# 魂屑的出射环半径（光环单位），**与纹章环解耦**。
# 它要贴着身体外沿升起：太靠内会从身体里冒出来（挡住棋子），太靠外会飘到队伍圈外
# 去蹭别的格子。实测剪影宽约 0.5 世界单位 ⇒ 环带取 0.22~0.32 正好绕开躯干。
const WISP_RING_RADIUS := 0.32
const WISP_RING_INNER := 0.70   # × WISP_RING_RADIUS
const WISP_BASE_AMOUNT := 14
const WISP_LIFETIME := 1.5
# 剪影边光的强度。**不能大**：four_star_rim.gdshader 的 alpha 由
# (1 - dot(NORMAL, VIEW)) 驱动，低面数模型上朝下/朝外的面（腿、披风下摆）会整片
# 吃到满 alpha。实测 0.62 会把小腿整段染成荧光绿（"腿没了"），0.15 才是「笼罩」。
# 这个数是拿 tools/undead_necrotic_aura_capture.gd 出片定的，别凭手感改大。
const RIM_OPACITY := 0.18
const RIM_MAX_MESHES := 8
const RIM_PRIORITY := 0
# 边光挂在模型的网格上，网格要等 actor 进树 / 编队开场遮挡解除后才可见。
# 这个窗口内每帧重试一次，之后不再空转。
const RIM_RETRY_WINDOW := 2.0
const HEIGHT_FALLBACK := 0.98
# FootAnchor 在 UnitActor3D 里的比例（拿不到锚点时的兜底）。
const FOOT_RATIO_FALLBACK := 0.05

# 网格与贴图是**跨实例共享**的常量资产，只造一次。
static var _sigil_mesh: PlaneMesh
static var _textures: Dictionary = {}

var configured := false
var sigil: MeshInstance3D
var wisps: GPUParticles3D
var sigil_material: StandardMaterial3D
var rim_material: ShaderMaterial
var rim_meshes: Array[MeshInstance3D] = []
var _height := HEIGHT_FALLBACK
var _age := 0.0


# ---------------------------------------------------------------- public API

## 把「死灵气息」同步到某个 actor 上：active 为真则建/刷新，为假则收掉。
## 与 FourStarAuraV3_3D.sync 同形，便于阅读和门禁对照。
static func sync(actor: Node3D, active: bool, height := HEIGHT_FALLBACK) -> Node3D:
	if actor == null or not is_instance_valid(actor):
		return null
	var aura := actor.get_node_or_null(NODE_NAME) as Node3D
	if aura == null and active:
		var script := load(SCRIPT_PATH) as Script
		if script == null:
			return null
		aura = script.new() as Node3D
		if aura == null:
			return null
		aura.name = NODE_NAME
		actor.add_child(aura)
	if aura == null:
		return null
	if active:
		aura.call("configure", height)
	else:
		aura.call("deactivate")
	return aura


## 建层并贴到父 actor 的脚底。重复用同一身高调用是**幂等**的（早退），
## 所以调用方可以每帧无脑调用，不必自己记状态。
func configure(height := HEIGHT_FALLBACK) -> void:
	var wanted := maxf(0.25, height)
	if configured and visible and is_equal_approx(wanted, _height):
		return
	_height = wanted
	if not configured:
		_build()
		configured = true
	scale = Vector3.ONE * _height
	var anchor: Node3D = null
	var parent := get_parent()
	if parent is Node3D:
		anchor = (parent as Node3D).get_node_or_null("FootAnchor") as Node3D
	position = anchor.position if anchor != null else Vector3(0.0, _height * FOOT_RATIO_FALLBACK, 0.0)
	visible = true
	if wisps != null:
		wisps.emitting = true
	_attach_rim()
	set_process(true)


## 借来的这条命结束了（强制真死 / 复活体离场）：收掉光环并交还 material_overlay。
func deactivate() -> void:
	visible = false
	set_process(false)
	if wisps != null:
		wisps.emitting = false
	_clear_rim()


func is_active() -> bool:
	return configured and visible


func debug_state() -> Dictionary:
	return {
		"configured": configured,
		"visible": visible,
		"height": _height,
		"sigil_radius": SIGIL_RADIUS * scale.x,
		"sigil_y": sigil.position.y if sigil != null else 0.0,
		"rim_meshes": rim_meshes.size(),
		"wisp_amount": wisps.amount if wisps != null else 0,
		"wisp_emitting": wisps.emitting if wisps != null else false,
	}


# ---------------------------------------------------------------- 每帧

func _process(delta: float) -> void:
	_age += delta
	if sigil != null:
		# 纹章环慢慢自转 + 呼吸；这是唯一的每帧脚本开销，而光环本身极稀有
		# （3 秒一次、且只有凤凰涅槃这一条宝藏）。粒子全在 GPU 上跑。
		sigil.rotation.y = -_age * 0.45
		if sigil_material != null:
			sigil_material.albedo_color.a = 0.72 + 0.22 * sin(_age * 1.7)
	if rim_material != null:
		# four_star_rim.gdshader 的 eligible=1 会把 opacity 接到一条 2.5s 周期的
		# 呼吸曲线上，clock 是它的相位。
		rim_material.set_shader_parameter("clock", _age)
		if rim_meshes.is_empty() and _age < RIM_RETRY_WINDOW:
			_attach_rim()


func _exit_tree() -> void:
	_clear_rim()


# ---------------------------------------------------------------- 建层

func _build() -> void:
	_clear_rim()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	sigil = MeshInstance3D.new()
	sigil.name = "NecroticSigil"
	sigil.mesh = _get_sigil_mesh()
	sigil_material = _make_sigil_material()
	sigil.material_override = sigil_material
	sigil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sigil.position = Vector3(0.0, SIGIL_Y, 0.0)
	add_child(sigil)
	wisps = _make_wisps()
	rim_material = _make_rim_material()


func _make_sigil_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# 加色：地面纹章只提亮、不压暗地面或棋子（结构不变量，门禁会验）。
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = _get_texture("sigil")
	# 别用最亮的 CORE_COLOR 直接当底色：加色混到黑底上会「打白」，看起来像一圈白灯。
	# 往主体绿压一档，留出「死灵绿」而不是「白光」。
	mat.albedo_color = Color(BODY_COLOR.lerp(CORE_COLOR, 0.45), 0.78)
	mat.emission_enabled = true
	mat.emission = BODY_COLOR
	mat.emission_energy_multiplier = 0.60
	mat.render_priority = RIM_PRIORITY
	return mat


func _make_wisps() -> GPUParticles3D:
	var node := GPUParticles3D.new()
	node.name = "RisingSoulWisps"
	node.local_coords = true
	node.amount = QUALITY_BUDGET.particle_count(WISP_BASE_AMOUNT)
	node.lifetime = WISP_LIFETIME
	node.preprocess = WISP_LIFETIME
	node.randomness = 0.6
	node.process_material = _make_wisp_process()
	node.draw_pass_1 = _make_wisp_quad()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_aabb = AABB(Vector3(-0.95, -0.15, -0.95), Vector3(1.9, 1.8, 1.9))
	add_child(node)
	return node


static func _make_wisp_process() -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = WISP_RING_RADIUS
	pm.emission_ring_inner_radius = WISP_RING_RADIUS * WISP_RING_INNER
	pm.emission_ring_height = 0.0
	pm.direction = Vector3.UP
	pm.spread = 7.0
	pm.gravity = Vector3.ZERO
	pm.initial_velocity_min = 0.30
	pm.initial_velocity_max = 0.55
	# 切向加速度让魂屑绕着身体升，而不是直挺挺地飘；径向**轻微向外**，
	# 免得往回收敛时蹭进身体挡住棋子。
	pm.tangential_accel_min = 0.12
	pm.tangential_accel_max = 0.30
	pm.radial_accel_min = 0.0
	pm.radial_accel_max = 0.05
	pm.damping_min = 0.04
	pm.damping_max = 0.14
	pm.angle_min = -22.0
	pm.angle_max = 22.0
	pm.angular_velocity_min = -35.0
	pm.angular_velocity_max = 35.0
	pm.scale_min = 0.55
	pm.scale_max = 1.15
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.18, 0.62, 1.0])
	gradient.colors = PackedColorArray([
		Color(DARK_COLOR.r, DARK_COLOR.g, DARK_COLOR.b, 0.0),
		Color(CORE_COLOR.r, CORE_COLOR.g, CORE_COLOR.b, 0.85),
		Color(BODY_COLOR.r, BODY_COLOR.g, BODY_COLOR.b, 0.55),
		Color(BODY_COLOR.r, BODY_COLOR.g, BODY_COLOR.b, 0.0),
	])
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	pm.color_ramp = ramp
	var curve := Curve.new()
	for point in [[0.0, 0.35], [0.22, 1.0], [1.0, 0.25]]:
		curve.add_point(Vector2(float(point[0]), float(point[1])))
	var ct := CurveTexture.new()
	ct.curve = curve
	pm.scale_curve = ct
	return pm


static func _make_wisp_quad() -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.20, 0.42)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _get_texture("wisp")
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.no_depth_test = false
	mat.render_priority = RIM_PRIORITY
	quad.material = mat
	return quad


static func _make_rim_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = RIM_SHADER
	mat.render_priority = RIM_PRIORITY
	# eligible=1 走 shader 里那条 2.5s 周期的呼吸曲线，clock 每帧推进。
	mat.set_shader_parameter("eligible", 1.0)
	mat.set_shader_parameter("opacity", RIM_OPACITY)
	mat.set_shader_parameter("clock", 0.0)
	mat.set_shader_parameter("tint", CORE_COLOR)
	return mat


# ---------------------------------------------------------------- 剪影边光

func _attach_rim() -> void:
	_clear_rim()
	if rim_material == null:
		return
	var actor := get_parent() as Node3D
	if actor == null:
		return
	# 四星光环也占 material_overlay 这一个槽位（FourStarAuraV3.attach_rim 挂在
	# actor 的模型网格上）。两者同时存在时**让位**：那是玩家已经读了整局的招牌
	# 标识，不能因为多了一只复活体就被顶掉。判据看「actor 下有没有
	# FourStarAuraV2」而不是看 material_overlay 是否已被写 —— 四星光环的
	# attach_rim 是 call_deferred 的，同帧里谁先跑不确定。
	if actor.get_node_or_null("FourStarAuraV2") != null:
		return
	for node in actor.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh == null or is_ancestor_of(mesh) or not mesh.is_visible_in_tree():
			continue
		if mesh.material_overlay != null:
			continue
		# 地面投影与队伍圈不参与边光，否则黑影/地面环也会亮起死灵绿。
		if str(mesh.name) in ["ContactShadow3D", "GroundShadow3D", "TeamGlow3D"]:
			continue
		mesh.material_overlay = rim_material
		rim_meshes.append(mesh)
		if rim_meshes.size() >= RIM_MAX_MESHES:
			break


func _clear_rim() -> void:
	for mesh in rim_meshes:
		if is_instance_valid(mesh) and mesh.material_overlay == rim_material:
			mesh.material_overlay = null
	rim_meshes.clear()


# ---------------------------------------------------------------- 网格 / 贴图

static func _get_sigil_mesh() -> PlaneMesh:
	if _sigil_mesh == null:
		_sigil_mesh = PlaneMesh.new()
		var half := SIGIL_RADIUS / SIGIL_UV_RADIUS
		_sigil_mesh.size = Vector2(half * 2.0, half * 2.0)
	return _sigil_mesh


static func _get_texture(tex_name: String) -> Texture2D:
	if _textures.has(tex_name):
		return _textures[tex_name]
	var img: Image
	match tex_name:
		"sigil":
			img = _img_sigil()
		_:
			img = _img_wisp()
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_textures[tex_name] = tex
	return tex


# 贴图只造一次（白 RGB + alpha），颜色由材质的 albedo_color / 粒子的 color_ramp 上。
static func _img_sigil() -> Image:
	# 死灵纹章环：外圈断口环 + 内侧昏暗光池 + 一层极细雾边。
	# UV 半径约定：环中心线落在距纹理中心 SIGIL_UV_RADIUS/2 = 0.40 处。
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (float(x) + 0.5) / n - 0.5
			var v := (float(y) + 0.5) / n - 0.5
			var d := sqrt(u * u + v * v)
			var t := d / (SIGIL_UV_RADIUS * 0.5)
			var ang := atan2(v, u)
			# 12 段刻痕把环切成短弧，读起来是「刻了符的圈」而不是纯光环。
			var notch := smoothstep(0.35, 0.85, sin(ang * 12.0))
			var ring := (1.0 - smoothstep(0.10, 0.26, absf(t - 1.0))) * (0.55 + 0.45 * notch)
			var pool := (1.0 - smoothstep(0.30, 0.98, t)) * (0.24 + 0.14 * sin(ang * 6.0))
			# 雾边收得很细：宽了会在脚下糊成一团白雾，既像烟雾又抢队伍圈。
			var halo := (1.0 - smoothstep(0.10, 0.30, absf(t - 1.0))) * 0.10
			var a := clampf(maxf(maxf(ring, pool), halo), 0.0, 1.0)
			var shade := lerpf(0.55, 1.0, clampf(ring + halo, 0.0, 1.0))
			img.set_pixel(x, y, Color(shade, shade, shade, a))
	return img


static func _img_wisp() -> Image:
	# 上浮魂屑：下宽上尖的灵魂火苗，尾端轻微摆动，整体细长。
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := 2.0 * (float(x) + 0.5) / n - 1.0
			var v := 1.0 - 2.0 * (float(y) + 0.5) / n   # +1 = 顶部（尾尖）
			var t := clampf((v + 1.0) * 0.5, 0.0, 1.0)
			var bend := 0.10 * sin(v * 7.0) - 0.05 * v
			var du := u - bend
			var half := 0.36 * pow(sin(pow(t, 0.78) * PI), 0.8) * (1.0 - 0.22 * t)
			var edge := 1.0 - smoothstep(maxf(half - 0.07, 0.0), half + 0.03, absf(du))
			var fade := 1.0 - 0.45 * smoothstep(0.55, 1.0, t)
			var core := 1.0 - smoothstep(0.0, maxf(half * 0.5, 0.01), absf(du))
			var shade := lerpf(0.62, 1.0, core)
			img.set_pixel(x, y, Color(shade, shade, shade, clampf(edge * fade, 0.0, 1.0)))
	return img
