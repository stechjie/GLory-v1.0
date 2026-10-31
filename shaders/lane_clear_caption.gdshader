shader_type canvas_item;
// 清场字幕的一道横扫高光。只提亮字面（亮色像素），深色描边不动，
// 否则描边被扫成浅色，字反而糊。sweep < 0 时不扫。
uniform float sweep = -1.0;
uniform float extent_x = 900.0;
varying float local_x;

void vertex() {
	local_x = VERTEX.x;
}

void fragment() {
	float center = sweep * 1.3 - 0.15;
	float d = (local_x / extent_x - center) / 0.07;
	float band = exp(-d * d) * step(0.0, sweep);
	float lum = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	COLOR.rgb = mix(COLOR.rgb, vec3(1.0, 1.0, 0.94), band * smoothstep(0.35, 0.6, lum) * 0.9);
}
