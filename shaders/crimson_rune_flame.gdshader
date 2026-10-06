shader_type canvas_item;
render_mode blend_add;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float phase = 0.0;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float a = atan(p.y, p.x);
	float r = length(vec2(p.x * 0.86, p.y * 1.06));
	float flutter = sin(a * 7.0 + TIME * 3.2 + phase) * 0.075
		+ sin(a * 13.0 - TIME * 4.1 + phase * 1.7) * 0.045;
	float edge = (1.0 - smoothstep(0.66 + flutter, 0.83 + flutter, r))
		* smoothstep(0.37, 0.53, r);
	float gaps = 0.64 + 0.36 * sin(a * 5.0 - TIME * 2.0 + phase);
	float tongues = 0.0;
	for (int i = 0; i < 3; i++) {
		float path = (float(i) - 1.0) * 0.47
			+ 0.07 * sin(TIME * (2.1 + float(i) * 0.4) + p.y * 8.0 + phase);
		float thread = 1.0 - smoothstep(0.035, 0.15, abs(p.x - path));
		float rise = smoothstep(-0.99, -0.78, p.y)
			* (1.0 - smoothstep(-0.23, 0.47, p.y));
		tongues = max(tongues, thread * rise * (0.65 + float(i == 1) * 0.25));
	}
	float flame = (edge * gaps * 0.60 + tongues * 0.32) * intensity;
	vec3 color = mix(vec3(0.82, 0.035, 0.018), vec3(1.0, 0.47, 0.12), clamp(edge + tongues * 0.45, 0.0, 1.0));
	COLOR = vec4(color, clamp(flame, 0.0, 0.75));
}
