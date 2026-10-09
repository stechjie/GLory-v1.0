extends "res://effects/vfx3d/units/VFXCrimsonKit3D.gd"
class_name VFXCrimsonAttack3D

# 赤律族普攻。正式路由：
#   Director attack_start / projectile_spawn → BattleVfx.cue_play_basic_attack
#   → basic_attack_{melee|ranged}_crimson → UnitSkillVFXComposer3D._crimson_basic_attack
#   → 本模块 play_attack()。
#
# 远程五个单位各有专属弹体（CrimsonVFXCatalog.PROJECTILES），飞行时长与
# BattleVfx.cue_ranged_flight_time() 共用 CrimsonVFXCatalog.flight_time()，
# 所以伤害数字落在弹体到达的同一刻。近战只给招牌武器（战鼓 / 巨锤）。
# 纯表现：不读写模拟状态、不消耗 RngService。

var _mode := "ranged"
var _unit_id := ""
var _kind := ""
var _origin := Vector3.ZERO
var _target := Vector3.ZERO
var _target_ref: WeakRef
var _target_offset := Vector3.ZERO
var _flight := 0.0
var _flight_time := 0.4
var _arc := 0.0
var _in_flight := false
var _body_nodes: Array[GeometryInstance3D] = []
var _trail_nodes: Array[GeometryInstance3D] = []
var _trail_clock := 0.0
var _trail_index := 0
var _tracer: MeshInstance3D
var _spin := 0.0
var _height := UNIT_HEIGHT
var _target_foot := Vector3.ZERO
var _origin_height := UNIT_HEIGHT


func play_attack(origin: Vector3, target: Vector3, context: Dictionary) -> void:
	_mode = str(context.get("mode", "ranged"))
	_unit_id = str(context.get("source_unit_id", ""))
	_origin = origin
	_target = target
	_height = height_of(context, "target_height")
	_origin_height = height_of(context, "origin_height")
	_target_foot = context.get("target_foot", target + Vector3.DOWN * _height * 0.55)
	_target_ref = weak_node(context.get("target_node"))
	if _target_ref != null:
		_target_offset = target - node_position(_target_ref, target)
	begin_kit(int(absf(origin.x * 131.0 + target.z * 71.0)) + 1)
	if _mode == "melee":
		_kind = CATALOG.melee_kind_for(_unit_id)
		match _kind:
			"drum_shock":
				_drum_shock()
			"hammer_smash":
				_hammer_smash()
			_:
				# 赤卫等非招牌近战：与其它玩家近战棋子同一规则，不画通用刀光。
				finish()
		return
	var spec := CATALOG.projectile_for(_unit_id)
	_kind = str(spec.get("kind", "blood_arrow"))
	_arc = float(spec.get("arc", 0.0))
	_flight_time = CATALOG.flight_time(_ground_distance(_origin, _live_target()), _unit_id)
	_build_projectile()
	_in_flight = true
	keep_alive_until(_flight_time + 0.05)


func get_debug_state() -> Dictionary:
	return {"mode": _mode, "unit_id": _unit_id, "kind": _kind, "flight_time": _flight_time,
		"in_flight": _in_flight, "children": get_child_count()}


static func _ground_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


func _custom_done() -> bool:
	return not _in_flight


func _live_target() -> Vector3:
	if _target_ref == null:
		return _target
	return node_position(_target_ref, _target - _target_offset) + _target_offset


# ── 远程弹体 ─────────────────────────────────────────────────────────────

func _build_projectile() -> void:
	var trail_count := QUALITY_BUDGET.auxiliary_layers_for(3) + 1
	match _kind:
		"petal_blade":
			# 赤舞者：两片交叉旋转的绯色花刃 + 内核。
			_body_nodes.append(glow_sprite("PetalBladeA", _origin, 0.62, {"shape": SHAPE_RING, "ring_radius": 0.62, "ring_width": 0.34, "arc_span": 0.38, "core_white": 0.55, "edge_dark": 0.7}))
			_body_nodes.append(glow_sprite("PetalBladeB", _origin, 0.62, {"shape": SHAPE_RING, "ring_radius": 0.62, "ring_width": 0.34, "arc_span": 0.38, "arc_start": PI, "core_white": 0.55, "edge_dark": 0.7}))
			_body_nodes.append(glow_sprite("PetalCore", _origin, 0.24, {"core_white": 0.85, "energy": 1.1}))
			for i in trail_count:
				_trail_nodes.append(glow_sprite("PetalGhost%d" % i, _origin, 0.50, {"shape": SHAPE_RING, "ring_radius": 0.62, "ring_width": 0.28, "arc_span": 0.32, "core_white": 0.2, "edge_dark": 0.7}))
		"blood_arrow":
			# 血猎者：细长血色箭杆 + 白热箭尖 + 长拖尾。
			var shaft := solid("BloodArrowShaft", crystal_mesh(), {"style": STYLE_FACET, "facet": 0.8})
			_body_nodes.append(shaft)
			_body_nodes.append(glow_sprite("BloodArrowTip", _origin, 0.28, {"core_white": 0.9, "energy": 1.2}))
			_tracer = streak("BloodArrowTrail", {"core_white": 0.25})
		"frost_shard":
			# 霜印使：旋转的六棱冰晶，赤红晶体 + 冷白棱光。
			var crystal := solid("FrostShard", crystal_mesh(), {"style": STYLE_FACET, "facet": 1.0, "highlight": CATALOG.FROST_GLINT})
			_body_nodes.append(crystal)
			_body_nodes.append(glow_sprite("FrostShardGlow", _origin, 0.44, {"core_white": 0.45, "energy": 0.9, "white_hot": CATALOG.FROST_GLINT}))
			for i in trail_count:
				_trail_nodes.append(glow_sprite("FrostSparkle%d" % i, _origin, 0.22, {"shape": SHAPE_FLARE, "core_white": 0.9, "white_hot": CATALOG.FROST_GLINT}))
		"javelin":
			# 穿云弩手：掷出一支赤红标枪（细长枪身 + 白热枪尖 + 短尾迹），带一点抛物线。
			var spear := solid("Javelin", crystal_mesh(), {"style": STYLE_FACET, "facet": 0.75})
			_body_nodes.append(spear)
			_body_nodes.append(glow_sprite("JavelinTip", _origin, 0.30, {"core_white": 0.9, "energy": 1.25}))
			_tracer = streak("JavelinTrail", {"core_white": 0.3})
		_:
			# 赤灯使：灯火余烬，外焰柔光 + 跳动内核 + 上飘火星。
			_body_nodes.append(glow_sprite("LanternEmberHalo", _origin, 0.62, {"softness": 1.3, "energy": 0.95, "core_white": 0.3, "edge_dark": 0.3}))
			_body_nodes.append(glow_sprite("LanternEmberCore", _origin, 0.30, {"core_white": 0.85, "energy": 1.2}))
			for i in trail_count + 1:
				_trail_nodes.append(glow_sprite("LanternSpark%d" % i, _origin, 0.11, {"core_white": 0.7}))
	for node in _trail_nodes:
		node.set_meta("age", 99.0)


func _advance_custom(delta: float) -> void:
	if not _in_flight:
		return
	_flight += delta
	_spin += delta
	var x := clampf(_flight / _flight_time, 0.0, 1.0)
	var target := _live_target()
	var dir := (target - _origin)
	if dir.length_squared() < 0.000001:
		dir = Vector3.RIGHT
	var pos := _origin.lerp(target, x) + Vector3.UP * _arc * sin(x * PI) + CAMERA_DIR * 0.10
	var screen := screen_angle(_origin, target)
	var appear := smoothstep(0.0, 0.08, x)
	match _kind:
		"petal_blade":
			for i in 3:
				_body_nodes[i].global_position = pos
			set_param(_body_nodes[0], "spin", _spin * 17.0)
			set_param(_body_nodes[1], "spin", _spin * 17.0)
			show_with(_body_nodes[0], 0.95 * appear)
			show_with(_body_nodes[1], 0.95 * appear)
			show_with(_body_nodes[2], 0.85 * appear)
		"blood_arrow", "javelin":
			var length := 0.66 if _kind == "blood_arrow" else 1.1
			var radius := 0.040 if _kind == "blood_arrow" else 0.058
			# 标枪沿抛物线切线方向转头。
			var heading := (dir + Vector3.UP * _arc * PI * cos(x * PI)).normalized()
			var shaft := _body_nodes[0] as Node3D
			orient_along(shaft, pos, heading, length, radius)
			show_with(_body_nodes[0], 0.96 * appear)
			_body_nodes[1].global_position = pos + heading * length * 0.55
			show_with(_body_nodes[1], 0.9 * appear)
			if _tracer != null:
				var tail := pos - heading * (0.95 if _kind == "blood_arrow" else 0.85)
				tail = tail.lerp(pos, 1.0 - minf(1.0, x * 3.0))
				place_streak(_tracer, tail, pos - heading * length * 0.35, 0.11 if _kind == "blood_arrow" else 0.09)
				show_with(_tracer, 0.55 * appear)
		"frost_shard":
			var crystal := _body_nodes[0] as Node3D
			orient_along(crystal, pos, dir.normalized(), 0.48, 0.12, _spin * 9.0)
			show_with(_body_nodes[0], 0.97 * appear)
			_body_nodes[1].global_position = pos
			show_with(_body_nodes[1], 0.55 * appear)
		_:
			var flicker := 0.85 + 0.15 * sin(_spin * 31.0) * sin(_spin * 13.0 + 1.3)
			_body_nodes[0].global_position = pos
			_body_nodes[1].global_position = pos
			show_with(_body_nodes[0], 0.85 * appear * flicker)
			show_with(_body_nodes[1], 0.95 * appear)
			set_param(_body_nodes[1], "energy", 1.05 + 0.25 * flicker)
	_update_trail(delta, pos, dir.normalized(), screen)
	if x >= 1.0:
		_in_flight = false
		for node in _body_nodes:
			node.visible = false
		if _tracer != null:
			_tracer.visible = false
		_impact(target + CAMERA_DIR * 0.18, dir.normalized(), screen)


func _update_trail(delta: float, pos: Vector3, dir: Vector3, screen: float) -> void:
	if _trail_nodes.is_empty():
		return
	_trail_clock += delta
	var interval := 0.05 if _kind == "lantern_ember" else 0.06
	if _trail_clock >= interval:
		_trail_clock = 0.0
		var node := _trail_nodes[_trail_index % _trail_nodes.size()]
		_trail_index += 1
		node.set_meta("age", 0.0)
		node.global_position = pos - dir * 0.04
		node.set_meta("spin", _spin * 17.0)
	for node in _trail_nodes:
		var age := float(node.get_meta("age", 99.0)) + delta
		node.set_meta("age", age)
		var life := 0.26 if _kind == "lantern_ember" else 0.18
		var k := clampf(age / life, 0.0, 1.0)
		if k >= 1.0:
			node.visible = false
			continue
		match _kind:
			"petal_blade":
				set_param(node, "spin", float(node.get_meta("spin", 0.0)))
				show_with(node, 0.45 * (1.0 - k))
			"frost_shard":
				node.scale = Vector3.ONE * (0.22 * (1.0 - k * 0.5))
				show_with(node, 0.8 * (1.0 - k))
			_:
				node.global_position += Vector3.UP * delta * 0.55
				show_with(node, 0.85 * (1.0 - k))


func _impact(at: Vector3, dir: Vector3, screen: float) -> void:
	var t0 := elapsed()
	match _kind:
		"petal_blade":
			var pop := glow_sprite("PetalPop", at, 0.70, {"core_white": 0.6})
			var ring := glow_sprite("PetalRing", at, 0.60, {"shape": SHAPE_RING, "ring_radius": 0.7, "ring_width": 0.18, "breakup": 0.6, "seed": 2.0})
			var petals := shard_cloud("PetalFlecks", QUALITY_BUDGET.particle_count_for(7), {"facet": 0.9})
			var flecks := scatter(petals.multimesh.instance_count, at, dir, 0.9, 0.6, 1.0)
			track(t0, 0.22, func(x: float) -> void:
				pop.scale = Vector3.ONE * lerpf(0.40, 0.80, ease_out(x))
				show_with(pop, 0.95 * (1.0 - x * x)))
			track(t0, 0.30, func(x: float) -> void:
				ring.scale = Vector3.ONE * lerpf(0.36, 1.05, ease_out(x))
				show_with(ring, 0.8 * (1.0 - x)))
			track(t0, 0.42, func(x: float) -> void:
				drive_shards(petals, flecks, x, 0.42, 0.08, 0.5))
		"blood_arrow":
			var flare := glow_sprite("BloodArrowFlare", at, 0.62, {"shape": SHAPE_FLARE, "spin": screen, "core_white": 0.8})
			var spikes: Array[MeshInstance3D] = []
			for i in 3:
				spikes.append(streak("BloodSpike%d" % i, {"core_white": 0.3}))
			track(t0, 0.18, func(x: float) -> void:
				flare.scale = Vector3.ONE * lerpf(0.72, 0.34, x)
				show_with(flare, 0.95 * (1.0 - x)))
			track(t0, 0.20, func(x: float) -> void:
				for i in spikes.size():
					var spread := (float(i) - 1.0) * 0.55
					var d := (dir.rotated(Vector3.UP, spread) + Vector3.UP * 0.25).normalized()
					place_streak(spikes[i], at, at + d * lerpf(0.10, 0.42, ease_out(x)), 0.075)
					show_with(spikes[i], 0.85 * (1.0 - x)))
		"frost_shard":
			var glow := glow_sprite("FrostImpactGlow", at, 0.62, {"core_white": 0.55, "white_hot": CATALOG.FROST_GLINT})
			var ring := glow_sprite("FrostImpactRing", at, 0.60, {"shape": SHAPE_RING, "ring_radius": 0.72, "ring_width": 0.14, "ticks": 6.0, "white_hot": CATALOG.FROST_GLINT})
			var shards := shard_cloud("FrostSplinters", QUALITY_BUDGET.particle_count_for(8), {"facet": 1.0, "highlight": CATALOG.FROST_GLINT})
			var pieces := scatter(shards.multimesh.instance_count, at, dir, 0.8, 0.9, 1.1)
			track(t0, 0.22, func(x: float) -> void:
				glow.scale = Vector3.ONE * lerpf(0.46, 0.76, ease_out(x))
				show_with(glow, 0.85 * (1.0 - x)))
			track(t0, 0.32, func(x: float) -> void:
				ring.scale = Vector3.ONE * lerpf(0.36, 0.95, ease_out(x))
				show_with(ring, 0.75 * (1.0 - x)))
			track(t0, 0.46, func(x: float) -> void:
				drive_shards(shards, pieces, x, 0.46, 0.085, 0.8))
		"javelin":
			var pierce := streak("JavelinImpactStreak", {"core_white": 0.7})
			var flare := glow_sprite("JavelinImpactFlare", at, 0.62, {"shape": SHAPE_FLARE, "spin": screen, "core_white": 0.85})
			track(t0, 0.16, func(x: float) -> void:
				place_streak(pierce, at - dir * 0.48, at + dir * lerpf(0.16, 0.66, ease_out(x)), 0.17 * (1.0 - x * 0.6))
				show_with(pierce, 0.9 * (1.0 - x))
				show_with(flare, 0.9 * (1.0 - x)))
		_:
			var bloom := glow_sprite("LanternBloom", at, 0.78, {"softness": 1.2, "core_white": 0.55, "edge_dark": 0.3})
			var ring := glow_sprite("LanternBloomRing", at, 0.60, {"shape": SHAPE_RING, "ring_radius": 0.70, "ring_width": 0.16, "breakup": 0.4, "seed": 5.0})
			var sparks: Array[MeshInstance3D] = []
			for i in 4:
				sparks.append(glow_sprite("LanternBloomSpark%d" % i, at, 0.10, {"core_white": 0.8}))
			track(t0, 0.26, func(x: float) -> void:
				bloom.scale = Vector3.ONE * lerpf(0.46, 0.86, ease_out(x))
				show_with(bloom, 0.8 * (1.0 - x))
				ring.scale = Vector3.ONE * lerpf(0.34, 0.92, ease_out(x))
				show_with(ring, 0.6 * (1.0 - x)))
			track(t0, 0.48, func(x: float) -> void:
				for i in sparks.size():
					var a := TAU * float(i) / float(sparks.size()) + 0.4
					sparks[i].global_position = at + Vector3(cos(a) * 0.22 * x, 0.50 * x, sin(a) * 0.10 * x)
					show_with(sparks[i], 0.9 * (1.0 - x)))
	keep_alive_until(t0 + 0.5)


# ── 招牌近战 ─────────────────────────────────────────────────────────────

# 战鼓使：每次出手，从鼓手身上朝不同方向甩出几条红色「五线谱丝带」—— 五条
# 平行谱线组成的飘带呈 S 形向外飘，带上坐着跳动的音符，尾部散落碎点，边飘边散
# （参考：音符缠绕的谱线飘带）。不画圆环。鼓点层数已有头顶音符徽章表达，
# 这里只负责「鼓声」，不画命中刀光。
const STAFF_SEGMENTS := 20
const STAFF_LINES := 5

func _drum_shock() -> void:
	var h := _origin_height
	var body := toward_camera(_origin, 0.10)
	var thump := glow_sprite("DrumThump", body, 0.6, {"softness": 1.1, "core_white": 0.45})
	track(0.02, 0.18, func(x: float) -> void:
		thump.scale = Vector3.ONE * lerpf(0.40, 0.75, ease_out(x))
		show_with(thump, 0.7 * (1.0 - x)))
	var count := 2 if QUALITY_BUDGET.auxiliary_layers_for(2) >= 2 else 1
	var notes_per := 3
	# 一条往左上、一条往右上甩（往下的会被鼓手身体挡住），再加一点随机。
	var base_angle := (PI * 0.62 if _rng.randf() < 0.5 else PI * 0.38) + _rng.randf_range(-0.25, 0.25)
	for i in count:
		var angle := base_angle + (PI * 0.55 if base_angle > PI * 0.5 else -PI * 0.55) * float(i) * -1.0 + _rng.randf_range(-0.2, 0.2)
		var dir := (Vector3.RIGHT * cos(angle) + SCREEN_UP * sin(angle)).normalized()
		var side := (Vector3.RIGHT * -sin(angle) + SCREEN_UP * cos(angle)).normalized()
		var staff := _ribbon_node("DrumStaff%d" % i)
		var phase := _rng.randf() * TAU
		var reach := _rng.randf_range(1.6, 2.1) * h
		var sway := (0.30 if i % 2 == 0 else -0.30) * h
		var notes: Array[MeshInstance3D] = []
		var note_at: Array[float] = []
		var note_line: Array[float] = []
		for k in notes_per:
			notes.append(glow_sprite("DrumNote%d_%d" % [i, k], body, 0.24, {"shape": SHAPE_SEAL, "pattern": 4, "seal_rings": 0.0, "fill": 0.0, "stroke": 0.06, "core_white": 0.25, "edge_dark": 0.7}))
			note_at.append(0.30 + 0.6 * float(k) / float(maxi(1, notes_per - 1)) + _rng.randf_range(-0.05, 0.05))
			note_line.append(_rng.randf_range(-0.6, 0.6))
		var lag := 0.03 + 0.08 * float(i)
		track(lag, 0.80, func(x: float) -> void:
			var head := 0.22 * h + ease_out(x, 1.7) * reach
			var tail := maxf(0.10 * h, head - 1.45 * h)
			var spread := 0.26 * h * (0.8 + 0.4 * x)
			var drift := phase - x * 7.0
			_draw_staff(staff, body, dir, side, tail, head, sway, drift, spread, 0.017 * h)
			var fade := smoothstep(0.0, 0.08, x) * (1.0 - smoothstep(0.55, 1.0, x))
			show_with(staff, 0.9 * fade)
			for k in notes.size():
				var sk := note_at[k]
				var c := _staff_center(body, dir, side, tail, head, sway, drift, sk)
				var n := _staff_normal(body, dir, side, tail, head, sway, drift, sk)
				var hop := absf(sin(x * 16.0 + float(k) * 1.9)) * 0.05 * h
				notes[k].global_position = c + n * (note_line[k] * spread * 0.5 + hop)
				notes[k].scale = Vector3.ONE * 0.32 * h
				set_param(notes[k], "spin", 0.3 * sin(x * 10.0 + float(k)))
				show_with(notes[k], 0.95 * fade))
		# 尾部散落的碎点（一个 MultiMesh）。
		var dust := shard_cloud("DrumDust%d" % i, QUALITY_BUDGET.particle_count_for(8), {"facet": 0.4})
		var specks := scatter(dust.multimesh.instance_count, body + dir * 0.35 * h, dir, 0.9, 0.25, 0.6)
		track(lag + 0.10, 0.65, func(x: float) -> void:
			drive_shards(dust, specks, x, 0.65, 0.05, 0.15))


func _staff_center(origin: Vector3, dir: Vector3, side: Vector3, tail: float, head: float, sway: float, drift: float, s: float) -> Vector3:
	var d := lerpf(tail, head, s)
	# S 形：沿途约 3/4 周期的摆动，越往外摆得越开。
	return origin + dir * d + side * sin(s * TAU * 0.75 + drift) * sway * (0.4 + 0.6 * s)


func _staff_normal(origin: Vector3, dir: Vector3, side: Vector3, tail: float, head: float, sway: float, drift: float, s: float) -> Vector3:
	var a := _staff_center(origin, dir, side, tail, head, sway, drift, maxf(0.0, s - 0.02))
	var b := _staff_center(origin, dir, side, tail, head, sway, drift, minf(1.0, s + 0.02))
	var n := (b - a).cross(CAMERA_DIR)
	return n.normalized() if n.length_squared() > 0.0000001 else side


# 可每帧重画、正对镜头的网格（ImmediateMesh + 光层 shader 的 streak 形状：
# UV.x 从尾 0 到头 1，头亮尾淡；UV.y 横跨每条线）。
func _ribbon_node(label: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = ImmediateMesh.new()
	node.material_override = glow_material({"billboard": 0.0, "shape": SHAPE_STREAK, "core_white": 0.3, "edge_dark": 0.25})
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.top_level = true
	node.visible = false
	add_child(node)
	node.global_transform = Transform3D.IDENTITY
	return node


# 五条平行谱线，沿 S 形中心线、按局部法线等距排开。
func _draw_staff(node: MeshInstance3D, origin: Vector3, dir: Vector3, side: Vector3, tail: float, head: float, sway: float, drift: float, spread: float, line_width: float) -> void:
	var mesh := node.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var centers: Array[Vector3] = []
	var normals: Array[Vector3] = []
	for k in STAFF_SEGMENTS + 1:
		var s := float(k) / float(STAFF_SEGMENTS)
		centers.append(_staff_center(origin, dir, side, tail, head, sway, drift, s))
		normals.append(_staff_normal(origin, dir, side, tail, head, sway, drift, s))
	for line in STAFF_LINES:
		var offset := (float(line) / float(STAFF_LINES - 1) - 0.5) * spread
		for k in STAFF_SEGMENTS:
			var s0 := float(k) / float(STAFF_SEGMENTS)
			var s1 := float(k + 1) / float(STAFF_SEGMENTS)
			var p0: Vector3 = centers[k] + normals[k] * offset
			var p1: Vector3 = centers[k + 1] + normals[k + 1] * offset
			var w0: Vector3 = normals[k] * line_width
			var w1: Vector3 = normals[k + 1] * line_width
			mesh.surface_set_uv(Vector2(s0, 0.0)); mesh.surface_add_vertex(p0 - w0)
			mesh.surface_set_uv(Vector2(s1, 0.0)); mesh.surface_add_vertex(p1 - w1)
			mesh.surface_set_uv(Vector2(s1, 1.0)); mesh.surface_add_vertex(p1 + w1)
			mesh.surface_set_uv(Vector2(s0, 0.0)); mesh.surface_add_vertex(p0 - w0)
			mesh.surface_set_uv(Vector2(s1, 1.0)); mesh.surface_add_vertex(p1 + w1)
			mesh.surface_set_uv(Vector2(s0, 1.0)); mesh.surface_add_vertex(p0 + w0)
	mesh.surface_end()


# 破甲者：自上而下的重锤弧 → 命中白热闪 → 地面碎裂环 → 甩出的碎甲块。
func _hammer_smash() -> void:
	var hit := toward_camera(_target, 0.18)
	var foot: Vector3 = _target_foot
	var screen := screen_angle(_origin, _target)
	# 过顶砸击：弧心偏向攻击者一侧的上方。
	var arc_center := PI * 0.5 + (0.45 if cos(screen) >= 0.0 else -0.45)
	var swing := glow_sprite("HammerSwingArc", hit + SCREEN_UP * 0.16, 1.3, {"shape": SHAPE_RING, "ring_radius": 0.60, "ring_width": 0.30, "arc_span": 0.30, "arc_start": arc_center, "core_white": 0.45, "edge_dark": 0.75})
	var flare := glow_sprite("HammerImpactFlare", hit, 0.90, {"shape": SHAPE_FLARE, "spin": 0.4, "core_white": 0.9})
	var crack := ground_decal("HammerGroundCrack", foot + Vector3.UP * 0.02, Vector2(0.72, 0.54), {"ring_radius": 0.72, "ring_width": 0.17, "breakup": 0.85, "ticks": 9.0, "seed": 4.0, "fill": 0.6})
	var chunks := shard_cloud("HammerChunks", QUALITY_BUDGET.particle_count_for(7), {"facet": 0.7})
	var pieces := scatter(chunks.multimesh.instance_count, hit, flat_dir(_origin, _target), 0.7, 1.4, 1.2)
	track(0.0, 0.12, func(x: float) -> void:
		swing.scale = Vector3.ONE * lerpf(0.95, 1.30, ease_out(x))
		show_with(swing, 0.9 * smoothstep(0.0, 0.4, x)))
	track(0.12, 0.16, func(x: float) -> void:
		show_with(swing, 0.9 * (1.0 - x)))
	track(0.10, 0.18, func(x: float) -> void:
		flare.scale = Vector3.ONE * lerpf(1.05, 0.50, x)
		show_with(flare, 1.0 - x))
	track(0.10, 0.48, func(x: float) -> void:
		crack.scale = Vector3(lerpf(0.5, 1.0, ease_out(x)) * 1.44, 1.0, lerpf(0.5, 1.0, ease_out(x)) * 1.08)
		show_with(crack, 0.8 * envelope(x, 0.08, 0.6)))
	track(0.10, 0.50, func(x: float) -> void:
		drive_shards(chunks, pieces, x, 0.50, 0.12, 1.0))
