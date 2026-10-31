extends VFXBlockRoot
class_name VFXDeathShatter3D
## 10.29 死亡碎裂：棋子被打死时碎成种族色的发光碎片，朝击杀方向迸出去。
##
## 替掉原来那层 2D 的 DEATH_EXPLOSION（44 个白点 + 白环，画在 2D FX 层上，
## 和 3D 棋子不在一个空间，读不出来）。只在 BattleVfx.cue_play_death 里生成：
## 普通击杀 / 重量级 / 清场三档，己方阵亡不碎（见 BattleDeathFeedback）。
##
## 坐标：position 和 away 都是 _battle_3d_vfx_root 的本地空间，调用方负责换算。

const PresentationSettings := preload("res://effects/runtime/presentation/PresentationSettings.gd")
const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const IMPACT_FLASH := preload("res://effects/vfx3d/modules/VFXImpactFlash3D.gd")
const GROUND_RESIDUE := preload("res://effects/vfx3d/modules/VFXGroundResidue3D.gd")
const TARGET_IMPACT := preload("res://effects/vfx3d/VFXTargetImpact.gd")
const DEBRIS := preload("res://effects/vfx3d/modules/VFXDebrisBurst3D.gd")
const MONSTER_SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

# 一份缓存 shader、两个很小的粒子四边形；不需要图片、灯光、碰撞或大块碎石。
# 保留粒子自身缩放并乘 COLOR.a，消散曲线才能真正影响大小和透明度。
const MONSTER_DISSIPATE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 tint : source_color = vec4(0.3, 0.28, 0.25, 1.0);
uniform float ember = 0.0;
uniform float opacity = 1.0;
void vertex() {
    vec3 particle_scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * particle_scale.x, INV_VIEW_MATRIX[1] * particle_scale.y, INV_VIEW_MATRIX[2] * particle_scale.z, MODEL_MATRIX[3]);
}
void fragment() {
    vec2 p = (UV - vec2(0.5)) * 2.0;
    float radius = length(p * vec2(0.88, 1.08));
    float lobes = sin(p.x * 8.0 + p.y * 4.0) * 0.075 + sin(p.y * 11.0 - p.x * 3.0) * 0.035;
    float dust = 1.0 - smoothstep(0.18, 0.96, radius + lobes);
    float core = max(0.0, 1.0 - dot(p, p));
    float mask = mix(dust * 0.42, core * core * 0.90, ember);
    vec3 color = tint.rgb * COLOR.rgb;
    ALBEDO = color;
    EMISSION = color * ember * 0.35;
    ALPHA = mask * COLOR.a * tint.a * opacity;
}
"""

const PIECE_GLOW_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 tint : source_color = vec4(0.75, 0.87, 1.0, 1.0);
uniform float star_amount = 0.0;
uniform float opacity = 1.0;
void vertex() {
    vec3 particle_scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * particle_scale.x, INV_VIEW_MATRIX[1] * particle_scale.y, INV_VIEW_MATRIX[2] * particle_scale.z, MODEL_MATRIX[3]);
}
void fragment() {
    vec2 p = (UV - vec2(0.5)) * 2.0;
    float core = max(0.0, 1.0 - dot(p, p) * 2.2);
    core *= core;
    float vertical = (1.0 - smoothstep(0.015, 0.11, abs(p.x))) * (1.0 - smoothstep(0.12, 0.92, abs(p.y)));
    float horizontal = (1.0 - smoothstep(0.015, 0.10, abs(p.y))) * (1.0 - smoothstep(0.08, 0.76, abs(p.x)));
    float mask = core * 0.72 + (vertical + horizontal) * star_amount * 0.40;
    vec3 color = tint.rgb * COLOR.rgb;
    ALBEDO = color;
    EMISSION = color * 0.50;
    ALPHA = min(mask, 1.0) * COLOR.a * tint.a * opacity;
}
"""

const LANE_CLEAR_RING_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform float progress = 0.0;
uniform float opacity = 1.0;
uniform float quality_alpha = 1.0;
void fragment() {
    vec2 p = UV - vec2(0.5);
    float r = length(p);
    float radius = mix(0.25, 0.44, 1.0 - (1.0 - progress) * (1.0 - progress));
    float ring = 1.0 - smoothstep(0.002, 0.009, abs(r - radius));
    float edge = 1.0 - smoothstep(0.47, 0.50, r);
    float fade = smoothstep(0.0, 0.08, progress) * (1.0 - smoothstep(0.32, 1.0, progress));
    vec3 gold = vec3(1.0, 0.76, 0.34);
    ALBEDO = gold;
    EMISSION = gold * 0.75;
    ALPHA = ring * edge * fade * opacity * quality_alpha * 0.62;
}
"""

const MONSTER_DISSIPATE_TIERS := {
	"normal": {"dust": 4, "embers": 6, "life": 0.50, "size": 1.0},
	"heavy": {"dust": 6, "embers": 8, "life": 0.62, "size": 1.3},
	"finale": {"dust": 6, "embers": 8, "life": 0.66, "size": 1.35},
}
static var _monster_dust_quad: QuadMesh
static var _monster_ember_quad: QuadMesh
static var _monster_dust_scale: CurveTexture
static var _monster_ember_scale: CurveTexture
static var _monster_dust_fade: GradientTexture1D
static var _monster_ember_fade: GradientTexture1D
static var _piece_glow_quad: QuadMesh
static var _lane_clear_quad: QuadMesh
var _monster_materials: Array[ShaderMaterial] = []

# 档位参数。shards / sparks 是 HIGH 档基数，低档由 QUALITY.particle_count 统一砍。
# speed 按单位约 0.98 高标定：普通档碎片飞出约半个身位，清场档约一个身位。
const TIERS := {
	"normal": {"shards": 12, "sparks": 7, "speed": 2.1, "life": 0.52, "flash": 0.46, "ring": 0.0},
	"heavy": {"shards": 20, "sparks": 11, "speed": 2.6, "life": 0.62, "flash": 0.72, "ring": 0.95},
	"finale": {"shards": 26, "sparks": 14, "speed": 3.1, "life": 0.70, "flash": 0.95, "ring": 1.25},
}


## 棋子保留轻微种族残光；佣兵改为 2-4 个冷白星点，主体动作始终是倒下。
func play_piece_dissipate(at: Vector3, foot_y: float, away: Vector3, color: Color, tier: String,
		mercenary: bool = false, own: bool = false) -> void:
	begin()
	position = at
	var low := QUALITY.tier == QUALITY.Tier.LOW
	var high := QUALITY.tier == QUALITY.Tier.HIGH
	var count := (2 if low else (4 if high else 3))
	if not mercenary and tier != "normal" and not low:
		count += 1
	var tint := Color(0.76, 0.87, 1.0) if mercenary else color.lerp(Color(0.66, 0.66, 0.65), 0.22)
	if own:
		count = mini(count, 2 if mercenary else 3)
		tint = tint.darkened(0.45)
	var life := 0.36 if own else (0.46 if mercenary else 0.42)
	var glow := _make_piece_glow(tint, count, life, mercenary)
	glow.name = "MercenaryDeathStars" if mercenary else "PieceRaceAfterglow"
	glow.position = Vector3(0.0, maxf(0.035, foot_y - at.y + 0.13), 0.0)
	var process := glow.process_material as ParticleProcessMaterial
	var drift := Vector3(away.x, 0.0, away.z).normalized()
	process.direction = (drift * 0.18 + Vector3.UP * 0.70).normalized()
	if own:
		process.initial_velocity_max *= 0.65
	add_child(glow)
	if not await wait_for(life + 0.10):
		return
	finish()


## 一局只出现一次的清场收束：贴地细金环、少量上升点，不画遮满棋盘的光柱/白闪。
func play_lane_clear(at: Vector3) -> void:
	begin()
	position = at + Vector3.UP * 0.025
	_ensure_piece_resources()
	var low := QUALITY.tier == QUALITY.Tier.LOW
	var ring := MeshInstance3D.new()
	ring.name = "LaneClearThinGoldRing"
	ring.mesh = _lane_clear_quad
	ring.rotation_degrees.x = -90.0
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = MONSTER_SHADER_CACHE.get_shader(LANE_CLEAR_RING_SHADER)
	material.set_shader_parameter("progress", 0.0)
	material.set_shader_parameter("opacity", vfx_alpha)
	material.set_shader_parameter("quality_alpha", 0.65 if low else 1.0)
	ring.material_override = material
	_monster_materials.append(material)
	add_child(ring)
	var points := _make_piece_glow(Color(1.0, 0.79, 0.41), 2 if low else (6 if QUALITY.tier == QUALITY.Tier.HIGH else 4), 0.72, false)
	points.name = "LaneClearRisingPoints"
	points.position.y = 0.045
	var process := points.process_material as ParticleProcessMaterial
	process.emission_sphere_radius = 0.48
	process.direction = Vector3.UP
	process.spread = 12.0
	process.initial_velocity_min = 0.20
	process.initial_velocity_max = 0.38
	process.gravity = Vector3(0.0, 0.10, 0.0)
	add_child(points)
	var tween := track_tween(create_tween())
	tween.tween_property(material, "shader_parameter/progress", 1.0, 0.85)
	if not await wait_for(0.90):
		return
	finish()


func _make_piece_glow(color: Color, count: int, life: float, star: bool) -> GPUParticles3D:
	_ensure_piece_resources()
	var particles := GPUParticles3D.new()
	particles.amount = maxi(1, count)
	particles.lifetime = life
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.randomness = 0.30
	particles.emitting = true
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb = AABB(Vector3(-1.2, -0.3, -1.2), Vector3(2.4, 1.8, 2.4))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.16 if star else 0.12
	process.direction = Vector3.UP
	process.spread = 48.0
	process.initial_velocity_min = 0.15
	process.initial_velocity_max = 0.38
	process.gravity = Vector3(0.0, 0.08, 0.0)
	process.damping_min = 0.65
	process.damping_max = 1.15
	process.scale_min = 0.75 if star else 0.55
	process.scale_max = 1.25 if star else 0.85
	process.scale_curve = _monster_ember_scale
	process.color_ramp = _monster_ember_fade
	particles.process_material = process
	particles.draw_pass_1 = _piece_glow_quad
	var material := ShaderMaterial.new()
	material.shader = MONSTER_SHADER_CACHE.get_shader(PIECE_GLOW_SHADER)
	material.set_shader_parameter("tint", color)
	material.set_shader_parameter("star_amount", 1.0 if star else 0.0)
	material.set_shader_parameter("opacity", vfx_alpha)
	particles.material_override = material
	_monster_materials.append(material)
	return particles


static func _ensure_piece_resources() -> void:
	_ensure_monster_resources()
	if _piece_glow_quad != null:
		return
	_piece_glow_quad = QuadMesh.new()
	_piece_glow_quad.size = Vector2(0.105, 0.13)
	_lane_clear_quad = QuadMesh.new()
	_lane_clear_quad.size = Vector2(2.2, 2.2)


## 与 play_shatter 同接口；仅怪物倒地后调用，地面尘雾不跟随身体沉进地板。
func play_monster_dissipate(at: Vector3, foot_y: float, away: Vector3, color: Color, tier: String) -> void:
	begin()
	position = at
	var spec: Dictionary = MONSTER_DISSIPATE_TIERS.get(tier, MONSTER_DISSIPATE_TIERS["normal"])
	var life := float(spec["life"])
	var size := float(spec["size"])
	var dust_count := QUALITY.particle_count(int(spec["dust"]))
	if QUALITY.tier == QUALITY.Tier.LOW:
		dust_count = 2
	var ember_count := QUALITY.particle_count(int(spec["embers"]))
	var drift := Vector3(away.x, 0.0, away.z)
	if drift.length() > 0.001:
		drift = drift.normalized()
	var dust_color := Color(0.28, 0.26, 0.23).lerp(color.darkened(0.58), 0.22)
	var ember_color := color.lerp(Color(0.65, 0.58, 0.46), 0.48)
	var dust := _make_monster_particles(dust_color, dust_count, life, drift, size, false)
	dust.position = Vector3(0.0, foot_y - at.y + 0.065, 0.0)
	add_child(dust)
	var embers := _make_monster_particles(ember_color, ember_count, life * 0.76, drift, size, true)
	embers.position = Vector3(0.0, maxf(0.04, foot_y - at.y + 0.16), 0.0)
	add_child(embers)
	if not await wait_for(life + 0.12):
		return
	finish()


func _make_monster_particles(color: Color, amount: int, lifetime: float, away: Vector3, size: float, ember: bool) -> GPUParticles3D:
	_ensure_monster_resources()
	var particles := GPUParticles3D.new()
	particles.name = "MonsterDeathEmbers" if ember else "MonsterDeathDust"
	particles.amount = maxi(1, amount)
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.randomness = 0.35
	particles.emitting = true
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb = AABB(Vector3(-1.2, -0.4, -1.2), Vector3(2.4, 1.8, 2.4))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = (0.10 if ember else 0.15) * size
	process.direction = (away * 0.55 + Vector3.UP * (0.75 if ember else 0.28)).normalized()
	process.spread = 58.0 if ember else 82.0
	process.initial_velocity_min = (0.40 if ember else 0.13) * size
	process.initial_velocity_max = (1.05 if ember else 0.42) * size
	process.gravity = Vector3(0.0, -1.1 if ember else 0.08, 0.0)
	process.damping_min = 0.55
	process.damping_max = 1.10
	process.scale_min = size * (0.65 if ember else 0.82)
	process.scale_max = size * (1.15 if ember else 1.30)
	process.scale_curve = _monster_ember_scale if ember else _monster_dust_scale
	process.color_ramp = _monster_ember_fade if ember else _monster_dust_fade
	particles.process_material = process
	particles.draw_pass_1 = _monster_ember_quad if ember else _monster_dust_quad
	var material := ShaderMaterial.new()
	material.shader = MONSTER_SHADER_CACHE.get_shader(MONSTER_DISSIPATE_SHADER)
	material.set_shader_parameter("tint", color)
	material.set_shader_parameter("ember", 1.0 if ember else 0.0)
	material.set_shader_parameter("opacity", vfx_alpha)
	particles.material_override = material
	_monster_materials.append(material)
	return particles


static func _ensure_monster_resources() -> void:
	if _monster_dust_quad != null:
		return
	_monster_dust_quad = QuadMesh.new()
	_monster_dust_quad.size = Vector2(0.40, 0.28)
	_monster_ember_quad = QuadMesh.new()
	_monster_ember_quad.size = Vector2(0.040, 0.065)
	_monster_dust_scale = _monster_curve([Vector2(0.0, 0.50), Vector2(0.18, 0.92), Vector2(0.70, 1.16), Vector2(1.0, 1.28)])
	_monster_ember_scale = _monster_curve([Vector2(0.0, 0.80), Vector2(0.12, 1.0), Vector2(0.55, 0.70), Vector2(1.0, 0.0)])
	_monster_dust_fade = _monster_fade([0.0, 0.10, 0.48, 1.0], [0.0, 0.85, 0.58, 0.0])
	_monster_ember_fade = _monster_fade([0.0, 0.04, 0.35, 1.0], [0.0, 1.0, 0.82, 0.0])


static func _monster_curve(points: Array) -> CurveTexture:
	var curve := Curve.new()
	curve.max_value = 1.4
	for point: Vector2 in points:
		curve.add_point(point)
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture


static func _monster_fade(offsets: Array, alpha: Array) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array(offsets)
	var colors := PackedColorArray()
	for value: float in alpha:
		colors.append(Color(1.0, 1.0, 1.0, value))
	gradient.colors = colors
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture


func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	for material in _monster_materials:
		material.set_shader_parameter("opacity", vfx_alpha)


## at：身体中心（HitAnchor）；foot_y：脚底高度（冲击环落在这里）。
## away：远离击杀者的水平方向，零向量 = 原地向上散。
func play_shatter(at: Vector3, foot_y: float, away: Vector3, color: Color, tier: String) -> void:
	begin()
	position = at
	var spec: Dictionary = TIERS.get(tier, TIERS["normal"])
	var life := float(spec["life"])
	var speed := float(spec["speed"])
	var dir := Vector3(away.x * 0.85, 0.75, away.z * 0.85)
	if dir.length() < 0.001:
		dir = Vector3.UP
	dir = dir.normalized()

	if PresentationSettings.flash_allowed():
		var flash := IMPACT_FLASH.new()
		flash.name = "DeathShatterFlash"
		add_child(flash)
		flash.play_flash(Vector3.ZERO, color.lightened(0.45), float(spec["flash"]), 0.16)

	# 两组碎片：大块的偏重、飞得近；小块的偏轻、飞得远。两组同一帧发，不错开 ——
	# 碎裂要读成「一下炸开」，错开发射会变成「一阵一阵往外冒」。
	var total := QUALITY.particle_count(int(spec["shards"]))
	var heavy_count := maxi(1, int(round(total * 0.4)))
	add_child(_make_shards(color, heavy_count, speed * 0.72, life, dir, 1))
	add_child(_make_shards(color.lightened(0.18), maxi(1, total - heavy_count), speed, life * 0.86, dir, 2))

	var sparks := TARGET_IMPACT.burst(color.lightened(0.35), QUALITY.particle_count(int(spec["sparks"])), speed * 1.25, minf(life, 0.36))
	sparks.name = "DeathShatterSparks"
	(sparks.process_material as ParticleProcessMaterial).direction = dir
	(sparks.process_material as ParticleProcessMaterial).spread = 70.0
	add_child(sparks)

	var ring := float(spec["ring"])
	if ring > 0.0:
		# 冲击环落在脚下而不是胸口。
		var residue := GROUND_RESIDUE.new()
		residue.name = "DeathShatterGroundRing"
		add_child(residue)
		residue.play_residue(Vector3(0.0, foot_y - at.y + 0.02, 0.0), color.darkened(0.35), ring, life + 0.3)

	if not await wait_for(life + 0.45):
		return
	finish()


func _make_shards(color: Color, amount: int, speed: float, lifetime: float, dir: Vector3, variant: int) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "DeathShards%d" % variant
	particles.amount = maxi(amount, 1)
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.randomness = 0.5
	particles.emitting = true
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.16
	process.direction = dir
	process.spread = 58.0
	process.initial_velocity_min = speed * 0.55
	process.initial_velocity_max = speed
	process.gravity = Vector3(0.0, -6.0, 0.0)
	process.damping_min = 0.6
	process.damping_max = 1.4
	process.scale_min = 0.75
	process.scale_max = 1.25 if variant == 1 else 0.85
	process.angular_velocity_min = -720.0
	process.angular_velocity_max = 720.0
	# 后三成寿命缩到零：碎片是「化掉」而不是落地堆着。
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(0.68, 0.9))
	curve.add_point(Vector2(1.0, 0.0))
	var curve_tex := CurveTexture.new()
	curve_tex.curve = curve
	process.scale_curve = curve_tex
	particles.process_material = process
	# 复用碎屑模块的碎块网格，只换材质：碎屑那边是压暗的泥石色，这里要发光的种族色。
	var mesh := DEBRIS.make_shard_mesh(color, variant) as ArrayMesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 1.6
	mesh.surface_set_material(0, material)
	particles.draw_pass_1 = mesh
	return particles
