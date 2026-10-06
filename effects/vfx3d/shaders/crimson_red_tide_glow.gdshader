shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

uniform vec4 main_color : source_color = vec4(0.74, 0.018, 0.055, 1.0);
uniform vec4 core_color : source_color = vec4(1.0, 0.28, 0.17, 1.0);
uniform float opacity = 0.0;
uniform float reveal = 0.0;
uniform float flare = 0.0;
uniform float phase = 0.0;
uniform float flow_speed = 0.64;
uniform float filament = 0.0;
uniform float emission_energy = 2.4;

void fragment() {
	float across = abs(UV.y * 2.0 - 1.0);
	float drawn = 1.0 - smoothstep(reveal - 0.065, reveal + 0.015, UV.x);
	float head = fract(TIME * flow_speed + phase * 0.159);
	float distance_to_head = abs(UV.x - head);
	distance_to_head = min(distance_to_head, 1.0 - distance_to_head);
	float moving_core = 1.0 - smoothstep(0.012, 0.075, distance_to_head);
	float shimmer = 0.82 + 0.18 * sin(UV.x * 75.0 - TIME * 7.0 + phase);
	vec3 pink = mix(main_color.rgb, vec3(1.0, 0.47, 0.37), 0.55);
	vec3 white_hot = vec3(1.0, 0.77, 0.88);
	float envelope = 1.0 - smoothstep(0.05, 1.0, across);
	if (filament < 0.0) {
		float glow = pow(envelope, 1.45);
		vec3 color = mix(pink, white_hot, moving_core * 0.42);
		ALBEDO = color;
		EMISSION = color * emission_energy * (1.25 + moving_core * 0.65 + flare * 0.35);
		ALPHA = clamp(glow * drawn * opacity * COLOR.a
			* (0.36 + moving_core * 0.15 + flare * 0.08), 0.0, 0.62);
	} else {
		float line = 1.0 - smoothstep(0.15, 0.95, across);
		float hot = clamp(0.50 + moving_core * 0.50 + flare * 0.12, 0.0, 1.0);
		vec3 color = mix(core_color.rgb, white_hot, hot);
		ALBEDO = color;
		EMISSION = color * emission_energy * (1.35 + moving_core * 1.45 + flare * 0.42);
		ALPHA = clamp(line * drawn * opacity * COLOR.a * shimmer
			* (0.82 + moving_core * 0.18), 0.0, 0.94);
	}
}
