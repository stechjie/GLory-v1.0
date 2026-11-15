// 「融进手绘场景」的统一受光层。由 effects/runtime/presentation/UnitSceneBlend.gd 接在
// 角色每个表面材质 next_pass 链上，同一份网格再画一遍，不改各单位自己的材质。
//
// 各单位材质来历不一（人族顶点色自发光、暗族 race_body、神族各写各的），对场景灯的反应
// 也不一样：白甲亮成一片、暗族糊成一团、明暗方向互相对不上。这一层不读灯，直接按
// 「视空间法线 · 固定光向」给所有单位叠同一套明暗：
//   背光面：压暗并掺一点冷紫（手绘场景里的阴影偏青紫，不是黑），白色单位因此有了体积；
//           以压暗为主：直接盖颜色会把本来就深的暗族 / 血族冲成灰色。
//   受光面：薄薄一层暖色，把纯白拉向奶油色；
//   受光侧轮廓：暖色边缘光，暗色单位靠它从草地上分出来。
// 预乘 alpha 混合：alpha 负责压暗，rgb 负责加亮，一遍画完。
//
// ⚠️ 混合发生在线性空间：加上去的 rgb 哪怕只有 0.045，落在深色上也相当于 sRGB 提亮 0.2 多，
// 第一版就是这样把暗族 / 血族整个冲灰的。所以加亮项（warm / rim / shade_tint）都要给得很小，
// warm 默认关掉；压暗（alpha）不受这个影响。

shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, shadows_disabled, blend_premul_alpha, fog_disabled;

// 光从屏幕左上、略朝镜头照过来（视空间：x 右、y 上、z 朝镜头）。
uniform vec3 light_dir_view = vec3(-0.58, 0.55, 0.60);
uniform vec4 shade_color : source_color = vec4(0.30, 0.26, 0.50, 1.0);
uniform float shade_strength : hint_range(0.0, 1.0) = 0.38;
// 暗部里掺多少 shade_color：0 = 纯压暗（不改色相），1 = 完全盖成 shade_color（会把深色单位冲灰）。
uniform float shade_tint : hint_range(0.0, 1.0) = 0.15;
uniform float band_center : hint_range(-1.0, 1.0) = 0.05;
// 11.15 用户要「日漫风」：明暗交界收成一条硬边（赛璐璐两段式），原来 0.16 是柔和过渡。
uniform float band_softness : hint_range(0.001, 1.0) = 0.035;
uniform vec4 warm_color : source_color = vec4(1.0, 0.86, 0.58, 1.0);
uniform float warm_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 rim_color : source_color = vec4(1.0, 0.90, 0.62, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.12;
uniform float rim_power : hint_range(0.5, 8.0) = 3.6;

void fragment() {
	vec3 n = normalize(NORMAL);
	float ndl = dot(n, normalize(light_dir_view));
	float lit = smoothstep(band_center - band_softness, band_center + band_softness, ndl);
	float shade_a = (1.0 - lit) * shade_strength;
	float warm_a = lit * warm_strength;
	float fresnel = pow(1.0 - clamp(dot(n, normalize(VIEW)), 0.0, 1.0), rim_power);
	float rim = fresnel * smoothstep(0.0, 0.6, ndl) * rim_strength;
	// 预乘：rgb 已经乘过各自的不透明度；边缘光只加不遮。
	ALBEDO = shade_color.rgb * shade_a * shade_tint + warm_color.rgb * warm_a + rim_color.rgb * rim;
	ALPHA = shade_a + warm_a;
}
