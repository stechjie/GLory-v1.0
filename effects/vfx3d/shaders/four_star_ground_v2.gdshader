shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform vec4 dark_color : source_color;
uniform vec4 body_color : source_color;
uniform vec4 core_color : source_color;
uniform float clock = 0.0;
uniform float opacity = 0.5;
uniform float burst = 0.0;

void fragment() {
	float across = abs(UV.y * 2.0 - 1.0);
	float ends = smoothstep(0.0, 0.10, UV.x) * (1.0 - smoothstep(0.84, 1.0, UV.x));
	float pulse = 0.72 + 0.28 * sin(clock * 2.1 - UV.x * 9.0 + COLOR.r * 12.0);
	float alpha = ends * (1.0 - smoothstep(0.36, 1.0, across)) * pulse * opacity;
	if (burst > 0.5) {
		alpha *= (1.0 - smoothstep(0.42, 1.05, clock));
	}
	float core = pow(1.0 - across, 6.0);
	vec3 color = mix(dark_color.rgb, body_color.rgb, 0.68 + core * 0.22);
	color = mix(color, core_color.rgb, core * 0.68);
	ALBEDO = color;
	EMISSION = color * (0.35 + core * 0.55);
	ALPHA = clamp(alpha, 0.0, 0.78);
}
