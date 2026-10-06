shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec4 dark_color : source_color = vec4(0.15, 0.008, 0.024, 1.0);
uniform vec4 main_color : source_color = vec4(0.82, 0.025, 0.075, 1.0);
uniform vec4 core_color : source_color = vec4(1.0, 0.54, 0.32, 1.0);
uniform float opacity = 0.0;
uniform float reveal = 0.0;
uniform float flare = 0.0;
uniform float phase = 0.0;
uniform float flow_speed = 0.64;
uniform float filament = 0.0;
uniform float emission_energy = 2.4;

void fragment() {
	float angle = UV.x * 6.2831853;
	float across = abs(UV.y * 2.0 - 1.0);
	float torn_edge = 0.79 + 0.10 * sin(angle * 11.0 + phase * 2.3 + TIME * 2.1)
		+ 0.06 * sin(angle * 23.0 - TIME * 3.8 + phase);
	float band = 1.0 - smoothstep(torn_edge - 0.23, torn_edge + 0.13, across);
	float uneven = 0.77 + 0.17 * sin(angle * 7.0 - TIME * 2.4 + phase)
		* sin(angle * 15.0 + TIME * 1.6);
	float drawn = 1.0 - smoothstep(reveal - 0.065, reveal + 0.015, UV.x);

	float head = fract(TIME * flow_speed + phase * 0.159);
	float distance_to_head = abs(UV.x - head);
	distance_to_head = min(distance_to_head, 1.0 - distance_to_head);
	float moving_core = 1.0 - smoothstep(0.012, 0.075, distance_to_head);
	float ember = pow(max(0.0, sin(angle * 19.0 - TIME * 7.0 + phase * 5.0)), 22.0);
	float inner = 1.0 - smoothstep(0.08, 0.54, across);
	float hot = inner * clamp(moving_core * 0.91 + ember * 0.12 + flare * 0.26, 0.0, 1.0);
	if (filament < -0.5) {
		float haze = 1.0 - smoothstep(0.08, 1.0, across);
		vec3 glow = mix(main_color.rgb, core_color.rgb, moving_core * 0.32);
		ALBEDO = glow;
		EMISSION = glow * emission_energy * (0.50 + moving_core * 0.54 + flare * 0.28);
		ALPHA = clamp(haze * drawn * opacity * COLOR.a
			* (0.18 + moving_core * 0.11 + flare * 0.06), 0.0, 0.38);
	} else if (filament > 0.5) {
		float thread = 0.36 + 0.23 * sin(angle * 6.0 - TIME * 3.1 + phase)
			+ moving_core * 0.39 + flare * 0.18;
		vec3 glow = mix(main_color.rgb, core_color.rgb, clamp(0.38 + hot * 0.62, 0.0, 1.0));
		glow = mix(glow, vec3(1.0, 0.77, 0.88), pow(moving_core, 4.0) * inner * 0.78);
		ALBEDO = glow;
		EMISSION = glow * emission_energy * (0.60 + moving_core * 1.50 + flare * 0.45);
		ALPHA = clamp(band * drawn * opacity * COLOR.a * thread, 0.0, 0.88);
	} else {
		vec3 body = mix(dark_color.rgb, main_color.rgb, 0.28 + inner * 0.61);
		ALBEDO = body;
		EMISSION = body * emission_energy * (0.15 + inner * 0.20 + moving_core * 0.12);
		ALPHA = clamp(band * uneven * drawn * opacity * COLOR.a
			* (0.27 + moving_core * 0.08 + flare * 0.05), 0.0, 0.42);
	}
}
