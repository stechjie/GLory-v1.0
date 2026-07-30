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
uniform vec2 noise_scale = vec2(2.0, 1.0);
uniform vec2 noise_scroll = vec2(0.1, 0.3);
uniform float shape_curve = 1.0;
uniform float grow_amount : hint_range(0.0, 1.0, 0.05) = 1.0;
uniform float stepped_animation : hint_range(0.0, 1.0, 0.05) = 0.0;
uniform float animation_steps = 20.0;

group_uniforms Transparency;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.2;

float overlay(float base, float blend){
	float limit = step(0.5, base);
	return mix(2.0 * base * blend, 1.0 - 2.0 * (1.0 - base) * (1.0 - blend), limit);
}

void vertex() {
	float offset = pow(UV.y * 2.0, 8.0);
	
	VERTEX.xz *= 1.0 + offset * 0.1;
}

void fragment() {
	float wave_x = sin((UV.x + TIME * 0.1) * PI * 12.0) * 0.5 + 0.5;
	
	vec2 scroll = mix(TIME * noise_scroll, floor(TIME * noise_scroll * animation_steps) / animation_steps, stepped_animation);
	vec2 noise_uv = UV * noise_scale + scroll;
	
	float noise = texture(noise_texture, noise_uv).r;
	float noise2 = texture(noise_texture, noise_uv * 2.0).r;
	
	noise = overlay(noise, noise2);
	noise = pow(noise, shape_curve);
	
	float gradient = (UV.y * 2.0) - (1.0 - grow_amount);
	
	float noise_mask1 = (gradient - (wave_x * 0.1)) * 2.0 - 1.0;
	float noise_wave1 = sin(noise_mask1 * 8.0 + TIME * 20.0) * 0.5 + 0.5;
	float value1 = overlay(noise_mask1, max(noise - (noise_wave1 * wave_x * 0.5), 0.0));
	value1 = smoothstep(0.2, 1.0, value1);
	value1 = mix(value1, floor(value1 * 3.0) / 2.0, edge_hardness);
	
	
	float noise_mask2 = (gradient - (wave_x * 0.1)) * 2.0 - 0.6;
	float noise_wave2 = sin(noise_mask2 * 8.0 + TIME * 20.0) * 0.5 + 0.5;
	float value2 = overlay(noise_mask2, max(noise - (noise_wave2 * wave_x * 0.5), 0.0));
	value2 = smoothstep(0.2, 1.0, value2);
	value2 = mix(value2, floor(value2 * 3.0) / 2.0, edge_hardness);
	
	float alpha = max(max(value1, value2), pow(gradient, 3.0));
	alpha = smoothstep(edge_hardness * edge_position, 1.01 - edge_hardness * (1.0 - edge_position), alpha);
	ALPHA = alpha;
	
	vec3 layer1_color = mix(secondary_color, primary_color, value1);
	vec3 layer2_color = mix(tertiary_color, secondary_color, pow(value2, color_curve));
	vec3 base_color = mix(layer2_color, layer1_color, value1);
	
	ALBEDO = base_color * emission;
}