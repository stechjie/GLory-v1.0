// 法阵友军身上的火（CPUParticles3D 面片），构造参考 pixelfx（MIT）的 fire/_lib.js：
//   - 火舌 = 4 层由外到内套叠（暗边 / 主色 / 亮色 / 白热芯），每层更窄更矮；
//   - 每层的半宽和中心按「高度 + 时间」的值噪声逐行抖动，噪声随时间往上滚，
//     轮廓是会跳的不规则火苗，而不是整根规整的刺；
//   - 整体高度按两个频率的噪声闪烁（0.74 + 0.16·N1 + 0.1·N2）；
//   - puff 模式：脱离火舌往上飘的圆火团 / 火星，随寿命沿色阶冷却（白→黄→主色→暗边）。
// 画风保持平涂扁平、边缘平滑，不做像素化、不做切面。没有贴图，全程序化。
// 火舌模式下 COLOR.a = 寿命饱满度（火舌随它收窄变矮，不变透明）；
// puff 模式下 COLOR.a = 热度（1 → 0）。COLOR.rgb 不用，颜色全来自 uniform。
shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 core_color : source_color = vec4(1.0, 0.92, 0.6, 1.0);
uniform vec4 mid_color : source_color = vec4(1.0, 0.45, 0.08, 1.0);
uniform vec4 edge_color : source_color = vec4(0.6, 0.08, 0.02, 1.0);
// 只给最里两层提亮，外层保持平涂
uniform float intensity : hint_range(0.0, 4.0) = 1.0;
uniform float sway : hint_range(0.0, 0.6) = 0.22;
uniform float sway_speed : hint_range(0.0, 8.0) = 2.4;
// 行抖动幅度（相对半宽）和往上滚的速度
uniform float edge_jitter : hint_range(0.0, 0.6) = 0.22;
uniform float edge_scroll : hint_range(0.0, 12.0) = 6.0;
uniform float rim_alpha : hint_range(0.0, 1.0) = 0.85;
// 火舌最多偏离屏幕竖直方向多少（弧度）
uniform float max_lean : hint_range(0.0, 1.5) = 0.75;
uniform bool puff = false;
// 分遍画层：脚本把同一材质复制成 外边 / 主色 / 亮芯 三遍（next_pass + render_priority 递增），
// 先画完所有火舌的外边再画主色、亮芯，相邻火舌的暗边就不会盖到别人的亮芯上。
uniform int layer_from : hint_range(0, 3) = 0;
uniform int layer_to : hint_range(0, 3) = 3;

varying float v_seed;

const float LAYER_W[4] = float[](1.0, 0.76, 0.54, 0.30);
const float LAYER_H[4] = float[](1.0, 0.86, 0.68, 0.42);

float hash11(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

// 平滑值噪声，-1..1
float vn(float x) {
	float i = floor(x);
	float f = fract(x);
	float u = f * f * (3.0 - 2.0 * f);
	return mix(hash11(i), hash11(i + 1.0), u) * 2.0 - 1.0;
}

vec3 layer_color(int i) {
	if (i == 0) {
		return edge_color.rgb;
	} else if (i == 1) {
		return mid_color.rgb;
	} else if (i == 2) {
		return mix(mid_color.rgb, core_color.rgb, 0.6) * mix(1.0, intensity, 0.5);
	}
	return mix(core_color.rgb, vec3(1.0), 0.45) * intensity;
}

void vertex() {
	vec3 origin_vs = (VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0)).xyz;
	// align_y 在速度接近 0 时会把 Y 轴压扁，所以尺寸只认 X 轴的缩放
	float s = length(MODEL_MATRIX[0].xyz);
	vec3 ydir_ws = MODEL_MATRIX[1].xyz;
	vec2 up_vs = vec2(0.0, 1.0);
	vec2 proj = (VIEW_MATRIX * vec4(ydir_ws, 0.0)).xy;
	if (!puff && length(proj) > 0.0001 * max(s, 0.0001)) {
		float ang = atan(proj.x, proj.y);   // 0 = 屏幕正上
		ang = clamp(ang, -max_lean, max_lean);
		up_vs = vec2(sin(ang), cos(ang));
	}
	vec2 right_vs = vec2(up_vs.y, -up_vs.x);
	MODELVIEW_MATRIX = mat4(
		vec4(right_vs * s, 0.0, 0.0),
		vec4(up_vs * s, 0.0, 0.0),
		vec4(0.0, 0.0, s, 0.0),
		vec4(origin_vs, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(1.0);
	v_seed = hash11(float(INSTANCE_ID) * 0.618 + floor(MODEL_MATRIX[3].x * 7.0) * 0.13);
}

void fragment() {
	float seed = v_seed * 37.0;
	if (puff) {
		// 圆火团：边缘按角度轻微起伏；外圈 + 内芯两层，颜色随热度沿色阶往下走
		float heat = clamp(COLOR.a, 0.0, 1.0);
		// puff 用居中的正方形面片
		vec2 q = UV * 2.0 - 1.0;
		float ang = atan(q.y, q.x);
		float r = length(q) / 0.9 * (1.0 + 0.1 * vn(ang * 1.6 + TIME * 5.0 + seed));
		float aa = clamp(fwidth(r), 0.001, 0.2) * 1.2;
		float m = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);
		if (m <= 0.001) {
			discard;
		}
		// 不画暗边（会像泡泡）：热时亮色 + 白芯，冷了只剩主色，再靠缩小熄灭
		float hot = step(0.55, heat);
		// 白芯只在刚脱离的一小段，否则一颗颗像光球
		float inner = (1.0 - smoothstep(0.42 - aa, 0.42 + aa, r)) * step(0.82, heat);
		vec3 col = mix(layer_color(1), layer_color(2), hot);
		col = mix(col, layer_color(3), inner);
		ALBEDO = col;
		ALPHA = m;
	} else {
		float life = clamp(COLOR.a, 0.0, 1.0);
		float x = UV.x * 2.0 - 1.0;   // -1 左 .. 1 右
		float h = 1.0 - UV.y;         // 0 根部 .. 1 尖
		// 闪烁：两个频率的噪声控制整体高度
		float flick = 0.74 + 0.16 * vn(TIME * 3.6 + seed) + 0.1 * vn(TIME * 9.5 + seed * 1.7);
		float top = mix(0.4, 1.0, life) * mix(0.82, 1.1, flick);
		float hh = h / top;
		if (hh < 0.0 || hh > 1.0) {
			discard;
		}
		// 整根按相位摆动（波从根部往尖端传）+ 中心线噪声游走（越往上越明显）
		float t = TIME * sway_speed + v_seed * 6.2832;
		float bend = sway * hh * hh * sin(t - hh * 2.6)
			+ 0.12 * hh * vn(hh * 2.5 - TIME * 3.0 + seed);
		float cx = x - bend;
		float width_scale = mix(0.5, 1.0, life);
		vec3 col = vec3(0.0);
		float alpha = 0.0;
		for (int i = 0; i < 4; i++) {
			if (i > layer_to) {
				break;
			}
			if (i < layer_from) {
				continue;
			}
			float lhh = hh / LAYER_H[i];
			if (lhh > 1.0) {
				break;
			}
			float fi = float(i);
			// 行抖动：噪声随高度变化、随时间往上滚，每层用不同相位
			float jit = edge_jitter * vn(lhh * 7.0 - TIME * edge_scroll + seed + fi * 3.7);
			float half_w = 0.80 * LAYER_W[i] * width_scale
				* pow(max(1.0 - lhh, 0.0), 0.85)
				* sqrt(clamp(lhh / 0.24, 0.0, 1.0))
				* (1.0 + jit);
			// 内层中心再各自游走一点，层与层不完全同心
			float lc = cx - 0.06 * fi * lhh * vn(TIME * 2.2 + fi * 2.1 + seed);
			float d = abs(lc) / max(half_w, 0.0001);
			float aa = clamp(fwidth(d), 0.001, 0.15) * 1.2;
			float m = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, d);
			if (i == layer_from) {
				alpha = m * (i == 0 ? rim_alpha : 1.0);
				col = layer_color(i);
			} else {
				col = mix(col, layer_color(i), m);
			}
		}
		if (alpha <= 0.001) {
			discard;
		}
		ALBEDO = col;
		ALPHA = alpha;
	}
}
