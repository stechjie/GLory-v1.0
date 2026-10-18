extends "res://effects/vfx3d/units/VFXCrimsonKit3D.gd"
class_name VFXTreasureSkill3D

# 宝藏触发的战斗表现（10.18）。全部是纯表现，只消费已经发生的权威结果：
#
#   treasure_element_burst   元素四件套  hit_number(treasure, skill_id 相同)：爆点处四色元素弧
#                                        旋转扩散到真实半径，范围内每个被打中的目标闪一下元素色
#   （自爆灵的毒爆 treasure_poison_blast 在 UnitSkillVFXComposer3D._poison_blast，用绿色序列帧）
#   treasure_soul_counter    亡魂反击    同上：倒下的持有者身上升起亡魂，弧线飞向凶手，撞上重击
#   treasure_control_refresh 控制四件套  前端按「技能冷却突然归零」推断：头顶紫色时钟扫一圈
#
# 颜色走 glow 着色器的 edge/tint/hot/white_hot 四色；几何全是程序生成，不引入贴图。
# context：
#   radius        Vector2，爆炸半径（世界单位，X/Z 两轴，模拟坐标的圆在世界里是椭圆）
#   targets       Array[Vector3]，被打中目标的受击点（BODY 锚点）
#   target_height 目标身高；origin_node / target_node 用来跟随移动

const ELEMENT_COLORS := [
	{"edge": Color(0.30, 0.03, 0.0), "tint": Color(1.0, 0.32, 0.06), "hot": Color(1.0, 0.70, 0.30), "white_hot": Color(1.0, 0.95, 0.80)},   # 火
	{"edge": Color(0.0, 0.08, 0.24), "tint": Color(0.20, 0.62, 1.0), "hot": Color(0.62, 0.90, 1.0), "white_hot": Color(0.94, 0.99, 1.0)},  # 冰
	{"edge": Color(0.22, 0.16, 0.0), "tint": Color(1.0, 0.86, 0.12), "hot": Color(1.0, 0.98, 0.55), "white_hot": Color(1.0, 1.0, 0.92)},  # 雷
	{"edge": Color(0.02, 0.16, 0.02), "tint": Color(0.30, 0.86, 0.18), "hot": Color(0.70, 1.0, 0.45), "white_hot": Color(0.94, 1.0, 0.88)}, # 毒
]
# 深紫底 + 亮青边：浅色亡魂压在冰雪地图上会和地面融成一片（10.18 实战截图），所以底色压暗。
const SOUL := {"edge": Color(0.04, 0.0, 0.10), "tint": Color(0.34, 0.14, 0.66), "hot": Color(0.40, 0.92, 1.0), "white_hot": Color(0.86, 1.0, 1.0)}
const SOUL_HIT := {"edge": Color(0.10, 0.0, 0.16), "tint": Color(0.52, 0.20, 0.86), "hot": Color(0.86, 0.62, 1.0), "white_hot": Color(1.0, 0.94, 1.0)}
const CLOCK := {"edge": Color(0.12, 0.02, 0.22), "tint": Color(0.62, 0.30, 1.0), "hot": Color(0.86, 0.66, 1.0), "white_hot": Color(1.0, 0.96, 1.0)}

var _skill := ""
var _debug: Dictionary = {}


func play_treasure(skill_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> void:
	_skill = skill_id
	begin_kit(int(absf(origin.x * 71.0 + origin.z * 37.0 + float(skill_id.length()))) + 5)
	_debug = {"skill": skill_id}
	match skill_id:
		"treasure_element_burst":
			_element_burst(origin, context)
		"treasure_soul_counter":
			_soul_counter(origin, target, context)
		"treasure_control_refresh":
			_refresh_clock(origin, context)
		_:
			finish()


func get_debug_state() -> Dictionary:
	var state := {"skill": _skill, "children": get_child_count(), "end_time": _end_time}
	state.merge(_debug, true)
	return state


func _pal(palette: Dictionary, params: Dictionary) -> Dictionary:
	var p := palette.duplicate()
	p.merge(params, true)
	return p


func _radius(context: Dictionary) -> Vector2:
	var r: Variant = context.get("radius", Vector2(1.2, 1.2))
	return r if r is Vector2 else Vector2(1.2, 1.2)


func _targets(context: Dictionary) -> Array:
	var out: Array = []
	for v in context.get("targets", []):
		if v is Vector3:
			out.append(v)
	var limit := QUALITY_BUDGET.max_aoe_targets(out.size())
	return out if limit >= out.size() else out.slice(0, limit)


# 被打中的目标：身上一下爆闪 + 一个小环，颜色由调用方给。
func _target_pop(label: String, at_body: Vector3, start: float, palette: Dictionary, size: float) -> void:
	var at := toward_camera(at_body, 0.2)
	var flare := glow_sprite(label + "Flare", at, size, _pal(palette, {"shape": SHAPE_FLARE, "core_white": 0.8, "spin": _rng.randf() * TAU}))
	var ring := glow_sprite(label + "Ring", at, size, _pal(palette, {"shape": SHAPE_RING, "ring_radius": 0.6, "ring_width": 0.12, "core_white": 0.4, "edge_dark": 0.3}))
	track(start, 0.32, func(x: float) -> void:
		flare.scale = Vector3.ONE * size * lerpf(1.1, 0.4, ease_out(x))
		show_with(flare, 0.95 * (1.0 - x))
		ring.scale = Vector3.ONE * size * lerpf(0.4, 1.2, ease_out(x))
		show_with(ring, 0.8 * (1.0 - x)))


# ── 元素四件套 ──────────────────────────────────────────────────────────
# 元素环在画面上只画真实范围的这么大（用户反馈 180 的真实半径在战场上占了半个战区，太大）。
# 只缩表现，伤害范围不变；被打中的目标照样逐个闪。
const ELEMENT_VISUAL_RADIUS_SCALE := 0.5

func _element_burst(center_foot: Vector3, context: Dictionary) -> void:
	var radius := _radius(context) * ELEMENT_VISUAL_RADIUS_SCALE
	var h := height_of(context, "target_height")
	var ground := center_foot + Vector3.UP * 0.03
	_debug["radius"] = radius
	# 中心白闪
	var core := glow_sprite("ElemCore", toward_camera(center_foot + Vector3.UP * h * 0.55, 0.25), h * 1.3, {"shape": SHAPE_FLARE, "core_white": 1.0, "tint": Color(1, 1, 1), "hot": Color(1, 1, 1), "white_hot": Color(1, 1, 1), "edge": Color(0.4, 0.4, 0.5)})
	track(0.0, 0.28, func(x: float) -> void:
		core.scale = Vector3.ONE * h * lerpf(0.6, 1.6, ease_out(x))
		show_with(core, 1.0 * (1.0 - x)))
	# 四段元素弧：各占四分之一圈，一边旋转一边扩散到真实半径
	for i in ELEMENT_COLORS.size():
		var arc := ground_decal("ElemArc%d" % i, ground, radius, _pal(ELEMENT_COLORS[i], {"ring_radius": 0.86, "ring_width": 0.10, "arc_span": 0.22, "arc_start": float(i) * PI * 0.5, "core_white": 0.55, "edge_dark": 0.25, "breakup": 0.2}))
		var phase := float(i) * PI * 0.5
		track(0.02, 0.62, func(x: float) -> void:
			var r := lerpf(0.18, 1.0, ease_out(x))
			arc.scale = Vector3(radius.x * 2.0 * r, 1.0, radius.y * 2.0 * r)
			set_param(arc, "arc_start", phase + x * PI * 1.1)
			show_with(arc, envelope(x, 0.08, 0.4)))
	# 外圈一道细白环，标出真实范围
	var edge := ground_decal("ElemEdge", ground, radius, {"ring_radius": 0.92, "ring_width": 0.04, "core_white": 0.9, "edge_dark": 0.1, "tint": Color(0.9, 0.9, 1.0), "hot": Color(1, 1, 1), "white_hot": Color(1, 1, 1), "edge": Color(0.3, 0.3, 0.4)})
	track(0.16, 0.42, func(x: float) -> void:
		edge.scale = Vector3(radius.x * 2.0, 1.0, radius.y * 2.0)
		show_with(edge, 0.7 * envelope(x, 0.1, 0.6)))
	var targets := _targets(context)
	_debug["targets"] = targets.size()
	for i in targets.size():
		var at: Vector3 = targets[i]
		var dist := Vector2(at.x - center_foot.x, at.z - center_foot.z).length() / maxf(0.01, maxf(radius.x, radius.y) / ELEMENT_VISUAL_RADIUS_SCALE)
		_target_pop("ElemHit%d" % i, at, 0.10 + 0.30 * clampf(dist, 0.0, 1.0), ELEMENT_COLORS[i % ELEMENT_COLORS.size()], h * 0.95)


static func bezier3(a: Vector3, b: Vector3, c: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return a * u * u + b * 2.0 * u * t + c * t * t


# ── 亡魂反击 ────────────────────────────────────────────────────────────
# 同样不用圆环：亡魂是一颗拖长尾巴的幽魂彗星，先从尸体上扭动着升起，再俯冲向凶手；
# 撞上时四道暗紫触须从四周缠住凶手，同时砸出一团暗色重击。
const SOUL_TENDRIL := {"edge": Color(0.02, 0.0, 0.05), "tint": Color(0.26, 0.06, 0.44), "hot": Color(0.60, 0.30, 0.95), "white_hot": Color(0.82, 0.70, 1.0)}

func _soul_counter(from_foot: Vector3, killer_body: Vector3, context: Dictionary) -> void:
	var oh := height_of(context, "origin_height")
	var th := height_of(context, "target_height")
	var killer_ref := weak_node(context.get("target_node"))
	var killer_base := node_position(killer_ref, killer_body)
	var start_at := from_foot + Vector3.UP * oh * 0.35
	var rise_at := from_foot + Vector3.UP * oh * 1.15
	var head := glow_sprite("SoulHead", toward_camera(start_at, 0.22), oh * 0.62, _pal(SOUL, {"shape": SHAPE_GLOW, "softness": 0.35, "core_white": 0.75, "edge_dark": 0.5}))
	var tail := streak("SoulTail", _pal(SOUL, {"core_white": 0.35, "edge_dark": 0.6}))
	var tail_glow := streak("SoulTailGlow", _pal(SOUL, {"core_white": 0.0, "edge_dark": 0.9}))
	var history: Array[Vector3] = []
	var rise := 0.30
	var fly := 0.30
	var dest_now := func() -> Vector3:
		return killer_body + (node_position(killer_ref, killer_base) - killer_base)
	var path := func(t: float) -> Vector3:
		if t <= rise:
			var u := t / rise
			# 扭动着往上：横向正弦摆动，越往上越收
			return start_at.lerp(rise_at, ease_out(u)) + Vector3.RIGHT * sin(u * PI * 3.0) * oh * 0.18 * (1.0 - u)
		var v := clampf((t - rise) / fly, 0.0, 1.0)
		var dest: Vector3 = dest_now.call()
		var mid := rise_at.lerp(dest, 0.4) + Vector3.UP * oh * 0.5
		return bezier3(rise_at, mid, dest, v * v)
	track(0.0, rise + fly, func(x: float) -> void:
		var t := x * (rise + fly)
		var p: Vector3 = path.call(t)
		history.push_front(p)
		if history.size() > 14:
			history.resize(14)
		var tail_end: Vector3 = history[history.size() - 1]
		head.global_position = toward_camera(p, 0.22)
		head.scale = Vector3.ONE * oh * (0.62 + 0.07 * sin(t * 40.0))
		show_with(head, smoothstep(0.0, 0.08, t))
		place_streak(tail, toward_camera(tail_end, 0.2), toward_camera(p, 0.2), oh * 0.17)
		place_streak(tail_glow, toward_camera(tail_end, 0.19), toward_camera(p, 0.19), oh * 0.40)
		show_with(tail, 0.9 * smoothstep(0.0, 0.1, t))
		show_with(tail_glow, 0.55 * smoothstep(0.0, 0.1, t)))
	var hit_at := rise + fly
	# 撞上：四道触须从凶手四周往身上收拢、绕身体转着缠住
	for k in 4:
		var ang := float(k) / 4.0 * TAU + 0.4
		var tendril := streak("SoulTendril%d" % k, _pal(SOUL_TENDRIL, {"core_white": 0.25, "edge_dark": 0.7}))
		track(hit_at, 0.5, func(x: float) -> void:
			var c: Vector3 = dest_now.call()
			var dir := Vector3.RIGHT * cos(ang) + SCREEN_UP * sin(ang)
			var twist := Vector3.RIGHT * cos(ang + x * 1.4) + SCREEN_UP * sin(ang + x * 1.4)
			var outer := c + twist * th * lerpf(0.95, 0.55, ease_out(x))
			var inner := c + dir * th * lerpf(0.95, 0.12, ease_out(minf(1.0, x * 1.6)))
			place_streak(tendril, toward_camera(outer, 0.24), toward_camera(inner, 0.24), th * 0.12 * (1.0 - 0.4 * x))
			show_with(tendril, 0.95 * envelope(x, 0.1, 0.35)))
	# 暗色重击：暗边很重、纵向拉长的爆闪（不是环）
	var smash := glow_sprite("SoulSmash", toward_camera(killer_body, 0.26), th * 1.3, _pal(SOUL_HIT, {"shape": SHAPE_FLARE, "core_white": 0.55, "edge_dark": 0.85}))
	track(hit_at, 0.35, func(x: float) -> void:
		smash.global_position = toward_camera(dest_now.call() as Vector3, 0.26)
		smash.scale = Vector3(1.0, 1.4, 1.0) * th * lerpf(0.6, 1.8, ease_out(x))
		set_param(smash, "spin", 0.2 + x * 0.5)
		show_with(smash, 1.0 - x))
	var shards := shard_cloud("SoulShards", QUALITY_BUDGET.particle_count_for(8), {"facet": 0.6, "main_color": Color(0.22, 0.06, 0.40), "core_color": Color(0.5, 0.9, 1.0)})
	var pieces := scatter(shards.multimesh.instance_count, killer_body, Vector3.ZERO, 1.2, 0.6, 0.8)
	track(hit_at, 0.5, func(x: float) -> void:
		drive_shards(shards, pieces, x, 0.5, 0.06, 1.6))
	_debug["hit_at"] = hit_at


# ── 控制四件套：技能冷却刷新 ───────────────────────────────────────────
func _refresh_clock(head: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "origin_height")
	var ref := weak_node(context.get("origin_node"))
	var base := node_position(ref, head)
	var at := head + Vector3.UP * h * 0.32
	var size := h * 0.62
	var face := glow_sprite("ClockFace", toward_camera(at, 0.3), size, _pal(CLOCK, {"shape": SHAPE_RING, "ring_radius": 0.78, "ring_width": 0.07, "ticks": 12.0, "fill": 0.35, "core_white": 0.3, "edge_dark": 0.5}))
	var sweep := glow_sprite("ClockSweep", toward_camera(at, 0.31), size, _pal(CLOCK, {"shape": SHAPE_RING, "ring_radius": 0.55, "ring_width": 0.42, "reveal": 0.0, "core_white": 0.45, "edge_dark": 0.2}))
	var hand := streak("ClockHand", _pal(CLOCK, {"core_white": 0.9}))
	var ding := glow_sprite("ClockDing", toward_camera(at, 0.32), size, _pal(CLOCK, {"shape": SHAPE_FLARE, "core_white": 1.0}))
	var sweep_sec := 0.5
	# 弹出 → 扫一圈 → 叮 → 淡出，整体跟着头顶走
	track(0.0, sweep_sec + 0.45, func(x: float) -> void:
		var t := x * (sweep_sec + 0.45)
		var c := toward_camera(at + (node_position(ref, base) - base), 0.3)
		var pop := ease_out(minf(1.0, t / 0.12), 2.0) * (1.0 + 0.15 * sin(minf(1.0, t / 0.12) * PI))
		var fade := 1.0 - smoothstep(sweep_sec + 0.2, sweep_sec + 0.45, t)
		var u := clampf(t / sweep_sec, 0.0, 1.0)
		face.global_position = c
		face.scale = Vector3.ONE * size * pop
		show_with(face, 0.95 * fade)
		sweep.global_position = c + CAMERA_DIR * 0.01
		sweep.scale = Vector3.ONE * size * pop
		set_param(sweep, "reveal", u)
		show_with(sweep, 0.75 * fade)
		# 指针从 12 点顺时针转一圈
		var ang := PI * 0.5 - u * TAU
		var dir := Vector3.RIGHT * cos(ang) + SCREEN_UP * sin(ang)
		place_streak(hand, c + CAMERA_DIR * 0.02, c + CAMERA_DIR * 0.02 + dir * size * 0.40 * pop, size * 0.06)
		show_with(hand, fade)
		var dk := clampf((t - sweep_sec) / 0.3, 0.0, 1.0)
		ding.global_position = c + CAMERA_DIR * 0.03
		ding.scale = Vector3.ONE * size * lerpf(0.6, 1.8, ease_out(dk))
		show_with(ding, (1.0 - dk) if t >= sweep_sec else 0.0))
	_debug["sweep"] = sweep_sec
