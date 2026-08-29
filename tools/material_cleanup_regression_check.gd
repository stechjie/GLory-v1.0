extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleRendererScript := preload("res://scenes/battle/BattleRenderer.gd")
const CHECK_NAME := "material_cleanup_regression"
const TEMP_MATERIAL_PATH := "user://p005_material_cleanup_fixture.tres"
const ALLOWED_CHANGED_FIELDS := {
	"emission_enabled": true,
	"emission_energy_multiplier": true,
}

var _h: CheckHarness
var _renderer: BattleRendererScript


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_renderer = BattleRendererScript.new()
	BattleRendererScript.clear_for_test()
	_test_base_material_preservation()
	_test_cache_identity_and_state_hash()
	_test_resource_path_state_change()
	_test_shader_material_preservation()
	_test_surface_and_material_overrides()
	_test_cleanup_audit()
	BattleRendererScript.clear_for_test()
	_h.expect(BattleRendererScript.material_cache_count_for_test() == 0,
		"cache_clear_failed", "clear_for_test() 后缓存必须为空")
	_renderer.free()
	_cleanup_temp_fixture()
	_h.finish(get_tree())


func _test_base_material_preservation() -> void:
	BattleRendererScript.clear_for_test()
	var source := _make_base_material(Color(0.24, 0.38, 0.56, 0.72))
	_h.expect(source.resource_path.is_empty(), "fixture_has_path", "无 resource path 用例必须确实为空路径")
	var cleaned := _clean(source)
	_h.expect(cleaned != null, "base_clean_null", "BaseMaterial3D 清理结果不能为空")
	if cleaned == null:
		return
	_h.expect(cleaned != source, "base_not_duplicated", "BaseMaterial3D 必须浅复制，不能改写源材质")
	_h.expect(source.emission_enabled, "source_emission_mutated", "清理不得关闭源材质 emission")
	_h.expect(is_equal_approx(source.emission_energy_multiplier, 3.25),
		"source_energy_mutated", "清理不得改变源材质 emission energy")
	_h.expect(not cleaned.emission_enabled, "emission_not_disabled", "清理副本必须关闭 emission")
	_h.expect(is_zero_approx(cleaned.emission_energy_multiplier),
		"emission_energy_not_zero", "清理副本 emission energy 必须为 0")
	_assert_material_equal_except_emission(source, cleaned, "base")
	_assert_texture_rids_equal(source, cleaned, "base")


func _test_cache_identity_and_state_hash() -> void:
	BattleRendererScript.clear_for_test()
	var source := _make_base_material(Color(0.18, 0.32, 0.47, 1.0))
	var first := _clean(source)
	var second := _clean(source)
	_h.expect(first == second, "cache_miss_same_state", "相同 RID 与状态必须复用同一清理副本")
	_h.expect(BattleRendererScript.material_cache_count_for_test() == 1,
		"cache_count_same_state", "相同状态重复调用后缓存数量应为 1")

	# Same RID, different runtime override. A path/RID-only cache would return first.
	source.albedo_color = Color(0.67, 0.21, 0.14, 1.0)
	var changed := _clean(source)
	_h.expect(changed != first, "cache_stale_after_mutation", "同一 RID 状态变化后不得返回旧副本")
	_h.expect(changed.albedo_color == source.albedo_color,
		"cache_lost_runtime_override", "新副本必须保留运行时 albedo override")
	_h.expect(BattleRendererScript.material_cache_count_for_test() == 2,
		"cache_count_state_change", "同一 RID 的两个状态应产生两个缓存项")

	var local_material := _make_base_material(Color(0.11, 0.62, 0.39, 1.0))
	var local_clean := _clean(local_material)
	_h.expect(local_clean != changed, "empty_path_collision", "两个空路径局部材质不得错误共用副本")
	_h.expect(local_clean.albedo_color == local_material.albedo_color,
		"empty_path_state_lost", "空路径局部材质必须保留自身状态")


func _test_resource_path_state_change() -> void:
	BattleRendererScript.clear_for_test()
	_cleanup_temp_fixture()
	var saved := _make_base_material(Color(0.31, 0.27, 0.58, 1.0))
	var save_error := ResourceSaver.save(saved, TEMP_MATERIAL_PATH)
	_h.expect(save_error == OK, "fixture_save_failed", "无法保存临时同路径材质，error=%d" % save_error)
	if save_error != OK:
		return
	var loaded := ResourceLoader.load(TEMP_MATERIAL_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as ORMMaterial3D
	_h.expect(loaded != null, "fixture_load_failed", "无法重新加载临时同路径材质")
	if loaded == null:
		return
	_h.expect(not loaded.resource_path.is_empty(), "fixture_path_empty", "同路径回归用例必须有 resource_path")
	var first := _clean(loaded)
	loaded.cull_mode = BaseMaterial3D.CULL_FRONT
	loaded.albedo_color = Color(0.76, 0.33, 0.16, 1.0)
	var second := _clean(loaded)
	_h.expect(second != first, "path_cache_stale", "同一路径资源的运行时状态变化不得命中旧副本")
	_h.expect(second.cull_mode == loaded.cull_mode and second.albedo_color == loaded.albedo_color,
		"path_override_lost", "同路径材质的新 cull/albedo 状态必须保留")
	_assert_material_equal_except_emission(loaded, second, "same_path")


func _test_shader_material_preservation() -> void:
	BattleRendererScript.clear_for_test()
	var shader := Shader.new()
	shader.code = "shader_type spatial; uniform vec4 tint : source_color = vec4(0.2, 0.4, 0.8, 1.0); uniform sampler2D detail_tex; void fragment(){ ALBEDO = tint.rgb; }"
	var source := ShaderMaterial.new()
	source.shader = shader
	var texture := _make_texture(Color(0.19, 0.73, 0.44, 1.0))
	source.set_shader_parameter("tint", Color(0.65, 0.22, 0.48, 0.9))
	source.set_shader_parameter("detail_tex", texture)
	var cleaned := _clean(source) as ShaderMaterial
	_h.expect(cleaned != null, "shader_clean_null", "ShaderMaterial 清理结果不能为空")
	if cleaned == null:
		return
	_h.expect(cleaned != source, "shader_not_duplicated", "ShaderMaterial 应保持浅副本缓存合同")
	_h.expect(cleaned.shader == source.shader, "shader_resource_drift", "Shader resource 必须保持同一引用")
	_h.expect(cleaned.get_shader_parameter("tint") == source.get_shader_parameter("tint"),
		"shader_param_drift", "Shader tint 参数不得变化")
	var cleaned_texture := cleaned.get_shader_parameter("detail_tex") as Texture2D
	_h.expect(cleaned_texture != null and cleaned_texture.get_rid() == texture.get_rid(),
		"shader_texture_rid_drift", "Shader texture RID 必须保持一致")
	_assert_material_equal_except_emission(source, cleaned, "shader")


func _test_surface_and_material_overrides() -> void:
	BattleRendererScript.clear_for_test()
	var mesh := _triangle_mesh()
	var imported := _make_base_material(Color(0.15, 0.22, 0.34, 1.0))
	mesh.surface_set_material(0, imported)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	var local_override := _make_base_material(Color(0.82, 0.31, 0.12, 0.8))
	instance.set_surface_override_material(0, local_override)
	var changed: Array = _renderer._disable_mesh_emission(instance)
	var cleaned_surface := instance.get_surface_override_material(0) as BaseMaterial3D
	_h.expect(cleaned_surface != null and cleaned_surface != local_override,
		"surface_override_not_cleaned", "surface override 必须获得独立清理副本")
	_h.expect(cleaned_surface != null and cleaned_surface.albedo_color == local_override.albedo_color,
		"surface_override_state_lost", "surface override 的局部状态必须保留")
	_h.expect(imported.emission_enabled, "mesh_material_mutated", "surface override 清理不得修改 mesh 源材质")
	_expect_only_emission_fields(changed, "surface_override")

	var global_override := _make_base_material(Color(0.42, 0.13, 0.74, 0.66))
	instance.material_override = global_override
	changed = _renderer._disable_mesh_emission(instance)
	var cleaned_override := instance.material_override as BaseMaterial3D
	_h.expect(cleaned_override != null and cleaned_override != global_override,
		"material_override_not_cleaned", "material_override 必须获得独立清理副本")
	_h.expect(cleaned_override != null and cleaned_override.albedo_color == global_override.albedo_color,
		"material_override_state_lost", "material_override 的局部状态必须保留")
	_expect_only_emission_fields(changed, "material_override")
	instance.free()


func _test_cleanup_audit() -> void:
	BattleRendererScript.clear_for_test()
	var root := Node3D.new()
	add_child(root)
	var light := OmniLight3D.new()
	root.add_child(light)
	var instance := MeshInstance3D.new()
	instance.mesh = _triangle_mesh()
	var source := _make_base_material(Color(0.95, 0.96, 0.97, 1.0))
	instance.mesh.surface_set_material(0, source)
	root.add_child(instance)
	var audit: Dictionary = _renderer.cleanup_imported_model_visuals(root)
	_h.expect(light.get_parent() == null, "embedded_light_not_removed", "导入模型内嵌 Light3D 必须从模型树移除")
	_h.expect(int(audit.get("surface_count", 0)) == 1, "audit_surface_count", "material_audit surface_count 应为 1")
	_h.expect(int(audit.get("textured_surface_count", 0)) == 1,
		"audit_texture_count", "material_audit 应识别贴图表面")
	_h.expect(int(audit.get("suspect_white_count", 0)) == 0,
		"audit_false_white", "有 albedo 贴图的近白材质不应判作白模嫌疑")
	var changed: Array = audit.get("cleanup_changed_fields", [])
	_h.expect(not changed.is_empty(), "audit_missing_changes", "material_audit 必须记录实际 emission 改动")
	_expect_only_emission_fields(changed, "material_audit")
	_h.expect(root.get_meta("material_audit", {}) == audit,
		"audit_meta_missing", "清理根节点必须保存 material_audit 元数据")
	root.queue_free()


func _make_base_material(color: Color) -> ORMMaterial3D:
	var material := ORMMaterial3D.new()
	material.albedo_color = color
	material.albedo_texture = _make_texture(Color(0.73, 0.35, 0.19, 1.0))
	material.normal_enabled = true
	material.normal_texture = _make_texture(Color(0.5, 0.5, 1.0, 1.0))
	material.orm_texture = _make_texture(Color(1.0, 0.58, 0.16, 1.0))
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.metallic = 0.37
	material.roughness = 0.68
	material.emission_enabled = true
	material.emission = Color(0.91, 0.42, 0.17, 1.0)
	material.emission_texture = _make_texture(Color(0.84, 0.29, 0.11, 1.0))
	material.emission_energy_multiplier = 3.25
	return material


func _make_texture(color: Color) -> ImageTexture:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _triangle_mesh() -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, 0.0, 0.0),
		Vector3(0.5, 0.0, 0.0),
		Vector3(0.0, 1.0, 0.0),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2(0.5, 1.0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _clean(material: Material) -> Material:
	return _renderer._material_without_emission(material)


func _assert_material_equal_except_emission(source: Material, cleaned: Material, label: String) -> void:
	var before := _material_state(source)
	var after := _material_state(cleaned)
	var names: Dictionary = {}
	for property_name in before.keys():
		names[property_name] = true
	for property_name in after.keys():
		names[property_name] = true
	for property_name in names.keys():
		var name := str(property_name)
		if ALLOWED_CHANGED_FIELDS.has(name):
			continue
		_h.expect(before.has(name) and after.has(name) and _values_equal(before.get(name), after.get(name)),
			"material_field_drift", "%s 非 emission 字段发生漂移：%s" % [label, name])


func _assert_texture_rids_equal(source: BaseMaterial3D, cleaned: BaseMaterial3D, label: String) -> void:
	for property_name in ["albedo_texture", "normal_texture", "orm_texture", "emission_texture"]:
		var before := source.get(property_name) as Texture2D
		var after := cleaned.get(property_name) as Texture2D
		_h.expect(before != null and after != null and before.get_rid() == after.get_rid(),
			"texture_rid_drift", "%s %s 的纹理 RID 必须保持一致" % [label, property_name])


func _material_state(material: Material) -> Dictionary:
	var state: Dictionary = {}
	for property_info in material.get_property_list():
		if (int(property_info.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var property_name := str(property_info.get("name", ""))
		if property_name.is_empty() or property_name == "script" or property_name.begins_with("resource_"):
			continue
		state[property_name] = material.get(property_name)
	return state


func _values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Resource:
		return is_same(a, b)
	return a == b


func _expect_only_emission_fields(fields: Array, label: String) -> void:
	for field_value in fields:
		var field := str(field_value)
		_h.expect(ALLOWED_CHANGED_FIELDS.has(field), "cleanup_field_drift",
			"%s 清理改变了非 emission 字段：%s" % [label, field])


func _cleanup_temp_fixture() -> void:
	var absolute := ProjectSettings.globalize_path(TEMP_MATERIAL_PATH)
	if FileAccess.file_exists(TEMP_MATERIAL_PATH):
		DirAccess.remove_absolute(absolute)
