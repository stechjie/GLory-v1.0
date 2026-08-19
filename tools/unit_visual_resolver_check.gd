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
	_check_portrait_fallback_chain(entries)
	_check_failure_aggregation()
	_h.note("combat_entries=%d unique_model_scenes=%d portraits=%d" % [entries.size(), unique_model_paths.size(), entries.size()])
	_h.finish(get_tree())


func _check_actor_contract(entries: Array[Dictionary]) -> void:
	# 清单 §8 要求「全部首发单位」而不是抽样：演员合同由 UnitActor3D._ensure_contract()
	# 在构造期建立，不加载任何模型场景，所以全量覆盖依然很快。
	var registry = UnitActorRegistryScript.new()
	var actors: Array[Node3D] = []
	for definition in entries:
		var unit_id := str(definition.get("id", ""))
		var actor = UnitActor3DScript.new()
		actor.name = "CheckActor_%s" % unit_id
		actor.configure_contract(0.98)
		add_child(actor)
		actors.append(actor)
		_h.expect(UnitActorRegistryScript.has_complete_contract(actor),
			"actor_contract", "%s 演员契约不完整" % unit_id)
		_h.expect(registry.register_actor(unit_id, actor),
			"registry_register", "%s 无法注册演员" % unit_id)
		for anchor_name in ["FootAnchor", "HeadAnchor", "CastAnchor", "HitAnchor"]:
			_h.expect(registry.get_anchor(unit_id, anchor_name) != null,
				"anchor_missing", "%s 缺锚点 %s" % [unit_id, anchor_name])
		# 兼容别名：已验收的状态特效和旧截帧工具仍按这两个名字取锚点。
		_h.expect(registry.get_anchor(unit_id, "FeetAnchor") == registry.get_anchor(unit_id, "FootAnchor"),
			"anchor_alias", "%s 的 FeetAnchor 未对齐 FootAnchor" % unit_id)
		_h.expect(registry.get_anchor(unit_id, "BodyAnchor") == registry.get_anchor(unit_id, "HitAnchor"),
			"anchor_alias", "%s 的 BodyAnchor 未对齐 HitAnchor" % unit_id)
	_h.expect(registry.size() == entries.size(),
		"registry_size", "注册表应收录 %d 个演员，实际 %d" % [entries.size(), registry.size()])

	# 清单 §5.4：下一局不得继承上一局的演员。clear() 之后解析必须整体落空。
	registry.clear()
	_h.expect(registry.size() == 0 and registry.ids().is_empty(),
		"registry_clear", "clear() 之后注册表仍有残留演员")
	for definition in entries:
		var unit_id := str(definition.get("id", ""))
		_h.expect(registry.get_actor(unit_id) == null,
			"registry_clear_actor", "%s 在 clear() 之后仍能解析到演员" % unit_id)
		_h.expect(registry.get_anchor(unit_id, "CastAnchor") == null,
			"registry_clear_anchor", "%s 在 clear() 之后仍能解析到锚点" % unit_id)
	for actor in actors:
		actor.queue_free()


# 清单 §8 的后半句：坏模型必须进入立绘 fallback，并把资源路径报进一次性汇总。
func _check_portrait_fallback_chain(entries: Array[Dictionary]) -> void:
	UnitVisualResolverScript.reset_failure_report()
	var samples := ["human_militia", "pve_sky_cloud_eagle", "boss_meteor_caster"]
	for sample_id in samples:
		var matches := entries.filter(func(d: Dictionary) -> bool: return str(d.get("id", "")) == sample_id)
		_h.expect(matches.size() == 1, "sample_missing", "演员检查样本缺失：%s" % sample_id)
		if matches.size() != 1:
			continue
		var definition: Dictionary = (matches[0] as Dictionary).duplicate(true)
		# 把模型指向一个不存在的路径，模拟坏资源/缺场景。
		var broken_path := "res://assets/models/units/__missing__/%s.tscn" % sample_id
		definition["model"] = broken_path
		definition.erase("model_by_element")
		var resolved_path := UnitVisualResolverScript.effective_model_path(definition)
		_h.expect(resolved_path == broken_path,
			"broken_path_resolution", "%s 未解析到被破坏的模型路径" % sample_id)
		_h.expect(not UnitVisualResolverScript.resource_exists(resolved_path),
			"broken_path_exists", "%s 的坏模型路径意外存在，用例失效" % sample_id)
		# 消费者在加载失败时必须报告路径并改用立绘，而不是静默生成胶囊（§0 第 4 条）。
		UnitVisualResolverScript.report_failure(sample_id, resolved_path, "check", "model scene missing")
		var actor = UnitActor3DScript.new()
		actor.name = "FallbackActor_%s" % sample_id
		actor.configure_contract(0.98)
		add_child(actor)
		var portrait_ok: bool = actor.attach_portrait_fallback(
			str(definition.get("portrait", "")),
			str(definition.get("fallback_frame", "")),
			Color(0.25, 0.85, 1.0, 0.58),
			0.98
		)
		_h.expect(portrait_ok, "fallback_portrait", "%s 无法建立立绘 fallback" % sample_id)
		_h.expect(actor.is_portrait_fallback(),
			"fallback_kind", "%s 的 fallback 演员没有标记为立绘" % sample_id)
		_h.expect(UnitActorRegistryScript.has_complete_contract(actor),
			"fallback_contract", "%s 的立绘 fallback 丢失了演员契约" % sample_id)
		actor.queue_free()
	var rows := UnitVisualResolverScript.failure_rows()
	for sample_id in samples:
		var reported := rows.filter(func(row: Dictionary) -> bool:
			return str(row.get("unit_id", "")) == sample_id \
				and str(row.get("resource_path", "")).contains("__missing__"))
		_h.expect(reported.size() == 1,
			"fallback_path_reported", "%s 的坏资源路径没有被恰好报告一次" % sample_id)
	UnitVisualResolverScript.reset_failure_report()

func _check_failure_aggregation() -> void:
	UnitVisualResolverScript.reset_failure_report()
	# 这条路径是**故意**不存在的夹具，用来验证同一坏资源只上报一次。
	UnitVisualResolverScript.report_failure("human_militia", "res://missing_model.tscn", "check", "forced failure")  # asset-manifest-ignore
	UnitVisualResolverScript.report_failure("human_militia", "res://missing_model.tscn", "check", "forced failure")  # asset-manifest-ignore
	_h.expect(UnitVisualResolverScript.failure_rows().size() == 1, "failure_aggregation", "同一资源失败没有聚合为一次")
	UnitVisualResolverScript.reset_failure_report()
