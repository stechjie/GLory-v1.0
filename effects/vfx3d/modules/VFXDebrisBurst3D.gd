extends VFXBlockRoot
class_name VFXDebrisBurst3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const IMPACT_FLASH := preload("res://effects/vfx3d/modules/VFXImpactFlash3D.gd")
const GROUND_RESIDUE := preload("res://effects/vfx3d/modules/VFXGroundResidue3D.gd")
const TARGET_IMPACT := preload("res://effects/vfx3d/VFXTargetImpact.gd")

const DUST_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 dust_color : source_color = vec4(0.22, 0.16, 0.10, 0.62);
void vertex() {
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
    vec2 p = UV - vec2(0.5);
    p.x *= 0.72;
    float r = length(p) * 2.0;
    float angle = atan(p.y, p.x);
    float torn = sin(angle * 7.0 + TIME * 1.8) * 0.10;
    torn += sin(angle * 11.0 - TIME * 1.2) * 0.045;
    float cloud = smoothstep(0.94 + torn, 0.16, r);
    float hollow = smoothstep(0.03, 0.23, r);
    vec2 card = abs(UV - vec2(0.5)) * 2.0;
    float card_fade = smoothstep(1.0, 0.74, max(card.x, card.y));
    float alpha = cloud * hollow * card_fade * dust_color.a;
    ALBEDO = dust_color.rgb * mix(0.72, 1.0, cloud);
    ALPHA = alpha;
}
"""

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	var params := profile.parameters
	await _play_layered(
		context.get("target", Vector3.ZERO), profile.main_color,
		int(params.get("shard_count", profile.particle_count)),
		float(params.get("speed", 2.8)), profile.duration, params)

func play_debris(at: Vector3, color: Color, amount := 10, speed := 2.4, lifetime := 0.72) -> void:
	await _play_layered(at, color, amount, speed, lifetime, {})

func _play_layered(at: Vector3, color: Color, amount: int, speed: float, lifetime: float, params: Dictionary) -> void:
	begin()
	position = at
	var flash_size := float(params.get("flash_size", 0.72))
	var dust_count := int(params.get("dust_count", 4))
	var spark_count := int(params.get("spark_count", 7))
	var residue_size := float(params.get("residue_size", 0.78))

	var flash := IMPACT_FLASH.new()
	flash.name = "DebrisIgnitionFlash"
	add_child(flash)
	flash.play_flash(Vector3.ZERO, color.lightened(0.36), flash_size, minf(0.22, lifetime * 0.34))

	var total_shards := QUALITY.particle_count(amount)
	var base_count := total_shards / 3
	var remainder := total_shards % 3
	for variant in range(3):
		var count := base_count + (1 if variant < remainder else 0)
		var emitter := _make_shard_emitter(color, count, speed, lifetime, variant)
		emitter.name = "DebrisShardEmitter%d" % variant
		add_child(emitter)
		if variant < 2:
			await get_tree().create_timer(0.025).timeout

	var sparks := TARGET_IMPACT.burst(color.lightened(0.24), QUALITY.particle_count(spark_count), speed * 1.35, minf(lifetime, 0.48))
	sparks.name = "DebrisLargeSparks"
	sparks.position = Vector3(0.0, 0.12, 0.0)
	add_child(sparks)

	var dust := _make_dust(Color(0.30, 0.23, 0.16, 1.0), dust_count, lifetime)
	dust.name = "DebrisGroundDust"
	dust.position = Vector3(0.0, 0.045, 0.0)
	add_child(dust)

	var residue := GROUND_RESIDUE.new()
	residue.name = "DebrisGroundResidue"
	add_child(residue)
	var residue_duration := maxf(0.82, lifetime + 0.18)
	residue.play_residue(Vector3.ZERO, color.darkened(0.48), residue_size, residue_duration)

	await get_tree().create_timer(maxf(lifetime + 0.28, residue_duration + 0.06)).timeout
	finish()

func _make_shard_emitter(color: Color, amount: int, speed: float, lifetime: float, variant: int) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = maxi(amount, 1)
	particles.lifetime = lifetime * (0.82 + float(variant) * 0.10)
	particles.one_shot = true
	particles.explosiveness = 0.97
	particles.randomness = 0.56
	particles.emitting = true
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.075
	process.direction = Vector3(float(variant - 1) * 0.28, 0.90, 0.24 - float(variant) * 0.19).normalized()
	process.spread = 65.0
	process.initial_velocity_min = speed * (0.52 + float(variant) * 0.07)
	process.initial_velocity_max = speed * (0.94 + float(variant) * 0.13)
	process.gravity = Vector3(0.0, -6.2, 0.0)
	process.damping_min = 0.14
	process.damping_max = 0.46
	process.scale_min = 0.68 + float(variant) * 0.08
	process.scale_max = 1.12 + float(variant) * 0.16
	process.angular_velocity_min = -11.0 - float(variant) * 2.0
	process.angular_velocity_max = 11.0 + float(variant) * 2.0
	process.scale_curve = _make_scale_curve(variant)
	process.color_ramp = _make_fade_ramp()
	particles.process_material = process
	var variant_color := color.darkened(0.66 - float(variant) * 0.08)
	particles.draw_pass_1 = make_shard_mesh(variant_color, variant)
	return particles

func _make_dust(color: Color, amount: int, lifetime: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = QUALITY.particle_count(maxi(amount, 3))
	particles.lifetime = maxf(0.58, lifetime * 0.82)
	particles.one_shot = true
	particles.explosiveness = 0.88
	particles.randomness = 0.72
	particles.emitting = true
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0.0, 0.18, 0.0)
	process.spread = 180.0
	process.initial_velocity_min = 0.34
	process.initial_velocity_max = 0.92
	process.gravity = Vector3(0.0, -0.16, 0.0)
	process.scale_min = 0.72
	process.scale_max = 1.28
	process.angular_velocity_min = -1.8
	process.angular_velocity_max = 1.8
	process.scale_curve = _make_dust_scale_curve()
	process.color_ramp = _make_fade_ramp(0.58)
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.64, 0.36)
	var material := ShaderMaterial.new()
	material.shader = SHADER_CACHE.get_shader(DUST_SHADER)
	material.set_shader_parameter("dust_color", Color(color.r, color.g, color.b, 0.68))
	quad.material = material
	particles.draw_pass_1 = quad
	return particles

static func make_shard_mesh(color: Color, variant := 0) -> ArrayMesh:
	var points: Array[Vector3] = [
		Vector3(-0.070, -0.050, -0.045), Vector3(0.058, -0.043, -0.052),
		Vector3(0.076, -0.031, 0.036), Vector3(-0.054, -0.047, 0.057),
		Vector3(-0.043, 0.061, -0.035), Vector3(0.034, 0.078, -0.027),
		Vector3(0.056, 0.052, 0.043), Vector3(-0.034, 0.066, 0.049),
	]
	match variant % 3:
		1:
			for index in range(points.size()):
				points[index] = Vector3(points[index].x * 0.72 + points[index].y * 0.18, points[index].y * 1.18, points[index].z * 0.88)
		2:
			for index in range(points.size()):
				points[index] = Vector3(points[index].x * 1.24, points[index].y * 0.68 + points[index].x * 0.12, points[index].z * 1.06)
		_:
			pass
	var faces := PackedInt32Array([
		0, 2, 1, 0, 3, 2,
		4, 5, 6, 4, 6, 7,
		0, 1, 5, 0, 5, 4,
		1, 2, 6, 1, 6, 5,
		2, 3, 7, 2, 7, 6,
		3, 0, 4, 3, 4, 7,
	])
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mesh_scale := 1.04 + float(variant % 3) * 0.08
	for index in faces:
		surface.add_vertex(points[index] * mesh_scale)
	surface.generate_normals()
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.albedo_color = color
	material.roughness = 0.78
	material.metallic = 0.04
	material.emission_enabled = true
	material.emission = color.lightened(0.08)
	material.emission_energy_multiplier = 0.28
	surface.set_material(material)
	return surface.commit() as ArrayMesh

func _make_scale_curve(variant: int) -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.25))
	curve.add_point(Vector2(0.10 + float(variant) * 0.02, 1.08 + float(variant) * 0.06))
	curve.add_point(Vector2(0.68, 0.92))
	curve.add_point(Vector2(1.0, 0.0))
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture

func _make_dust_scale_curve() -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.32))
	curve.add_point(Vector2(0.18, 1.0))
	curve.add_point(Vector2(0.72, 1.28))
	curve.add_point(Vector2(1.0, 0.0))
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture

func _make_fade_ramp(peak_alpha := 1.0) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.12, 0.68, 1.0])
	gradient.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0), Color(1.0, 1.0, 1.0, peak_alpha),
		Color(0.74, 0.74, 0.74, peak_alpha * 0.78), Color(0.30, 0.30, 0.30, 0.0),
	])
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture
