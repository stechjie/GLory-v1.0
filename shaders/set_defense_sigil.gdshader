shader_type spatial;
// 防卫套常驻盾纹：脚下一圈淡青金细环 + 六个盾形刻口，外侧垫一圈淡黑晕（雪地 / 草地亮底上才读得出）。
// 常驻元素，亮度刻意压低；pulse 让它每隔几秒轻轻亮一下，不抢战斗画面。
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled, shadows_disabled;
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
uniform vec4 ring_color : source_color = vec4(0.48, 0.92, 1.0, 1.0);
uniform vec4 notch_color : source_color = vec4(1.0, 0.86, 0.48, 1.0);
uniform vec4 shade_color : source_color = vec4(0.0, 0.05, 0.10, 1.0);

float bell(float value, float center, float width) {
	float d = (value - center) / width;
	return exp(-d * d);
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float angle = atan(p.y, p.x);
	float ring = bell(r, 0.80, 0.045);
	float inner = bell(r, 0.64, 0.025) * 0.55;
	// 六个刻口：每 60° 一个小菱形，压在外环上。
	float sector = mod(angle + 3.14159, 1.0471976) - 0.5235988;
	float notch = (1.0 - smoothstep(0.06, 0.12, abs(sector) + abs(r - 0.80) * 0.9)) ;
	float shade = bell(r, 0.86, 0.12) * 0.35;
	vec3 color = mix(ring_color.rgb, notch_color.rgb, clamp(notch, 0.0, 1.0));
	float bright = max(max(ring, inner), notch);
	color = mix(shade_color.rgb, color, clamp(bright * 2.0, 0.0, 1.0));
	float alpha = max(bright * (0.55 + 0.45 * pulse), shade);
	ALBEDO = color;
	ALPHA = clamp(alpha, 0.0, 0.9) * fade;
	if (ALPHA < 0.01) {
		discard;
	}
}
