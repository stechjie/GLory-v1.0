// 战斗单位的平面投影影子。由 effects/runtime/presentation/UnitPlanarShadow.gd 接到
// 角色每个表面材质 next_pass 链的最后，同一份蒙皮网格再画一遍：每个顶点沿影子方向
// 压到地面 y = ground_y，画成半透明暗色。影子就是角色剪影，动作、翅膀、被击飞都跟着走。
// 2026-10-21 在 scenes/debug/CharacterLookAB 对照「现状圆 / 方向椭圆 / 实时阴影」后选定。
//
// 重叠：压扁后几十层三角形叠在同一像素上，直接半透明混合会越叠越黑。模板缓冲让
// 第一次画到的像素写 1，之后 compare_not_equal 1 一律不画——一个单位自己叠、几个
// 单位的影子互相压到，都只暗一次。
//
// 离脚越远越淡，按「地面上离模型原点多远」算，不按原顶点高度：同一像素上每层三角形
// 算出来的值相同，模板只放第一层进来也不会因为绘制顺序出现斑块。
//
// 方向是 uniform，不读场景灯：战斗主光从镜头这一侧照过去，跟灯的影子会落在角色身后、
// 大半被身体挡住，所以用单独的「可读方向」让影子落向右下方（用户 2026-10-21 定）。
// 死亡淡出走 GeometryInstance3D.transparency，会同时乘到这一层。

shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix, fog_disabled;
stencil_mode read, write, compare_not_equal, 1;

// 影子「行进」的世界方向（y 必须为负）。
uniform vec3 shadow_direction = vec3(0.42, -0.78, 0.46);
// 由 UnitPlanarShadow.attach() 按战斗单位实际站立高度写入（battle_unit_y_offset + 0.004）。
uniform float ground_y = 1.004;
uniform vec4 shadow_color : source_color = vec4(0.03, 0.03, 0.06, 1.0);
uniform float shadow_alpha : hint_range(0.0, 1.0) = 0.42;
// 地面上离模型原点这么远时，影子淡到 alpha * (1 - fade_strength)。单位：世界米。
uniform float fade_distance = 0.45;
uniform float fade_strength : hint_range(0.0, 1.0) = 0.55;

varying float ground_distance;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 dir = normalize(shadow_direction);
	dir.y = min(dir.y, -0.15);
	float height = max(world.y - ground_y, 0.0);
	// 沿影子方向走到地面；地面以下的顶点（死亡下沉时）直接竖直贴地。
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
