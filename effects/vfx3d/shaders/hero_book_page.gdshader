shader_type spatial;
// 母灵「亡者之书」的书页 / 封面。一张 PlaneMesh（XZ 平面，UV 0..1）既当书页也当封面：
//   is_cover = 0：羊皮纸底 + 几行会发光的符文墨迹 + 页边暗角；
//   is_cover = 1：暗色皮革 + 发光包边 + 中央眼形徽记。
// depth_prepass_alpha：书页彼此遮挡要靠深度排序（翻页时前后关系一直在变），
// 同时还能整体淡入淡出。unshaded —— 与赤律族光层一样不吃场景灯光，雪地上也读得清。
render_mode unshaded, cull_disabled, depth_prepass_alpha, shadows_disabled, fog_disabled;

uniform vec4 paper_color : source_color = vec4(0.86, 0.80, 0.64, 1.0);
uniform vec4 paper_edge : source_color = vec4(0.42, 0.34, 0.24, 1.0);
uniform vec4 cover_color : source_color = vec4(0.10, 0.07, 0.10, 1.0);
uniform vec4 trim_color : source_color = vec4(0.30, 0.86, 0.62, 1.0);
uniform vec4 ink_color : source_color = vec4(0.06, 0.20, 0.15, 1.0);
uniform vec4 glow_color : source_color = vec4(0.42, 1.0, 0.72, 1.0);
uniform float is_cover = 0.0;
uniform float glow = 0.0;       // 0..1 符文 / 包边亮度
uniform float opacity = 1.0;
uniform float seed = 0.0;
uniform float flip_shade = 0.0; // 0..1 翻到一半时侧光变暗，帮助读出「立起来的那一页」

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7)) + seed * 17.13) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	vec3 col;
	if (is_cover > 0.5) {
		float trim = 1.0 - smoothstep(0.035, 0.07, edge);
		float inner_trim = 1.0 - smoothstep(0.008, 0.02, abs(edge - 0.12));
		vec2 c = (uv - vec2(0.5)) * vec2(2.0, 2.6);
		float eye = max(length(c - vec2(0.42, 0.0)), length(c + vec2(0.42, 0.0))) - 0.72;
		float emblem = 1.0 - smoothstep(0.02, 0.06, abs(eye));
		float pupil = 1.0 - smoothstep(0.8, 1.0, length(c / vec2(0.06, 0.20)));
		float lines = max(trim, max(inner_trim * 0.8, max(emblem, pupil)));
		col = mix(cover_color.rgb, trim_color.rgb * 0.55, lines);
		col = mix(col, glow_color.rgb, lines * glow);
	} else {
		float vignette = smoothstep(0.0, 0.16, edge);
		col = mix(paper_edge.rgb, paper_color.rgb, vignette);
		// 几行「文字」：每行一串长短不一的墨划，靠中缝一侧留白。
		float row = floor(uv.y * 11.0);
		float in_row = 1.0 - smoothstep(0.10, 0.20, abs(fract(uv.y * 11.0) - 0.5));
		float word = step(0.32, hash(vec2(floor(uv.x * 9.0 + row * 3.7), row)));
		float margin = step(0.12, uv.x) * step(uv.x, 0.88) * step(1.5, row) * step(row, 9.5);
		float text = in_row * word * margin;
		// 页心一枚发光的小符印。
		vec2 c = (uv - vec2(0.5, 0.5)) * 2.0;
		float sigil = 1.0 - smoothstep(0.02, 0.05, abs(length(c) - 0.30));
		float ink = max(text * 0.85, sigil * step(0.5, hash(vec2(seed, 3.0)) + 0.5));
		vec3 ink_col = mix(ink_color.rgb, glow_color.rgb, glow);
		col = mix(col, ink_col, ink);
		col += glow_color.rgb * glow * 0.18 * (1.0 - vignette);
	}
	col *= 1.0 - 0.35 * flip_shade;
	ALBEDO = col;
	ALPHA = clamp(opacity, 0.0, 1.0);
}
