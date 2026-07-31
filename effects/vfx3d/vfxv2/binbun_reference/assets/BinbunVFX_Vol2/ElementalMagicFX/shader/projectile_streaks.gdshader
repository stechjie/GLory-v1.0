shader_type spatial;
render_mode unshaded, cull_disabled, blend_add;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0,0.8,0.2);
uniform vec3 secondary_color : source_color = vec3(1.0,0.4,0.1);
uniform vec3 tertiary_color : source_color = vec3(0.6,0.1,0.05);
uniform float emission = 2.0;

group_uniforms Shape;
uniform sampler2D noise_texture;
uniform vec2 noise_scale = vec2(1.0);
uniform float grow_amount : hint_range(0.0, 1.0, 0.05) = 1.0;
uniform float streaks_width : hint_range(0.0, 2.0, 0.1) = 0.1;

group_uniforms Spiral;
uniform float spiral_amount : hint_range(0.0, 1.0, 0.1) = 0.3;
uniform float spiral_scale = 20.0;
uniform int spiral_count = 3;
uniform float spiral_speed = 20.0;
uniform float spiral_noise : hint_range(0.0, 1.0, 0.01) = 0.0;

group_uniforms Transparency;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;

float wobble(vec2 uv){
	float wobble = sin(uv.y * spiral_scale + (uv.x * TAU * float(spiral_count)) - TIME * spiral_speed);
	return wobble;
}

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	float noise = texture(noise_texture, UV * noise_scale).r;
	float spiral = wobble(UV + noise * spiral_noise) * 0.5 + 0.5;
	float gradient = pow(UV.y / 0.5, streaks_width);
	spiral = max(spiral - gradient, 0.0);
	
	spiral *= grow_amount;
	spiral = smoothstep(0.02 * edge_hardness, 0.1 * (1.0 - edge_hardness * 0.8) + 0.001, spiral);
	
	ALBEDO = primary_color * emission;
	ALPHA = spiral;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
