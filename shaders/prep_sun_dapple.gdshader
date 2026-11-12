shader_type canvas_item;
// 摆放界面草地的「树叶缝里漏下来的阳光被风吹动」（11.12，默认青草地皮肤，挂在满屏 2D 草地底图上）。
//
// 草地图里本来就画了一块块黄色光斑。这里不改构图，只让光在动：
//   1. 光斑（又亮又偏黄的像素）跟着一张往风向漂的噪声一明一暗，像树叶晃动挡光；
//   2. 整片草地上再漂几片很淡的树叶影子，同一个风向；
//   3. 图最上面那一截树冠轻轻左右摆（越往上摆得越多，树干不动）。

uniform sampler2D noise_tex : repeat_enable, filter_linear;   // 无缝噪声（PrepSunDapple 生成）
uniform vec2 wind = vec2(0.020, 0.006);     // 风向 + 风速（UV/秒）
uniform float patch_swing = 0.34;           // 光斑被风吹亮的幅度（只往亮里走，压暗会发灰发脏）
uniform float shadow_depth = 0.035;         // 树叶影子深度
uniform vec2 rune_center = vec2(0.1143, 0.5246);   // 符文中心（底图 UV，同 PrepLawnFx.RUNE_UV）
uniform vec2 rune_half = vec2(0.016, 0.040);         // 符文范围的一半
uniform float canopy_height = 0.26;         // 树冠范围（从图顶往下的比例）
uniform float canopy_sway = 0.0;            // 树冠摆幅（UV）。11.12 用户：树是整张图的一部分，一摆整块被拉扯 —— 关掉

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

void fragment() {
	float t = TIME;
	vec2 uv = UV;
	// 3. 树冠摆动：只在图最上面那截，越往上越明显；两个频率叠一下，别像节拍器
	float canopy = 1.0 - smoothstep(0.0, canopy_height, uv.y);
	uv.x += (sin(t * 1.1 + uv.y * 14.0) + 0.45 * sin(t * 2.3 + uv.x * 9.0)) * canopy_sway * canopy;
	vec4 base = texture(TEXTURE, uv);
	vec3 col = base.rgb;
	// 1. 光斑：亮、偏黄（红绿都高、蓝低）
	float l = luma(col);
	float yellow = smoothstep(0.08, 0.22, (col.r + col.g) * 0.5 - col.b);
	float spot = smoothstep(0.50, 0.70, l) * yellow;
	// 两层噪声往同一风向、不同速度漂，乘起来让明暗是一团一团地过去
	float n1 = texture(noise_tex, UV * vec2(2.2, 3.6) - wind * t).r;
	float n2 = texture(noise_tex, UV * vec2(4.1, 6.3) - wind * t * 1.7 + vec2(0.37, 0.61)).r;
	float gust = clamp(n1 * 0.65 + n2 * 0.55 - 0.1, 0.0, 1.0);
	// 只提亮：风吹开树叶 = 光斑更亮更暖；风停 = 回到原图（不压暗，压暗的黄会变成泥色）
	float lift = smoothstep(0.35, 0.9, gust) * patch_swing;
	col = mix(col, col * (1.0 + lift) + vec3(0.07, 0.06, 0.0) * lift, spot);
	// 2. 树叶影子：很淡、很大块，漂得比光斑慢
	float s = texture(noise_tex, UV * vec2(0.9, 1.4) - wind * t * 0.6 + vec2(0.13, 0.29)).r;
	float shade = smoothstep(0.6, 0.95, s) * shadow_depth * (1.0 - spot);
	col *= 1.0 - shade;
	// 4. 符文石：只提亮符文那几根青色线条（青 = 绿蓝都高、红低），一明一暗地呼吸
	vec2 rd = (UV - rune_center) / rune_half;
	float near_rune = 1.0 - smoothstep(0.8, 1.2, length(rd));
	float cyan = smoothstep(0.25, 0.5, min(col.g, col.b) - col.r);
	float rune_pulse = 0.5 + 0.5 * sin(t * 6.2831 / 2.8);
	col += vec3(0.25, 0.6, 0.6) * cyan * near_rune * (0.15 + 0.6 * rune_pulse);
	COLOR = vec4(col, base.a);
}
