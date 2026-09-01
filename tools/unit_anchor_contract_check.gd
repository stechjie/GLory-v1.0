extends Node

# V2 P1-04 第 3、4 条的门禁：脚底基准/目标高度统一，且**不允许所有角色共用同一个
# 高度常量**。
#
# 背景（2026-08-29 实测 registry）：模型缩放按类型分档 —— 普通单位 1.0（32 个全是）、
# 援军 1.15、Boss **2.0**、佣兵 11 个 1.0 加 1 个 2.0。但改前 BattleRenderer 算锚点
# 高度时压根不看 model_visual_scale，所有人都按 0.98 算（T3 乘 1.12）。于是 Boss
# 渲染高约 1.9、锚点却按 1.098 走：头顶状态图标挂在胸口，投射物瞄在半腰。
#
# 为什么必须遍历整个 registry 而不是只看采样回合：固定 seed 的 round 1 / round 21
# 里**一个 Boss 都没有**（缩放全是 1.0，只有两个 1.15 的援军）。也就是说这个 bug
# 最严重的那一档，截图和基线都覆盖不到 —— 只有把 75 个战斗条目全跑一遍才守得住。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BattleRendererScript := preload("res://scenes/battle/BattleRenderer.gd")
const UnitActor3DScript := preload("res://effects/runtime/presentation/UnitActor3D.gd")
const VisualResolver := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const CHECK_NAME := "unit_anchor_contract"

# CastAnchor 之外的锚点比例与类型无关 —— 同一场里状态图标必须高低一致。
const EXPECTED_HEAD_RATIO := 1.02
const EXPECTED_HIT_RATIO := 0.55
const EXPECTED_FOOT_RATIO := 0.05

# 出手点的合理区间。低于腰、高于头顶都说明配错了。
const CAST_RATIO_MIN := 0.40
const CAST_RATIO_MAX := 0.90

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var entries := VisualResolver.all_combat_entries()
	if not _h.expect(entries.size() >= 50, "registry_too_small",
		"只解析到 %d 个战斗条目，registry 没加载全" % entries.size()):
		_h.finish(get_tree())
		return

	_check_height_follows_scale(entries)
	_check_height_is_not_one_constant(entries)
	_check_archetype_classification(entries)
	_check_cast_ratio_is_tiered()
	_check_anchors_actually_placed()
	_check_other_ratios_are_uniform()
	_h.finish(get_tree())


# 核心一条：锚点高度必须与模型实际缩放成正比。
func _check_height_follows_scale(entries: Array) -> void:
	var nominal: float = BattleRendererScript.NOMINAL_UNIT_HEIGHT
	var boost: float = BattleRendererScript.TIER3_VISUAL_BOOST
	var worst := ""
	for entry in entries:
		var def_dict: Dictionary = entry
		var scale := float(def_dict.get("model_visual_scale", 1.0))
		var want := nominal * scale
		if int(def_dict.get("tier", 1)) == 3:
			want *= boost
		var got: float = BattleRendererScript.anchor_height_for(def_dict)
		if not is_equal_approx(got, want):
			worst = "%s: 缩放 %.2f / tier %s -> 锚点高度 %.4f，应为 %.4f" % [
				str(def_dict.get("id", "?")), scale, str(def_dict.get("tier", "?")), got, want]
			break
	_h.expect(worst.is_empty(), "height_ignores_scale",
		"锚点高度没跟着 model_visual_scale 走。%s" % worst)

	# Boss 那一档单独点名：它是这个 bug 影响最大的地方，且采样回合覆盖不到。
	var boss_heights: Array[float] = []
	var plain_heights: Array[float] = []
	for entry in entries:
		var def_dict: Dictionary = entry
		var h: float = BattleRendererScript.anchor_height_for(def_dict)
		if float(def_dict.get("model_visual_scale", 1.0)) >= 2.0:
			boss_heights.append(h)
		elif is_equal_approx(float(def_dict.get("model_visual_scale", 1.0)), 1.0) \
				and int(def_dict.get("tier", 1)) != 3:
			plain_heights.append(h)
	if not _h.expect(not boss_heights.is_empty(), "no_double_scale_entry",
		"registry 里找不到 model_visual_scale >= 2.0 的条目，本条无法验证"):
		return
	if plain_heights.is_empty():
		return
	var min_boss: float = boss_heights.min()
	var max_plain: float = plain_heights.max()
	_h.expect(min_boss > max_plain * 1.5,
		"boss_anchor_not_taller",
		"最矮的 2.0x 单位锚点 %.3f 没有明显高于最高的 1.0x 单位 %.3f —— Boss 的头顶图标会挂在胸口"
			% [min_boss, max_plain])
	_h.note("锚点高度：1.0x 档最高 %.3f，2.0x 档最矮 %.3f" % [max_plain, min_boss])


# V2 明写"不允许所有角色用同一高度常量"。这条把它变成可执行判据。
func _check_height_is_not_one_constant(entries: Array) -> void:
	var distinct := {}
	for entry in entries:
		var def_dict: Dictionary = entry
		distinct[snappedf(BattleRendererScript.anchor_height_for(def_dict), 0.0001)] = true
	_h.expect(distinct.size() >= 3,
		"height_is_single_constant",
		"整个 registry 只解析出 %d 种锚点高度 —— V2 P1-04 要求近战/远程/Boss 分开配置，不能共用一个常量"
			% distinct.size())
	_h.note("registry 共 %d 个条目，%d 种不同的锚点高度" % [entries.size(), distinct.size()])


func _check_archetype_classification(entries: Array) -> void:
	var counts := {"melee": 0, "ranged": 0, "boss": 0}
	var bad := ""
	for entry in entries:
		var def_dict: Dictionary = entry
		var got := VisualResolver.archetype_for(def_dict)
		if not counts.has(got):
			bad = "%s 被分成了未知类型 '%s'" % [str(def_dict.get("id", "?")), got]
			break
		counts[got] += 1
		# 反向验一遍：分类必须能由 kind/range 复算出来。
		var kind := str(def_dict.get("visual_kind", ""))
		var want := "boss" if kind == "boss" \
			else ("ranged" if float(def_dict.get("range", 1.0)) >= VisualResolver.RANGED_MIN_RANGE else "melee")
		if got != want:
			bad = "%s: kind=%s range=%s 应为 %s，实际 %s" % [
				str(def_dict.get("id", "?")), kind, str(def_dict.get("range", "?")), want, got]
			break
	_h.expect(bad.is_empty(), "archetype_misclassified", bad)
	for key in ["melee", "ranged", "boss"]:
		_h.expect(int(counts[key]) > 0,
			"archetype_empty",
			"没有任何条目被分成 %s —— 分档等于没生效" % key)
	_h.note("分类：近战 %d、远程 %d、Boss %d" % [counts["melee"], counts["ranged"], counts["boss"]])


func _check_cast_ratio_is_tiered() -> void:
	var table: Dictionary = UnitActor3DScript.CAST_RATIO_BY_ARCHETYPE
	for key in ["melee", "ranged", "boss"]:
		if not _h.expect(table.has(key), "cast_ratio_missing",
			"CAST_RATIO_BY_ARCHETYPE 缺少 %s" % key):
			continue
		var ratio := float(table[key])
		_h.expect(ratio >= CAST_RATIO_MIN and ratio <= CAST_RATIO_MAX,
			"cast_ratio_out_of_band",
			"%s 的出手点比例 %.3f 不在 %.2f-%.2f —— 会出手在脚下或头顶之上"
				% [key, ratio, CAST_RATIO_MIN, CAST_RATIO_MAX])
	# 远程必须比近战高：这是分档存在的理由，全相等就等于没分。
	_h.expect(float(table.get("ranged", 0.0)) > float(table.get("melee", 1.0)),
		"cast_ratio_not_tiered",
		"远程出手点 %.3f 不高于近战 %.3f —— 三档配成了同一个值，分档形同虚设"
			% [float(table.get("ranged", 0.0)), float(table.get("melee", 1.0))])


# 上面都是算术。这条真建一个 actor，确认锚点节点确实落在 高度 x 比例 上。
func _check_anchors_actually_placed() -> void:
	var cases := [
		{"archetype": "melee", "height": 0.98},
		{"archetype": "ranged", "height": 0.98},
		{"archetype": "boss", "height": 1.96},
	]
	for case_value in cases:
		var case_dict: Dictionary = case_value
		var height := float(case_dict["height"])
		var archetype := str(case_dict["archetype"])
		var actor: Node3D = UnitActor3DScript.new()
		add_child(actor)
		actor.configure_contract(height, archetype)

		var want_cast := height * float(UnitActor3DScript.CAST_RATIO_BY_ARCHETYPE[archetype])
		var expected := {
			"HeadAnchor": height * EXPECTED_HEAD_RATIO,
			"HitAnchor": height * EXPECTED_HIT_RATIO,
			"FootAnchor": height * EXPECTED_FOOT_RATIO,
			"CastAnchor": want_cast,
		}
		for anchor_name in expected:
			var anchor := actor.get_node_or_null(str(anchor_name)) as Node3D
			if not _h.expect(anchor != null, "anchor_missing",
				"%s 档缺少锚点 %s" % [archetype, anchor_name]):
				continue
			_h.expect(is_equal_approx(anchor.position.y, float(expected[anchor_name])),
				"anchor_misplaced",
				"%s 档 %s 落在 y=%.4f，应为 %.4f" % [
					archetype, anchor_name, anchor.position.y, float(expected[anchor_name])])
		# 脚底必须贴近地面，否则角色会看起来浮空（V2 验收原话："不贴地漂浮"）。
		var foot := actor.get_node_or_null("FootAnchor") as Node3D
		if foot != null:
			_h.expect(foot.position.y < height * 0.12,
				"foot_not_grounded",
				"%s 档脚底锚点在 y=%.4f，占身高 %.1f%% —— 会读成浮空"
					% [archetype, foot.position.y, 100.0 * foot.position.y / height])
		actor.queue_free()


# 回归护栏：除了 CastAnchor，其余比例必须与类型无关。
# 谁把头顶/受击/脚底也分档，同一场里的状态图标就会高低不齐。
func _check_other_ratios_are_uniform() -> void:
	var heights := 1.23
	var by_archetype := {}
	for archetype in ["melee", "ranged", "boss"]:
		var actor: Node3D = UnitActor3DScript.new()
		add_child(actor)
		actor.configure_contract(heights, archetype)
		by_archetype[archetype] = {
			"head": (actor.get_node("HeadAnchor") as Node3D).position.y,
			"hit": (actor.get_node("HitAnchor") as Node3D).position.y,
			"foot": (actor.get_node("FootAnchor") as Node3D).position.y,
			"cast": (actor.get_node("CastAnchor") as Node3D).position.y,
		}
		actor.queue_free()
	var base: Dictionary = by_archetype["melee"]
	for archetype in ["ranged", "boss"]:
		var other: Dictionary = by_archetype[archetype]
		for key in ["head", "hit", "foot"]:
			_h.expect(is_equal_approx(float(other[key]), float(base[key])),
				"non_cast_anchor_tiered",
				"%s 档的 %s 锚点是 %.4f，与近战的 %.4f 不同 —— 只有 CastAnchor 该分档"
					% [archetype, key, float(other[key]), float(base[key])])
		_h.expect(not is_equal_approx(float(other["cast"]), float(base["cast"])),
			"cast_anchor_not_tiered",
			"%s 档的出手点与近战完全相同 —— 分档没有生效" % archetype)
