shader_type spatial;
// 防卫套开局护罩：青金色六边形网格 + 边缘菲涅尔亮边。sweep 让一道亮带从下往上扫过护罩。
render_mode unshaded, cull_back, depth_draw_never, blend_mix, fog_disabled, shadows_disabled;
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform float sweep = 0.0;
uniform vec4 grid_color : source_color = vec4(0.45, 0.92, 1.0, 1.0);
uniform vec4 rim_color : source_color = vec4(1.0, 0.86, 0.45, 1.0);
uniform vec4 edge_color : source_color = vec4(0.02, 0.14, 0.24, 1.0);
varying float local_y;

void vertex() {
	local_y = VERTEX.y;
}

float hex_edge(vec2 p) {
	p *= vec2(1.0, 1.1547);
	vec2 a = mod(p, vec2(1.0, 1.7320508)) - vec2(0.5, 0.8660254);
	vec2 b = mod(p + vec2(0.5, 0.8660254), vec2(1.0, 1.7320508)) - vec2(0.5, 0.8660254);
	vec2 g = dot(a, a) < dot(b, b) ? a : b;
	vec2 q = abs(g);
	float dist = max(dot(q, normalize(vec2(1.0, 1.7320508))), q.x);
	return smoothstep(0.40, 0.47, dist);
}

void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.2);
	float grid = hex_edge(UV * vec2(14.0, 7.0));
	float band = exp(-pow((local_y - sweep) / 0.12, 2.0));
	vec3 color = mix(grid_color.rgb, rim_color.rgb, clamp(fresnel * 0.6 + band, 0.0, 1.0));
	float outline = smoothstep(0.82, 0.95, fresnel);
	color = mix(color, edge_color.rgb, outline * 0.55);
	float alpha = grid * (0.30 + 0.55 * fresnel) + fresnel * 0.45 + band * 0.55 * (0.4 + grid);
	ALBEDO = color;
	ALPHA = clamp(alpha, 0.0, 0.95) * fade;
	if (ALPHA < 0.01) {
		discard;
	}
}
