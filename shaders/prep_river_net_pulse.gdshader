shader_type spatial;
// 下河面的「原地流光」（11.16，夜荧光皮肤）。
//
// 旧的流光层（assets/shaders/prep_river_flow.gdshader）是把整张河面图横着滑两份再叠回去。
// 夜荧光这张图水面上本来就画了一张发光的网，岸边还有水晶、蘑菇、花 —— 一滑，
// 装饰物的亮斑拖着重影漂过水面，网上又叠两张错位的网，看着就是乱闪，看不出往哪流。
//
// 这里图一动不动，只做三件事：
//   1. 只认水面上那张网（见 net_mask），装饰物和石头不发光；
//   2. 一道道明暗波往下游走，波经过的网线亮起来 —— 光顺着网流过去，流向一眼看得出；
//   3. 网的交点各自偶尔闪一下。
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, specular_disabled;

// 不加 source_color：下面的判据是照图上的原始色值量的。
uniform sampler2D river_tex : filter_linear_mipmap;
uniform float flow_speed = 0.06;       // 光波往下游走多快（UV/秒，正 = 往右）
uniform float wave_count = 5.0;        // 一屏宽同时有几道主波
uniform float glow_gain = 0.9;         // 光波经过时网线提亮多少
uniform float sheen_gain = 0.07;       // 光波经过时整片水面跟着亮一点（很淡，让波本身看得见）
uniform float twinkle_gain = 0.7;      // 交点闪烁强度
uniform float wobble = 0.0006;         // 亮线轻微晃动（UV，约 1 像素），给点水感
uniform vec3 glow_color : source_color = vec3(1.0, 0.96, 1.0);
// 网线亮度判据：这张图蓝色几乎处处顶到 1.0，分不出亮暗；红绿里较小的那个才是「有多白」：
// 水体约 0.2，淡网线 0.35～0.5，交点接近 1.0。
uniform float line_lo = 0.24;
uniform float line_hi = 0.50;
// 水面从图高多少开始（往上是岸边的石头和花）；左右两端留给角上的水晶和蘑菇。
// 网线「红绿接近」的容差：差得比 hi 多就不算网线（夜荧光的花偏粉、水晶偏青；樱花的花更粉，要卡紧）
uniform float neutral_lo = 0.16;
uniform float neutral_hi = 0.30;
// 蓝至少比红高多少才算水上的东西（樱花：漂着的花和石头高光是红比蓝高，用它排除；-1 = 不查）
uniform float cool_min = -1.0;
// 交点（最白的芯）的判据
uniform float node_lo = 0.80;
uniform float node_hi = 0.97;
uniform float shore_v = 0.815;
uniform float side_fade = 0.15;
// 以下几样给浅色水面用（樱花）：白网在浅水上再提亮也看不出来，要靠在动的东西让人看出水在流。
// 水体判据：蓝至少比红高 body_cool（漂着的花、石头高光是红比蓝高），且不暗于 body_dark（石头）。
uniform float use_body = 0.0;          // 1 = 流纹 / 水面亮带 / 漂花按水体判据画，不按网线那套
uniform float body_cool = 0.0;
uniform float body_dark = 0.5;
uniform float streak_gain = 0.0;       // 顺流漂的白色细流纹（0 = 不画）
uniform int petal_count = 0;           // 水面上顺流漂的花瓣数（最多 8；0 = 不画）

// 省着画：这块面片和整张棋盘一样大，但水只占最下面那一条。把上边两个顶点直接拉到水线上，
// 片元着色器就只在河那一条上跑（约整块的 1/5），不用每个像素先采样再丢掉。
void vertex() {
	if (UV.y < 0.5) {
		VERTEX.z *= 1.0 - 2.0 * shore_v;
		UV.y = shore_v;
	}
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	float t = TIME;
	vec2 uv = UV + vec2(0.0, sin(UV.x * 70.0 + t * 1.3) * wobble);
	vec4 c = texture(river_tex, uv);
	float white = min(c.r, c.g);
	float line = smoothstep(line_lo, line_hi, white);
	// 网线是白里带一点紫（红绿接近）；花偏粉（红远大于绿）、水晶偏青（绿远大于红），排除掉。
	float neutral = 1.0 - smoothstep(neutral_lo, neutral_hi, abs(c.r - c.g));
	neutral *= smoothstep(cool_min, cool_min + 0.05, c.b - c.r);
	float shore = smoothstep(shore_v, shore_v + 0.055, UV.y);
	float side = smoothstep(0.03, side_fade, UV.x) * smoothstep(0.97, 1.0 - side_fade, UV.x);
	float water = c.a * neutral * shore * side;
	float m = water * line;
	float body = c.a * shore * side * smoothstep(body_cool, body_cool + 0.05, c.b - c.r)
		* smoothstep(body_dark, body_dark + 0.08, white);
	float surface = mix(water, body, use_body);
	if (max(water, surface) <= 0.003) {
		discard;
	}
	// 两道不同疏密、不同速度的波；波前按位置弯一点，别像一把直尺扫过去。
	float bend = sin(UV.y * 38.0 + UV.x * 4.0) * 0.06 + sin(UV.x * 13.0 - UV.y * 20.0) * 0.03;
	float p1 = (UV.x + bend) * wave_count - t * flow_speed * wave_count;
	float p2 = (UV.x - bend) * wave_count * 1.7 - t * flow_speed * wave_count * 2.3 + 0.3;
	// 幂次用连乘（手机上 pow 贵）
	float s1 = 0.5 + 0.5 * sin(p1 * TAU);
	float s2 = 0.5 + 0.5 * sin(p2 * TAU);
	s2 *= s2;
	float w1 = s1 * s1 * s1;
	float w2 = s2 * s2 * 0.55;
	float pulse = max(w1, w2);
	// 交点（最白的芯）各闪各的
	float node = smoothstep(node_lo, node_hi, white);
	float rnd = hash(floor(UV * vec2(20.0, 20.0)));
	float tw = max(0.0, sin(t * (1.1 + rnd * 1.4) + rnd * 40.0));
	float tw2 = tw * tw;
	float tw4 = tw2 * tw2;
	tw = tw4 * tw4 * tw2;
	float glow_a = clamp(m * (pulse * glow_gain + node * tw * twinkle_gain) + surface * pulse * sheen_gain, 0.0, 1.0);
	// 顺流漂的细流纹：横向拉得很长、纵向很窄的噪声，两层不同速度往下游走
	if (streak_gain > 0.0) {
		float n1 = vnoise(vec2(UV.x * 5.0 - t * flow_speed * 8.0, UV.y * 70.0));
		float n2 = vnoise(vec2(UV.x * 8.0 - t * flow_speed * 19.0 + 3.1, UV.y * 110.0 + 1.7));
		float streak = smoothstep(0.62, 0.80, n1) * 0.8 + smoothstep(0.68, 0.85, n2) * 0.6;
		glow_a = clamp(glow_a + surface * streak * streak_gain, 0.0, 1.0);
	}
	// 叠色用预乘：先是上面的光，再往上盖漂花的倒影、涟漪和花瓣
	vec3 acc = glow_color * glow_a;
	float acc_a = glow_a;
	// 漂花只让路给画在河里的花和石头（红明显比蓝高 / 暗），网线和粉色水面照样盖过去，
	// 不然花瓣漂到网线上会被咬掉一口
	float clear_water = c.a * shore * side * smoothstep(-0.08, -0.03, c.b - c.r) * smoothstep(0.45, 0.53, white);
	for (int i = 0; i < 8; i++) {
		if (i >= petal_count) {
			break;
		}
		float seed = float(i) * 1.37 + 0.5;
		float lane = mix(shore_v + 0.065, 0.985, hash(vec2(seed, 1.0)));
		float speed = flow_speed * (0.45 + 0.4 * hash(vec2(seed, 2.0)));
		float x = fract(hash(vec2(seed, 5.0)) + t * speed / 1.2) * 1.2 - 0.1;
		vec2 center = vec2(x, lane + sin(t * 0.6 + seed * 3.0) * 0.003);
		// 换成地面上的真实长度（面片 8 × 4.5），圆才是圆；透视由相机自己压扁 —— 所以看着是贴在水面上的
		vec2 d = (UV - center) * vec2(8.0, 4.5);
		float dist = length(d);
		if (dist > 0.40) {
			continue;
		}
		float ends = smoothstep(-0.1, 0.0, x) * smoothstep(1.1, 1.0, x) * clear_water;
		// 涟漪（11.16 返工：原来是两圈一直在扩的硬白环，像雷达）。现在：
		//   · 圈不是正圆：半径按方向起伏一点，还会慢慢变；
		//   · 边是软的，越往外越宽越淡；亮圈里侧贴一道很淡的暗纹（水波有峰有谷）；
		//   · 有起有落：每朵花的涟漪强弱各自慢慢变，不是每一圈都一样亮；第二圈更淡。
		float around = atan(d.y, d.x);
		float wobble_r = dist * (1.0 + 0.07 * sin(around * 3.0 + seed * 7.0 + t * 0.4)
			+ 0.04 * sin(around * 5.0 - seed * 3.0 - t * 0.3));
		float swell = 0.45 + 0.55 * sin(t * 0.23 + seed * 5.0) * sin(t * 0.23 + seed * 5.0);
		float crest = 0.0;
		float trough = 0.0;
		for (int k = 0; k < 2; k++) {
			float ph = fract(t * 0.2 + seed + float(k) * 0.5);
			float width = 0.007 + 0.020 * ph;
			float dr = wobble_r - (0.055 + 0.24 * ph);
			float fade = smoothstep(0.0, 0.12, ph) * (1.0 - ph) * (1.0 - ph) * (k == 0 ? 1.0 : 0.55);
			float soft = 1.0 - smoothstep(0.0, width, abs(dr));
			crest += soft * soft * fade;
			float inner = 1.0 - smoothstep(0.0, width, abs(dr + width * 1.5));
			trough += inner * inner * fade;
		}
		float trough_a = clamp(trough * 0.16 * swell, 0.0, 1.0) * ends;
		acc = mix(acc, vec3(0.133, 0.093, 0.349), trough_a);
		acc_a = trough_a + acc_a * (1.0 - trough_a);
		float ring_a = clamp(crest * 0.34 * swell, 0.0, 1.0) * ends;
		acc = mix(acc, vec3(1.0), ring_a);
		acc_a = ring_a + acc_a * (1.0 - ring_a);
		// 花瓣慢慢自转；水下一块偏深的倒影（往下游、往近处错开一点）
		float ang = seed * 2.0 + t * 0.2;
		vec2 rd = vec2(d.x * cos(ang) - d.y * sin(ang), d.x * sin(ang) + d.y * cos(ang));
		// 单数是一片花瓣（椭圆），双数是一整朵五瓣的小花（和河里画的那些一个样子，带黄花心）
		bool blossom = (i % 2) == 0;
		vec2 ext = blossom ? vec2(0.095, 0.095) : vec2(0.075, 0.046);
		float lobes = blossom ? 0.74 + 0.26 * abs(cos(2.5 * (around + ang))) : 1.0;
		// 倒影不跟着花转：固定往近处、往下游错开一点
		float shadow_a = (1.0 - smoothstep(0.55, 1.3, length((d - vec2(0.014, 0.026)) / (ext * 1.15)))) * 0.38 * ends;
		acc = mix(acc, vec3(0.133, 0.093, 0.349), shadow_a);
		acc_a = shadow_a + acc_a * (1.0 - shadow_a);
		float e = length(rd / ext) / lobes;
		float petal_a = (1.0 - smoothstep(0.90, 1.0, e)) * ends;
		// 花心粉白 → 瓣尖粉 → 一圈深粉的边（和画的花一样有描边，才不像一块白斑）
		vec3 pc = mix(vec3(1.0, 0.88, 0.92), vec3(0.99, 0.62, 0.76), smoothstep(0.15, 0.8, e));
		pc = mix(pc, vec3(0.86, 0.40, 0.58), smoothstep(0.78, 0.95, e));
		if (blossom) {
			pc = mix(vec3(1.0, 0.80, 0.40), pc, smoothstep(0.12, 0.22, e));
		}
		// 这里写的是屏幕上看到的颜色，ALBEDO 要线性值，换算一下（不换会发白）
		acc = mix(acc, pow(pc, vec3(2.2)), petal_a);
		acc_a = petal_a + acc_a * (1.0 - petal_a);
	}
	ALBEDO = acc_a > 0.001 ? acc / acc_a : glow_color;
	ALPHA = acc_a;
}
