extends "res://effects/vfx3d/units/VFXCrimsonKit3D.gd"
class_name VFXHeroSkill3D

# 三位传说棋子的技能表现（与赤律族共用一套光层 / 实体 shader 与时间轴工具，只换配色）：
#
#   black_hole                 黑龙  skill_ready 上升沿。模拟器记录的「被拉的人」逐个画：
#                                    贴地引力漩涡（半径 = 数据 220）→ 外圈向内收缩 → 每个
#                                    被拉者从旧位置拖出一道残影 + 暗色牵引触须 → 落地受击 →
#                                    奇点坍缩。被拉者脚下的引力锁环持续到真实眩晕时长。
#   global_divine_blast        神王  skill_ready 上升沿。头顶金色日轮法印 → 每个记录目标
#                                    一颗带粒子拖尾的能量光弹弧线飞去 → 命中爆闪 + 火花 →
#                                    目标身上留绕身能量光点（覆盖 5 跳伤害的 2 秒）。
#                                    不画任何竖直光柱。
#   global_divine_blast_pulse  神王  后续每跳伤害（hit_number，skill_id 相同）的小脉冲。
#   unique_death_execute       母灵  mother_execute 事件。头顶一本立体的书：封面翻开 →
#                                    书页连续翻动 → 目标头顶落「亡魂之眼」→ 魂火飞回书里 →
#                                    合书。Boss = 重击（不吸魂），无目标 = 空翻一遍后熄灭。
#
# 纯表现：不读写模拟状态、不消耗 RngService（装饰随机走 Kit 的独立 RNG）。

const PAGE_SHADER := preload("res://effects/vfx3d/shaders/hero_book_page.gdshader")

const DARK_PALETTE := {
	"edge": Color(0.10, 0.0, 0.20),
	"tint": Color(0.42, 0.06, 0.78),
	"hot": Color(0.80, 0.42, 1.0),
	"white_hot": Color(0.96, 0.88, 1.0),
}
const DARK_BODY := {
	"dark_color": Color(0.03, 0.0, 0.06),
	"main_color": Color(0.20, 0.04, 0.36),
	"core_color": Color(0.62, 0.30, 0.92),
	"highlight": Color(0.92, 0.80, 1.0),
}
const GOLD_PALETTE := {
	"edge": Color(0.52, 0.20, 0.0),
	"tint": Color(1.0, 0.56, 0.04),
	"hot": Color(1.0, 0.86, 0.32),
	"white_hot": Color(1.0, 0.99, 0.90),
}
const SOUL_PALETTE := {
	"edge": Color(0.0, 0.16, 0.10),
	"tint": Color(0.02, 0.62, 0.40),
	"hot": Color(0.40, 1.0, 0.66),
	"white_hot": Color(0.88, 1.0, 0.94),
}
const SOUL_BODY := {
	"dark_color": Color(0.0, 0.08, 0.06),
	"main_color": Color(0.06, 0.40, 0.30),
	"core_color": Color(0.40, 0.95, 0.70),
	"highlight": Color(0.88, 1.0, 0.94),
}

var _skill := ""
var _palette: Dictionary = DARK_PALETTE
var _ribbons: Array[Dictionary] = []
var _debug: Dictionary = {}


func play_hero_skill(skill_id: String, origin: Vector3, target: Vector3, context: Dictionary = {}) -> void:
	_skill = skill_id
	begin_kit(int(absf(origin.x * 89.0 + target.z * 61.0 + float(skill_id.length()) * 7.0)) + 11)
	_debug = {}
	match skill_id:
		"black_hole":
			_palette = DARK_PALETTE
			_black_hole(origin, context)
		"global_divine_blast":
			_palette = GOLD_PALETTE
			_divine_blast(origin, target, context)
		"global_divine_blast_pulse":
			_palette = GOLD_PALETTE
			_divine_pulse(target, context)
		"unique_death_execute":
			_palette = SOUL_PALETTE
			_death_book(origin, target, context)
		_:
			finish()


func get_debug_state() -> Dictionary:
	var state := {"skill": _skill, "children": get_child_count(), "end_time": _end_time}
	state.merge(_debug, true)
	return state


# ── 小工具 ───────────────────────────────────────────────────────────────

func _p(params: Dictionary) -> Dictionary:
	var out := _palette.duplicate()
	out.merge(params, true)
	return out


func g(label: String, at: Vector3, size: float, params: Dictionary = {}) -> MeshInstance3D:
	return glow_sprite(label, at, size, _p(params))


func gd(label: String, center: Vector3, radii: Vector2, params: Dictionary = {}) -> MeshInstance3D:
	return ground_decal(label, center, radii, _p(params))


# 一团发光粒子：MultiMesh 上每个实例都是一张面向镜头的光片（glow shader 的 billboard
# 读的是含实例变换的 MODEL_MATRIX），实例色的 alpha 当单颗粒子的不透明度。
func motes(label: String, count: int, params: Dictionary = {}) -> MultiMeshInstance3D:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.mesh = _quad
	multi.instance_count = maxi(1, count)
	var node := MultiMeshInstance3D.new()
	node.name = label
	node.multimesh = multi
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var p := {"billboard": 1.0, "shape": SHAPE_GLOW, "softness": 0.6, "core_white": 0.7}
	p.merge(params, true)
	node.material_override = glow_material(_p(p))
	node.visible = false
	add_child(node)
	for i in multi.instance_count:
		multi.set_instance_color(i, Color(1, 1, 1, 0))
	return node


static func set_mote(node: MultiMeshInstance3D, i: int, at: Vector3, size: float, alpha: float) -> void:
	if node == null or not is_instance_valid(node) or i >= node.multimesh.instance_count:
		return
	node.multimesh.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(size, size, 1.0)), node.to_local(at)))
	node.multimesh.set_instance_color(i, Color(1, 1, 1, clampf(alpha, 0.0, 1.0)))


static func ease_in(x: float, power: float = 2.0) -> float:
	return pow(clampf(x, 0.0, 1.0), power)


static func ease_in_out(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func bezier(a: Vector3, b: Vector3, c: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return a * u * u + b * 2.0 * u * t + c * t * t


# 节点相对开播时刻的位移（目标被拉 / 走动时，挂在它身上的层跟着走）。
static func _drift(ref: WeakRef, base: Vector3) -> Vector3:
	return node_position(ref, base) - base


func _capped_points(values: Variant) -> Array:
	var out: Array = []
	if values is Array:
		for value in values:
			if value is Vector3:
				out.append(value)
	var limit := QUALITY_BUDGET.max_aoe_targets(out.size())
	return out if limit >= out.size() else out.slice(0, limit)


# 每帧重画的正对镜头曲线条带（触须 / 拖尾），UV.x 尾 0 → 头 1。
func _ribbon(label: String, params: Dictionary = {}) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = ImmediateMesh.new()
	var p := {"billboard": 0.0, "shape": SHAPE_STREAK, "core_white": 0.25, "edge_dark": 0.5}
	p.merge(params, true)
	node.material_override = glow_material(_p(p))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.top_level = true
	node.visible = false
	add_child(node)
	node.global_transform = Transform3D.IDENTITY
	return node


func _draw_curve(node: MeshInstance3D, points: PackedVector3Array, width: float) -> void:
	var mesh := node.mesh as ImmediateMesh
	mesh.clear_surfaces()
	if points.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := points.size()
	var sides: Array[Vector3] = []
	for k in n:
		var a := points[maxi(0, k - 1)]
		var b := points[mini(n - 1, k + 1)]
		var s := (b - a).cross(CAMERA_DIR)
		sides.append(s.normalized() if s.length_squared() > 0.0000001 else Vector3.RIGHT)
	for k in n - 1:
		var u0 := float(k) / float(n - 1)
		var u1 := float(k + 1) / float(n - 1)
		var w0 := sides[k] * width * (0.35 + 0.65 * u0)
		var w1 := sides[k + 1] * width * (0.35 + 0.65 * u1)
		mesh.surface_set_uv(Vector2(u0, 0.0)); mesh.surface_add_vertex(points[k] - w0)
		mesh.surface_set_uv(Vector2(u1, 0.0)); mesh.surface_add_vertex(points[k + 1] - w1)
		mesh.surface_set_uv(Vector2(u1, 1.0)); mesh.surface_add_vertex(points[k + 1] + w1)
		mesh.surface_set_uv(Vector2(u0, 0.0)); mesh.surface_add_vertex(points[k] - w0)
		mesh.surface_set_uv(Vector2(u1, 1.0)); mesh.surface_add_vertex(points[k + 1] + w1)
		mesh.surface_set_uv(Vector2(u0, 1.0)); mesh.surface_add_vertex(points[k] + w0)
	mesh.surface_end()


# ══ 黑龙 · 黑洞 ══════════════════════════════════════════════════════════

func _black_hole(origin: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "origin_height")
	var center: Vector3 = context.get("origin_foot", Vector3(origin.x, 0.0, origin.z))
	var radius: Vector2 = context.get("world_radius", Vector2(2.4, 3.0))
	radius = Vector2(clampf(radius.x, 0.8, 6.0), clampf(radius.y, 0.8, 6.0))
	var stun := clampf(float(context.get("stun_duration", 1.0)), 0.3, 6.0)
	var targets := _capped_points(context.get("targets", []))
	var from_positions: Array = context.get("from_positions", [])
	var nodes: Array = context.get("target_nodes", [])
	_debug["pulled"] = targets.size()
	_debug["radius"] = radius
	_debug["stun"] = stun
	_debug["tendrils"] = 0
	_debug["locks"] = 0
	var ground := center + Vector3.UP * 0.03

	# 施法：龙胸前一团暗紫光迅速鼓起又被吸回地面。
	var cast := g("BHCast", toward_camera(origin, 0.2), 0.9, {"softness": 1.1, "core_white": 0.4})
	track(0.0, 0.32, func(x: float) -> void:
		cast.scale = Vector3.ONE * lerpf(0.4, 1.15, ease_out(x)) * (1.0 - 0.6 * smoothstep(0.6, 1.0, x))
		show_with(cast, 0.85 * envelope(x, 0.15, 0.5)))

	# 引力范围：贴地一圈细的撕裂光边标出数据半径（玩家能读到「这么大」），再向内收缩。
	var rim := gd("BHRim", ground, radius, {"ring_radius": 0.93, "ring_width": 0.05, "breakup": 0.8, "fill": 0.08, "edge_dark": 0.35, "core_white": 0.4})
	track(0.0, 0.85, func(x: float) -> void:
		var k := 1.0 - 0.78 * ease_in(smoothstep(0.12, 1.0, x), 2.2)
		rim.scale = Vector3(radius.x * 2.0 * k, 1.0, radius.y * 2.0 * k)
		set_param(rim, "ring_width", clampf(0.04 / maxf(k, 0.25), 0.035, 0.14))
		show_with(rim, 0.75 * smoothstep(0.0, 0.10, x) * (1.0 - smoothstep(0.82, 1.0, x))))

	# 奇点：悬在黑龙头顶的一颗真正的黑球（不透明、写深度 —— 吸积盘的粒子转到它背后
	# 会被挡住，立体感就从这里来）+ 视界亮环 + 一圈暗紫光晕。
	var hole_at := center + Vector3.UP * h * 1.55 + CAMERA_DIR * 0.1
	_debug["hole_at"] = hole_at
	var sphere := MeshInstance3D.new()
	sphere.name = "BHSphere"
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.5
	sphere_mesh.height = 1.0
	sphere_mesh.radial_segments = 24
	sphere_mesh.rings = 12
	sphere.mesh = sphere_mesh
	var sphere_material := StandardMaterial3D.new()
	sphere_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere_material.albedo_color = Color(0.025, 0.0, 0.05)
	sphere.material_override = sphere_material
	sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sphere.visible = false
	add_child(sphere)
	sphere.global_position = hole_at
	var horizon := g("BHHorizon", hole_at, 1.0, {"shape": SHAPE_RING, "ring_radius": 0.62, "ring_width": 0.13, "breakup": 0.35, "core_white": 0.75, "edge_dark": 0.1})
	var shroud := g("BHShroud", hole_at - CAMERA_DIR * 0.3, 1.0, {"softness": 1.2, "tint": Color(0.22, 0.02, 0.40), "core_white": 0.0, "edge_dark": 0.2})
	var lens := g("BHLens", hole_at, 1.0, {"shape": SHAPE_RING, "ring_radius": 0.7, "ring_width": 0.07, "breakup": 0.65, "core_white": 0.4, "edge_dark": 0.15})
	var core_r := 0.30
	var grow_at := 0.05
	var collapse_at := 1.0
	track(grow_at, collapse_at + 0.16 - grow_at, func(x: float) -> void:
		var t := grow_at + x * (collapse_at + 0.16 - grow_at)
		var grow := ease_out(clampf((t - grow_at) / 0.25, 0.0, 1.0), 2.4)
		var crush := 1.0 - ease_in(clampf((t - collapse_at) / 0.16, 0.0, 1.0), 2.0)
		var pulse := 1.0 + 0.06 * sin(t * 31.0)
		var r := core_r * grow * crush * pulse
		sphere.scale = Vector3.ONE * maxf(0.001, r * 2.0)
		sphere.visible = r > 0.01 and vfx_alpha > 0.05
		horizon.global_position = hole_at + CAMERA_DIR * r * 1.1
		horizon.scale = Vector3.ONE * r * 4.3
		set_param(horizon, "spin", t * 5.0)
		set_param(horizon, "seed", t * 6.0)
		show_with(horizon, 0.95 * minf(1.0, grow * 2.0) * crush)
		shroud.scale = Vector3.ONE * r * 8.0
		show_with(shroud, 0.7 * grow * crush)
		lens.global_position = hole_at + CAMERA_DIR * r * 1.2
		lens.scale = Vector3.ONE * r * 5.6
		set_param(lens, "spin", -t * 3.0)
		set_param(lens, "seed", t * 4.0)
		show_with(lens, 0.6 * minf(1.0, grow * 2.0) * crush))

	# 吸积盘：围着黑球高速旋转的光粒，盘面向镜头倾斜成椭圆，内圈快、外圈慢；
	# 转到黑球背后时被挡住。
	var disk_tilt := Basis(Vector3.RIGHT, deg_to_rad(-20.0))
	var disk_n := QUALITY_BUDGET.particle_count_for(96)
	# 雪地上白热色会「消失」，吸积盘粒子刻意压成深紫 → 亮紫，不往白里走。
	var disk := motes("BHDisk", disk_n, {"softness": 0.2, "core_white": 0.05, "edge_dark": 0.55, "hot": Color(0.66, 0.22, 1.0)})
	var dspecs: Array[Dictionary] = []
	for i in disk_n:
		dspecs.append({"a": _rng.randf() * TAU, "r": _rng.randf_range(1.3, 3.6), "y": _rng.randf_range(-0.15, 0.15), "s": _rng.randf_range(0.13, 0.24)})
	# 两条真正倾斜的吸积光环（一张贴图面按盘面姿态摆放，不是正对镜头的平面），
	# 前半圈压在黑球前面、后半圈被黑球挡住 —— 一眼读出「立体」。
	var bands: Array[MeshInstance3D] = []
	for k in 2:
		var band := gd("BHBand%d" % k, hole_at, Vector2.ONE, {"ring_radius": 0.82, "ring_width": 0.13 - 0.04 * float(k), "breakup": 0.55, "seed": 3.0 + float(k) * 5.0, "core_white": 0.25, "edge_dark": 0.25})
		(band.material_override as ShaderMaterial).render_priority = 1
		bands.append(band)
	track(0.1, collapse_at + 0.45, func(x: float) -> void:
		var t := 0.1 + x * (collapse_at + 0.45)
		var grow := ease_out(clampf((t - 0.1) / 0.3, 0.0, 1.0), 2.0)
		var fling := clampf((t - collapse_at) / 0.45, 0.0, 1.0)
		for k in bands.size():
			var span := core_r * (2.6 if k == 0 else 3.6) * grow * (1.0 + 2.5 * ease_out(fling, 2.0))
			bands[k].global_transform = Transform3D(disk_tilt * Basis(Vector3.UP, t * (6.0 if k == 0 else -4.0)).scaled(Vector3(span * 2.0, 1.0, span * 2.0)), hole_at)
			show_with(bands[k], (0.95 if k == 0 else 0.7) * grow * (1.0 - fling))
		var burst := clampf((t - collapse_at) / 0.45, 0.0, 1.0)
		for i in dspecs.size():
			var s: Dictionary = dspecs[i]
			var rr := float(s["r"]) * core_r
			var ang := float(s["a"]) + t * 9.0 / float(s["r"])
			var local := Vector3(cos(ang) * rr, float(s["y"]) * core_r, sin(ang) * rr)
			# 坍缩时整盘被甩出去。
			local *= grow * (1.0 + ease_out(burst, 2.0) * 3.5)
			var heat := 1.0 - (float(s["r"]) - 1.25) / 2.0
			set_mote(disk, i, hole_at + disk_tilt * local, float(s["s"]) * (0.8 + 0.6 * heat), (0.65 + 0.35 * heat) * grow * (1.0 - burst))
		show_with(disk, 1.0))

	# 引力漏斗：地上一大片光粒和碎石沿螺旋被卷起、越转越快地吸进头顶的黑球 —— 立体的漩涡。
	var inflow_n := QUALITY_BUDGET.particle_count_for(64)
	var inflow := motes("BHInflow", inflow_n, {"softness": 0.25, "core_white": 0.05, "edge_dark": 0.55, "hot": Color(0.62, 0.2, 0.95)})
	var ispecs: Array[Dictionary] = []
	for i in inflow_n:
		ispecs.append({"a": _rng.randf() * TAU, "r": _rng.randf_range(0.35, 1.0), "t0": _rng.randf_range(0.0, 0.62), "life": _rng.randf_range(0.42, 0.7), "s": _rng.randf_range(0.10, 0.19), "lift": _rng.randf_range(0.0, 0.25)})
	var inflow_path := func(s: Dictionary, u: float) -> Vector3:
		var pull := ease_in(u, 1.7)
		var rr := float(s["r"]) * (1.0 - pull)
		var ang := float(s["a"]) + pull * 4.2
		var ground_p := center + Vector3(cos(ang) * radius.x * rr, 0.06 + float(s["lift"]), sin(ang) * radius.y * rr)
		var rise := ease_in(u, 2.4)
		return ground_p.lerp(hole_at + Vector3(cos(ang), 0.0, sin(ang)) * core_r * 1.2 * (1.0 - u), rise)
	track(0.02, collapse_at, func(x: float) -> void:
		var t := x * collapse_at
		for i in ispecs.size():
			var s: Dictionary = ispecs[i]
			var u := clampf((t - float(s["t0"])) / float(s["life"]), 0.0, 1.0)
			if u <= 0.0 or u >= 1.0:
				set_mote(inflow, i, center, 0.01, 0.0)
				continue
			set_mote(inflow, i, inflow_path.call(s, u), float(s["s"]) * (1.0 - 0.4 * u), smoothstep(0.0, 0.12, u) * (1.0 - smoothstep(0.88, 1.0, u)))
		show_with(inflow, 1.0))
	var rocks_n := QUALITY_BUDGET.particle_count_for(14)
	var rocks := shard_cloud("BHRocks", rocks_n, DARK_BODY)
	var rspecs: Array[Dictionary] = []
	for i in rocks_n:
		rspecs.append({"a": _rng.randf() * TAU, "r": _rng.randf_range(0.3, 0.85), "t0": _rng.randf_range(0.0, 0.45), "life": _rng.randf_range(0.55, 0.8), "lift": 0.0, "axis": Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)).normalized(), "s": _rng.randf_range(0.7, 1.3)})
	track(0.02, collapse_at, func(x: float) -> void:
		var t := x * collapse_at
		for i in rspecs.size():
			var s: Dictionary = rspecs[i]
			var u := clampf((t - float(s["t0"])) / float(s["life"]), 0.0, 1.0)
			var visible_k := 0.0 if u <= 0.0 or u >= 1.0 else 1.0
			var at: Vector3 = inflow_path.call(s, u)
			var b := Basis(s["axis"] as Vector3, t * 9.0).scaled(Vector3.ONE * 0.09 * float(s["s"]) * (1.0 - 0.6 * u) * visible_k + Vector3.ONE * 0.0001)
			rocks.multimesh.set_instance_transform(i, Transform3D(b, rocks.to_local(at)))
			rocks.multimesh.set_instance_color(i, Color(0.7, 1.0, 1.0, visible_k * (1.0 - smoothstep(0.85, 1.0, u))))
		show_with(rocks, 1.0))

	# 每个被拉的人：旧位置拖出的残影条 + 两根牵引触须 + 落点受击 + 引力锁环（眩晕时长）。
	for i in targets.size():
		var to: Vector3 = targets[i]
		var from: Vector3 = from_positions[i] if i < from_positions.size() and from_positions[i] is Vector3 else to
		var ref: WeakRef = weak_node(nodes[i]) if i < nodes.size() else null
		var base := node_position(ref, to)
		var th := UNIT_HEIGHT * 1.1
		var smear := streak("BHDrag%d" % i, _p({"core_white": 0.3, "edge_dark": 0.6}))
		track(0.0, 0.48, func(x: float) -> void:
			var now := to + _drift(ref, base)
			var tail := from.lerp(now, ease_out(x, 2.0) * 0.85)
			place_streak(smear, tail + Vector3.UP * th * 0.42, now + Vector3.UP * th * 0.42 + CAMERA_DIR * 0.1, th * 0.55 * (1.0 - 0.45 * x))
			show_with(smear, 1.0 * (1.0 - smoothstep(0.45, 1.0, x)) * smoothstep(0.0, 0.05, x)))
		for k in 2:
			var tendril := _ribbon("BHTendril%d_%d" % [i, k], {"core_white": 0.3, "edge_dark": 0.3})
			_debug["tendrils"] = int(_debug["tendrils"]) + 1
			var phase := _rng.randf() * TAU
			var bend := (0.35 if k == 0 else -0.35) * _rng.randf_range(0.7, 1.2)
			track(0.02 + 0.04 * float(k), 0.72, func(x: float) -> void:
				var foot := to + _drift(ref, base) + Vector3.UP * (0.12 + 0.25 * float(k))
				var hub := hole_at
				var pts := PackedVector3Array()
				var side := (hub - foot).cross(CAMERA_DIR).normalized()
				for s in 12:
					var u := float(s) / 11.0
					var wave := sin(u * 7.0 + phase + x * 16.0) * 0.12 * (1.0 - u) + bend * sin(u * PI)
					pts.append(foot.lerp(hub, u) + side * wave + Vector3.UP * sin(u * PI) * 0.18)
				_draw_curve(tendril, pts, 0.13 * (1.0 - 0.5 * x))
				show_with(tendril, 0.85 * envelope(x, 0.12, 0.45)))
		var hit := g("BHHit%d" % i, toward_camera(to + Vector3.UP * th * 0.5, 0.25), 1.3, {"shape": SHAPE_FLARE, "core_white": 0.75})
		track(0.14, 0.30, func(x: float) -> void:
			hit.global_position = toward_camera(to + _drift(ref, base) + Vector3.UP * th * 0.5, 0.25)
			hit.scale = Vector3.ONE * lerpf(0.5, 1.15, ease_out(x))
			set_param(hit, "spin", x * 1.4)
			show_with(hit, 0.95 * (1.0 - x)))
		var shards := shard_cloud("BHShards%d" % i, QUALITY_BUDGET.particle_count_for(7), DARK_BODY)
		var flying := scatter(shards.multimesh.instance_count, to + Vector3.UP * th * 0.5, Vector3.ZERO, 1.6, 1.2, 0.8)
		track(0.14, 0.55, func(x: float) -> void:
			drive_shards(shards, flying, x, 0.55, 0.06, 0.8))
		var lock := gd("BHLock%d" % i, to + Vector3.UP * 0.035, Vector2(0.42, 0.42), {"shape": SHAPE_SEAL, "pattern": 7, "seal_rings": 1.0, "stroke": 0.05, "breakup": 0.4, "fill": 0.2, "core_white": 0.35, "edge_dark": 0.3})
		_debug["locks"] = int(_debug["locks"]) + 1
		track(0.18, stun, func(x: float) -> void:
			var t := x * stun
			lock.global_position = to + _drift(ref, base) + Vector3.UP * 0.035
			set_param(lock, "spin", -t * 4.0)
			var squeeze := 1.0 - 0.12 * ease_out(minf(1.0, t / 0.25))
			lock.scale = Vector3(0.84 * squeeze, 1.0, 0.84 * squeeze)
			show_with(lock, 0.8 * smoothstep(0.0, 0.12 / stun, x) * (1.0 - smoothstep(1.0 - 0.25 / stun, 1.0, x))))

	# 坍缩：奇点被压到一点后弹出一圈短促的紫光。
	var burst := g("BHCollapse", hole_at + CAMERA_DIR * 0.3, 1.4, {"shape": SHAPE_FLARE, "core_white": 0.85})
	var wave := g("BHCollapseWave", hole_at + CAMERA_DIR * 0.25, 1.0, {"shape": SHAPE_RING, "ring_radius": 0.85, "ring_width": 0.08, "breakup": 0.45, "core_white": 0.5})
	track(collapse_at + 0.12, 0.36, func(x: float) -> void:
		burst.scale = Vector3.ONE * lerpf(0.4, 1.5, ease_out(x))
		set_param(burst, "spin", 0.6 + x)
		show_with(burst, 0.95 * (1.0 - x)))
	track(collapse_at + 0.14, 0.42, func(x: float) -> void:
		wave.scale = Vector3.ONE * lerpf(0.3, 2.6, ease_out(x))
		show_with(wave, 0.85 * (1.0 - x)))
	keep_alive_until(maxf(1.5, 0.2 + stun))


# ══ 神王 · 神威 ══════════════════════════════════════════════════════════

func _divine_blast(origin: Vector3, target: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "origin_height")
	var foot: Vector3 = context.get("origin_foot", origin + Vector3.DOWN * h * 0.6)
	var caster_ref := weak_node(context.get("origin_node"))
	var caster_base := node_position(caster_ref, origin)
	var sigil_at := toward_camera(foot + Vector3.UP * h * 1.62, 0.15)
	var targets := _capped_points(context.get("targets", []))
	if targets.is_empty():
		targets = [target]
	var nodes: Array = context.get("target_nodes", [])
	_debug["orbs"] = targets.size()
	_debug["linger"] = 0

	# 头顶一圈环绕旋转的能量团（不是一张平面法印）：每团 = 四芒亮核 + 光晕 + 沿轨道拖出的
	# 粒子尾巴；轨道是绕头一周、向镜头倾斜的椭圆，越接近出手转得越快。光弹从这些能量团里
	# 依次甩出去，全部打出后能量团向中心收拢消失。
	var cluster_n := 4 if QUALITY_BUDGET.tier == 0 else 6
	var last_launch := 0.30 + 0.06 * float(targets.size() - 1)
	var orbit_life := last_launch + 0.45
	_debug["clusters"] = cluster_n
	var center_glow := g("GKCenter", sigil_at, 0.9, {"softness": 1.3, "core_white": 0.5, "edge_dark": 0.2})
	var cores: Array[MeshInstance3D] = []
	var glows: Array[MeshInstance3D] = []
	for k in cluster_n:
		cores.append(g("GKCluster%d" % k, sigil_at, 0.42, {"shape": SHAPE_FLARE, "core_white": 1.0}))
		glows.append(g("GKClusterGlow%d" % k, sigil_at, 0.75, {"softness": 1.0, "core_white": 0.55, "edge_dark": 0.25}))
	var tail_per := 6
	var tails := motes("GKClusterTails", cluster_n * tail_per, {"softness": 0.45, "core_white": 0.7})
	track(0.0, orbit_life, func(x: float) -> void:
		var t := x * orbit_life
		var at := sigil_at + _drift(caster_ref, caster_base)
		var open := ease_out(minf(1.0, t / 0.22), 2.5)
		var fold := ease_in(smoothstep(orbit_life - 0.30, orbit_life, t), 2.0)
		for k in cluster_n:
			var phase := _gk_phase(t, k, cluster_n)
			var p := _gk_orbit(at, phase, open * (1.0 - fold))
			var flick := 1.0 + 0.18 * sin(t * 37.0 + float(k) * 2.1)
			cores[k].global_position = p + CAMERA_DIR * 0.03
			cores[k].scale = Vector3.ONE * 0.42 * flick * open
			set_param(cores[k], "spin", t * 4.0 + float(k))
			show_with(cores[k], open * (1.0 - fold))
			glows[k].global_position = p
			glows[k].scale = Vector3.ONE * 0.75 * flick * open
			show_with(glows[k], 0.75 * open * (1.0 - fold))
			for j in tail_per:
				var lag := _gk_phase(t - float(j + 1) * 0.022, k, cluster_n)
				var q := _gk_orbit(at, lag, open * (1.0 - fold))
				set_mote(tails, k * tail_per + j, q, 0.20 * (1.0 - float(j) / float(tail_per)), 0.85 * open * (1.0 - fold) * (1.0 - float(j) / float(tail_per)))
		show_with(tails, 1.0)
		center_glow.global_position = at
		center_glow.scale = Vector3.ONE * (0.6 + 0.5 * open + 0.6 * fold) * (1.0 + 0.06 * sin(t * 24.0))
		show_with(center_glow, 0.55 * open * (1.0 - smoothstep(0.75, 1.0, x))))

	# 聚能：一圈金色光点被吸进法印。
	var gather_count := QUALITY_BUDGET.particle_count_for(22)
	var gather := motes("GKGather", gather_count, {"softness": 0.4})
	var gspecs: Array[Dictionary] = []
	for i in gather_count:
		gspecs.append({"a": _rng.randf() * TAU, "r": _rng.randf_range(0.9, 1.6), "t0": _rng.randf_range(0.0, 0.12), "s": _rng.randf_range(0.10, 0.18)})
	track(0.0, 0.36, func(x: float) -> void:
		var t := x * 0.36
		var at := sigil_at + _drift(caster_ref, caster_base)
		for i in gspecs.size():
			var s: Dictionary = gspecs[i]
			var u := clampf((t - float(s["t0"])) / 0.24, 0.0, 1.0)
			var rr := float(s["r"]) * (1.0 - ease_in(u, 1.8))
			var ang := float(s["a"]) + u * 1.6
			set_mote(gather, i, at + (Vector3.RIGHT * cos(ang) + SCREEN_UP * sin(ang)) * rr, float(s["s"]), smoothstep(0.0, 0.2, u) * (1.0 - smoothstep(0.85, 1.0, u)))
		show_with(gather, 1.0))

	for i in targets.size():
		var launch := 0.30 + 0.06 * float(i)
		# 从当时正转到那个位置的能量团里甩出去。
		var start := _gk_orbit(sigil_at, _gk_phase(launch, i % cluster_n, cluster_n), 1.0)
		_divine_orb(i, start, targets[i], nodes[i] if i < nodes.size() else null, caster_ref, caster_base, launch)
	keep_alive_until(last_launch + 0.5 + 2.4)


# 能量团 k 在时刻 t 的轨道相位：开始慢、越转越快。
static func _gk_phase(t: float, k: int, n: int) -> float:
	var tt := maxf(0.0, t)
	return float(k) * TAU / float(n) + tt * 5.0 + tt * tt * 6.0


# 绕头的倾斜椭圆轨道（宽 0.62，前后 0.30，带一点上下起伏），open 控制张开程度。
static func _gk_orbit(center: Vector3, phase: float, open: float) -> Vector3:
	return center + (Vector3.RIGHT * cos(phase) * 0.62 + Vector3.BACK * sin(phase) * 0.30 + Vector3.UP * sin(phase * 2.0) * 0.06) * open


func _divine_orb(index: int, sigil_at: Vector3, target_foot: Vector3, node: Variant, caster_ref: WeakRef, caster_base: Vector3, launch: float) -> void:
	var ref := weak_node(node)
	var th := UNIT_HEIGHT * 1.05
	var hit_base := target_foot + Vector3.UP * th * 0.55
	var node_base := node_position(ref, hit_base)
	var distance := Vector2(target_foot.x - sigil_at.x, target_foot.z - sigil_at.z).length()
	var travel := clampf(0.22 + distance / 9.0, 0.28, 0.55)
	var side := (1.0 if index % 2 == 0 else -1.0) * _rng.randf_range(0.35, 0.75)
	var lift := _rng.randf_range(0.8, 1.3)
	var head := g("GKOrb%d" % index, sigil_at, 0.5, {"shape": SHAPE_FLARE, "core_white": 1.0})
	var glow := g("GKOrbGlow%d" % index, sigil_at, 1.0, {"softness": 1.0, "core_white": 0.5, "edge_dark": 0.25})
	var trail_n := QUALITY_BUDGET.particle_count_for(16)
	var trail := motes("GKTrail%d" % index, trail_n, {"softness": 0.5, "core_white": 0.75})
	var path := func(t: float) -> Vector3:
		var start := sigil_at + _drift(caster_ref, caster_base)
		var end := hit_base + _drift(ref, node_base) + CAMERA_DIR * 0.15
		var mid := start.lerp(end, 0.5) + Vector3.UP * lift + Vector3.RIGHT * side
		return bezier(start, mid, end, t)
	track(launch, travel, func(x: float) -> void:
		var u := ease_in(x, 1.35)
		var at: Vector3 = path.call(u)
		head.global_position = at
		glow.global_position = at
		head.scale = Vector3.ONE * (0.55 + 0.10 * sin(x * 40.0))
		set_param(head, "spin", x * 6.0)
		glow.scale = Vector3.ONE * 1.0
		show_with(head, 1.0 * smoothstep(0.0, 0.08, x))
		show_with(glow, 0.7 * smoothstep(0.0, 0.08, x))
		for k in trail_n:
			var lag := u - float(k + 1) * 0.03
			if lag <= 0.0:
				set_mote(trail, k, at, 0.01, 0.0)
				continue
			var jitter := Vector3(sin(float(k) * 2.3 + x * 20.0), cos(float(k) * 1.7 + x * 17.0), 0.0) * 0.022 * float(k)
			set_mote(trail, k, (path.call(lag) as Vector3) + jitter, 0.36 * (1.0 - float(k) / float(trail_n)) + 0.05, 0.95 * (1.0 - float(k) / float(trail_n)))
		show_with(trail, 1.0))
	var arrive := launch + travel
	track(arrive, 0.02, func(_x: float) -> void:
		show_with(head, 0.0)
		show_with(glow, 0.0)
		show_with(trail, 0.0))
	# 命中：四芒爆闪 + 面向镜头的光环 + 一把向外炸开的金色火花。
	var flare := g("GKImpact%d" % index, hit_base, 1.6, {"shape": SHAPE_FLARE, "core_white": 0.9})
	var ring := g("GKImpactRing%d" % index, hit_base, 1.0, {"shape": SHAPE_RING, "ring_radius": 0.8, "ring_width": 0.12, "breakup": 0.55, "core_white": 0.6, "edge_dark": 0.0, "edge": Color(0.9, 0.48, 0.0)})
	var ground := gd("GKImpactGround%d" % index, target_foot + Vector3.UP * 0.03, Vector2(0.6, 0.6), {"ring_radius": 0.85, "ring_width": 0.10, "fill": 0.45, "breakup": 0.5, "core_white": 0.5, "edge_dark": 0.0, "edge": Color(0.9, 0.48, 0.0)})
	track(arrive, 0.34, func(x: float) -> void:
		var at := hit_base + _drift(ref, node_base) + CAMERA_DIR * 0.2
		flare.global_position = at
		flare.scale = Vector3.ONE * lerpf(0.7, 1.8, ease_out(x))
		set_param(flare, "spin", x * 1.1)
		show_with(flare, 1.0 * (1.0 - x)))
	track(arrive, 0.42, func(x: float) -> void:
		ring.global_position = hit_base + _drift(ref, node_base) + CAMERA_DIR * 0.18
		ring.scale = Vector3.ONE * lerpf(0.25, 1.3, ease_out(x))
		show_with(ring, 0.9 * (1.0 - smoothstep(0.4, 1.0, x)))
		ground.global_position = target_foot + _drift(ref, node_base) + Vector3.UP * 0.03
		ground.scale = Vector3(1.0, 1.0, 1.0) * lerpf(0.5, 1.5, ease_out(x))
		show_with(ground, 0.75 * (1.0 - smoothstep(0.4, 1.0, x))))
	var spark_n := QUALITY_BUDGET.particle_count_for(18)
	var sparks := motes("GKSparks%d" % index, spark_n, {"shape": SHAPE_FLARE, "core_white": 0.85})
	var sspecs: Array[Dictionary] = []
	for k in spark_n:
		var a := _rng.randf() * TAU
		sspecs.append({"v": (Vector3.RIGHT * cos(a) + SCREEN_UP * sin(a)) * _rng.randf_range(1.4, 2.8) + Vector3.UP * _rng.randf_range(0.2, 1.0), "s": _rng.randf_range(0.14, 0.24)})
	track(arrive, 0.5, func(x: float) -> void:
		var t := x * 0.5
		var at := hit_base + _drift(ref, node_base) + CAMERA_DIR * 0.22
		for k in sspecs.size():
			var s: Dictionary = sspecs[k]
			var p: Vector3 = at + (s["v"] as Vector3) * t * (1.0 - 0.5 * x) + Vector3.DOWN * 1.6 * t * t
			set_mote(sparks, k, p, float(s["s"]) * (1.0 - 0.6 * x), 1.0 - smoothstep(0.5, 1.0, x))
		show_with(sparks, 1.0))
	# 余能：绕身旋转的光点 + 淡金光晕，覆盖后续 5 跳伤害（0.5 秒一跳）。
	var linger_n := QUALITY_BUDGET.auxiliary_layers_for(3) + 2
	var orbit := motes("GKLinger%d" % index, linger_n, {"softness": 0.45, "core_white": 0.8})
	var aura := g("GKAura%d" % index, hit_base, 0.9, {"softness": 1.4, "core_white": 0.2, "edge_dark": 0.2})
	_debug["linger"] = int(_debug["linger"]) + 1
	var linger := 2.3
	track(arrive + 0.1, linger, func(x: float) -> void:
		var t := x * linger
		var gone := ref != null and not is_instance_valid(ref.get_ref())
		var at := hit_base + _drift(ref, node_base)
		var fade := smoothstep(0.0, 0.08, x) * (1.0 - smoothstep(0.8, 1.0, x)) * (0.0 if gone else 1.0)
		for k in linger_n:
			var ph := t * 3.4 + float(k) * TAU / float(linger_n)
			var p := at + Vector3(cos(ph) * 0.38, sin(ph * 1.7) * 0.18 + 0.05 * float(k), sin(ph) * 0.22)
			set_mote(orbit, k, toward_camera(p, 0.1), 0.22 + 0.05 * sin(t * 9.0 + float(k)), 0.95 * fade)
		show_with(orbit, 1.0)
		aura.global_position = toward_camera(at, 0.05)
		aura.scale = Vector3.ONE * (0.85 + 0.08 * sin(t * 6.0))
		show_with(aura, 0.45 * fade))


func _divine_pulse(target: Vector3, context: Dictionary) -> void:
	var ref := weak_node(context.get("target_node"))
	var base := node_position(ref, target)
	_debug["pulse"] = int(context.get("pulse_index", 0))
	var flare := g("GKPulse", target, 0.8, {"shape": SHAPE_FLARE, "core_white": 0.85})
	var ring := g("GKPulseRing", target, 0.8, {"shape": SHAPE_RING, "ring_radius": 0.8, "ring_width": 0.11, "breakup": 0.4, "core_white": 0.5, "edge_dark": 0.0, "edge": Color(0.9, 0.48, 0.0)})
	track(0.0, 0.32, func(x: float) -> void:
		var at := toward_camera(target + _drift(ref, base), 0.2)
		flare.global_position = at
		ring.global_position = at
		flare.scale = Vector3.ONE * lerpf(0.35, 0.85, ease_out(x))
		set_param(flare, "spin", 0.4 + x)
		ring.scale = Vector3.ONE * lerpf(0.2, 0.95, ease_out(x))
		show_with(flare, 0.9 * (1.0 - x))
		show_with(ring, 0.7 * (1.0 - x)))
	var n := QUALITY_BUDGET.particle_count_for(7)
	var sparks := motes("GKPulseSparks", n, {"core_white": 0.8})
	var dirs: Array[Vector3] = []
	for k in n:
		var a := TAU * float(k) / float(n) + _rng.randf_range(-0.3, 0.3)
		dirs.append((Vector3.RIGHT * cos(a) + SCREEN_UP * sin(a)) * _rng.randf_range(0.9, 1.5))
	track(0.0, 0.38, func(x: float) -> void:
		var at := toward_camera(target + _drift(ref, base), 0.22)
		for k in n:
			set_mote(sparks, k, at + dirs[k] * 0.38 * ease_out(x), 0.11 * (1.0 - 0.5 * x), 1.0 - x)
		show_with(sparks, 1.0))


# ══ 母灵 · 亡者之书 ══════════════════════════════════════════════════════

const PAGE_W := 0.44
const PAGE_H := 0.58

func _book_material(cover: bool, seed_value: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = PAGE_SHADER
	material.render_priority = 1
	material.set_shader_parameter("is_cover", 1.0 if cover else 0.0)
	material.set_shader_parameter("seed", seed_value)
	material.set_shader_parameter("opacity", 0.0)
	material.set_shader_parameter("trim_color", SOUL_PALETTE["tint"])
	material.set_shader_parameter("glow_color", SOUL_PALETTE["hot"])
	return material


func _book_leaf(parent: Node3D, label: String, cover: bool, lift: float, seed_value: float) -> Node3D:
	var hinge := Node3D.new()
	hinge.name = label
	parent.add_child(hinge)
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(PAGE_W * (1.06 if cover else 1.0), PAGE_H * (1.08 if cover else 1.0))
	var leaf := MeshInstance3D.new()
	leaf.name = "Leaf"
	leaf.mesh = mesh
	leaf.material_override = _book_material(cover, seed_value)
	leaf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	leaf.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	leaf.position = Vector3(mesh.size.x * 0.5, lift, 0.0)
	hinge.add_child(leaf)
	return hinge


static func _leaf_angle(hinge: Node3D, angle: float) -> void:
	hinge.basis = Basis(Vector3(0, 0, 1), angle)


static func _leaf_param(hinge: Node3D, key: String, value: Variant) -> void:
	var leaf := hinge.get_node_or_null("Leaf") as MeshInstance3D
	if leaf != null:
		(leaf.material_override as ShaderMaterial).set_shader_parameter(key, value)


func _death_book(origin: Vector3, target: Vector3, context: Dictionary) -> void:
	var h := height_of(context, "origin_height")
	var heavy := bool(context.get("heavy", false))
	var has_victim := bool(context.get("has_victim", context.has("target_node")))
	var head_ref := weak_node(context.get("origin_head_node", context.get("origin_node")))
	var head_base := node_position(head_ref, origin)
	# 与旧版书本同高（头顶锚点上方约 0.86），避开血条 / 魂火计数一排。
	var book_at := toward_camera(origin + Vector3.UP * maxf(0.86, h * 0.72), 0.3)
	var pages := 3 if QUALITY_BUDGET.tier == 0 else 5
	_debug["pages"] = pages
	_debug["heavy"] = heavy
	_debug["victim"] = has_victim
	_debug["wisps"] = 0

	# 书体：脊在中线，书页绕脊（局部 Z）翻。书面朝镜头并略向后仰，像悬在头顶摊开。
	var book := Node3D.new()
	book.name = "DeathBook"
	add_child(book)
	var normal := CAMERA_DIR.lerp(Vector3.UP, 0.45).normalized()
	var spine := Vector3.RIGHT.cross(normal).normalized()
	book.global_transform = Transform3D(Basis(Vector3.RIGHT, normal, spine), book_at)
	book.scale = Vector3.ONE * 0.01
	var back := _book_leaf(book, "BackCover", true, -0.012, 1.0)
	var leaves: Array[Node3D] = []
	for k in pages:
		leaves.append(_book_leaf(book, "Page%d" % k, false, -0.006 + 0.012 * float(k + 1) / float(pages + 1), float(k) * 3.1 + 2.0))
	var front := _book_leaf(book, "FrontCover", true, 0.012, 5.0)
	var all_leaves: Array[Node3D] = [back]
	all_leaves.append_array(leaves)
	all_leaves.append(front)

	var aura := g("BookAura", book_at, 1.6, {"softness": 1.3, "core_white": 0.25, "edge_dark": 0.3})
	var sigil := g("BookSigil", book_at, 0.55, {"shape": SHAPE_SEAL, "pattern": 6, "seal_rings": 0.0, "stroke": 0.07, "fill": 0.0, "core_white": 0.55})
	# 有目标：翻书 → 光波飞出去收人 → 魂火飞回 → 合书，整段要长一些。
	var close_at := 1.62 if has_victim else 1.25
	var life := close_at + 0.6
	# 书的总体：弹出 → 悬停微晃 → 合上后缩小上浮消失；整体跟着母灵头顶走。
	track(0.0, life, func(x: float) -> void:
		var t := x * life
		var at := book_at + _drift(head_ref, head_base)
		var pop := ease_out(minf(1.0, t / 0.2), 2.0) * (1.0 + 0.12 * sin(minf(1.0, t / 0.2) * PI))
		var leave := smoothstep(close_at + 0.22, life, t)
		var bob := Vector3.UP * 0.03 * sin(t * 6.0)
		book.global_position = at + bob + Vector3.UP * 0.25 * leave
		book.scale = Vector3.ONE * maxf(0.01, pop * (1.0 - 0.45 * leave))
		var alpha := smoothstep(0.0, 0.08, t) * (1.0 - leave)
		for leaf in all_leaves:
			_leaf_param(leaf, "opacity", alpha)
		aura.global_position = at + bob - CAMERA_DIR * 0.05
		aura.scale = Vector3.ONE * (1.0 + 0.1 * sin(t * 14.0)) * (0.7 + 0.3 * pop)
		show_with(aura, 0.55 * alpha))
	_leaf_angle(back, 0.0)
	_leaf_angle(front, 0.0)
	for leaf in leaves:
		_leaf_angle(leaf, 0.0)
	# 封面翻开。
	track(0.14, 0.22, func(x: float) -> void:
		_leaf_angle(front, PI * ease_in_out(x))
		_leaf_param(front, "flip_shade", sin(PI * x)))
	# 书页一张接一张翻过去，翻动时符文亮起。
	for k in leaves.size():
		var leaf := leaves[k]
		var start := 0.32 + 0.11 * float(k)
		track(start, 0.24, func(x: float) -> void:
			_leaf_angle(leaf, PI * ease_in_out(x))
			_leaf_param(leaf, "flip_shade", sin(PI * x))
			_leaf_param(leaf, "glow", 0.35 + 0.65 * sin(PI * x)))
	# 翻页时从书缝飞出的小魂火。
	var flutter_n := QUALITY_BUDGET.particle_count_for(10)
	var flutter := motes("BookFlutter", flutter_n, {"softness": 0.5, "core_white": 0.6})
	var fspecs: Array[Dictionary] = []
	for k in flutter_n:
		var a := _rng.randf_range(-PI * 0.85, -PI * 0.15)
		fspecs.append({"t0": 0.3 + _rng.randf() * 0.7, "v": (Vector3.RIGHT * cos(a) * 0.6 + SCREEN_UP * -sin(a)) * _rng.randf_range(0.4, 0.8), "s": _rng.randf_range(0.05, 0.10)})
	track(0.3, 1.1, func(x: float) -> void:
		var t := 0.3 + x * 1.1
		var at := book_at + _drift(head_ref, head_base)
		for k in fspecs.size():
			var s: Dictionary = fspecs[k]
			var u := clampf((t - float(s["t0"])) / 0.5, 0.0, 1.0)
			set_mote(flutter, k, at + (s["v"] as Vector3) * u + Vector3.UP * 0.15 * u, float(s["s"]), (1.0 - u) * smoothstep(0.0, 0.1, u))
		show_with(flutter, 1.0))
	# 书前浮起「亡魂之眼」。
	var sigil_end := close_at if has_victim else 0.95
	track(0.36, sigil_end - 0.36, func(x: float) -> void:
		var at := book_at + _drift(head_ref, head_base) + SCREEN_UP * 0.55 + CAMERA_DIR * 0.12
		sigil.global_position = at
		var fizzle := 0.0 if has_victim else smoothstep(0.7, 1.0, x)
		sigil.scale = Vector3.ONE * (lerpf(0.3, 0.7, ease_out(minf(1.0, x * 3.0))) + 0.3 * fizzle)
		set_param(sigil, "spin", 0.15 * sin(x * 9.0))
		show_with(sigil, 0.95 * smoothstep(0.0, 0.1, x) * (1.0 - smoothstep(0.82, 1.0, x))))
	if has_victim:
		_book_victim(target, context, heavy, book_at, head_ref, head_base, leaves)
	else:
		_debug["empty"] = true
		# 空翻：眼印化作一把散开的灰绿余烬。
		var ash := motes("BookAsh", QUALITY_BUDGET.particle_count_for(8), {"softness": 0.6, "core_white": 0.2, "edge_dark": 0.7})
		var dirs: Array[Vector3] = []
		for k in ash.multimesh.instance_count:
			var a := _rng.randf() * TAU
			dirs.append((Vector3.RIGHT * cos(a) + SCREEN_UP * sin(a)) * _rng.randf_range(0.25, 0.55))
		track(0.85, 0.5, func(x: float) -> void:
			var at := book_at + _drift(head_ref, head_base) + SCREEN_UP * 0.55 + CAMERA_DIR * 0.12
			for k in dirs.size():
				set_mote(ash, k, at + dirs[k] * ease_out(x) + Vector3.DOWN * 0.2 * x * x, 0.08, 0.8 * (1.0 - x))
			show_with(ash, 1.0))
	# 合书：左侧整叠（封面 + 翻过的页）一起拍回，合上瞬间爆一圈魂光。
	var stack: Array[Node3D] = leaves.duplicate()
	stack.append(front)
	for k in stack.size():
		var leaf := stack[k]
		track(close_at + 0.01 * float(stack.size() - 1 - k), 0.16, func(x: float) -> void:
			_leaf_angle(leaf, PI * (1.0 - ease_in(x, 2.4)))
			_leaf_param(leaf, "glow", 0.4 * (1.0 - x)))
	var slam := g("BookSlam", book_at, 1.0, {"shape": SHAPE_FLARE, "core_white": 0.85})
	var slam_ring := g("BookSlamRing", book_at, 1.0, {"shape": SHAPE_RING, "ring_radius": 0.8, "ring_width": 0.08, "breakup": 0.4, "core_white": 0.45})
	track(close_at + 0.17, 0.36, func(x: float) -> void:
		var at := book_at + _drift(head_ref, head_base) + CAMERA_DIR * 0.1
		slam.global_position = at
		slam_ring.global_position = at
		slam.scale = Vector3.ONE * lerpf(0.4, 1.2, ease_out(x))
		set_param(slam, "spin", 0.3 + x)
		slam_ring.scale = Vector3.ONE * lerpf(0.3, 1.4, ease_out(x))
		show_with(slam, 0.95 * (1.0 - x))
		show_with(slam_ring, 0.7 * (1.0 - x)))
	keep_alive_until(life)


func _book_victim(target: Vector3, context: Dictionary, heavy: bool, book_at: Vector3, head_ref: WeakRef, head_base: Vector3, leaves: Array[Node3D]) -> void:
	var th := height_of(context, "target_height")
	var foot: Vector3 = context.get("target_foot", target)
	var ref := weak_node(context.get("target_node"))
	var base := node_position(ref, foot)
	# 目标被处决当帧就死了：节点一旦消失，标记留在最后的位置，不再跟随。
	var mark := g("SoulMark", foot + Vector3.UP * th * 1.25, 0.6, {"shape": SHAPE_SEAL, "pattern": 6, "seal_rings": 0.0, "stroke": 0.08, "fill": 0.0, "core_white": 0.6})
	var ring := gd("SoulRing", foot + Vector3.UP * 0.03, Vector2(0.6, 0.6), {"ring_radius": 0.8, "ring_width": 0.12, "breakup": 0.6, "fill": 0.45, "core_white": 0.45, "edge_dark": 0.2})
	var mark_size := 1.0 if heavy else 0.78
	var hit_time := _soul_wave(foot, th, ref, base, book_at, head_ref, head_base)
	track(hit_time - 0.02, 0.85, func(x: float) -> void:
		var at := foot + _drift(ref, base)
		mark.global_position = toward_camera(at + Vector3.UP * th * 1.25, 0.15)
		mark.scale = Vector3.ONE * lerpf(mark_size * 1.9, mark_size, ease_out(minf(1.0, x * 3.0)))
		show_with(mark, 0.95 * envelope(x, 0.08, 0.3))
		ring.global_position = at + Vector3.UP * 0.03
		set_param(ring, "reveal", minf(1.0, x * 2.5))
		ring.rotation.y = x * 1.5
		show_with(ring, 0.75 * envelope(x, 0.05, 0.3)))
	if heavy:
		_debug["heavy_hit"] = true
		var crash := g("SoulCrash", foot + Vector3.UP * th * 0.6, 1.4, {"shape": SHAPE_FLARE, "core_white": 0.9})
		var shock := gd("SoulShock", foot + Vector3.UP * 0.03, Vector2.ONE, {"ring_radius": 0.9, "ring_width": 0.09, "breakup": 0.45, "core_white": 0.5})
		track(hit_time, 0.4, func(x: float) -> void:
			var at := foot + _drift(ref, base)
			crash.global_position = toward_camera(at + Vector3.UP * th * 0.6, 0.25)
			crash.scale = Vector3.ONE * lerpf(0.5, 1.7, ease_out(x))
			set_param(crash, "spin", x)
			show_with(crash, 1.0 * (1.0 - x))
			var r := lerpf(0.3, 1.5, ease_out(x))
			shock.global_position = at + Vector3.UP * 0.03
			shock.scale = Vector3(r * 2.0, 1.0, r * 2.0)
			show_with(shock, 0.8 * (1.0 - x)))
		var shards := shard_cloud("SoulShards", QUALITY_BUDGET.particle_count_for(10), SOUL_BODY)
		var flying := scatter(shards.multimesh.instance_count, foot + Vector3.UP * th * 0.6, Vector3.ZERO, 1.8, 1.4, 0.9)
		track(hit_time, 0.6, func(x: float) -> void:
			drive_shards(shards, flying, x, 0.6, 0.07, 0.9))
	# 魂火：从目标身上升起，沿弧线飞回书里，到书时书页一亮。
	var wisp_count := 1 if heavy else (2 if QUALITY_BUDGET.tier == 0 else 3)
	_debug["wisps"] = wisp_count
	for j in wisp_count:
		var start := hit_time + 0.16 + 0.10 * float(j)
		var travel := 0.48
		var lean := (float(j) - float(wisp_count - 1) * 0.5) * 0.5
		var wisp := g("SoulWisp%d" % j, foot, 0.32, {"core_white": 0.9, "softness": 0.5})
		var tail_n := QUALITY_BUDGET.particle_count_for(14)
		var tail := motes("SoulTail%d" % j, tail_n, {"softness": 0.6, "core_white": 0.5})
		var from := foot + Vector3.UP * th * 0.6
		var path := func(u: float) -> Vector3:
			var a := from + _drift(ref, base)
			var c := book_at + _drift(head_ref, head_base)
			var b := a.lerp(c, 0.4) + Vector3.UP * 0.9 + Vector3.RIGHT * lean
			return bezier(a, b, c, u)
		track(start, travel, func(x: float) -> void:
			var u := ease_in_out(x)
			var at: Vector3 = path.call(u)
			wisp.global_position = toward_camera(at, 0.2)
			wisp.scale = Vector3.ONE * (0.46 + 0.06 * sin(x * 33.0)) * (1.0 - 0.4 * smoothstep(0.85, 1.0, x))
			show_with(wisp, smoothstep(0.0, 0.1, x) * (1.0 - smoothstep(0.92, 1.0, x)))
			for k in tail_n:
				var lag := u - float(k + 1) * 0.03
				if lag <= 0.0:
					set_mote(tail, k, at, 0.01, 0.0)
					continue
				var sway := Vector3(sin(float(k) * 1.9 + x * 14.0), 0.0, 0.0) * 0.025 * float(k)
				set_mote(tail, k, toward_camera((path.call(lag) as Vector3) + sway, 0.18), 0.30 * (1.0 - float(k) / float(tail_n)) + 0.04, 0.9 * (1.0 - float(k) / float(tail_n)) * (1.0 - smoothstep(0.92, 1.0, x)))
			show_with(tail, 1.0))
		track(start + travel - 0.02, 0.25, func(x: float) -> void:
			for leaf in leaves:
				_leaf_param(leaf, "glow", 0.9 * (1.0 - x)))


# 书翻开后从书里射出一道弧形魂光波（新月形光刃 + 拖尾光束 + 粒子），飞到目标身上
# 收拢成两圈旋转的光环把人「收掉」。返回命中时刻，眼印 / 重击 / 魂火都从这一刻接上。
func _soul_wave(foot: Vector3, th: float, ref: WeakRef, base: Vector3, book_at: Vector3, head_ref: WeakRef, head_base: Vector3) -> float:
	var launch := 0.48
	var src := book_at
	var dst := foot + Vector3.UP * th * 0.6
	var distance := Vector2(dst.x - src.x, dst.z - src.z).length()
	var travel := clampf(0.18 + distance / 9.0, 0.22, 0.45)
	var hit_time := launch + travel
	_debug["wave"] = true
	_debug["wave_hit"] = hit_time
	var blade := g("SoulWave", src, 1.2, {"shape": SHAPE_RING, "ring_radius": 0.62, "ring_width": 0.2, "arc_span": 0.42, "arc_start": 0.0, "breakup": 0.25, "core_white": 0.85, "edge_dark": 0.15})
	var blade2 := g("SoulWaveEcho", src, 1.0, {"shape": SHAPE_RING, "ring_radius": 0.52, "ring_width": 0.12, "arc_span": 0.32, "arc_start": 0.0, "breakup": 0.4, "core_white": 0.5, "edge_dark": 0.2})
	var beam := streak("SoulBeam", _p({"core_white": 0.6, "edge_dark": 0.25}))
	var spray_n := QUALITY_BUDGET.particle_count_for(16)
	var spray := motes("SoulWaveSpray", spray_n, {"softness": 0.5, "core_white": 0.6})
	var jitter: Array[Vector3] = []
	for k in spray_n:
		jitter.append(Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 0.18)
	var flight := func(u: float) -> Vector3:
		var a := book_at + _drift(head_ref, head_base)
		var c := dst + _drift(ref, base)
		return toward_camera(a.lerp(c, u) + Vector3.UP * sin(u * PI) * 0.25, 0.2)
	track(launch, travel, func(x: float) -> void:
		var u := ease_in(x, 1.3)
		var at: Vector3 = flight.call(u)
		var ahead: Vector3 = flight.call(minf(1.0, u + 0.05))
		var angle := screen_angle(at, ahead) if ahead.distance_to(at) > 0.0001 else 0.0
		var grow := lerpf(0.7, 1.35, ease_out(x))
		blade.global_position = at
		blade.scale = Vector3.ONE * grow
		set_param(blade, "spin", angle)
		show_with(blade, smoothstep(0.0, 0.1, x))
		blade2.global_position = flight.call(maxf(0.0, u - 0.07))
		blade2.scale = Vector3.ONE * grow * 0.9
		set_param(blade2, "spin", angle)
		show_with(blade2, 0.7 * smoothstep(0.0, 0.15, x))
		var tail: Vector3 = flight.call(maxf(0.0, u - 0.45))
		place_streak(beam, tail, at, 0.22 * grow)
		show_with(beam, 0.85 * smoothstep(0.0, 0.1, x))
		for k in spray_n:
			var lag := u - float(k) / float(spray_n) * 0.4
			if lag <= 0.0:
				set_mote(spray, k, at, 0.01, 0.0)
				continue
			set_mote(spray, k, (flight.call(lag) as Vector3) + jitter[k] * (1.0 + 2.0 * (u - lag)), 0.12 * (1.0 - float(k) / float(spray_n)) + 0.03, 0.9 * (1.0 - float(k) / float(spray_n)))
		show_with(spray, 1.0))
	track(hit_time, 0.02, func(_x: float) -> void:
		show_with(blade, 0.0)
		show_with(blade2, 0.0)
		show_with(beam, 0.0)
		show_with(spray, 0.0))
	# 收人：两圈相向旋转的魂光环从大到小勒到目标身上，中间一记爆闪。
	var bind_a := g("SoulBindA", dst, 1.0, {"shape": SHAPE_RING, "ring_radius": 0.8, "ring_width": 0.12, "arc_span": 0.7, "breakup": 0.3, "core_white": 0.7, "edge_dark": 0.1})
	var bind_b := g("SoulBindB", dst, 1.0, {"shape": SHAPE_RING, "ring_radius": 0.8, "ring_width": 0.10, "arc_span": 0.7, "arc_start": PI, "breakup": 0.3, "core_white": 0.6, "edge_dark": 0.1})
	var snap := g("SoulSnap", dst, 1.2, {"shape": SHAPE_FLARE, "core_white": 0.9})
	track(hit_time, 0.5, func(x: float) -> void:
		var at := toward_camera(dst + _drift(ref, base), 0.25)
		var r := lerpf(1.7, 0.55, ease_out(x, 2.2))
		bind_a.global_position = at
		bind_b.global_position = at
		bind_a.scale = Vector3.ONE * r
		bind_b.scale = Vector3.ONE * r * 0.85
		set_param(bind_a, "spin", x * 7.0)
		set_param(bind_b, "spin", -x * 8.0)
		show_with(bind_a, 0.95 * (1.0 - smoothstep(0.7, 1.0, x)))
		show_with(bind_b, 0.85 * (1.0 - smoothstep(0.7, 1.0, x)))
		snap.global_position = at
		snap.scale = Vector3.ONE * lerpf(0.5, 1.5, ease_out(x))
		set_param(snap, "spin", x)
		show_with(snap, 1.0 - smoothstep(0.0, 0.6, x)))
	return hit_time
