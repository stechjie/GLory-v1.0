// 角色 toon 材质 B 版候选，只给 scenes/debug/CharacterLookAB 试验用，生产不引用。
//
// 以 res://shaders/character_toon.gdshader 为底整份复制，两段明暗、阴影底色、
// 受光侧 rim、高光的算法和参数一字不改；只多一组「侧光」。
// side_light_strength = 0 时输出与 A 版逐像素一致，方便确认差异只来自新增项。
//
// 为什么要侧光：现有 rim 乘了 band，只亮受光一侧。战斗只有一盏暖色主光
// （BattleArena 1.55），背光那半边轮廓全落在阴影底色里，小尺寸棋子容易糊成一团。
// 侧光按视线算，不依赖灯，写进 EMISSION——每像素算一次，不进 light() 的灯循环，
// 备战主光 + 补光两盏灯也不会叠两次。
//
// 两种做法对照：
//   程序版（默认）：0 次额外采样，Fresnel 环带 + 屏幕方向偏置 + 硬边。
//   贴图版（use_side_matcap）：多 1 次采样，读一张原创小图的亮度，形状可以手画。
// 都乘回底色一部分，避免变成一圈塑料感的纯色描边、盖掉手绘色块。

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, ambient_light_disabled;

group_uniforms Albedo;
uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
group_uniforms;

group_uniforms Cel;
uniform vec4 shadow_tint : source_color = vec4(0.42, 0.47, 0.56, 1.0);
uniform float light_threshold : hint_range(0.0, 1.0) = 0.40;
uniform float band_softness : hint_range(0.0, 0.25) = 0.02;
uniform float light_energy : hint_range(0.0, 3.0) = 1.0;
uniform float light_response : hint_range(0.1, 4.0) = 1.5;
group_uniforms;

group_uniforms Rim;
uniform vec4 rim_color : source_color = vec4(0.85, 0.95, 1.0, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.12;
uniform float rim_power : hint_range(0.5, 8.0) = 3.0;
uniform float rim_threshold : hint_range(0.0, 1.0) = 0.55;
group_uniforms;

group_uniforms Specular;
uniform vec4 specular_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float specular_amount : hint_range(0.0, 2.0) = 0.0;
uniform float specular_gloss : hint_range(0.0, 1.0) = 0.7;
uniform float specular_threshold : hint_range(0.0, 1.0) = 0.5;
group_uniforms;

group_uniforms NormalMap;
uniform bool use_normal_map = false;
uniform sampler2D normal_map_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float normal_map_depth : hint_range(-2.0, 2.0) = 0.45;
group_uniforms;

group_uniforms Emission;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy : hint_range(0.0, 8.0) = 0.0;
uniform sampler2D emission_mask : hint_default_white, filter_linear_mipmap, repeat_enable;
group_uniforms;

group_uniforms SideLight;
// 0 = 关闭，与 A 版完全一致。
uniform float side_light_strength : hint_range(0.0, 1.5) = 0.0;
// 偏冷，和暖色主光拉开色温，背光侧读得出体积。
uniform vec4 side_light_color : source_color = vec4(0.62, 0.78, 1.0, 1.0);
// 0 = 纯色加光；1 = 完全乘底色（只把原色提亮）。中间值保留手绘色相。
uniform float side_light_albedo_mix : hint_range(0.0, 1.0) = 0.55;
// 环带位置与宽度：Fresnel 超过阈值才亮，边缘仍是 toon 的硬边。
uniform float side_light_threshold : hint_range(0.0, 1.0) = 0.62;
uniform float side_light_power : hint_range(0.5, 6.0) = 2.0;
// 屏幕空间里侧光来自哪边（视图空间 xy，会被归一化）。默认左上，
// 和战斗主光（rotation -55, 35，从右侧打）相对，正好补到背光那半边。
uniform vec2 side_light_direction = vec2(-0.75, 0.45);
// 方向偏置强度：0 = 整圈均匀，1 = 只亮朝向 side_light_direction 的那半圈。
uniform float side_light_directional : hint_range(0.0, 1.0) = 0.7;
// 贴图版开关：用原创 MatCap 小图的亮度代替程序曲线，多 1 次采样。
uniform bool use_side_matcap = false;
uniform sampler2D side_matcap : hint_default_black, filter_linear, repeat_disable;
group_uniforms;

group_uniforms Tiling;
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform vec2 uv_offset = vec2(0.0, 0.0);
group_uniforms;

void vertex() {
	UV = UV * uv_scale + uv_offset;
}

float side_light_mask(vec3 normal, vec3 view_dir) {
	if (use_side_matcap) {
		// 视图空间法线映射到贴图坐标；贴图上方 = 屏幕上方，所以翻 y。
		vec2 matcap_uv = normal.xy * vec2(0.5, -0.5) + vec2(0.5);
		return texture(side_matcap, matcap_uv).r;
	}
	float fresnel = pow(1.0 - clamp(dot(normal, view_dir), 0.0, 1.0), side_light_power);
	float facing = dot(normalize(normal.xy + vec2(0.0001)), normalize(side_light_direction));
	float bias = mix(1.0, smoothstep(-0.1, 0.6, facing), side_light_directional);
	return smoothstep(
			side_light_threshold - band_softness,
			side_light_threshold + band_softness,
			fresnel * bias);
}

void fragment() {
	vec4 base = texture(albedo_texture, UV) * albedo_color;
	ALBEDO = base.rgb;
	// 角色本体不透明；碰 ALPHA 会整体进透明队列，A 版同理不写。
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;

	if (use_normal_map) {
		NORMAL_MAP = texture(normal_map_texture, UV).rgb;
		NORMAL_MAP_DEPTH = normal_map_depth;
	}

	EMISSION = ALBEDO * shadow_tint.rgb
			+ emission_color.rgb * emission_energy * texture(emission_mask, UV).rgb;

	if (side_light_strength > 0.0) {
		vec3 tint = mix(side_light_color.rgb, ALBEDO * side_light_color.rgb * 2.0, side_light_albedo_mix);
		EMISSION += tint * side_light_mask(normalize(NORMAL), normalize(VIEW)) * side_light_strength;
	}
}

void light() {
	vec3 normal = normalize(NORMAL);
	vec3 light_dir = normalize(LIGHT);
	vec3 view_dir = normalize(VIEW);

	float peak = max(LIGHT_COLOR.r, max(LIGHT_COLOR.g, LIGHT_COLOR.b));
	vec3 light_tint = (LIGHT_COLOR / max(peak, 0.0001))
			* clamp(peak * light_response, 0.0, 1.0);

	float ndotl = max(dot(normal, light_dir), 0.0) * ATTENUATION;
	float band = smoothstep(
			light_threshold - band_softness,
			light_threshold + band_softness,
			ndotl);

	float shadow_level = dot(shadow_tint.rgb, vec3(0.2126, 0.7152, 0.0722));
	DIFFUSE_LIGHT += ALBEDO * light_tint * band * light_energy
			* (1.0 - clamp(shadow_level, 0.0, 1.0));

	if (rim_strength > 0.0) {
		float fresnel = pow(1.0 - max(dot(normal, view_dir), 0.0), rim_power);
		float rim = smoothstep(
				rim_threshold - band_softness,
				rim_threshold + band_softness,
				fresnel * band);
		SPECULAR_LIGHT += rim_color.rgb * rim * rim_strength * light_tint;
	}

	if (specular_amount > 0.0) {
		vec3 half_dir = normalize(view_dir + light_dir);
		float blinn = pow(max(dot(normal, half_dir), 0.0), mix(4.0, 128.0, specular_gloss));
		float highlight = smoothstep(
				specular_threshold - band_softness,
				specular_threshold + band_softness,
				blinn * ATTENUATION);
		SPECULAR_LIGHT += specular_color.rgb * highlight * specular_amount * light_tint;
	}
}
