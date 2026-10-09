extends "res://effects/vfx3d/units/VFXCrimsonKit3D.gd"
class_name VFXCrimsonSkill3D

# 赤律族技能表现。每个分支只消费已经发生的权威结果：
#
#   random_ally_buff   赤舞者  skill_ready 上升沿；手上红光，被记录的友军身上挂红色音符直到增益结束
#   frost_status       霜印使  skill_ready 上升沿；手上蓝光，真带 ice_vulnerable 的范围内敌人短暂结冰
#   aoe_silence        赤灯使  skill_ready 上升沿；红色能量光环贴地扩散，扫到记录目标时受击一闪
#   block_guard        赤卫    模拟器补的 unit_skill_proc（只在格挡成功时）
#   stacking_def_break 破甲者  模拟器补的 unit_skill_proc（只在破甲成功时）
#   current_hp_strike  血猎者  已有 hit_number 事件（skill_id 相同）；同一击两条 = 四星斩杀
#   line_pierce        穿云弩手 已有 impact 事件（skill_id 相同）；标枪从主目标继续飞穿后排
#   （战鼓使的鼓点不单独出技能特效：头顶音符徽章表达层数，鼓声画在它的普攻音波里）
#
# 持续状态（沉默 / 冰脆）仍由 StatusVFXController 跟随真实状态显示；这里的
# 施法表现都是短尾（赤舞者音符随增益时长），不冒充状态寿命。

var _skill := ""
var _follow_ref: WeakRef
var _follow_nodes: Array[Node3D] = []
var _follow_bases: Array[Vector3] = []
var _follow_anchor := Vector3.ZERO
# 只给契约检查 / 预览读的表现摘要（画了几个目标、几枚封印、半径…），不参与任何逻辑。
var _debug: Dictionary = {}


func play_crimson_skill(skill_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> void:
	_skill = skill_id
	begin_kit(int(absf(origin.x * 97.0 + target.z * 53.0 + float(skill_id.length()))) + 3)
	var delay := maxf(0.0, float(context.get("delay", 0.0)))
	_debug = {"delay": delay}
	match skill_id:
		"block_guard":
			_block_guard(origin, target, context, delay)
		"random_ally_buff":
			_dancer_buff(origin, context, delay)
		"stacking_def_break":
			_armor_break(target, context, delay)
		"current_hp_strike":
			_blood_bite(target, context, delay)
		"line_pierce":
			_pierce_through(origin, target, context, delay)
		"frost_status":
			_frost_seal(origin, target, context, delay)
		"aoe_silence":
			_lantern_silence(origin, context, delay)
		_:
			finish()


func get_debug_state() -> Dictionary:
	var state := {"skill": _skill, "children": get_child_count(), "end_time": _end_time, "follows": _follow_ref != null}
	state.merge(_debug, true)
	return state


func _advance_custom(_delta: float) -> void:
	if _follow_ref == null or _follow_nodes.is_empty():
		return
	var anchor := node_position(_follow_ref, _follow_anchor)
	var moved := anchor - _follow_anchor
	for i in _follow_nodes.size():
		var node := _follow_nodes[i]
		if is_instance_valid(node):
			node.global_position = _follow_bases[i] + moved


func _follow(ref: WeakRef, anchor: Vector3, nodes: Array) -> void:
	if ref == null:
		return
	_follow_ref = ref
	_follow_anchor = node_position(ref, anchor)
	for node in nodes:
		if node is Node3D:
			_follow_nodes.append(node)
			_follow_bases.append((node as Node3D).global_position)


func _capped(targets: Variant) -> Array:
	var out: Array = []
	if not targets is Array:
		return out
	for value in targets:
		if value is Vector3:
			out.append(value)
	var limit := QUALITY_BUDGET.max_aoe_targets(out.size())
	return out if limit >= out.size() else out.slice(0, limit)


# ── 赤卫 · 格挡 ──────────────────────────────────────────────────────────
# 朝攻击者一侧瞬间张开一道赤色弧形格挡壁（双层弧），接触点亮起六角盾印并白热
# 一闪，火花向两侧弹开。只在模拟器确认格挡成功时触发。
func _block_guard(origin: Vector3, attacker: Vector3, context: Dictionary, delay: float) -> void:
	var h := height_of(context, "origin_height")
	var dir := flat_dir(origin, attacker)
	var facing := screen_angle(origin, attacker)
	var center := toward_camera(origin + Vector3.DOWN * h * 0.04, 0.12)
	var outer := glow_sprite("AegisArcOuter", center, 1.25 * h, {"shape": SHAPE_RING, "ring_radius": 0.70, "ring_width": 0.20, "arc_span": 0.40, "arc_start": facing, "core_white": 0.55, "edge_dark": 0.75})
	var inner := glow_sprite("AegisArcInner", center, 1.25 * h, {"shape": SHAPE_RING, "ring_radius": 0.52, "ring_width": 0.10, "arc_span": 0.30, "arc_start": facing, "core_white": 0.3, "edge_dark": 0.6, "fill": 0.0})
	var contact := center + (Vector3.RIGHT * cos(facing) + SCREEN_UP * sin(facing)) * h * 0.44
	var emblem := glow_sprite("AegisEmblem", contact, 0.46 * h, {"shape": SHAPE_SEAL, "pattern": 3, "seal_rings": 0.0, "stroke": 0.08, "fill": 0.55, "core_white": 0.6, "edge_dark": 0.15})
	var flare := glow_sprite("AegisContactFlare", contact, 0.72, {"shape": SHAPE_FLARE, "spin": facing, "core_white": 0.9})
	var sparks: Array[MeshInstance3D] = []
	for i in 4:
		sparks.append(streak("AegisDeflect%d" % i, {"core_white": 0.55}))
	_follow(weak_node(context.get("origin_node")), origin, [outer, inner, emblem, flare])
	_debug["toward"] = dir
	track(delay, 0.42, func(x: float) -> void:
		var open := ease_out(minf(1.0, x / 0.18), 2.5)
		outer.scale = Vector3.ONE * 1.25 * h * lerpf(0.72, 1.0, open)
		inner.scale = Vector3.ONE * 1.25 * h * lerpf(0.62, 1.0, open)
		set_param(outer, "core_white", lerpf(1.0, 0.45, smoothstep(0.0, 0.35, x)))
		var hold := 1.0 - smoothstep(0.55, 1.0, x)
		show_with(outer, 0.95 * hold * smoothstep(0.0, 0.08, x))
		show_with(inner, 0.70 * hold * smoothstep(0.05, 0.18, x)))
	track(delay, 0.34, func(x: float) -> void:
		emblem.scale = Vector3.ONE * 0.46 * h * lerpf(1.35, 1.0, ease_out(minf(1.0, x * 3.0)))
		set_param(emblem, "spin", -x * 0.4)
		show_with(emblem, 0.9 * envelope(x, 0.10, 0.45)))
	track(delay, 0.18, func(x: float) -> void:
		flare.scale = Vector3.ONE * lerpf(0.86, 0.38, x)
		show_with(flare, 1.0 - x))
	track(delay + 0.02, 0.22, func(x: float) -> void:
		for i in sparks.size():
			var side := -1.0 if i % 2 == 0 else 1.0
			var spread := side * (1.0 + 0.35 * float(i / 2))
			var d := (dir.rotated(Vector3.UP, spread) + Vector3.UP * (0.35 + 0.2 * float(i / 2))).normalized()
			var head := contact + d * lerpf(0.06, 0.46, ease_out(x))
			place_streak(sparks[i], contact + d * lerpf(0.0, 0.24, ease_out(x)), head, 0.065)
			show_with(sparks[i], 0.9 * (1.0 - x)))


# ── 赤舞者 · 随机友军增益 ────────────────────────────────────────────────
# 施法时手上一记红光；被选中的友军身上挂几枚红色音符上下跳动，跟着人走，
# 持续到增益结束（数据 buff_duration）后消失。只表现「拿到了增益」，
# 不声称是三选一里的哪一种（模拟器没有记录）。
func _dancer_buff(origin: Vector3, context: Dictionary, delay: float) -> void:
	var h := height_of(context, "origin_height")
	var hand_glow := glow_sprite("DancerHandGlow", toward_camera(origin, 0.12), 0.95, {"core_white": 0.65, "softness": 1.1})
	var hand_flare := glow_sprite("DancerHandFlare", toward_camera(origin, 0.14), 0.80, {"shape": SHAPE_FLARE, "core_white": 0.85})
	_follow(weak_node(context.get("origin_node")), origin, [hand_glow, hand_flare])
	track(delay, 0.45, func(x: float) -> void:
		hand_glow.scale = Vector3.ONE * lerpf(0.55, 1.15, ease_out(x))
		show_with(hand_glow, 0.95 * envelope(x, 0.15, 0.55)))
	track(delay, 0.28, func(x: float) -> void:
		hand_flare.scale = Vector3.ONE * lerpf(1.25, 0.50, x)
		set_param(hand_flare, "spin", x * 1.2)
		show_with(hand_flare, 0.9 * (1.0 - x)))
	var allies := _capped(context.get("targets", []))
	var nodes: Array = context.get("target_nodes", [])
	var duration := clampf(float(context.get("duration", 3.0)), 0.5, 12.0)
	var per_ally := mini(3, QUALITY_BUDGET.auxiliary_layers_for(3) + 1)
	_debug["targets"] = allies.size()
	_debug["duration"] = duration
	_debug["notes"] = 0
	for index in allies.size():
		var foot: Vector3 = allies[index]
		var ref: WeakRef = weak_node(nodes[index]) if index < nodes.size() else null
		var base := node_position(ref, foot)
		var notes: Array[MeshInstance3D] = []
		for k in per_ally:
			notes.append(glow_sprite("BuffNote%d_%d" % [index, k], foot, 0.30, {"shape": SHAPE_SEAL, "pattern": 4, "seal_rings": 0.0, "fill": 0.0, "stroke": 0.06, "core_white": 0.30, "edge_dark": 0.65}))
		_debug["notes"] = int(_debug["notes"]) + notes.size()
		var start := delay + 0.18 + float(index) * 0.05
		track(start, duration, func(x: float) -> void:
			var t := x * duration
			# 被增益者离场（节点已释放）时音符随之熄灭，不留在原地。
			var gone := ref != null and not is_instance_valid(ref.get_ref())
			var now := foot + (node_position(ref, base) - base)
			var fade := smoothstep(0.0, 0.25 / duration, x) * (1.0 - smoothstep(1.0 - 0.35 / duration, 1.0, x))
			for k in notes.size():
				var phase := float(k) * TAU / float(notes.size())
				var orbit := t * 1.6 + phase
				var bounce := absf(sin(t * 5.2 + phase * 1.7))
				var p := now + Vector3.UP * h * (0.98 + 0.18 * float(k % 2) + 0.12 * bounce) + Vector3(cos(orbit) * 0.30, 0.0, sin(orbit) * 0.16)
				notes[k].global_position = toward_camera(p, 0.15)
				notes[k].scale = Vector3.ONE * (0.36 + 0.06 * bounce)
				set_param(notes[k], "spin", 0.25 * sin(t * 4.0 + phase))
				show_with(notes[k], 0.0 if gone else 0.95 * fade))


# ── 破甲者 · 破甲 ────────────────────────────────────────────────────────
# 目标胸前一块赤色裂甲：放射裂纹 + 掉落的甲片；累计破甲越多裂纹越多（上限 8 道）。
func _armor_break(target: Vector3, context: Dictionary, delay: float) -> void:
	var stacks := clampi(int(context.get("stacks", 2)), 1, 40)
	var at := toward_camera(target, 0.22)
	var crack := solid("ArmorCrack", _crack_mesh(4 + mini(4, stacks / 4)), {"style": STYLE_CRACK, "main_color": CATALOG.DARK.lerp(CATALOG.MAIN, 0.55)})
	var plate := glow_sprite("ArmorPlateFlash", at, 0.62, {"shape": SHAPE_SEAL, "pattern": 3, "seal_rings": 0.0, "stroke": 0.05, "fill": 0.35, "core_white": 0.3})
	var face := Basis(Vector3.RIGHT, SCREEN_UP, CAMERA_DIR)
	var size := 0.26 + 0.010 * float(mini(stacks, 12))
	_debug["stacks"] = stacks
	crack.global_transform = Transform3D(face.scaled(Vector3.ONE * size), at)
	var flare := glow_sprite("ArmorBreakFlare", at, 0.55, {"shape": SHAPE_FLARE, "spin": 0.78, "core_white": 0.7})
	var plates := shard_cloud("ArmorPlates", QUALITY_BUDGET.particle_count_for(3 + mini(3, stacks / 6)), {"facet": 0.5})
	var pieces := scatter(plates.multimesh.instance_count, at, Vector3.ZERO, 0.6, 0.6, 1.0)
	_follow(weak_node(context.get("target_node")), target, [crack, flare, plate])
	track(delay, 0.30, func(x: float) -> void:
		plate.scale = Vector3.ONE * lerpf(0.66, 0.52, ease_out(x))
		show_with(plate, 0.75 * (1.0 - smoothstep(0.25, 1.0, x))))
	track(delay, 0.10, func(x: float) -> void:
		crack.global_transform.basis = face.scaled(Vector3.ONE * size * lerpf(0.55, 1.0, ease_out(x)))
		show_with(crack, smoothstep(0.0, 0.6, x)))
	track(delay + 0.10, 0.42, func(x: float) -> void:
		show_with(crack, 1.0 - smoothstep(0.45, 1.0, x)))
	track(delay, 0.16, func(x: float) -> void:
		flare.scale = Vector3.ONE * lerpf(0.64, 0.30, x)
		show_with(flare, 0.9 * (1.0 - x)))
	track(delay + 0.04, 0.52, func(x: float) -> void:
		drive_shards(plates, pieces, x, 0.52, 0.095, 1.1))


# ── 血猎者 · 当前生命伤害 / 四星斩杀 ─────────────────────────────────────
# 箭到之后，目标身上一道 X 形血噬 + 坠落血滴；四星斩杀额外一道自上而下的血刺。
func _blood_bite(target: Vector3, context: Dictionary, delay: float) -> void:
	var h := height_of(context, "target_height")
	var at := toward_camera(target, 0.22)
	var cuts: Array[MeshInstance3D] = []
	for i in 2:
		cuts.append(streak("BloodBiteCut%d" % i, {"core_white": 0.35}))
	var splash := glow_sprite("BloodBiteSplash", at, 0.62, {"edge_dark": 0.9, "softness": 0.6, "core_white": 0.25})
	track(delay, 0.26, func(x: float) -> void:
		splash.scale = Vector3.ONE * lerpf(0.30, 0.62, ease_out(x))
		show_with(splash, 0.85 * (1.0 - smoothstep(0.2, 1.0, x))))
	var drops := shard_cloud("BloodDrops", QUALITY_BUDGET.particle_count_for(5), {"facet": 0.3, "main_color": Color(0.55, 0.012, 0.04), "core_color": Color(0.9, 0.16, 0.12)})
	var pieces := scatter(drops.multimesh.instance_count, at, Vector3.ZERO, 0.35, 0.5, 1.0)
	for i in cuts.size():
		var cut := cuts[i]
		var a := 0.80 if i == 0 else PI - 0.80
		var d := (Vector3.RIGHT * cos(a) + SCREEN_UP * sin(a)).normalized()
		track(delay + float(i) * 0.05, 0.30, func(x: float) -> void:
			var draw := ease_out(minf(1.0, x * 3.5))
			place_streak(cut, at - d * 0.34, at - d * 0.34 + d * 0.68 * draw, 0.15 * (1.0 - x * 0.5))
			show_with(cut, 0.95 * (1.0 - smoothstep(0.4, 1.0, x))))
	track(delay + 0.04, 0.48, func(x: float) -> void:
		drive_shards(drops, pieces, x, 0.48, 0.065, 1.2))
	_follow(weak_node(context.get("target_node")), target, [])
	_debug["execute"] = bool(context.get("execute", false))
	if bool(context.get("execute", false)):
		var foot: Vector3 = context.get("target_foot", target + Vector3.DOWN * h * 0.55)
		var spike := streak("ExecuteSpike", {"core_white": 0.75})
		var ring := ground_decal("ExecuteRing", foot + Vector3.UP * 0.02, Vector2(0.5, 0.36) * h, {"ring_radius": 0.84, "ring_width": 0.16, "breakup": 0.5, "ticks": 6.0, "seed": 9.0, "fill": 0.5})
		var top := foot + Vector3.UP * h * 1.45
		track(delay + 0.10, 0.36, func(x: float) -> void:
			var draw := ease_out(minf(1.0, x * 3.0))
			place_streak(spike, top, top.lerp(foot + Vector3.UP * 0.05, draw), 0.22 * (1.0 - x * 0.6))
			show_with(spike, 1.0 - smoothstep(0.5, 1.0, x)))
		track(delay + 0.18, 0.40, func(x: float) -> void:
			ring.scale = Vector3(1.0 * h, 1.0, 0.74 * h) * lerpf(0.5, 1.1, ease_out(x))
			show_with(ring, 0.85 * (1.0 - x)))


# ── 穿云弩手 · 贯穿 ──────────────────────────────────────────────────────
# 标枪扎中主目标后不停，沿同一直线继续飞穿后排被贯穿的目标（按模拟器顺序），
# 经过谁谁身上一道血口。与普攻标枪同一外形，看起来是同一支枪。
func _pierce_through(primary: Vector3, first_target: Vector3, context: Dictionary, delay: float) -> void:
	var targets := _capped(context.get("targets", [first_target]))
	if targets.is_empty():
		targets = [first_target]
	_debug["targets"] = targets.size()
	var start := toward_camera(primary, 0.12)
	var last: Vector3 = toward_camera(targets[targets.size() - 1] as Vector3, 0.12)
	var dir := last - start
	if dir.length_squared() < 0.0001:
		dir = flat_dir(primary, first_target) if primary.distance_to(first_target) > 0.01 else Vector3.RIGHT
	dir = dir.normalized()
	var finish_at := last + dir * 0.7
	var span := maxf(0.2, start.distance_to(finish_at))
	var travel := clampf(span / 11.0, 0.12, 0.6)
	var spear := solid("JavelinThrough", crystal_mesh(), {"style": STYLE_FACET, "facet": 0.75})
	var tip := glow_sprite("JavelinThroughTip", start, 0.30, {"core_white": 0.9, "energy": 1.25})
	var trail := streak("JavelinThroughTrail", {"core_white": 0.3})
	track(delay, travel, func(x: float) -> void:
		var pos := start.lerp(finish_at, x)
		orient_along(spear, pos, dir, 1.1, 0.058)
		tip.global_position = pos + dir * 0.55
		place_streak(trail, pos - dir * minf(0.85, span * x), pos - dir * 0.35, 0.09)
		var out := 1.0 - smoothstep(0.82, 1.0, x)
		show_with(spear, 0.96 * out)
		show_with(tip, 0.9 * out)
		show_with(trail, 0.55 * out))
	for i in targets.size():
		var at := toward_camera(targets[i] as Vector3, 0.18)
		var reach := clampf(start.distance_to(at) / span, 0.0, 1.0)
		var slit := streak("PierceWound%d" % i, {"core_white": 0.75})
		var glow := glow_sprite("PierceWoundGlow%d" % i, at, 0.55, {"shape": SHAPE_FLARE, "spin": screen_angle(start, at), "core_white": 0.7})
		track(delay + travel * reach, 0.22, func(x: float) -> void:
			place_streak(slit, at - dir * 0.46, at + dir * lerpf(0.12, 0.58, ease_out(x)), 0.21 * (1.0 - x * 0.6))
			show_with(slit, 0.9 * (1.0 - x))
			glow.scale = Vector3.ONE * lerpf(0.70, 0.34, x)
			show_with(glow, 0.7 * (1.0 - x)))


# ── 霜印使 · 霜印 ────────────────────────────────────────────────────────
# 手上凝出一团蓝光 → 被技能打到的敌人身上短暂结一层冰（冰晶包住身体、脚下一圈霜）
# → 冰碎消散。目标 = 施法这一刻真带 ice_vulnerable 的范围内敌人（BattleVfx 按模拟
# 状态挑选），免疫的不结冰。持续的冰脆状态仍由 StatusVFXController 的图标表达。
func _ice_glow(params: Dictionary) -> Dictionary:
	var p := {"edge": CATALOG.ICE_EDGE, "tint": CATALOG.ICE_TINT, "hot": CATALOG.ICE_HOT, "white_hot": CATALOG.ICE_WHITE}
	p.merge(params, true)
	return p


func _ice_body(params: Dictionary) -> Dictionary:
	var p := {"dark_color": CATALOG.ICE_BODY_DARK, "main_color": CATALOG.ICE_BODY_MAIN, "core_color": CATALOG.ICE_BODY_CORE, "highlight": CATALOG.ICE_WHITE}
	p.merge(params, true)
	return p


func _frost_seal(origin: Vector3, center_body: Vector3, context: Dictionary, delay: float) -> void:
	var h := height_of(context, "target_height")
	var center: Vector3 = context.get("target_foot", center_body + Vector3.DOWN * h * 0.55)
	var radius: Vector2 = context.get("world_radius", Vector2(144.0 * 14.5 * 0.88 / 1000.0, 144.0 * 10.0 * 0.88 / 520.0))
	_debug["world_radius"] = radius
	_debug["center"] = center
	var hand := glow_sprite("FrostHandGlow", toward_camera(origin, 0.12), 0.75, _ice_glow({"core_white": 0.6, "softness": 1.0}))
	var hand_seal := glow_sprite("FrostHandSeal", toward_camera(origin, 0.14), 0.60, _ice_glow({"shape": SHAPE_SEAL, "pattern": 0, "seal_rings": 0.0, "stroke": 0.06, "fill": 0.35, "core_white": 0.5}))
	_follow(weak_node(context.get("origin_node")), origin, [hand, hand_seal])
	track(delay, 0.55, func(x: float) -> void:
		hand.scale = Vector3.ONE * lerpf(0.55, 1.10, ease_out(x))
		show_with(hand, 0.95 * envelope(x, 0.18, 0.45))
		hand_seal.scale = Vector3.ONE * lerpf(0.45, 0.78, ease_out(x))
		set_param(hand_seal, "spin", x * 1.6)
		show_with(hand_seal, 0.85 * envelope(x, 0.2, 0.45)))
	var targets := _capped(context.get("targets", []))
	_debug["targets"] = targets.size()
	if targets.is_empty():
		return
	# 每个目标一簇冰晶围着身体立起（共用一个 MultiMesh），低画质按粒子预算削减。
	var plan: Array[Dictionary] = []
	for value in targets:
		var foot: Vector3 = value
		for k in 5:
			var a := TAU * float(k) / 5.0 + 0.3
			var out := Vector3(cos(a), 0.0, sin(a))
			plan.append({"at": foot + Vector3(out.x * h * 0.17, 0.0, out.z * h * 0.12), "out": out,
				"len": _rng.randf_range(0.55, 0.85) * h, "rad": 0.13 * h})
	var spike_count := mini(plan.size(), QUALITY_BUDGET.particle_count_for(plan.size()))
	_debug["spikes"] = spike_count
	var spikes := MultiMesh.new()
	spikes.transform_format = MultiMesh.TRANSFORM_3D
	spikes.use_colors = true
	spikes.mesh = crystal_mesh()
	spikes.instance_count = maxi(1, spike_count)
	var spike_node := MultiMeshInstance3D.new()
	spike_node.name = "IceEncase"
	spike_node.multimesh = spikes
	spike_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	spike_node.material_override = body_material(_ice_body({"style": STYLE_FACET, "facet": 1.0}))
	spike_node.visible = false
	add_child(spike_node)
	var layout: Array[Dictionary] = []
	for i in spikes.instance_count:
		var item: Dictionary = plan[i]
		var out: Vector3 = item["out"]
		layout.append({"base": item["at"], "up": (Vector3.UP + out * 0.30).normalized(),
			"length": float(item["len"]), "radius": float(item["rad"]), "lag": float(i % 5) * 0.02})
	var mists: Array[MeshInstance3D] = []
	var frosts: Array[MeshInstance3D] = []
	for i in targets.size():
		var foot: Vector3 = targets[i]
		mists.append(glow_sprite("IceMist%d" % i, toward_camera(foot + Vector3.UP * h * 0.5, 0.2), 1.0, _ice_glow({"softness": 1.2, "core_white": 0.4, "edge_dark": 0.2})))
		frosts.append(ground_decal("IceFrost%d" % i, foot + Vector3.UP * 0.02, Vector2(0.42, 0.32) * h, _ice_glow({"ring_radius": 0.80, "ring_width": 0.16, "ticks": 6.0, "fill": 0.55, "breakup": 0.3, "seed": float(i)})))
	var freeze := delay + 0.20
	var hold := 0.72
	track(freeze, hold, func(x: float) -> void:
		var t := x * hold
		for i in layout.size():
			var item: Dictionary = layout[i]
			var grow := ease_out(clampf((t - float(item["lag"])) / 0.12, 0.0, 1.0), 2.5)
			var crumble := smoothstep(0.52, 0.72, t)
			var up: Vector3 = item["up"]
			var side := up.cross(Vector3.FORWARD)
			if side.length_squared() < 0.0001:
				side = Vector3.RIGHT
			side = side.normalized()
			var fwd := side.cross(up).normalized()
			var length := float(item["length"]) * grow * (1.0 - crumble * 0.6)
			var b := Basis(side, up, fwd) * Basis.from_scale(Vector3(float(item["radius"]), maxf(0.001, length), float(item["radius"])))
			var p: Vector3 = (item["base"] as Vector3) + up * length * 0.42
			spikes.set_instance_transform(i, Transform3D(b, spike_node.to_local(p)))
			spikes.set_instance_color(i, Color(1.0, 1.0, 1.0, 1.0 - crumble))
		set_param(spike_node, "flash", 1.0 - smoothstep(0.0, 0.12, t))
		show_with(spike_node, 0.92)
		for i in mists.size():
			mists[i].scale = Vector3.ONE * h * lerpf(0.7, 1.05, ease_out(x))
			show_with(mists[i], 0.75 * envelope(x, 0.08, 0.4))
			frosts[i].scale = Vector3(0.84 * h, 1.0, 0.64 * h) * lerpf(0.7, 1.0, ease_out(x))
			show_with(frosts[i], 0.75 * envelope(x, 0.1, 0.35)))
	var shatter := shard_cloud("IceShatter", QUALITY_BUDGET.particle_count_for(4 * targets.size()), _ice_body({"facet": 1.0}))
	var pieces: Array[Dictionary] = []
	var per := maxi(1, shatter.multimesh.instance_count / targets.size())
	for i in shatter.multimesh.instance_count:
		var foot: Vector3 = targets[mini(i / per, targets.size() - 1)]
		pieces.append_array(scatter(1, foot + Vector3.UP * h * 0.4, Vector3.ZERO, 0.8, 0.9, 1.1))
	track(freeze + 0.52, 0.42, func(x: float) -> void:
		drive_shards(shatter, pieces, x, 0.42, 0.075, 1.0))


# ── 赤灯使 · 全体禁言 ────────────────────────────────────────────────────
# 头顶亮起一盏赤灯 → 一圈流动碎裂、带火星的红色能量光环贴地向外扩散 → 光环扫到
# 被选中的敌人时身上一闪（真被沉默的更亮）。沉默由现有状态图标表达，这里不另画印。
func _lantern_silence(origin: Vector3, context: Dictionary, delay: float) -> void:
	var h := height_of(context, "origin_height")
	var foot: Vector3 = context.get("origin_foot", origin + Vector3.DOWN * h * 0.55)
	var lantern_at := foot + Vector3.UP * h * 1.32
	var halo := glow_sprite("LanternHalo", lantern_at, 1.0, {"softness": 1.2, "core_white": 0.35, "energy": 0.95, "edge_dark": 0.3})
	var core := glow_sprite("LanternCore", lantern_at, 0.34, {"core_white": 0.85, "energy": 1.2})
	var glyph := glow_sprite("LanternGlyph", lantern_at, 0.85, {"shape": SHAPE_SEAL, "pattern": 1, "core_white": 0.5, "stroke": 0.055})
	track(delay, 1.0, func(x: float) -> void:
		var rise := ease_out(minf(1.0, x / 0.25), 2.0)
		var p := lantern_at + Vector3.UP * (rise - 1.0) * h * 0.35
		halo.global_position = p
		core.global_position = p
		glyph.global_position = p + CAMERA_DIR * -0.04
		var flicker := 0.9 + 0.1 * sin(x * 29.0) * sin(x * 11.0 + 0.7)
		var env := envelope(x, 0.12, 0.35)
		show_with(halo, 0.55 * env * flicker)
		show_with(core, 0.95 * env)
		glyph.scale = Vector3.ONE * lerpf(0.50, 0.88, rise)
		set_param(glyph, "spin", x * 0.6)
		show_with(glyph, 0.75 * env))
	var targets := _capped(context.get("targets", []))
	var sealed: Array = context.get("sealed", [])
	_debug["targets"] = targets.size()
	# 光圈半径刚好盖过最远的目标（地面距离），再留一点余量。
	var reach := 1.6
	for value in targets:
		var t_foot: Vector3 = value
		reach = maxf(reach, Vector2(t_foot.x - foot.x, t_foot.z - foot.z).length() + 0.5)
	reach = minf(reach, 8.0)
	_debug["reach"] = reach
	var wave_start := delay + 0.22
	var wave_time := 0.35 + 0.09 * reach
	var power := 1.7
	# 能量光环：环画在贴片 0.8 半径处（留出外圈给环宽，小半径时不被裁成方角）；
	# breakup 让环身碎裂并随时间流动，外加一圈沿环跳动的火星 —— 不是一圈死色。
	var wave := ground_decal("LanternWave", foot + Vector3.UP * 0.03, Vector2.ONE, {"ring_radius": 0.80, "ring_width": 0.06, "fill": 0.0, "breakup": 0.45, "seed": 3.0, "core_white": 0.8, "edge_dark": 0.15, "energy": 1.1})
	# 光环外侧一层宽而淡的辉光，让环身像在发光而不是一条实线。
	var echo := ground_decal("LanternWaveGlow", foot + Vector3.UP * 0.025, Vector2.ONE, {"ring_radius": 0.80, "ring_width": 0.12, "breakup": 0.3, "seed": 7.0, "core_white": 0.2, "edge_dark": 0.0, "edge": CATALOG.MAIN, "tint": CATALOG.CORE})
	track(wave_start, wave_time, func(x: float) -> void:
		var r := lerpf(0.25, reach, ease_out(x, power))
		var pulse := 1.0 + 0.25 * sin(x * 40.0)
		wave.scale = Vector3(r * 2.5, 1.0, r * 2.5)
		set_param(wave, "ring_width", clampf(0.20 / r, 0.03, 0.16) * pulse)
		show_with(wave, 0.92 * smoothstep(0.0, 0.06, x) * (1.0 - smoothstep(0.75, 1.0, x))))
	track(wave_start, wave_time, func(x: float) -> void:
		var r := lerpf(0.25, reach, ease_out(x, power))
		echo.scale = Vector3(r * 2.5, 1.0, r * 2.5)
		set_param(echo, "ring_width", clampf(0.55 / r, 0.05, 0.19))
		show_with(echo, 0.32 * smoothstep(0.0, 0.08, x) * (1.0 - smoothstep(0.6, 1.0, x))))
	# 沿环跳动的火星：随光环外扩，各自上飘、闪烁。
	var spark_count := QUALITY_BUDGET.particle_count_for(16)
	var sparks: Array[MeshInstance3D] = []
	var spark_angles: Array[float] = []
	for k in spark_count:
		sparks.append(glow_sprite("LanternWaveSpark%d" % k, foot, 0.3, {"shape": SHAPE_FLARE, "core_white": 0.6, "energy": 1.1, "edge_dark": 0.2}))
		spark_angles.append(_rng.randf() * TAU)
	track(wave_start, wave_time, func(x: float) -> void:
		var r := lerpf(0.25, reach, ease_out(x, power))
		for k in sparks.size():
			var a := spark_angles[k] + x * 0.6
			var lift := absf(sin(x * 14.0 + float(k) * 1.7)) * 0.30 + 0.08
			sparks[k].global_position = foot + Vector3(cos(a) * r, lift, sin(a) * r)
			sparks[k].scale = Vector3.ONE * (0.30 + 0.18 * absf(sin(x * 23.0 + float(k))))
			show_with(sparks[k], 0.9 * smoothstep(0.0, 0.08, x) * (1.0 - smoothstep(0.7, 1.0, x))))
	# 光扫到目标的那一刻在身上一闪（真被沉默的更亮）；沉默本身交给现有状态图标，不另画印。
	_debug["silenced_flashes"] = 0
	for i in targets.size():
		var target_foot: Vector3 = targets[i]
		var distance := Vector2(target_foot.x - foot.x, target_foot.z - foot.z).length()
		var u := clampf((distance - 0.25) / maxf(0.01, reach - 0.25), 0.0, 1.0)
		var reached := wave_start + wave_time * (1.0 - pow(1.0 - u, 1.0 / power))
		var is_sealed := i < sealed.size() and bool(sealed[i])
		if is_sealed:
			_debug["silenced_flashes"] = int(_debug["silenced_flashes"]) + 1
		var touch := glow_sprite("LanternTouch%d" % i, toward_camera(target_foot + Vector3.UP * h * 0.5, 0.12), 0.9, {"softness": 1.2, "core_white": 0.55 if is_sealed else 0.3, "edge_dark": 0.3})
		track(reached, 0.32, func(x: float) -> void:
			touch.scale = Vector3.ONE * h * lerpf(0.6, 1.05, ease_out(x))
			show_with(touch, (0.8 if is_sealed else 0.35) * (1.0 - x)))


# ── 网格 ─────────────────────────────────────────────────────────────────

# 放射状折线裂纹，位于 XY 平面，半径 1。顶点色 r = 热度（中心最热）。
func _crack_mesh(lines: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for line in lines:
		var angle := TAU * float(line) / float(lines) + _rng.randf_range(-0.25, 0.25)
		var points: Array[Vector2] = [Vector2.ZERO]
		var length := _rng.randf_range(0.65, 1.0)
		for k in 4:
			var t := float(k + 1) / 4.0
			var jitter := _rng.randf_range(-0.22, 0.22) * t
			points.append(Vector2(cos(angle + jitter), sin(angle + jitter)) * length * t)
		for k in points.size() - 1:
			var a: Vector2 = points[k]
			var b: Vector2 = points[k + 1]
			var t0 := float(k) / float(points.size() - 1)
			var t1 := float(k + 1) / float(points.size() - 1)
			var side := (b - a).orthogonal().normalized()
			var w0 := 0.05 * (1.0 - t0 * 0.8)
			var w1 := 0.05 * (1.0 - t1 * 0.8)
			var quad := [a - side * w0, b - side * w1, b + side * w1, a - side * w0, b + side * w1, a + side * w0]
			var heat := [1.0 - t0, 1.0 - t1, 1.0 - t1, 1.0 - t0, 1.0 - t1, 1.0 - t0]
			for j in 6:
				var v: Vector2 = quad[j]
				st.set_normal(Vector3.BACK)
				st.set_color(Color(float(heat[j]), 1.0, 1.0, 0.35 + 0.65 * float(heat[j])))
				st.set_uv(Vector2(0.0, 0.0))
				st.add_vertex(Vector3(v.x, v.y, 0.0))
	return st.commit()
