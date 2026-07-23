extends VFXBlockRoot
class_name VFXSmokeBurst
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const SMOKE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 smoke_color : source_color = vec4(0.20, 0.23, 0.26, 1.0);
uniform float phase = 0.0;
void vertex() {
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
    vec2 p = UV - vec2(0.5);
    float r = length(p) * 2.0;
    float wobble = sin((p.x * 12.0 + TIME * 1.6) + cos(p.y * 9.0)) * 0.08;
    float body = smoothstep(0.92, 0.25, r + wobble);
    float edge = smoothstep(0.82, 0.42, r + wobble);
    vec2 card = abs(p) * 2.0;
    float card_fade = smoothstep(1.0, 0.72, max(card.x, card.y));
    float breakup = 0.82 + 0.18 * sin(atan(p.y, p.x) * 7.0 + TIME * 1.4);
    float alpha = clamp(body * (1.0 - phase) + edge * 0.16, 0.0, 1.0) * card_fade * breakup;
    ALBEDO = smoke_color.rgb * (0.72 + edge * 0.28);
    ALPHA = alpha;
}
"""

func play_smoke(target: Vector3, color := Color(0.24, 0.26, 0.30)) -> void:
	begin()
	var particles := GPUParticles3D.new()
	particles.name = "SmokeParticles"
	particles.amount = 22
	particles.lifetime = 0.82
	particles.one_shot = true
	particles.explosiveness = 0.82
	particles.position = target + Vector3(0.0, 0.08, 0.0)
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0.0, 1.0, 0.0)
	process.spread = 42.0
	process.initial_velocity_min = 0.25
	process.initial_velocity_max = 0.85
	process.gravity = Vector3(0.0, -0.18, 0.0)
	process.scale_min = 0.16
	process.scale_max = 0.34
	process.angular_velocity_min = -1.6
	process.angular_velocity_max = 1.6
	process.color = Color(color.r, color.g, color.b, 0.76)
	particles.process_material = process
	var draw := QuadMesh.new()
	draw.size = Vector2(0.48, 0.48)
	var material := ShaderMaterial.new()
	material.shader = SHADER_CACHE.get_shader(SMOKE_SHADER)
	material.set_shader_parameter("smoke_color", color)
	material.set_shader_parameter("phase", 0.0)
	draw.material = material
	particles.draw_pass_1 = draw
	add_child(particles)
	var debris := VFXTargetImpact.burst(Color(0.42, 0.30, 0.18), 18, 1.7, 0.46)
	debris.position = target + Vector3(0.0, 0.12, 0.0)
	add_child(debris)
	var tween := create_tween()
	tween.tween_property(material, "shader_parameter/phase", 1.0, 0.78)
	await get_tree().create_timer(1.02).timeout
	finish()
