shader_type spatial;
// 升星光柱：一根从脚下冲到头顶之上的圆柱。
//
// 为什么光柱是主体、地面环只是底座：备战是 45° 俯视（相机 (0,3.8,2.0) 看 (0,-0.07,-0.03)），
// 贴地的圆在屏幕上被压成扁椭圆 —— 那是**被压缩得最厉害**的那个轴。竖直方向几乎不被压缩，
// 所以同样的像素预算，光柱比地面环显眼得多。TFT / 金铲铲这类自走棋升星时视觉重心全在
// 竖直方向上，就是这个道理。
//
// 两条让它读成「光」而不是「一根塑料管」的做法：
//   · **底亮顶淡**（v_h 的幂次衰减）—— 光是从地里升起来的，不是悬着一根柱子。
//   · **边缘更亮**（NORMAL 与 VIEW 的夹角）—— 圆柱侧面在轮廓处视线掠过最多体积，
//     真实的体积光就是边上最亮。少了这条，柱子会是一块均匀的色板。
// cull_front = 只画圆柱的**背面**。画两面的话，近侧柱壁会盖在棋子前面，
// 加色混合下棋子整个蒙上一层黄（第四轮预览就是这样，棋子看不清了）。
// 只留背面 ⇒ 光在棋子**身后与两侧**，棋子本身保持可读 —— 这也是 TFT 那类
// 升星光柱的观感：人站在光里，不是人被光糊住。
render_mode unshaded, blend_add, cull_front, depth_draw_never;

uniform vec4 beam_color : source_color = vec4(1.0, 0.86, 0.42, 1.0);
uniform float alpha = 1.0;
// 圆柱的世界高度。CylinderMesh 以原点为中心，所以 VERTEX.y 是 [-h/2, h/2]。
uniform float height = 1.0;

varying float v_h;

void vertex() {
	v_h = clamp(VERTEX.y / max(height, 0.001) + 0.5, 0.0, 1.0);
}

void fragment() {
	float up = pow(1.0 - v_h, 1.6);
	float edge = 1.0 - abs(dot(normalize(NORMAL), normalize(VIEW)));
	ALBEDO = beam_color.rgb;
	ALPHA = up * (0.30 + 0.70 * edge) * alpha * beam_color.a;
}
