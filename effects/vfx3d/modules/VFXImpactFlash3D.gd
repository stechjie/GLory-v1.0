extends VFXBlockRoot
class_name VFXImpactFlash3D
const SHADER_CACHE := preload("res://effects/vfx3d/core/VFXShaderCache.gd")

const FLASH_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec4 main_color : source_color = vec4(1.0, 0.55, 0.12, 1.0);
uniform float progress = 0.0;
uniform float opacity = 1.0;
void fragment() {
    vec2 p = UV - vec2(0.5);
    float r = length(p) * 2.0;
    float ring = smoothstep(0.14, 0.018, abs(r - progress));
    float core = smoothstep(0.42, 0.0, r) * (1.0 - progress);
    float rays = pow(max(0.0, cos(atan(p.y, p.x) * 8.0)), 14.0) * smoothstep(1.0, 0.08, r);
    float alpha = clamp(ring + core + rays * 0.54, 0.0, 1.0) * (1.0 - progress * 0.82);
    vec3 color = mix(main_color.rgb, vec3(1.0), core * 0.72 + rays * 0.35);
    ALBEDO = color;
    EMISSION = color * (3.2 + core * 2.5);
    ALPHA = alpha * opacity;
}
"""

var _material: ShaderMaterial

func play_profile(profile: VFXProfile3D, context: Dictionary) -> void:
	play_flash(context.get("target", Vector3.ZERO), profile.main_color, profile.size, profile.duration)

func play_flash(at: Vector3, color: Color, size := 1.1, duration := 0.42) -> void:
	begin()
	position = at + Vector3(0.0, 0.035, 0.0)
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var node := MeshInstance3D.new()
	node.name = "ImpactFlash"
	node.mesh = quad
	node.rotation_degrees.x = -90.0
	_material = ShaderMaterial.new()
	_material.shader = SHADER_CACHE.get_shader(FLASH_SHADER)
	_material.set_shader_parameter("main_color", color)
	_material.set_shader_parameter("progress", 0.0)
	_material.set_shader_parameter("opacity", vfx_alpha)
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	var tween := track_tween(create_tween())
	tween.set_parallel(true)
	tween.tween_property(node, "scale", Vector3.ONE * 1.55, duration)
	tween.tween_property(_material, "shader_parameter/progress", 1.0, duration)
	await get_tree().create_timer(duration + 0.05).timeout
	finish()

func set_vfx_alpha(value: float) -> void:
	super.set_vfx_alpha(value)
	if _material != null:
		_material.set_shader_parameter("opacity", vfx_alpha)
