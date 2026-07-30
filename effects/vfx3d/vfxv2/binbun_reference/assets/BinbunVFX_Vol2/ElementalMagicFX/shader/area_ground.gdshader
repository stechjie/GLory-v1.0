shader_type spatial;
render_mode unshaded;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0,0.8,0.2);
uniform vec3 secondary_color : source_color = vec3(1.0,0.4,0.1);
uniform vec3 tertiary_color : source_color = vec3(0.6,0.1,0.05);
uniform float emission = 2.0;
uniform float color_curve = 1.0;

group_uniforms Shape;
uniform sampler2D noise_texture;
uniform vec2 noise_scale = vec2(1.0);
uniform vec2 noise_scroll = vec2(0.1, 0.3);
uniform float grow_amount : hint_range(0.0, 1.0, 0.05) = 1.0;

group_uniforms Transparency;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.2;

uniform sampler2D gradient_texture;

float overlay(float base, float blend){
	float limit = step(0.5, base);
	return mix(2.0 * base * blend, 1.0 - 2.0 * (1.0 - base) * (1.0 - blend), limit);
}

vec2 to_polar(vec2 uv)
{
	vec2 dir = uv - 0.5;
	float radius = length(dir) * 2.0;
	float angle = atan(dir.y, dir.x) * 1.0/(3.1416 * 2.0);
	return vec2(radius, angle * 2.0);
}

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	float gradient = texture(gradient_texture, UV).r * grow_amount;
	gradient = max(pow(gradient, 8.0), 0.0);
	
	vec2 uv = UV - 0.5;
	vec2 noise_uv = to_polar(UV) - vec2(TIME * 0.2, 0.0);
	float noise = texture(noise_texture, noise_uv).r;
	gradient = mix(overlay(gradient, noise), gradient, 0.5);
	float value = mix(gradient, floor(gradient * 3.0) / 3.0, edge_hardness);
	
	vec3 color = mix(secondary_color, primary_color, pow(value, color_curve));
	
	ALBEDO = color * emission;
	
	float alpha = smoothstep(edge_hardness * edge_position, 1.01 - edge_hardness * (1.0 - edge_position), gradient);
	ALPHA = alpha;
}