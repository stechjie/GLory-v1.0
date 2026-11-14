extends VFXBlockRoot
## One ground quad clips the entire shockwave to the actual local lane.
## Bounds use VFX-root X/Z coordinates, including the arena's replay flip.
##
## 10.31 清场加强（用户批准的方案 2、4）：
##   * 地面光波保留；
##   * 两道竖直光幕从击杀点沿本路向两端推开（雪地上贴地光波几乎看不见，竖起来才读得出）；
##   * 击杀点一根短光柱；
##   * 我方本路存活棋子脚下各亮一圈金环（小跳在 BattleVfx 里做，这里只出光）。
## 11.14 加（用户：原有的保留，再加上）：
##   * 皮肤扫光 —— 按棋盘皮肤的 refresh_fx（火 / 樱花 / 冰雪 / 夜荧光），一道消失边从我方这头
##     扫到敌方那头，把整条路刷一遍，跟商店刷新时卷轴烧掉同一套颜色和粒子（PrepShopRefreshBurn）；
##   * 第 21 回合路是横的：光幕和扫光都沿本路的长边走（方向由 sweep 的起止点决定）。
## 整个块 0.9 秒内自行释放（coin_damage_check 的 wave_released 等 1.05 秒）。
const PRESENTATION := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const CURTAIN_SHADER := preload("res://shaders/lane_clear_curtain.gdshader")
const REFRESH_BURN := preload("res://scenes/prep/effects/PrepShopRefreshBurn.gd")
const FX_TEXTURES := preload("res://scenes/prep/effects/PrepRefreshFxTextures.gd")
const PETAL_TEXTURE := preload("res://scenes/prep/effects/PrepPetalTexture.gd")

const TOTAL_SEC := 0.9
# 单位实测只有 0.28–0.93 高（见 vfx-world-scale），光幕 / 光柱按这个量级取。
# 相机俯角约 46°，竖直面在屏幕上被压扁；0.62 时只剩一条细线（10.31 截帧），抬到 1.05。
const CURTAIN_HEIGHT := 1.05
const CURTAIN_SWEEP_SEC := 0.52
const PILLAR_SIZE := Vector2(0.34, 1.7)
const PILLAR_SEC := 0.62
const CHEER_RING_SIZE := 0.62
const CHEER_RING_SEC := 0.55
# 皮肤扫光：0.05 秒起步，0.42 秒扫完整条路；粒子寿命都 ≤ 0.45 秒，块 0.9 秒收尾前基本飞完。
const SWEEP_DELAY_SEC := 0.05
const SWEEP_SEC := 0.42
const SWEEP_CURTAIN_HEIGHT := 0.8
const SWEEP_PARTICLE_SIZE := 0.16

var _along_x := false


# 皮肤贴图都是代码现画的（第一次用时生成），清场那一刻再画会卡一下；开战前先画好。
static func warm_skin_textures(kind: String) -> void:
	match kind:
		"petal":
			PETAL_TEXTURE.get_texture()
		"frost":
			FX_TEXTURES.shard()
		"wisp":
			FX_TEXTURES.spark()
			FX_TEXTURES.glow()
		_:
			FX_TEXTURES.flame_atlas()
			FX_TEXTURES.spark()


## sweep：{from: Vector3, to: Vector3, kind: String}，VFX 根节点坐标。不给就只有原来那套金光。
func play_clear(origin: Vector3, bounds: Rect2, cheer_points: Array = [], sweep: Dictionary = {}) -> void:
	begin()
	var has_sweep: bool = sweep.get("from") is Vector3 and sweep.get("to") is Vector3
	_along_x = false
	if has_sweep:
		var delta: Vector3 = sweep["to"] - sweep["from"]
		_along_x = absf(delta.x) > absf(delta.z)
	var plane := MeshInstance3D.new()
	plane.name = "LaneClippedWave"
	plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = bounds.size
	plane.mesh = quad
	plane.rotation.x = -PI * 0.5
	plane.position = Vector3(bounds.get_center().x, origin.y + 0.035, bounds.get_center().y)
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/lane_clear_wave.gdshader")
	material.set_shader_parameter("progress", 0.0)
	material.set_shader_parameter("world_size", bounds.size)
	var uv := (Vector2(origin.x, origin.z) - bounds.position) / bounds.size
	material.set_shader_parameter("origin_uv", uv.clamp(Vector2.ZERO, Vector2.ONE))
	material.set_shader_parameter("opacity", 1.0 if PRESENTATION.flash_allowed() else 0.35)
	material.set_shader_parameter("detail", PRESENTATION.QUALITY.tier != PRESENTATION.QUALITY.Tier.LOW)
	plane.material_override = material
	add_child(plane)
	var tween := track_tween(create_tween())
	tween.tween_property(material, "shader_parameter/progress", 1.0, 0.68)
	var strength := 1.0 if PRESENTATION.flash_allowed() else 0.45
	_spawn_curtains(origin, bounds, strength)
	_spawn_pillar(origin, strength)
	for point in cheer_points:
		if point is Vector3:
			_spawn_cheer_ring(point, strength)
	if has_sweep:
		_spawn_skin_sweep(sweep["from"], sweep["to"], origin.y, bounds, str(sweep.get("kind", "fire")), strength)
	var done := track_tween(create_tween())
	done.tween_interval(TOTAL_SEC)
	done.tween_callback(finish)


# 两道光幕：宽度 = 本路宽，从击杀点分别沿本路推向两端，边推边淡。
# 普通回合沿 z（竖路）；第 21 回合横路沿 x，光幕转 90° 横过来。
func _spawn_curtains(origin: Vector3, bounds: Rect2, strength: float) -> void:
	var lo := bounds.position.x if _along_x else bounds.position.y
	var hi := bounds.end.x if _along_x else bounds.end.y
	var start := clampf(origin.x if _along_x else origin.z, lo, hi)
	var width := bounds.size.y if _along_x else bounds.size.x
	var axis_property := "position:x" if _along_x else "position:z"
	var index := 0
	for target in [lo, hi]:
		if absf(target - start) < 0.2:
			continue
		var curtain := _quad_node("LaneClearCurtain%d" % index, Vector2(width, CURTAIN_HEIGHT), 0, strength)
		if _along_x:
			curtain.rotation.y = PI * 0.5
			curtain.position = Vector3(start, origin.y + CURTAIN_HEIGHT * 0.5, bounds.get_center().y)
		else:
			curtain.position = Vector3(bounds.get_center().x, origin.y + CURTAIN_HEIGHT * 0.5, start)
		add_child(curtain)
		var mat := curtain.material_override as ShaderMaterial
		var tween := track_tween(create_tween().set_parallel(true))
		tween.tween_property(curtain, axis_property, target, CURTAIN_SWEEP_SEC) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(curtain, "scale:y", 0.35, CURTAIN_SWEEP_SEC) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.tween_property(mat, "shader_parameter/fade", 0.0, CURTAIN_SWEEP_SEC * 0.55) \
			.set_delay(CURTAIN_SWEEP_SEC * 0.45)
		index += 1


func _spawn_pillar(origin: Vector3, strength: float) -> void:
	var pillar := _quad_node("LaneClearPillar", PILLAR_SIZE, 1, strength)
	pillar.position = Vector3(origin.x, origin.y + PILLAR_SIZE.y * 0.5, origin.z)
	pillar.scale = Vector3(0.4, 0.2, 1.0)
	add_child(pillar)
	var mat := pillar.material_override as ShaderMaterial
	var tween := track_tween(create_tween())
	tween.tween_property(pillar, "scale", Vector3(1.0, 1.0, 1.0), 0.12) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.chain().set_parallel(true)
	tween.tween_property(pillar, "scale:x", 0.15, PILLAR_SEC - 0.12).set_ease(Tween.EASE_IN)
	tween.tween_property(mat, "shader_parameter/fade", 0.0, PILLAR_SEC - 0.12).set_ease(Tween.EASE_IN)


func _spawn_cheer_ring(foot: Vector3, strength: float) -> void:
	var ring := _quad_node("LaneClearCheerRing", Vector2.ONE * CHEER_RING_SIZE, 2, strength)
	ring.rotation.x = -PI * 0.5
	ring.position = foot + Vector3(0.0, 0.03, 0.0)
	ring.scale = Vector3.ONE * 0.45
	add_child(ring)
	var mat := ring.material_override as ShaderMaterial
	var tween := track_tween(create_tween().set_parallel(true))
	tween.tween_property(ring, "scale", Vector3.ONE * 1.15, CHEER_RING_SEC) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "shader_parameter/fade", 0.0, CHEER_RING_SEC * 0.6).set_delay(CHEER_RING_SEC * 0.4)


# ── 皮肤扫光 ─────────────────────────────────────────────────────
# 一个「消失边」节点从 from 平移到 to：身上一道皮肤色光幕（商店卷轴消失边那三圈颜色），
# 再挂两组粒子。粒子 local_coords = false，喷出去就留在原地自己飞，于是整条路被一路刷过去。
func _spawn_skin_sweep(from: Vector3, to: Vector3, ground_y: float, bounds: Rect2, kind: String, strength: float) -> void:
	if not REFRESH_BURN.EDGE_COLORS.has(kind):
		kind = "fire"
	var width := bounds.size.y if _along_x else bounds.size.x
	var dir := to - from
	dir.y = 0.0
	if dir.length() < 0.01:
		return
	dir = dir.normalized()
	var front := Node3D.new()
	front.name = "SkinSweepFront"
	front.position = Vector3(from.x, ground_y + 0.03, from.z)
	add_child(front)
	var colors: Dictionary = REFRESH_BURN.EDGE_COLORS[kind]
	var curtain := _quad_node("SkinSweepCurtain", Vector2(width, SWEEP_CURTAIN_HEIGHT), 0, strength * 0.9)
	curtain.rotation.y = PI * 0.5 if _along_x else 0.0
	curtain.position = Vector3(0.0, SWEEP_CURTAIN_HEIGHT * 0.5, 0.0)
	var curtain_mat := curtain.material_override as ShaderMaterial
	curtain_mat.set_shader_parameter("core_color", colors["hot_color"])
	curtain_mat.set_shader_parameter("glow_color", colors["ember_color"])
	curtain_mat.set_shader_parameter("edge_color", colors["char_color"])
	curtain_mat.set_shader_parameter("fade", 0.0)
	front.add_child(curtain)
	# 发射范围：横跨整条路宽，沿扫的方向留一点厚度（后半程一帧走得远，太薄会断成一团团）。
	var extents := Vector3(0.12, 0.02, width * 0.45) if _along_x else Vector3(width * 0.45, 0.02, 0.12)
	var low := PRESENTATION.QUALITY.tier == PRESENTATION.QUALITY.Tier.LOW
	var emitters: Array[CPUParticles3D] = _make_skin_emitters(kind, dir)
	for p in emitters:
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		p.emission_box_extents = extents
		if low:
			p.amount = maxi(8, p.amount / 2)
		front.add_child(p)
	var tween := track_tween(create_tween())
	tween.tween_interval(SWEEP_DELAY_SEC)
	tween.tween_callback(func() -> void:
		for p in emitters:
			if is_instance_valid(p):
				p.emitting = true)
	tween.tween_property(front, "position", Vector3(to.x, ground_y + 0.03, to.z), SWEEP_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(func() -> void:
		for p in emitters:
			if is_instance_valid(p):
				p.emitting = false)
	var glow := track_tween(create_tween())
	glow.tween_interval(SWEEP_DELAY_SEC)
	glow.tween_property(curtain_mat, "shader_parameter/fade", strength * 0.9, 0.06)
	glow.tween_interval(maxf(0.0, SWEEP_SEC - 0.16))
	glow.tween_property(curtain_mat, "shader_parameter/fade", 0.0, 0.10)


# 每种皮肤两组粒子，参数照商店刷新那套（PrepShopRefreshBurn）换成世界单位：
# 单位实测 0.28–0.93 高（vfx-world-scale），粒子按 0.16 底尺寸放大。
func _make_skin_emitters(kind: String, dir: Vector3) -> Array[CPUParticles3D]:
	var out: Array[CPUParticles3D] = []
	match kind:
		"petal":
			# 花瓣从消失边往回吹、转着落下
			var p := _skin_particles("SkinSweepPetals", PETAL_TEXTURE.get_texture(), false, 90, 0.45)
			p.direction = (-dir + Vector3.UP * 0.7).normalized()
			p.spread = 40.0
			p.initial_velocity_min = 0.8
			p.initial_velocity_max = 1.8
			p.damping_min = 1.0
			p.damping_max = 2.0
			p.gravity = Vector3(0.0, -2.4, 0.0)
			p.angle_min = 0.0
			p.angle_max = 360.0
			p.angular_velocity_min = -320.0
			p.angular_velocity_max = 320.0
			p.scale_amount_min = 0.6
			p.scale_amount_max = 1.0
			p.color_ramp = _ramp([0.0, 0.12, 0.7, 1.0], [
				Color(1, 1, 1, 0.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.9), Color(1, 1, 1, 0.0)])
			p.color_initial_ramp = _ramp([0.0, 1.0], [Color(1.0, 1.0, 1.0), Color(1.0, 0.84, 0.91)])
			out.append(p)
			var lift := _skin_particles("SkinSweepPetalLift", PETAL_TEXTURE.get_texture(), false, 40, 0.4)
			lift.direction = Vector3.UP
			lift.spread = 60.0
			lift.initial_velocity_min = 0.6
			lift.initial_velocity_max = 1.2
			lift.gravity = Vector3(0.0, -1.2, 0.0)
			lift.angle_max = 360.0
			lift.angular_velocity_min = -240.0
			lift.angular_velocity_max = 240.0
			lift.scale_amount_min = 0.45
			lift.scale_amount_max = 0.75
			lift.color_ramp = p.color_ramp
			out.append(lift)
		"frost":
			# 冰刺墙：一路「长」出直立冰晶，弹出来再缩没
			var spikes := _skin_particles("SkinSweepFrostSpikes", FX_TEXTURES.shard(), false, 90, 0.3)
			spikes.direction = Vector3.UP
			spikes.spread = 0.0
			spikes.initial_velocity_min = 0.0
			spikes.initial_velocity_max = 0.08
			spikes.gravity = Vector3.ZERO
			spikes.angle_min = -28.0
			spikes.angle_max = 28.0
			spikes.scale_amount_min = 1.1
			spikes.scale_amount_max = 1.9
			spikes.scale_amount_curve = _curve([Vector2(0.0, 0.2), Vector2(0.18, 1.1), Vector2(0.3, 1.0), Vector2(1.0, 0.0)])
			spikes.color_ramp = _ramp([0.0, 0.1, 0.8, 1.0], [
				Color(1, 1, 1, 0.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.0)])
			out.append(spikes)
			# 冰碴：往前崩出去、转着掉
			var shards := _skin_particles("SkinSweepFrostShards", FX_TEXTURES.shard(), false, 60, 0.45)
			shards.direction = (dir + Vector3.UP * 0.8).normalized()
			shards.spread = 42.0
			shards.initial_velocity_min = 1.0
			shards.initial_velocity_max = 2.2
			shards.gravity = Vector3(0.0, -6.0, 0.0)
			shards.angle_max = 360.0
			shards.angular_velocity_min = -540.0
			shards.angular_velocity_max = 540.0
			shards.scale_amount_min = 0.5
			shards.scale_amount_max = 0.9
			shards.color_ramp = spikes.color_ramp
			shards.color_initial_ramp = _ramp([0.0, 1.0], [Color(1.0, 1.0, 1.0), Color(0.80, 0.92, 1.0)])
			out.append(shards)
		"wisp":
			# 暖黄柔光跟着边走 + 一群荧光往上飘、一闪一闪
			var glow := _skin_particles("SkinSweepWispGlow", FX_TEXTURES.glow(), true, 14, 0.22)
			glow.direction = Vector3.UP
			glow.spread = 30.0
			glow.initial_velocity_max = 0.15
			glow.gravity = Vector3.ZERO
			glow.scale_amount_min = 3.0
			glow.scale_amount_max = 4.2
			glow.color_ramp = _ramp([0.0, 0.25, 1.0], [
				Color(1.0, 0.85, 0.35, 0.0), Color(1.0, 0.80, 0.30, 0.34), Color(0.8, 0.5, 1.0, 0.0)])
			out.append(glow)
			var swarm := _skin_particles("SkinSweepWispSwarm", FX_TEXTURES.spark(), true, 110, 0.45)
			swarm.direction = (Vector3.UP + dir * 0.3).normalized()
			swarm.spread = 55.0
			swarm.initial_velocity_min = 0.3
			swarm.initial_velocity_max = 1.0
			swarm.damping_min = 0.6
			swarm.damping_max = 1.2
			swarm.gravity = Vector3(0.0, 0.5, 0.0)
			swarm.scale_amount_min = 1.2
			swarm.scale_amount_max = 2.4
			swarm.scale_amount_curve = _curve([Vector2(0.0, 0.3), Vector2(0.15, 1.0), Vector2(0.45, 0.65),
				Vector2(0.65, 1.0), Vector2(1.0, 0.0)])
			swarm.color_ramp = _ramp([0.0, 0.1, 0.55, 1.0], [
				Color(1.0, 0.98, 0.85, 0.0), Color(1.0, 0.92, 0.55, 1.0),
				Color(1.0, 0.76, 0.28, 0.85), Color(1.0, 0.55, 0.12, 0.0)])
			out.append(swarm)
		_:
			# 火墙：软火舌往上蹿、越来越红；火星往上蹦
			var body := _skin_particles("SkinSweepFireBody", FX_TEXTURES.flame_atlas(), false, 140, 0.32, FX_TEXTURES.FLAME_FRAMES)
			body.direction = Vector3.UP
			body.spread = 20.0
			body.initial_velocity_min = 0.4
			body.initial_velocity_max = 1.0
			body.gravity = Vector3(0.0, 3.0, 0.0)
			body.angle_min = -18.0
			body.angle_max = 18.0
			body.scale_amount_min = 1.0
			body.scale_amount_max = 1.7
			body.scale_amount_curve = _curve([Vector2(0.0, 0.6), Vector2(0.3, 1.0), Vector2(1.0, 0.65)])
			body.color_ramp = _ramp([0.0, 0.08, 0.35, 0.7, 1.0], [
				Color(1.0, 0.86, 0.45, 0.0), Color(1.0, 0.74, 0.30, 0.75),
				Color(1.0, 0.46, 0.10, 0.65), Color(0.80, 0.18, 0.04, 0.35), Color(0.32, 0.06, 0.03, 0.0)])
			body.color_initial_ramp = _ramp([0.0, 1.0], [Color(1.0, 1.0, 0.9), Color(1.0, 0.78, 0.7)])
			out.append(body)
			var sparks := _skin_particles("SkinSweepFireSparks", FX_TEXTURES.spark(), true, 40, 0.45)
			sparks.direction = (Vector3.UP - dir * 0.25).normalized()
			sparks.spread = 35.0
			sparks.initial_velocity_min = 1.2
			sparks.initial_velocity_max = 2.4
			sparks.damping_min = 1.6
			sparks.damping_max = 2.6
			sparks.gravity = Vector3(0.0, 0.6, 0.0)
			sparks.scale_amount_min = 0.9
			sparks.scale_amount_max = 1.6
			sparks.scale_amount_curve = _curve([Vector2(0.0, 1.0), Vector2(1.0, 0.25)])
			sparks.color_ramp = _ramp([0.0, 0.08, 0.5, 1.0], [
				Color(1.0, 0.95, 0.7, 0.0), Color(1.0, 0.88, 0.45, 1.0),
				Color(1.0, 0.50, 0.10, 0.85), Color(0.8, 0.18, 0.03, 0.0)])
			out.append(sparks)
	return out


# anim_frames > 0：贴图横排这么多格，每颗粒子随机取一格（不播动画）。
func _skin_particles(node_name: String, texture: Texture2D, additive: bool, amount: int, lifetime: float, anim_frames := 0) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.local_coords = false
	p.amount = amount
	p.lifetime = lifetime
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * SWEEP_PARTICLE_SIZE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = texture
	if anim_frames > 0:
		mat.particles_anim_h_frames = anim_frames
		mat.particles_anim_v_frames = 1
		mat.particles_anim_loop = false
		p.anim_speed_min = 0.0
		p.anim_speed_max = 0.0
		p.anim_offset_min = 0.0
		p.anim_offset_max = 1.0
	quad.material = mat
	p.mesh = quad
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


func _quad_node(node_name: String, size: Vector2, shape: int, strength: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = size
	node.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = CURTAIN_SHADER
	mat.set_shader_parameter("shape", shape)
	mat.set_shader_parameter("fade", strength)
	node.material_override = mat
	return node
