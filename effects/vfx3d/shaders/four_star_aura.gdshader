shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform sampler2D blade_mask : filter_linear_mipmap;
uniform vec4 dark_color : source_color;
uniform vec4 body_color : source_color;
uniform vec4 core_color : source_color;
uniform float clock = 0.0;
uniform float opacity = 0.8;
uniform float energy = 0.35;
uniform float element_mode = 0.0;
uniform float burst = 0.0;
uniform float duration = 1.2;

void vertex() {
	float seed = COLOR.r * 6.0;
	float wave = sin(clock * 2.0 + seed + UV.x * 4.0);
	if (burst > 0.5) {
		float t = clamp((clock - 0.12 - seed * 0.012) / duration, 0.0, 1.0);
		float release = 1.0 - pow(1.0 - clamp(t * 3.0, 0.0, 1.0), 3.0);
		VERTEX.xz *= 0.72 + release * (element_mode == 1.0 ? 0.7 : 0.4);
		VERTEX.y *= 0.64 + release * 0.58;
		VERTEX.y += t * (element_mode == 1.0 ? 0.10 : 0.28);
	} else if (element_mode == 0.0) {
		VERTEX.y += wave * 0.045 * UV.x;
		VERTEX.xz *= 1.0 + wave * 0.055;
	} else if (element_mode == 1.0) {
		VERTEX.xz *= 1.0 + pow(0.5 + 0.5 * wave, 3.0) * 0.09;
		VERTEX.y += sin(clock * 1.3 + seed) * 0.012;
	} else {
		VERTEX.xz *= 0.93 + pow(0.5 + 0.5 * wave, 2.0) * 0.15;
		VERTEX.y += wave * 0.02;
	}
}

void fragment() {
	float painted = texture(blade_mask, vec2(1.0 - UV.x, UV.y)).a;
	float across = abs(UV.y * 2.0 - 1.0);
	float body = smoothstep(0.12, 0.8, painted);
	float core = (1.0 - smoothstep(0.04, 0.28, across)) * body;
	float seed = COLOR.r * 6.0;
	float pulse = 0.65 + 0.35 * pow(0.5 + 0.5 * sin(clock * 2.5 - UV.x * 6.0 + seed), 2.0);
	float alpha = painted * pulse * opacity;
	if (burst > 0.5) {
		float t = (clock - 0.12 - seed * 0.012) / duration;
		float reveal = smoothstep(0.0, 0.15, t - UV.x * 0.07);
		float fade = 1.0 - smoothstep(0.26, 0.90, t + UV.x * 0.12);
		alpha = painted * opacity * reveal * fade;
	}
	vec3 color = mix(dark_color.rgb, body_color.rgb, body);
	color = mix(color, core_color.rgb, core * 0.70);
	ALBEDO = color;
	EMISSION = color * energy * (0.35 + core);
	ALPHA = clamp(alpha, 0.0, 0.94);
}
