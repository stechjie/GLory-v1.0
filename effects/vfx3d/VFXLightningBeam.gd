extends RefCounted
class_name VFXLightningBeam

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
uniform vec3 main_color : source_color = vec3(1.0);
uniform vec3 effect_color : source_color = vec3(0.3, 0.75, 1.0);
uniform int octave_count = 8;
uniform float amp_start = 0.5;
uniform float amp_coeff = 0.5;
uniform float freq_coeff = 2.0;
uniform float speed = 3.0;
uniform float emission_power = 2.0;
uniform sampler2D power_texture : source_color;

float hash12(vec2 p) {
    return fract(cos(mod(dot(p, vec2(13.9898, 8.141)), 3.14)) * 43758.5453);
}

vec2 hash22(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return 2.0 * fract(sin(p) * 43758.5453);
}

float noise(vec2 p) {
    vec2 cell = floor(p);
    vec2 local = fract(p);
    vec2 smooth_local = smoothstep(0.0, 1.0, local);
    float a = dot(hash22(cell), local);
    float b = dot(hash22(cell + vec2(1.0, 0.0)), local - vec2(1.0, 0.0));
    float c = dot(hash22(cell + vec2(0.0, 1.0)), local - vec2(0.0, 1.0));
    float d = dot(hash22(cell + vec2(1.0, 1.0)), local - vec2(1.0, 1.0));
    return mix(mix(a, b, smooth_local.x), mix(c, d, smooth_local.x), smooth_local.y) + 0.5;
}

float fbm(vec2 p) {
    float value = 0.0;
    float amplitude = amp_start;
    for (int i = 0; i < octave_count; i++) {
        value += amplitude * noise(p);
        p *= freq_coeff;
        amplitude *= amp_coeff;
    }
    return value;
}

void fragment() {
    float power_value = texture(power_texture, UV).r;
    vec2 modified_uv = 2.0 * UV - 1.0;
    modified_uv.y *= 4.0;
    modified_uv.x -= amp_start;
    modified_uv += fbm(modified_uv + TIME * speed);
    modified_uv.x += 0.5 - amp_coeff;
    float distance_to_bolt = abs(modified_uv.x);
    float flicker = 0.72 + hash12(vec2(floor(TIME * speed * 2.0))) * 0.42;
    float core = smoothstep(0.17, 0.018, distance_to_bolt);
    float middle = smoothstep(0.31, 0.045, distance_to_bolt);
    float outer_glow = smoothstep(0.58, 0.08, distance_to_bolt);
    vec3 final_color = effect_color * (outer_glow * 0.72 + middle * 1.45);
    final_color += main_color * core * 3.4;
    final_color *= flicker * mix(0.76, 1.0, power_value);
    ALBEDO = final_color;
    EMISSION = final_color * emission_power;
    ALPHA = clamp(outer_glow * 0.42 + middle * 0.52 + core, 0.0, 1.0);
}
"""

static var _power_texture: ImageTexture

static func make_ribbon(from_pos: Vector3, to_pos: Vector3, width: float, color: Color) -> MeshInstance3D:
	var beam := MeshInstance3D.new()
	var direction := to_pos - from_pos
	var length := maxf(direction.length(), 0.01)
	var forward := direction.normalized()
	# Battle uses a fixed elevated front camera. Build the ribbon in the
	# camera-facing XY plane so the lightning does not disappear edge-on.
	var side := forward.cross(Vector3.FORWARD)
	if side.length_squared() < 0.001:
		side = forward.cross(Vector3.UP)
	side = side.normalized() * width * 0.5
	var vertices := PackedVector3Array([
		from_pos - side, from_pos + side, to_pos + side, to_pos - side
	])
	var uvs := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)
	])
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, make_material(color, length))
	beam.mesh = mesh
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return beam

static func make_material(color: Color, length := 1.0) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER_CODE
	material.shader = shader
	material.set_shader_parameter("main_color", Color(0.78, 0.98, 1.0, 1.0))
	material.set_shader_parameter("effect_color", color)
	material.set_shader_parameter("speed", 3.8 + length * 0.8)
	material.set_shader_parameter("emission_power", 3.2)
	material.set_shader_parameter("power_texture", _get_power_texture())
	return material

static func _get_power_texture() -> ImageTexture:
	if _power_texture != null:
		return _power_texture
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var edge := absf(float(x) / 63.0 * 2.0 - 1.0)
			var value := clampf(1.0 - edge * edge, 0.0, 1.0)
			image.set_pixel(x, y, Color(value, value, value, 1.0))
	_power_texture = ImageTexture.create_from_image(image)
	return _power_texture
