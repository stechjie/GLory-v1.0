// BA 风格描边（ba_toon.gdshader 的 next_pass）。
//
// 两个要点：
//  - 描边颜色 = 贴图颜色 × outline_tint（BA 实测衣物 0.27、头发 0.33、脸偏暖），不是统一的黑线。
//  - 宽度按「屏幕像素」算，在裁剪空间里沿法线外推：和模型自身尺寸无关。
//    宠物原生只有 0.011 个单位高、靠缩放放大约 86 倍，旧的模型空间描边宽度会被放大成一团黑，
//    屏幕空间宽度没有这个问题，近看远看都是同样几个像素。
// 同样不写 ALPHA，留在不透明队列（主菜单透明背景视口）。

shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec4 outline_tint : source_color = vec4(0.30, 0.28, 0.32, 1.0);
// 描边宽度（像素，按 1080 高的画面换算，分辨率变了宽度跟着等比变）。
uniform float outline_px : hint_range(0.0, 6.0) = 2.0;

void vertex() {
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	vec3 n_view = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec2 n_clip = (PROJECTION_MATRIX * vec4(n_view, 0.0)).xy;
	float len = length(n_clip);
	if (len > 1.0e-5) {
		n_clip /= len;
		// 归一化设备坐标里 2 个单位 = 整个画面高度
		float px_to_ndc = 2.0 / 1080.0;
		clip.xy += n_clip * outline_px * px_to_ndc * clip.w * vec2(VIEWPORT_SIZE.y / VIEWPORT_SIZE.x, 1.0);
	}
	POSITION = clip;
}

void fragment() {
	ALBEDO = (texture(albedo_texture, UV) * albedo_color).rgb * outline_tint.rgb;
}
