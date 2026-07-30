shader_type spatial;
render_mode unshaded, blend_add, cull_disabled;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0,0.8,0.2);
uniform vec3 secondary_color : source_color = vec3(1.0,0.4,0.1);
uniform vec3 tertiary_color : source_color = vec3(0.6,0.1,0.05);
uniform float emission = 2.0;
uniform float color_curve = 4.0;

group_uniforms Shape;
uniform sampler2D noise_texture;
uniform vec2 noise_scale = vec2(1.0);
uniform vec2 noise_scroll = vec2(0.1, 0.5);
uniform float noise_curve : hint_range(0.0, 8.0, 0.1) = 1.0;
uniform float grow_amount : hint_range(0.0, 1.0, 0.05) = 1.0;

group_uniforms Wave;
uniform float wave_scale = 2.0;
uniform float wave_offset : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform float wave_speed = 1.0;
uniform float wave_noise = 0.6;
uniform float wave_detail = 3.0;
uniform float wave_twist = 2.0;

group_uniforms Spiral;
uniform float spiral_amount : hint_range(0.0, 1.0, 0.1) = 0.3;
uniform float spiral_scale = 20.0;
uniform int spiral_count = 3;
uniform float spiral_speed = 20.0;

group_uniforms Transparency;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.2;

float overlay(float base, float blend){
	float limit = step(0.5, base);
	return mix(2.0 * base * blend, 1.0 - 2.0 * (1.0 - base) * (1.0 - blend), limit);
}

float wave(vec2 uv, float offset) {
	float x_wave = sin(uv.x * TAU * wave_detail + (uv.y * TAU * wave_twist)) * 0.2;
	float tiled_y = fract((uv.y * 2.0 - TIME * wave_speed) * wave_scale + offset * wave_noise + x_wave);
	float front = tiled_y / wave_offset;
	float back = (1.0 - tiled_y) / (1.0 - wave_offset);
	
	return min(front, back);
}

void vertex() {
	float noise = texture(noise_texture, UV * noise_scale + (TIME * noise_scroll)).r;
	float wave = wave(UV, noise);
	
	VERTEX += NORMAL * pow(wave, 0.4) * 0.1 * (UV.y);
	
	float spiral = sin(UV.y * spiral_scale + (UV.x * TAU * float(spiral_count)) - TIME * spiral_speed) * smoothstep(0.2, 0.4, UV.y);
	
	VERTEX += NORMAL * spiral * 0.1 * spiral_amount;
}

void fragment() {
	float noise = 1.0 - texture(noise_texture, UV + vec2(TIME * 0.5, 0.0)).r;
	
	float wave = wave(UV, noise);
	wave = pow(wave, noise_curve);
	
	float fade_tail = max(((1.0 - UV.y) + wave * 0.1) - .4, 0.0);
	fade_tail = smoothstep((1.0 - grow_amount), 0.5 + (1.0 - grow_amount) * 0.5, fade_tail);
	
	float tail_color_mix = mix(wave, floor(wave * 2.0) / 2.0, edge_hardness);
	vec3 tail_color = mix(tertiary_color, secondary_color, tail_color_mix);
	
	float color_mix = mix(pow(fade_tail, color_curve), floor(pow(fade_tail, 4.0) * 2.0) / 2.0, edge_hardness);
	vec3 color = mix(tail_color, primary_color, color_mix);
	
	ALBEDO = color * emission;
	
	float alpha = smoothstep(edge_hardness * edge_position, 1.01 - edge_hardness * (1.0 - edge_position), fade_tail);
	
	ALPHA = alpha;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
