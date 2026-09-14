shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 shadow_color : source_color = vec4(0.025, 0.030, 0.026, 0.34);

void fragment() {
	vec2 point = (UV - vec2(0.5)) * 2.0;
	float radius_squared = dot(point, point);
	float core = 1.0 - smoothstep(0.08, 0.34, radius_squared);
	float feather = 1.0 - smoothstep(0.18, 1.0, radius_squared);
	ALBEDO = shadow_color.rgb;
	ALPHA = shadow_color.a * mix(feather, core, 0.28);
}
