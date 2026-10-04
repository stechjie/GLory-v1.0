shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never;

uniform bool low_quality = false;
uniform float emphasis : hint_range(0.0, 1.0) = 0.0;
uniform float dissolve : hint_range(0.0, 1.0) = 0.0;
uniform float half_height = 0.27;
varying vec3 local_position;

void vertex() { local_position = VERTEX; }
void fragment() {
	float rim = smoothstep(0.72, 1.0, abs(local_position.y) / max(half_height, 0.001));
	float ground_line = 1.0 - smoothstep(0.0, 0.018, abs(abs(local_position.x)-0.128));
	float wave = 0.5 + 0.5 * sin(local_position.z * 5.0 - TIME * 1.4);
	float bands = pow(0.5 + 0.5 * cos(local_position.z * 9.0 + local_position.y * 13.0), 18.0);
	float rune_z = abs(fract(local_position.z * 0.65) - 0.5);
	float rune = 1.0 - smoothstep(0.016, 0.035, abs(rune_z + abs(local_position.x) * 1.8 - 0.22));
	float detail = low_quality ? 0.0 : bands * 0.035 + wave * 0.018 + rune * 0.24;
	ALBEDO = mix(vec3(0.12, 0.48, 0.43), vec3(0.55, 0.88, 0.73), rim);
	ALPHA = (0.10 + rim * 0.21 + ground_line * 0.035 + detail + emphasis * 0.12) * (1.0 - dissolve);
}
