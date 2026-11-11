shader_type canvas_item;

// 主菜单主按钮的扫光：每 period 秒一道斜向亮带从左扫到右，只亮在不透明的像素上。
uniform float period = 3.4;
uniform float sweep_time = 0.85;
uniform float width = 0.07;
uniform float strength = 0.5;

void fragment() {
	// COLOR 进来时已经是 贴图 × modulate，再采一次会把颜色平方变暗
	vec4 c = COLOR;
	float t = mod(TIME, period) / sweep_time;
	float pos = mix(-0.35, 1.35, t);
	float d = abs(UV.x + (UV.y - 0.5) * 0.45 - pos);
	float band = smoothstep(width, 0.0, d) * step(t, 1.0);
	c.rgb += vec3(1.0, 0.96, 0.78) * band * strength * c.a;
	COLOR = c;
}
