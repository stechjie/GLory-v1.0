// Billboard flame sprite for formation-ally body fire (CPUParticles3D quads).
// Procedural: no texture. Additive, unshaded, no depth write. Per-particle
// COLOR.a drives fade, COLOR.rgb is unused (colours come from the uniforms so
// one material per unit tints every emitter on it).
shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 core_color : source_color = vec4(1.0, 0.92, 0.6, 1.0);
uniform vec4 mid_color : source_color = vec4(1.0, 0.45, 0.08, 1.0);
uniform vec4 edge_color : source_color = vec4(0.6, 0.08, 0.02, 1.0);
uniform float intensity : hint_range(0.0, 4.0) = 1.6;

varying float v_seed;

void vertex() {
	// camera-facing, keep particle scale (same as BaseMaterial3D particle billboard)
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	v_seed = fract(MODEL_MATRIX[3].x * 3.17 + MODEL_MATRIX[3].z * 5.31 + float(INSTANCE_ID) * 0.618);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;          // x: -1..1, y: -1 (top) .. 1 (bottom)
	float t = TIME * 3.0 + v_seed * 17.0;
	// flicker the outline sideways, more toward the tip
	float tip = clamp((1.0 - p.y) * 0.5, 0.0, 1.0);
	p.x += sin(p.y * 5.0 + t) * 0.12 * tip + sin(p.y * 11.0 - t * 1.7) * 0.05 * tip;
	// teardrop: wide round base, narrow tip
	float width = mix(0.78, 0.08, pow(tip, 1.25));
	float body = 1.0 - smoothstep(width * 0.55, width, abs(p.x));
	body *= smoothstep(1.0, 0.55, p.y);            // round bottom
	body *= 1.0 - smoothstep(0.75, 1.0, tip);       // soft tip
	float core = body * (1.0 - smoothstep(0.0, width * 0.38, abs(p.x))) * smoothstep(0.35, 0.95, p.y + 0.25);
	vec3 col = mix(edge_color.rgb, mid_color.rgb, smoothstep(0.0, 0.6, body));
	col = mix(col, core_color.rgb, clamp(core * 0.75, 0.0, 1.0));
	float a = body * COLOR.a;
	ALBEDO = col * a * intensity;
	ALPHA = 1.0;
}
