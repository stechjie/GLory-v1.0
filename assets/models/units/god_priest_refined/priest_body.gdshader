shader_type spatial;
render_mode cull_back, ambient_light_disabled;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
void fragment() {
 vec3 tex = texture(albedo_texture, UV).rgb;
 // Keep atlas colours and facial marks; separate warm embroidery from white silk.
 float gold = smoothstep(0.035, 0.19, tex.r - tex.b) * smoothstep(0.13, 0.40, tex.r);
 ALBEDO = mix(tex, tex * vec3(1.03, 0.94, 0.78), gold * 0.42);
 ROUGHNESS = mix(0.85, 0.38, gold);
 SPECULAR = 0.0;
 EMISSION = ALBEDO * vec3(0.49, 0.53, 0.60);
}
void light() {
 float ndl = max(dot(normalize(NORMAL),normalize(LIGHT)),0.0);
 float peak = max(max(LIGHT_COLOR.r,LIGHT_COLOR.g),LIGHT_COLOR.b);
 vec3 tint = LIGHT_COLOR/max(peak,0.001)*min(peak,1.0);
 DIFFUSE_LIGHT += tint * smoothstep(-0.15,0.85,ndl) * 0.52 * ATTENUATION;
 float gold = smoothstep(0.035,0.19, ALBEDO.r-ALBEDO.b);
 float spec = pow(max(dot(normalize(NORMAL),normalize(LIGHT+VIEW)),0.0),32.0);
 SPECULAR_LIGHT += tint * spec * gold * 0.12 * ATTENUATION;
}
