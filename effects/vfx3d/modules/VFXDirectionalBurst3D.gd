extends VFXBlockRoot
class_name VFXDirectionalBurst3D

const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

const STREAK_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 main_color : source_color = vec4(1.0, 0.5, 0.1, 1.0);
void vertex() {
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
    vec2 p = UV - vec2(0.5);
    float taper = smoothstep(0.50, 0.02, abs(p.y)) * smoothstep(0.52, -0.42, p.x);
    float tip = smoothstep(0.50, 0.18, abs(p.x - 0.22));
    float mask = taper * tip;
    vec3 color = mix(main_color.rgb, vec3(1.0), smoothstep(0.25, 0.0, length(p)));
    ALBEDO = color;
    EMISSION = color * 3.8;
    ALPHA = mask;
}
"""

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_burst(context.get("target", Vector3.ZERO), context.get("direction", Vector3.RIGHT), profile)

func play_burst(at: Vector3, direction: Vector3, profile: VFXProfile3D = null) -> void:
	begin()
	position = at + Vector3(0.0, 0.16, 0.0)
	var params: Dictionary = profile.parameters if profile != null else {}
	var particles := GPUParticles3D.new()
	particles.amount = QUALITY.particle_count(profile.particle_count if profile != null else 18)
	particles.lifetime = profile.duration if profile != null else 0.48
	particles.one_shot = true
	particles.explosiveness = 0.98
	particles.randomness = 0.38
	particles.local_coords = false
	var process := ParticleProcessMaterial.new()
	process.direction = direction.normalized()
	process.spread = float(params.get("spread", 28.0))
	process.initial_velocity_min = float(params.get("speed_min", 2.0))
	process.initial_velocity_max = float(params.get("speed_max", 4.2))
	process.gravity = Vector3(0.0, float(params.get("gravity", -2.8)), 0.0)
	process.scale_min = 0.76
	process.scale_max = 1.35
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.24, 0.075)
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = STREAK_SHADER
	material.shader = shader
	material.set_shader_parameter("main_color", profile.main_color if profile != null else Color(1.0, 0.5, 0.1))
	quad.material = material
	particles.draw_pass_1 = quad
	add_child(particles)
	await get_tree().create_timer(particles.lifetime + 0.18).timeout
	finish()
