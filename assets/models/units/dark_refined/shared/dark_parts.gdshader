// Crafted dark-race parts (horns, wings, chains, ...): one material for every unit.
// Vertex colour RGB is the albedo and its alpha the glow amount, painted per part in
// tools/model_refinement/build_dark_parts.py. Lighting matches dark_body.gdshader
// (two cel bands, light-independent violet rim) so parts sit in the same style as
// the skinned bodies. Opaque, no textures, Compatibility/Mobile safe.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, ambient_light_disabled;

uniform vec3 shadow_tint : source_color = vec3(0.58, 0.48, 0.72);
uniform float light_threshold : hint_range(0.0, 1.0) = 0.32;
uniform float band_softness : hint_range(0.0, 0.25) = 0.03;
uniform float light_energy : hint_range(0.0, 3.0) = 1.25;
uniform float light_response : hint_range(0.1, 4.0) = 1.5;
uniform float glow_energy : hint_range(0.0, 4.0) = 1.1;
uniform vec3 rim_color : source_color = vec3(0.52, 0.36, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.22;
uniform float rim_power : hint_range(0.5, 8.0) = 2.5;
uniform float rim_threshold : hint_range(0.0, 1.0) = 0.56;
uniform float highlight : hint_range(0.0, 2.0) = 0.45;

void fragment() {
	ALBEDO = COLOR.rgb;
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	float rim = smoothstep(rim_threshold - band_softness, rim_threshold + band_softness, fresnel);
	EMISSION = ALBEDO * shadow_tint + COLOR.rgb * COLOR.a * glow_energy + rim_color * rim * rim_strength;
}

void light() {
	vec3 normal = normalize(NORMAL);
	vec3 light_dir = normalize(LIGHT);
	float peak = max(LIGHT_COLOR.r, max(LIGHT_COLOR.g, LIGHT_COLOR.b));
	vec3 light_tint = (LIGHT_COLOR / max(peak, 0.0001)) * clamp(peak * light_response, 0.0, 1.0);
	float ndotl = max(dot(normal, light_dir), 0.0) * ATTENUATION;
	float band = smoothstep(light_threshold - band_softness, light_threshold + band_softness, ndotl);
	float shadow_level = dot(shadow_tint, vec3(0.2126, 0.7152, 0.0722));
	DIFFUSE_LIGHT += ALBEDO * light_tint * band * light_energy * (1.0 - clamp(shadow_level, 0.0, 1.0));
	// Highlights stay cool and only on light-coloured parts (steel, bone): the warm battle
	// key turned broad dark wing membranes into flat tan patches (iteration 03).
	vec3 half_dir = normalize(normalize(VIEW) + light_dir);
	float blinn = pow(max(dot(normal, half_dir), 0.0), 64.0);
	float bright = smoothstep(0.06, 0.25, dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722)));
	SPECULAR_LIGHT += vec3(0.85, 0.80, 1.0) * smoothstep(0.42, 0.48, blinn * ATTENUATION) * highlight * bright
			* clamp(peak * light_response, 0.0, 1.0);
}
