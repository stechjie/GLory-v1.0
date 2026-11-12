extends Node3D
class_name VFXAuthoredProjectileBatch3D

# 11.12：怪物 / Boss / 佣兵远程普攻弹道（AUTHORED_UNIT_PROJECTILE_PROFILES 那 7 种）的合批渲染。
#
# 为什么要换：原来每打一发都 new 一个 VFXAuthoredUnitProjectile3D，里面再 new 出手光、弹体、
# 3 层残影、命中光（各一个 VFXBlockRoot + MeshInstance + 新 QuadMesh + 新 ShaderMaterial），
# 命中再 new 4~6 片碎片（每片现场建 ArrayMesh 和 StandardMaterial3D）。一发十几个节点、
# 十几次绘制，而且每个精灵都算进全局并发计数 —— 第 20 回合实测一场被丢弃 1200 次，
# 78% 就是它。
#
# 现在：同一张贴图的所有精灵共用一个 MultiMeshInstance3D（一次绘制），全部碎片共用另一个；
# 每发只是几行数据，由本节点一个 _process 统一推进。不是 VFXBlockRoot，不占并发计数，
# 也就不再需要被丢弃。
#
# 外观逐项照抄 VFXAuthoredUnitProjectile3D（时序、尺寸、颜色、透明度曲线、弧线、
# 摆动、残影节奏、碎片飞散），对照截图见 11.12 的记录。有一处刻意「照抄现状」：
# 原模块对精灵做的 scale 补间（出手 0.2→0.88、命中 0.18→1.04、残影收缩、弹体呼吸）
# 从来没有生效过 —— 精灵着色器的 billboard 用 INV_VIEW_MATRIX 重建了矩阵，把节点缩放丢掉了，
# 屏幕上一直是固定尺寸。这里保持屏幕上的样子不变，不顺手「修好」它。

const MIN_TRAVEL_TIME := 0.28
const MAX_TRAVEL_TIME := 0.80
const MAX_AFTERIMAGES := 3
const RELEASE_DELAY := 0.045
const FADE_IN := 0.012
const RELEASE_LIFE := 0.14
const AFTERIMAGE_LIFE := 0.16
const IMPACT_LIFE := 0.22
const SHARD_LIFE := 0.24
const INITIAL_CAPACITY := 64

# 与 VFXBlockRoot.CAMERA_DIR 同一个方向（朝战斗相机）。
const CAMERA_DIR := Vector3(0.0, 0.727, 0.687)

enum CardKind { AFTERIMAGE, RELEASE, BODY, IMPACT }

# 与 VFXSpriteFlipbook3D.FLIPBOOK_SHADER 的单帧情形逐行对应；尺寸 / 旋转 / 颜色改从实例数据读。
# 原着色器的 EMISSION 在 unshaded 下不起作用，这里省掉。
const CARD_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform sampler2D atlas_texture : source_color;
varying float v_rotation;
// 实例颜色不像 `source_color` 的 uniform 那样自动转线性；照 Godot 对 source_color 的做法手动转，
// 否则同一个 tint 在 Forward+/Mobile 下会偏亮偏白（原模块的 tint 是 source_color uniform）。
vec3 tint_to_render_space(vec3 c, bool output_is_srgb) {
    if (output_is_srgb) {
        return c;
    }
    return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}
void vertex() {
    VERTEX.xy *= INSTANCE_CUSTOM.xy;
    v_rotation = INSTANCE_CUSTOM.z;
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
    vec2 centered_uv = UV - vec2(0.5);
    float rotation_cos = cos(v_rotation);
    float rotation_sin = sin(v_rotation);
    vec2 local_uv = vec2(
        centered_uv.x * rotation_cos - centered_uv.y * rotation_sin,
        centered_uv.x * rotation_sin + centered_uv.y * rotation_cos
    ) + vec2(0.5);
    float inside_card = step(0.0, local_uv.x) * step(local_uv.x, 1.0) * step(0.0, local_uv.y) * step(local_uv.y, 1.0);
    vec4 tex = texture(atlas_texture, clamp(local_uv, vec2(0.001), vec2(0.999)));
    vec2 p = abs(UV - vec2(0.5)) * 2.0;
    float card_fade = smoothstep(1.0, 0.72, max(p.x, p.y));
    ALBEDO = tex.rgb * tint_to_render_space(COLOR.rgb, OUTPUT_IS_SRGB);
    ALPHA = tex.a * card_fade * inside_card * COLOR.a;
}
"""
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")


class Card:
	var kind := 0
	var pos := Vector3.ZERO
	var size := Vector2.ONE
	var rotation := 0.0
	var color := Color.WHITE
	var age := 0.0
	var life := -1.0 # -1：弹体，随 Shot 一起结束


class Shot:
	var lane: Lane
	var origin := Vector3.ZERO
	var target := Vector3.ZERO
	var target_ref: WeakRef = null
	var size := 0.5
	var core_color := Color.WHITE
	var main_color := Color.WHITE
	var particle_count := 6
	var speed := 6.4
	var arc_height := 0.12
	var trail_interval := 0.095
	var trail_alpha := 0.16
	var impact_scale := 1.45
	var motion_style := "steady"
	var motion_amplitude := 0.025
	var motion_frequency := 2.0
	var wait := RELEASE_DELAY
	var travel_duration := 0.0
	var elapsed := 0.0
	var trail_elapsed := 0.0
	var trail_index := 0
	var pos := Vector3.ZERO
	var facing := 0.0
	var body: Card = null


class Shard:
	var base := Vector3.ZERO
	var start := Vector3.ZERO
	var end := Vector3.ZERO
	var angle := 0.0
	var length := 0.1
	var width := 0.02
	var color := Color.WHITE
	var age := 0.0


class Lane:
	var texture_path := ""
	var instance: MultiMeshInstance3D
	var multimesh: MultiMesh
	var cards: Array[Card] = []
	var buffer := PackedFloat32Array()


var _lanes: Dictionary = {} # texture_path -> Lane
var _shots: Array[Shot] = []
var _shards: Array[Shard] = []
var _shard_instance: MultiMeshInstance3D
var _shard_multimesh: MultiMesh
var _shard_buffer := PackedFloat32Array()


func _ready() -> void:
	set_process(false)


func active_shot_count() -> int:
	return _shots.size()


func play(profile: VFXProfile3D, origin: Vector3, target: Vector3, target_node: Variant = null) -> void:
	if profile == null:
		return
	var params: Dictionary = profile.parameters
	var lane := _lane_for(str(params.get("texture", "")))
	if lane == null:
		return
	var shot := Shot.new()
	shot.lane = lane
	shot.origin = origin
	shot.target = target
	if is_instance_valid(target_node) and target_node is Node3D:
		shot.target_ref = weakref(target_node)
	shot.size = profile.size
	shot.core_color = profile.core_color
	shot.main_color = profile.main_color
	shot.particle_count = profile.particle_count
	shot.speed = maxf(0.5, float(params.get("speed", 6.4)))
	shot.arc_height = maxf(0.0, float(params.get("arc_height", 0.12)))
	shot.trail_interval = clampf(float(params.get("trail_interval", 0.095)), 0.07, 0.16)
	shot.trail_alpha = clampf(float(params.get("trail_alpha", 0.16)), 0.08, 0.24)
	shot.impact_scale = float(params.get("impact_scale", 1.45))
	shot.motion_style = str(params.get("motion_style", "steady"))
	shot.motion_amplitude = clampf(float(params.get("motion_amplitude", 0.025)), 0.0, 0.12)
	shot.motion_frequency = clampf(float(params.get("motion_frequency", 2.0)), 0.5, 5.0)
	shot.trail_elapsed = shot.trail_interval * 0.55
	var tracked := _tracked_target_position(target, shot.target_ref)
	shot.target = tracked
	shot.facing = _screen_facing(origin, tracked)
	shot.pos = origin + CAMERA_DIR * 0.10
	var release_tint := shot.core_color
	release_tint.a = 0.34
	_add_card(lane, CardKind.RELEASE, shot.pos, Vector2.ONE * shot.size * 0.78, shot.facing, release_tint, RELEASE_LIFE)
	_shots.append(shot)
	set_process(true)


func _process(delta: float) -> void:
	_step_shots(delta)
	_step_cards(delta)
	_step_shards(delta)
	_write_instances()
	if _shots.is_empty() and _shards.is_empty() and _all_lanes_empty():
		set_process(false)


func _step_shots(delta: float) -> void:
	var i := 0
	while i < _shots.size():
		var shot := _shots[i]
		if _advance_shot(shot, delta):
			i += 1
		else:
			_shots.remove_at(i)


# 返回 false 表示这一发已经命中、可以移除。
func _advance_shot(shot: Shot, delta: float) -> bool:
	if shot.wait > 0.0:
		shot.wait -= delta
		if shot.wait > 0.0:
			return true
		# 等待结束的这一帧建弹体（原模块：0.045s 计时器到点后建弹体，下一帧才开始移动）。
		var distance := shot.origin.distance_to(shot.target)
		shot.travel_duration = clampf(distance / shot.speed, MIN_TRAVEL_TIME, MAX_TRAVEL_TIME)
		shot.body = _add_card(shot.lane, CardKind.BODY, shot.pos, Vector2.ONE * shot.size * 1.50, shot.facing, Color.WHITE, -1.0)
		return true
	shot.elapsed += delta
	shot.trail_elapsed += delta
	shot.target = _tracked_target_position(shot.target, shot.target_ref)
	var ratio := clampf(shot.elapsed / shot.travel_duration, 0.0, 1.0)
	var motion := _motion_sample(shot.motion_style, ratio, shot.motion_amplitude, shot.motion_frequency)
	shot.pos = shot.origin.lerp(shot.target, ratio) \
		+ Vector3(0.0, shot.arc_height * sin(ratio * PI) + motion.x, 0.0) \
		+ CAMERA_DIR * 0.10
	shot.facing = _screen_facing(shot.origin, shot.target) + motion.y
	shot.body.pos = shot.pos
	shot.body.rotation = shot.facing
	if shot.trail_elapsed >= shot.trail_interval and shot.trail_index < MAX_AFTERIMAGES:
		shot.trail_elapsed = 0.0
		var ghost_tint := shot.core_color
		ghost_tint.a = shot.trail_alpha
		_add_card(shot.lane, CardKind.AFTERIMAGE, shot.pos - CAMERA_DIR * 0.012, Vector2.ONE * shot.size * 1.18, shot.facing, ghost_tint, AFTERIMAGE_LIFE)
		shot.trail_index += 1
	if shot.elapsed < shot.travel_duration:
		return true
	shot.lane.cards.erase(shot.body)
	shot.body = null
	var impact_tint := shot.core_color.lerp(Color.WHITE, 0.28)
	impact_tint.a = 0.70
	_add_card(shot.lane, CardKind.IMPACT, shot.pos, Vector2.ONE * shot.size * shot.impact_scale, shot.facing + PI * 0.5, impact_tint, IMPACT_LIFE)
	_spawn_shards(shot)
	return false


func _spawn_shards(shot: Shot) -> void:
	var shard_count := clampi(shot.particle_count, 4, 6)
	for index in range(shard_count):
		var angle := shot.facing + (-0.92 + float(index) * 1.84 / maxf(1.0, float(shard_count - 1)))
		var direction := Vector3(cos(angle), sin(angle), 0.0).normalized()
		var shard := Shard.new()
		shard.base = shot.pos
		shard.start = CAMERA_DIR * (0.02 + float(index) * 0.003)
		shard.end = direction * shot.size * (0.58 + 0.08 * float(index % 2))
		shard.angle = angle
		shard.length = shot.size * (0.22 + 0.025 * float(index % 3))
		shard.width = shot.size * (0.035 + 0.008 * float(index % 2))
		shard.color = shot.core_color if index % 3 == 0 else shot.main_color
		_shards.append(shard)


func _step_cards(delta: float) -> void:
	for lane: Lane in _lanes.values():
		var i := 0
		while i < lane.cards.size():
			var card := lane.cards[i]
			card.age += delta
			if card.life > 0.0 and card.age >= card.life:
				lane.cards.remove_at(i)
			else:
				i += 1


func _step_shards(delta: float) -> void:
	var i := 0
	while i < _shards.size():
		_shards[i].age += delta
		if _shards[i].age >= SHARD_LIFE:
			_shards.remove_at(i)
		else:
			i += 1


# 透明度曲线：原模块用 tween_method(set_vfx_alpha, 1→0, life, TRANS_QUAD, EASE_IN) = 1 - t²，
# 再乘精灵自己的 0.012s 淡入。弹体只有淡入。
func _card_alpha(card: Card) -> float:
	var fade_in := smoothstep(0.0, FADE_IN, card.age)
	if card.life <= 0.0:
		return fade_in
	var t := clampf(card.age / card.life, 0.0, 1.0)
	return (1.0 - t * t) * fade_in


func _write_instances() -> void:
	for lane: Lane in _lanes.values():
		_write_lane(lane)
	_write_shards()


# 每帧整块写 MultiMesh.buffer（一次赋值），不逐个实例调 set_instance_*：
# 第 20 回合同屏 355 个实例时，逐个调用在桌面上最坏一帧 1.8ms，手机上会再放大几倍。
# 布局（Godot MultiMesh TRANSFORM_3D）：每实例 3x4 变换按行 12 个数，然后颜色 4 个，自定义数据 4 个。
const CARD_STRIDE := 20
const SHARD_STRIDE := 16
const CARD_ORDER := [CardKind.AFTERIMAGE, CardKind.BODY, CardKind.RELEASE, CardKind.IMPACT]


func _write_lane(lane: Lane) -> void:
	var count := lane.cards.size()
	if count > lane.multimesh.instance_count:
		_grow(lane.multimesh, count)
		lane.buffer.resize(lane.multimesh.instance_count * CARD_STRIDE)
	lane.multimesh.visible_instance_count = count
	if count == 0:
		return
	# 叠放顺序：残影 → 弹体 → 出手光 → 命中光。原来各自是独立节点、靠深度排序；这个顺序是
	# 和原模块逐帧截图对比后最接近的一种（11.12）。
	var buf := lane.buffer
	var o := 0
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for kind in CARD_ORDER:
		for card in lane.cards:
			if card.kind != kind:
				continue
			var p := card.pos
			buf[o] = 1.0; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = p.x
			buf[o + 4] = 0.0; buf[o + 5] = 1.0; buf[o + 6] = 0.0; buf[o + 7] = p.y
			buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = 1.0; buf[o + 11] = p.z
			var c := card.color
			buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = c.a * _card_alpha(card)
			buf[o + 16] = card.size.x; buf[o + 17] = card.size.y; buf[o + 18] = card.rotation; buf[o + 19] = 0.0
			o += CARD_STRIDE
			var half := maxf(card.size.x, card.size.y) * 0.5
			lo = Vector3(minf(lo.x, p.x - half), minf(lo.y, p.y - half), minf(lo.z, p.z - half))
			hi = Vector3(maxf(hi.x, p.x + half), maxf(hi.y, p.y + half), maxf(hi.z, p.z + half))
	lane.buffer = buf
	lane.multimesh.buffer = buf
	# 实例跟着弹道满场跑，MultiMesh 自己的包围盒不会更新；按当前实例算，既不被误剔除，
	# 透明排序也落在弹道实际所在的位置附近。
	lane.instance.custom_aabb = AABB(lo, hi - lo)


func _write_shards() -> void:
	if _shard_multimesh == null:
		if _shards.is_empty():
			return
		_build_shard_instance()
	var count := _shards.size()
	if count > _shard_multimesh.instance_count:
		_grow(_shard_multimesh, count)
		_shard_buffer.resize(_shard_multimesh.instance_count * SHARD_STRIDE)
	_shard_multimesh.visible_instance_count = count
	if count == 0:
		return
	var buf := _shard_buffer
	var o := 0
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for shard in _shards:
		var t := clampf(shard.age / SHARD_LIFE, 0.0, 1.0)
		# 原模块三条并行补间：位置 QUART/EASE_OUT，缩放 1→0.05 QUAD/EASE_IN，transparency 线性 0→1。
		var move := 1.0 - pow(1.0 - t, 4.0)
		var scale := lerpf(1.0, 0.05, t * t)
		var p := shard.base + shard.start.lerp(shard.end, move)
		# 变换 = 绕 Z 转 angle × 缩放 (length·s, width·s, 1)，按行写出。
		var ca := cos(shard.angle)
		var sa := sin(shard.angle)
		var sx := shard.length * scale
		var sy := shard.width * scale
		buf[o] = ca * sx; buf[o + 1] = -sa * sy; buf[o + 2] = 0.0; buf[o + 3] = p.x
		buf[o + 4] = sa * sx; buf[o + 5] = ca * sy; buf[o + 6] = 0.0; buf[o + 7] = p.y
		buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = 1.0; buf[o + 11] = p.z
		var c := shard.color
		buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = c.a * (1.0 - t)
		o += SHARD_STRIDE
		var r := shard.length
		lo = Vector3(minf(lo.x, p.x - r), minf(lo.y, p.y - r), minf(lo.z, p.z - r))
		hi = Vector3(maxf(hi.x, p.x + r), maxf(hi.y, p.y + r), maxf(hi.z, p.z + r))
	_shard_buffer = buf
	_shard_multimesh.buffer = buf
	_shard_instance.custom_aabb = AABB(lo, hi - lo)


func _grow(multimesh: MultiMesh, needed: int) -> void:
	var capacity := maxi(INITIAL_CAPACITY, multimesh.instance_count)
	while capacity < needed:
		capacity *= 2
	# 改 instance_count 会清空实例数据；每帧本来就整批重写，所以无妨。
	multimesh.instance_count = capacity


func _all_lanes_empty() -> bool:
	for lane: Lane in _lanes.values():
		if not lane.cards.is_empty():
			return false
	return true


func _add_card(lane: Lane, kind: int, pos: Vector3, size: Vector2, rotation: float, color: Color, life: float) -> Card:
	var card := Card.new()
	card.kind = kind
	card.pos = pos
	card.size = size
	card.rotation = rotation
	card.color = color
	card.life = life
	lane.cards.append(card)
	return card


func _lane_for(texture_path: String) -> Lane:
	var existing: Lane = _lanes.get(texture_path)
	if existing != null:
		return existing
	var texture := _load_texture(texture_path)
	if texture == null:
		push_warning("Authored unit projectile texture missing: %s" % texture_path)
		return null
	var lane := Lane.new()
	lane.texture_path = texture_path
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	lane.multimesh = MultiMesh.new()
	lane.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	lane.multimesh.use_colors = true
	lane.multimesh.use_custom_data = true
	lane.multimesh.mesh = quad
	lane.multimesh.instance_count = INITIAL_CAPACITY
	lane.multimesh.visible_instance_count = 0
	lane.buffer.resize(INITIAL_CAPACITY * CARD_STRIDE)
	var material := ShaderMaterial.new()
	material.shader = SHADER_CACHE.get_shader(CARD_SHADER)
	material.set_shader_parameter("atlas_texture", texture)
	lane.instance = MultiMeshInstance3D.new()
	lane.instance.name = "AuthoredProjectileCards_" + texture_path.get_file().get_basename()
	lane.instance.multimesh = lane.multimesh
	lane.instance.material_override = material
	lane.instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lane.instance)
	_lanes[texture_path] = lane
	return lane


# 碎片：与原模块 _make_shard 同一套材质设置，三角形按 length=width=1 建一次，尺寸放进实例变换。
func _build_shard_instance() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.40, -1.0, 0.0),
		Vector3(-0.34, 1.0, 0.0),
		Vector3(0.60, 0.0, 0.0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.no_depth_test = true
	material.vertex_color_use_as_albedo = true
	# 原模块把颜色写在 albedo_color（按 sRGB 转线性）；实例颜色要显式声明同样的色彩空间。
	material.vertex_color_is_srgb = true
	# 碎片画在卡片之后：同样是对比截图后最接近原模块的顺序。
	material.render_priority = 1
	material.albedo_color = Color.WHITE
	_shard_multimesh = MultiMesh.new()
	_shard_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_shard_multimesh.use_colors = true
	_shard_multimesh.mesh = mesh
	_shard_multimesh.instance_count = INITIAL_CAPACITY
	_shard_multimesh.visible_instance_count = 0
	_shard_buffer.resize(INITIAL_CAPACITY * SHARD_STRIDE)
	_shard_instance = MultiMeshInstance3D.new()
	_shard_instance.name = "AuthoredProjectileShards"
	_shard_instance.multimesh = _shard_multimesh
	_shard_instance.material_override = material
	_shard_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shard_instance)


# 贴图走 VFXManager 的缓存（同 VFXBlockRoot.vfx_texture），没有 autoload 时退回 load()。
func _load_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if is_inside_tree():
		var manager := get_tree().root.get_node_or_null("VFXManager")
		if manager != null and manager.has_method("get_texture"):
			return manager.call("get_texture", path) as Texture2D
	return load(path) as Texture2D


func _tracked_target_position(fallback: Vector3, target_ref: WeakRef) -> Vector3:
	if target_ref == null:
		return fallback
	var target_node: Variant = target_ref.get_ref()
	if not is_instance_valid(target_node) or not (target_node is Node3D):
		return fallback
	var tracked := to_local((target_node as Node3D).global_position)
	tracked.y = fallback.y
	return tracked


func _screen_facing(from: Vector3, to: Vector3) -> float:
	var delta := to - from
	var screen_y := delta.y * 0.688 - delta.z * 0.726
	if absf(delta.x) < 0.0001 and absf(screen_y) < 0.0001:
		return PI * 0.5
	return atan2(screen_y, delta.x)


# Returns vertical offset, rotation offset, width scale and height scale.
# 与原模块同一张表；宽高缩放对 billboard 精灵不生效（见文件头），只用前两项。
func _motion_sample(style: String, ratio: float, amplitude: float, frequency: float) -> Vector4:
	var phase := ratio * TAU * frequency
	var vertical := 0.0
	var rotation := 0.0
	var scale_x := 1.0
	var scale_y := 1.0
	match style:
		"echo":
			vertical = sin(phase) * amplitude * 0.42
			rotation = sin(phase * 0.52) * amplitude * 0.55
			scale_x += sin(phase) * amplitude * 0.55
		"wobble":
			vertical = sin(phase) * amplitude
			rotation = sin(phase * 0.86) * amplitude * 1.35
			scale_y += cos(phase) * amplitude * 0.65
		"tumble":
			vertical = sin(phase) * amplitude * 0.32
			rotation = sin(phase * 0.72) * amplitude * 1.70
		"resonance":
			vertical = sin(phase) * amplitude * 0.45
			scale_x += cos(phase) * amplitude * 0.45
			scale_y += sin(phase) * amplitude * 1.45
		"flutter":
			vertical = sin(phase) * amplitude * 1.15
			rotation = sin(phase * 0.70) * amplitude * 0.75
			scale_y += sin(phase * 1.35) * amplitude * 2.10
		"heavy":
			vertical = sin(phase) * amplitude * 0.28
			rotation = sin(phase * 0.55) * amplitude * 0.42
		"swing":
			vertical = sin(phase * 0.72) * amplitude * 0.42
			rotation = sin(phase) * amplitude * 1.85
	return Vector4(vertical, rotation, scale_x, scale_y)
