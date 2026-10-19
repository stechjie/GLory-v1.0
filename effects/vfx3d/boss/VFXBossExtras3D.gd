extends "res://effects/vfx3d/units/VFXCrimsonKit3D.gd"
class_name VFXBossExtras3D

# Boss 技能的程序化补层（10.18 Boss 特效优化）。手绘层还是 BossSkillVFXComposer3D 画，
# 这里只补贴图做不出来的：电场、粒子气、冲击波、蓄力倒计时圈这类会动的东西。
# 全部纯表现；位置都是世界坐标（和宝藏模块同一套约定）。
#
#   meteor_warn      陨星预警：落点一个往里收的红橙圈，落地前越闪越快
#   meteor_embers    陨星落地：一下小爆闪 + 往外溅的火星
#   thunder_field    雷球砸下后：落点地面一圈闪烁的电环，环上乱跳的短电弧，电火花往外迸
#   mirror_shatter   镜像分身出现：镜面碎裂的紫白闪光 + 一圈碎片
#   holy_ring        圣光净化：施法者脚下金色光圈向外铺开
#   rage_shock       狂暴兽里程碑：脚下两道红橙冲击波 + 飞溅的碎石
#   blood_qi         血怒暴走（常驻，调用方负责释放）：身上不断往上冒的红色粒子气 + 脚下暗红圈
#   soul_wisps       噬魂：一串青色魂粒从死者飞进 Boss
#   twin_sigil       双生复活：脚下紫色法阵
#   twin_countdown   双生倒下：倒下那只脚下一个金色计时圈，扇形在复活倒计时内顺时针填满
#   apocalypse_warn  灭世蓄力：这一路每个敌人脚下一个逐渐填满的预警圈（倒计时）
#   apocalypse_flash 灭世落下：每个目标一下大爆闪

const SPARK := {"edge": Color(0.0, 0.10, 0.30), "tint": Color(0.30, 0.72, 1.0), "hot": Color(0.72, 0.94, 1.0), "white_hot": Color(0.96, 1.0, 1.0)}
const SPARK_BODY := {"facet": 0.0, "main_color": Color(0.40, 0.80, 1.0), "core_color": Color(0.92, 1.0, 1.0)}
const EMBER := {"edge": Color(0.30, 0.04, 0.0), "tint": Color(1.0, 0.42, 0.06), "hot": Color(1.0, 0.80, 0.34), "white_hot": Color(1.0, 0.96, 0.82)}
const EMBER_BODY := {"facet": 0.2, "main_color": Color(1.0, 0.42, 0.08), "core_color": Color(1.0, 0.86, 0.40)}
const MIRROR := {"edge": Color(0.08, 0.0, 0.16), "tint": Color(0.60, 0.30, 0.96), "hot": Color(0.90, 0.74, 1.0), "white_hot": Color(1.0, 0.97, 1.0)}
const MIRROR_BODY := {"facet": 0.9, "main_color": Color(0.62, 0.40, 0.95), "core_color": Color(0.96, 0.90, 1.0)}
const HOLY := {"edge": Color(0.30, 0.16, 0.0), "tint": Color(1.0, 0.78, 0.22), "hot": Color(1.0, 0.94, 0.56), "white_hot": Color(1.0, 1.0, 0.90)}
const RAGE := {"edge": Color(0.26, 0.02, 0.0), "tint": Color(1.0, 0.30, 0.06), "hot": Color(1.0, 0.66, 0.24), "white_hot": Color(1.0, 0.92, 0.76)}
const ROCK_BODY := {"facet": 0.8, "main_color": Color(0.36, 0.28, 0.24), "core_color": Color(0.80, 0.50, 0.30)}
const SOUL := {"edge": Color(0.0, 0.10, 0.12), "tint": Color(0.22, 0.86, 0.86), "hot": Color(0.66, 1.0, 0.96), "white_hot": Color(0.94, 1.0, 1.0)}
const SOUL_BODY := {"facet": 0.0, "main_color": Color(0.24, 0.86, 0.84), "core_color": Color(0.86, 1.0, 0.98)}
const TWIN := {"edge": Color(0.06, 0.0, 0.14), "tint": Color(0.58, 0.30, 0.92), "hot": Color(0.86, 0.72, 1.0), "white_hot": Color(1.0, 0.96, 1.0)}
const DOOM := {"edge": Color(0.10, 0.0, 0.12), "tint": Color(0.86, 0.16, 0.42), "hot": Color(1.0, 0.62, 0.40), "white_hot": Color(1.0, 0.94, 0.86)}

var _kind := ""
var _debug: Dictionary = {}
# 常驻效果（血怒粒子气）：调用方 queue_free 前一直活着。
var _looping := false
var _loop_fn: Callable


func play_extra(kind: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> void:
	_kind = kind
	begin_kit(int(absf(origin.x * 53.0 + origin.z * 29.0 + float(kind.length()))) + 11)
	_debug = {"kind": kind}
	match kind:
		"meteor_warn": _meteor_warn(target, context)
		"meteor_embers": _meteor_embers(target, context)
		"thunder_field": _thunder_field(target, context)
		"mirror_shatter": _mirror_shatter(target, context)
		"holy_ring": _holy_ring(origin, context)
		"rage_shock": _rage_shock(origin, context)
		"blood_qi": _blood_qi(origin, context)
		"soul_wisps": _soul_wisps(target, origin, context)
		"twin_sigil": _twin_sigil(origin, context)
		"twin_countdown": _twin_countdown(origin, context)
		"apocalypse_warn": _apocalypse_warn(context)
		"apocalypse_flash": _apocalypse_flash(origin, context)
		_: finish()


func get_debug_state() -> Dictionary:
	var state := {"kind": _kind, "children": get_child_count(), "end_time": _end_time, "looping": _looping}
	state.merge(_debug, true)
	return state


func _pal(palette: Dictionary, params: Dictionary) -> Dictionary:
	var p := palette.duplicate()
	p.merge(params, true)
	return p


func _advance_custom(delta: float) -> void:
	if _looping and _loop_fn.is_valid():
		_loop_fn.call(delta)


func _custom_done() -> bool:
	return not _looping


func _targets(context: Dictionary) -> Array:
	var out: Array = []
	for v in context.get("targets", []):
		if v is Vector3:
			out.append(v)
	var limit := QUALITY_BUDGET.max_aoe_targets(out.size())
	return out if limit >= out.size() else out.slice(0, limit)


# ── 陨星 ────────────────────────────────────────────────────────────────
# 预警圈：原来用的 VFXGroundSigil3D 其实是个命中爆炸模块（火团 + 红烟 + 碎石），施法一出手
# 就在落点炸一大团带黑烟的火 —— 这就是用户看到的「爆炸范围太大」。改成纯预警：贴地一圈
# 红橙环从外往里收，中间淡淡一层填充，落地前闪得越来越快。
func _meteor_warn(at: Vector3, context: Dictionary) -> void:
	var dur := float(context.get("fall_sec", 0.68))
	var h := height_of(context, "target_height")
	var r := maxf(0.38, h * 0.5)
	var ground := at + Vector3.UP * 0.03
	var ring := ground_decal("MeteorWarnRing", ground, Vector2(r, r * 0.8), _pal(EMBER, {"ring_radius": 0.86, "ring_width": 0.09, "ticks": 8.0, "core_white": 0.5, "edge_dark": 0.4}))
	var fill := ground_decal("MeteorWarnFill", ground, Vector2(r, r * 0.8), _pal(EMBER, {"shape": SHAPE_GLOW, "core_white": 0.1, "edge_dark": 0.2}))
	track(0.0, dur, func(x: float) -> void:
		var g := lerpf(1.35, 0.9, ease_out(x, 2.0))
		var blink := 0.7 + 0.3 * sin(x * x * 40.0)
		ring.scale = Vector3(r * 2.0 * g, 1.0, r * 1.6 * g)
		fill.scale = ring.scale
		show_with(ring, blink * smoothstep(0.0, 0.15, x))
		show_with(fill, 0.35 * blink * smoothstep(0.0, 0.3, x)))

# 用户口径：爆炸范围要小。这里只有一下小白闪和往外溅的火星，不再铺大面积。
func _meteor_embers(at: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "target_height")
	var flash := glow_sprite("MeteorFlash", toward_camera(at + Vector3.UP * h * 0.3, 0.25), h * 0.9, _pal(EMBER, {"shape": SHAPE_FLARE, "core_white": 1.0}))
	track(0.0, 0.22, func(x: float) -> void:
		flash.scale = Vector3.ONE * h * lerpf(0.5, 1.1, ease_out(x))
		show_with(flash, 1.0 - x))
	var embers := shard_cloud("MeteorEmbers", QUALITY_BUDGET.particle_count_for(12), EMBER_BODY)
	var pieces := scatter(embers.multimesh.instance_count, at + Vector3.UP * 0.08, Vector3.ZERO, 1.1, 1.5, 0.9)
	track(0.0, 0.6, func(x: float) -> void:
		drive_shards(embers, pieces, x, 0.6, 0.05, 1.4))


# ── 雷核：电场 ──────────────────────────────────────────────────────────
# 用户口径：雷球炸下来后「周围有电的感觉」。落点贴地一圈电环忽明忽暗，环上随机两点之间
# 每隔几帧换一道折线电弧（电在地上乱窜），同时往外迸电火花。持续约 0.9 秒。
const FIELD_SEC := 0.95
const BOLT_COUNT := 4
const BOLT_SEGMENTS := 4

func _thunder_field(at: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "target_height")
	var r := maxf(0.42, h * 0.62)
	var ground := at + Vector3.UP * 0.03
	var ring := ground_decal("ThunderRing", ground, Vector2(r, r * 0.8), _pal(SPARK, {"ring_radius": 0.84, "ring_width": 0.10, "core_white": 0.7, "edge_dark": 0.3, "breakup": 0.45}))
	var fill := ground_decal("ThunderFill", ground, Vector2(r, r * 0.8), _pal(SPARK, {"shape": SHAPE_GLOW, "core_white": 0.2, "edge_dark": 0.0}))
	track(0.0, FIELD_SEC, func(x: float) -> void:
		var flicker := 0.65 + 0.35 * sin(x * 70.0) * sin(x * 23.0)
		var grow := lerpf(0.55, 1.0, ease_out(minf(1.0, x * 4.0)))
		ring.scale = Vector3(r * 2.0 * grow, 1.0, r * 1.6 * grow)
		fill.scale = ring.scale
		show_with(ring, flicker * envelope(x, 0.06, 0.35))
		show_with(fill, 0.35 * flicker * envelope(x, 0.06, 0.5)))
	# 乱窜的电弧：每条由 BOLT_SEGMENTS 段条带拼成折线，每 0.06 秒换一次落点。
	var bolts: Array = []
	for b in BOLT_COUNT:
		var segs: Array = []
		for k in BOLT_SEGMENTS:
			segs.append(streak("ThunderBolt%d_%d" % [b, k], _pal(SPARK, {"core_white": 0.95, "edge_dark": 0.2})))
		bolts.append(segs)
	var state := {"next": 0.0, "pts": []}
	track(0.0, FIELD_SEC, func(x: float) -> void:
		var t := x * FIELD_SEC
		if t >= float(state["next"]):
			state["next"] = t + 0.06
			var all_pts: Array = []
			for b in BOLT_COUNT:
				var a0 := _rng.randf() * TAU
				var a1 := a0 + _rng.randf_range(0.7, 1.9)
				var p0 := ground + Vector3(cos(a0) * r, 0.0, sin(a0) * r * 0.8) * _rng.randf_range(0.3, 1.0)
				var p1 := ground + Vector3(cos(a1) * r, 0.0, sin(a1) * r * 0.8) * _rng.randf_range(0.5, 1.0)
				var pts: Array = [p0]
				for k in range(1, BOLT_SEGMENTS):
					var u := float(k) / float(BOLT_SEGMENTS)
					pts.append(p0.lerp(p1, u) + Vector3(_rng.randf_range(-0.12, 0.12), _rng.randf_range(0.02, 0.22), _rng.randf_range(-0.10, 0.10)))
				pts.append(p1)
				all_pts.append(pts)
			state["pts"] = all_pts
		var live := envelope(x, 0.04, 0.3)
		for b in BOLT_COUNT:
			var pts: Array = (state["pts"] as Array)[b]
			var segs: Array = bolts[b]
			var on := 1.0 if _rng.randf() > 0.25 else 0.0
			for k in BOLT_SEGMENTS:
				place_streak(segs[k], toward_camera(pts[k], 0.15), toward_camera(pts[k + 1], 0.15), 0.035)
				show_with(segs[k], live * on))
	var sparks := shard_cloud("ThunderSparks", QUALITY_BUDGET.particle_count_for(12), SPARK_BODY)
	var flying := scatter(sparks.multimesh.instance_count, ground + Vector3.UP * 0.1, Vector3.ZERO, 1.5, 1.2, 1.0)
	track(0.0, 0.55, func(x: float) -> void:
		drive_shards(sparks, flying, x, 0.55, 0.035, 1.2))
	_debug["radius"] = r


# ── 镜像魔君：分身出现 ──────────────────────────────────────────────────
func _mirror_shatter(foot: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "target_height")
	var body := foot + Vector3.UP * h * 0.5
	var flare := glow_sprite("MirrorFlare", toward_camera(body, 0.25), h * 1.2, _pal(MIRROR, {"shape": SHAPE_FLARE, "core_white": 1.0}))
	var ring := glow_sprite("MirrorRing", toward_camera(body, 0.24), h, _pal(MIRROR, {"shape": SHAPE_RING, "ring_radius": 0.7, "ring_width": 0.08, "core_white": 0.8, "edge_dark": 0.3}))
	track(0.0, 0.34, func(x: float) -> void:
		flare.scale = Vector3.ONE * h * lerpf(0.4, 1.4, ease_out(x))
		show_with(flare, 1.0 - x)
		ring.scale = Vector3.ONE * h * lerpf(0.3, 1.7, ease_out(x))
		show_with(ring, 0.9 * (1.0 - x)))
	var shards := shard_cloud("MirrorShards", QUALITY_BUDGET.particle_count_for(14), MIRROR_BODY)
	var pieces := scatter(shards.multimesh.instance_count, body, Vector3.ZERO, 1.6, 0.8, 1.0)
	track(0.02, 0.6, func(x: float) -> void:
		drive_shards(shards, pieces, x, 0.6, 0.075, 1.0))


# ── 圣光：脚下光圈 ──────────────────────────────────────────────────────
func _holy_ring(foot: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "origin_height")
	var r := h * 0.85
	var ground := foot + Vector3.UP * 0.03
	var ring := ground_decal("HolyRing", ground, Vector2(r, r * 0.8), _pal(HOLY, {"ring_radius": 0.86, "ring_width": 0.09, "ticks": 16.0, "core_white": 0.7, "edge_dark": 0.3}))
	var fill := ground_decal("HolyFill", ground, Vector2(r, r * 0.8), _pal(HOLY, {"shape": SHAPE_GLOW, "core_white": 0.4}))
	track(0.0, 1.1, func(x: float) -> void:
		var g := lerpf(0.3, 1.0, ease_out(minf(1.0, x * 2.5)))
		ring.scale = Vector3(r * 2.0 * g, 1.0, r * 1.6 * g)
		fill.scale = ring.scale
		show_with(ring, 0.95 * envelope(x, 0.08, 0.4))
		show_with(fill, 0.45 * envelope(x, 0.08, 0.5)))


# ── 狂暴兽：冲击波 ──────────────────────────────────────────────────────
func _rage_shock(foot: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "origin_height")
	var ground := foot + Vector3.UP * 0.03
	for i in 2:
		var wave := ground_decal("RageWave%d" % i, ground, Vector2.ONE, _pal(RAGE, {"ring_radius": 0.82, "ring_width": 0.14 - 0.04 * float(i), "core_white": 0.6, "edge_dark": 0.35, "breakup": 0.3}))
		var reach := h * (1.25 + 0.45 * float(i))
		track(0.10 * float(i), 0.5, func(x: float) -> void:
			var g := lerpf(0.15, 1.0, ease_out(x))
			wave.scale = Vector3(reach * 2.0 * g, 1.0, reach * 1.6 * g)
			show_with(wave, 0.95 * (1.0 - smoothstep(0.35, 1.0, x))))
	var rocks := shard_cloud("RageRocks", QUALITY_BUDGET.particle_count_for(10), ROCK_BODY)
	var pieces := scatter(rocks.multimesh.instance_count, ground + Vector3.UP * 0.05, Vector3.ZERO, 1.3, 1.8, 1.0)
	track(0.0, 0.7, func(x: float) -> void:
		drive_shards(rocks, pieces, x, 0.7, 0.07, 1.6))


# ── 血怒魔王：暴走粒子气（常驻） ────────────────────────────────────────
# 用户口径：「红色的粒子气的感觉」。粒子从身体轮廓里不断冒出、往上飘、边飘边散，
# 循环播放直到调用方释放（Boss 死亡 / 战斗结束）。跟着模型走。
const QI_COUNT := 30
const QI_PUFFS := 7
const QI_LIFE := 1.1
const QI_PUFF_LIFE := 1.4
# 亮红的粒子：原来那版（暗红、0.055 倍身高）叠在黑色模型上实战截图里几乎看不见。
const QI_MOTE_BODY := {"facet": 0.0, "main_color": Color(1.0, 0.16, 0.14), "core_color": Color(1.0, 0.70, 0.62)}
const QI_PUFF := {"edge": Color(0.30, 0.0, 0.02), "tint": Color(1.0, 0.10, 0.12), "hot": Color(1.0, 0.40, 0.34), "white_hot": Color(1.0, 0.78, 0.72)}

func _blood_qi(foot: Vector3, context: Dictionary) -> void:
	_looping = true
	# 调用方给的是 1.5 倍体型；模型本身约 2 倍高，粒子气要包住整个身体，按 2 倍身高铺。
	var h := height_of(context, "origin_height") * 1.33
	var ref := weak_node(context.get("origin_node"))
	var base := node_position(ref, foot)
	var count := QUALITY_BUDGET.particle_count_for(QI_COUNT)
	var motes := shard_cloud("BloodQi", count, QI_MOTE_BODY)
	var halo := ground_decal("BloodQiGround", foot + Vector3.UP * 0.03, Vector2(h * 0.5, h * 0.4), _pal(QI_PUFF, {"ring_radius": 0.8, "ring_width": 0.18, "core_white": 0.45, "edge_dark": 0.3, "breakup": 0.35, "fill": 0.35}))
	# 往上飘的红雾：几团柔光片，从身体下半部升起、边升边胀边淡，循环错相。
	var puffs: Array = []
	var puff_seeds: Array[Vector3] = []
	for k in QI_PUFFS:
		puffs.append(glow_sprite("BloodQiPuff%d" % k, foot, h * 0.4, _pal(QI_PUFF, {"shape": SHAPE_GLOW, "core_white": 0.15, "edge_dark": 0.0, "softness": 1.4})))
		puff_seeds.append(Vector3(_rng.randf_range(-0.28, 0.28), _rng.randf_range(0.1, 0.4), float(k) / float(QI_PUFFS)))
	var seeds: Array[Vector4] = []
	for k in count:
		# x/z = 身体轮廓上的水平偏移，y = 起始高度比例，w = 相位
		seeds.append(Vector4(_rng.randf_range(-0.34, 0.34), _rng.randf_range(0.05, 0.7), _rng.randf_range(-0.2, 0.2), _rng.randf()))
	var clock := [0.0]
	_loop_fn = func(delta: float) -> void:
		clock[0] += delta
		var t: float = clock[0]
		var at := foot + (node_position(ref, base) - base)
		var fade_in := minf(1.0, t / 0.35)
		for k in seeds.size():
			var s4: Vector4 = seeds[k]
			var u := fposmod(t / QI_LIFE + s4.w, 1.0)
			var sway := sin((t + s4.w * 5.0) * 3.0) * 0.06 * h
			var p := at + Vector3(s4.x * h * (1.0 + u * 0.5) + sway, h * (s4.y + u * 0.7), s4.z * h)
			var size := h * 0.07 * (1.0 - 0.55 * u)
			motes.multimesh.set_instance_transform(k, Transform3D(Basis().scaled(Vector3.ONE * size), motes.to_local(toward_camera(p, 0.30))))
			motes.multimesh.set_instance_color(k, Color(1, 1, 1, fade_in * smoothstep(0.0, 0.1, u) * (1.0 - smoothstep(0.6, 1.0, u))))
		show_with(motes, 1.0)
		for k in puffs.size():
			var ps: Vector3 = puff_seeds[k]
			var v := fposmod(t / QI_PUFF_LIFE + ps.z, 1.0)
			var puff: MeshInstance3D = puffs[k]
			var pp := at + Vector3(ps.x * h + sin(t * 2.0 + ps.z * 6.0) * 0.05 * h, h * (ps.y + v * 0.75), 0.0)
			puff.global_position = toward_camera(pp, 0.26)
			puff.scale = Vector3.ONE * h * lerpf(0.30, 0.62, v)
			show_with(puff, 0.42 * fade_in * smoothstep(0.0, 0.2, v) * (1.0 - smoothstep(0.5, 1.0, v)))
		var pulse := 0.75 + 0.25 * sin(t * 5.0)
		halo.global_position = at + Vector3.UP * 0.03
		show_with(halo, 0.9 * pulse * fade_in)
	_debug["motes"] = count


# ── 噬魂：魂粒飞进 Boss ─────────────────────────────────────────────────
func _soul_wisps(victim_body: Vector3, boss_foot: Vector3, context: Dictionary) -> void:
	var bh := height_of(context, "origin_height")
	var ref := weak_node(context.get("origin_node"))
	var base := node_position(ref, boss_foot)
	var count := QUALITY_BUDGET.particle_count_for(14)
	var motes := shard_cloud("SoulWisps", count, SOUL_BODY)
	var offsets: Array[Vector3] = []
	for k in count:
		offsets.append(Vector3(_rng.randf_range(-0.2, 0.2), _rng.randf_range(-0.1, 0.25), _rng.randf_range(0.0, 0.35)))
	track(0.05, 0.85, func(x: float) -> void:
		var boss_body := boss_foot + (node_position(ref, base) - base) + Vector3.UP * bh * 0.55
		for k in count:
			var o: Vector3 = offsets[k]
			var u := clampf((x - o.z) / 0.65, 0.0, 1.0)
			var mid := victim_body.lerp(boss_body, 0.5) + Vector3.UP * bh * (0.35 + o.y)
			var p := VFXTreasureSkill3D.bezier3(victim_body + Vector3(o.x, o.y, 0.0) * bh * 0.4, mid, boss_body, ease_out(u, 2.0))
			motes.multimesh.set_instance_transform(k, Transform3D(Basis().scaled(Vector3.ONE * bh * 0.075 * (1.0 - 0.4 * u)), motes.to_local(toward_camera(p, 0.32))))
			motes.multimesh.set_instance_color(k, Color(1, 1, 1, (1.0 if u > 0.0 and u < 1.0 else 0.0)))
		show_with(motes, 1.0))


# ── 双生守门人：复活法阵 ────────────────────────────────────────────────
func _twin_sigil(foot: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "origin_height")
	var r := h * 0.75
	var ground := foot + Vector3.UP * 0.03
	var seal := ground_decal("TwinSeal", ground, Vector2(r, r * 0.8), _pal(TWIN, {"shape": SHAPE_SEAL, "core_white": 0.6, "edge_dark": 0.3}))
	var ring := ground_decal("TwinSealRing", ground, Vector2(r, r * 0.8), _pal(TWIN, {"ring_radius": 0.9, "ring_width": 0.06, "ticks": 12.0, "core_white": 0.8, "edge_dark": 0.2}))
	track(0.0, 1.2, func(x: float) -> void:
		var g := lerpf(0.4, 1.0, ease_out(minf(1.0, x * 3.0)))
		seal.scale = Vector3(r * 2.0 * g, 1.0, r * 1.6 * g)
		ring.scale = seal.scale
		set_param(seal, "spin", x * 2.0)
		show_with(seal, 0.9 * envelope(x, 0.1, 0.35))
		show_with(ring, 0.95 * envelope(x, 0.1, 0.35)))


# 手绘 boss_twin_timer 在实战里只剩一小块（被自身的 reveal / dissolve 遮罩吃掉大半），
# 计时改由这一圈表达：金环 + 12 道刻度，扇形随复活倒计时填满，最后半秒闪烁。
const TWIN_GOLD := {"edge": Color(0.30, 0.18, 0.0), "tint": Color(1.0, 0.78, 0.22), "hot": Color(1.0, 0.94, 0.58), "white_hot": Color(1.0, 1.0, 0.90)}

func _twin_countdown(foot: Vector3, context: Dictionary) -> void:
	var dur := float(context.get("revive_sec", 4.6))
	var h := height_of(context, "origin_height")
	var r := h * 0.6
	var ground := foot + Vector3.UP * 0.04
	var edge := ground_decal("TwinClockEdge", ground, Vector2(r, r * 0.8), _pal(TWIN_GOLD, {"ring_radius": 0.88, "ring_width": 0.09, "ticks": 12.0, "core_white": 0.7, "edge_dark": 0.3}))
	var fill := ground_decal("TwinClockFill", ground, Vector2(r, r * 0.8), _pal(TWIN_GOLD, {"ring_radius": 0.42, "ring_width": 0.84, "reveal": 0.0, "core_white": 0.3, "edge_dark": 0.15}))
	track(0.0, dur, func(x: float) -> void:
		var t := x * dur
		var pop := ease_out(minf(1.0, t / 0.25), 2.0)
		var blink := 1.0 if t < dur - 0.6 else 0.65 + 0.35 * sin(t * 30.0)
		var fade := 1.0 - smoothstep(dur - 0.15, dur, t)
		edge.scale = Vector3(r * 2.0 * pop, 1.0, r * 1.6 * pop)
		fill.scale = edge.scale
		set_param(fill, "reveal", x)
		show_with(edge, 0.95 * blink * fade)
		show_with(fill, 0.6 * blink * fade))


# ── 灭世裁决者 ──────────────────────────────────────────────────────────
# 蓄力 2 秒：这一路每个敌人脚下出一个预警圈，圈里的扇形随时间顺时针填满（就是倒计时），
# 越接近落下闪得越快。被打断时调用方直接释放这个块。
func _apocalypse_warn(context: Dictionary) -> void:
	var dur := float(context.get("charge_sec", 1.95))
	var targets := _targets(context)
	var h := height_of(context, "target_height")
	# 第一版（半径 0.55 倍身高、细环）实战截图里几乎看不出来，放大加粗、填充调亮。
	var r := maxf(0.55, h * 0.75)
	for i in targets.size():
		var ground: Vector3 = (targets[i] as Vector3) + Vector3.UP * 0.03
		var edge := ground_decal("DoomEdge%d" % i, ground, Vector2(r, r * 0.8), _pal(DOOM, {"ring_radius": 0.88, "ring_width": 0.12, "ticks": 8.0, "core_white": 0.75, "edge_dark": 0.3}))
		var fill := ground_decal("DoomFill%d" % i, ground, Vector2(r, r * 0.8), _pal(DOOM, {"ring_radius": 0.42, "ring_width": 0.84, "reveal": 0.0, "core_white": 0.35, "edge_dark": 0.15}))
		track(0.0, dur, func(x: float) -> void:
			var blink := 0.75 + 0.25 * sin(x * x * 60.0)
			var pop := ease_out(minf(1.0, x * 6.0), 2.0)
			edge.scale = Vector3(r * 2.0 * pop, 1.0, r * 1.6 * pop)
			fill.scale = edge.scale
			set_param(fill, "reveal", x)
			show_with(edge, blink)
			show_with(fill, 0.8 * blink))
	_debug["targets"] = targets.size()


func _apocalypse_flash(boss_foot: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "target_height")
	var targets := _targets(context)
	for i in targets.size():
		var at: Vector3 = (targets[i] as Vector3) + Vector3.UP * h * 0.45
		var flare := glow_sprite("DoomFlare%d" % i, toward_camera(at, 0.3), h * 1.6, _pal(DOOM, {"shape": SHAPE_FLARE, "core_white": 1.0}))
		track(0.0, 0.3, func(x: float) -> void:
			flare.scale = Vector3.ONE * h * lerpf(0.6, 2.0, ease_out(x))
			show_with(flare, 1.0 - x))
