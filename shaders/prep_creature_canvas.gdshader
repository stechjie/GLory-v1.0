shader_type spatial;
// 备战棋盘生物（凤凰等）贴地画布的材质（11.04）。
//
// 画布是 2D 离屏视口，透明底上画出来的颜色本来就是预乘的 → blend_premul_alpha。
// 提亮：备战 3D 场景用 Filmic 色调映射，会把亮部往下压、发灰（共鸣光球在战斗里亮，
// 一半是因为战斗场景是线性映射，亮度直接顶满）。这里只把**亮的部分**乘上去（> 1），
// 让核心冲到白热；暗边、轮廓保持原样，草地也不会被提亮（画布透明处 alpha = 0，不贡献颜色）。
render_mode unshaded, cull_disabled, depth_draw_never, blend_premul_alpha, shadows_disabled, fog_disabled;

uniform sampler2D canvas : source_color, filter_linear_mipmap;
// 全体的底倍数，和亮部额外加的倍数
// 11.04 美术统一：1.7 时大片冲白，和游戏柔和的手绘光不搭；只留核心发亮
uniform float boost = 1.0;
uniform float hot_boost = 0.75;

void fragment() {
	vec4 c = texture(canvas, UV);
	float lum = dot(c.rgb, vec3(0.299, 0.587, 0.114)) / max(c.a, 0.001);
	float k = boost + hot_boost * smoothstep(0.75, 0.98, lum);
	ALBEDO = c.rgb * k;
	ALPHA = c.a;
}
