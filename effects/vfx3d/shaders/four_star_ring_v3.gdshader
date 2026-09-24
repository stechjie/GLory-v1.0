shader_type spatial;
// Four-star ground ring V3. One shader, three art styles picked by `style`:
//   0 = sky  : soft glow, double ring + swirling wind streaks
//   1 = land : low-poly, faceted polygon ring with stepped flicker per facet
//   2 = ren  : toon, thick hard-edged band with outline + rotating highlight
// Alpha-blended (not additive) so colours stay saturated on the green board.
// The scene has no bloom, so every "glow" is painted into the alpha falloff.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix;

uniform int style = 0;
uniform vec4 dark_color : source_color = vec4(0.05, 0.25, 0.55, 1.0);
uniform vec4 body_color : source_color = vec4(0.25, 0.72, 1.0, 1.0);
uniform vec4 core_color : source_color = vec4(0.88, 0.98, 1.0, 1.0);
uniform float opacity = 1.0;
// Ring centre radius in UV space (plane spans -1..1). Mesh size is chosen so
// this lands on the configured world radius.
uniform float ring_radius = 0.80;

float hash11(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

// Anti-aliased "inside" test for a band of half-width w around distance d.
float band(float d, float w, float fw) {
	return 1.0 - smoothstep(w - fw, w + fw, d);
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float fw = max(fwidth(r), 0.002);
	float R = ring_radius;
	vec3 col = body_color.rgb;
	float alpha = 0.0;

	if (style == 0) {
		// ---- sky: soft ----
		float d1 = abs(r - R);
		float d2 = abs(r - R * 0.84);
		float g1 = exp(-pow(d1 / 0.045, 2.0));
		float g2 = exp(-pow(d2 / 0.024, 2.0)) * 0.75;
		float halo = exp(-pow(d1 / 0.14, 2.0)) * 0.34;
		// Wind streaks spiralling between the two rings.
		float spiral = sin(a * 3.0 + r * 10.0 - TIME * 1.7);
		float streak = pow(clamp(spiral * 0.5 + 0.5, 0.0, 1.0), 7.0);
		streak *= smoothstep(R * 0.60, R * 0.78, r) * (1.0 - smoothstep(R * 1.02, R * 1.16, r));
		float travel = 0.75 + 0.25 * sin(a * 2.0 + TIME * 2.3);
		float halo2 = exp(-pow(d1 / 0.06, 2.0)) * 0.55;
		float core = pow(max(g1, g2 * 0.7), 2.5);
		alpha = max(max(g1 * travel, g2), max(max(halo, halo2), streak * 0.6));
		col = mix(dark_color.rgb, body_color.rgb, clamp(alpha * 1.4, 0.0, 1.0));
		col = mix(col, core_color.rgb, clamp(core * 0.8 + streak * 0.25, 0.0, 1.0));
	} else if (style == 1) {
		// ---- land: low-poly ----
		float n = 12.0;
		float sector = TAU / n;
		float aa = a + TIME * 0.12;
		float idx = floor(aa / sector);
		float local_a = mod(aa, sector) - sector * 0.5;
		// Distance to a regular 12-gon edge instead of a circle.
		float q = r * cos(local_a) / cos(sector * 0.5);
		float d = abs(q - R);
		float w = 0.075;
		float outer = band(d, w, fw);
		float body = band(d, w * 0.62, fw);
		float core = band(d, w * 0.26, fw);
		// Stepped per-facet flicker: discrete, not smooth, to read as low-poly.
		float flick = hash11(idx + floor(TIME * 5.0) * 13.0);
		float facet = 0.82 + 0.30 * flick;
		// Inner / outer half of the band get different flat tones (bevel).
		float bevel = step(q, R) * 0.14;
		col = dark_color.rgb;
		col = mix(col, body_color.rgb * (facet + bevel), body);
		col = mix(col, core_color.rgb, core);
		float halo = (1.0 - smoothstep(w, w + 0.10, d)) * 0.22;
		alpha = max(outer, halo);
		col = mix(body_color.rgb, col, outer);
	} else {
		// ---- ren: toon ----
		float breathe = 1.0 + 0.10 * sin(TIME * 2.4);
		float d = abs(r - R);
		float w = 0.09 * breathe;
		float outline = band(d, w, fw);
		float body = band(d, w * 0.68, fw);
		// Core line sits slightly inward, like a lit bevel.
		float core = band(abs(r - (R - w * 0.18)), w * 0.24, fw);
		float hl = smoothstep(0.80, 0.96, cos(a - TIME * 1.3));
		hl += smoothstep(0.90, 0.99, cos(a + 2.4 - TIME * 1.3)) * 0.6;
		col = dark_color.rgb;
		col = mix(col, body_color.rgb, body);
		col = mix(col, core_color.rgb, clamp(core + body * hl * 0.55, 0.0, 1.0));
		float halo = (1.0 - smoothstep(w, w + 0.16, d)) * 0.28;
		alpha = max(outline, halo);
		col = mix(body_color.rgb, col, outline);
	}

	// Keep everything tight to the unit's own circle: nothing spreads past it.
	alpha *= 1.0 - smoothstep(R + 0.09, R + 0.14, r);
	// Tinted inner disc: darkens the bright board inside the ring so the aura pops.
	float fill = (1.0 - smoothstep(R - 0.03, R, r)) * (0.20 + 0.16 * smoothstep(0.0, R, r));
	vec3 fill_col = mix(dark_color.rgb, body_color.rgb, 0.35);
	col = mix(fill_col, col, clamp(alpha / max(alpha + fill * (1.0 - alpha), 0.001), 0.0, 1.0));
	alpha = alpha + fill * (1.0 - alpha);
	ALBEDO = col;
	ALPHA = clamp(alpha * opacity, 0.0, 1.0);
}
