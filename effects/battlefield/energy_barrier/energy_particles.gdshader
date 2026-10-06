shader_type particles;
render_mode disable_force;

// 两个 GPUParticles3D 共用的运动逻辑（mode 区分），要求节点 local_coords = true：
//   mode 0 = 竖向光柱：在线上随机位置冒出、不移动；高度随机，光柱本身的升起 / 淡出在绘制 shader 里做。
//   mode 1 = 漂浮粒子：约一半从地面线缓慢往上飘，另一半沿段长方向顺着光带流动。
// 写给绘制 shader 的 CUSTOM：x = 种类（0 上飘 / 1 顺流），y = 已活比例，z = 大小或高度系数，w = 寿命上限（0..1）。

uniform int mode = 1;
// 这一组由根节点 EnergyBarrierSegment 写入（别在这里改）。
group_uniforms set_by_root_node;
uniform float barrier_length = 6.0;
uniform float barrier_height = 0.7;
uniform float root_ribbon_speed = 1.0;
group_uniforms;

uint hash_u(uint x) {
	x = ((x >> 16u) ^ x) * 73244475u;
	x = ((x >> 16u) ^ x) * 73244475u;
	return (x >> 16u) ^ x;
}

float rnd(inout uint s) {
	s = hash_u(s);
	return float(s % 1000003u) / 1000003.0;
}

void start() {
	uint s = hash_u(NUMBER * 7919u + RANDOM_SEED);
	float half_len = max(barrier_length * 0.5 - 0.3, 0.1);
	vec3 pos = vec3(0.0);
	vec3 vel = vec3(0.0);
	vec4 custom = vec4(0.0);
	float track_phase = rnd(s) * 6.283;
	if (mode == 0) {
		pos.z = (rnd(s) * 2.0 - 1.0) * half_len;
		custom = vec4(0.0, 0.0, mix(0.45, 1.0, rnd(s)), mix(0.65, 1.0, rnd(s)));
	} else {
		float kind = rnd(s) < 0.45 ? 1.0 : 0.0;
		pos.z = (rnd(s) * 2.0 - 1.0) * half_len;
		if (kind < 0.5) {
			pos.x = (rnd(s) - 0.5) * 0.14;
			pos.y = 0.03 + rnd(s) * 0.15 * barrier_height;
			vel = vec3((rnd(s) - 0.5) * 0.05, mix(0.10, 0.22, rnd(s)) * barrier_height, (rnd(s) - 0.5) * 0.08);
		} else {
			vel.z = mix(0.35, 0.65, rnd(s)) * max(root_ribbon_speed, 0.05);
		}
		custom = vec4(kind, 0.0, mix(0.6, 1.0, rnd(s)), mix(0.55, 1.0, rnd(s)));
	}
	if (RESTART_POSITION) {
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = pos;
		TRANSFORM = EMISSION_TRANSFORM * TRANSFORM;
	}
	if (RESTART_VELOCITY) {
		VELOCITY = (EMISSION_TRANSFORM * vec4(vel, 0.0)).xyz;
	}
	if (RESTART_CUSTOM) {
		CUSTOM = custom;
	}
	COLOR = vec4(track_phase, 0.0, 0.0, 1.0);
}

void process() {
	CUSTOM.y += DELTA / LIFETIME;
	if (mode == 1 && CUSTOM.x > 0.5) {
		// 顺流粒子贴着一条起伏的轨道走，和光带的高度区间一致。
		float z = TRANSFORM[3].z;
		float ph = COLOR.r;
		TRANSFORM[3].y = barrier_height * (0.45 + 0.20 * sin(z * 1.4 + ph));
		TRANSFORM[3].x = 0.08 * sin(z * 2.1 + ph * 1.7);
		if (abs(z) > barrier_length * 0.5 - 0.15) {
			ACTIVE = false;
		}
	}
	if (CUSTOM.y > CUSTOM.w) {
		ACTIVE = false;
	}
}
