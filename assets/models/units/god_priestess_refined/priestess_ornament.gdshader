shader_type spatial;
render_mode depth_draw_opaque, cull_back, ambient_light_disabled;
uniform vec4 base_color : source_color = vec4(1.0);
uniform float highlight = 0.08;
void fragment() {
	ALBEDO = base_color.rgb;
	ROUGHNESS = 0.65;
	EMISSION = ALBEDO * vec3(0.64, 0.68, 0.74);
}
void light() {
	float peak = max(LIGHT_COLOR.r, max(LIGHT_COLOR.g, LIGHT_COLOR.b));
	vec3 tint = LIGHT_COLOR / max(peak, 0.0001) * clamp(peak * 1.5, 0.0, 1.0);
	float band = smoothstep(0.26, 0.40, max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION);
	DIFFUSE_LIGHT += ALBEDO * tint * band * 0.32;
	float spec = pow(max(dot(NORMAL, normalize(LIGHT + VIEW)), 0.0), 24.0);
	SPECULAR_LIGHT += tint * smoothstep(0.5, 0.65, spec) * highlight * ATTENUATION;
}
