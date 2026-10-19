shader_type spatial;
// 「可升 4★」的光幕：一圈围住棋子的竖直光，**底部最亮、往上渐淡**，像脚底下有一盏灯
// 往上打（Leno 10.18：「棋子脚下周围有金色光辉往上照开来」）。
//
// 三条让它读成「光」而不是「一根金色塑料管」：
//   · 底亮顶淡（v_h 的幂次衰减）—— 光是从地上往上照的。
//   · 轮廓处更亮（NORMAL 与 VIEW 的夹角）—— 体积光在边缘视线掠过最多。
//   · cull_front：只画圆柱**背面**。两面都画的话，近侧柱壁会盖在棋子前面，加色混合下
//     棋子整个蒙一层金 —— 那正是这次要拿掉的「满身金色」。
render_mode unshaded, blend_add, cull_front, depth_draw_never;

uniform vec4 glow_color : source_color = vec4(1.0, 0.80, 0.32, 1.0);
uniform float alpha = 1.0;
// 圆柱的高度（本地单位）。CylinderMesh 以原点为中心，VERTEX.y ∈ [-h/2, h/2]。
uniform float height = 1.0;

varying float v_h;

void vertex() {
	v_h = clamp(VERTEX.y / max(height, 0.001) + 0.5, 0.0, 1.0);
}

void fragment() {
	float up = pow(1.0 - v_h, 1.8);
	float edge = 1.0 - abs(dot(normalize(NORMAL), normalize(VIEW)));
	ALBEDO = glow_color.rgb;
	ALPHA = up * (0.25 + 0.75 * edge) * alpha * glow_color.a;
}
