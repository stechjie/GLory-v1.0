shader_type canvas_item;
varying vec4 tint;
void vertex() { tint = COLOR; }

// 用同一边框下侧的无图标部分替换左上角徽章，保留聊天框其他装饰。
void fragment() {
	float patch = (1.0 - smoothstep(0.15, 0.23, UV.x)) * (1.0 - smoothstep(0.30, 0.40, UV.y));
	COLOR = tint * mix(texture(TEXTURE, UV), texture(TEXTURE, vec2(UV.x, 1.0 - UV.y)), patch);
}
