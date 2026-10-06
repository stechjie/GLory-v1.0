shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

// 柱子上的能量发生器：顶上的低模水晶 + 柱身的发光细槽，同一张网格。
// 顶点色：r = 这一面的明暗（做出切面感），a = 1 表示属于水晶（会慢慢自转、上下浮动），槽是 0。
// 不透明，不加光晕，不额外叠透明面。

// 这一组由根节点 EnergyBarrierSegment 写入（别在这里改）。根节点的亮度 / 速度是乘在本层数值上的倍数；
// 只有根节点勾了「统一颜色」(unify_color) 才用 root_color，否则用下面本层自己的 color。
group_uniforms set_by_root_node;
uniform bool use_root_color = false;
uniform vec3 root_color : source_color = vec3(0.30, 0.62, 1.0);
uniform float root_intensity = 1.0;
uniform float root_pulse_speed = 1.0;
group_uniforms;

// 本层自己的外观：在这里改，预览和战斗里都生效。
uniform vec3 color : source_color = vec3(0.30, 0.62, 1.0);
uniform float energy_intensity = 1.0;
uniform float pulse_speed = 1.0;

void vertex() {
	if (COLOR.a > 0.5) {
		float a = TIME * 0.5;
		mat2 rot = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a)));
		VERTEX.xz = rot * VERTEX.xz;
		NORMAL.xz = rot * NORMAL.xz;
		VERTEX.y += sin(TIME * 1.3) * 0.015;
	}
}

void fragment() {
	float pulse = 0.88 + 0.12 * sin(TIME * 2.1 * pulse_speed * root_pulse_speed);
	float facet = COLOR.r;
	vec3 col = use_root_color ? root_color : color;
	vec3 deep = col * 0.55;
	vec3 bright = mix(col, vec3(1.0), 0.55);
	ALBEDO = mix(deep, bright, facet) * pulse * clamp(energy_intensity * root_intensity, 0.0, 1.6);
}
