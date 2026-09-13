shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque;

uniform vec4 outline_color : source_color = vec4(0.025, 0.015, 0.04, 1.0);
uniform float outline_width : hint_range(0.0, 0.10) = 0.028;
uniform float outline_max_pixels : hint_range(0.0, 4.0) = 1.25;

void vertex() {
	// Preserve each material's tuned width, but cap the projected shell on
	// small chess pieces. Model-space extrusion otherwise turns thin parts
	// and hard-normal seams into thick black wedges inside the character.
	vec4 original_clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 expanded_clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX + NORMAL * outline_width, 1.0);
	if (original_clip.w > 0.0001 && expanded_clip.w > 0.0001) {
		vec2 pixel_offset = (expanded_clip.xy / expanded_clip.w - original_clip.xy / original_clip.w)
				* VIEWPORT_SIZE * 0.5;
		float pixels = length(pixel_offset);
		pixel_offset *= min(1.0, outline_max_pixels / max(pixels, 0.0001));
		original_clip.xy += pixel_offset * 2.0 / VIEWPORT_SIZE * original_clip.w;
	}
	// Keep the original surface depth, so the shell does not move through
	// neighbouring faces. This also works with Compatibility and reverse-Z.
	POSITION = original_clip;
}

void fragment() {
	// The opaque body casts the shadow. A screen-space shell must not replace
	// the engine's special point-light shadow projection with camera clip space.
	if (IN_SHADOW_PASS) {
		discard;
	}
	ALBEDO = outline_color.rgb;
}
