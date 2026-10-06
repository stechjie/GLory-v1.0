shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// 段中央悬浮的菱形符文。一张始终面向镜头的 QuadMesh，图案全部程序生成（不用贴图、没有底板）：
// 外框菱形 + 内实心菱形 + 上下两颗小星，自身发光、缓慢上下浮动、呼吸明暗、偶尔扫过一道光。
// 节点缩放 = 符文尺寸。

// 这一组由根节点 EnergyBarrierSegment 写入（别在这里改）。根节点的亮度 / 速度是乘在本层数值上的倍数；
// 只有根节点勾了「统一颜色」(unify_color) 才用 root_color，否则用下面本层自己的 color。
group_uniforms set_by_root_node;
uniform bool use_root_color = false;
uniform vec3 root_color : source_color = vec3(0.30, 0.62, 1.0);
uniform float root_intensity = 1.0;
uniform float root_pulse_speed = 1.0;
uniform float emphasis = 0.0;
// 多段错开相位用。
uniform float time_offset = 0.0;
group_uniforms;

// 本层自己的外观：在这里改，预览和战斗里都生效。
uniform vec3 color : source_color = vec3(0.30, 0.62, 1.0);
uniform float energy_intensity = 1.0;
uniform float pulse_speed = 1.0;
// 世界单位的上下浮动幅度。
uniform float float_amount = 0.05;

void vertex() {
	float bob = sin((TIME + time_offset) * 1.1 * max(pulse_speed * root_pulse_speed, 0.05)) * float_amount;
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	mat4 billboard = mat4(
		vec4(normalize(INV_VIEW_MATRIX[0].xyz) * scale.x, 0.0),
		vec4(normalize(INV_VIEW_MATRIX[1].xyz) * scale.y, 0.0),
		vec4(normalize(INV_VIEW_MATRIX[2].xyz) * scale.z, 0.0),
		MODEL_MATRIX[3] + vec4(0.0, bob, 0.0, 0.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

float diamond(vec2 p, float aspect) {
	return abs(p.x) / aspect + abs(p.y);
}

void fragment() {
	float t = TIME + time_offset;
	vec2 p = UV * 2.0 - 1.0;
	float d = diamond(p, 0.62);
	float breath = 0.5 + 0.5 * sin(t * 1.6 * max(pulse_speed * root_pulse_speed, 0.05));
	// 外框：白芯 + 色带。框内是一层深色底，战斗视角里符文正好叠在同色的能量线上，
	// 没有这层深色就分不出来。
	float ring_d = abs(d - 0.80);
	float ring_core = 1.0 - smoothstep(0.035, 0.06, ring_d);
	float ring_band = 1.0 - smoothstep(0.09, 0.13, ring_d);
	float body = 1.0 - smoothstep(0.76, 0.80, d);
	// 内实心菱形：中心发白、边缘一圈亮线。
	float inner = 1.0 - smoothstep(0.40, 0.45, d);
	float inner_hot = 1.0 - smoothstep(0.0, 0.32, d);
	float inner_edge = 1.0 - smoothstep(0.02, 0.045, abs(d - 0.42));
	// 上下两颗四角小星，贴在外框尖端外侧。
	float stars = 0.0;
	for (int i = 0; i < 2; i++) {
		vec2 c = vec2(0.0, i == 0 ? 0.95 : -0.95);
		vec2 q = abs(p - c);
		stars += exp(-q.x * 50.0) * exp(-q.y * 12.0) + exp(-q.y * 50.0) * exp(-q.x * 12.0);
	}
	stars = clamp(stars, 0.0, 1.0);
	float halo = (1.0 - smoothstep(0.0, 1.0, d)) * (0.18 + 0.14 * breath + 0.2 * emphasis);
	// 斜向扫光：大约每 3.5 秒扫过一次。
	float sweep_pos = fract(t * 0.28) * 3.2 - 1.6;
	float sweep = (1.0 - smoothstep(0.0, 0.16, abs(p.x * 0.6 + p.y - sweep_pos))) * max(ring_band, inner);

	float lit = max(ring_band, inner);
	float shape = max(max(lit, body * 0.78), stars * 0.9);
	float whiten = clamp(ring_core * 0.85 + inner_hot * (0.45 + 0.35 * breath) + inner_edge * 0.75 + stars * 0.6 + sweep * 0.7 + emphasis * 0.3, 0.0, 1.0);
	float intensity = clamp(energy_intensity * root_intensity, 0.0, 3.0);
	float fade_edge = 1.0 - smoothstep(0.9, 1.0, max(abs(p.x), abs(p.y)));
	vec3 col = use_root_color ? root_color : color;
	vec3 base = mix(col * 0.26, col, max(lit, stars));
	ALBEDO = mix(base, vec3(1.0), whiten) * (1.0 + 0.2 * max(intensity - 1.0, 0.0));
	ALPHA = clamp(max(shape, halo * (1.0 - body)) * fade_edge * min(intensity, 1.0), 0.0, 1.0);
}
