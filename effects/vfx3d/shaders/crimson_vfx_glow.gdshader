shader_type spatial;
// Crimson race (赤律族) light layer. One program serves every glow, streak,
// ring, arc and seal of VFXCrimsonAttack3D / VFXCrimsonSkill3D so the whole race
// warms up as a single pipeline; only uniforms change per layer.
//
// blend_mix, not blend_add: the battle 3D viewport is transparent and composited
// over the 2D arena art. Additive layers write almost no coverage there and wash
// out completely on the white snow PvP board (verified in CrimsonVFXPreview).
// Light is therefore painted as dark rim -> crimson body -> hot core -> white-hot.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

uniform vec4 edge : source_color = vec4(0.12, 0.006, 0.02, 1.0);
uniform vec4 tint : source_color = vec4(0.74, 0.018, 0.055, 1.0);
uniform vec4 hot : source_color = vec4(1.0, 0.28, 0.17, 1.0);
uniform vec4 white_hot : source_color = vec4(1.0, 0.77, 0.88, 1.0);
uniform float opacity = 1.0;
uniform float energy = 1.0;
// 0 radial glow, 1 streak (UV.x tail->head), 2 ring / arc band,
// 3 four-ray flare, 4 seal (snowflake / lantern / drum glyph), 5 vertex colour.
uniform int shape = 0;
// 1: camera-facing quad. Rotation `spin` is applied in screen space first.
uniform float billboard = 0.0;
uniform float spin = 0.0;
uniform float softness = 1.0;
uniform float core_white = 0.35;
// How far the fading edge falls toward the dark rim colour (0 = none).
uniform float edge_dark = 0.45;
// ring / arc controls (shape 2): radius and band width in quad UV units (0..1 = edge).
uniform float ring_radius = 0.82;
uniform float ring_width = 0.10;
uniform float arc_span = 1.0;      // fraction of the circle kept (1 = full ring)
uniform float arc_start = 0.0;     // radians, centre of the kept arc
uniform float breakup = 0.0;       // 0 clean, 1 heavily broken (torn energy)
uniform float ticks = 0.0;         // rune tick count around the ring
uniform float reveal = 1.0;        // 0..1 sweep reveal around the ring
uniform float fill = 0.0;          // soft inner fill under a ring / seal (0..1)
uniform float seal_rings = 1.0;    // draw the seal's two framing circles
uniform float stroke = 0.035;      // seal stroke half-width in quad UV units
// seal (shape 4): 0 frost snowflake, 1 lantern seal, 2 drum ripple, 3 aegis, 4 music note,
// 5 divine sun sigil (神王), 6 soul-reaper eye (母灵), 7 gravity vortex arms (黑龙).
uniform int pattern = 0;
uniform float seed = 0.0;

void vertex() {
	if (billboard > 0.5) {
		float s = sin(spin);
		float c = cos(spin);
		VERTEX.xy = mat2(vec2(c, s), vec2(-s, c)) * VERTEX.xy;
		float sx = length(MODEL_MATRIX[0].xyz);
		float sy = length(MODEL_MATRIX[1].xyz);
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * sx, INV_VIEW_MATRIX[1] * sy, INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
}

float hash11(float n) {
	return fract(sin(n * 12.9898 + seed * 78.233) * 43758.5453);
}

float torn(float angle) {
	return 0.5 + 0.5 * sin(angle * 7.0 + seed * 3.1 + TIME * 1.7) * sin(angle * 13.0 - seed * 1.3 - TIME * 2.3);
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float alpha = 0.0;
	float heat = 0.0;
	if (shape == 0) {
		float body = clamp(1.0 - r, 0.0, 1.0);
		alpha = pow(body, 1.0 + softness * 1.6);
		heat = smoothstep(0.62, 0.0, r);
	} else if (shape == 1) {
		float along = clamp(UV.x, 0.0, 1.0);
		float across = abs(UV.y * 2.0 - 1.0);
		float taper = mix(0.25, 1.0, along);
		float line = 1.0 - smoothstep(0.08 * taper, taper, across);
		float fade_tail = pow(along, 1.25);
		float fade_head = 1.0 - smoothstep(0.93, 1.0, along);
		alpha = line * fade_tail * fade_head;
		heat = smoothstep(0.55, 1.0, along) * (1.0 - smoothstep(0.0, 0.45 * taper, across));
	} else if (shape == 2) {
		float rel = mod(a - arc_start + 3.14159265, 6.2831853) - 3.14159265;
		float half_span = max(arc_span, 0.0001) * 3.14159265;
		float window = arc_span >= 0.999 ? 1.0 : 1.0 - smoothstep(half_span * 0.55, half_span, abs(rel));
		// Arcs taper to blade tips instead of ending as flat bands.
		float taper = arc_span >= 0.999 ? 1.0 : mix(0.18, 1.0, sqrt(clamp(1.0 - abs(rel) / half_span, 0.0, 1.0)));
		float width = ring_width * taper;
		float d = abs(r - ring_radius);
		float band = 1.0 - smoothstep(width * 0.25, width, d);
		float ang01 = fract((a + 3.14159265) / 6.2831853 + seed * 0.13);
		float swept = reveal >= 0.999 ? 1.0 : 1.0 - smoothstep(reveal - 0.04, reveal + 0.002, ang01);
		float gaps = mix(1.0, smoothstep(0.15, 0.65, torn(a)), breakup);
		float tick_mark = 0.0;
		if (ticks > 0.5) {
			float cell = fract(ang01 * ticks);
			float notch = 1.0 - smoothstep(0.0, 0.10, abs(cell - 0.5));
			float notch_r = 1.0 - smoothstep(ring_width * 0.4, ring_width * 1.9, abs(r - (ring_radius - ring_width * 1.6)));
			tick_mark = notch * notch_r;
		}
		float inner = fill * smoothstep(ring_radius * 0.15, ring_radius, r) * (1.0 - smoothstep(ring_radius - width * 0.2, ring_radius, r)) * 0.55;
		alpha = max(max(band * gaps, tick_mark * 0.85), inner) * window * swept;
		heat = (1.0 - smoothstep(0.0, width * 0.45, d)) * window;
	} else if (shape == 3) {
		float rays = 0.0;
		for (int i = 0; i < 2; i++) {
			float ang = float(i) * 1.5707963 + spin * 0.0;
			vec2 dir = vec2(cos(ang), sin(ang));
			float along = abs(dot(p, dir));
			float across = abs(dot(p, vec2(-dir.y, dir.x)));
			rays = max(rays, (1.0 - smoothstep(0.0, 0.06 + 0.10 * (1.0 - along), across)) * (1.0 - smoothstep(0.2, 1.0, along)));
		}
		float bloom = pow(clamp(1.0 - r, 0.0, 1.0), 3.0);
		alpha = max(rays, bloom);
		heat = smoothstep(0.45, 0.0, r);
	} else if (shape == 4) {
		float w0 = stroke * 0.45;
		float w1 = stroke;
		float outer = 1.0 - smoothstep(w0, w1, abs(r - 0.92));
		float inner = 1.0 - smoothstep(w0 * 0.8, w1 * 0.8, abs(r - 0.70));
		float glyph = 0.0;
		if (pattern == 0) {
			// Six-armed frost seal: spokes with two branch pairs each.
			float sector = 1.0471976;
			float local = mod(a + sector * 0.5, sector) - sector * 0.5;
			vec2 q = vec2(cos(local), sin(local)) * r;
			float spoke = (1.0 - smoothstep(w0, w1, abs(q.y))) * step(0.08, q.x) * (1.0 - step(0.88, q.x));
			float b1 = (1.0 - smoothstep(w0, w1, abs(abs(q.y) - (q.x - 0.38) * 0.75))) * step(0.38, q.x) * (1.0 - step(0.60, q.x));
			float b2 = (1.0 - smoothstep(w0, w1, abs(abs(q.y) - (q.x - 0.58) * 0.75))) * step(0.58, q.x) * (1.0 - step(0.76, q.x));
			float hexagon = 1.0 - smoothstep(w0, w1, abs(r * cos(local) - 0.30));
			glyph = max(max(spoke, max(b1, b2)), hexagon * step(r, 0.36));
		} else if (pattern == 1) {
			// Lantern seal: eight short rays, a closed inner ring and a horizontal bar.
			float sector = 0.7853982;
			float local = mod(a + sector * 0.5, sector) - sector * 0.5;
			vec2 q = vec2(cos(local), sin(local)) * r;
			float ray = (1.0 - smoothstep(w0, w1, abs(q.y))) * step(0.74, q.x) * (1.0 - step(0.90, q.x));
			float core_ring = 1.0 - smoothstep(w0, w1, abs(r - 0.36));
			float bar = (1.0 - smoothstep(w0 * 1.2, w1 * 1.4, abs(p.y))) * (1.0 - step(0.30, abs(p.x)));
			glyph = max(ray, max(core_ring, bar));
		} else if (pattern == 2) {
			// Drum head: heavy rim, zig-zag lacing and a taut inner skin.
			float rim = 1.0 - smoothstep(w0 * 1.6, w1 * 1.8, abs(r - 0.80));
			float lace_r = 0.80 + 0.10 * (abs(fract(a * 12.0 / 6.2831853) * 2.0 - 1.0) * 2.0 - 1.0);
			float lacing = (1.0 - smoothstep(w0, w1, abs(r - lace_r))) * step(0.66, r);
			float skin = 1.0 - smoothstep(w0, w1, abs(r - 0.42));
			glyph = max(rim, max(lacing * 0.85, skin * 0.7));
		} else if (pattern == 4) {
			// Eighth note (赤舞者增益): tilted oval head, stem and one swept flag.
			vec2 q = vec2(p.x, -p.y);
			vec2 hc = q - vec2(-0.20, -0.50);
			float ca = cos(0.45);
			float sa = sin(0.45);
			vec2 hr = vec2(ca * hc.x + sa * hc.y, -sa * hc.x + ca * hc.y);
			float head = 1.0 - smoothstep(0.86, 1.05, length(hr / vec2(0.30, 0.20)));
			float stem = (1.0 - smoothstep(0.045, 0.075, abs(q.x - 0.07))) * step(-0.52, q.y) * (1.0 - step(0.78, q.y));
			float fx = clamp((q.x - 0.07) / 0.40, 0.0, 1.0);
			float flag_y = 0.76 - 0.62 * pow(fx, 1.3);
			float flag_w = mix(0.13, 0.04, fx);
			float flag = (1.0 - smoothstep(flag_w * 0.6, flag_w, abs(q.y - flag_y))) * step(0.05, q.x) * (1.0 - step(0.48, q.x));
			glyph = max(head, max(stem, flag));
		} else if (pattern == 5) {
			// Divine sun sigil (神王): twelve tapered rays of alternating length,
			// a broken inner ring and a four-point star core. Rotated by `seed` phase.
			float sector = 0.5235988;
			float ra = a + seed * 0.37;
			float local = mod(ra + sector * 0.5, sector) - sector * 0.5;
			float idx = floor((ra + sector * 0.5) / sector);
			float ray_len = mod(idx, 2.0) < 0.5 ? 0.95 : 0.76;
			vec2 q = vec2(cos(local), sin(local)) * r;
			float ray_w = mix(w1 * 1.5, w0 * 0.5, clamp((q.x - 0.50) / (ray_len - 0.50), 0.0, 1.0));
			float ray = (1.0 - smoothstep(ray_w * 0.5, ray_w, abs(q.y))) * step(0.50, q.x) * (1.0 - step(ray_len, q.x));
			float ring_gap = smoothstep(0.15, 0.55, abs(sin(ra * 6.0)));
			float ring = (1.0 - smoothstep(w0, w1, abs(r - 0.40))) * ring_gap;
			vec2 sq = abs(p);
			float star = 1.0 - smoothstep(0.0, 0.05, sq.x * 1.0 + sq.y * 1.0 - 0.06 - 0.24 * (1.0 - smoothstep(0.0, 0.05, min(sq.x, sq.y))));
			glyph = max(ray, max(ring, star));
		} else if (pattern == 6) {
			// Soul-reaper mark (母灵): an upright almond eye with a slit pupil
			// and two falling tear strokes underneath.
			vec2 q = vec2(p.x, -p.y);
			float eye_out = max(length(q - vec2(0.52, 0.10)), length(q - vec2(-0.52, 0.10))) - 0.86;
			float rim = 1.0 - smoothstep(w0, w1, abs(eye_out));
			float pupil = 1.0 - smoothstep(0.85, 1.05, length((q - vec2(0.0, 0.10)) / vec2(0.07, 0.24)));
			float tear_l = (1.0 - smoothstep(w0, w1, abs(q.x + 0.16 + (q.y + 0.42) * 0.10))) * step(-0.86, q.y) * (1.0 - step(-0.46, q.y));
			float tear_r = (1.0 - smoothstep(w0, w1, abs(q.x - 0.16 - (q.y + 0.42) * 0.10))) * step(-0.78, q.y) * (1.0 - step(-0.50, q.y));
			glyph = max(max(rim, pupil), max(tear_l, tear_r) * 0.85);
		} else if (pattern == 7) {
			// Gravity vortex (黑龙): three logarithmic spiral arms winding inward,
			// rotated by `spin` (ground decals do not billboard, so spin is free).
			float arms = sin((a + spin) * 3.0 + log(max(r, 0.02)) * 7.5);
			float band = smoothstep(0.25, 0.95, arms);
			float body_mask = smoothstep(0.98, 0.70, r) * smoothstep(0.06, 0.30, r);
			float torn_a = mix(1.0, smoothstep(0.1, 0.7, torn(a * 1.3 + r * 4.0)), breakup);
			glyph = band * body_mask * torn_a;
		} else {
			// Aegis: double hexagon with a centre boss.
			float sector = 1.0471976;
			float local = mod(a + sector * 0.5, sector) - sector * 0.5;
			float hex_r = r * cos(local);
			float h1 = 1.0 - smoothstep(w0 * 1.4, w1 * 1.6, abs(hex_r - 0.78));
			float h2 = 1.0 - smoothstep(w0, w1, abs(hex_r - 0.52));
			float boss = 1.0 - smoothstep(0.10, 0.20, r);
			glyph = max(h1, max(h2 * 0.8, boss));
		}
		float sweep_a = fract((a + 3.14159265) / 6.2831853 + seed * 0.13);
		float swept = reveal >= 0.999 ? 1.0 : 1.0 - smoothstep(reveal - 0.05, reveal + 0.002, sweep_a);
		float disc = fill * (1.0 - smoothstep(0.55, 0.95, r)) * 0.45;
		alpha = max(max(max(outer, inner * 0.75) * seal_rings, glyph), disc) * swept * step(r, 1.0);
		heat = glyph * 0.75 + outer * 0.35;
	} else {
		alpha = COLOR.a;
		heat = COLOR.r;
	}
	float coverage = clamp(alpha, 0.0, 1.0);
	vec3 color = mix(edge.rgb, tint.rgb, mix(1.0, smoothstep(0.0, 0.55, coverage), edge_dark));
	color = mix(color, hot.rgb, clamp(heat, 0.0, 1.0));
	color = mix(color, white_hot.rgb, clamp(heat * heat * core_white, 0.0, 1.0));
	ALBEDO = min(color * energy, vec3(1.0));
	// Soft shoulders read as glow; the dense core stays nearly opaque.
	float shaped = coverage * (0.55 + 0.45 * coverage);
	ALPHA = clamp(shaped * opacity * (shape == 5 ? 1.0 : COLOR.a), 0.0, 1.0);
}
