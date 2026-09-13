shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

void fragment() {
	vec2 point = (UV - vec2(0.5)) * 2.0;
	float radius_squared = dot(point, point);
	// A small contact core fades continuously to a transparent edge. No opaque
	// disc or second screen-space shadow is needed below the same actor.
	float falloff = max(0.0, (exp(-3.5 * radius_squared) - exp(-3.5)) / (1.0 - exp(-3.5)));
	ALBEDO = vec3(0.025, 0.035, 0.028);
	ALPHA = falloff * 0.32;
}
