shader_type canvas_item;
// 摆放界面樱花皮肤的草地（11.16，挂在满屏 2D 底图上）。对应青草地的 prep_sun_dapple：
//   1. 树影摇晃：草地上那片紫色的树叶影子真的来回挪（树枝在晃）。做法：先把这一点原有的影子
//      「除掉」还原成草地，再按挪了位置之后那一点有没有影子重新盖上 —— 草的纹理不动，只有影子在动；
//   2. 花吹雪的风带：阵风来的时候，一道斜着的淡亮带从左往右扫过整张图（PrepSakuraFx 喂 gust_front）。
// 只改颜色不挪像素：树和石头是整张图的一部分，一挪整块被拉扯。

uniform sampler2D noise_tex : repeat_enable, filter_linear;   // 无缝噪声（同 PrepSunDapple 那张）
uniform vec2 wind = vec2(0.024, 0.008);     // 风向 + 风速（UV/秒）
uniform float sway = 0.0075;                // 树影来回挪多远（UV；阵风时再加大）
uniform vec2 sway_dir = vec2(1.0, 0.35);    // 顺着风的方向来回
uniform vec3 shadow_tint = vec3(0.85, 0.93, 1.02);   // 影子色 ÷ 草地色（照图量的）
uniform float gust = 0.0;                   // 阵风强度 0~1
uniform float gust_front = -1.0;            // 风带现在扫到哪（UV.x + UV.y * 0.25 的值）

float ground(vec3 c) {
	return smoothstep(0.62, 0.72, c.r) * (1.0 - smoothstep(0.64, 0.70, c.g));
}

// 树影：偏紫 = 红比蓝高不了多少（没被挡的草地红比蓝高一大截）
float shadow_of(vec3 c) {
	return 1.0 - smoothstep(0.10, 0.20, c.r - c.b);
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec3 col = base.rgb;
	// 只动草地（含被影子盖住的草地）：够亮、绿不高。花（绿高）、叶子和树干（暗）、石头亮面都不碰；只在左半边
	float region = 1.0 - smoothstep(0.58, 0.68, UV.x);
	float here = ground(col) * region;
	if (here > 0.003) {
		float t = TIME;
		// 11.16 返工：原来每一小块各晃各的，影子像果冻在抖。现在照树枝真的晃的样子来：
		//   · 一整枝一起慢慢来回（相位只按很大块的噪声错开一点：不同的枝不同步，同一枝不变形）；
		//   · 只顺着风向来回，两个互不成倍数的慢频率叠着，不像节拍器；
		//   · 时强时弱：风有一阵没一阵，摆幅跟着一条很慢的噪声涨落；
		//   · 再叠一点点很细很快的抖（约 2 像素），是叶子自己在颤。
		float n = texture(noise_tex, UV * vec2(0.8, 1.2)).r - 0.5;
		float breeze = 0.30 + 0.70 * texture(noise_tex, vec2(t * 0.021, 0.37)).r;
		float swing = sin(t * 0.9 + n * 3.0 + UV.y * 2.0) + 0.5 * sin(t * 1.47 + n * 5.0 + 1.3);
		vec2 off = sway_dir * swing * sway * breeze * (1.0 + 1.6 * gust)
			+ vec2(sin(t * 3.1 + UV.x * 40.0 + UV.y * 31.0), cos(t * 2.7 + UV.y * 37.0)) * 0.0012;
		vec3 there = texture(TEXTURE, UV + off).rgb;
		float s0 = shadow_of(col);
		float s1 = shadow_of(there) * ground(there);
		vec3 bare = col / mix(vec3(1.0), shadow_tint, s0);
		col = mix(col, bare * mix(vec3(1.0), shadow_tint, s1), here);
	}
	if (gust > 0.003) {
		float d = (UV.x + UV.y * 0.25 - gust_front) / 0.14;
		col += vec3(0.11, 0.10, 0.10) * exp(-d * d) * gust;
	}
	COLOR = vec4(col, base.a);
}
