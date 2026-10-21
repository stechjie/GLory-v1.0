// 受击闪白。由 effects/runtime/presentation/BattleHitFeedback.gd 在命中瞬间临时挂到
// 受击单位网格的 material_overlay 上，约 0.1 秒内把 amount 从 1 降到 0 后摘掉。
// 不改任何角色材质：角色用了十几种着色器（toon / 暗族 race_body / 装备 / 宠物……），
// 覆盖层对它们一视同仁。加法混合，只提亮不改色相；边缘多亮一点，读起来是「被打亮」
// 而不是整块变成白色剪影。
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

uniform vec3 flash_color : source_color = vec3(1.0, 0.95, 0.86);
uniform float amount : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	float rim = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	ALBEDO = flash_color * amount * (0.55 + 0.45 * rim);
}
