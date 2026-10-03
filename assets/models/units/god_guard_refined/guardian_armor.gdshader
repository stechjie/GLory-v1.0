// Vertex-painted ivory, aged gold, and small crystal inlays. One material
// for all crafted parts; no alpha queue, screen sampling, or bloom required.
shader_type spatial;
render_mode depth_draw_opaque, cull_back, ambient_light_disabled;
varying float metal_region;
varying float crystal_region;
void fragment() {
    ALBEDO = COLOR.rgb;
    metal_region = smoothstep(0.1, 0.3, COLOR.r - COLOR.b);
    crystal_region = smoothstep(0.1, 0.3, COLOR.b - COLOR.r);
    METALLIC = 0.0;
    SPECULAR = 0.0;
    ROUGHNESS = 0.4;
    EMISSION = ALBEDO * vec3(0.50, 0.52, 0.56) + crystal_region * ALBEDO * 0.08;
}
void light() {
    vec3 n = normalize(NORMAL);
    float peak = max(max(LIGHT_COLOR.r, LIGHT_COLOR.g), LIGHT_COLOR.b);
    vec3 tint = mix(vec3(1.0), LIGHT_COLOR / max(peak, 0.001), 0.25);
    float ndl = max(dot(n, normalize(LIGHT)), 0.0);
    float diffuse = mix(smoothstep(0.0, 0.85, ndl), smoothstep(0.23, 0.5, ndl), 0.2);
    DIFFUSE_LIGHT += diffuse * tint * ATTENUATION * 0.74;
    float highlight = pow(max(dot(n, normalize(normalize(LIGHT) + normalize(VIEW))), 0.0), 56.0);
    SPECULAR_LIGHT += mix(vec3(0.72,0.80,0.91), vec3(1.0,0.79,0.44), metal_region) * highlight * mix(0.16,0.55,metal_region) * ATTENUATION;
}
