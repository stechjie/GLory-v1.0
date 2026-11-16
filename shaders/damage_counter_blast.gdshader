shader_type canvas_item;
// 11.16 伤害牌常驻特效：垫在木牌后面，按档位加码（火星 → 火舌 → 间歇爆点 → 持续爆炸 + 冲击环 + 放射光）。
// 画风：扁平三色剪影（深棕边 / 主色 / 亮芯），火星画十字星；不做伪立体。全程不采样贴图。
// 坐标一律用设计像素（1600×720 下的 px）：p = UV * extent。木牌左上角在 plate_origin。
uniform float level = 0.0;            // 0..6（前 10 回合的 4 档按 ×1.5 映射）
uniform vec4 accent : source_color = vec4(1.0, 0.82, 0.29, 1.0);
uniform vec2 extent = vec2(344.0, 138.0);
uniform vec2 plate_origin = vec2(8.0, 50.0);
uniform float px = 1.0;               // 一个屏幕像素合多少设计像素（抗锯齿宽度）
uniform float motion = 1.0;           // 0 = 减少动效：只留静态火舌和暖光
uniform float simple = 0.0;           // 1 = 关闭闪光：不出爆炸 / 冲击环 / 放射光
uniform float lite = 0.0;             // 1 = 低画质：火星减半、不画放射光
uniform float punch = 1.0;            // 升档冲击进度 0→1；1 = 空闲
uniform float punch_power = 0.0;      // 升档力度 0..1（档位越高越大）

const vec3 DARK = vec3(0.23, 0.09, 0.03);
const vec3 HI = vec3(1.0, 0.90, 0.52);
const vec3 WHITE = vec3(1.0, 0.98, 0.88);

float hash(float n) { return fract(sin(n * 127.1) * 43758.5453); }
float hash2(vec2 v) { return fract(sin(dot(v, vec2(127.1, 311.7))) * 43758.5453); }

void over(inout vec4 dst, vec3 c, float a) {
	dst.rgb = dst.rgb * (1.0 - a) + c * a;
	dst.a = dst.a * (1.0 - a) + a;
}

float round_box(vec2 q, vec2 half_size, float r) {
	vec2 d = abs(q) - half_size + vec2(r);
	return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - r;
}

// 一排火舌：每条是上窄下宽、随高度摆动的水滴形。shrink < 1 得到套在里面的内层。
float tongues(vec2 p, float t, float base_y, float height, float shrink) {
	float rise = base_y - p.y;
	if (height <= 0.0 || rise > height || rise < -3.0) {
		return 0.0;
	}
	float w = 27.0;
	float xi = (p.x - plate_origin.x) / w;
	float cell = floor(xi);
	float m = 0.0;
	for (int j = -1; j <= 1; j++) {
		float id = cell + float(j);
		float cx = plate_origin.x + (id + 0.5) * w;
		float env = smoothstep(plate_origin.x + 14.0, plate_origin.x + 42.0, cx) * smoothstep(plate_origin.x + 272.0, plate_origin.x + 246.0, cx);
		float h = height * env * (0.50 + 0.50 * hash(id + 2.0))
			* (0.80 + 0.20 * sin(t * (3.2 + 2.4 * hash(id + 7.0)) + hash(id + 3.0) * TAU)) * shrink;
		if (h < 2.0) {
			continue;
		}
		float yn = clamp(rise / h, 0.0, 1.0);
		float sway = 0.20 * sin(t * 2.6 + id * 1.7 + yn * 2.6) * yn;
		float half_w = 0.64 * pow(1.0 - yn, 0.72) * mix(0.72, 1.0, shrink);
		float fx = xi - id - 0.5;
		float inside = smoothstep(0.0, px / w * 1.5, half_w - abs(fx - sway)) * step(rise, h);
		m = max(m, inside);
	}
	return m;
}

// 卡通爆点：带尖角的星形先弹出（带过冲），再从中心掏空散掉。返回 4 层的覆盖度。
vec4 burst(vec2 q, float ph, float radius, float seed) {
	float grow_t = min(ph / 0.34, 1.0);
	float grow = (1.0 - pow(1.0 - grow_t, 3.0)) * (1.0 + 0.20 * sin(grow_t * PI));
	float ang = atan(q.y, q.x);
	float spikes = 7.0 + floor(seed * 3.0);
	float rr = radius * grow * (1.0 + 0.30 * cos(ang * spikes + seed * TAU)) / 1.3;
	float len = length(q);
	float hole = radius * 1.15 * smoothstep(0.36, 1.0, ph);
	float open = smoothstep(hole - px, hole + px, len) * (1.0 - smoothstep(0.62, 1.0, ph));
	vec4 layers;
	layers.x = smoothstep(px, -px, len - rr) * open;
	layers.y = smoothstep(px, -px, len - rr * 0.80) * open;
	layers.z = smoothstep(px, -px, len - rr * 0.52) * open;
	layers.w = smoothstep(px, -px, len - rr * 0.26) * open;
	return layers;
}

void fragment() {
	vec2 p = UV * extent;
	float t = TIME * motion;
	float live = motion * (1.0 - simple);
	vec3 main_color = mix(vec3(1.0, 0.47, 0.10), accent.rgb, 0.40);
	vec4 acc = vec4(0.0);
	// 木牌主板（不含上面的小标题牌）在本矩形里的位置
	vec2 board_center = plate_origin + vec2(143.0, 52.0);
	vec2 board_half = vec2(137.0, 29.0);
	float sd = round_box(p - board_center, board_half, 14.0);
	float base_y = plate_origin.y + 30.0;
	float kick = (1.0 - punch) * punch_power;

	// 1) 放射光（满档）：从牌心向外的扇形条，慢转
	if (level >= 5.5 && lite < 0.5 && live > 0.5) {
		vec2 q = p - board_center;
		float stripe = abs(fract(atan(q.y, q.x) / TAU * 14.0 + t * 0.045) - 0.5) * 2.0;
		float ray = smoothstep(0.52, 0.70, stripe) * (1.0 - smoothstep(70.0, 185.0, length(q)));
		over(acc, HI, ray * 0.26);
	}

	// 2) 暖光：贴着牌边的一圈，随档位变宽变亮，慢呼吸
	if (level > 0.0) {
		float breathe = 0.84 + 0.16 * sin(t * (1.6 + 0.35 * level));
		float glow = exp(-max(sd, 0.0) / (5.0 + 2.6 * level)) * min(0.16 + 0.075 * level, 0.62) * breathe;
		over(acc, main_color, clamp(glow + kick * exp(-max(sd, 0.0) / 22.0) * 0.5, 0.0, 1.0));
	}

	// 3) 冲击环：满档每 1.3 秒一圈；升档时再来一圈更粗的
	if (live > 0.5) {
		if (level >= 5.5) {
			float ph = fract(t / 1.3);
			float ring = smoothstep(2.6, 0.6, abs(sd - ph * 44.0)) * (1.0 - ph);
			over(acc, HI, ring * 0.45);
		}
		if (punch < 0.999) {
			float e = 1.0 - pow(1.0 - punch, 3.0);
			float width = mix(4.0, 1.2, punch);
			float ring = smoothstep(width, width * 0.35, abs(sd - e * (26.0 + 22.0 * punch_power))) * (1.0 - punch);
			over(acc, HI, ring * (0.40 + 0.35 * punch_power));
		}
	}

	// 4) 火舌（第 3 档起），升档瞬间蹿高
	float height = level >= 2.5 ? (34.0 + 12.7 * (level - 3.0)) * (1.0 + 0.55 * kick) : 0.0;
	if (height > 0.0) {
		over(acc, DARK, tongues(p, t, base_y, height, 1.0) * 0.92);
		over(acc, main_color, tongues(p, t, base_y, height, 0.76));
		over(acc, HI, tongues(p, t, base_y, height, 0.48));
		if (level >= 5.5) {
			over(acc, WHITE, tongues(p, t, base_y, height, 0.24));
		}
	}

	// 5) 火星（第 1 档起）：十字星从牌顶飘起
	if (motion > 0.5 && level > 0.0) {
		float count = floor((3.0 + 1.5 * level) * mix(1.0, 0.5, lite));
		for (int k = 0; k < 12; k++) {
			float fk = float(k);
			if (fk >= count) {
				break;
			}
			float cyc = t * (0.55 + 0.45 * hash(fk + 11.0)) + hash(fk + 5.0);
			float n = floor(cyc);
			float ph = fract(cyc);
			vec2 c = vec2(plate_origin.x + 14.0 + hash2(vec2(n, fk)) * 258.0 + sin(ph * 5.0 + fk) * 6.0,
				base_y + 4.0 - ph * (34.0 + 6.0 * level));
			vec2 q = abs(p - c);
			float s = (3.6 + 2.6 * hash(fk + 23.0)) * (1.0 - 0.6 * ph);
			float star = min(q.x + q.y * 3.6, q.y + q.x * 3.6);
			over(acc, HI, smoothstep(s, s - px * 1.2, star) * (1.0 - ph * ph));
		}
	}

	// 6) 爆点：第 3 档起间歇（约 2 秒一次），第 5 档起持续（约 0.5 秒一次），满档更密（约 0.24 秒一次）
	if (live > 0.5 && level >= 2.5) {
		float slots = level >= 5.5 ? 5.0 : (level >= 4.5 ? 3.0 : 1.0);
		float period = level >= 5.5 ? 1.2 : (level >= 4.5 ? 1.5 : (level >= 3.5 ? 1.5 : 2.0));
		for (int k = 0; k < 5; k++) {
			float fk = float(k);
			if (fk >= slots) {
				break;
			}
			float cyc = t / period + fk / slots + 0.13 * fk;
			float n = floor(cyc);
			float ph = fract(cyc) * period / 0.70;
			if (ph >= 1.0) {
				continue;
			}
			float radius = (18.0 + 10.0 * hash2(vec2(n, fk + 40.0))) * (0.80 + 0.09 * level);
			float pick = hash2(vec2(n + 3.0, fk));
			float u = hash2(vec2(n + 9.0, fk + 17.0));
			float v = hash2(vec2(n + 21.0, fk + 31.0));
			vec2 c = pick < 0.72
				? vec2(mix(radius + 2.0, extent.x - radius - 26.0, u), mix(radius + 2.0, plate_origin.y + 12.0, v))
				: vec2(mix(plate_origin.x + 276.0, extent.x - radius - 2.0, u), mix(plate_origin.y + 22.0, plate_origin.y + 70.0, v));
			vec4 b = burst(p - c, ph, radius, hash2(vec2(n, fk + 55.0)));
			over(acc, DARK, b.x * 0.92);
			over(acc, main_color, b.y);
			over(acc, HI, b.z);
			if (level >= 4.5) {
				over(acc, WHITE, b.w);
			}
		}
	}

	// 7) 升档爆点：牌右上角一个大的
	if (live > 0.5 && punch < 0.999 && punch_power > 0.0) {
		float radius = 24.0 + 20.0 * punch_power;
		vec4 b = burst(p - (plate_origin + vec2(268.0, 18.0)), punch, radius, 0.37);
		over(acc, DARK, b.x * 0.92);
		over(acc, main_color, b.y);
		over(acc, HI, b.z);
		over(acc, WHITE, b.w);
	}

	// 矩形四边收一下，避免被硬切
	float edge = smoothstep(0.0, 5.0, p.x) * smoothstep(0.0, 5.0, p.y) * smoothstep(0.0, 5.0, extent.x - p.x) * smoothstep(0.0, 3.0, extent.y - p.y);
	COLOR = vec4(acc.rgb / max(acc.a, 0.0001), acc.a * edge);
}
