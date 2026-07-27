shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled;

uniform vec4 outline_color : source_color = vec4(0.030, 0.020, 0.070, 1.0);
// Thickness is measured in normalized screen height, not model space, so the ink
// line stays the same weight across cluster parts that use very different scales.
uniform float outline_width : hint_range(0.0, 0.04) = 0.008;

void vertex() {
	vec4 clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 view_normal = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float aspect = VIEWPORT_SIZE.x / max(VIEWPORT_SIZE.y, 1.0);
	vec2 dir = (PROJECTION_MATRIX * vec4(view_normal, 0.0)).xy;
	dir.x *= aspect;
	if (length(dir) > 0.00001) {
		dir = normalize(dir);
		dir.x /= aspect;
		clip.xy += dir * outline_width * clip.w;
	}
	POSITION = clip;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
