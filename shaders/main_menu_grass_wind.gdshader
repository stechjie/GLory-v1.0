shader_type canvas_item;

// 主菜单草地的风：画在整张背景之上，只在草地遮罩里出效果。
// 1. 草面轻微摆动（UV 横向小幅晃）
// 2. 一道道偏亮的风痕顺风扫过，风痕经过处草也被压得更弯
// gust 由 MainMenuAmbience 每帧写入（0~1），与飘叶共用同一条阵风曲线。
uniform sampler2D mask_texture : filter_linear;
uniform sampler2D noise_texture : repeat_enable, filter_linear;
uniform vec2 wind_direction = vec2(1.0, 0.22);
uniform float gust = 0.5;
uniform float sway_px = 1.4;
uniform float streak_strength = 0.16;
uniform vec3 streak_tint : source_color = vec3(1.0, 0.97, 0.62);
uniform vec2 ref_size = vec2(1672.0, 941.0);

float n(vec2 p) {
	return texture(noise_texture, p).r;
}

void fragment() {
	float m = texture(mask_texture, UV).r;
	if (m < 0.01) {
		discard;
	}
	vec2 px = UV * ref_size;
	vec2 dir = normalize(wind_direction);
	vec2 side = vec2(-dir.y, dir.x);
	float along = dot(px, dir);
	float across = dot(px, side);

	// 风痕：顺风方向拉长的噪声斑（沿风 : 横风 ≈ 1 : 5），整体往下风处移动。
	// 两层不同尺度、不同速度，叠出一阵一阵扫过草面的亮条。
	vec2 w = vec2(along, across) / 256.0;
	float g1 = n(vec2(w.x * 0.32 - TIME * 0.30, w.y * 1.6));
	float g2 = n(vec2(w.x * 0.55 - TIME * 0.48, w.y * 2.6 + 0.37));
	float band1 = smoothstep(0.66, 0.88, g1);
	float band2 = smoothstep(0.74, 0.92, g2) * 0.6;
	// 带子内部再打碎一点，像草叶一片片被翻过来
	float grain = n(px / 256.0 * vec2(2.4, 5.0) + dir * TIME * 0.08);
	float streak = clamp(band1 + band2, 0.0, 1.0) * mix(0.55, 1.0, grain);
	streak *= mix(0.45, 1.0, gust);

	// 摆动：常驻的细碎晃动 + 风痕处额外压弯
	float jitter = n(px / 256.0 * 1.3 + vec2(TIME * 0.11, 0.0)) - 0.5;
	float bend = sin(TIME * 1.7 + px.y * 0.045 + jitter * 6.0) * 0.5 + streak * 1.4;
	vec2 offset = dir * bend * sway_px / ref_size;

	vec4 base = texture(TEXTURE, UV - offset * m);
	vec3 color = base.rgb + streak_tint * streak * streak_strength;
	COLOR = vec4(color, m);
}
