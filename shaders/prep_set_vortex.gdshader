shader_type spatial;
// 元素套：环绕棋子旋转的元素光带（11.04，Leno：「光柱要围着棋子模型环绕着转的感觉」）。
//
// 画在一个围住棋子的无盖圆筒上（宿主建 CylinderMesh）：筒壁上两条螺旋光带，边转边往上爬。
// 真 3D：光带转到棋子前面就挡在前面，转到后面被棋子挡住 —— 环绕感是真的；背面那半圈再压暗，纵深更强。
// 颜色 火 → 冰 → 雷 → 毒 轮换（logo 4元素），每种元素的光带样子不同：
//   火：带火苗边的波浪带；冰：带上一颗颗冰晶闪光；雷：锯齿形、频闪；毒：带上冒泡泡。
// 切换元素的瞬间整圈猛亮一下（ease-out 回落）。普通混合（亮草地上加色会被洗白）。
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

uniform float fade = 0.0;
uniform float strength = 1.0;

vec3 elem_col(int i) {
	int k = i - (i / 4) * 4;
	if (k == 0) { return vec3(1.0, 0.30, 0.05); }      // 火
	if (k == 1) { return vec3(0.25, 0.65, 1.0); }      // 冰
	if (k == 2) { return vec3(1.0, 0.85, 0.12); }      // 雷
	return vec3(0.35, 0.95, 0.20);                     // 毒
}

void fragment() {
	float ph = TIME * 0.45;
	int idx = int(mod(floor(ph), 4.0));
	float t = fract(ph);
	vec3 ec = mix(elem_col(idx), elem_col(idx + 1), smoothstep(0.86, 1.0, t));
	float burst = 1.0 - smoothstep(0.0, 0.25, t);
	float u = UV.x;                         // 绕圆筒一圈 0 ~ 1
	float h = 1.0 - UV.y;                   // 0 = 脚底，1 = 筒顶
	// 两条螺旋：绕一圈的同时往上爬；整体旋转 + 往上流
	float s = u * 2.0 + h * 1.6 - TIME * 0.85;
	if (idx == 2) {
		// 雷：锯齿形，每 1/8 秒换一次折法
		s += 0.06 * (abs(fract(h * 7.0 + floor(TIME * 8.0) * 0.37) * 2.0 - 1.0) * 2.0 - 1.0);
	}
	float d = abs(fract(s) - 0.5);          // 0 = 光带中线
	float w = 0.17;                         // 第一版 0.11：小棋子身上只剩一根细线，看不出光带
	if (idx == 0) {
		// 火：带边一跳一跳的火苗
		w += 0.045 * sin(h * 34.0 - TIME * 11.0 + u * 6.2831853 * 2.0) * smoothstep(0.1, 0.6, h);
	}
	float ribbon = 1.0 - smoothstep(w * 0.55, w, d);
	float core = pow(1.0 - clamp(d / w, 0.0, 1.0), 3.0);
	// 切面明暗：朝光（左上）那侧的筒壁亮、背光那侧暗；背面那半圈再压暗
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float lit = 0.55 + 0.45 * dot(normalize(wn.xz), normalize(vec2(-0.6, -0.8)));
	vec3 col = mix(ec * mix(0.55, 1.0, lit), vec3(1.0), core * 0.55);
	float a = ribbon * (FRONT_FACING ? 0.92 : 0.40);
	// 每种元素的点缀
	float deco = 0.0;
	if (idx == 1) {
		// 冰：光带上一颗颗冰晶闪光（菱形），轮流亮
		vec2 g = vec2(fract(u * 10.0), fract(h * 6.0 - TIME * 0.6)) - 0.5;
		float dd = abs(g.x) / 0.18 + abs(g.y) / 0.32;
		deco = (1.0 - smoothstep(0.8, 1.0, dd)) * ribbon * (0.5 + 0.5 * sin(TIME * 6.0 + floor(u * 10.0) * 2.3));
	} else if (idx == 3) {
		// 毒：光带上冒泡（小圆环往上走）
		vec2 g = vec2(fract(u * 9.0), fract(h * 5.0 - TIME * 0.9)) - 0.5;
		float rr = length(g * vec2(1.0, 0.7));
		deco = (1.0 - smoothstep(0.03, 0.08, abs(rr - 0.20))) * ribbon;
	} else if (idx == 2) {
		// 雷：频闪
		a *= 0.55 + 0.45 * step(0.3, fract(TIME * 7.0));
	}
	col = mix(col, vec3(1.0), deco * 0.85);
	a = max(a, deco * 0.9);
	// 筒壁一层很淡的元素色光，让光带之间不是空的
	a = max(a, 0.13 * (FRONT_FACING ? 1.0 : 0.5));
	// 上下两头淡出；切换瞬间整圈猛亮
	float vfade = smoothstep(0.0, 0.08, h) * (1.0 - smoothstep(0.78, 1.0, h));
	a *= vfade * (1.0 + 0.5 * burst);
	ALBEDO = col;
	ALPHA = clamp(a, 0.0, 0.95) * fade * strength;
}
