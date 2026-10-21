extends Node

# 战斗投影剪影影子（UnitPlanarShadow + shaders/unit_planar_shadow.gdshader）的门禁。
#
# 守四件事：
#   1. 真实模型（人族精修民兵、暗族魅魔、暗龙）挂上后，影子在每个角色网格的材质链尾；
#      磁盘上的共享 .tres 一点没变（备战 / 预览 / 头像渲染都在用同一份）。
#   2. 同种单位共用一份带影子的副本，重复挂不会越接越长。
#   3. 不新增任何 GeometryInstance3D：四星 / 亡灵光环、死亡发光按「角色下所有 ArrayMesh」
#      挂 material_overlay，多出一个影子网格就会多一层没压扁的重影；死亡淡出也只认这些节点。
#   4. LOW 不挂、MEDIUM / HIGH 挂；BattleRenderer 在 _add_3d_unit_readability 里真的调用了它，
#      且只缩脚底圆、不缩队伍光圈。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const PlanarShadow := preload("res://effects/runtime/presentation/UnitPlanarShadow.gd")
const CHECK_NAME := "unit_planar_shadow"
const SHADER_PATH := "res://shaders/unit_planar_shadow.gdshader"
const RENDERER_PATH := "res://scenes/battle/BattleRenderer.gd"
const MODELS := {
	"human_militia": {
		"scene": "res://assets/models/units/human_refined/human_militia/human_militia_refined.tscn",
		"materials": ["res://assets/models/units/human_refined/human_militia/body.tres",
				"res://assets/models/units/human_refined/human_militia/gear.tres"],
	},
	"dark_suc": {
		"scene": "res://assets/models/units/dark_refined/dark_suc/dark_suc_refined.tscn",
		"materials": ["res://assets/models/units/dark_refined/dark_suc/dark_suc_body.tres",
				"res://assets/models/units/dark_refined/shared/dark_parts.tres"],
	},
	"dark_dragon": {
		"scene": "res://assets/models/units/dark_refined/dark_dragon/dark_dragon_refined.tscn",
		"materials": ["res://assets/models/units/dark_refined/dark_dragon/dark_dragon_body.tres",
				"res://assets/models/units/dark_refined/shared/dark_parts.tres"],
	},
}

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_shader()
	_check_tiers()
	_check_renderer_call()
	for unit_id in MODELS.keys():
		await _check_model(unit_id, MODELS[unit_id])
	_h.finish(get_tree())


func _check_shader() -> void:
	var src := FileAccess.get_file_as_string(SHADER_PATH)
	if not _h.expect(not src.is_empty(), "shader_missing", SHADER_PATH + " 读不到"):
		return
	var code := _strip_comments(src)
	_h.expect(code.contains("stencil_mode read, write, compare_not_equal"), "stencil_missing",
			"没有模板去重：压扁后的三角形会在同一像素叠出越来越黑的斑块")
	_h.expect(code.contains("unshaded") and code.contains("depth_draw_never"), "render_mode_drift",
			"影子必须 unshaded + depth_draw_never，否则会进灯循环或挡住后面的单位")
	_h.expect(not code.contains("texture("), "shader_samples_texture", "影子不该采样贴图")


func _check_tiers() -> void:
	var forced := PlanarShadow.force_mode()
	if not forced.is_empty():
		_h.note("检测到 %s=%s，画质档判断被强制覆盖，本项跳过" % [PlanarShadow.TEST_SWITCH_PATH, forced])
		_h.item()
		return
	_h.expect(not PlanarShadow.enabled_for_tier(VFXQualityBudget.Tier.LOW), "low_tier_enabled",
			"低画质必须保留现状圆形影，不挂投影")
	_h.expect(PlanarShadow.enabled_for_tier(VFXQualityBudget.Tier.MEDIUM), "medium_tier_disabled",
			"中画质应挂投影（Redmi A5 这类 8 核低端机跑的就是 MEDIUM）")
	_h.expect(PlanarShadow.enabled_for_tier(VFXQualityBudget.Tier.HIGH), "high_tier_disabled", "高画质应挂投影")


## 只看 _add_3d_unit_readability 的函数体、去掉注释后的代码形状，
## 免得注释里的字样把断言喂饱（见 tools 里 source.contains 的老坑）。
func _check_renderer_call() -> void:
	var body := _function_body(FileAccess.get_file_as_string(RENDERER_PATH), "_add_3d_unit_readability")
	if not _h.expect(not body.is_empty(), "renderer_function_missing", "BattleRenderer 里找不到 _add_3d_unit_readability"):
		return
	var code := _strip_comments(body)
	_h.expect(code.contains("UnitPlanarShadowScript.enabled_for_tier(VFXManager.get_quality_tier())"),
			"renderer_tier_gate_missing", "影子开关必须按当前画质档决定")
	_h.expect(code.contains("UnitPlanarShadowScript.attach(model, battle_unit_y_offset)"), "renderer_attach_missing",
			"_add_3d_unit_readability 没有给模型挂投影，或没把单位站立高度传进去（战斗单位站在 y=1.0，不是 0）")
	_h.expect(code.contains("UnitContactShadowScript.create(\"GroundShadow3D\", Vector2.ONE * 0.62 * shadow_scale)"),
			"core_scale_missing", "挂了投影后脚底圆应按 shadow_scale 缩小")
	_h.expect(code.contains("glow_mesh.size = Vector2.ONE * 0.72 * footprint_scale"),
			"team_ring_scaled", "队伍光圈必须仍按 footprint_scale，不能跟着影子核心一起缩")


func _check_model(unit_id: String, spec: Dictionary) -> void:
	var originals: Array[Dictionary] = []
	for path in spec.materials:
		var material := load(path) as Material
		if not _h.expect(material != null, "material_missing", "%s: %s 读不到" % [unit_id, path]):
			return
		originals.append({"path": path, "material": material, "chain": _chain_signature(material)})
	var scene := load(str(spec.scene)) as PackedScene
	if not _h.expect(scene != null, "scene_missing", "%s: %s 读不到" % [unit_id, spec.scene]):
		return
	var models: Array[Node3D] = []
	for i in 2:
		var model := scene.instantiate() as Node3D
		add_child(model)
		models.append(model)
	await get_tree().process_frame
	var geometry_before := _geometry_count(models[0])
	for model in models:
		PlanarShadow.attach(model, 0.0)
		PlanarShadow.attach(model, 0.0)   # 重复挂必须是空操作
	await get_tree().process_frame
	await get_tree().process_frame
	_h.expect(PlanarShadow.is_attached(models[0]), "not_attached", "%s: 材质链尾没有投影影子" % unit_id)
	_h.expect(_geometry_count(models[0]) == geometry_before, "geometry_added",
			"%s: 挂影子后 GeometryInstance3D 从 %d 变成 %d，光环 overlay 会多出重影" % [unit_id, geometry_before, _geometry_count(models[0])])
	var tails := _planar_counts(models[0])
	_h.expect(tails.meshes > 0 and tails.missing == 0, "mesh_without_shadow",
			"%s: %d 个角色网格里 %d 个没挂上影子" % [unit_id, tails.meshes, tails.missing])
	_h.expect(tails.doubled == 0, "shadow_chained_twice", "%s: 有 %d 个网格的材质链里影子出现了不止一次" % [unit_id, tails.doubled])
	_h.expect(_first_materials(models[0]) == _first_materials(models[1]), "copies_not_shared",
			"%s: 同种单位两个实例拿到了不同的带影子副本，每只单位都会复制一份材质" % unit_id)
	for entry in originals:
		_h.expect(_chain_signature(entry.material) == entry.chain, "shared_resource_mutated",
				"%s: 共享材质 %s 的 next_pass 链被改了，备战 / 预览也会带上影子" % [unit_id, entry.path])
	for model in models:
		model.queue_free()
	await get_tree().process_frame


func _geometry_count(root: Node) -> int:
	var count := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is GeometryInstance3D:
			count += 1
	return count


func _planar_counts(root: Node) -> Dictionary:
	var result := {"meshes": 0, "missing": 0, "doubled": 0}
	var shared := PlanarShadow.shared_material()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if not (node is MeshInstance3D and (node as MeshInstance3D).mesh is ArrayMesh):
			continue
		var mesh_instance := node as MeshInstance3D
		var surfaces := 1 if mesh_instance.material_override != null else mesh_instance.mesh.get_surface_count()
		for surface in surfaces:
			var material := mesh_instance.material_override if mesh_instance.material_override != null else mesh_instance.get_active_material(surface)
			if material == null:
				continue
			result.meshes += 1
			var hits := 0
			while material != null:
				if material == shared:
					hits += 1
				material = material.next_pass
			if hits == 0:
				result.missing += 1
			elif hits > 1:
				result.doubled += 1
	return result


func _first_materials(root: Node) -> Array:
	var ids: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_front()
		stack.append_array(node.get_children())
		if node is MeshInstance3D and (node as MeshInstance3D).mesh is ArrayMesh:
			var mesh_instance := node as MeshInstance3D
			var material := mesh_instance.material_override if mesh_instance.material_override != null else mesh_instance.get_active_material(0)
			ids.append(material.get_instance_id() if material != null else 0)
	return ids


func _chain_signature(material: Material) -> Array:
	var out: Array = []
	while material != null:
		out.append(material.get_instance_id())
		material = material.next_pass
	return out


func _function_body(src: String, name: String) -> String:
	var start := src.find("\nfunc %s(" % name)
	if start < 0:
		return ""
	var next := src.find("\nfunc ", start + 1)
	return src.substr(start, (next if next > 0 else src.length()) - start)


func _strip_comments(src: String) -> String:
	var lines: PackedStringArray = []
	for line in src.split("\n"):
		var hash := line.find("#")
		var slashes := line.find("//")
		var cut := -1
		if hash >= 0 and not line.strip_edges().begins_with("\""):
			cut = hash
		if slashes >= 0 and (cut < 0 or slashes < cut):
			cut = slashes
		lines.append(line.substr(0, cut) if cut >= 0 else line)
	return "\n".join(lines)
