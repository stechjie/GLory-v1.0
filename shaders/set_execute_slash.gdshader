shader_type spatial;
// 攻击套斩杀的一道斜劈刀光：沿 UV.x 从左往右划出（reveal），中间白金、外沿赤红、最外一圈深色描边，
// 两头收尖。blend_mix 不用加法：雪地白底上加法金光会被吃掉。
// depth_test_disabled：斩杀同一拍还有死亡碎裂和金币爆闪，不关深度测试刀光会被模型和爆闪盖住（10.31 截帧）。
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, blend_mix, fog_disabled, shadows_disabled;
uniform float reveal : hint_range(0.0, 1.0) = 1.0;
uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform vec4 core_color : source_color = vec4(1.0, 0.97, 0.84, 1.0);
uniform vec4 blade_color : source_color = vec4(0.95, 0.12, 0.05, 1.0);
uniform vec4 edge_color : source_color = vec4(0.22, 0.02, 0.0, 1.0);

void fragment() {
	// 刀身中线微弯，像一刀劈过的弧。
	float center = 0.5 + 0.10 * sin(UV.x * 3.14159);
	float taper = sin(clamp(UV.x, 0.0, 1.0) * 3.14159);
	float half_width = 0.40 * taper + 0.02;
	float d = abs(UV.y - center) / half_width;
	float core = 1.0 - smoothstep(0.0, 0.22, d);
	float blade = 1.0 - smoothstep(0.55, 0.90, d);
	float edge = smoothstep(0.75, 0.95, d) * (1.0 - smoothstep(0.95, 1.25, d));
	float cut = 1.0 - smoothstep(reveal - 0.06, reveal, UV.x);
	vec3 color = mix(blade_color.rgb, core_color.rgb, core);
	color = mix(color, edge_color.rgb, edge * (1.0 - blade));
	ALBEDO = color;
	ALPHA = clamp(max(blade, edge * 0.6), 0.0, 1.0) * cut * fade;
	if (ALPHA < 0.01) {
		discard;
	}
}
