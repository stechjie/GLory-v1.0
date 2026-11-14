// BA 风格描边（ba_pet_body.gdshader 的 next_pass）。
// 按 Blue Archive Outline 基线顶点程序（参考包 MX_C-General_Layer4/p4_blob_0141、MX_C-Hair/p4_blob_0076）复现：
//  - 外扩方向用 TANGENT.xyz，不用 NORMAL。网格的 TANGENT 由 scripts/pets/BAOutlineDataImport.gd
//    在导入时写成平滑法线（对应原作 OL 网格的专用切线）；会跟骨骼蒙皮。
//  - 投影到裁剪空间后取 xy，按 rsqrt(max(dot, 0.000061)) 归一化。
//  - 外扩量 = clip.w × 顶点色 Alpha × outline_width（原作常量 0.002），Y 方向再乘 屏宽/屏高：
//    结果是与距离无关、约等于 0.001×屏宽 像素的线宽。
//  - clip.z 加 outline_z_correction（_OutlineZCorrection）。
//  - 正面剔除；颜色 = 顶点处贴图颜色（LOD 0）× _OutlineTint × 主光色。
//    _OutlineTint 是 Unity 颜色属性，Linear 工程里会转线性 → 这里用 source_color。
// 同样不写 ALPHA，留在不透明队列。

shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque;

uniform sampler2D albedo_texture : source_color, filter_linear, repeat_enable;
uniform vec4 outline_tint : source_color = vec4(0.4, 0.4, 0.4, 1.0);  // _OutlineTint
uniform vec4 light_tone : source_color = vec4(1.0);                   // 替代 _MainLightColor
uniform float outline_width = 0.002;                                  // 原作常量
uniform float outline_z_correction = 0.0;                             // _OutlineZCorrection

varying vec3 outline_color;

void vertex() {
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	vec2 dir = (PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(TANGENT, 0.0))).xy;
	dir *= inversesqrt(max(dot(dir, dir), 0.000061));
	float amount = clip.w * COLOR.a * outline_width;
	clip.x += dir.x * amount;
	clip.y += dir.y * amount * (VIEWPORT_SIZE.x / VIEWPORT_SIZE.y);
	clip.z += outline_z_correction;
	POSITION = clip;
	outline_color = textureLod(albedo_texture, UV, 0.0).rgb * outline_tint.rgb * light_tone.rgb;
}

void fragment() {
	ALBEDO = outline_color;
}
