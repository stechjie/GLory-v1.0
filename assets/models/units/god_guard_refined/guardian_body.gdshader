// Character-local material. Original shared character toon remains untouched.
shader_type spatial;
render_mode depth_draw_opaque, cull_back, ambient_light_disabled;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec3 shadow_tint : source_color = vec3(0.48, 0.53, 0.64);
uniform float specular_strength = 0.28;
varying float gold_region;
void fragment() {
    vec3 tex = texture(albedo_texture, UV).rgb;
    gold_region = smoothstep(0.025, 0.16, tex.r - tex.b) * smoothstep(0.08, 0.3, tex.r);
    // Keep painted seams; reserve the darkest values for gaps rather than
    // multiplying another hard shadow boundary into every painted bevel.
    ALBEDO = mix(tex, sqrt(max(tex, vec3(0.0))), 0.16);
    METALLIC = 0.0;
    ROUGHNESS = 0.65;
    SPECULAR = 0.0;
    EMISSION = ALBEDO * shadow_tint * 0.8;
}
void light() {
    vec3 n = normalize(NORMAL);
    float ndl = max(dot(n, normalize(LIGHT)), 0.0);
    float shade = mix(smoothstep(0.04, 0.66, ndl), smoothstep(0.22, 0.42, ndl), 0.35);
    float peak = max(max(LIGHT_COLOR.r, LIGHT_COLOR.g), LIGHT_COLOR.b);
    vec3 tint = mix(vec3(1.0), LIGHT_COLOR / max(peak, 0.001), 0.3);
    DIFFUSE_LIGHT += tint * shade * ATTENUATION * 0.7;
    float spec = pow(max(dot(n, normalize(normalize(LIGHT) + normalize(VIEW))), 0.0), mix(48.0, 82.0, gold_region));
    SPECULAR_LIGHT += mix(vec3(0.7,0.8,0.9), vec3(1.0,0.79,0.38), gold_region) * spec * mix(0.08, specular_strength, gold_region) * ATTENUATION;
}
