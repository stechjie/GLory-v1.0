shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 team_color : source_color = vec4(0.25, 0.85, 1.0, 0.48);

void fragment() {
	float radius = length((UV - vec2(0.5)) * 2.0);
	float ring = smoothstep(0.75, 0.80, radius) * (1.0 - smoothstep(0.85, 0.90, radius));
	ALBEDO = team_color.rgb;
	ALPHA = ring * team_color.a;
}
