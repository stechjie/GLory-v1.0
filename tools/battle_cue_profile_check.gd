extends Node

# D5 gate for the cue profiles and their resolver.
#
# Checks two things the rest of the pipeline assumes:
#   * every .tres in data/vfx/battle_cues carries the fields checklist section 6
#     requires, with values that are actually usable;
#   * VfxProfileResolver routes each event to the right profile, degrades to a
#     cheap built-in when one is missing, and aggregates that warning once.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ResolverScript := preload("res://effects/runtime/presentation/VfxProfileResolver.gd")
const ProfileScript := preload("res://effects/runtime/presentation/BattleCueProfile.gd")
const EventSchema := preload("res://scripts/battle/BattlePresentationEvent.gd")
const BudgetScript := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")

const CHECK_NAME := "battle_cue_profile"

# Checklist section 6 lists these as the minimum a profile must configure.
const REQUIRED_FIELDS := [
	"id", "event_types", "priority", "anchors",
	"windup_ms", "impact_ms", "recovery_ms",
	"camera_mode", "audio_cue", "vfx_scene",
	"max_concurrent", "quality_overrides", "fallback_profile",
]

# Anchors may only name nodes from the D3 actor contract.
const LEGAL_ANCHORS := ["ActorRoot", "FootAnchor", "HeadAnchor", "CastAnchor", "HitAnchor", "Shadow"]
const LEGAL_PRIORITIES := ["critical", "important", "ambient"]

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var resolver = ResolverScript.new()
	var loaded := int(resolver.load_profiles())
	_h.expect(loaded == 5, "profile_count", "应加载 5 个 cue profile，实际 %d" % loaded)
	_check_profile_fields(resolver)
	_check_routing(resolver)
	_check_missing_profile_fallback()
	_check_tier_overrides(resolver)
	_check_priority_cost_budget()
	_check_review_comparability()
	_h.note("loaded=%s" % str(resolver.profile_ids()))
	_h.finish(get_tree())


func _check_profile_fields(resolver) -> void:
	for profile_id in resolver.profile_ids():
		var profile: Resource = _profile_of(resolver, str(profile_id))
		if profile == null:
			_h.fail("profile_missing", "无法取得 profile %s" % profile_id)
			continue
		for field in REQUIRED_FIELDS:
			_h.expect(profile.get(field) != null, "field_missing", "%s 缺字段 %s" % [profile_id, field])
		_h.expect(str(profile.get("id")) == str(profile_id),
			"id_mismatch", "%s 的 id 字段与文件名不一致" % profile_id)
		_h.expect(LEGAL_PRIORITIES.has(str(profile.get("priority"))),
			"priority_invalid", "%s 的 priority 非法：%s" % [profile_id, str(profile.get("priority"))])
		_h.expect(not (profile.get("event_types") as PackedStringArray).is_empty(),
			"event_types_empty", "%s 没有声明 event_types" % profile_id)
		_h.expect(profile.total_ms() > 0,
			"timing_zero", "%s 的三段时长全为 0，cue 会瞬间结束" % profile_id)
		_h.expect(int(profile.get("max_concurrent")) > 0,
			"concurrency_zero", "%s 的 max_concurrent 必须为正" % profile_id)
		var anchors: Dictionary = profile.get("anchors")
		for role_value in anchors.keys():
			var anchor_name := str(anchors[role_value])
			_h.expect(LEGAL_ANCHORS.has(anchor_name),
				"anchor_illegal", "%s 的 %s 锚点 %s 不在 D3 演员合同内" % [profile_id, str(role_value), anchor_name])
		var fallback := str(profile.get("fallback_profile"))
		if not fallback.is_empty():
			_h.expect(resolver.has_profile(fallback),
				"fallback_dangling", "%s 声明的 fallback_profile %s 不存在" % [profile_id, fallback])


# Every event the D4 chain produces must land on the intended profile.
func _check_routing(resolver) -> void:
	var cases := [
		{"event": {"type": "attack_start", "skill_id": "basic_melee"}, "want": "basic_melee"},
		{"event": {"type": "attack_start", "skill_id": "basic_ranged"}, "want": "basic_ranged"},
		{"event": {"type": "projectile_spawn", "skill_id": "basic_ranged"}, "want": "basic_ranged"},
		{"event": {"type": "impact", "skill_id": "basic_melee", "is_crit": false}, "want": "basic_melee"},
		{"event": {"type": "impact", "skill_id": "basic_melee", "is_crit": true}, "want": "crit"},
		{"event": {"type": "death"}, "want": "death"},
		{"event": {"type": "heal"}, "want": "heal"},
		{"event": {"type": "hit_number", "kind": "heal"}, "want": "heal"},
	]
	for case in cases:
		var resolved: Resource = resolver.resolve(case["event"])
		_h.expect(str(resolved.get("id")) == str(case["want"]),
			"routing", "%s 应解析到 %s，实际 %s" % [
				str((case["event"] as Dictionary).get("type", "")), str(case["want"]), str(resolved.get("id"))])

	# A type with no profile yet is legitimate and must not crash or drop.
	var unknown: Resource = resolver.resolve({"type": "skill_shake"})
	_h.expect(str(unknown.get("id")) == "fallback_minimal",
		"unknown_type_fallback", "未覆盖的事件类型应落到内建 fallback")
	_h.expect(str(unknown.get("priority")) == "ambient",
		"fallback_priority", "内建 fallback 必须是 ambient，才可被预算优先合并")


func _check_missing_profile_fallback() -> void:
	# A resolver that never loaded anything is the worst case: every cue must still
	# resolve to the cheap built-in, and the warning must aggregate to one row.
	var empty_resolver = ResolverScript.new()
	empty_resolver.reset_reports()
	for i in 5:
		var resolved: Resource = empty_resolver.resolve({"type": "impact", "skill_id": "basic_melee"})
		_h.expect(str(resolved.get("id")) == "fallback_minimal",
			"empty_resolver_fallback", "无 profile 时应使用内建 fallback")
	var rows: Array = empty_resolver.missing_rows()
	_h.expect(rows.size() == 1,
		"missing_aggregation", "同一 type/profile 的缺失告警应只聚合成 1 条，实际 %d" % rows.size())


func _check_tier_overrides(resolver) -> void:
	var previous = BudgetScript.tier
	for profile_id in resolver.profile_ids():
		var profile: Resource = _profile_of(resolver, str(profile_id))
		if profile == null:
			continue
		var high: Dictionary = profile.resolved_for_tier("HIGH")
		var low: Dictionary = profile.resolved_for_tier("LOW")
		# An override may only make a cue cheaper; it can never buy more budget.
		_h.expect(int(low.get("max_concurrent", 0)) <= int(high.get("max_concurrent", 0)),
			"override_grows", "%s 的 LOW 档 max_concurrent 大于 HIGH 档" % profile_id)
		if str(profile.get("priority")) == "critical":
			# Checklist 7 D5: a budget overflow may degrade, never make a critical
			# cue disappear. A low tier must still leave it visible.
			_h.expect(int(low.get("recovery_ms", 0)) > 0 or int(low.get("impact_ms", 0)) > 0,
				"critical_vanishes", "%s 是 critical，低档退化后仍必须有可见时长" % profile_id)
	BudgetScript.tier = BudgetScript.Tier.LOW
	_h.expect(ResolverScript.tier_name() == "LOW", "tier_name_low", "tier_name() 未跟随 LOW 档")
	BudgetScript.tier = BudgetScript.Tier.HIGH
	_h.expect(ResolverScript.tier_name() == "HIGH", "tier_name_high", "tier_name() 未跟随 HIGH 档")
	BudgetScript.tier = previous

	# Priority budgets: critical is uncapped, the others are not.
	_h.expect(BudgetScript.max_cues_per_tick("critical") < 0,
		"critical_uncapped", "critical 每 tick 上限必须是无限")
	_h.expect(BudgetScript.max_live_cues("critical") < 0,
		"critical_live_uncapped", "critical 存活上限必须是无限")
	_h.expect(BudgetScript.max_cues_per_tick("important") > 0,
		"important_capped", "important 必须有每 tick 上限")
	_h.expect(is_equal_approx(BudgetScript.recovery_scale_when_over_budget("critical"), 1.0),
		"critical_no_degrade", "critical 超预算时不得缩短收招")
	_h.expect(BudgetScript.recovery_scale_when_over_budget("important") < 1.0,
		"important_degrades", "important 超预算时应缩短收招")
	_h.expect(not BudgetScript.may_merge("critical") and not BudgetScript.may_merge("important"),
		"merge_scope", "只有 ambient 允许合并")


# B4: the other half of the budget. D5 capped how many cues may run; this caps how
# expensive each one may be. The invariant is the same everywhere: an overflow may
# only make a cue cheaper, and a critical cue is never made cheaper at all.
func _check_priority_cost_budget() -> void:
	var previous = BudgetScript.tier
	for tier_value in [BudgetScript.Tier.LOW, BudgetScript.Tier.MEDIUM, BudgetScript.Tier.HIGH]:
		BudgetScript.tier = tier_value
		var label := str(tier_value)
		# critical keeps the full tier allowance, on every tier.
		_h.expect(BudgetScript.particle_count_for(100, "critical") == BudgetScript.particle_count(100),
			"critical_particles", "tier %s：critical 的粒子数被削减了" % label)
		_h.expect(BudgetScript.auxiliary_layers_for(3, "critical") == BudgetScript.auxiliary_layers(3),
			"critical_layers", "tier %s：critical 的附加层被削减了" % label)
		_h.expect(BudgetScript.max_simultaneous_effects_for("critical") < 0,
			"critical_concurrency", "tier %s：critical 的并发必须不设限" % label)
		# ambient is never more expensive than important, which is never more than critical.
		var amb := BudgetScript.particle_count_for(100, "ambient")
		var imp := BudgetScript.particle_count_for(100, "important")
		var crit := BudgetScript.particle_count_for(100, "critical")
		_h.expect(amb <= imp and imp <= crit,
			"particle_ordering", "tier %s：粒子预算未按 ambient <= important <= critical 排序（%d/%d/%d）" % [label, amb, imp, crit])
		_h.expect(BudgetScript.distortion_layers_for(3, "ambient") <= BudgetScript.distortion_layers_for(3, "important"),
			"distortion_ordering", "tier %s：ambient 的透明叠层多于 important" % label)
		_h.expect(BudgetScript.max_simultaneous_effects_for("ambient") <= BudgetScript.max_simultaneous_effects_for("important"),
			"concurrency_ordering", "tier %s：ambient 的并发上限高于 important" % label)
		# a priority may never buy more than the tier itself allows.
		_h.expect(imp <= BudgetScript.particle_count(100),
			"priority_over_tier", "tier %s：important 的粒子数超过了档位允许值" % label)
		_h.expect(not BudgetScript.allow_dynamic_light_for("ambient") or BudgetScript.allow_dynamic_light(),
			"light_over_tier", "tier %s：ambient 在档位禁用动态光时仍然放行" % label)
	BudgetScript.tier = BudgetScript.Tier.LOW
	_h.expect(not BudgetScript.allow_dynamic_light_for("ambient"),
		"low_ambient_light", "LOW 档的 ambient cue 不应有动态光")
	_h.expect(BudgetScript.particle_count_for(100, "critical") > 0,
		"low_critical_visible", "LOW 档的 critical cue 仍必须有粒子——降级不等于消失")
	BudgetScript.tier = previous

	# The ambient context must not leak: a cue that forgets to clear would silently
	# starve or over-spend the next, unrelated one.
	BudgetScript.begin_cue_priority("ambient")
	_h.expect(BudgetScript.current_cue_priority() == "ambient",
		"cue_context_set", "begin_cue_priority() 没有生效")
	BudgetScript.clear_cue_priority()
	_h.expect(BudgetScript.current_cue_priority() == "important",
		"cue_context_cleared", "clear_cue_priority() 应回到 important 默认值")
	BudgetScript.begin_cue_priority("nonsense")
	_h.expect(BudgetScript.current_cue_priority() == "important",
		"cue_context_invalid", "非法优先级应退回 important，而不是被原样接受")
	BudgetScript.clear_cue_priority()


# B5: the review scene compares a candidate profile set against the live one on the
# same fixed battle. Two things have to hold for that comparison to mean anything.
func _check_review_comparability() -> void:
	# 1. The candidate directory must load the same five profiles, or side B would be
	#    silently running on the built-in fallback and the comparison would be a lie.
	var candidate = ResolverScript.new()
	var loaded := int(candidate.load_profiles_from("res://data/vfx/battle_cues_candidate/"))
	_h.expect(loaded == 5,
		"candidate_profiles", "候选 profile 目录应加载 5 个，实际 %d —— 少了的话对照的 B 侧会悄悄跑内建 fallback" % loaded)
	_h.expect(candidate.profile_dir() == "res://data/vfx/battle_cues_candidate/",
		"candidate_dir", "load_profiles_from() 没有记住实际加载的目录")

	# 2. The override seam must default to empty. If it ever leaked a value, every
	#    normal battle would quietly load whatever the last review run pointed at.
	_h.expect(ResolverScript.review_profile_dir_override.is_empty(),
		"override_leaked", "review_profile_dir_override 不为空 —— 正式流程会被评审场景的残留值劫持")

	# 3. The fixed battle fixture must be shared, not copy-pasted. The review scene
	#    originally set only the seed and the round, so its replay was always empty.
	for path in ["res://scripts/qa/battle_presentation_baseline.gd", "res://scenes/debug/BattleVfxReview.gd"]:
		var source := FileAccess.get_file_as_string(path)
		_h.expect(not source.is_empty(), "source_missing", "读不到 %s" % path)
		_h.expect(source.contains("FixedBattleFixture"),
			"fixture_not_shared", "%s 必须使用共享的 FixedBattleFixture，否则固定战斗会各跑各的" % path)


func _profile_of(resolver, profile_id: String) -> Resource:
	# resolve() is the only public accessor; drive it with an event that is known to
	# route to this profile so the check exercises the real path.
	match profile_id:
		"basic_melee":
			return resolver.resolve({"type": "attack_start", "skill_id": "basic_melee"})
		"basic_ranged":
			return resolver.resolve({"type": "attack_start", "skill_id": "basic_ranged"})
		"crit":
			return resolver.resolve({"type": "impact", "skill_id": "basic_melee", "is_crit": true})
		"heal":
			return resolver.resolve({"type": "heal"})
		"death":
			return resolver.resolve({"type": "death"})
	return null
