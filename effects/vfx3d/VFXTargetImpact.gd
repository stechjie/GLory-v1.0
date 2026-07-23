extends Node3D
class_name VFXTargetImpact
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const IMPACT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 core_color : source_color = vec4(0.3, 0.75, 1.0, 1.0);
uniform float progress = 0.0;
void fragment() {
    vec2 p = UV - vec2(0.5);
    float r = length(p) * 2.0;
    float ring = smoothstep(0.16, 0.02, abs(r - progress));
    float core = smoothstep(0.30, 0.0, r) * (1.0 - progress * 0.55);
    float rays = pow(max(0.0, cos(atan(p.y, p.x) * 8.0)), 12.0) * smoothstep(0.95, 0.15, r);
    ALBEDO = core_color.rgb;
    EMISSION = core_color.rgb * (2.5 + rays * 2.0);
    ALPHA = clamp(max(ring, core * 0.9) + rays * 0.35, 0.0, 1.0) * (1.0 - progress);
}
"""

const SPARK_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 spark_color : source_color = vec4(1.0, 0.65, 0.18, 1.0);
void vertex() {
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
    vec2 p = UV - vec2(0.5);
    float taper = smoothstep(0.50, 0.02, abs(p.y)) * smoothstep(0.52, 0.04, abs(p.x));
    float hot_core = smoothstep(0.15, 0.0, abs(p.y)) * smoothstep(0.48, 0.05, abs(p.x));
    float alpha = taper * (0.68 + hot_core * 0.32);
    vec3 color = mix(spark_color.rgb, vec3(1.0, 0.94, 0.72), hot_core);
    ALBEDO = color;
    EMISSION = color * (3.2 + hot_core * 2.4);
    ALPHA = alpha;
}
"""

static func make(color: Color, size := 0.9) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	node.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = SHADER_CACHE.get_shader(IMPACT_SHADER)
	mat.set_shader_parameter("core_color", color)
	mat.set_shader_parameter("progress", 0.0)
	node.material_override = mat
	node.rotation_degrees.x = -90.0
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

static func burst(color: Color, amount := 18, speed := 2.2, lifetime := 0.28) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.explosiveness = 0.95
	particles.emitting = true
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0.0, 1.0, 0.0)
	process.spread = 52.0
	process.initial_velocity_min = speed * 0.45
	process.initial_velocity_max = speed
	process.gravity = Vector3(0.0, -4.5, 0.0)
	process.scale_min = 0.10
	process.scale_max = 0.20
	particles.process_material = process
	var draw := QuadMesh.new()
	draw.size = Vector2(0.16, 0.055)
	var glow := ShaderMaterial.new()
	glow.shader = SHADER_CACHE.get_shader(SPARK_SHADER)
	glow.set_shader_parameter("spark_color", color)
	draw.material = glow
	particles.draw_pass_1 = draw
	return particles
