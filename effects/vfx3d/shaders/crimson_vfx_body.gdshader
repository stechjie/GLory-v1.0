shader_type spatial;
// Crimson race (赤律族) solid/body layer: arrow shafts, frost crystals, shards,
// the guard's aegis panel and armour cracks. Alpha-blended with a dark rim so
// the shapes stay readable over the bright snow arena without bloom.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

uniform vec4 dark_color : source_color = vec4(0.12, 0.006, 0.02, 1.0);
uniform vec4 main_color : source_color = vec4(0.74, 0.018, 0.055, 1.0);
uniform vec4 core_color : source_color = vec4(1.0, 0.28, 0.17, 1.0);
uniform vec4 highlight : source_color = vec4(1.0, 0.77, 0.88, 1.0);
uniform float opacity = 1.0;
uniform float flash = 0.0;        // 0..1 brief white-hot pulse on spawn/impact
uniform float facet = 0.6;        // how strongly view-angle facets brighten
// 0 faceted solid (vertex COLOR.r = core weight), 1 hex panel (UV grid),
// 2 crack lines (vertex COLOR.r = heat along the crack), 3 plain vertex colour.
uniform int style = 0;
uniform float age = 0.0;

void fragment() {
	float core_w = clamp(COLOR.r, 0.0, 1.0);
	float rim = pow(1.0 - clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0), 1.7);
	vec3 col;
	float alpha = COLOR.a;
	if (style == 1) {
		// Aegis panel: hexagonal cells, bright frame, nearly clear centre.
		vec2 uv = UV * vec2(6.0, 3.4);
		vec2 g = vec2(uv.x + 0.5 * mod(floor(uv.y), 2.0), uv.y);
		vec2 cell = abs(fract(g) - 0.5);
		float hex_line = 1.0 - smoothstep(0.38, 0.48, max(cell.x * 1.15 + cell.y * 0.58, cell.y * 1.15));
		float edge_u = min(UV.x, 1.0 - UV.x);
		float edge_v = min(UV.y, 1.0 - UV.y);
		float frame = 1.0 - smoothstep(0.02, 0.09, min(edge_u, edge_v));
		float lines = max(frame, (1.0 - hex_line) * 0.65);
		col = mix(main_color.rgb, core_color.rgb, lines);
		col = mix(col, highlight.rgb, frame * flash);
		alpha *= clamp(0.12 + lines * 0.80 + rim * 0.25, 0.0, 1.0);
	} else if (style == 2) {
		col = mix(main_color.rgb, core_color.rgb, core_w);
		col = mix(col, highlight.rgb, core_w * core_w * 0.7);
	} else if (style == 3) {
		col = mix(dark_color.rgb, main_color.rgb, smoothstep(0.0, 0.5, core_w));
		col = mix(col, core_color.rgb, smoothstep(0.5, 1.0, core_w));
	} else {
		// Three-value structure: dark edge -> crimson body -> hot core.
		float body = clamp(core_w + rim * facet * 0.55, 0.0, 1.0);
		col = mix(dark_color.rgb, main_color.rgb, smoothstep(0.0, 0.45, body));
		col = mix(col, core_color.rgb, smoothstep(0.45, 0.85, body));
		col = mix(col, highlight.rgb, smoothstep(0.82, 1.0, body) * 0.75);
	}
	col = mix(col, highlight.rgb, clamp(flash, 0.0, 1.0) * 0.65);
	ALBEDO = col;
	ALPHA = clamp(alpha * opacity, 0.0, 1.0);
}
