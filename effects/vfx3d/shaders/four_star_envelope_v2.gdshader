shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform vec4 dark_color : source_color = vec4(0.02, 0.10, 0.18, 1.0);
uniform vec4 body_color : source_color = vec4(0.10, 0.66, 0.88, 1.0);
uniform vec4 core_color : source_color = vec4(0.76, 0.96, 1.0, 1.0);
uniform float clock = 0.0;
uniform float opacity = 0.72;
uniform float energy = 0.55;
uniform float burst = 0.0;
uniform float burst_duration = 1.1;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	float seed = COLOR.r * 9.0;
	float breathe = sin(clock * 1.75 + seed + UV.x * 5.0);
	float push = 1.0 + breathe * 0.035;
	if (burst > 0.5) {
		float t = clamp(clock / max(burst_duration, 0.01), 0.0, 1.0);
		float attack = 1.0 - pow(1.0 - clamp(t * 4.2, 0.0, 1.0), 3.0);
		push *= 0.58 + attack * 0.92;
		VERTEX.y += attack * (0.10 + 0.08 * COLOR.g);
	}
	VERTEX.xz *= push;
	VERTEX.y += breathe * 0.012;
}

void fragment() {
	float across = abs(UV.y * 2.0 - 1.0);
	float tapered = smoothstep(0.0, 0.12, UV.x) * (1.0 - smoothstep(0.82, 1.0, UV.x));
	float broken = 0.60 + 0.40 * sin(UV.x * 18.0 + clock * 2.25 + COLOR.r * 15.0);
	float grain = hash21(floor(vec2(UV.x * 31.0, UV.y * 9.0) + COLOR.rg * 17.0));
	float edge_mask = 1.0 - smoothstep(0.52 + broken * 0.10, 1.0, across);
	// COLOR.b marks the camera-facing half of the authored envelope.  The near
	// layer is broader/brighter so the top-down view keeps a clear front edge.
	float depth_weight = mix(1.08, 0.70, COLOR.b);
	float alpha = tapered * edge_mask * (0.78 + grain * 0.22) * opacity * depth_weight;
	float hot = pow(1.0 - across, 5.5) * (0.55 + 0.45 * broken);
	if (burst > 0.5) {
		float t = clock / max(burst_duration, 0.01);
		float reveal = smoothstep(0.0, 0.16, t - UV.x * 0.055);
		float fade = 1.0 - smoothstep(0.38, 0.98, t + UV.x * 0.08);
		alpha *= reveal * fade;
	}
	vec3 color = mix(dark_color.rgb, body_color.rgb, 1.0 - across * 0.76);
	color = mix(color, core_color.rgb, hot * (0.60 + COLOR.b * 0.26));
	ALBEDO = color;
	EMISSION = color * energy * (0.55 + hot * 0.95);
	ALPHA = clamp(alpha, 0.0, 0.95);
}
