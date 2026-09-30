shader_type canvas_item;

uniform float progress : hint_range(0.0, 7.0) = 0.0;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec2 scale = vec2(1.0, 1.55);
	float reveal = 0.0;
	if (progress >= 1.0) reveal = max(reveal, 1.0 - smoothstep(0.22, 0.43,
		length((UV - vec2(0.22, 0.80)) * scale)));
	if (progress >= 2.0) reveal = max(reveal, 1.0 - smoothstep(0.22, 0.43,
		length((UV - vec2(0.79, 0.80)) * scale)));
	if (progress >= 3.0) reveal = max(reveal, 1.0 - smoothstep(0.22, 0.43,
		length((UV - vec2(0.22, 0.46)) * scale)));
	if (progress >= 4.0) reveal = max(reveal, 1.0 - smoothstep(0.22, 0.43,
		length((UV - vec2(0.78, 0.46)) * scale)));
	if (progress >= 5.0) reveal = max(reveal, 1.0 - smoothstep(0.22, 0.43,
		length((UV - vec2(0.50, 0.60)) * scale)));
	if (progress >= 6.0) reveal = max(reveal, 1.0 - smoothstep(0.23, 0.48,
		length((UV - vec2(0.50, 0.16)) * scale)));
	if (progress >= 7.0) reveal = 1.0;
	float gray = dot(base.rgb, vec3(0.25, 0.62, 0.13));
	vec3 dim = mix(vec3(gray), vec3(0.05, 0.13, 0.22), 0.58) * 0.55;
	COLOR = vec4(mix(dim, base.rgb, reveal), base.a);
}
