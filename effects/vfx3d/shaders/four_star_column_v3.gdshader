shader_type spatial;
// Four-star aura column V3: an open, slightly tapered cylinder around the unit
// that makes the aura read from the top-down board camera. It may overlap the
// model on purpose. All three elements use the same swirling wind sheet;
// `style` only changes colour-independent character (speed / density):
//   0 = sky  : airy, medium speed
//   1 = land : broader, slower heat swirl
//   2 = ren  : denser, faster, more aggressive swirl
// UV.x = around (0..1), UV.y = height (0 bottom .. 1 top).
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix;

uniform int style = 0;
uniform vec4 dark_color : source_color;
uniform vec4 body_color : source_color;
uniform vec4 core_color : source_color;
uniform float opacity = 1.0;
// Near (camera-facing) wall is dimmed so the model's face stays readable.
uniform float front_opacity = 0.62;

void fragment() {
	float u = UV.x;
	float v = UV.y;

	// Per-style character: [bands, twist, speed, sharpness]
	vec4 k = vec4(3.0, 1.1, 2.6, 5.0);
	vec3 k2 = vec3(5.0, 0.7, 1.9);   // fine streaks: bands, twist, speed
	float boost = 1.0;               // warm colours need more alpha on the yellow-green board
	if (style == 1) {
		k = vec4(2.0, 0.8, 1.7, 3.5);
		k2 = vec3(4.0, 0.5, 1.3);
		boost = 1.7;
	} else if (style == 2) {
		k = vec4(4.0, 1.5, 3.6, 6.0);
		k2 = vec3(7.0, 0.9, 2.8);
		boost = 1.55;
	}

	float s1 = sin((u * k.x + v * k.y) * TAU - TIME * k.z);
	float s2 = sin((u * k2.x - v * k2.y) * TAU + TIME * k2.z);
	float streak = pow(clamp(s1 * 0.5 + 0.5, 0.0, 1.0), k.w);
	float fine = pow(clamp(s2 * 0.5 + 0.5, 0.0, 1.0), 9.0) * 0.6;
	float fade = pow(1.0 - v, 1.4) * smoothstep(0.0, 0.08, v);
	float base = (1.0 - smoothstep(0.0, 0.35, v)) * 0.35;
	float alpha = (max(streak, fine) * 1.25 + base * 1.3) * fade * boost;
	vec3 col = mix(dark_color.rgb, body_color.rgb, clamp((style == 0 ? 0.45 : 0.2) + streak, 0.0, 1.0));
	col = mix(col, core_color.rgb, clamp(streak * streak * (style == 0 ? 0.8 : 0.45) + fine * 0.5, 0.0, 1.0));

	alpha *= opacity * (FRONT_FACING ? front_opacity : 1.0);
	ALBEDO = col;
	ALPHA = clamp(alpha, 0.0, 1.0);
}
