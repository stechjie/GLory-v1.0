shader_type spatial;
render_mode unshaded, cull_disabled, blend_add;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0,0.8,0.2);
uniform vec3 secondary_color : source_color = vec3(1.0,0.4,0.1);
uniform float emission = 2.0;
uniform float color_curve = 1.0;

group_uniforms Shape;
uniform sampler2D noise_texture;
uniform vec2 noise_scale = vec2(1.0, 1.0);
uniform vec2 noise_scroll = vec2(0.1, 0.3);
uniform float shape_curve = 1.0;
uniform float grow_amount : hint_range(0.0, 1.0, 0.05) = 1.0;

group_uniforms Transparency;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.2;

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	vec2 scroll = TIME * noise_scroll;
	float noise = texture(noise_texture, UV * noise_scale + scroll).r;
	noise = pow(noise, shape_curve);
	
	float fade_gradient = max(UV.y * 4.0 - 3.0, 0.0);
	
	float wave = sin((fade_gradient + (grow_amount - 0.5) * 2.0) * PI);
	wave = max(wave * fade_gradient, 0.0);
	
	float value = noise * wave;
	value = smoothstep(0.2, 0.8, value);
	
	float mask = cos(UV.x * TAU * 4.0) * 0.5 + 0.5;
	value *= mask;
	
	float glow = pow(max((UV.y - 0.8) / 0.2, 0.0), 2.0);
	glow *= max(sin(grow_amount * PI * 1.5),0.0);
	
	vec3 color = mix(secondary_color, primary_color, pow(value, color_curve));
	color += primary_color * min(glow * 20.0, 1.0);
	
	ALBEDO = color * emission;
	
	float alpha = min(value + glow, 1.0);
	alpha = smoothstep(edge_hardness * edge_position, 1.01 - edge_hardness * (1.0 - edge_position), alpha);
	ALPHA = alpha;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
