shader_type spatial;
// 摆放界面下河的「水在流」那一层（11.12，默认青草地皮肤）。
//
// 叠在河面底图（PrepRiverBottomLayer）上面，只在**水**的像素上画（青蓝色：蓝明显大于红），
// 河里的石头、岸边那道草线都不画 —— 它们保持静止，只有水在动：
//   1. 水面纹理顺流往右「淌」：flow map 的两相位交替法（各自往下游拖一小段再淡出换另一相），
//      看起来是连续流动，但不会把整张图越拖越远；拖到石头上取到的颜色退回原图，石头不糊；
//   2. 被拉长的白色细流纹往下游漂（两层不同速度），流向一眼就看得出；
//   3. 一层很淡的水底网状亮纹，同方向漂。
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, specular_disabled;

uniform sampler2D river_tex : source_color, filter_linear_mipmap;
uniform sampler2D noise_tex : repeat_enable, filter_linear;   // 无缝噪声（PrepBoardModels 生成）
uniform float flow_speed = 0.05;      // 流纹往下游漂的速度（UV/秒，正 = 往右）
uniform float drag_len = 0.018;       // 每个相位里纹理被往下游拖多远
uniform float drag_cycle = 1.6;       // 一个相位多少秒
uniform float streak_gain = 0.55;     // 白色流纹强度
uniform float caustic_gain = 0.25;    // 网状亮纹强度
uniform vec2 caustic_scale = vec2(26.0, 9.0);

// 水的像素：有颜色、蓝比红高出一截（石头是灰的、草线是绿的）
float water_mask(vec4 c) {
	float blue_lead = c.b - c.r;
	float not_green = smoothstep(-0.02, 0.06, c.b - c.g);
	return c.a * smoothstep(0.10, 0.22, blue_lead) * not_green;
}

float caustic(vec2 p, float t) {
	vec2 i = p;
	float c = 1.0;
	float inten = 0.005;
	for (int n = 0; n < 4; n++) {
		float tt = t * (1.0 - (3.5 / float(n + 1)));
		i = p + vec2(cos(tt - i.x) + sin(tt + i.y), sin(tt - i.y) + cos(tt + i.x));
		c += 1.0 / length(vec2(p.x / (sin(i.x + tt) / inten), p.y / (cos(i.y + tt) / inten)));
	}
	c /= 4.0;
	c = 1.17 - pow(c, 1.4);
	return clamp(pow(abs(c), 5.0), 0.0, 1.0);
}

vec3 sample_water(vec2 uv, vec3 fallback) {
	vec4 c = texture(river_tex, uv);
	return mix(fallback, c.rgb, water_mask(c));
}

void fragment() {
	float t = TIME;
	vec4 orig = texture(river_tex, UV);
	float m = water_mask(orig);
	if (m <= 0.002) {
		discard;
	}
	// 1. 两相位流动：相位 A、B 错开半个周期，各自从 0 拖到 drag_len，权重三角波交替
	// 加一点按位置变化的相位偏移，别整条河同时「换相」
	float jitter = texture(noise_tex, UV * vec2(3.0, 6.0)).r;
	float ph = t / drag_cycle + jitter;
	float pa = fract(ph);
	float pb = fract(ph + 0.5);
	vec2 wobble = vec2(0.0, sin(UV.x * 60.0 + t * 1.7) * 0.0015);
	vec3 a = sample_water(UV - vec2(pa * drag_len, 0.0) + wobble, orig.rgb);
	vec3 b = sample_water(UV - vec2(pb * drag_len, 0.0) - wobble, orig.rgb);
	float wa = 1.0 - abs(pa * 2.0 - 1.0);
	vec3 col = mix(b, a, wa);
	// 2. 被拉长的白色流纹（横向很长、纵向很窄），往下游漂；两层速度不同
	float s1 = texture(noise_tex, vec2(UV.x * 1.4 - t * flow_speed, UV.y * 9.0)).r;
	float s2 = texture(noise_tex, vec2(UV.x * 2.3 - t * flow_speed * 1.6 + 0.4, UV.y * 14.0 + 0.3)).r;
	float streak = smoothstep(0.66, 0.82, s1) * 0.8 + smoothstep(0.7, 0.86, s2) * 0.6;
	col += vec3(0.85, 1.0, 1.0) * streak * streak_gain;
	// 3. 网状亮纹
	vec2 p = UV * caustic_scale;
	float c1 = caustic(p - vec2(t * flow_speed * caustic_scale.x, 0.0), t * 0.45);
	col += vec3(0.9, 1.0, 1.0) * c1 * caustic_gain;
	ALBEDO = col;
	ALPHA = m;
}
