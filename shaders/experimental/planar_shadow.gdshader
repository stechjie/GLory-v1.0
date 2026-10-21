// 平面投影影子，只给 scenes/debug/CharacterLookAB 试验用，生产不引用。
//
// 挂在角色材质 next_pass 链的最后：同一份蒙皮网格再画一遍，每个顶点沿光的方向
// 压到地面 y = ground_y 上，画成半透明暗色。影子就是角色剪影，动作、翅膀都会跟着动。
//
// 重叠：一个角色压扁后几十层三角形叠在一起，直接半透明混合会越叠越黑。
// 用模板缓冲：第一次画到的像素写 1，之后 compare_not_equal 1 一律不画，
// 所以不管叠几层（包括几个单位的影子互相压到）都只暗一次。
//
// 离脚越远影子越淡，脚底最实——和贴地小核心一起把脚「踩住」。淡化按「地面上离
// 模型原点多远」算而不是按原顶点高度：同一像素上叠着的每层三角形算出来的值相同，
// 模板只放第一层进来也不会因为绘制顺序出现斑块。
// 光方向单独作为 uniform，不读场景里的灯：影子方向和角色身上的明暗可以分开调。

shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix, fog_disabled;
stencil_mode read, write, compare_not_equal, 1;

// 光「行进」的世界方向（从灯指向地面，y 必须为负）。
uniform vec3 light_direction = vec3(-0.47, -0.82, -0.33);
uniform float ground_y = 0.004;
uniform vec4 shadow_color : source_color = vec4(0.03, 0.03, 0.06, 1.0);
uniform float shadow_alpha : hint_range(0.0, 1.0) = 0.42;
// 地面上离模型原点这么远时影子淡到 alpha * (1 - fade_strength)。单位：世界米。
uniform float fade_distance = 0.45;
uniform float fade_strength : hint_range(0.0, 1.0) = 0.55;

varying float ground_distance;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 dir = normalize(light_direction);
	dir.y = min(dir.y, -0.15);
	float height = max(world.y - ground_y, 0.0);
	// 沿光线走到地面；地面以下的顶点（极少）直接贴地，不往反方向翻。
	vec3 projected = world + dir * (height / -dir.y);
	projected.y = ground_y;
	ground_distance = length(projected.xz - MODEL_MATRIX[3].xz);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(projected, 1.0);
}

void fragment() {
	if (IN_SHADOW_PASS) {
		discard;
	}
	ALBEDO = shadow_color.rgb;
	float fade = 1.0 - fade_strength * clamp(ground_distance / max(fade_distance, 0.001), 0.0, 1.0);
	ALPHA = shadow_alpha * fade;
}
