shader_type canvas_item;

uniform float brightness : hint_range(0.0, 3.0) = 0.0;
uniform float flash : hint_range(0.0, 1.0) = 0.0;
uniform float glow_strength : hint_range(0.0, 1.0) = 0.0;
uniform bool glow_pass = false;

void fragment() {
	vec4 source = texture(TEXTURE, UV);
	if (glow_pass) {
		vec2 step_uv = TEXTURE_PIXEL_SIZE * 8.0;
		float spread = source.a * 0.42;
		spread += texture(TEXTURE, UV + vec2(step_uv.x, 0.0)).a * 0.12;
		spread += texture(TEXTURE, UV - vec2(step_uv.x, 0.0)).a * 0.12;
		spread += texture(TEXTURE, UV + vec2(0.0, step_uv.y)).a * 0.12;
		spread += texture(TEXTURE, UV - vec2(0.0, step_uv.y)).a * 0.12;
		spread += texture(TEXTURE, UV + step_uv).a * 0.05;
		spread += texture(TEXTURE, UV - step_uv).a * 0.05;
		COLOR = vec4(1.0, 0.16 + brightness * 0.13, 0.035, spread * glow_strength);
	} else {
		float lit = 1.0 + brightness * 0.29 + flash * 0.65;
		vec3 warm = mix(source.rgb, vec3(1.0, 0.66, 0.31), clamp(brightness * 0.20 + flash * 0.22, 0.0, 0.68));
		COLOR = vec4(warm * lit, source.a);
	}
}
