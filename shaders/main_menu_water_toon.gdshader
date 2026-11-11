shader_type canvas_item;

// 主菜单卡通水：画在整张背景之上，只在遮罩里出效果。
// mode 0 = 河面（顺流的白色细波纹 + 闪烁高光点）
// mode 1 = 瀑布（竖向白色水纹快速下落，粗细不一）
// mode 2 = 泡沫（瀑布底、石头边一团团翻涌）
uniform int mode = 0;
uniform sampler2D mask_texture : filter_linear;
uniform sampler2D noise_texture : repeat_enable, filter_linear;
uniform vec2 flow_direction = vec2(1.0, 0.0);
uniform float speed = 0.05;
uniform float distortion = 0.002;
uniform float line_strength = 0.55;
uniform float sparkle_strength = 0.8;
uniform vec2 ref_size = vec2(1672.0, 941.0);

const vec3 FOAM = vec3(0.96, 1.0, 1.0);

float n(vec2 p) {
	return texture(noise_texture, p).r;
}

void fragment() {
	float m = texture(mask_texture, UV).r;
	if (m < 0.01) {
		discard;
	}
	vec2 px = UV * ref_size / 256.0; // 噪声按屏幕像素铺，不随画布比例拉伸
	vec2 dir = normalize(flow_direction);
	vec2 side = vec2(-dir.y, dir.x);
	float t = TIME * speed;
	vec3 add = vec3(0.0);
	float alpha = 0.0;
	vec2 warp = vec2(0.0);

	if (mode == 0) {
		// 沿水流方向拉长的噪声 → 细长波纹；两层反向错开，交叠处才亮
		vec2 q = vec2(dot(px, dir) * 0.9, dot(px, side) * 4.5);
		float a = n(q - vec2(t, 0.0));
		float b = n(q * 1.37 + vec2(-t * 0.63, 0.21));
		float ridge = 1.0 - abs(a + b - 1.0) * 2.0;
		float lines = smoothstep(0.78, 0.97, ridge);
		// 高光点：高频噪声取峰值，按各自相位闪
		float s = n(px * 3.1 + vec2(t * 0.4, 0.0));
		float tw = 0.5 + 0.5 * sin(TIME * 3.0 + n(px * 1.7) * 40.0);
		float spark = smoothstep(0.84, 0.93, s) * tw * tw;
		warp = side * (a - 0.5) * distortion;
		add = FOAM * (lines * line_strength + spark * sparkle_strength);
		alpha = max(lines * line_strength, spark * sparkle_strength);
	} else if (mode == 1) {
		// 横向高频、竖向低频 = 竖条纹，往下滚
		vec2 q = vec2(px.x * 9.0, px.y * 0.7 - TIME * speed);
		float a = n(q);
		float b = n(q * vec2(0.53, 1.6) + vec2(0.37, -TIME * speed * 0.6));
		float streak = smoothstep(0.52, 0.78, a * 0.65 + b * 0.35);
		float dark = smoothstep(0.42, 0.30, a) * 0.25;
		warp = vec2(0.0, (b - 0.5) * distortion);
		add = FOAM * streak * line_strength - vec3(0.05, 0.02, 0.0) * dark;
		alpha = max(streak * line_strength, dark);
	} else {
		// 两层慢速噪声对冲，阈值随时间起伏 → 泡沫鼓起又散开
		float a = n(px * 2.2 + vec2(TIME * speed, TIME * speed * 0.4));
		float b = n(px * 3.4 - vec2(TIME * speed * 0.7, -TIME * speed * 0.2));
		float v = a * 0.55 + b * 0.45;
		float th = 0.50 + 0.05 * sin(TIME * 2.3 + a * 6.0);
		float foam = smoothstep(th - 0.04, th + 0.14, v);
		add = FOAM * foam;
		alpha = foam * line_strength;
	}

	if (mode == 2) {
		COLOR = vec4(FOAM, alpha * m);
	} else {
		// 底图就是背景本身，遮罩内整片替换 = 只多出扭曲和白纹，边缘无缝
		vec4 base = texture(TEXTURE, UV + warp * m);
		COLOR = vec4(base.rgb + add, m);
	}
}
