extends Node

# 9.27 探针 L：钉死"智能选敌"的可行性边界
#
# 探针 K 的关键读数：
#   k1a（1 敌，正后方）: min_dist=37.5  reached=false
#   k1b（3 敌，正后+左后+右后）: min_dist=30.0  reached=**true**  passed_ally=false
#   k1b_locked=e_three_0  ← 它锁定的仍是**正后方那个**
#
# 这两条合起来说明：
#   **毒灵不需要"越过队友"，也能打到侧后方的敌人** ——
#   它停在队友背后时，斜距已经进了近战射程（30 ≤ 32）。
#
# 所以"智能选敌"的机制是成立的：**选一个斜距可达的敌人**，
# 而不是"绕到队友前面去"。
#
# 本探针要回答：
#   L1 侧后方敌人在什么横偏范围内是"可达"的？（扫描横偏）
#   L2 若强制锁定"正后方那个"，是否会一直够不到？（对照）
#   L3 当前选敌逻辑（`_team_select_target`：本路内取**最近**）
#      在 3 敌场景会选谁？为什么它选了正后方那个？
#      —— 因为按 `distance_squared` 算，正后方的**直线距离最短**，
#         所以现有逻辑选了它 → 这就是"不够智能"的确切位置。

const Harness := preload("res://tools/CheckHarness.gd")
const Shared := preload("res://scripts/battle/BattleSimShared.gd")
const Simulator := preload("res://scripts/battle/BattleSimulator.gd")

const PROBE_ID := "poison_reach_927"

var h: RefCounted


func _r(tag: String, value: String) -> void:
	print("PROBE_%s %s=%s" % [PROBE_ID, tag, value])


func _mk(id: String, team: String, lane: int, x: float, y: float,
		hp: int, move_speed: float, range_px: float, uid: String,
		skill_id: String = "") -> Dictionary:
	var d := {
		"id": id, "name": id, "name_en": id,
		"hp": hp, "atk": 12, "def": 0, "attack_speed": 0.5,
		"range_px": range_px, "move_speed_px": move_speed, "footprint_cells": 1,
		"element": "none", "race": "none", "skill_id": skill_id,
		"crit": 0.0, "dodge": 0.0,
	}
	var f := Simulator._fighter_from_def(d, lane, team, lane, 1, 1, false, false)
	f.pos = Vector2(x, y)
	f.uid = uid
	# ★ `_fighter_from_def` **不写** `lane`（生产里是 `_place_in_lane` 写的）。
	#   不补这一行的话 `f.get("lane", -1) == -1`，`_team_select_target` 的分路打分
	#   整段落空、直接走 `_nearest` 兜底 —— L5 的"可达性避让"就永远跑不到，
	#   断言会变成对 `_nearest` 的断言（第一版实测就是这个假绿）。
	f["lane"] = lane
	return f


func _base_state(player: Array, enemy: Array) -> Dictionary:
	return {
		"kind": "pvp", "player": player, "enemy": enemy,
		"elapsed": 0.0, "next_decay": 9999.0, "finished": false,
		"log": [], "player_syn": {}, "enemy_syn": {},
		"enemy_deaths": 0, "total_deaths": 0, "field_death_count": 0,
		"mother_death_counter": 0, "dark_kill_stacks": 0,
		"undead_trait_death_counter": 0, "race_trait_processed_deaths": {},
		"death_history": [], "revive_queue": [],
		"player_kill_gold": 0, "enemy_kill_gold": 0, "kill_gold_by_slot": {},
		"player_kills": [], "enemy_kills": [], "bonus_gold": 0,
		"temporary_deaths": [], "visual_events": [], "unit_stats": {},
	}


# 单敌，横偏 off_x，看最终能否进射程
func _run_one(label: String, off_x: float, ticks: int = 400) -> Dictionary:
	var poison := _mk("undead_poison", "player", 0, 230.0, 470.0, 660,
		3.3 * 55.0, 32.0, "p_%s" % label, "poison_attack")
	var ally := _mk("hymn_wisp", "player", 0, 230.0, 425.0, 900, 0.0, 32.0, "a_%s" % label)
	var foe := _mk("bubble", "enemy", 0, 230.0 + off_x, 180.0, 900000, 0.0, 32.0, "e_%s" % label)
	var st := _base_state([poison, ally], [foe])
	var dmin := INF
	var reached := false
	var attack_ticks := 0
	var prev_hp := int(foe.get("hp", 0))
	for t in ticks:
		Simulator.step_state(st)
		if not bool(poison.get("alive", false)):
			break
		dmin = minf(dmin, float(poison.pos.distance_to(foe.pos)))
		var hp := int(foe.get("hp", 0))
		if hp < prev_hp:
			attack_ticks += 1
		prev_hp = hp
		if dmin <= 33.0:
			reached = true
	return {
		"label": label, "off_x": off_x, "min_dist": dmin, "reached": reached,
		"attack_ticks": attack_ticks,
		"damage": int(foe.get("max_hp", 1)) - int(foe.get("hp", 0)),
		"final_y": float(poison.pos.y),
	}


func _ready() -> void:
	h = Harness.new(PROBE_ID)
	GameState.tutorial_mode = false
	GameState.team_mode = true

	# L1：横偏扫描 —— 找出"可达"的横偏阈值
	var scan := []
	for off in [0.0, 20.0, 30.0, 40.0, 50.0, 60.0, 80.0, 100.0, 140.0]:
		var r := _run_one("o%d" % int(off), off)
		scan.append(r)
		_r("l1_off%03d" % int(off),
			"min_dist=%.1f reached=%s attacks=%d dmg=%d final_y=%.0f" % [
				float(r["min_dist"]), str(r["reached"]), int(r["attack_ticks"]),
				int(r["damage"]), float(r["final_y"])])

	# L1 结论：第一个可达的横偏
	var first_reach := -1.0
	for r in scan:
		if bool(r["reached"]) and first_reach < 0:
			first_reach = float(r["off_x"])
	_r("l1_first_reachable_off_x", "%.0f" % first_reach)

	# L3：现有选敌逻辑在"正后方 + 侧后方"混合场景会选谁
	var poison := _mk("undead_poison", "player", 0, 230.0, 470.0, 660,
		3.3 * 55.0, 32.0, "p_l3", "poison_attack")
	var ally := _mk("hymn_wisp", "player", 0, 230.0, 425.0, 900, 0.0, 32.0, "a_l3")
	var f_front := _mk("bubble", "enemy", 0, 230.0, 180.0, 900000, 0.0, 32.0, "e_front")
	var f_side := _mk("bubble", "enemy", 0, 330.0, 190.0, 900000, 0.0, 32.0, "e_side")
	var enemy: Array = [f_front, f_side]
	var picked := Shared._team_select_target(poison, enemy, false)
	_r("l3_picked_uid", str(picked.get("uid", "<none>")))
	_r("l3_front_dist", "%.1f" % float(poison.pos.distance_to(f_front.pos)))
	_r("l3_side_dist", "%.1f" % float(poison.pos.distance_to(f_side.pos)))

	# ---------- 判据 ----------
	# ① 正后方敌人：够不到
	var r0: Dictionary = scan[0]
	h.call("expect", not bool(r0["reached"]), "front_foe_unreachable",
		"正后方敌人（横偏 0）：reached=%s —— 够不到" % str(r0["reached"]))
	# ② 存在某个横偏阈值，超过后可达（证明"换个敌人"有效）
	h.call("expect", first_reach > 0.0, "lateral_foe_reachable",
		"横偏 ≥ %.0f 的敌人可达 —— **换目标确实能解决**" % first_reach)
	# ③ 现有选敌逻辑选的是"直线距离最近"的那个（=正后方）
	h.call("expect", str(picked.get("uid", "")) == "e_front",
		"current_picker_chooses_nearest",
		"现有 `_team_select_target` 选了 %s（直线距离最近）—— 这就是「不够智能」的确切位置"
			% str(picked.get("uid", "<none>")))

	# ---------- L5（9.27 docx 第 4 条）：智能选敌 —— 可达性避让 ----------
	# L5 用**自己的一组敌人**（不动 L3 的读数）：
	#   毒灵在 (230,470)；友军在 (230,425) 挡在正前方；
	#   g_front 在 (230,180) —— 正好躲在友军背后（直线最近 290，去路被挡）；
	#   g_side  在 (550,180) —— 横偏 320（斜距 432），射线已绕开友军半径 30 的碰撞圆。
	# ★ 横偏必须**足够大**（本几何下约 > 262px）射线才真的绕开碰撞圆；100px 那种
	#   小横偏在几何上**仍然被挡**（第一版就栽在这：拿 L3 的 (330,190) 当"可达"用，
	#   实测仍 blocked）。所以选目标几何不能靠"看着偏了一点"。
	# 判据：给选敌函数传 bodies 后必须改选 g_side；不传则保持旧口径（选最近）。
	var g_front := _mk("bubble", "enemy", 0, 230.0, 180.0, 900000, 0.0, 32.0, "g_front")
	var g_side := _mk("bubble", "enemy", 0, 550.0, 180.0, 900000, 0.0, 32.0, "g_side")
	var enemy2: Array = [g_front, g_side]
	var bodies: Array = [poison, ally, g_front, g_side]
	var front_dist := Vector2(g_front.pos).distance_to(Vector2(poison.pos))
	var side_dist := Vector2(g_side.pos).distance_to(Vector2(poison.pos))
	var hit_front: Dictionary = Shared._first_contact(Vector2(poison.pos), Shared.body_radius(poison),
		(Vector2(g_front.pos) - Vector2(poison.pos)).normalized(), front_dist, poison, [ally])
	var hit_side: Dictionary = Shared._first_contact(Vector2(poison.pos), Shared.body_radius(poison),
		(Vector2(g_side.pos) - Vector2(poison.pos)).normalized(), side_dist, poison, [ally])
	var b_front := bool(Shared._ally_blocks(poison, g_front, bodies))
	var b_side := bool(Shared._ally_blocks(poison, g_side, bodies))
	_r("l5_front_dist", "%.1f" % front_dist)
	_r("l5_side_dist", "%.1f" % side_dist)
	_r("l5_block_front", str(b_front))
	_r("l5_block_side", str(b_side))
	_r("l5_contact_front_uid", str(hit_front.get("uid", "<none>")))
	_r("l5_contact_side_uid", str(hit_side.get("uid", "<none>")))
	# 几何体检：先证明两个候选的"挡住/没挡住"确实不同，否则后面的重选断言可能空过。
	h.call("expect", b_front, "l5_front_blocked",
		"g_front 被友军挡住（几何体检：否则后面的断言可能空过）")
	h.call("expect", not b_side, "l5_side_clear",
		"g_side 不被友军挡住（射线已绕开碰撞圆；斜距 %.1f > 直线 %.1f）"
			% [side_dist, front_dist])
	h.call("expect", str(hit_front.get("uid", "")) == str(ally.get("uid", "")), "l5_first_contact_front",
		"_first_contact 去 g_front 的路上先撞到友军")
	h.call("expect", str(hit_side.get("uid", "")).is_empty(), "l5_first_contact_side",
		"_first_contact 去 g_side 的路上畅通")

	# ★ 主判据：传 bodies → 改选 g_side（可达），而不是最近的 g_front（被挡）
	var smart := Shared._team_select_target(poison, enemy2, false, bodies)
	_r("l5_smart_picked", str(smart.get("uid", "<none>")))
	h.call("expect", str(smart.get("uid", "")) == "g_side", "l5_smart_picks_reachable",
		"★ 传 bodies 后改选 g_side（可达）—— 实得 %s" % str(smart.get("uid", "<none>")))
	# 反向对照：不传 bodies（旧口径）仍选最近的 g_front —— 证明"只对被挡的单位启用"
	var legacy := Shared._team_select_target(poison, enemy2, false)
	h.call("expect", str(legacy.get("uid", "")) == "g_front", "l5_legacy_unchanged",
		"反例：不传 bodies 时仍是旧口径（选最近的 g_front）—— 未被挡的单位行为零变化")

	# 反向对照 2：两个候选都被挡住 → 必须退回旧口径给出目标（不空选、不崩）。
	#   wall_a (230,425) 挡 g_front；wall_b (390,325) 正好落在 毒灵→g_side 的连线上。
	var wall_a := _mk("hymn_wisp", "player", 0, 230.0, 425.0, 900, 0.0, 32.0, "wa")
	var wall_b := _mk("hymn_wisp", "player", 0, 390.0, 325.0, 900, 0.0, 32.0, "wb")
	var all_blocked := Shared._team_select_target(poison, enemy2, false, [poison, wall_a, wall_b, g_front, g_side])
	_r("l5_all_blocked_picked", str(all_blocked.get("uid", "<none>")))
	h.call("expect", str(all_blocked.get("uid", "")) == "g_front", "l5_all_blocked_fallback",
		"两个候选都被挡住时仍退回旧目标（最近的 g_front），不空选 —— 实得 %s"
			% str(all_blocked.get("uid", "<none>")))

	# ---------- L6：端到端 —— 毒灵在真实 tick 里真的会去打那个侧后方敌人 ----------
	var p2 := _mk("undead_poison", "player", 0, 230.0, 470.0, 660, 3.3 * 55.0, 32.0, "p_e2e", "poison_attack")
	var a2 := _mk("hymn_wisp", "player", 0, 230.0, 425.0, 900, 0.0, 32.0, "a_e2e")
	var e_front2 := _mk("bubble", "enemy", 0, 230.0, 180.0, 900000, 0.0, 32.0, "e_front2")
	var e_side2 := _mk("bubble", "enemy", 0, 550.0, 180.0, 900000, 0.0, 32.0, "e_side2")
	var st2 := _base_state([p2, a2], [e_front2, e_side2])
	# 直接驱动一次选敌（诊断：确认纯函数在仿真上下文里也改选 e_side2）
	var diag_bodies: Array = [p2, a2, e_front2, e_side2]
	var diag_pick := Shared._select_attack_target(p2, [e_front2, e_side2],
		Shared._attack_target_index([e_front2, e_side2]), diag_bodies)
	_r("l6_direct_pick", str(diag_pick.get("uid", "<none>")))
	_r("l6_p2_lane", str(int(p2.get("lane", -1))))
	_r("l6_p2_block_front", str(Shared._ally_blocks(p2, e_front2, diag_bodies)))
	_r("l6_team_mode", str(GameState.team_mode))
	p2.erase("locked_target_uid")
	var locked_uid := ""
	for _t in 8:
		Simulator.step_state(st2)
		locked_uid = str(p2.get("locked_target_uid", ""))
		if not locked_uid.is_empty():
			break
	_r("l6_locked_uid", locked_uid)
	h.call("expect", locked_uid == "e_side2", "l6_sim_picks_side",
		"★ 端到端：毒灵在真实 tick 里锁定的是可达的 e_side2 —— 实得 %s" % locked_uid)
	# 继续跑，看它是否真的摸到侧后方敌人并打出伤害。
	for _t in 500:
		Simulator.step_state(st2)
		if not bool(p2.get("alive", false)):
			break
	var side_dmg := 900000 - int(e_side2.get("hp", 0))
	var front_dmg := 900000 - int(e_front2.get("hp", 0))
	_r("l6_side_damage", str(side_dmg))
	_r("l6_front_damage", str(front_dmg))
	h.call("expect", side_dmg > 0, "l6_side_took_damage",
		"★ 端到端：侧后方敌人确实吃到伤害（%d）—— 毒灵真的参战了" % side_dmg)

	print("PROBE_%s STAGE before_finish" % PROBE_ID)
	var failed: int = int(h.call("failure_count"))
	print("PROBE_%s DONE failures=%d checked=%d" % [PROBE_ID, failed, int(h.call("checked_count"))])
	h.call("finish", get_tree())
