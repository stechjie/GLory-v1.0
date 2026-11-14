// BA 风格卡通着色（宠物先用）。数值规格参考 Blue Archive 材质参数的实测值，实现是自己写的。
//
// 和 pet_toon 的区别：
//  - 不吃场景灯光：用固定在「视角空间」的假光源（右上前方），菜单、营地、战斗任何灯光下看起来都一样，
//    也不会被不同场景的灯光强度（备战 0.64 / 预览 0.82 / 战斗 1.55）带偏。
//  - 半兰伯特 + 硬分界：0.5·N·L + 0.5 过阈值就是亮面，分界只留一点点抗锯齿。
//  - 阴影色是乘上去的颜色（不是压灰）：衣物偏冷灰紫，皮肤偏暖粉。
//  - 皮肤按贴图颜色自动识别（偏橙粉、中等饱和、够亮），皮肤几乎不进阴影 —— 脸始终是亮的。
//  - 边缘光只在受光面。
//  - 背面（如披风内侧）压暗。
//
// 和 pet_toon 一样故意不写 ALPHA：主菜单宠物在 transparent_bg 的 SubViewport 里，
// 写了 ALPHA 会进透明队列，整只隐形。
// 描边见 ba_outline.gdshader（作为 next_pass 挂上）。

shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

group_uniforms Albedo;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
group_uniforms;

group_uniforms Light;
// 视角空间里的假光源方向（x 右、y 上、z 朝镜头）。默认右上前方。
uniform vec3 light_dir_view = vec3(0.35, 0.76, 0.55);
// 半兰伯特阈值：BA 衣物/头发是 0.5。
uniform float shadow_threshold : hint_range(0.0, 1.0) = 0.5;
uniform float band_softness : hint_range(0.0, 0.1) = 0.015;
// 亮面整体亮度。1.0 = 贴图原色。
uniform float lit_brightness : hint_range(0.5, 1.5) = 1.0;
group_uniforms;

group_uniforms Shadow;
uniform vec4 shadow_tint : source_color = vec4(0.70, 0.72, 0.80, 1.0);
uniform bool skin_detect = true;
uniform vec4 skin_shadow_tint : source_color = vec4(0.94, 0.75, 0.73, 1.0);
// 皮肤往亮面推多少（加在半兰伯特值上）。
uniform float skin_lift : hint_range(0.0, 0.6) = 0.28;
uniform float backface_tint : hint_range(0.0, 1.0) = 0.42;
group_uniforms;

group_uniforms Rim;
uniform float rim_strength : hint_range(0.0, 1.0) = 0.28;
uniform float rim_start : hint_range(0.0, 1.0) = 0.62;
uniform float rim_end : hint_range(0.0, 1.0) = 0.78;
group_uniforms;

vec3 rgb_to_hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float skin_mask(vec3 srgb) {
	vec3 hsv = rgb_to_hsv(srgb);
	float h_ok = smoothstep(0.0, 0.01, hsv.x) * (1.0 - smoothstep(0.09, 0.12, hsv.x));
	float s_ok = smoothstep(0.08, 0.14, hsv.y) * (1.0 - smoothstep(0.55, 0.65, hsv.y));
	float v_ok = smoothstep(0.45, 0.6, hsv.z);
	return h_ok * s_ok * v_ok;
}

void fragment() {
	vec3 base = (texture(albedo_texture, UV) * albedo_color).rgb;
	// 故意不写 ALPHA（见文件头）。

	vec3 n = normalize(NORMAL);
	if (!FRONT_FACING) {
		n = -n;
	}
	float half_lambert = 0.5 * dot(n, normalize(light_dir_view)) + 0.5;

	vec3 shadow = shadow_tint.rgb;
	if (skin_detect) {
		// 阈值是在 Blender 预览里按线性颜色调出来的，这里同样用线性值判断
		float skin = skin_mask(clamp(base, 0.0, 1.0));
		shadow = mix(shadow, skin_shadow_tint.rgb, skin);
		half_lambert += skin * skin_lift;
	}
	float lit = smoothstep(shadow_threshold - band_softness, shadow_threshold + band_softness, half_lambert);
	vec3 col = mix(base * shadow, base * lit_brightness, lit);

	// 边缘光：越靠轮廓越亮，只在受光面，屏幕混合
	float facing = 1.0 - clamp(dot(n, normalize(VIEW)), 0.0, 1.0);
	float rim = smoothstep(rim_start, rim_end, facing) * lit * rim_strength;
	col = 1.0 - (1.0 - col) * (1.0 - rim);

	if (!FRONT_FACING) {
		col *= backface_tint;
	}
	ALBEDO = col;
}
