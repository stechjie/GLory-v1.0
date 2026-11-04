shader_type spatial;
// 备战棋子的套装「贴身光」（11.04）：叠在棋子模型每个网格上的 material_overlay，
// 按「越靠模型边缘越亮」（菲涅尔）画一圈贴着身形的光边 —— 与四星光环的 four_star_rim 同一思路。
//   mode 0 攻击：红色轮廓光，轻轻脉动（logo 4攻击 的红）
//   mode 1 控制：淡紫轮廓光（logo 4控制 的紫）
//   mode 2 金钱：淡金轮廓光 + 一道鎏金反光定时斜扫过全身；strength（= 金币加成）越高扫得越频、越亮
//   mode 3 元素：轮廓光在 火红 → 冰蓝 → 雷黄 → 毒绿 四色间轮转（logo 4元素 的四块），身上一道道往上流的能量纹
// 普通混合（不是加色）：备战草地亮，加色会被洗白。
render_mode unshaded, depth_draw_never, blend_mix, cull_back, shadows_disabled, fog_disabled;

uniform int mode = 0;
uniform vec4 c_main : source_color = vec4(0.95, 0.15, 0.12, 1.0);
uniform vec4 c_hot : source_color = vec4(1.0, 0.62, 0.52, 1.0);
uniform vec4 e_fire : source_color = vec4(1.0, 0.38, 0.10, 1.0);
uniform vec4 e_ice : source_color = vec4(0.35, 0.72, 1.0, 1.0);
uniform vec4 e_thunder : source_color = vec4(1.0, 0.88, 0.25, 1.0);
uniform vec4 e_poison : source_color = vec4(0.45, 0.95, 0.25, 1.0);
uniform float fade = 0.0;
uniform float strength = 1.0;
// 由脚本每帧给：棋子脚底的世界坐标、世界身高（扫光 / 流纹按身高归一）
uniform vec3 center_world = vec3(0.0);
uniform float height_world = 0.3;

vec3 elem_color(float phase) {
	// 每色停留大半拍，最后两成时间渐变到下一色
	float i = mod(floor(phase), 4.0);
	float f = smoothstep(0.7, 1.0, fract(phase));
	vec3 a = i < 0.5 ? e_fire.rgb : (i < 1.5 ? e_ice.rgb : (i < 2.5 ? e_thunder.rgb : e_poison.rgb));
	vec3 b = i < 0.5 ? e_ice.rgb : (i < 1.5 ? e_thunder.rgb : (i < 2.5 ? e_poison.rgb : e_fire.rgb));
	return mix(a, b, f);
}

void fragment() {
	// 指数 2.4：备战棋子很小，指数低时几乎整个模型都算「边缘」，被染成一片（实拍攻击套整只发粉）
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.4);
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = max(height_world, 0.0001);
	float hy = (world.y - center_world.y) / h;               // 0 = 脚底，1 = 头顶
	float hx = (world.x - center_world.x) / h;
	vec3 col = c_main.rgb;
	float a = 0.0;
	if (mode == 2) {
		// 鎏金：淡金边 + 一道斜着从脚扫到头的亮带
		col = mix(c_main.rgb, c_hot.rgb, fres);
		a = fres * 0.80;
		// 扫光：第一版 0.22~0.65 次/秒、带宽 0.09，实拍两帧都没拍到 —— 加快、加宽、加亮
		float rate = mix(0.45, 1.1, clamp(strength, 0.0, 1.0));
		float p = fract(TIME * rate) * 1.8 - 0.4;
		float t = hy * 0.85 + hx * 0.45;
		float band = exp(-pow((t - p) / 0.16, 2.0));
		col = mix(col, vec3(1.0, 0.97, 0.80), band);
		a = max(a, band * mix(0.60, 0.95, clamp(strength, 0.0, 1.0)));
	} else if (mode == 3) {
		vec3 ec = elem_color(TIME * 0.33);
		col = mix(ec, vec3(1.0), fres * 0.25);
		float flow = smoothstep(0.55, 1.0, sin(hy * 9.0 - TIME * 3.2 + hx * 4.0));
		// 元素套主体换成背后的四色水晶球，轮廓光只当呼应，压低
		a = fres * 0.55 + flow * 0.18 * (1.0 - fres * 0.5);
	} else {
		col = mix(c_main.rgb, c_hot.rgb, fres * fres);
		float pulse = mode == 0 ? (0.82 + 0.18 * sin(TIME * 3.0)) : 1.0;
		a = fres * 0.90 * pulse;
	}
	ALBEDO = col;
	ALPHA = clamp(a, 0.0, 0.95) * fade;
}
