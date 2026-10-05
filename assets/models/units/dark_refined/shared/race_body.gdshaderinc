// Shared body of the race refinement materials (dark, undead). Included by
// dark_body.gdshader (cull_back) and dark_body_two_sided.gdshader (cull_disabled, for
// bodies with inward-facing cloak triangles that otherwise show the black outline shell).
group_uniforms Albedo;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 body_tint : source_color = vec3(1.0);
uniform float value_lift : hint_range(0.0, 1.0) = 0.25;
group_uniforms;

group_uniforms Palette;
uniform float race_hue : hint_range(0.0, 1.0) = 0.76;
uniform float hue_unify : hint_range(0.0, 1.0) = 0.85;
// Below this saturation (skin, white hair, steel) paint keeps its own hue.
uniform float unify_min_saturation : hint_range(0.0, 1.0) = 0.18;
group_uniforms;

group_uniforms Cel;
uniform vec3 shadow_tint : source_color = vec3(0.62, 0.52, 0.74);
uniform float light_threshold : hint_range(0.0, 1.0) = 0.32;
uniform float band_softness : hint_range(0.0, 0.25) = 0.03;
uniform float light_energy : hint_range(0.0, 3.0) = 1.25;
uniform float light_response : hint_range(0.1, 4.0) = 1.5;
group_uniforms;

group_uniforms Accent;
uniform vec3 accent_color : source_color = vec3(0.85, 0.35, 1.0);
// Hue centre/width on 0..1, measured from the unit's own atlas.
uniform float accent_hue : hint_range(0.0, 1.0) = 0.8;
uniform float accent_hue_width : hint_range(0.01, 0.5) = 0.08;
uniform float accent_min_saturation : hint_range(0.0, 1.0) = 0.4;
uniform float accent_min_value : hint_range(0.0, 1.0) = 0.35;
uniform float accent_glow : hint_range(0.0, 4.0) = 0.6;
group_uniforms;

group_uniforms Trim;
uniform float trim_max_saturation : hint_range(0.0, 1.0) = 0.25;
uniform float trim_min_value : hint_range(0.0, 1.0) = 0.45;
uniform vec3 trim_highlight_color : source_color = vec3(0.92, 0.88, 1.0);
uniform float trim_highlight : hint_range(0.0, 2.0) = 0.5;
uniform float trim_gloss : hint_range(0.0, 1.0) = 0.75;
group_uniforms;

group_uniforms Rim;
uniform vec3 rim_color : source_color = vec3(0.62, 0.40, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.35;
uniform float rim_power : hint_range(0.5, 8.0) = 2.5;
uniform float rim_threshold : hint_range(0.0, 1.0) = 0.5;
group_uniforms;

group_uniforms Maps;
uniform bool use_normal_map = false;
uniform sampler2D normal_map_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float normal_map_depth : hint_range(-2.0, 2.0) = 0.45;
uniform sampler2D emission_texture : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float emission_energy : hint_range(0.0, 8.0) = 0.0;
group_uniforms;

varying float trim_region;

vec3 rgb_to_hsv(vec3 c) {
	vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, k.wz), vec4(c.gb, k.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 1.0e-5)), d / (q.x + 1.0e-5), q.x);
}

vec3 hsv_to_rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

void fragment() {
	// Classify and recolour in display (sRGB-like) space, where the thresholds were measured.
	vec3 display = sqrt(max(texture(albedo_texture, UV).rgb, vec3(0.0)));
	vec3 hsv = rgb_to_hsv(display);
	float hue_distance = abs(fract(hsv.x - accent_hue + 0.5) - 0.5);
	float accent = (1.0 - smoothstep(accent_hue_width * 0.6, accent_hue_width, hue_distance))
			* smoothstep(accent_min_saturation * 0.7, accent_min_saturation, hsv.y)
			* smoothstep(accent_min_value * 0.7, accent_min_value, hsv.z);
	trim_region = (1.0 - smoothstep(trim_max_saturation * 0.7, trim_max_saturation, hsv.y))
			* smoothstep(trim_min_value * 0.75, trim_min_value, hsv.z);

	// Shortest way round the hue circle toward the race violet, scaled by saturation.
	float pull = hue_unify * smoothstep(unify_min_saturation, unify_min_saturation + 0.2, hsv.y);
	float delta = fract(race_hue - hsv.x + 0.5) - 0.5;
	vec3 unified = hsv_to_rgb(vec3(fract(hsv.x + delta * pull), hsv.y, hsv.z));
	ALBEDO = mix(unified * unified, unified, value_lift) * body_tint;
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	if (use_normal_map) {
		NORMAL_MAP = texture(normal_map_texture, UV).rgb;
		NORMAL_MAP_DEPTH = normal_map_depth;
	}
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	float rim = smoothstep(rim_threshold - band_softness, rim_threshold + band_softness, fresnel);
	// Shadow floor once (key + fill never stack it), then light-independent glow.
	EMISSION = ALBEDO * shadow_tint
			+ accent_color * accent * accent_glow * hsv.z
			+ rim_color * rim * rim_strength
			+ texture(emission_texture, UV).rgb * emission_energy;
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
	if (trim_highlight > 0.0) {
		vec3 half_dir = normalize(normalize(VIEW) + light_dir);
		float blinn = pow(max(dot(normal, half_dir), 0.0), mix(4.0, 96.0, trim_gloss));
		float highlight = smoothstep(0.45 - band_softness, 0.45 + band_softness, blinn * ATTENUATION);
		// Intensity only: the warm battle key would tint pale hair/trim tan.
		SPECULAR_LIGHT += trim_highlight_color * highlight * trim_highlight * trim_region * clamp(peak * light_response, 0.0, 1.0);
	}
}
