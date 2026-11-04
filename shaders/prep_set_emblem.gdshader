shader_type spatial;
// 备战棋子背后的套装虚影（11.04），一张朝相机的面片，图案全用距离场画：
//   mode 0 攻击：交叉双斧（Leno 11.04 给了参考图：伐木斧、柄在中心交叉成 X），轮流劈砍 + 红光 ——
//          劈下那一下红光猛亮、斧刃划过处留一道红色残影弧；
//   mode 3 元素：四色光柱（Leno 11.04 换的）—— 从脚下拔地而起、竖直，柱里飘对应元素的粒子；
//   mode 2 元素（旧方案，暂留对比）：四色水晶球 —— 切面球体、球里翻滚的能量按 火→冰→雷→毒 轮换，球外跳出对应元素的小特效；
//   mode 1 控制：一面钟盘（logo 4控制）—— 外环按朝光分亮暗、十二刻度、两根转动的指针、中心紫色菱形水晶。
// 「虚影」：整体半透明，外面一圈柔光；淡边，不描黑。棋子模型在它前面，深度测试自然把下半截挡住。
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

uniform int mode = 0;
uniform vec4 c_edge : source_color = vec4(0.22, 0.02, 0.04, 1.0);
uniform vec4 c_main : source_color = vec4(0.82, 0.10, 0.10, 1.0);
uniform vec4 c_lit : source_color = vec4(1.0, 0.50, 0.42, 1.0);
uniform vec4 c_white : source_color = vec4(1.0, 0.90, 0.86, 1.0);
uniform float fade = 0.0;
uniform float sway = 0.0;          // 战斧摆动角（弧度，绕握柄底部）
uniform float ghost = 0.82;        // 虚影整体透明度

void vertex() {
	// 朝相机的公告板（保留节点缩放）。mode 3 光柱只水平转向相机，柱身永远竖直。
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	if (mode == 99) {
		// （弃用）世界竖直公告板：俯视透视下高柱子会往两边歪，和矮棋子放一起很别扭 —— 光柱改用屏幕竖直
		vec3 cr = INV_VIEW_MATRIX[0].xyz;
		vec3 right = normalize(vec3(cr.x, 0.0, cr.z) + vec3(0.0001, 0.0, 0.0));
		vec3 up = vec3(0.0, 1.0, 0.0);
		vec3 fwd = cross(right, up);
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(right * sx, 0.0), vec4(up * sy, 0.0), vec4(fwd, 0.0), MODEL_MATRIX[3]);
	} else {
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * sx, INV_VIEW_MATRIX[1] * sy, INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
}

// 把形状的有符号距离（< 0 在里面）转成：填充覆盖、暗边覆盖
vec2 cover(float d) {
	float aa = max(fwidth(d), 0.002);
	float fill = 1.0 - smoothstep(-aa, aa, d + 0.02);
	float edge = 1.0 - smoothstep(-aa, aa, d);
	return vec2(fill, edge);
}

// 一把伐木斧的距离场（Leno 11.04 给的交叉双斧参考图）。局部坐标：柄沿 +y，柄尾在 y = 0，
// 斧头在顶上（y 约 1.25 ~ 1.78），刃口朝 +x 往外张开。
// 输出：d_head（斧头）、detail（白色细线：刃口内侧那道、柄上木纹、柄尾两道握把环）。
float axe_shape(vec2 p, out float d_head, out float detail) {
	// 柄：略往柄尾加粗
	float hw = mix(0.066, 0.052, clamp(p.y / 1.6, 0.0, 1.0));
	float d_handle = max(abs(p.x) - hw, max(-p.y, p.y - 1.66));
	// 斧头：靠柄那段是方块，往刃口上下张开（楔形）
	float x = p.x;
	float top = 1.70 + max(x - 0.10, 0.0) / 0.38 * 0.08;
	float bot = 1.46 - max(x - 0.06, 0.0) / 0.42 * 0.22;
	d_head = max(max(bot - p.y, p.y - top), max(-0.13 - x, x - 0.48));
	// 斧背小圆帽
	float d_poll = length(vec2(max(abs(x + 0.15) - 0.04, 0.0), max(abs(p.y - 1.64) - 0.05, 0.0))) - 0.035;
	d_head = min(d_head, d_poll);
	// 白色细线
	float edge_line = (1.0 - smoothstep(0.010, 0.022, abs(x - 0.40))) * step(d_head, 0.0);
	float grain = (1.0 - smoothstep(0.006, 0.014, abs(p.x - 0.012))) * step(0.30, p.y) * step(p.y, 1.30) * step(d_handle, 0.0);
	float bands = (1.0 - smoothstep(0.008, 0.018, min(abs(p.y - 0.10), abs(p.y - 0.17)))) * step(d_handle, 0.0);
	detail = max(edge_line, max(grain * 0.8, bands));
	return min(d_handle, d_head);
}

// 劈砍的角度曲线（一周期 = 1）：返回相对角度（正 = 往外举起，负 = 劈向中间），strike = 劈下那一下的强度 0~1。
// 0~0.55 慢慢举起（ease-out，蓄力）→ 0.55~0.68 极快劈下（ease-in）→ 0.68~0.80 冲过头回弹 → 0.80~1 回原位。
float chop_angle(float t, out float strike) {
	float u = fract(t);
	float ang = 0.0;
	strike = 0.0;
	if (u < 0.55) {
		float k = u / 0.55;
		ang = 0.55 * (1.0 - pow(1.0 - k, 3.0));
	} else if (u < 0.68) {
		float k = (u - 0.55) / 0.13;
		ang = mix(0.55, -0.50, k * k * k);
		strike = k;
	} else if (u < 0.80) {
		float k = (u - 0.68) / 0.12;
		ang = mix(-0.50, -0.32, 1.0 - pow(1.0 - k, 2.0));
		strike = 1.0 - k;
	} else {
		float k = (u - 0.80) / 0.20;
		ang = mix(-0.32, 0.0, k * k * (3.0 - 2.0 * k));
	}
	return ang;
}

vec3 elem_col(int i) {
	int k = i - (i / 4) * 4;
	if (k == 0) { return vec3(1.0, 0.36, 0.08); }      // 火
	if (k == 1) { return vec3(0.35, 0.72, 1.0); }      // 冰
	if (k == 2) { return vec3(1.0, 0.86, 0.20); }      // 雷
	return vec3(0.42, 0.95, 0.26);                     // 毒
}

float ease_out_back(float x) {
	float c = x - 1.0;
	return 1.0 + 2.70158 * c * c * c + 1.70158 * c * c;
}

void fragment() {
	vec2 q = (UV - 0.5) * 2.0;
	q.y = -q.y;                                  // y 朝上
	vec3 col = vec3(0.0);
	float a = 0.0;
	float glow_d = 1.0;
	if (mode == 0) {
		// 交叉双斧，轮流劈砍 + 红光（Leno 11.04：「换成双斧交叉，然后一直在砍，然后有红光的感觉」）
		// 每把斧绕自己握柄底部转：慢慢举起蓄力 → 极快劈下 → 冲过头回弹 → 回原位；两把错开半拍交替。
		float best_d = 10.0;
		float best_head = 10.0;
		float best_detail = 0.0;
		vec2 best_p = vec2(0.0);
		float flash = 0.0;
		float smear = 0.0;
		for (int k = 0; k < 2; k++) {
			// side = 1：斧头在左上、柄尾在右下；side = -1 镜像 —— 两根柄在中心交叉成 X（参考图）
			float side = k == 0 ? 1.0 : -1.0;
			float strike_k = 0.0;
			float ang = chop_angle(TIME * 0.95 + float(k) * 0.5, strike_k);
			flash = max(flash, strike_k);
			vec2 pivot = vec2(0.56 * side, -0.88);
			vec2 rel = q - pivot;
			rel.x *= side;                                   // 镜像后两把都按「斧头在左上」算
			// 倾斜：柄从右下往左上约 33°；劈 = 斧头往外下砸（倾斜变大），举 = 往竖直回（摆幅小，始终是 X）
			float lean = 0.58 - ang * 0.32;
			vec2 dir = vec2(-sin(lean), cos(lean));          // 柄的方向（往斧头）
			vec2 perp = vec2(cos(lean), sin(lean));          // 柄的右侧
			vec2 lp = vec2(-dot(rel, perp), dot(rel, dir));  // 刃口朝外（左）= 局部 +x
			float d_head;
			float detail;
			float d = axe_shape(lp, d_head, detail);
			if (d < best_d) {
				best_d = d;
				best_head = d_head;
				best_detail = detail;
				best_p = lp;
			}
			// 劈下时刃口划过的红色残影：斧头那个半径上、刚扫过的一段弧
			float r = length(rel);
			float th = atan(-rel.x, rel.y);
			float head_r = smoothstep(1.20, 1.32, r) * (1.0 - smoothstep(1.70, 1.85, r));
			float along = smoothstep(lean - 0.55, lean - 0.05, th) * (1.0 - smoothstep(lean - 0.02, lean + 0.06, th));
			smear = max(smear, head_r * along * strike_k);
		}
		vec2 c = cover(best_d);
		vec3 face = c_main.rgb;
		if (best_head <= 0.0) {
			face = best_p.y > 1.60 ? c_lit.rgb : c_main.rgb;
		} else {
			face = best_p.x > 0.0 ? c_lit.rgb : c_main.rgb;
		}
		col = mix(c_edge.rgb, face, c.x);
		col = mix(col, c_white.rgb, best_detail * c.x);
		// 劈下的那一下整把斧被红光冲亮
		col = mix(col, vec3(1.0, 0.22, 0.18), flash * 0.35 * c.x);
		a = c.y;
		glow_d = best_d;
		// 红光：常驻一圈红晕，劈下时猛地变亮变大；加上残影弧
		float red_glow = exp(-max(best_d, 0.0) * mix(7.0, 4.0, flash)) * mix(0.55, 0.95, flash);
		col = a > 0.01 ? col : mix(c_main.rgb, vec3(1.0, 0.12, 0.10), smear);
		a = max(a, max(red_glow, smear * 0.85));
		glow_d = 10.0;                                     // 斧的光晕自己算过了，下面通用光晕不再叠
	} else if (mode == 3) {
		// 元素光柱（Leno 11.04：「换成元素的光柱效果会不会比较好」）：从脚下拔地而起，
		// 颜色 火 → 冰 → 雷 → 毒 轮换；柱里飘对应元素的粒子；切换瞬间整根猛亮一下。
		float ph = TIME * 0.45;
		int idx = int(mod(floor(ph), 4.0));
		float t = fract(ph);
		vec3 ec = mix(elem_col(idx), elem_col(idx + 1), smoothstep(0.86, 1.0, t));
		float burst = 1.0 - smoothstep(0.0, 0.25, t);                 // 切换瞬间的猛亮，ease-out 回落
		float y01 = q.y * 0.5 + 0.5;                                   // 0 = 脚底，1 = 柱顶
		float x = q.x;
		// 柱身：亮芯 + 柔光，越往上越淡；底部往两侧散开成一圈
		// 柱身加宽、以元素色为主，只在最中心留一条细亮线（第一版太细、亮芯把颜色冲成白）
		float widen = mix(1.0, 1.9, 1.0 - smoothstep(0.0, 0.14, y01));
		float body = exp(-x * x / (0.24 * widen * widen));
		float coreb = exp(-x * x / (0.0035 * widen));
		float vfade = (1.0 - smoothstep(0.55, 1.0, y01)) * smoothstep(0.0, 0.04, y01);
		// 往上流的能量纹
		float streak = smoothstep(0.55, 1.0, sin(y01 * 22.0 - TIME * 7.0 + sin(x * 9.0 + TIME) * 1.5)) * body;
		float beam = (body * 0.70 + coreb * 0.45 + streak * 0.35) * vfade * (1.0 + 0.5 * burst);
		col = mix(ec, vec3(1.0), clamp(coreb * 0.55 + streak * 0.15, 0.0, 1.0));
		a = beam;
		// 柱里的元素粒子
		float pfx = 0.0;
		vec3 pcol = mix(ec, vec3(1.0), 0.5);
		for (int i = 0; i < 6; i++) {
			float fi = float(i);
			float seed = fract(sin(fi * 12.9898 + 4.1) * 43758.5453);
			float speed = idx == 1 ? 0.20 : (idx == 3 ? 0.30 : 0.42);
			float py = fract(TIME * speed + seed);                       // 往上飘
			float px = (seed - 0.5) * 0.75 + 0.06 * sin(TIME * 2.0 + fi * 1.9);
			vec2 pp = vec2(px, py * 2.0 - 1.0);
			vec2 dq = q - pp;
			float life = smoothstep(0.0, 0.12, py) * (1.0 - smoothstep(0.75, 1.0, py));
			if (idx == 0) {
				// 火：余烬火星，一闪一闪
				float flick = 0.6 + 0.4 * sin(TIME * 18.0 + fi * 3.0);
				pfx = max(pfx, (1.0 - smoothstep(0.030, 0.052, length(dq * vec2(1.0, 0.6)))) * life * flick);
				pcol = vec3(1.0, 0.82, 0.35);
			} else if (idx == 1) {
				// 冰：菱形冰晶，边转边闪
				float rot = TIME * 1.5 + fi;
				vec2 rq = vec2(cos(rot) * dq.x - sin(rot) * dq.y, sin(rot) * dq.x + cos(rot) * dq.y);
				float dd = abs(rq.x) / 0.048 + abs(rq.y) / 0.085;
				pfx = max(pfx, (1.0 - smoothstep(0.85, 1.0, dd)) * life);
				pcol = vec3(0.85, 0.97, 1.0);
			} else if (idx == 3) {
				// 毒：带亮边的毒泡往上冒
				float rr = length(dq);
				float ring = 1.0 - smoothstep(0.006, 0.016, abs(rr - 0.050));
				float fill = (1.0 - smoothstep(0.042, 0.052, rr)) * 0.45;
				pfx = max(pfx, max(ring, fill) * life);
				pcol = vec3(0.70, 1.0, 0.50);
			}
		}
		if (idx == 2) {
			// 雷：一道锯齿电弧沿柱子上下跳，频闪
			float zig = 0.07 * (abs(fract(y01 * 6.0 + floor(TIME * 9.0) * 0.37) * 2.0 - 1.0) * 2.0 - 1.0);
			float on = step(0.30, fract(TIME * 6.0));
			pfx = (1.0 - smoothstep(0.020, 0.040, abs(x - zig))) * vfade * on;
			pcol = vec3(1.0, 0.98, 0.75);
		}
		col = mix(col, pcol, pfx);
		a = max(a, pfx * 0.95);
		glow_d = 10.0;
	} else if (mode == 2) {
		// 四色水晶球（Leno 11.04 选的元素套方案）：切面球体 + 球里翻滚的能量，按 火 → 冰 → 雷 → 毒 轮流切换，
		// 切到哪种元素，球外就跳出那种元素的小特效（切换瞬间 overshoot 弹出，快换下一种前收掉）。
		float ph = TIME * 0.45;
		int idx = int(mod(floor(ph), 4.0));
		float t = fract(ph);
		vec3 ec = mix(elem_col(idx), elem_col(idx + 1), smoothstep(0.86, 1.0, t));
		float env = ease_out_back(clamp(t / 0.18, 0.0, 1.0)) * (1.0 - smoothstep(0.74, 0.92, t));
		vec2 oc = vec2(0.0, 0.02);
		float R = 0.40;
		vec2 v = q - oc;
		float r = length(v);
		float ang = atan(v.y, v.x);
		// 切面球：十边形，每个切面按外法线朝光（左上）分亮暗 + 一点浮动
		float seg = 6.2831853 / 10.0;
		float a2 = mod(ang + seg * 0.5, seg) - seg * 0.5;
		float d_orb = r * cos(a2) - R * cos(seg * 0.5);
		float fid = floor((ang + 3.14159265 + seg * 0.5) / seg);
		float fa = fid * seg - 3.14159265;
		float lit = clamp(0.5 + 0.5 * dot(vec2(cos(fa), sin(fa)), normalize(vec2(-0.6, 0.8))) + (fract(sin(fid * 12.9898) * 43758.5453) - 0.5) * 0.25, 0.0, 1.0);
		vec2 co = cover(d_orb);
		// 球里的能量：绕中心翻滚的旋涡，越靠中心越亮
		float swirl = 0.5 + 0.5 * sin(ang * 3.0 - TIME * 2.6 + r * 14.0);
		float core = 1.0 - smoothstep(0.0, R * 0.85, r);
		// 颜色压深、提饱和：第一版被冲成粉彩色，不亮眼；只让球心发白
		vec3 shell = mix(ec * 0.30, mix(ec, vec3(1.0), 0.12), lit);
		vec3 energy = mix(ec * 0.85, mix(ec, vec3(1.0), 0.65), swirl * core * core);
		vec3 orb_col = mix(shell, energy, smoothstep(R * 0.95, R * 0.55, r));
		// 左上高光
		float hl = 1.0 - smoothstep(0.045, 0.07, length((v - vec2(-0.13, 0.14)) * vec2(1.0, 1.5)));
		orb_col = mix(orb_col, vec3(1.0), hl * 0.9);
		col = mix(c_edge.rgb, orb_col, co.x);
		a = co.y;
		// 托环：四色分段的细环（logo 外圈），缓缓转
		float d_ring = abs(r - (R + 0.07)) - 0.022;
		float ring_ang = ang + TIME * 0.5;
		int seg_i = int(mod(floor((ring_ang + 3.14159265) / 1.5707963), 4.0));
		vec2 cr = cover(d_ring);
		col = mix(col, elem_col(seg_i), cr.x * (1.0 - a));
		a = max(a, cr.y * 0.9);
		// 元素特效（球外）
		float fx = 0.0;
		vec3 fx_col = ec;
		if (idx == 0) {
			// 火：球顶窜出五缕火苗，各自跳动
			for (int i = 0; i < 5; i++) {
				float ai = 1.5708 + (float(i) - 2.0) * 0.38;
				vec2 dir = vec2(cos(ai), sin(ai));
				vec2 b = oc + dir * R * 0.92;
				float h = (0.34 + 0.10 * sin(TIME * 9.0 + float(i) * 1.7)) * env;
				vec2 lq = q - b;
				float sa = dot(lq, dir);
				float ta = dot(lq, vec2(-dir.y, dir.x)) + 0.03 * sin(sa * 20.0 - TIME * 12.0) * sa / max(h, 0.001);
				float w = 0.09 * (1.0 - clamp(sa / max(h, 0.001), 0.0, 1.0));
				float inside = step(0.0, sa) * step(sa, h) * (1.0 - smoothstep(w * 0.7, w, abs(ta)));
				fx = max(fx, inside);
			}
			fx_col = mix(vec3(1.0, 0.85, 0.30), vec3(1.0, 0.30, 0.08), smoothstep(R, R + 0.25, r));
		} else if (idx == 1) {
			// 冰：一圈冰晶碎片往外刺出
			for (int i = 0; i < 7; i++) {
				float ai = float(i) * 0.8976 + 0.3;
				vec2 dir = vec2(cos(ai), sin(ai));
				vec2 lq = q - oc;
				float sa = dot(lq, dir) - (R + 0.03);
				float ta = dot(lq, vec2(-dir.y, dir.x));
				float len = 0.34 * env;
				float d_shard = abs(sa - len * 0.5) / max(len * 0.5, 0.001) + abs(ta) / 0.075;
				fx = max(fx, 1.0 - smoothstep(0.9, 1.0, d_shard));
			}
			fx_col = mix(vec3(0.85, 0.96, 1.0), vec3(0.35, 0.70, 1.0), smoothstep(R, R + 0.25, r));
		} else if (idx == 2) {
			// 雷：几道锯齿电弧从球上往外跳，一闪一闪
			for (int i = 0; i < 4; i++) {
				float ai = float(i) * 1.5708 + 0.6 + floor(TIME * 6.0) * 0.9;
				vec2 dir = vec2(cos(ai), sin(ai));
				vec2 lq = q - oc;
				float sa = dot(lq, dir) - R;
				float ta = dot(lq, vec2(-dir.y, dir.x));
				float zig = 0.06 * (abs(fract(sa * 7.0 + float(i) * 0.37) * 2.0 - 1.0) * 2.0 - 1.0);
				float on = step(0.35, fract(TIME * 7.0 + float(i) * 0.31));
				float len = 0.44 * env;
				float inside = step(0.0, sa) * step(sa, len) * (1.0 - smoothstep(0.020, 0.036, abs(ta - zig))) * on;
				fx = max(fx, inside);
			}
			fx_col = vec3(1.0, 0.95, 0.55);
		} else {
			// 毒：球底不断滴下毒液
			for (int i = 0; i < 3; i++) {
				float k = fract(TIME * 0.9 + float(i) * 0.33);
				vec2 dp = vec2((float(i) - 1.0) * 0.14, oc.y - R - 0.02 - k * 0.45);
				vec2 lq = (q - dp) * vec2(1.0, 0.8);
				float drop = 1.0 - smoothstep(0.052, 0.068, length(lq) - max(lq.y, 0.0) * 0.6);
				fx = max(fx, drop * (1.0 - k) * env);
			}
			fx_col = vec3(0.50, 1.0, 0.30);
		}
		col = mix(col, fx_col, fx * (1.0 - co.y));
		a = max(a, fx * 0.95);
		// 光晕：当前元素色，切换瞬间亮一下
		float halo = exp(-max(d_orb, 0.0) * 8.0) * (0.35 + 0.35 * env);
		col = a > 0.02 ? col : ec;
		a = max(a, halo);
		glow_d = 10.0;
	} else {
		float r = length(q);
		float ang = atan(q.y, q.x);
		// 外环：按朝光（左上）分亮暗
		float d_ring = abs(r - 0.82) - 0.065;
		float lit_side = 0.5 + 0.5 * dot(normalize(q + vec2(0.0001)), normalize(vec2(-0.6, 0.8)));
		// 刻度：十二根，每三根长一点
		float sector = mod(ang + 3.14159265, 0.5235988) - 0.2617994;
		float idx = floor((ang + 3.14159265) / 0.5235988 + 0.5);
		float major = mod(idx, 3.0) < 0.5 ? 1.0 : 0.0;
		float d_tick = max(abs(sector) * r - 0.022, abs(r - mix(0.66, 0.62, major)) - mix(0.05, 0.09, major));
		// 指针：时针慢、分针快
		float ha = TIME * 0.35;
		float ma = TIME * 1.7;
		vec2 hd = vec2(sin(ha), cos(ha));
		vec2 md = vec2(sin(ma), cos(ma));
		float d_hour = max(abs(dot(q, vec2(hd.y, -hd.x))) - 0.035, max(-dot(q, hd), dot(q, hd) - 0.40));
		float d_min = max(abs(dot(q, vec2(md.y, -md.x))) - 0.022, max(-dot(q, md), dot(q, md) - 0.58));
		// 中心紫晶：菱形，左半亮、右半暗
		float d_gem = abs(q.x) / 0.17 + abs(q.y) / 0.26 - 1.0;
		d_gem *= 0.17;
		float d_parts = min(min(d_ring, d_tick), min(d_hour, d_min));
		vec2 c1 = cover(d_parts);
		vec2 c2 = cover(d_gem);
		vec3 ring_col = mix(c_main.rgb, c_lit.rgb, d_ring < 0.0 ? lit_side : 0.6);
		col = mix(c_edge.rgb, ring_col, c1.x);
		float a1 = c1.y;
		vec3 gem_face = q.x < 0.0 ? c_lit.rgb : c_main.rgb;
		gem_face = mix(gem_face, c_white.rgb, (1.0 - smoothstep(0.0, 0.03, abs(q.x))) * 0.7);
		vec3 gem_col = mix(c_edge.rgb, gem_face, c2.x);
		col = mix(col, gem_col, c2.y);
		// 盘面一层淡淡的紫色底
		float disc = 1.0 - smoothstep(0.74, 0.78, r);
		a = max(max(a1, c2.y), disc * 0.16);
		col = mix(c_main.rgb, col, max(a1, c2.y) > 0.01 ? 1.0 : 0.0);
		glow_d = min(d_ring, d_gem);
	}
	// 外圈柔光：「虚影」的光晕
	float glow = exp(-max(glow_d, 0.0) * 14.0) * 0.30;
	vec3 out_col = mix(c_main.rgb, col, clamp(a / max(a + glow, 0.0001), 0.0, 1.0));
	ALBEDO = out_col;
	// 靠近面片边缘淡出：光晕被面片边界切出方形直边很难看（双斧第二版实拍顶边有一道切口）
	float edge_fade = 1.0 - smoothstep(0.80, 0.99, max(abs(q.x), abs(q.y)));
	ALPHA = clamp(max(a * ghost, glow), 0.0, 0.95) * fade * edge_fade;
}
