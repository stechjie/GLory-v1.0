shader_type spatial;
// 宝藏套装常驻脚下纹。最早只给防卫套（战斗里的盾纹），11.04 起备战界面五个套装共用：
// 一圈淡色细环 + 按 pattern 换的刻口，外侧垫一圈淡黑晕（雪地 / 草地亮底上才读得出）。
// 常驻元素，亮度刻意压低；pulse 让它每隔几秒轻轻亮一下，不抢画面。
//   pattern 0 = 防卫 · 六个盾形菱口（默认值，战斗盾纹不传这个参数，外观不变）
//   pattern 1 = 攻击 · 四道朝外的刀刃
//   pattern 2 = 控制 · 十二刻度 + 一根转动的指针
//   pattern 3 = 金钱 · 八枚方孔铜钱
//   pattern 4 = 元素 · 三枚火苗形，分别用 notch / elem_b / elem_c 三色
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled, shadows_disabled;
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
uniform vec4 ring_color : source_color = vec4(0.48, 0.92, 1.0, 1.0);
uniform vec4 notch_color : source_color = vec4(1.0, 0.86, 0.48, 1.0);
uniform vec4 shade_color : source_color = vec4(0.0, 0.05, 0.10, 1.0);
uniform int pattern = 0;
uniform vec4 elem_b : source_color = vec4(0.55, 0.85, 1.0, 1.0);
uniform vec4 elem_c : source_color = vec4(1.0, 0.92, 0.35, 1.0);
// 控制套指针的角速度（弧度 / 秒）。整片还会随 SetDefenseSigil3D 慢转，两者叠加。
uniform float hand_speed = 1.6;
// 注意：PI 是 Godot shader 内置常量，不能再 const 一次（会整块编译失败，战斗盾纹也跟着没了）。

float bell(float value, float center, float width) {
	float d = (value - center) / width;
	return exp(-d * d);
}

// 把角度切成 count 份，返回在本份里的偏移（弧度，-半份 ~ +半份）。
float sector_of(float angle, float count) {
	float span = 2.0 * PI / count;
	return mod(angle + PI, span) - span * 0.5;
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float angle = atan(p.y, p.x);
	float ring = bell(r, 0.80, 0.045);
	float inner = bell(r, 0.64, 0.025) * 0.55;
	float notch = 0.0;
	vec3 notch_rgb = notch_color.rgb;
	if (pattern == 1) {
		// 刀刃：从内环往外逐渐收尖，四道。
		float s = sector_of(angle + PI * 0.25, 4.0);
		float t = clamp((r - 0.52) / 0.46, 0.0, 1.0);
		float half_w = 0.11 * (1.0 - t);
		notch = (1.0 - smoothstep(half_w * 0.55, half_w + 0.004, abs(s) * r)) * step(0.52, r) * step(r, 0.98);
	} else if (pattern == 2) {
		// 刻度：每 30° 一根，每 90° 的长一点；再加一根从中心伸出的指针。
		float s = sector_of(angle, 12.0);
		float idx = floor((angle + PI) / (PI / 6.0) + 0.5);
		bool major = mod(idx, 3.0) < 0.5;
		float lo = major ? 0.58 : 0.66;
		float tick = (1.0 - smoothstep(0.014, 0.028, abs(s) * r)) * step(lo, r) * step(r, 0.76);
		float ha = TIME * hand_speed;
		vec2 dir = vec2(cos(ha), sin(ha));
		float along = dot(p, dir);
		float across = abs(dot(p, vec2(-dir.y, dir.x)));
		float hand = (1.0 - smoothstep(0.018, 0.034, across)) * step(0.05, along) * step(along, 0.56);
		notch = max(tick, hand);
	} else if (pattern == 3) {
		// 方孔铜钱：外圆实心，中间挖一个方孔。
		float s = sector_of(angle, 8.0);
		vec2 local = vec2(r - 0.80, s * 0.80);
		float coin = 1.0 - smoothstep(0.075, 0.095, length(local));
		float hole = 1.0 - smoothstep(0.022, 0.032, max(abs(local.x), abs(local.y)));
		notch = coin * (1.0 - hole);
	} else if (pattern == 4) {
		// 三枚火苗形（往外的一头尖），每枚一个颜色：炎 / 冰 / 雷。
		float s = sector_of(angle, 3.0);
		vec2 local = vec2(r - 0.80, s * 0.80);
		float taper = 1.0 + clamp(local.x / 0.12, 0.0, 1.0) * 1.6;
		// 实拍里 0.07 半径太小，三种颜色认不出来，放大到 0.11。
		notch = 1.0 - smoothstep(0.105, 0.135, length(vec2(local.x * 0.85, local.y * taper)));
		float idx = mod(floor((angle + PI) / (2.0 * PI / 3.0) + 0.5), 3.0);
		notch_rgb = idx < 0.5 ? notch_color.rgb : (idx < 1.5 ? elem_b.rgb : elem_c.rgb);
	} else {
		// 六个刻口：每 60° 一个小菱形，压在外环上。
		float sector = mod(angle + 3.14159, 1.0471976) - 0.5235988;
		notch = (1.0 - smoothstep(0.06, 0.12, abs(sector) + abs(r - 0.80) * 0.9));
	}
	float shade = bell(r, 0.86, 0.12) * 0.35;
	vec3 color = mix(ring_color.rgb, notch_rgb, clamp(notch, 0.0, 1.0));
	float bright = max(max(ring, inner), notch);
	color = mix(shade_color.rgb, color, clamp(bright * 2.0, 0.0, 1.0));
	float alpha = max(bright * (0.55 + 0.45 * pulse), shade);
	ALBEDO = color;
	ALPHA = clamp(alpha, 0.0, 0.9) * fade;
	if (ALPHA < 0.01) {
		discard;
	}
}
