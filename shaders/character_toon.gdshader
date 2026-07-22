// Two-band hard cel shader for character models.
//
// Lighting approach adapted from eldskald's "Complete Cel Shader for Godot 4" (MIT):
// https://github.com/eldskald/godot4-cel-shader
// Rewritten as a single file with only the parts the Mobile renderer supports
// (no screen-reading refraction / transparency, no anisotropy, no subsurface).
//
// Design notes:
//  - Ambient light is disabled and replaced by `shadow_tint`, so the shadow band
//    stays a flat, art-directed color instead of being washed out by the scene
//    ambient. The shadow floor is written once in fragment(), and each light only
//    adds its lit share, so a key + fill setup never darkens the shadow twice.
//  - The band edge uses a narrow smoothstep instead of step(). A hard step
//    shimmers along the terminator on animated skinned meshes, especially on
//    mobile; ~0.02 of softness reads as a hard edge but stays stable.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, ambient_light_disabled;

group_uniforms Albedo;
uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
group_uniforms;

group_uniforms Cel;
// Color multiplied into the albedo on the unlit side. Doubles as the ambient fill.
uniform vec4 shadow_tint : source_color = vec4(0.42, 0.47, 0.56, 1.0);
// N-dot-L value where the terminator sits. Higher pushes the shadow further up.
uniform float light_threshold : hint_range(0.0, 1.0) = 0.40;
// Width of the band edge. Keep small; 0.0 gives a razor edge that aliases.
uniform float band_softness : hint_range(0.0, 0.25) = 0.02;
uniform float light_energy : hint_range(0.0, 3.0) = 1.0;
// LIGHT_COLOR already folds in the light's energy, and this project runs very
// different rigs (prep key 0.64, preview 0.82, battle 1.55). Scaling by this and
// clamping keeps the lit band art-directed instead of scene-dependent, while a
// deliberately weak fill light still lands weak.
uniform float light_response : hint_range(0.1, 4.0) = 1.5;
group_uniforms;

group_uniforms Rim;
uniform vec4 rim_color : source_color = vec4(0.85, 0.95, 1.0, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.12;
uniform float rim_power : hint_range(0.5, 8.0) = 3.0;
// Rim is also banded so it matches the cel look instead of fading smoothly.
uniform float rim_threshold : hint_range(0.0, 1.0) = 0.55;
group_uniforms;

group_uniforms Specular;
uniform vec4 specular_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// 0.0 disables the highlight entirely. Meant for metallic / wet-looking bosses.
uniform float specular_amount : hint_range(0.0, 2.0) = 0.0;
uniform float specular_gloss : hint_range(0.0, 1.0) = 0.7;
uniform float specular_threshold : hint_range(0.0, 1.0) = 0.5;
group_uniforms;

group_uniforms NormalMap;
// Off by default: a normal map breaks the two-band silhouette into noisy patches.
uniform bool use_normal_map = false;
uniform sampler2D normal_map_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float normal_map_depth : hint_range(-2.0, 2.0) = 0.45;
group_uniforms;

group_uniforms Emission;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy : hint_range(0.0, 8.0) = 0.0;
uniform sampler2D emission_mask : hint_default_white, filter_linear_mipmap, repeat_enable;
group_uniforms;

group_uniforms Tiling;
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform vec2 uv_offset = vec2(0.0, 0.0);
group_uniforms;

void vertex() {
	UV = UV * uv_scale + uv_offset;
}

void fragment() {
	vec4 base = texture(albedo_texture, UV) * albedo_color;
	ALBEDO = base.rgb;
	ALPHA = base.a;

	// Flat metallic/roughness: the custom light() ignores them, but keeping them
	// pinned avoids reflection probes tinting the result unevenly.
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;

	if (use_normal_map) {
		NORMAL_MAP = texture(normal_map_texture, UV).rgb;
		NORMAL_MAP_DEPTH = normal_map_depth;
	}

	// Shadow floor. Written once here rather than per-light so that a key + fill
	// rig does not stack the tint twice. With ambient_light_disabled this is the
	// entire unlit contribution.
	EMISSION = ALBEDO * shadow_tint.rgb
			+ emission_color.rgb * emission_energy * texture(emission_mask, UV).rgb;
}

void light() {
	vec3 normal = normalize(NORMAL);
	vec3 light_dir = normalize(LIGHT);
	vec3 view_dir = normalize(VIEW);

	float peak = max(LIGHT_COLOR.r, max(LIGHT_COLOR.g, LIGHT_COLOR.b));
	vec3 light_tint = (LIGHT_COLOR / max(peak, 0.0001))
			* clamp(peak * light_response, 0.0, 1.0);

	// ATTENUATION folds in shadow-map occlusion and distance falloff, so banding
	// after the multiply gives cast shadows the same hard edge as the terminator.
	float ndotl = max(dot(normal, light_dir), 0.0) * ATTENUATION;
	float band = smoothstep(
			light_threshold - band_softness,
			light_threshold + band_softness,
			ndotl);

	// The lit band only fills in what the shadow floor left missing, so a fully lit
	// surface lands near ALBEDO instead of blowing past white. The headroom is a
	// scalar rather than (1 - shadow_tint) per channel: subtracting the tint
	// channel-wise would cancel the same hue out of the lit side and leave every
	// character looking jaundiced under the warm key light.
	float shadow_level = dot(shadow_tint.rgb, vec3(0.2126, 0.7152, 0.0722));
	DIFFUSE_LIGHT += ALBEDO * light_tint * band * light_energy
			* (1.0 - clamp(shadow_level, 0.0, 1.0));

	if (rim_strength > 0.0) {
		float fresnel = pow(1.0 - max(dot(normal, view_dir), 0.0), rim_power);
		// Gated by `band` so the rim only lights the side facing the light.
		float rim = smoothstep(
				rim_threshold - band_softness,
				rim_threshold + band_softness,
				fresnel * band);
		SPECULAR_LIGHT += rim_color.rgb * rim * rim_strength * light_tint;
	}

	if (specular_amount > 0.0) {
		vec3 half_dir = normalize(view_dir + light_dir);
		float blinn = pow(max(dot(normal, half_dir), 0.0), mix(4.0, 128.0, specular_gloss));
		float highlight = smoothstep(
				specular_threshold - band_softness,
				specular_threshold + band_softness,
				blinn * ATTENUATION);
		SPECULAR_LIGHT += specular_color.rgb * highlight * specular_amount * light_tint;
	}
}
