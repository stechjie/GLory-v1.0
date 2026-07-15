shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, specular_disabled;

uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_texture = false;
uniform vec4 shadow_color : source_color = vec4(0.48, 0.58, 0.50, 1.0);
uniform float shadow_steps : hint_range(2.0, 4.0, 1.0) = 3.0;
uniform float light_threshold : hint_range(0.05, 0.95) = 0.52;
uniform vec4 rim_color : source_color = vec4(0.75, 0.92, 1.0, 1.0);
uniform float rim_strength : hint_range(0.0, 1.0) = 0.10;
uniform float rim_power : hint_range(0.5, 8.0) = 3.0;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_strength : hint_range(0.0, 6.0) = 0.0;

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	vec4 base = use_texture ? tex * albedo_color : albedo_color;
	ALBEDO = base.rgb;
	ALPHA = base.a;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	float rim = pow(1.0 - max(dot(normalize(NORMAL), normalize(VIEW)), 0.0), rim_power);
	EMISSION = emission_color.rgb * emission_strength + rim_color.rgb * rim * rim_strength;
}

void light() {
	float ndotl = max(dot(NORMAL, LIGHT), 0.0);
	float stepped = floor(clamp(ndotl / max(light_threshold, 0.001), 0.0, 1.0) * shadow_steps) / max(shadow_steps - 1.0, 1.0);
	vec3 toon_light = mix(shadow_color.rgb, vec3(1.0), stepped);
	DIFFUSE_LIGHT += ALBEDO * toon_light * LIGHT_COLOR * ATTENUATION;
}