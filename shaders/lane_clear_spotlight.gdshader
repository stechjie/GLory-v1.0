shader_type canvas_item;
// 本路清场定格时的全场压暗：最后被打死的敌人（spot_a）和击杀者（spot_b）
// 留出两个亮洞，像聚光灯。纯色压暗 + 暗角，不采样屏幕贴图（手机端省一次回读）。
uniform float dim : hint_range(0.0, 1.0) = 0.0;
uniform vec2 rect_size = vec2(1600.0, 720.0);
uniform vec2 spot_a = vec2(-10000.0);
uniform vec2 spot_b = vec2(-10000.0);
uniform float radius = 120.0;
uniform vec4 tint : source_color = vec4(0.025, 0.03, 0.07, 1.0);
uniform vec4 rim_color : source_color = vec4(1.0, 0.78, 0.32, 1.0);

float bell(float value, float center, float width) {
	float d = (value - center) / width;
	return exp(-d * d);
}

void fragment() {
	vec2 p = UV * rect_size;
	float da = distance(p, spot_a);
	float db = distance(p, spot_b);
	float hole_a = 1.0 - smoothstep(radius * 0.50, radius, da);
	float hole_b = (1.0 - smoothstep(radius * 0.38, radius * 0.78, db)) * 0.85;
	float hole = max(hole_a, hole_b);
	float vignette = smoothstep(0.30, 0.85, length((UV - 0.5) * vec2(1.0, rect_size.y / rect_size.x)) * 1.6);
	float shade = (0.60 + 0.25 * vignette) * (1.0 - hole);
	// 目标外沿一圈细金边，让「聚光」在任何地图底色上都读得出来。
	float rim = bell(da, radius * 0.86, radius * 0.07) * 0.75;
	vec3 color = mix(tint.rgb, rim_color.rgb, clamp(rim / max(shade + rim, 0.001), 0.0, 1.0));
	COLOR = vec4(color, clamp(shade + rim, 0.0, 0.92) * dim);
}
