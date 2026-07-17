shader_type canvas_item;

uniform sampler2D mask_texture : filter_linear;
uniform sampler2D noise_texture : repeat_enable, filter_linear;
uniform vec2 flow_direction = vec2(1.0, 0.0);
uniform vec3 water_tint : source_color = vec3(0.12, 0.72, 0.95);
uniform float speed : hint_range(0.0, 1.0) = 0.12;
uniform float distortion : hint_range(0.0, 0.02) = 0.004;
uniform float highlight_strength : hint_range(0.0, 1.0) = 0.22;
uniform float overlay_opacity : hint_range(0.0, 1.0) = 0.65;

void fragment() {
	float mask_value = texture(mask_texture, UV).r;
	vec2 noise_uv = UV * vec2(7.0, 5.0) + flow_direction * TIME * speed;
	float noise_a = texture(noise_texture, noise_uv).r;
	float noise_b = texture(noise_texture, noise_uv * 1.73 - flow_direction * TIME * speed * 0.61).r;
	float wave = (noise_a + noise_b - 1.0);
	vec2 perpendicular = vec2(-flow_direction.y, flow_direction.x);
	vec2 warped_uv = UV + perpendicular * wave * distortion * mask_value;
	vec4 base = texture(TEXTURE, warped_uv);
	float moving_highlight = smoothstep(0.58, 0.92, noise_a * 0.66 + noise_b * 0.34);
	vec3 color = base.rgb + water_tint * moving_highlight * highlight_strength;
	COLOR = vec4(color, mask_value * overlay_opacity);
}
