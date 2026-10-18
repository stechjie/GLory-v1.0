shader_type spatial;
// 升星地面环：平躺在棋盘上的一张 quad，上面画一圈**软边**的环。
//
// 为什么软边是硬指标：VFXShockwave 读起来像「被砸了一下」，靠的就是硬边 + 匀速外扩。
// 升星是「获得」，语义相反 —— 同样外扩，边缘羽化 + 边扩边淡才读成「光散开」。
// 所以这里的 ALPHA 用的是 smoothstep 的**平方**衰减，不是一刀切的阶跃。
//
// unshaded + blend_add：棋盘底图是暖绿草地，加色混合才不会在亮处变成一块灰膜。
// depth_draw_never + cull_disabled：它只是一层贴地的光，不该写深度、也不该被背面剔除；
// 深度**测试**保留 —— 棋子站在环上时应当挡住它脚下那一段，那是对的。
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 ring_color : source_color = vec4(1.0, 0.86, 0.42, 1.0);
// 半径与线宽都按 quad 的 UV 算。quad 的世界边长固定 1.0，所以 UV 的 0..0.5
// 正好等于世界的 0..0.5 —— 这里的 radius 可以当世界半径直接读（0.20 = 一格站位圈）。
uniform float radius = 0.20;
uniform float thickness = 0.05;
uniform float alpha = 1.0;

void fragment() {
	float d = length(UV - vec2(0.5));
	float e = 1.0 - smoothstep(0.0, thickness, abs(d - radius));
	ALBEDO = ring_color.rgb;
	ALPHA = e * e * alpha * ring_color.a;
}
