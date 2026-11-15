// 商店手牌铭牌的「能量流动」（2026-11-15）：稀有（蓝）、史诗（金）用，普通卡不挂。
// 盖在卡框贴图同一块区域上，UV 与卡框贴图一致；只在 plate_mask 白色处发光，名字 Label 画在上面不受影响。
//   扫光：每圈从左到右扫过一次，带一点斜度（稀有卡 sweep_strength = 0，不扫）；
//   流光：两层值噪声反向滚动，取亮的部分做成流动的光纹，整体随圈数轻微呼吸；
//   星光：铭牌上沿冒出的十字星，往上飘、左右轻摆、淡出（特效画风：柔和十字星，不挂几何小图形）。
// 叠加混合：只加亮，不遮挡。preview 脚本：reports/hand_card_style/v6_plate_energy/plate_energy2.py。
shader_type canvas_item;
render_mode blend_add, unshaded;

uniform sampler2D plate_mask : filter_linear, repeat_disable;
uniform vec4 plate_rect = vec4(0.11, 0.835, 0.887, 0.933);   // 铭牌在 UV 里的 x0, y0, x1, y1
uniform float period = 2.0;
uniform float phase = 0.0;
uniform float speed = 1.0;            // 0 = 减少动态：画面静止
uniform vec3 sweep_color : source_color = vec3(1.0, 0.97, 0.82);
uniform float sweep_strength = 0.55;
uniform float sweep_width = 0.075;
uniform vec3 flow_color : source_color = vec3(1.0, 0.86, 0.45);
uniform float flow_strength = 0.32;
uniform float flow_low = 0.52;
uniform vec3 spark_color : source_color = vec3(1.0, 0.97, 0.84);
uniform int spark_count = 9;
uniform float spark_strength = 0.9;
uniform float spark_size = 0.022;     // UV 单位
uniform float spark_rise = 0.075;     // 星光一生往上飘的距离（UV）

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float cross_star(vec2 d, float r) {
	vec2 a = abs(d);
	float s1 = 1.0 - a.x / (r * 0.22) - a.y / r;
	float s2 = 1.0 - a.y / (r * 0.22) - a.x / r;
	return clamp(max(s1, s2) * 3.0, 0.0, 1.0);
}

void fragment() {
	float clock = TIME * speed;
	float t = fract(clock / period + phase);
	vec2 size = plate_rect.zw - plate_rect.xy;
	vec2 pu = (UV - plate_rect.xy) / size;
	vec3 add = vec3(0.0);
	float m = texture(plate_mask, UV).r;
	if (m > 0.002) {
		float xc = -0.35 + 1.7 * t;
		float sw = exp(-pow(((pu.x + (pu.y - 0.5) * 0.25) - xc) / sweep_width, 2.0));
		// 噪声沿铭牌宽方向约 8 格；层 1 每圈滚过一个铭牌宽，层 2 反向、半速
		float a1 = vnoise(vec2(pu.x * 8.0 - clock / period * 8.0, pu.y * 2.2 + 3.1));
		float a2 = vnoise(vec2(pu.x * 6.0 + clock / period * 3.0 + 17.0, pu.y * 2.6 + 9.4));
		float flow = smoothstep(flow_low, 0.85, a1 * 0.6 + a2 * 0.4);
		float breath = 0.85 + 0.15 * sin(t * TAU);
		add = (sweep_color * sw * sweep_strength + flow_color * flow * flow_strength * breath) * m;
	}
	for (int i = 0; i < 12; i++) {
		if (i >= spark_count) {
			break;
		}
		float fi = float(i);
		float sx = hash(vec2(fi, 1.7));
		float ph = hash(vec2(fi, 8.3));
		float sp = 1.0 + floor(hash(vec2(fi, 4.1)) * 2.0);     // 每圈 1 或 2 次，首尾接得上
		float life = fract(t * sp + ph);
		vec2 c = vec2(plate_rect.x + sx * size.x + sin((life + ph) * TAU) * 0.006,
				plate_rect.y + 0.004 - life * spark_rise);
		float a = pow(sin(life * PI), 1.5);
		add += spark_color * cross_star(UV - c, spark_size * (0.6 + 0.5 * (1.0 - life))) * a * spark_strength;
	}
	COLOR = vec4(add, 1.0);
}
