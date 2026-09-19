shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

// A geometry-only reveal for the Blender V3 ribbons.  There is no billboard,
// texture card, circle or primitive mask in this material.
uniform vec4 layer_color : source_color = vec4(0.20, 0.40, 0.34, 1.0);
uniform float reveal = 0.0;
uniform float opacity = 0.0;
uniform float core_energy = 0.0;

varying float forward_distance;
varying float local_lateral;

void vertex() {
	// Blender authored its outgoing stroke along local -Z.  The small sinusoidal
	// offset breaks an overly mechanical reveal edge without adding a texture.
	forward_distance = clamp(-VERTEX.z + 0.055 * sin(VERTEX.x * 19.0 + VERTEX.z * 11.0), 0.0, 1.12);
	local_lateral = VERTEX.x;
}

void fragment() {
	float reveal_edge = 1.0 - smoothstep(reveal + 0.010, reveal + 0.075, forward_distance);
	float breakup = 0.92 + 0.08 * sin(local_lateral * 33.0 + forward_distance * 27.0);
	float alpha = reveal_edge * breakup * opacity;
	ALBEDO = layer_color.rgb;
	EMISSION = layer_color.rgb * core_energy;
	ALPHA = alpha;
}
