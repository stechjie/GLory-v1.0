// 方向椭圆接地影，只给 scenes/debug/CharacterLookAB 试验用，生产不引用。
//
// 现有 shaders/unit_contact_shadow.gdshader 是脚底正中一块对称高斯圆。
// 这里在同一块平面上叠两层：脚底一个小而实的核心（踩地感），加一条朝背光方向
// 拉长、逐渐变淡的尾巴（光的方向感）。仍是一块平面、0 次采样，代价和原来一样，
// 适合做低画质档；形状不随动作变，这是它和投影影子的差别。
//
// 平面要比原来大：尾巴要伸出去。平面中心就是单位脚底。

shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

// 影子在平面 UV 空间里伸出去的方向（对应世界 xz，会被归一化）。
uniform vec2 shadow_direction = vec2(0.82, 0.57);
uniform vec3 shadow_color : source_color = vec3(0.025, 0.03, 0.045);
// 核心：半径（占平面半宽的比例）与浓度。
uniform float core_radius = 0.22;
uniform float core_alpha : hint_range(0.0, 1.0) = 0.42;
// 尾巴：中心离脚多远、沿方向 / 横向的半径、浓度。
uniform float tail_offset = 0.32;
uniform float tail_length = 0.55;
uniform float tail_width = 0.26;
uniform float tail_alpha : hint_range(0.0, 1.0) = 0.26;

float soft_ellipse(vec2 p, vec2 radii) {
	vec2 q = p / max(radii, vec2(0.001));
	float r2 = dot(q, q);
	return max(0.0, (exp(-3.0 * r2) - exp(-3.0)) / (1.0 - exp(-3.0)));
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	vec2 dir = normalize(shadow_direction);
	vec2 local = vec2(dot(p, dir), dot(p, vec2(-dir.y, dir.x)));
	float core = soft_ellipse(p, vec2(core_radius)) * core_alpha;
	float tail = soft_ellipse(local - vec2(tail_offset, 0.0), vec2(tail_length, tail_width)) * tail_alpha;
	// 取较大值而不是相加：核心和尾巴交界不会多出一圈更黑的环。
	ALBEDO = shadow_color;
	ALPHA = max(core, tail);
}
