shader_type spatial;
// 金钱套：棋子周围落下的金币（11.04，Leno：「金币在棋子周围下，10 个档，金币随档提升」）。
// MultiMesh 每个实例一枚金币：朝相机的面片，按 INSTANCE_CUSTOM.x（翻转相位）横向收窄 = 在空中翻转；
// INSTANCE_CUSTOM.y = 透明度。金币按左上光源分亮暗两半（切面），方孔、淡边，和场景低多边形一致。
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

// 金色压深：备战 3D 的提亮 + Filmic 会把浅金冲成白（第一版实拍像白色小圈）
uniform vec4 c_edge : source_color = vec4(0.36, 0.18, 0.0, 1.0);
uniform vec4 c_main : source_color = vec4(0.88, 0.55, 0.04, 1.0);
uniform vec4 c_lit : source_color = vec4(1.0, 0.80, 0.22, 1.0);
uniform float fade = 0.0;

varying float v_spin;
varying float v_alpha;

void vertex() {
	v_spin = INSTANCE_CUSTOM.x;
	v_alpha = INSTANCE_CUSTOM.y;
	float sx = length(MODEL_MATRIX[0].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * sx, INV_VIEW_MATRIX[1] * sx, INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	vec2 q = (UV - 0.5) * 2.0;
	float c = cos(v_spin);
	float squash = max(abs(c), 0.12);              // 翻到侧面时剩一条细边
	vec2 p = vec2(q.x / squash, q.y);
	float r = length(p);
	float aa = fwidth(r) * 1.5 + 0.02;
	float disc = 1.0 - smoothstep(0.92 - aa, 0.92, r);
	if (disc <= 0.001) {
		discard;
	}
	float hole = 1.0 - smoothstep(0.16, 0.16 + aa, max(abs(p.x), abs(p.y)));
	// 切面：朝左上的一半亮（翻到背面时左右对调）
	float side = (p.x * sign(c) * -0.6 + p.y * -0.8) > 0.0 ? 1.0 : 0.0;
	vec3 face = mix(c_main.rgb, c_lit.rgb, side);
	float rim = smoothstep(0.70, 0.80, r);
	vec3 col = mix(face, c_edge.rgb, rim * 0.75);
	col = mix(col, c_edge.rgb, hole);
	// 翻到正面朝相机的一瞬间闪一下
	col = mix(col, vec3(1.0, 0.95, 0.70), pow(abs(c), 24.0) * 0.45);
	ALBEDO = col;
	ALPHA = disc * (1.0 - hole * 0.85) * v_alpha * fade;
}
