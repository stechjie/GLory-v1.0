shader_type spatial;
render_mode unshaded, cull_disabled, blend_add;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0,0.8,0.2);
uniform vec3 secondary_color : source_color = vec3(1.0,0.4,0.1);
uniform vec3 tertiary_color : source_color = vec3(0.6,0.1,0.05);

group_uniforms Shape;
uniform sampler2D noise_texture;
uniform vec2 noise_scale = vec2(0.4, 0.4);
uniform bool use_icon = false;
uniform sampler2D icon_texture;

varying flat int id;

float overlay(float base, float blend){
	float limit = step(0.5, base);
	return mix(2.0 * base * blend, 1.0 - 2.0 * (1.0 - base) * (1.0 - blend), limit);
}

void vertex(){
	id = INSTANCE_ID;
}

void fragment() {
	float value = 1.0;
	if(!use_icon){
		float id_offset = float(id) / TAU;
		
		float noise = texture(noise_texture, UV * noise_scale * 0.3 + id_offset).r;
		float gradient = max(1.0 - length(UV * 2.0 - 1.0), 0.0);
		
		value = overlay(gradient, noise) - (1.0 - COLOR.a);
		
		value = smoothstep(0.6, 0.8, value);
	} else {
		vec4 icon = texture(icon_texture, UV);
		
		value = icon.a * COLOR.a;
	}
	
	vec3 color = mix(secondary_color, tertiary_color, COLOR.r);
	
	ALBEDO = color * 2.0;
	ALPHA = value;
}