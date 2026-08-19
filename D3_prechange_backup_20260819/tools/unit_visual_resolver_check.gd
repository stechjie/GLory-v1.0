extends Node

const CheckHarness := preload("res://tools/CheckHarness.gd")
const UnitVisualResolverScript := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const UnitActor3DScript := preload("res://effects/runtime/presentation/UnitActor3D.gd")
const UnitActorRegistryScript := preload("res://effects/runtime/presentation/UnitActorRegistry.gd")
const BattleAssetManifestScript := preload("res://scripts/assets/BattleAssetManifest.gd")
const CHECK_NAME := "unit_visual_resolver"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var entries := UnitVisualResolverScript.all_combat_entries()
	_h.expect(entries.size() == 74, "combat_count", "可战斗单位应为 74，实际 %d" % entries.size())
	var ids: Dictionary = {}
	var unique_model_paths: Dictionary = {}
	for definition in entries:
		var unit_id := str(definition.get("id", ""))
		_h.expect(not unit_id.is_empty(), "empty_id", "发现空 unit id")
		_h.expect(not ids.has(unit_id), "duplicate_id", "重复 unit id：%s" % unit_id)
		ids[unit_id] = true
		var portrait_path := str(definition.get("portrait", ""))
		_h.expect(UnitVisualResolverScript.resource_exists(portrait_path), "portrait_missing", "%s 立绘缺失：%s" % [unit_id, portrait_path])
		for model_path in UnitVisualResolverScript.all_model_paths(definition):
			unique_model_paths[model_path] = true
			_h.expect(UnitVisualResolverScript.resource_exists(model_path), "model_missing", "%s 模型缺失：%s" % [unit_id, model_path])
	_h.expect(unique_model_paths.size() == 75, "model_path_count", "基础模型+元素变体应为 75 个唯一场景，实际 %d" % unique_model_paths.size())

	var twin_value = entries.filter(func(d: Dictionary) -> bool: return str(d.get("id", "")) == "boss_twin_gate")
	_h.expect(twin_value.size() == 1, "twin_missing", "双生守门人定义缺失")
	if twin_value.size() == 1:
		var twin_sky := (twin_value[0] as Dictionary).duplicate(true)
		twin_sky["element"] = "sky"
		var resolved_sky := UnitVisualResolverScript.resolve_definition("boss_twin_gate", twin_sky)
		_h.expect(str(resolved_sky.get("model", "")).contains("/sky/"), "variant_resolution", "双生守门人 sky 变体未解析到 sky 模型")
		var replay_paths := BattleAssetManifestScript.replay_paths({"roster": {"twin": {"def": twin_value[0]}}})
		_h.expect(replay_paths.any(func(path: String) -> bool: return path.contains("/land/")), "variant_prefetch_land", "双生守门人 land 变体未进入预取清单")
		_h.expect(replay_paths.any(func(path: String) -> bool: return path.contains("/sky/")), "variant_prefetch_sky", "双生守门人 sky 变体未进入预取清单")

	_check_actor_contract(entries)
	_check_failure_aggregation()
	_h.note("combat_entries=%d unique_model_scenes=%d portraits=%d" % [entries.size(), unique_model_paths.size(), entries.size()])
	_h.finish(get_tree())


func _check_actor_contract(entries: Array[Dictionary]) -> void:
	var registry = UnitActorRegistryScript.new()
	for sample_id in ["human_militia", "pve_sky_cloud_eagle", "boss_meteor_caster"]:
		var matches := entries.filter(func(d: Dictionary) -> bool: return str(d.get("id", "")) == sample_id)
		_h.expect(matches.size() == 1, "sample_missing", "演员检查样本缺失：%s" % sample_id)
		if matches.size() != 1:
			continue
		var definition: Dictionary = matches[0]
		var actor = UnitActor3DScript.new()
		actor.name = "CheckActor_%s" % sample_id
		actor.configure_contract(0.98)
		var portrait_ok: bool = actor.attach_portrait_fallback(
			str(definition.get("portrait", "")),
			str(definition.get("fallback_frame", "")),
			Color(0.25, 0.85, 1.0, 0.58),
			0.98
		)
		add_child(actor)
		_h.expect(portrait_ok, "fallback_portrait", "%s 无法建立立绘 fallback" % sample_id)
		_h.expect(UnitActorRegistryScript.has_complete_contract(actor), "actor_contract", "%s 演员契约不完整" % sample_id)
		_h.expect(registry.register_actor(sample_id, actor), "registry_register", "%s 无法注册演员" % sample_id)
		for anchor_name in ["FootAnchor", "HeadAnchor", "CastAnchor", "HitAnchor"]:
			_h.expect(registry.get_anchor(sample_id, anchor_name) != null, "anchor_missing", "%s 缺锚点 %s" % [sample_id, anchor_name])
		actor.queue_free()
	registry.clear()


func _check_failure_aggregation() -> void:
	UnitVisualResolverScript.reset_failure_report()
	UnitVisualResolverScript.report_failure("human_militia", "res://missing_model.tscn", "check", "forced failure")
	UnitVisualResolverScript.report_failure("human_militia", "res://missing_model.tscn", "check", "forced failure")
	_h.expect(UnitVisualResolverScript.failure_rows().size() == 1, "failure_aggregation", "同一资源失败没有聚合为一次")
	UnitVisualResolverScript.reset_failure_report()
