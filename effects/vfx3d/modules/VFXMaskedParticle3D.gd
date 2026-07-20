extends VFXBlockRoot
class_name VFXMaskedParticle3D

const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

const SPARK_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 main_color : source_color = vec4(0.3, 0.85, 1.0, 1.0);
void vertex() {
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
    vec2 p = abs(UV - vec2(0.5)) * 2.0;
    float h = smoothstep(0.24, 0.018, p.y) * smoothstep(1.0, 0.06, p.x);
    float v = smoothstep(0.24, 0.018, p.x) * smoothstep(1.0, 0.06, p.y);
    float diamond = smoothstep(0.94, 0.12, p.x + p.y);
    float core = smoothstep(0.32, 0.01, length(p));
    float mask = clamp(max(max(h, v) * 0.78, diamond * 0.55) + core, 0.0, 1.0);
    vec3 color = mix(main_color.rgb, vec3(0.90, 0.99, 1.0), core);
    ALBEDO = color;
    EMISSION = color * (2.6 + core * 3.4);
    ALPHA = mask;
}
"""

func play_burst(at: Vector3, color: Color, amount := 16, speed := 2.6, lifetime := 0.42) -> void:
	begin()
	position = at
	var particles := GPUParticles3D.new()
	particles.name = "MaskedParticles"
	particles.amount = QUALITY.particle_count(amount)
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.explosiveness = 0.96
	particles.randomness = 0.38
	particles.local_coords = false
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3.UP
	process.spread = 68.0
	process.initial_velocity_min = speed * 0.48
	process.initial_velocity_max = speed
	process.gravity = Vector3(0.0, -4.2, 0.0)
	process.scale_min = 0.78
	process.scale_max = 1.35
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.13, 0.09)
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SPARK_SHADER
	material.shader = shader
	material.set_shader_parameter("main_color", color)
	quad.material = material
	particles.draw_pass_1 = quad
	add_child(particles)
	await get_tree().create_timer(lifetime + 0.18).timeout
	finish()
