extends Node

# 9.28 门禁：战斗单位「打不到就换目标」+「被队友夹住会绕行」。
#
# 守的是什么（用户第二、三次报「棋子排队不攻击 / 卡在后面不动」）：
#   9.27 已有**可达性感知选敌** —— `_team_select_target` 给出目标时用 `_ally_blocks`
#   判「沿这条路有没有友军挡着」，被挡就改选可达的那个。但那套判据**只在
#   「重选目标那一刻」跑一次**：`_select_target` / `_select_attack_target` 命中锁定
#   就直接返回 ⇒ 锁定发生在「被挡住之前」时，它一直锁着够不到的目标站到队友死。
#
# 9.28 第二轮补了「持续无进展看门狗」，但又留了两个洞（本轮修掉）：
#   ① ★★★ `MAX_SWITCH_ATTEMPTS` 被当成**整场预算** —— 换满 3 次就永久退回旧行为。
#      真实对局实测（30 场 / 76 单位）：46 个单位卡住 ≥3 秒、最长 282 tick（28 秒），
#      其中 **41/46 个的 `_switch_attempts` 正好等于 3** —— 全死在永久放弃上。
#      现在：上限是**每轮**的，换满进冷却、冷却结束清空避让重开一轮，绝不停手。
#   ② ★★ 避让只有一个槽位且拿 `locked_target_uid` 当被避让者 —— 两个够不到的
#      目标会互相覆盖（来回踢），锁定为空/被嘲讽改写时又记了个不相干的人。
#      现在：避让是**集合**（`avoid_target_uids`），记的是**实际没打到的那个**
#      （`_progress_uid`），并且逐个元素修剪（目标死了/去路通了就放回）。
#   ③ ★★★ 位移层：正对挡路者时切向残量「很小但非 0」⇒ 旧口径既不触发绕行、
#      又几乎走不动，位移恒为 0（真实现场：2~3 只同队友军互停在接触距离 d=30/31/32）。
#      现在：残量小于本次位移的 20% 就按「正对」处理，两侧都试、取走得远的。
#
# ★ 判据一律读**施动者自己的记录**：
#   - 打了谁 → `vfx_attack_target_uid`（`_step_team` 真的出手才写），不看血量反推
#     （友军也在打，血量会被算到它头上 —— 第一版就这么误判过）。
#   - 有没有放弃 → 它自己的 `_switch_attempts` / `_switch_cooldown` / `avoid_target_uids`。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Shared := preload("res://scripts/battle/BattleSimShared.gd")
const Simulator := preload("res://scripts/battle/BattleSimulator.gd")

const CHECK_NAME := "battle_reach_target"

# 进射程的判定：`_effective_attack_distance` = 32 + ATTACK_RANGE_EPS(4) = 36。
const IN_RANGE_PX := 36.0
const LONG_TICKS := 400

const SHARED_PATH := "res://scripts/battle/BattleSimShared.gd"
const SIM_PATH := "res://scripts/battle/BattleSimulator.gd"

var h: RefCounted


func _mk(id: String, team: String, lane: int, x: float, y: float,
		hp: int, range_px: float, uid: String, skill_id: String = "") -> Dictionary:
	var d := {
		"id": id, "name": id, "name_en": id,
		"hp": hp, "atk": 12, "def": 0, "attack_speed": 0.5,
		"range_px": range_px, "move_speed_px": 3.3 * 55.0, "footprint_cells": 1,
		"element": "none", "race": "none", "skill_id": skill_id,
		"crit": 0.0, "dodge": 0.0,
	}
	var f := Simulator._fighter_from_def(d, lane, team, lane, 1, 1, false, false)
	f.pos = Vector2(x, y)
	f.uid = uid
	# ★ `_fighter_from_def` **不写** `lane`（生产里由 `_place_in_lane` 写）。
	#   漏了这行 `f.get("lane") == -1`，`_team_select_target` 整段落空 ——
	#   断言会退化成对 `_nearest` 的断言（一个证明不了任何事的绿灯）。
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


# 友军墙：3 只同速单位横在 y=330（x=200/230/260），封住毒灵正前方走廊。
func _wall() -> Array:
	var wall: Array = []
	for i in 3:
		wall.append(_mk("hymn_wisp", "player", 0, 200.0 + 30.0 * float(i), 330.0, 900, 32.0,
			"w%d" % i))
	return wall


# 跑一个场景，返回 focus 单位的观测值。
# `front_foes` 里的第一个用来量「最近靠到多少 px」。
func _run(focus: Dictionary, allies: Array, foes: Array, ticks: int,
		kill_at: int = -1, doomed: Array = []) -> Dictionary:
	var units: Array = [focus] + allies
	var st := _base_state(units, foes)
	var attacked := {}
	var min_front := INF
	var avoid_seen := false
	var max_avoid := 0
	# --- 场景 C（挡路者被拆）专用的四路读数 --------------------------------
	# 拆墙之前避让集合的峰值 —— **前提体检**：如果这里恒为 0，说明这一场压根
	# 没建立起「这个目标够不到」的记录，后面的「释放」断言就是**空过**
	# （变异 M3 第一次正是这么漏成假绿的：焦点单位 6 tick 内就贴到墙上，
	#  no_progress 还没攒够 6 tick、墙就被拆了 ⇒ 避让从未被记录过，
	#  于是拆墙后的读数在变异前后都为 0，判据没有判别力）。
	var max_avoid_before_kill := 0
	# 拆墙**那一 tick 结束时**避让集合的规模 —— 最紧的判据：修剪是同步生效的，
	# 不该等到下一个窗口才看得出来。`-1` 表示没跑到那一 tick。
	var avoid_at_kill_tick := -1
	# 拆墙之后 10 tick 窗口内的避让峰值（兜底：同 tick 读数万一被别的路径干扰）。
	var max_avoid_after_kill := 0
	# ★ 有没有第二条清空路径参与：冷却（`_switch_cooldown > 0`）一旦被触发，
	#   `erase("avoid_target_uids")` 也会把避让擦掉 —— 那就证明不了是**修剪**做的。
	#   这是直接读「那条路径有没有跑」，比事后数 attempts 更贴机制。
	var window_cooldown_seen := false
	var retry_rounds := 0
	var prev_attempts := 0
	var pinned_ticks := 0
	var max_pinned := 0
	var first_foe: Dictionary = foes[0] if not foes.is_empty() else {}
	for t in ticks:
		if t == kill_at:
			for d in doomed:
				d["hp"] = 0
				d["alive"] = false
		Simulator.step_state(st)
		if not bool(focus.get("alive", false)):
			break
		var vu := str(focus.get("vfx_attack_target_uid", ""))
		if not vu.is_empty():
			attacked[vu] = true
		var avoided: Array = focus.get("avoid_target_uids", [])
		if not avoided.is_empty():
			avoid_seen = true
		max_avoid = maxi(max_avoid, avoided.size())
		if kill_at >= 0:
			if t < kill_at:
				max_avoid_before_kill = maxi(max_avoid_before_kill, avoided.size())
			if t == kill_at:
				avoid_at_kill_tick = avoided.size()
			if t >= kill_at and t <= kill_at + 10:
				max_avoid_after_kill = maxi(max_avoid_after_kill, avoided.size())
				if int(focus.get("_switch_cooldown", 0)) > 0:
					window_cooldown_seen = true
		# ★ 轮次重置：`_switch_attempts` 由大变小 = 冷却结束、重开一轮。
		#   旧口径（整场预算）里它单调涨到 MAX 后**永不下降** ⇒ retry_rounds 恒为 0。
		var att := int(focus.get("_switch_attempts", 0))
		if att < prev_attempts:
			retry_rounds += 1
		prev_attempts = att
		# ★ 永久停手签名：attempts 已满却还在原地耗 —— 旧口径里会一直涨。
		if att >= Shared.MAX_SWITCH_ATTEMPTS:
			pinned_ticks += 1
			max_pinned = maxi(max_pinned, pinned_ticks)
		else:
			pinned_ticks = 0
		if not first_foe.is_empty():
			min_front = minf(min_front, float(focus.pos.distance_to(first_foe.pos)))
	return {
		"attacked": attacked.keys(),
		"front_attacked": attacked.has("e_front"),
		"side_attacked": attacked.has("e_side"),
		"locked": str(focus.get("locked_target_uid", "")),
		"avoid": str(focus.get("avoid_target_uids", [])),
		"avoid_seen": avoid_seen,
		"max_avoid": max_avoid,
		"max_avoid_before_kill": max_avoid_before_kill,
		"avoid_at_kill_tick": avoid_at_kill_tick,
		"max_avoid_after_kill": max_avoid_after_kill,
		"window_cooldown_seen": window_cooldown_seen,
		"retry_rounds": retry_rounds,
		"max_pinned": max_pinned,
		"min_front": min_front,
	}


func _src(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


# 取某个 static func 的源码块（到下一个顶层 `static func` / `func` / `class` / `const` 之前）。
# ★ 必须限定作用域：本仓栽过「整份文件 contains，被同名字段顶上」的假绿。
func _fn_body(source: String, header: String) -> String:
	var start := source.find(header)
	if start < 0:
		return ""
	var rest := source.substr(start + header.length())
	var cut := rest.length()
	for marker in ["\nstatic func ", "\nfunc ", "\nclass ", "\nconst "]:
		var at := rest.find(marker)
		if at >= 0:
			cut = mini(cut, at)
	return rest.substr(0, cut)


# 剥掉整行注释与行尾注释，再做文本断言。
# ★ 本仓教训：不剥注释的 `contains` 会被**自己的注释**满足
#   （"写了注释就算通过"），结构断言就成了摆设。
func _strip_comments(text: String) -> String:
	var out: Array[String] = []
	for line in text.split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		var cut := line.find("#")
		out.append(line if cut < 0 else line.substr(0, cut))
	return "\n".join(out)


func _ready() -> void:
	h = CheckHarness.new(CHECK_NAME)
	GameState.tutorial_mode = false
	GameState.team_mode = true
	_check_behavior()
	_check_liveness()
	_check_avoid_accumulates()
	_check_wedge_movement()
	_check_pure_functions()
	_check_structure()
	h.finish(get_tree())


# ---------- 行为：够不到就换到可达的 ----------
func _check_behavior() -> void:
	# A：预置锁定 + 友军墙挡路（复现原缺口）
	var a_poison := _mk("undead_poison", "player", 0, 230.0, 470.0, 660, 32.0, "p", "poison_attack")
	var a_wall := _wall()
	var a_front := _mk("bubble", "enemy", 0, 230.0, 120.0, 900000, 32.0, "e_front")
	var a_side := _mk("bubble", "enemy", 0, 700.0, 330.0, 900000, 32.0, "e_side")
	a_poison["locked_target_uid"] = "e_front"
	var a := _run(a_poison, a_wall, [a_front, a_side], 300)

	# 前提体检：友军墙确实把它挡在射程外 —— 否则后面的断言可能空过。
	h.expect(not bool(a["front_attacked"]) and float(a["min_front"]) > IN_RANGE_PX,
		"blocked_target_really_unreachable",
		"前提体检：毒灵从没打过 e_front、最近只到 %.1f px（射程 %.0f）—— 它确实够不到"
			% [float(a["min_front"]), IN_RANGE_PX])
	h.expect(bool(a["side_attacked"]), "stuck_unit_switches_to_reachable",
		"★ 够不到原目标时改打可达目标：毒灵真的出手打过 e_side=%s"
			% str(a["side_attacked"]))
	h.expect(str(a["locked"]) == "e_side", "stuck_unit_ends_on_reachable",
		"锁定最终落在可达的 e_side —— 实得 %s" % str(a["locked"]))
	# ★ 避让真的被记下过：不是「因为别的原因顺手打了 e_side」。
	h.expect(bool(a["avoid_seen"]), "avoidance_recorded",
		"★ 过程中确实记过避让（`avoid_target_uids` 至少非空过一次）")

	# B：无阻挡对照 —— 不许把正常单位带坏（仍然锁定最近的、老实打它）
	var b_poison := _mk("undead_poison", "player", 0, 230.0, 470.0, 660, 32.0, "p2", "poison_attack")
	var b_front := _mk("bubble", "enemy", 0, 230.0, 120.0, 900000, 32.0, "e_front")
	var b_side := _mk("bubble", "enemy", 0, 700.0, 330.0, 900000, 32.0, "e_side")
	var b := _run(b_poison, [], [b_front, b_side], 300)
	h.expect(bool(b["front_attacked"]), "no_wall_attacks_nearest",
		"无阻挡对照：毒灵打过最近的 e_front=%s" % str(b["front_attacked"]))
	h.expect(str(b["locked"]) == "e_front", "no_wall_keeps_lock",
		"无阻挡对照：仍锁定最近的 e_front —— 实得 %s" % str(b["locked"]))
	h.expect(not bool(b["avoid_seen"]), "no_wall_no_avoidance",
		"无阻挡对照：没有产生避让记录 —— 实得 %s" % str(b["avoid"]))
	h.expect(int(b["retry_rounds"]) == 0, "no_wall_no_retry",
		"无阻挡对照：压根没有换目标轮次 —— 实得 %d" % int(b["retry_rounds"]))

	# C：挡路者被拆 → 避让必须**当场**解除（★ 不能永久忽略一个重新可达的目标）
	#
	# ★★★ 本场景必须把「位移」这个变量**冻住**，只考「修剪」一件事：
	#   焦点单位与它的目标都设成 `move_speed_px = 0`（墙仍然会朝目标走）。
	#   为什么（变异 M3 第一次漏成假绿的复盘）：焦点单位移动速度 18.15px/tick，
	#   6 tick 就贴到墙上，而 `NO_PROGRESS_TICKS = 6` —— 时间上「攒够停滞」与
	#   「贴到墙上」几乎同时发生，只要墙拆早一点，避让**从未被记录过**，
	#   拆墙后的读数在变异前后都为 0 ⇒ 判据没有判别力。冻住位移后，
	#   焦点与目标的距离恒定 350px，停滞判定在第 7 tick 必然触发，完全确定。
	#   位移层由下面的 F 场景单独考，这里不重复。
	var c_poison := _mk("undead_poison", "player", 0, 230.0, 470.0, 660, 32.0, "p3", "poison_attack")
	var c_wall := _wall()
	var c_front := _mk("bubble", "enemy", 0, 230.0, 120.0, 900000, 32.0, "e_front")
	c_poison["move_speed_px"] = 0.0
	c_front["move_speed_px"] = 0.0
	c_poison["locked_target_uid"] = "e_front"
	# 拆墙 tick 10：第 7 tick 就已经把 e_front 记进避让（t=7..9 读数 ≥1），
	# 拆墙后只跑 14 tick —— 远早于「换满 3 次进冷却」（t≈21），
	# 所以这段时间里唯一能清空避让的路径就是**修剪**。
	var c := _run(c_poison, c_wall, [c_front], 24, 10, c_wall)
	# 前提体检：拆墙之前避让**确实**被建立过 —— 否则下面的「释放」是空过。
	h.expect(int(c["max_avoid_before_kill"]) >= 1, "avoidance_recorded_before_kill",
		"前提体检：拆墙之前 e_front 已被记进避让（峰值 %d ≥ 1）—— 这一场确实建立了「够不到」记录"
			% int(c["max_avoid_before_kill"]))
	h.expect(int(c["avoid_at_kill_tick"]) == 0, "avoid_released_at_kill_tick",
		"★ 拆墙那一 tick 结束时避让里已经不带 e_front（实得 %d，期望 0）—— 修剪是同步生效的"
			% int(c["avoid_at_kill_tick"]))
	h.expect(int(c["max_avoid_after_kill"]) == 0, "avoid_released_after_wall_gone",
		"★ 友军墙拆掉后避让**当场**被修剪掉（拆墙后 10 tick 窗口内峰值 %d，期望 0）"
			% int(c["max_avoid_after_kill"]))
	h.expect(not bool(c["window_cooldown_seen"]) and int(c["retry_rounds"]) == 0,
		"avoid_release_not_via_round_reset",
		"这次释放是**修剪**做的，不是被「换满一轮进冷却」顺带擦掉的"
			+ "（窗口内冷却被触发过=%s，重开轮数=%d，均应为假/0）"
			% [str(c["window_cooldown_seen"]), int(c["retry_rounds"])])


# ---------- 行为：换目标上限是「每轮」的，绝不停手 ----------
func _check_liveness() -> void:
	# D：只有一个够不到的目标（没有任何可达替代）+ 友军墙 → 旧口径换满 3 次就永久
	#    退回旧行为（`_switch_attempts` 停在 3 再也不动）；现在必须一直接着试。
	var d_poison := _mk("undead_poison", "player", 0, 230.0, 470.0, 660, 32.0, "p4", "poison_attack")
	var d_wall := _wall()
	var d_front := _mk("bubble", "enemy", 0, 230.0, 120.0, 900000, 32.0, "e_front")
	d_poison["locked_target_uid"] = "e_front"
	var d := _run(d_poison, d_wall, [d_front], LONG_TICKS)

	h.expect(int(d["retry_rounds"]) >= 2, "switch_budget_is_per_round",
		"★ 换满一轮之后会重开新轮、继续尝试（重开轮数 %d ≥ 2）—— 旧口径是整场预算，这里恒为 0"
			% int(d["retry_rounds"]))
	h.expect(int(d["max_pinned"]) <= Shared.NO_PROGRESS_TICKS + 2, "never_pinned_at_cap",
		"★ 「换满了」顶多撑过一个停滞窗口（最长 %d tick，上限 %d）—— 旧口径里它单调涨到战斗结束（数百 tick）"
			% [int(d["max_pinned"]), Shared.NO_PROGRESS_TICKS + 2])


# ---------- 行为：避让是集合，不是单槽 ----------
func _check_avoid_accumulates() -> void:
	# E：同一条路线上两个够不到的目标 → 避让必须**累积**成 2 个。
	#    旧口径只有一个槽位：第二个会把第一个覆盖掉，两个目标之间来回踢。
	var e_poison := _mk("undead_poison", "player", 0, 230.0, 470.0, 660, 32.0, "p5", "poison_attack")
	var e_wall := _wall()
	var e_f1 := _mk("bubble", "enemy", 0, 230.0, 120.0, 900000, 32.0, "e_front")
	var e_f2 := _mk("bubble", "enemy", 0, 290.0, 120.0, 900000, 32.0, "e_front2")
	e_poison["locked_target_uid"] = "e_front"
	var e := _run(e_poison, e_wall, [e_f1, e_f2], LONG_TICKS)

	h.expect(int(e["max_avoid"]) == 2, "avoidance_accumulates",
		"★ 两个够不到的目标都被记进避让集合（峰值 %d，期望 2）—— 旧口径单槽位峰值只有 1"
			% int(e["max_avoid"]))
	h.expect(int(e["retry_rounds"]) >= 1, "avoid_pair_keeps_retrying",
		"场景 E（两个都够不到）换满一轮后仍在重开新轮（重开 %d 次）"
			% int(e["retry_rounds"]))


# ---------- 行为：顶着队友也要能挪动（位移层绕行） ----------
func _check_wedge_movement() -> void:
	# F：目标正前方顶着一只同队友军，而且**略微偏离连线** ——
	#    切向残量落在 1e-4~1e-2 量级：旧口径既不触发绕行、又几乎走不动（实测 0.34px/tick），
	#    新口径按「正对挡路者」处理、两侧取走得远的（实测 ≈ 满额）。
	var f := _mk("mover", "player", 0, 300.0, 260.0, 900, 32.0, "mover")
	var ally := _mk("ally", "player", 0, 330.0, 262.0, 900, 32.0, "ally")
	var goal := _mk("goal", "enemy", 0, 400.0, 260.0, 900, 32.0, "goal")
	var bodies: Array = [f, ally, goal]
	var step_px := 4.25
	var dir: Vector2 = (goal.pos - f.pos).normalized()
	var before: Vector2 = f.pos
	Simulator._move_without_pushing(f, dir * step_px, bodies)
	var moved := float(before.distance_to(f.pos))
	# 前提体检：确实是「正对挡路者」——切向残量小到旧口径不侧移、又几乎走不动。
	var hit: Dictionary = Shared._first_contact(before, Shared.body_radius(f), dir, 60.0, f, bodies)
	h.expect(str(hit.get("uid", "")) == "ally" and float(hit.get("contact", 999.0)) < 1.0,
		"wedge_blocker_really_head_on",
		"前提体检：正前方确实顶着队友（first_contact=%s@%.2f）"
			% [str(hit.get("uid", "")), float(hit.get("contact", -1.0))])
	h.expect(moved > step_px * 0.5, "head_on_blocker_still_walks_around",
		"★ 顶着队友时仍然走得动（一次 %.2fpx，期望 > %.2f）—— 旧口径只挪 0.3px 左右"
			% [moved, step_px * 0.5])
	# 反向：前方什么都没有时，还是老老实实走上满额。
	var f2 := _mk("mover2", "player", 0, 300.0, 260.0, 900, 32.0, "mover2")
	var goal2 := _mk("goal2", "enemy", 0, 400.0, 260.0, 900, 32.0, "goal2")
	var free_bodies: Array = [f2, goal2]
	var before2: Vector2 = f2.pos
	Simulator._move_without_pushing(f2, dir * step_px, free_bodies)
	var moved2 := float(before2.distance_to(f2.pos))
	h.expect(absf(moved2 - step_px) < 0.01, "free_path_keeps_full_step",
		"无阻挡时位移仍是满额（%.2f ≈ %.2f），绕行分支没有干扰正常行走" % [moved2, step_px])


func _check_pure_functions() -> void:
	# 推进判定：门禁直接调同一份实现，不在门禁里复刻（复刻的那份会随生产漂移）。
	var s1: Dictionary = Shared.no_progress_step("e_front", "e_side", 60.0, 432.0, 5)
	var s2: Dictionary = Shared.no_progress_step("e_front", "e_front", 61.8, 61.8, 2)
	var s3: Dictionary = Shared.no_progress_step("e_front", "e_front", 61.8, 45.0, 4)
	var s4: Dictionary = Shared.no_progress_step("e_front", "e_front", 61.8, 61.5, 0)
	h.expect(str(s1["uid"]) == "e_side" and int(s1["ticks"]) == 0,
		"np_resets_on_target_change", "换目标 → 推进计数归零（实得 ticks=%d）" % int(s1["ticks"]))
	h.expect(int(s2["ticks"]) == 3, "np_counts_when_stalled",
		"距离不变 → 计数 +1（2 → %d）" % int(s2["ticks"]))
	h.expect(int(s3["ticks"]) == 0, "np_resets_on_progress",
		"距离明显缩短（61.8 → 45.0）→ 计数归零（实得 %d）" % int(s3["ticks"]))
	h.expect(int(s4["ticks"]) == 1, "np_counts_tiny_drift",
		"距离只挪 0.3px（< eps 0.5）→ 仍算停滞、计数 +1（实得 %d）" % int(s4["ticks"]))

	# 避让集合修剪：只有「还活着 **且** 仍然挡路」的才留下。
	var both_blocked: Array = Shared.avoid_prune(["a", "b"], ["a", "b"], ["a", "b"])
	var dead_one: Array = Shared.avoid_prune(["a", "b"], ["a"], ["a", "b"])
	var clear_one: Array = Shared.avoid_prune(["a", "b"], ["a", "b"], ["a"])
	var none: Array = Shared.avoid_prune([], ["a"], ["a"])
	h.expect(both_blocked == ["a", "b"], "prune_keeps_live_blocked",
		"目标都活着且仍挡路 → 原样保留（实得 %s）" % str(both_blocked))
	h.expect(dead_one == ["a"], "prune_drops_dead",
		"目标已死 → 从避让里放回（实得 %s）" % str(dead_one))
	h.expect(clear_one == ["a"], "prune_drops_unblocked",
		"去路已通 → 从避让里放回（实得 %s）" % str(clear_one))
	h.expect(none.is_empty(), "prune_empty_noop", "空集合 → 空结果（实得 %s）" % str(none))


func _check_structure() -> void:
	# 行为断言看不见「谁调用它 / 判据有几份实现」，这几条必须单独钉。
	# ★ 一律先剥注释 —— 不剥的话「写了注释就算通过」，断言等于没有。
	var src_shared := _strip_comments(_src(SHARED_PATH))
	var src_sim := _strip_comments(_src(SIM_PATH))
	var step_body := _fn_body(src_sim, "static func _step_team(")
	var pick_body := _fn_body(src_shared, "static func _team_select_target(")
	var np_body := _fn_body(src_shared, "static func no_progress_step(")
	var prune_body := _fn_body(src_shared, "static func avoid_prune(")
	var move_body := _fn_body(src_sim, "static func _move_without_pushing(")

	h.expect(not step_body.is_empty(), "step_team_found",
		"取到了 `_step_team` 的源码块（取不到时下面几条会静默失效）")
	h.expect(step_body.contains("no_progress_step("), "step_team_calls_no_progress",
		"`_step_team` 里真的调用了推进判定（不是只定义不用）")
	h.expect(step_body.contains("avoid_target_uids"), "step_team_writes_avoidance",
		"`_step_team` 里真的写/读**避让集合**字段")
	h.expect(step_body.contains("_progress_uid") and step_body.contains("avoid_target_uids"),
		"avoidance_records_into_set",
		"`_step_team` 把「够不到」记进 `avoid_target_uids` 集合")
	h.expect(step_body.contains('var failed := str(f.get("_progress_uid", ""))'),
		"avoidance_attributes_to_actual_target",
		"★ 避让记的是**实际没打到的目标**（`_progress_uid`），不是可能为空/被人改写的锁定")
	h.expect(step_body.contains("MAX_SWITCH_ATTEMPTS") and step_body.contains("SWITCH_COOLDOWN_TICKS"),
		"switch_budget_has_cooldown",
		"`_step_team` 里同时出现「换目标上限」与「冷却」两个常量")
	# ★★ 上面那条只够证明「两个名字都出现过」—— 把上限改回**整场预算**、冷却留在
	#    不可达的 else 分支里，它照样绿（变异 M4 第一次就是这么漏过去的）。真正要钉的是：
	#    ① 冷却被**真的挂上**；② 判定条件里**不许**出现「整场预算」那种写法。
	h.expect(step_body.contains("f._switch_cooldown = SWITCH_COOLDOWN_TICKS"),
		"switch_cooldown_armed",
		"★ 换满一轮后真的会挂上冷却（`f._switch_cooldown = SWITCH_COOLDOWN_TICKS`）")
	h.expect(not step_body.contains('int(f.get("_switch_attempts", 0)) < MAX_SWITCH_ATTEMPTS'),
		"no_lifetime_switch_cap",
		"★ 判定条件里**没有**「整场预算」写法（那等于换满就永久放弃 —— 用户第三次报的就是它）")
	h.expect(step_body.contains("avoid_prune("), "step_team_prunes_avoidance",
		"`_step_team` 真的调用避让修剪（否则避让永远不会解除）")
	h.expect(not src_sim.contains("avoid_should_clear("), "no_lingering_single_slot_clear",
		"旧的单槽位解除函数已完全退场（没有留下第二个实现）")
	h.expect(pick_body.contains("avoid_target_uids"), "select_honors_avoidance",
		"`_team_select_target` 真的读避让集合（否则换目标会立刻被选回来、等于没换）")
	h.expect(np_body.contains("best") and np_body.contains("ticks"),
		"no_progress_single_implementation",
		"推进判定只有这一份实现（选敌侧不另写一套）")
	h.expect(prune_body.contains("alive_uids") and prune_body.contains("blocked_uids"),
		"prune_single_implementation",
		"避让修剪只有这一份实现（几何由调用方按同一套 `_ally_blocks` 算好传入）")
	h.expect(not src_shared.contains("func _reach_progress("), "no_second_geometry",
		"没有另起一套推进几何实现")

	# ★ 位移层：绕行分支必须仍然走 `_first_contact`（同一份几何），且两侧都试。
	h.expect(move_body.contains("0.2"), "wedge_tangent_threshold_is_scale_relative",
		"★ 绕行门槛按「本次位移的比例」判（固定 1e-6 阈值会漏掉 1e-4~1e-2 的残量）")
	h.expect(move_body.count("_first_contact(") == 3, "wedge_probes_both_sides",
		"★ 选侧时两侧各探一次（正文 1 次 + 两侧 2 次 = 3 次 `_first_contact`），实得 %d"
			% move_body.count("_first_contact("))
	h.expect(move_body.contains("tangent") and move_body.contains("budget"),
		"wedge_uses_full_budget",
		"绕行走的是「本次剩余位移」全额，不是残留的那一点点切向分量")

	# ★ 回放帧列数不能动：`frames` 属于 ReplayDigest.SIMULATION_TOP_FIELDS，
	#   加列必然改冻结哈希。本次新增的是 fighter 字典字段，不进 frames。
	var frame_body := _fn_body(src_sim, "static func _replay_capture_frame(")
	h.expect(frame_body.contains("vfx_skill_target_uid") and frame_body.count("frame.append") == 1,
		"replay_frame_columns_untouched",
		"`_replay_capture_frame` 仍是单次 13 列构造，本次改动没有加列")
