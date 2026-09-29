shader_type canvas_item;

// Eight-pixel corners on the 48 px settlement portraits.
uniform float corner_radius = 0.166667;
void fragment() {
	vec4 source = COLOR;
	vec2 q = abs(UV - vec2(0.5)) - vec2(0.5 - corner_radius);
	float distance_to_corner = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - corner_radius;
	source.a *= 1.0 - smoothstep(-0.008, 0.008, distance_to_corner);
	COLOR = source;
}
