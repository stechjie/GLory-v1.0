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

# 档位参数。shards / sparks 是 HIGH 档基数，低档由 QUALITY.particle_count 统一砍。
# speed 按单位约 0.98 高标定：普通档碎片飞出约半个身位，清场档约一个身位。
const TIERS := {
	"normal": {"shards": 12, "sparks": 7, "speed": 2.1, "life": 0.52, "flash": 0.46, "ring": 0.0},
	"heavy": {"shards": 20, "sparks": 11, "speed": 2.6, "life": 0.62, "flash": 0.72, "ring": 0.95},
	"finale": {"shards": 26, "sparks": 14, "speed": 3.1, "life": 0.70, "flash": 0.95, "ring": 1.25},
}


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
