shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 main_color : source_color = vec4(1.0, 0.98, 0.93, 1.0);
uniform float opacity = 0.0;
uniform float activation = 1.0;
uniform float age = 0.0;
varying float shield_height;
void vertex() {
    shield_height = VERTEX.y;
}
void fragment() {
    float sheen = 0.92 + 0.08 * sin(age * 2.4);
    float soft_edge = smoothstep(0.0, 0.42, UV.x) * (1.0 - smoothstep(0.58, 1.0, UV.x));
    float sweep = exp(-pow((shield_height - mod(age * 0.75, 1.5)) * 8.0, 2.0));
    ALBEDO = main_color.rgb;
    EMISSION = main_color.rgb * (0.25 + activation * 0.30);
    ALPHA = COLOR.a * soft_edge * opacity * sheen * (0.62 + 0.26 * activation + 0.12 * sweep) * main_color.a;
}
