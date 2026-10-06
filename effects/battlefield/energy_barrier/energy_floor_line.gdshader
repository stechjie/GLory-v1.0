shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// 底部能量线：贴在地面上的一条窄长条（PlaneMesh，节点缩放成「线宽 × 1 × 段长」）。
// 整段护栏里最亮的一层：白芯 + 饱和色带 + 短柔边，整体呼吸、沿线流动的亮脉冲、偶发小电弧。
// UV.x 横跨线宽，UV.y 沿段长。
//
// 为什么不用加色混合：战斗的 3D 层是透明底、叠在 2D 战场图上的，这一层里加色光和
// 半透明光晕会被吃掉大半（透明度为 0 的加色完全看不见）。卡通式的「白芯 + 实色带」
// 接近不透明，在电脑和手机两种渲染器里都能原样显示，也更贴合低模卡通风。

// 这一组由根节点 EnergyBarrierSegment 写入（别在这里改）。根节点的亮度 / 速度是乘在本层数值上的倍数；
// 只有根节点勾了「统一颜色」(unify_color) 才用 root_color，否则用下面本层自己的 color。
group_uniforms set_by_root_node;
uniform bool use_root_color = false;
uniform vec3 root_color : source_color = vec3(0.30, 0.62, 1.0);
uniform float root_intensity = 1.0;
uniform float root_pulse_speed = 1.0;
uniform float barrier_length = 6.0;
// 开场强调：1 = 刚出现时更亮更宽，脚本在 0.85 秒内把它降到 0。
uniform float emphasis = 0.0;
// 多段错开相位用（play_loop 的 start_frame 换算过来）。
uniform float time_offset = 0.0;
group_uniforms;

// 本层自己的外观：在这里改，预览和战斗里都生效。
uniform vec3 color : source_color = vec3(0.30, 0.62, 1.0);
uniform float energy_intensity = 1.0;
uniform float pulse_speed = 1.0;
// 中央白线的强度：0 = 没有白线，只剩色带；1 = 原来那条白芯。
uniform float core_amount : hint_range(0.0, 1.0) = 0.0;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

// 分段线性噪声：拿来画电弧的折线。
float zigzag(float x) {
	float i = floor(x);
	return mix(hash11(i), hash11(i + 1.0), fract(x)) - 0.5;
}

void fragment() {
	float across = UV.x * 2.0 - 1.0;
	float a = abs(across);
	float along = UV.y * barrier_length;
	float t = TIME + time_offset;
	float pspeed = pulse_speed * root_pulse_speed;
	float breath = 0.5 + 0.5 * sin(t * 2.1 * pspeed);

	// 沿线跑的亮脉冲：间距约 2.8 米，头亮尾长。
	float phase = fract(along * 0.36 - t * 0.55 * pspeed);
	float pulse = smoothstep(0.55, 0.93, phase) * (1.0 - smoothstep(0.93, 1.0, phase));

	// 小电弧：每个时间槽在随机位置闪一下（只占槽的前 12%），槽内再快速明灭。
	float rate = 0.65 * max(pspeed, 0.05);
	float slot_time = t * rate;
	float slot = floor(slot_time);
	float show = 1.0 - smoothstep(0.05, 0.12, fract(slot_time));
	float flicker = step(0.35, hash11(floor(t * 38.0) + slot));
	float center = (0.1 + 0.8 * hash11(slot * 7.13 + 1.7)) * barrier_length;
	float span = 0.30 + 0.25 * hash11(slot * 3.1 + 0.4);
	float d = (along - center) / span;
	float arc_env = max(1.0 - d * d, 0.0);
	float offset = zigzag(along * 16.0 + slot * 5.0) * 0.9 * arc_env;
	float arc = (1.0 - smoothstep(0.03, 0.07, abs(across - offset))) * arc_env * show * flicker;

	// 呼吸和脉冲都体现在色带宽度和亮度上，不整面闪。
	float band_w = 0.17 + 0.04 * breath + 0.07 * pulse + 0.08 * emphasis;
	float core = (1.0 - smoothstep(0.045, 0.085, a)) * core_amount;
	float band = 1.0 - smoothstep(band_w, band_w + 0.09, a);
	float halo = pow(1.0 - a, 2.2) * (0.22 + 0.10 * breath + 0.15 * emphasis);

	// 两端收进柱子底下，别在柱子外面露一截硬边。
	float ends = smoothstep(0.0, 0.18, along) * smoothstep(0.0, 0.18, barrier_length - along);

	float intensity = clamp(energy_intensity * root_intensity, 0.0, 3.0);
	float whiten = clamp(core * (0.75 + 0.25 * pulse) + arc * 0.8 + band * pulse * 0.25, 0.0, 1.0);
	vec3 tint = mix(use_root_color ? root_color : color, vec3(1.0), whiten);
	tint *= 0.85 + 0.15 * breath + 0.2 * max(intensity - 1.0, 0.0);
	ALBEDO = tint;
	ALPHA = clamp(max(max(core, band * 0.9), max(halo, arc)) * ends * min(intensity, 1.0), 0.0, 1.0);
}
