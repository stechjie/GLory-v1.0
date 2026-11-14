// BA 风格宠物身体着色：按 Blue Archive「MX/C-General/Layer4」无关键词基线像素程序
// （参考包 shaders/MX_C-General_Layer4/p4_blob_0084.asm.txt）逐项复现，参数名一一对应。
//
// ── 和原作一致（从反汇编实测）──
//  - _MaskTex.a 用 floor/ceil 硬选四层参数（<0.25 / 0.25~0.5 / 0.5~0.75 / >0.75），不是透明度。
//  - Mask G：gTerm = 1-2G，乘 _MaskGSensitivity 加进明暗判断（G>0.5 更容易进阴影）；B 是发光。
//  - 明暗判断 q = gTerm·sens + 0.77·N·V + N·L，阴影量 saturate((q - 阈值)·-10)：身体的过渡系数是 10。
//  - 视角光（_View*4）、逆视角光（_InvView*4）、底亮（_BaseBrightness4）、边缘光（_RimArea/Strength4，乘顶点 Alpha）。
//  - 背面走另一条：tex·_TwoSideTint·(0.33·N·L+0.5)·阴影色。
//  - 颜色类属性（_Tint/_TwoSideTint/_GlowTint）在 Unity Linear 工程里会先转线性 → 这里用 source_color；
//    _ShadowTintR4/G4/B4 是 Vector，原值使用 → 这里不加 source_color。
//
// ── 为本项目做的设计选择（不是原作）──
//  - 原作的 _MxCharLightDir/LightTone/ShadowTone/LightData 是运行时全局值，静态资源里拿不到。
//    这里用固定在视角空间的假光源 + 白色光色：菜单、营地、战斗不同灯光下宠物看起来一致（沿用 ba_toon 的做法）。
//  - 原作在顶点阶段加球谐环境光（上限 0.3）；这里默认 0，亮面就是贴图原色。
//  - 故意不写 ALPHA：主菜单宠物在 transparent_bg 的 SubViewport 里，写了 ALPHA 会进透明队列整只隐形。
//  - Mask 用 nearest 无 mipmap 采样：层选择不能在边界插值出中间层。
// 描边见 ba_pet_outline.gdshader（next_pass）。

shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

group_uniforms Textures;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);                    // _Tint
uniform sampler2D mask_texture : filter_nearest, repeat_enable;  // _MaskTex
uniform float mask_g_sensitivity = 1.0;                          // _MaskGSensitivity
uniform vec4 glow_tint : source_color = vec4(0.0, 0.0, 0.0, 1.0); // _GlowTint
uniform float glow_strength = 0.0;                               // _GlowStrength
uniform vec4 two_side_tint : source_color = vec4(1.0);           // _TwoSideTint
group_uniforms;

// 每个 vec4 的 x/y/z/w 分别是第 0/1/2/3 层（Mask A 选择）
group_uniforms Layers;
uniform vec4 shadow_threshold4 = vec4(0.15, 0.4, 0.4, 0.4);      // _ShadowThreshold4
uniform vec4 shadow_tint_r4 = vec4(0.94, 0.45, 0.62, 1.0);       // _ShadowTintR4
uniform vec4 shadow_tint_g4 = vec4(0.77, 0.38, 0.52, 1.0);       // _ShadowTintG4
uniform vec4 shadow_tint_b4 = vec4(0.76, 0.62, 0.48, 1.0);       // _ShadowTintB4
uniform vec4 base_brightness4 = vec4(0.0);                       // _BaseBrightness4
uniform vec4 view_offset4 = vec4(0.0, 0.5, -0.4, 0.0);           // _ViewOffset4
uniform vec4 view_power4 = vec4(1.0, 30.0, 30.0, 1.0);           // _ViewPower4
uniform vec4 view_strength4 = vec4(0.0, 0.2, 0.6, 0.0);          // _ViewStrength4
uniform vec4 inv_view_power4 = vec4(1.0);                        // _InvViewPower4
uniform vec4 inv_view_strength4 = vec4(0.0);                     // _InvViewStrength4
uniform vec4 view_light_edge4 = vec4(0.0, 0.25, 0.15, 0.0);      // _ViewLightEdge4
uniform vec4 rim_area4 = vec4(5.0);                              // _RimAreaMultiplier4
uniform vec4 rim_strength4 = vec4(1.0, 1.0, 1.0, 0.0);           // _RimStrength4
group_uniforms;

// 原作的运行时全局值的替代（设计选择，见文件头）
group_uniforms Light;
uniform vec3 light_dir_view = vec3(0.35, 0.76, 0.55);            // 替代 _MxCharLightDir（视角空间）
uniform vec4 light_tone : source_color = vec4(1.0);              // 替代 _MxCharLightTone
uniform vec4 shadow_tone : source_color = vec4(1.0);             // 替代 _MxCharShadowTone
uniform float light_intensity = 1.0;                             // 替代 _MxCharLightData.x
uniform float light_data_y = 1.0;                                // 替代 _MxCharLightData.y（阈值 +0.15·(1-y)）
uniform vec3 ambient = vec3(0.0);                                // 替代顶点阶段的球谐环境光
// 明暗用导入时算好的平滑法线（与描边方向同一份 TANGENT）。AI 生成的网格法线拆得很碎
// （猫：4513 个顶点只有 1554 个不同位置），直接用 NORMAL 明暗是一块一块的碎面。
// 原作的明暗用的是美术调过的法线；这是为本项目网格做的替代，关掉就回到原始法线。
uniform bool shade_with_smooth_normal = true;
group_uniforms;

varying vec3 smooth_normal;

void vertex() {
	smooth_normal = (MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz;
}

void fragment() {
	vec4 m = texture(mask_texture, UV);
	float g_term = 1.0 - 2.0 * m.g;
	float g_bias = g_term * mask_g_sensitivity;

	vec3 n = shade_with_smooth_normal ? normalize(smooth_normal) : normalize(NORMAL);
	if (!FRONT_FACING) {
		n = -n;
	}
	vec3 v = normalize(VIEW);
	vec3 l = normalize(light_dir_view);

	// 四层硬选择（与反汇编同一组 floor/ceil）
	vec3 a3 = vec3(m.a) - vec3(0.25, 0.5, 0.75);
	vec3 fl = floor(a3);
	vec3 ce = ceil(a3);
	vec4 w = vec4(-fl.x, -fl.y * ce.x, -fl.z * ce.y, ce.z);

	// 视角光
	vec3 dvo = normalize(l * dot(w, view_offset4) + v);
	float view_light = pow(clamp(dot(n, dvo), 0.0, 1.0), dot(w, view_power4));
	view_light = clamp(g_bias + view_light, 0.0, 1.0);
	float edge = dot(w, view_light_edge4);
	view_light = (1.0 - edge) * view_light + clamp((view_light - 0.5) * 10.0, 0.0, 1.0) * edge;

	float ndv = dot(n, v);
	float ndl = dot(n, l);

	// 逆视角光
	float inv_view = pow(clamp(1.0 - ndv, 0.0, 1.0), dot(w, inv_view_power4));
	inv_view = clamp(g_bias + inv_view, 0.0, 1.0);
	inv_view = (1.0 - edge) * inv_view + min(inv_view * 4000.0, 1.0) * edge;
	inv_view *= dot(w, inv_view_strength4);

	float add_light = view_light * dot(w, view_strength4) + inv_view + dot(w, base_brightness4);

	// 主明暗
	vec3 shadow_col = vec3(dot(w, shadow_tint_r4), dot(w, shadow_tint_g4), dot(w, shadow_tint_b4)) * shadow_tone.rgb;
	float q = g_bias + 0.77 * ndv + ndl;
	float threshold = dot(w, shadow_threshold4) + 0.15 * (1.0 - light_data_y);
	float shadow = clamp((q - threshold) * -10.0, 0.0, 1.0);
	vec3 light = mix(light_tone.rgb, shadow_col, shadow) * light_intensity + ambient;

	// 边缘光（乘顶点 Alpha）
	float rim_area = dot(w, rim_area4);
	float rim = clamp((1.0 - ndv) * rim_area - max(rim_area - 1.0, 0.0), 0.0, 1.0) * COLOR.a;
	rim *= dot(w, rim_strength4) * light_intensity;
	light += rim * (clamp(ndl * 4.0 + 0.25, 0.0, 1.0) * 0.4 + 0.3) * light_tone.rgb;
	light += add_light * light_tone.rgb;

	vec3 tex = (texture(albedo_texture, UV) * tint).rgb;
	vec3 col;
	if (FRONT_FACING) {
		col = light * tex + m.b * glow_strength * glow_tint.rgb;
	} else {
		col = tex * two_side_tint.rgb * (ndl * 0.33 + 0.5) * shadow_col;
	}
	ALBEDO = col;
}
