shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 main_color : source_color = vec4(1.0, 0.98, 0.93, 1.0);
uniform float opacity = 0.0;
uniform float age = 0.0;
uniform bool seal = false;
void fragment() {
    float edge = smoothstep(0.0, 0.17, UV.y) * (1.0 - smoothstep(0.72, 1.0, UV.y));
    float dash = step(0.22, fract(UV.x * (seal ? 12.0 : 40.0)));
    float orbit = pow(max(0.0, cos(UV.x * 6.283185 - age * 1.3)), 16.0);
    ALBEDO = main_color.rgb;
    EMISSION = main_color.rgb * (0.15 + orbit * 0.2);
    ALPHA = edge * dash * opacity * main_color.a;
}
