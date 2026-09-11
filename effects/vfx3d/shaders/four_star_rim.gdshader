shader_type spatial;
render_mode unshaded, depth_draw_never;
uniform vec4 tint : source_color = vec4(1.0, 0.72, 0.24, 1.0);
uniform float clock = 0.0;
uniform float opacity = 0.0;
uniform float eligible = 0.0;
void fragment() {
	float edge = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 1.4);
	float pulse = mix(0.85, 0.24 + 0.76 * pow(0.5 + 0.5 * sin(clock * 2.513), 2.0), eligible);
	ALBEDO = tint.rgb;
	EMISSION = tint.rgb * 0.35;
	ALPHA = (0.08 + edge * 0.92) * opacity * pulse;
}
