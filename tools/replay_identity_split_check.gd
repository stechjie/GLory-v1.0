extends Node

# V2 收尾 G1：玩法回放身份与完整回放载荷的 SHA 拆账合同。
#
# 为什么要拆：表现层改动不应该让「玩法回放身份」变化，但完整载荷仍必须对任何
# 字段变化敏感。两件事以前挤在同一个 `replay_sha256` 里 —— 2026-09-02 的根位移
# 批次真的撞上了：`final_state` 三个回合逐字节相同，`replay_sha256` 却全变，
# 差异定位下去只有一处，是 5 个 roster 条目多了 `model_in_place_actions`
# 这个纯表现配置。当时无法回答「模拟到底变没变」，只能把决定权交回给人。
#
# 这条门禁锁住拆完之后的四条合同。**每一条都必须双向可证伪** ——
# 光断言「注入表现字段后 simulation 不变」是不够的：如果投影函数写成恒返回 {}，
# 那条断言照样通过。所以每一类变异都同时断言「哪个必须变」和「哪个必须不变」。
#
# 合同：
#
# | 变异                            | simulation | payload |
# |---------------------------------|------------|---------|
# | 同一 replay 重算两次            | 不变       | 不变    |
# | roster.def 注入表现字段          | **不变**   | **必变**，首差异能定位到该字段 |
# | 改一帧 HP / result / roster 身份 | **必变**   | **必变** |
# | 改 frame_events                 | **不变**   | **必变** |
#
# 白名单是**正向**的（`ReplayDigest.SIMULATION_ROSTER_FIELDS`）：
# 黑名单会随新字段静默失效，白名单加字段必须有人显式改那里。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ReplayDigest := preload("res://scripts/qa/ReplayDigest.gd")

const CHECK_NAME := "replay_identity_split"

# 构造一份结构与真实回放一致的最小样本。用真实模拟跑一局会把这条门禁的
# 运行时间和依赖面都拉大，而这里要验的是**投影与哈希的合同**，
# 不是模拟本身 —— 模拟的确定性归 determinism_check。
func _sample() -> Dictionary:
	return {
		"kind": "pve",
		"frames": [
			[{"uid": "p1", "hp": 100}, {"uid": "e1", "hp": 80}],
			[{"uid": "p1", "hp": 92}, {"uid": "e1", "hp": 61}],
		],
		"frame_events": [
			[{"t": "hit", "src": "p1", "dst": "e1", "amount": 19}],
			[{"t": "hit", "src": "e1", "dst": "p1", "amount": 8}],
		],
		"result": {"winner": "player", "rounds": 2},
		"roster": {
			"p1": {
				"uid": "p1", "id": "human_militia", "name": "民兵", "name_en": "Militia",
				"team": "player", "lane": 0, "max_hp": 100,
				"is_mercenary": false, "is_formation_ally": false,
				"star": 1, "footprint_cells": 1, "owner_slot": 0,
				# 故意写不存在的路径：这里只需要 def 里有几个表现字段供投影丢弃，
				# 不需要它们真的能加载。行尾标记告诉 asset_manifest_check 别当缺失报。
				"def": {"model": "res://fixture_a.tscn", "portrait": "res://fixture_a.png"},  # asset-manifest-ignore
			},
			"e1": {
				"uid": "e1", "id": "pve_land_rock_beast", "name": "岩兽", "name_en": "Rock Beast",
				"team": "enemy", "lane": 1, "max_hp": 80,
				"is_mercenary": false, "is_formation_ally": false,
				"star": 2, "footprint_cells": 1, "owner_slot": -1,
				"def": {"model": "res://fixture_b.tscn", "portrait": "res://fixture_b.png"},  # asset-manifest-ignore
			},
		},
	}


var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var base := _sample()
	var base_sim := ReplayDigest.simulation_sha256(base)
	var base_pay := ReplayDigest.payload_sha256(base)

	# 非空过守卫：投影写成恒返回 {} 时，下面「表现字段不影响 simulation」
	# 那几条会全部通过。所以先证明投影确实带着内容。
	_h.item()
	_h.expect(not base_sim.is_empty() and not base_pay.is_empty(),
		"hash_failed", "SHA-256 计算失败")
	_h.item()
	_h.expect(base_sim != base_pay, "projection_is_identity",
		("simulation 与 payload 的 SHA 相同 —— 投影没有真的丢掉任何字段，"
			+ "拆账等于没做"))
	var projection := ReplayDigest.simulation_projection(base)
	_h.item()
	_h.expect(projection.has("frames") and not (projection["frames"] as Array).is_empty(),
		"projection_lost_frames", "投影里没有 frames —— 玩法身份成了空壳")
	_h.item()
	_h.expect(not projection.has("frame_events"), "projection_kept_frame_events",
		"投影里含 frame_events —— 演出事件流不属于玩法状态")
	var projected_roster: Dictionary = projection.get("roster", {})
	_h.item()
	_h.expect(projected_roster.size() == 2, "projection_lost_roster",
		"投影里 roster 条目数 %d，应为 2" % projected_roster.size())
	var p1: Dictionary = projected_roster.get("p1", {})
	_h.item()
	_h.expect(not p1.has("def"), "projection_kept_def",
		"投影保留了 roster.def —— 里面混着 model/material/animation 等表现配置")
	_h.item()
	_h.expect(not p1.has("name") and not p1.has("name_en"), "projection_kept_display_name",
		"投影保留了本地化展示串 —— 改文案不该让玩法身份变化")
	_h.item()
	_h.expect(p1.has("max_hp") and p1.has("star") and p1.has("lane"),
		"projection_lost_identity_fields", "投影丢了模拟必需的身份字段")

	_case_recompute(base, base_sim, base_pay)
	_case_presentation_field(base, base_sim, base_pay)
	_case_gameplay_fields(base, base_sim, base_pay)
	_case_frame_events(base, base_sim, base_pay)

	_h.finish(get_tree())


# 1. 同一份 replay 重算两次：两个 SHA 都必须逐字一致。
func _case_recompute(base: Dictionary, base_sim: String, base_pay: String) -> void:
	var again := base.duplicate(true)
	_h.item()
	_h.expect(ReplayDigest.simulation_sha256(again) == base_sim,
		"simulation_not_stable", "同一份 replay 重算，simulation SHA 变了")
	_h.item()
	_h.expect(ReplayDigest.payload_sha256(again) == base_pay,
		"payload_not_stable", "同一份 replay 重算，payload SHA 变了")


# 2. 只在 roster.def 注入表现字段：simulation 不变、payload 必变，
#    且首差异要能定位到那个字段。
func _case_presentation_field(base: Dictionary, base_sim: String, base_pay: String) -> void:
	var mutated := base.duplicate(true)
	var entry: Dictionary = (mutated["roster"] as Dictionary)["p1"]
	var definition: Dictionary = entry["def"]
	definition["model_in_place_actions"] = ["run"]

	_h.item()
	_h.expect(ReplayDigest.simulation_sha256(mutated) == base_sim,
		"presentation_field_moved_simulation",
		"往 roster.def 注入 model_in_place_actions 之后 simulation SHA 变了 —— 表现字段泄进了玩法身份")
	_h.item()
	_h.expect(ReplayDigest.payload_sha256(mutated) != base_pay,
		"presentation_field_invisible_to_payload",
		"注入表现字段之后 payload SHA 没变 —— 完整载荷对字段变化不敏感了")

	var diff := ReplayDigest.first_difference(base, mutated)
	_h.item()
	_h.expect(diff.contains("model_in_place_actions"), "first_difference_lost_field",
		"首差异是 %s，没有定位到注入的字段" % diff)


# 3. 改玩法状态：一帧 HP、result、roster 身份字段，三者都必须让两个 SHA 都变。
func _case_gameplay_fields(base: Dictionary, base_sim: String, base_pay: String) -> void:
	var cases := {
		"frame_hp": func(r: Dictionary) -> void:
			var frame: Array = (r["frames"] as Array)[1]
			(frame[0] as Dictionary)["hp"] = 91,
		"result": func(r: Dictionary) -> void:
			(r["result"] as Dictionary)["winner"] = "enemy",
		"roster_identity": func(r: Dictionary) -> void:
			((r["roster"] as Dictionary)["e1"] as Dictionary)["max_hp"] = 81,
	}
	for label in cases.keys():
		var mutated := base.duplicate(true)
		(cases[label] as Callable).call(mutated)
		_h.item()
		_h.expect(ReplayDigest.simulation_sha256(mutated) != base_sim,
			"gameplay_change_invisible_to_simulation",
			"改了 %s，simulation SHA 却没变 —— 玩法身份漏掉了这个字段" % label)
		_h.item()
		_h.expect(ReplayDigest.payload_sha256(mutated) != base_pay,
			"gameplay_change_invisible_to_payload",
			"改了 %s，payload SHA 却没变" % label)


# 4. 改 frame_events：payload 必变，simulation 按合同保持不变。
func _case_frame_events(base: Dictionary, base_sim: String, base_pay: String) -> void:
	var mutated := base.duplicate(true)
	var bucket: Array = (mutated["frame_events"] as Array)[0]
	(bucket[0] as Dictionary)["t"] = "crit"

	_h.item()
	_h.expect(ReplayDigest.simulation_sha256(mutated) == base_sim,
		"frame_events_moved_simulation",
		"改 frame_events 之后 simulation SHA 变了 —— 演出事件流不该算进玩法身份")
	_h.item()
	_h.expect(ReplayDigest.payload_sha256(mutated) != base_pay,
		"frame_events_invisible_to_payload",
		"改 frame_events 之后 payload SHA 没变 —— 演出确定性失去了保护")
