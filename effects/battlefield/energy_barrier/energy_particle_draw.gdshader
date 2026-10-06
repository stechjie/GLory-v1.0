shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled, skip_vertex_transform;

// 竖向光柱和漂浮粒子的绘制（两个 GPUParticles3D 共用，beam_mode 区分）。
// 网格是 1×1 的 QuadMesh，运动和 CUSTOM 的含义见 energy_particles.gdshader。
//   光柱：绕竖直轴面向镜头的细条，从地面往上长出来，然后淡出、熄灭，等下一次随机重生。
//   粒子：完全面向镜头的小光点，淡入淡出、轻微闪烁。

// 这一组由根节点 EnergyBarrierSegment 写入（别在这里改）。根节点的亮度 / 速度是乘在本层数值上的倍数；
// 只有根节点勾了「统一颜色」(unify_color) 才用 root_color，否则用下面本层自己的 color。
group_uniforms set_by_root_node;
uniform bool use_root_color = false;
uniform vec3 root_color : source_color = vec3(0.30, 0.62, 1.0);
uniform float root_intensity = 1.0;
// 竖光最高高度 = 柱子高度 × 1.05。
uniform float beam_height = 0.75;
group_uniforms;

// 本层自己的外观：在这里改，预览和战斗里都生效。
uniform vec3 color : source_color = vec3(0.30, 0.62, 1.0);
uniform float energy_intensity = 1.0;
uniform bool beam_mode = false;
uniform float beam_width = 0.07;
uniform float spark_size = 0.07;

varying float v_fade;

void vertex() {
	float life = clamp(INSTANCE_CUSTOM.y / max(INSTANCE_CUSTOM.w, 0.001), 0.0, 1.0);
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 world;
	if (beam_mode) {
		vec3 up = vec3(0.0, 1.0, 0.0);
		vec3 right = cross(up, INV_VIEW_MATRIX[2].xyz);
		right = length(right) > 0.0001 ? normalize(right) : INV_VIEW_MATRIX[0].xyz;
		float grow = smoothstep(0.0, 0.22, life);
		float h = beam_height * INSTANCE_CUSTOM.z * grow;
		world = center + right * VERTEX.x * beam_width + up * (VERTEX.y + 0.5) * h;
		v_fade = smoothstep(0.0, 0.08, life) * (1.0 - smoothstep(0.30, 0.70, life));
	} else {
		float size = spark_size * INSTANCE_CUSTOM.z;
		world = center + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * size;
		float twinkle = 0.75 + 0.25 * sin(TIME * 9.0 + float(INSTANCE_ID) * 2.3);
		v_fade = sin(PI * life) * twinkle;
	}
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	// 白芯 + 实色带 + 短柔边（理由见 energy_floor_line.gdshader 开头）。
	float alpha;
	float whiten;
	if (beam_mode) {
		float a = abs(UV.x * 2.0 - 1.0);
		float up = 1.0 - UV.y;
		float core = 1.0 - smoothstep(0.12, 0.26, a);
		float band = 1.0 - smoothstep(0.34, 0.55, a);
		float halo = pow(1.0 - a, 2.0) * 0.25;
		// 底部最实，往上逐渐变淡，顶端收成尖。
		float vertical = (1.0 - smoothstep(0.35, 1.0, up));
		alpha = max(max(core * 0.95, band * 0.7), halo) * vertical * v_fade;
		whiten = core * (0.55 + 0.4 * (1.0 - up));
	} else {
		float r = length(UV * 2.0 - 1.0);
		float core = 1.0 - smoothstep(0.18, 0.34, r);
		float band = 1.0 - smoothstep(0.45, 0.62, r);
		float halo = pow(max(1.0 - r, 0.0), 2.0) * 0.3;
		alpha = max(max(core, band * 0.8), halo) * v_fade;
		whiten = core * 0.8;
	}
	float intensity = clamp(energy_intensity * root_intensity, 0.0, 3.0);
	ALBEDO = mix(use_root_color ? root_color : color, vec3(1.0), clamp(whiten, 0.0, 1.0)) * (1.0 + 0.2 * max(intensity - 1.0, 0.0));
	ALPHA = clamp(alpha * min(intensity, 1.0), 0.0, 1.0);
}
