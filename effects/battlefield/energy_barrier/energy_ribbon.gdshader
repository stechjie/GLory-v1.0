shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled, skip_vertex_transform;

// 一根流动能量丝。网格只是一条细分过的 QuadMesh（UV.x = 沿长度 0..1，UV.y = 两条边），
// 形状完全在这里按参数算：从左柱子里出来，高低起伏、左右编织，再钻进右柱子。
// 条带在观察空间里横向撑开，所以从任何角度看都是一根有宽度的线，不会变成一张片。
//
// 为什么要左右编织（weave_*）：战斗相机是沿着分路方向往里看的，墙所在的竖直面
// 在屏幕上几乎压成一条线，只靠高低起伏的几根丝在游戏里会叠成同一条线。

// 这一组由根节点 EnergyBarrierSegment 写入（别在这里改）。根节点的亮度 / 速度是乘在本层数值上的倍数；
// 只有根节点勾了「统一颜色」(unify_color) 才用 root_color，否则用下面本层自己的 color。
group_uniforms set_by_root_node;
uniform bool use_root_color = false;
uniform vec3 root_color : source_color = vec3(0.30, 0.62, 1.0);
uniform float root_intensity = 1.0;
uniform float root_ribbon_speed = 1.0;
uniform float barrier_length = 6.0;
uniform float barrier_height = 0.7;
uniform float emphasis = 0.0;
// 多段错开相位用。
uniform float time_offset = 0.0;
group_uniforms;

// 本层自己的外观：在这里改，预览和战斗里都生效。
uniform vec3 color : source_color = vec3(0.30, 0.62, 1.0);
uniform float energy_intensity = 1.0;

// 每根丝自己的形状（高度都是 barrier_height 的比例）。
uniform float ribbon_seed = 0.0;
uniform float end_height = 0.75;
uniform float mid_height = 0.45;
uniform float wave_amp = 0.15;
uniform float wave_freq = 1.0;
uniform float weave_amp = 0.10;
uniform float weave_freq = 1.5;
uniform float sway_amp = 0.04;
uniform float speed_mul = 1.0;
// 世界单位的线宽（含外圈光晕）。
uniform float width = 0.045;

varying float v_u;
varying float v_across;

vec3 ribbon_point(float u, float t) {
	float uc = clamp(u, 0.0, 1.0);
	float e = pow(sin(PI * uc), 0.65);
	float ph = ribbon_seed * TAU;
	float y_mid = mid_height + wave_amp * sin(TAU * wave_freq * uc + ph);
	float y = mix(end_height, y_mid, e);
	y += sway_amp * sin(t * 1.7 * root_ribbon_speed * speed_mul + uc * 7.0 + ph * 3.0) * e;
	float x = weave_amp * sin(TAU * weave_freq * uc + ph + t * 0.8 * root_ribbon_speed * speed_mul) * e;
	return vec3(x, max(y, 0.06) * barrier_height, (uc - 0.5) * barrier_length);
}

void vertex() {
	float u = UV.x;
	float side = UV.y * 2.0 - 1.0;
	float t = TIME + time_offset;
	vec3 p = ribbon_point(u, t);
	vec3 tangent = ribbon_point(u + 0.004, t) - ribbon_point(u - 0.004, t);

	vec3 pv = (MODELVIEW_MATRIX * vec4(p, 1.0)).xyz;
	vec3 tv = normalize(mat3(MODELVIEW_MATRIX) * tangent);
	// 正交相机 PROJECTION_MATRIX[3][3] == 1，透视为 0。
	vec3 view_dir = PROJECTION_MATRIX[3][3] > 0.5 ? vec3(0.0, 0.0, -1.0) : normalize(pv);
	vec3 offset_dir = cross(tv, view_dir);
	float len = length(offset_dir);
	offset_dir = len > 0.0001 ? offset_dir / len : vec3(1.0, 0.0, 0.0);
	// 两端变细，像是从柱子里抽出来的。
	float taper = 0.55 + 0.45 * smoothstep(0.0, 0.12, min(u, 1.0 - u));
	VERTEX = pv + offset_dir * side * width * 0.5 * taper;
	NORMAL = vec3(0.0, 0.0, 1.0);
	v_u = u;
	v_across = side;
}

void fragment() {
	float t = TIME + time_offset;
	float a = abs(v_across);
	// 能量包：从一端流向另一端，头亮尾长，间距约 1.4 米。
	float s = v_u * barrier_length;
	float q = fract((s - t * root_ribbon_speed * speed_mul * 1.6) / 1.4 + ribbon_seed);
	float packet = smoothstep(0.45, 0.95, q) * (1.0 - smoothstep(0.95, 1.0, q));
	float shimmer = 0.5 + 0.5 * sin(s * 9.0 - t * 6.0 * root_ribbon_speed + ribbon_seed * 40.0);
	// 白芯 + 实色带 + 短柔边（理由见 energy_floor_line.gdshader 开头）。比地面线淡一档。
	float core = 1.0 - smoothstep(0.16 + 0.10 * packet, 0.30 + 0.12 * packet, a);
	float band = 1.0 - smoothstep(0.50, 0.68, a);
	float halo = pow(1.0 - a, 1.6) * 0.30;
	float intensity = clamp(energy_intensity * root_intensity, 0.0, 3.0);
	float whiten = clamp(core * (0.35 + 0.55 * packet + 0.2 * emphasis), 0.0, 1.0);
	vec3 tint = mix(use_root_color ? root_color : color, vec3(1.0), whiten) * (0.9 + 0.1 * shimmer + 0.2 * max(intensity - 1.0, 0.0));
	float alpha = max(max(core * 0.95, band * (0.62 + 0.25 * packet + 0.08 * shimmer)), halo);
	ALBEDO = tint;
	ALPHA = clamp(alpha * min(intensity, 1.0), 0.0, 1.0);
}
