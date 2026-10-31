shader_type spatial;
// 本路清场的三种立体光：shape 0 = 沿本路推进的竖直光幕，1 = 击杀点光柱，2 = 我方脚下金环。
// 用 blend_mix + 深色描边而不是纯加法：加法金光在雪地（白底）上会被吃掉。
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled, shadows_disabled;
uniform int shape = 0;
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform vec4 core_color : source_color = vec4(1.0, 0.97, 0.80, 1.0);
uniform vec4 glow_color : source_color = vec4(1.0, 0.62, 0.12, 1.0);
uniform vec4 edge_color : source_color = vec4(0.26, 0.10, 0.01, 1.0);

float bell(float value, float center, float width) {
	float d = (value - center) / width;
	return exp(-d * d);
}

void fragment() {
	vec3 color = glow_color.rgb;
	float alpha = 0.0;
	if (shape == 0) {
		// UV.y：0 在顶、1 贴地。贴地最亮，往上淡出；两侧收边。
		float side = smoothstep(0.0, 0.07, UV.x) * smoothstep(0.0, 0.07, 1.0 - UV.x);
		float body = pow(UV.y, 1.5);
		float core = bell(UV.y, 0.93, 0.07);
		float ground_line = bell(UV.y, 0.995, 0.02);
		color = mix(glow_color.rgb, core_color.rgb, core);
		color = mix(color, edge_color.rgb, ground_line * 0.8);
		alpha = side * max(body * 0.80, ground_line * 0.9);
	} else if (shape == 1) {
		float x = UV.x - 0.5;
		float core = bell(x, 0.0, 0.07);
		float glow = bell(x, 0.0, 0.22);
		float edge = bell(abs(x), 0.30, 0.05);
		float rise = smoothstep(0.0, 0.55, UV.y) * (1.0 - smoothstep(0.92, 1.0, UV.y) * 0.4);
		color = mix(glow_color.rgb, core_color.rgb, core);
		color = mix(color, edge_color.rgb, edge * (1.0 - glow));
		alpha = max(glow * 0.95, edge * 0.45) * rise;
	} else {
		float r = length(UV - 0.5) * 2.0;
		float ring = bell(r, 0.74, 0.09);
		float edge = bell(r, 0.90, 0.05);
		float inner = (1.0 - smoothstep(0.0, 0.70, r)) * 0.18;
		color = mix(glow_color.rgb, core_color.rgb, ring * 0.55);
		color = mix(color, edge_color.rgb, edge * (1.0 - ring));
		alpha = max(max(ring, edge * 0.55), inner);
	}
	ALBEDO = color;
	ALPHA = clamp(alpha, 0.0, 1.0) * fade;
	if (ALPHA < 0.01) {
		discard;
	}
}
