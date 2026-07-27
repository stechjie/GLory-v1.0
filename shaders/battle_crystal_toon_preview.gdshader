shader_type spatial;
render_mode unshaded, cull_back;

uniform sampler2D albedo_texture : source_color;
uniform bool has_albedo_texture = false;
uniform vec4 shade_color : source_color = vec4(0.015, 0.12, 0.34, 1.0);
uniform vec4 body_color : source_color = vec4(0.02, 0.48, 0.84, 1.0);
uniform vec4 light_color : source_color = vec4(0.08, 0.82, 0.96, 1.0);
uniform vec4 glint_color : source_color = vec4(0.78, 0.98, 1.0, 1.0);
uniform vec4 rim_color : source_color = vec4(0.10, 0.72, 0.94, 1.0);
uniform vec4 tip_color : source_color = vec4(0.55, 0.95, 1.0, 1.0);
uniform float hp_ratio : hint_range(0.0, 1.0) = 1.0;
uniform float texture_influence : hint_range(0.0, 1.0) = 0.0;
uniform float rim_strength : hint_range(0.0, 1.0) = 0.16;
uniform float glint_strength : hint_range(0.0, 1.0) = 0.22;
// World-space vertical span of the crystal, feeding the base-to-tip gradient.
// World space rather than model space because the imported FBX has its own axis
// rotation baked in, so model-space Y does not point up.
uniform float gradient_base_y = 0.0;
uniform float gradient_height = 1.0;
uniform float gradient_strength : hint_range(0.0, 1.0) = 0.22;
// 被彩带命中时瞬间打亮，调用方拉到 1 再放回 0。
uniform float hit_flash : hint_range(0.0, 1.0) = 0.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 sampled_color = has_albedo_texture ? texture(albedo_texture, UV).rgb : vec3(1.0);
	vec3 view_dir = normalize(VIEW);
	// Flat per-facet normal derived from the screen-space derivatives of the view
	// position. This ignores the imported smooth normals so every facet reads as a
	// single solid block of color instead of a curved gradient band.
	vec3 face_cross = cross(dFdx(VERTEX), dFdy(VERTEX));
	vec3 facet_normal = length(face_cross) > 0.00000001 ? normalize(face_cross) : normalize(NORMAL);
	if (dot(facet_normal, view_dir) < 0.0) {
		facet_normal = -facet_normal;
	}
	vec3 key_dir = normalize(vec3(-0.42, 0.68, 0.60));
	float ndl = clamp(dot(facet_normal, key_dir), 0.0, 1.0);
	float facing = clamp(dot(facet_normal, view_dir), 0.0, 1.0);
	float rim = pow(1.0 - facing, 3.2);
	float glint = smoothstep(0.955, 0.992, dot(facet_normal, normalize(key_dir + view_dir)));

	vec3 palette = shade_color.rgb;
	if (ndl > 0.30) {
		palette = body_color.rgb;
	}
	if (ndl > 0.62) {
		palette = light_color.rgb;
	}
	if (ndl > 0.90) {
		palette = mix(light_color.rgb, glint_color.rgb, 0.32);
	}

	float source_value = dot(sampled_color, vec3(0.299, 0.587, 0.114));
	float painted_detail = mix(1.0, mix(0.82, 1.10, source_value), texture_influence);
	vec3 color = palette * painted_detail;

	// Base-to-tip gradient: deeper and more saturated at the root, lifted toward
	// the tip color at the top, matching the painted look of the reference art.
	float height_t = clamp((world_position.y - gradient_base_y) / max(gradient_height, 0.0001), 0.0, 1.0);
	vec3 base_tone = color * (1.0 - gradient_strength * 0.55);
	vec3 tip_tone = mix(color, tip_color.rgb, gradient_strength);
	color = mix(base_tone, tip_tone, height_t);

	float damage_stage = smoothstep(0.0, 0.82, hp_ratio);
	color = mix(color * 0.42, color, damage_stage);
	color += glint_color.rgb * glint * glint_strength;
	color += rim_color.rgb * rim * rim_strength;
	color = mix(color, mix(vec3(1.0), tip_color.rgb, 0.35), hit_flash * 0.6);
	ALBEDO = color;
}
