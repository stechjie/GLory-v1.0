shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform bool low_quality = false;
uniform float emphasis : hint_range(0.0, 1.0) = 0.0;
uniform float dissolve : hint_range(0.0, 1.0) = 0.0;
uniform float wall_length = 8.8;

// Animate light only; geometry stays fixed so lane boundaries remain parallel.
void fragment() {
	float along = UV.x * wall_length;
	float y = UV.y;
	float crest = smoothstep(0.88, 0.99, y);
	float foot = 1.0 - smoothstep(0.015, 0.13, y);
	// Pulse along the wall only: no diagonal bands, wandering highlights or side sway.
	float pulse = 0.5 + 0.5 * sin(along * 3.0 - TIME * 1.1);
	float detail = low_quality ? 0.0 : pulse * 0.04;
	float ends = smoothstep(0.0, 0.025, UV.x) * smoothstep(0.0, 0.025, 1.0 - UV.x);
	vec3 aqua = mix(vec3(0.12, 0.74, 0.89), vec3(0.66, 0.98, 0.93), crest);
	ALBEDO = aqua + vec3(detail);
	ALPHA = (0.42 + crest * 0.28 + foot * 0.08 + detail + emphasis * 0.06) * ends * (1.0 - dissolve);
}
