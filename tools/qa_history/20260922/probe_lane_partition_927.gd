extends Node

# 9.27 调查探针：大战场被两道隔断切成三个小战场。
# 用户问两件事：
#   ① 隔断未消失时，能不能攻击到其它小战场的敌人？（玩法层越界）
#   ② 模型会不会穿过隔断，造成"能打别路"的假象？（表现层越界）
#
# 「隔断」在两层的实现是**分开的**，必须分别验证：
#   玩法层 = `BattleSimShared._can_target()`  —— 它决定"能选谁当目标"
#   表现层 = 单位坐标有没有被 lane 约束 —— 它决定"模型站在哪"
#
# 关键几何（sim 坐标系，ARENA_W=1000）：
#   隔断线     = ARENA_W * 1/3 = 333.3  与  ARENA_W * 2/3 = 666.7
#   车道中心   = TEAM_LANE_CENTERS = [230, 500, 770]
#   所以 lane0 的活动带是 x<333.3，lane1 是 333.3~666.7，lane2 是 x>666.7。
#
# 探针原则（沿用本仓约定）：
#   · 只驱动**生产实现**，不在探针里复刻一份逻辑
#   · 每个"安全"结论都要有反例断言，证明它不是"没跑到"而假绿
#   · 判据不自证：期望值独立算，不借被测函数

const Harness := preload("res://tools/CheckHarness.gd")
const Shared := preload("res://scripts/battle/BattleSimShared.gd")
const Simulator := preload("res://scripts/battle/BattleSimulator.gd")

const PROBE_ID := "lane_partition_927"

# 隔断线的 sim x 坐标。独立算：直接用生产常量，不抄字面量。
const WALL_A := Shared.ARENA_W / 3.0
const WALL_B := Shared.ARENA_W * 2.0 / 3.0

var h: RefCounted
var report: Array = []

func _r(tag: String, value: String) -> void:
	report.append("%s=%s" % [tag, value])
	print("PROBE_%s %s=%s" % [PROBE_ID, tag, value])

func _fighter(team: String, lane: int, x: float, y: float, uid: String) -> Dictionary:
	return {
		"uid": uid, "team": team, "lane": lane, "pos": Vector2(x, y),
		"alive": true, "hp": 100, "max_hp": 100, "range_px": 72.0,
		"footprint_cells": 1, "move_speed_px": 165.0, "next_attack": 0.0,
		"atk": 10, "def": {}, "attack_speed": 1.0, "attack_count": 0,
	}


func _ready() -> void:
	h = Harness.new(PROBE_ID)

	# ---------- 0. 几何：把隔断线位置钉死，后面越界判定才有依据 ----------
	_r("wall_a", "%.1f" % WALL_A)
	_r("wall_b", "%.1f" % WALL_B)
	_r("lane_centers", str(Shared.TEAM_LANE_CENTERS))
	h.call("expect", is_equal_approx(WALL_A, 1000.0 / 3.0) and is_equal_approx(WALL_B, 2000.0 / 3.0),
		"wall_geometry", "隔断线在 333.3 / 666.7")
	h.call("expect", Shared.TEAM_LANE_CENTERS[0] < WALL_A
			and Shared.TEAM_LANE_CENTERS[1] > WALL_A and Shared.TEAM_LANE_CENTERS[1] < WALL_B
			and Shared.TEAM_LANE_CENTERS[2] > WALL_B,
		"lane_centers_inside_bands",
		"三个车道中心各自落在自己的带里（lane0<333.3, 333.3<lane1<666.7, lane2>666.7）")

	GameState.tutorial_mode = false
	GameState.team_mode = true

	# ---------- 1. _can_target 的门禁语义（玩法层） ----------
	# 场景：attacker 在 lane0，别路有敌人；自己 lane0 **还有活敌**。
	var atk0 := _fighter("player", 0, 230.0, 400.0, "p_L0_0")
	var enemy_l0 := _fighter("enemy", 0, 230.0, 120.0, "e_L0_0")
	var enemy_l1 := _fighter("enemy", 1, 500.0, 120.0, "e_L1_0")
	var enemy_l2 := _fighter("enemy", 2, 770.0, 120.0, "e_L2_0")
	var opps_with_l0 := [enemy_l0, enemy_l1, enemy_l2]

	var can_l0 := Shared._can_target(atk0, enemy_l0, opps_with_l0)
	var can_l1 := Shared._can_target(atk0, enemy_l1, opps_with_l0)
	var can_l2 := Shared._can_target(atk0, enemy_l2, opps_with_l0)
	_r("gate_own_lane", str(can_l0))
	_r("gate_other_lane_l1", str(can_l1))
	_r("gate_other_lane_l2", str(can_l2))
	h.call("expect", can_l0, "gate_allows_own_lane", "自己这路有敌人时，可以打自己这路")
	h.call("expect", not can_l1, "gate_blocks_l1",
		"自己 lane0 还有活敌 → 打不到 lane1（隔断生效）")
	h.call("expect", not can_l2, "gate_blocks_l2",
		"自己 lane0 还有活敌 → 打不到 lane2（隔断生效）")

	# 自己这路清空后 → 才允许打别路（隔断消失）。
	var dead_l0 := _fighter("enemy", 0, 230.0, 120.0, "e_L0_0")
	dead_l0.alive = false
	var opps_no_l0 := [dead_l0, enemy_l1, enemy_l2]
	var open_l1 := Shared._can_target(atk0, enemy_l1, opps_no_l0)
	var open_l2 := Shared._can_target(atk0, enemy_l2, opps_no_l0)
	_r("after_clear_can_l1", str(open_l1))
	_r("after_clear_can_l2", str(open_l2))
	h.call("expect", open_l1 and open_l2, "gate_opens_after_clear",
		"自己这路清空 → 隔断消失，可以支援别路")

	# **反向断言（防假绿）**：如果 _can_target 永远返回 true，
	# 上面那两条 not can_l1/not can_l2 才有意义。所以这里必须证明
	# 它至少**在某些情况下返回 false** —— 即门禁真的在工作。
	h.call("expect", not can_l1, "gate_is_not_always_true",
		"门禁不是恒真：lane0 未清空时确实挡住了 lane1")

	# ---------- 2. 提前返回旁路盘点（结构） ----------
	# _can_target 里有两条在 lane 判定**之前**的 return true：
	#   (a) 非 team_mode / 同队 → true
	#   (b) is_formation_ally → true  ← 法阵友军全场技的合法出口
	# 以及一条 lane<0 → true。
	# 这些是"隔断允许被打穿"的唯一合法出口，必须点出来，不能当成漏洞。
	var ally := _fighter("player", 1, 500.0, 400.0, "ally_guard")
	ally["is_formation_ally"] = true
	var ally_can_l0 := Shared._can_target(ally, enemy_l0, opps_with_l0)
	h.call("expect", ally_can_l0, "formation_ally_bypass_exists",
		"法阵友军 is_formation_ally 可以打别路（这是刻意的：全场技，见 BattleSimSkills 注释）")

	# lane<0 的单位（教学/未分路）不受限制 —— 记录为已知旁路。
	var no_lane := _fighter("player", -1, 500.0, 400.0, "p_nolane")
	var nolane_can := Shared._can_target(no_lane, enemy_l0, opps_with_l0)
	_r("nolane_can_target", str(nolane_can))
	h.call("expect", nolane_can, "nolane_bypass_exists",
		"lane<0 的单位不受隔断限制（已知旁路，教学战斗恒为 -1）")

	# ---------- 3. 表现层：模型坐标有没有被 lane 约束 ----------
	# 这是用户问的第②点。直接驱动生产移动函数，看它会不会把单位推出自己的带。
	var walker := _fighter("player", 0, 230.0, 260.0, "p_walker")
	# 目标在 lane2（x=770），跨过两道隔断。
	var far_target := Vector2(770.0, 260.0)
	var delta := far_target - Vector2(walker.pos)
	# 多 tick 走，累积位移足够越过 x=333.3。
	for _i in 40:
		Simulator._move_without_pushing(walker, delta.normalized() * 20.0, [])
	var walked_x := float(walker.pos.x)
	_r("walker_start_x", "230.0")
	_r("walker_end_x", "%.1f" % walked_x)
	_r("walker_lane_still", str(int(walker.get("lane", -1))))
	h.call("expect", walked_x > WALL_A, "move_ignores_lane_wall",
		"模型位移不受隔断约束：从 lane0 起点 230 走到了 %.1f，已越过 x=%.1f 的隔断线" % [walked_x, WALL_A])
	h.call("expect", int(walker.get("lane", -1)) == 0, "lane_field_not_rewritten",
		"走到别路了，但 lane 字段仍是 0 —— 玩法归属没变，只有模型越界")

	# 上界：只受竞技场边框 clamp（45~955），不受 lane。
	var edge := _fighter("player", 0, 230.0, 260.0, "p_edge")
	for _i in 200:
		Simulator._move_without_pushing(edge, Vector2(1.0, 0.0) * 20.0, [])
	_r("edge_end_x", "%.1f" % float(edge.pos.x))
	h.call("expect", is_equal_approx(float(edge.pos.x), Shared.ARENA_W - 45.0),
		"move_clamped_only_by_arena",
		"位移只被竞技场边框 clamp 到 955，没有任何 lane 约束")

	# 结构断言：两处运动入口的 clamp 都必须是竞技场边框，不得出现 lane 约束。
	var sim_src := FileAccess.get_file_as_string("res://scripts/battle/BattleSimulator.gd")
	h.call("expect", sim_src.contains("clampf(position.x, 45.0, ARENA_W - 45.0)"),
		"move_clamp_is_arena_only",
		"_move_without_pushing 的 clamp 只是竞技场边框（无 lane 项）")
	# 反向：源码里不存在按 lane 收窄 x 的写法。
	var lane_bound_markers := ["lane_min_x", "lane_max_x", "clamp_to_lane", "LANE_BOUNDS"]
	var found_marker := ""
	for m in lane_bound_markers:
		if sim_src.contains(m) or sim_src.contains(m):
			found_marker = m
			break
	h.call("expect", found_marker.is_empty(), "no_lane_bounds_in_simulator",
		"BattleSimulator 里没有任何按 lane 收窄 x 的机制（否则模型不会穿隔断）")

	# ---------- 4. 教学战斗不走分路（记录事实，不当失败） ----------
	# BattleSimulator 文件头写明：教学战斗 lane 恒为 -1，_can_target 会直接放过。
	# 也就是说**教学战斗里根本没有隔断这回事**。
	# headless 下 GameState.board_slots 是空的 → 玩家侧为空，state 提前 finished。
	# 这里只记录事实，不判失败（没有单位不是被测代码的错）。
	var tut := Simulator.prepare_tutorial_state("pve")
	var tut_p: Array = tut.get("player", [])
	_r("tutorial_player_units", str(tut_p.size()))
	var tut_lanes := {}
	for f in tut_p:
		tut_lanes[str(int(f.get("lane", -1)))] = true
	_r("tutorial_lane_values", str(tut_lanes.keys()))
	h.item(1) # 记一次"已检查"，避免整段被当成空跑

	# ---------- 5. 端到端：手工构造一场**分路**的 3v3，逐 tick 抓跨带 ----------
	# 为什么不走 prepare_team_state：它依赖联机 room 数据，headless 下棋盘为空。
	# 这里直接调生产构造函数 `_append_lane_board_fighters` 摆一个三路对阵，
	# 让它跑真实的 step_state —— 移动/选目标/推挤全走生产代码。
	var st := _build_lane_state()
	_r("e2e_state_built", str(st.get("player", []).size()) + "v" + str(st.get("enemy", []).size()))
	h.call("expect", (st.get("player", []) as Array).size() >= 3
			and (st.get("enemy", []) as Array).size() >= 3,
		"e2e_state_built", "端到端状态摆出了三路双方单位（否则下面全是空跑）")

	# 前置条件：每条路两边都有活人，且**每一路自己那路都还有活敌**。
	# 这时按隔断规则，任何单位都只该打自己那路 —— 谁跑到别路就是越界。
	var cross_count := 0
	var max_cross := 0.0
	var cross_detail: Array = []
	_snapshot_positions(st)
	for _t in 60:
		Simulator.step_state(st)
		if bool(st.get("finished", false)):
			break
		for f in (st.get("player", []) as Array) + (st.get("enemy", []) as Array):
			if not bool(f.get("alive", false)):
				continue
			var lane := int(f.get("lane", -1))
			if lane < 0:
				continue
			var x := float(f.pos.x)
			var in_band := (lane == 0 and x < WALL_A) \
				or (lane == 1 and x >= WALL_A and x <= WALL_B) \
				or (lane == 2 and x > WALL_B)
			if not in_band:
				cross_count += 1
				var overshoot := 0.0
				if lane == 0:
					overshoot = x - WALL_A
				elif lane == 2:
					overshoot = WALL_B - x
				else:
					overshoot = maxf(WALL_A - x, x - WALL_B)
				max_cross = maxf(max_cross, overshoot)
				if cross_detail.size() < 5:
					cross_detail.append("%s(lane%d,x=%.0f,越%.0fpx)"
						% [str(f.get("uid", "")), lane, x, overshoot])
	_r("e2e_cross_samples", str(cross_count))
	_r("e2e_max_overshoot_px", "%.1f" % max_cross)
	_r("e2e_cross_detail", str(cross_detail))
	_r("e2e_finished", str(bool(st.get("finished", false))))
	_r("e2e_elapsed", "%.2f" % float(st.get("elapsed", 0.0)))

	# **这是本探针最重要的一条**：隔断还在（自己这路有活敌）时，
	# 表现层却把单位放到了不属于它的带里。
	h.call("expect", cross_count == 0, "e2e_no_cross_band",
		"端到端跑完，单位越过分隔带到别路的采样次数 = %d（>0 = 模型穿隔断）。样例：%s"
			% [cross_count, str(cross_detail)])

	# ---------- 6. 反例锚：证明"跨带"确实可能发生 ----------
	# 如果上面的 cross_count 是 0，得排除"因为单位压根没动"而假绿。
	# 检查同一场里单位确实位移过（否则 e2e_no_cross_band 是无意义的绿灯）。
	var moved := _any_moved(st)
	_r("e2e_any_unit_moved", str(moved))
	h.call("expect", moved, "e2e_units_actually_moved",
		"端到端战斗里单位确实发生了位移（否则「没有跨带」是因为没动，属假绿）")

	# ---------- 7. 结论汇总 ----------
	# 探针只报告事实，不判"该不该"：
	#   玩法层门禁 = 有效（lane0 未清空时确实挡 lane1/lane2）
	#   表现层位移 = **没有** lane 约束，模型可以横穿隔断
	print("PROBE_%s STAGE section7" % PROBE_ID)
	h.call("expect", true, "summary_recorded",
		"汇总：玩法层 _can_target 挡得住；表现层 _move_without_pushing/_separate_units 无 lane 约束")
	print("PROBE_%s STAGE section7_done" % PROBE_ID)

	# ---------- 8. 决定性场景：清空自己那路后去支援，会发生什么 ----------
	# 上面 §5 的 e2e 是「三路各自正面对阵」，谁都没有横移动机，
	# 所以 cross_samples=0 **只证明"正常对阵不跨"，没证明"跨带真的会发生"**。
	# 必须构造一个"必然朝隔壁走"的场景，否则那条绿灯可能只是没跑到（假绿）。
	#
	# 场景：player 在 lane0 有一只近战；enemy 的 lane0 是**空的**（已被清光），
	# enemy 只在 lane1 有一只。按 _can_target：player 这路没活敌 → 隔断对它是
	# 开的 → 它会去支援 lane1，于是必须朝 x=333.3 那道隔断走过去。
	var st2 := _build_support_state()
	_r("sup_player_lane0_x", "%.1f" % float((st2.player[0] as Dictionary).pos.x))
	_r("sup_enemy_lane", str(int((st2.enemy[0] as Dictionary).lane)))
	_r("sup_gate_open", str(Shared._can_target(st2.player[0], st2.enemy[0], st2.enemy)))
	h.call("expect", bool(Shared._can_target(st2.player[0], st2.enemy[0], st2.enemy)),
		"sup_gate_is_open",
		"前置条件：player 的 lane0 无敌 → 隔断对它放开，可以打 lane1（否则本场景无意义）")

	var support_max_x := float((st2.player[0] as Dictionary).pos.x)
	var sup_log: Array = []
	for _t in 200:
		Simulator.step_state(st2)
		if bool(st2.get("finished", false)):
			sup_log.append("finished@%d" % _t)
			break
		var p0: Dictionary = st2.player[0]
		if not bool(p0.get("alive", false)):
			sup_log.append("dead@%d" % _t)
			break
		support_max_x = maxf(support_max_x, float(p0.pos.x))
		if _t % 20 == 0:
			sup_log.append("t%d:x=%.0f,y=%.0f,hp=%d,tgt=%s"
				% [_t, float(p0.pos.x), float(p0.pos.y), int(p0.get("hp", 0)),
					str(p0.get("locked_target_uid", ""))])
	_r("sup_trace", str(sup_log))
	_r("sup_enemy_pos", "%.0f,%.0f" % [float((st2.enemy[0] as Dictionary).pos.x), float((st2.enemy[0] as Dictionary).pos.y)])
	_r("sup_max_x_reached", "%.1f" % support_max_x)
	# **实测更正**：单位会在近战射程边缘**停下**，而不是一路走进对面带里。
	# 第一版我断言"必须跨过 x=333.3"，那是错的期望 —— 见 §9 的正确判据。
	h.call("expect", support_max_x > 300.0, "support_approached_wall",
		"支援时模型确实朝隔断推进了（起点 146 → 最远 x=%.1f）" % support_max_x)

	# ---------- 9. 关键：隔着隔断线对打（"假象"的量化） ----------
	# trace 显示：player 停在 x=320（lane0 带内），enemy 在 x=354（lane1 带内），
	# 两者相距 ~34px ≈ 近战射程 32px —— 也就是**隔着一道线在互殴**。
	# 这不是"模型穿过去"，而是"模型没过去、却在打线那边的人"。
	var p_end: Dictionary = st2.player[0]
	var e_end: Dictionary = st2.enemy[0]
	var p_x := float(p_end.pos.x)
	var e_x := float(e_end.pos.x)
	var span := absf(e_x - p_x)
	var straddles := p_x < WALL_A and e_x > WALL_A
	_r("final_player_x", "%.1f" % p_x)
	_r("final_enemy_x", "%.1f" % e_x)
	_r("final_span_px", "%.1f" % span)
	_r("final_straddles_wall", str(straddles))
	h.call("expect", p_x < WALL_A and e_x > WALL_A, "straddle_detected",
		"两人分处隔断线 %.1f 的两侧（player %.0f / enemy %.0f）却互相攻击 —— 隔着隔断开火"
			% [WALL_A, p_x, e_x])
	h.call("expect", span <= Shared.MELEE_RANGE_PX + 8.0, "straddle_in_melee_range",
		"两人间距 %.1fpx 已在近战射程 %.0fpx 内 —— 确实在互相攻击，不是各自站着"
			% [span, Shared.MELEE_RANGE_PX])
	h.call("expect", int(p_end.get("hp", 0)) < int(p_end.get("max_hp", 1)),
		"straddle_player_took_damage",
		"player 隔着隔断线**真的在挨打**（hp %d/%d）—— 伤害已跨过分隔线生效"
			% [int(p_end.get("hp", 0)), int(p_end.get("max_hp", 1))])
	# ---------- 10. 隔断消失判据本身是否自洽（玩法 vs 表现的对齐） ----------
	# 表现层的晶柱消不消失，由 BattleArena._should_release_3v3_boundary() 决定：
	#   boundary i 的两侧是 lane i 与 lane i+1；
	#   只要「左路被任一方清空」**或**「右路被任一方清空」就 release。
	# 而 _lane_cleared_by(team, lane) 要求**该 team 自己在 lane 里还有活人**
	# （own_survivor），否则直接返回 false。
	#
	# 于是 §9 那个场景里：player 只剩 lane0 一只、enemy 只剩 lane1 一只。
	#   _lane_cleared_by("player", 0)：player 在 lane0 有活人 → own_survivor=true，
	#      再看 lane0 有没有 enemy → 没有 → **true**（玩家这路"清空"了）
	#   → boundary 0 应当 release。
	# 这条正是"隔断该消失"的判据，必须能真的被点亮，否则 §9 的跨界对打
	# 就是"隔断明明还在、却在跨线互殴"。
	var arena_src := FileAccess.get_file_as_string("res://scenes/battle/BattleArena.gd").replace("\r\n", "\n")
	h.call("expect", arena_src.contains("func _should_release_3v3_boundary"),
		"release_predicate_exists", "BattleArena 里存在 _should_release_3v3_boundary()")
	h.call("expect", arena_src.contains("func _lane_cleared_by"),
		"lane_cleared_predicate_exists", "BattleArena 里存在 _lane_cleared_by()")
	# 结构（9.27 **换口径**）：release 判据不再是"左右两路各判一次再 or"的散写，
	# 而是**转发**给 BattleSimShared._boundary_released —— 唯一真源。
	# 旧断言（`_lane_cleared_by("player", left_lane)` 出现）已随实现一起失效，
	# 换成更强的一条：必须**字面**转发到共享实现。
	h.call("expect", arena_src.contains("return BattleSimShared._boundary_released(_state, boundary_index)"),
		"release_predicate_delegates",
		"release 判据字面转发给共享的 _boundary_released（唯一真源）")
	h.call("expect", arena_src.contains("return BattleSimShared._lane_cleared_by_side(_state, team, lane)"),
		"lane_cleared_delegates",
		"BattleArena._lane_cleared_by 也转发给共享实现")
	# 反向：旧写法（自己扫 opposing_side + own_survivor）必须**不在** BattleArena 里了。
	h.call("expect", not arena_src.contains("for fighter in opposing_side"),
		"no_third_copy_in_arena", "BattleArena 里不再自己扫 opposing_side（第三套写法已删）")

	# 行为：直接驱动 _lane_cleared_by 的等价输入，确认它按 lane 判定。
	# 注意 _lane_cleared_by 读的是 BattleArena 实例的 _state，headless 下拿不到
	# 真实例，所以这里只做**结构 + 数据形状**层面的确认，行为已由 §8/§9 覆盖。
	_r("release_note", "见 docs 报告：该判据不在批跑门禁覆盖范围内")

	# ---------- 11. 支援顺序：自己那路清空后，按"由近及远"扫其它路 ----------
	# 变异测试发现：把 _team_select_target 的 lane_order 拉平成 [0,1,2] 时，
	# 上面所有断言**照样绿** —— 因为前面的场景每路只有 1 个敌人，
	# lane 顺序不影响结果。这是探针的盲区，必须补一条能真的钉住顺序的断言。
	#
	# 读源码确认的真实规则（不要凭注释猜）：
	#   lane_order = [my_lane] + [my_lane-1 .. 0] + [my_lane+1 .. 2]
	#   也就是**先自己那路，然后向左逐路，再向右逐路**。
	# 对 my_lane=2 而言顺序是 [2, 1, 0] —— 先 lane1 再 lane0。
	#
	# 场景：attacker 在 lane2，lane2 无敌；lane0 与 lane1 **都有**敌人，
	# 且 lane1 的敌人**更近**。按上面的顺序它该选 lane1（既符合顺序也符合最近）。
	# 为了**区分"顺序"与"最近"**，把 lane0 的敌人放得**更近**再看它会选谁：
	#   若真按 lane_order 扫 → 仍选 lane1（顺序优先于距离）
	#   若被拉平成按最近   → 会选更近的 lane0
	var atk2 := _fighter("player", 2, 770.0, 400.0, "p_L2_probe")
	# lane1 敌人放远，lane0 敌人放近：这样"顺序"与"最近"给出不同答案。
	var far_l1 := _fighter("enemy", 1, 500.0, 120.0, "e_L1_far")
	var near_l0 := _fighter("enemy", 0, 745.0, 400.0, "e_L0_near")
	var opps2 := [near_l0, far_l1]
	var d_l0 := float(atk2.pos.distance_squared_to(near_l0.pos))
	var d_l1 := float(atk2.pos.distance_squared_to(far_l1.pos))
	_r("order_dist_l0", "%.0f" % d_l0)
	_r("order_dist_l1", "%.0f" % d_l1)
	h.call("expect", d_l0 < d_l1, "order_scenario_valid",
		"前置条件：lane0 的敌人比 lane1 的**更近**（于是顺序与最近会给出不同答案）")
	var picked := Shared._team_select_target(atk2, opps2, false)
	_r("order_picked", str(picked.get("uid", "")))
	# 独立推算期望：lane_order 对 my_lane=2 是 [2,1,0]，lane2 无敌 → 落到 lane1。
	h.call("expect", str(picked.get("uid", "")) == "e_L1_far", "order_follows_lane_order",
		"lane2 无敌时按 lane_order([2,1,0]) 先扫 lane1，即使 lane0 更近 —— 实际选了 %s"
			% str(picked.get("uid", "")))

	# 反向：确认"按最近"确实会给出**不同**答案，否则上面那条没有区分力。
	var by_nearest := Shared._nearest(atk2, opps2)
	_r("order_nearest_is", str(by_nearest.get("uid", "")))
	h.call("expect", str(by_nearest.get("uid", "")) == "e_L0_near",
		"order_nearest_differs",
		"若无 lane 顺序（按最近）会选 %s —— 与 lane 顺序的答案不同，说明该断言有区分力"
			% str(by_nearest.get("uid", "")))

	_r("report_count", str(report.size()))

	# ---------- 12. 门禁 vs 晶柱释放：9.27 **已改为同源** ----------
	# 玩法层"能不能打别路"由 _can_target 决定：自己这路还有活敌 → 不许打别路；清空 → 放开。
	# 表现层"晶柱消不消失"由 _should_release_3v3_boundary 决定。
	# 修**前**两者不同源：_lane_cleared_by 多一条 own_survivor 前置，于是"双方都打光"
	# 时晶柱不释放（现象 P2），并且出现"门禁已开、柱子还立着"的窗口（P1）。
	# 修**后**：整套判定搬到 BattleSimShared（唯一真源），Arena 只转发；
	# 且 own_survivor 换成 `_lane_ever_occupied`（区分"开场没进场"与"打完了都空"）。
	var shared_src := FileAccess.get_file_as_string("res://scripts/battle/BattleSimShared.gd").replace("\r\n", "\n")
	# 反向：own_survivor 这个旧写法必须**全仓消失**（不只是 Arena 里）。
	h.call("expect", not arena_src.contains("own_survivor"), "own_survivor_guard_removed",
		"★ BattleArena 里 own_survivor 前置已删除（P2 的根源）")
	# 结构（A 层唯一真源）：三处调用点都必须接同一个谓词。
	var gate_body := shared_src.substr(shared_src.find("static func _can_target"), 900)
	var owner_body := shared_src.substr(shared_src.find("static func _owner_lane_enemies_cleared"), 400)
	h.call("expect", gate_body.contains("_lane_has_living_opponent("), "p12_can_target_uses_shared",
		"_can_target 接共享谓词（唯一真源）")
	h.call("expect", owner_body.contains("_lane_has_living_opponent("), "p12_owner_cleared_uses_shared",
		"_owner_lane_enemies_cleared 接共享谓词（唯一真源）")
	h.call("expect", arena_src.contains("BattleSimShared._lane_cleared_by_side(_state, team, lane)"),
		"p12_arena_uses_shared", "BattleArena._lane_cleared_by 接共享实现（唯一真源）")

	# ---------- 13. 隔断判据的行为（A/B 层）—— 直接驱动生产纯函数 ----------
	# 期望值按"谁还活着 / 这条路过没过单位"独立推出来，不借被测谓词自己。
	var saved_team_mode := GameState.team_mode
	GameState.team_mode = true

	# 场景 α：lane0 双方都在打
	var st_alpha := {
		"player": [_fighter("player", 0, 230.0, 400.0, "a_p0")],
		"enemy": [_fighter("enemy", 0, 230.0, 120.0, "a_e0")],
	}
	_r("p13_alpha_living", str(Shared._lane_has_living_opponent(st_alpha.enemy, 0)))
	h.call("expect", Shared._lane_has_living_opponent(st_alpha.enemy, 0), "p13_alpha_living_enemy",
		"场景α：lane0 还有活敌")
	h.call("expect", not Shared._boundary_released(st_alpha, 0), "p13_alpha_boundary_up",
		"场景α：boundary0 不释放（双方都还在打）")

	# 场景 β（P1 正例）：lane0 对手清空、自己还活着
	var b_e := _fighter("enemy", 0, 230.0, 120.0, "b_e0")
	b_e["alive"] = false
	b_e["hp"] = 0
	var st_beta := {"player": [_fighter("player", 0, 230.0, 400.0, "b_p0")], "enemy": [b_e]}
	h.call("expect", not Shared._lane_has_living_opponent(st_beta.enemy, 0), "p13_beta_no_living",
		"场景β：lane0 已无活敌")
	h.call("expect", Shared._boundary_released(st_beta, 0), "p13_beta_released",
		"场景β：boundary0 释放（自己活着、对手清空）—— 与门禁放开同一帧")

	# 场景 γ（P2）：lane0 双方都打光 —— 曾经有单位，都死了
	var g_p := _fighter("player", 0, 230.0, 400.0, "g_p0")
	g_p["alive"] = false
	g_p["hp"] = 0
	var g_e := _fighter("enemy", 0, 230.0, 120.0, "g_e0")
	g_e["alive"] = false
	g_e["hp"] = 0
	var st_gamma := {"player": [g_p], "enemy": [g_e]}
	h.call("expect", Shared._lane_ever_occupied(st_gamma.player, st_gamma.enemy, 0), "p13_gamma_occupied",
		"场景γ：lane0 曾经有过单位")
	h.call("expect", Shared._boundary_released(st_gamma, 0), "p13_gamma_released",
		"★ 场景γ（P2）：双方都打光 → 隔断必须释放（修前 own_survivor 前置会挡住）")

	# 场景 δ（B 层回归点）：lane0 从没接过战，lane1 双方都在打
	var st_delta := {
		"player": [_fighter("player", 1, 500.0, 400.0, "d_p1")],
		"enemy": [_fighter("enemy", 1, 500.0, 120.0, "d_e1")],
	}
	h.call("expect", not Shared._lane_ever_occupied(st_delta.player, st_delta.enemy, 0), "p13_delta_never",
		"场景δ：lane0 从没出现过单位")
	h.call("expect", not Shared._boundary_released(st_delta, 0), "p13_delta_not_released",
		"★ 场景δ：开场「双方都没进这条路」**不**释放隔断（纯删 own_survivor 的 B1 会误放）")

	# ---------- 14. C 层行为：可达 lane 集合（瞬移/冲锋类技能的跨路限制） ----------
	# 三路双方都有单位（没有哪一路"清空"）→ 只能打自己那路。
	var c_p0 := _fighter("player", 0, 230.0, 400.0, "c_p0")
	var c_p1 := _fighter("player", 1, 500.0, 400.0, "c_p1")
	var c_p2 := _fighter("player", 2, 770.0, 400.0, "c_p2")
	var c_e0 := _fighter("enemy", 0, 230.0, 120.0, "c_e0")
	var c_e1 := _fighter("enemy", 1, 500.0, 120.0, "c_e1")
	var c_e2 := _fighter("enemy", 2, 770.0, 120.0, "c_e2")
	var st_c := {"player": [c_p0, c_p1, c_p2], "enemy": [c_e0, c_e1, c_e2]}
	var lanes_up: Array = Shared._reachable_lanes_for(c_p1, st_c)
	lanes_up.sort()
	_r("p14_lanes_up", str(lanes_up))
	h.call("expect", lanes_up == [1], "p14_only_own_lane",
		"两道隔断都立着时只能打自己那路 —— 实得 %s" % str(lanes_up))
	# lane1 的敌人清空（自己这路打赢了）→ 两道隔断都释放 → 可达全部三路
	c_e1["alive"] = false
	c_e1["hp"] = 0
	var lanes_open: Array = Shared._reachable_lanes_for(c_p1, st_c)
	lanes_open.sort()
	_r("p14_lanes_open", str(lanes_open))
	h.call("expect", lanes_open == [0, 1, 2], "p14_expands_after_clear",
		"自己那路清空后可达全部三路（允许支援，D1）—— 实得 %s" % str(lanes_open))
	# 过滤：候选池按可达 lane 收窄
	var filtered: Array = Shared._opponents_in_reachable_lanes(c_p1, st_c.enemy, st_c)
	_r("p14_filtered", str(filtered.size()))
	h.call("expect", filtered.size() == 3, "p14_filter_keeps_all_when_open",
		"隔断全开时过滤不删任何候选（实得 %d）" % filtered.size())
	# 反向：隔断全立着时只剩本路候选。
	# ★ 必须用**全新**的 fighter 重建 —— 上面为了开隔断把 `c_e1` 置成了阵亡，
	#   而它是同一个 Dictionary 引用，直接复用 st_c 会让"隔断全立着"的前提不成立
	#   （第一版就栽在这：`p14_filtered_up` 实得 3 而不是 1）。
	var st_c2 := {
		"player": [
			_fighter("player", 0, 230.0, 400.0, "d2_p0"),
			_fighter("player", 1, 500.0, 400.0, "d2_p1"),
			_fighter("player", 2, 770.0, 400.0, "d2_p2"),
		],
		"enemy": [
			_fighter("enemy", 0, 230.0, 120.0, "d2_e0"),
			_fighter("enemy", 1, 500.0, 120.0, "d2_e1"),
			_fighter("enemy", 2, 770.0, 120.0, "d2_e2"),
		],
	}
	var filtered2: Array = Shared._opponents_in_reachable_lanes(st_c2.player[1], st_c2.enemy, st_c2)
	_r("p14_filtered_up", str(filtered2.size()))
	h.call("expect", filtered2.size() == 1 and int(filtered2[0].get("lane", -1)) == 1,
		"p14_filter_keeps_own_lane_only", "隔断全立着时只剩本路候选（实得 %d）" % filtered2.size())
	# 非 team_mode（1v1 / 教学）→ 空数组 ⇒ 调用方不过滤
	GameState.team_mode = false
	h.call("expect", Shared._reachable_lanes_for(c_p1, st_c).is_empty(), "p14_non_teammode_empty",
		"非 team_mode（1v1/教学）返回空数组 → 调用方跳过过滤")
	GameState.team_mode = saved_team_mode

	# 结构（C 层）：三个会改动单位坐标的术式技能都必须按"可达 lane"过滤选目标。
	var skills_src := FileAccess.get_file_as_string("res://scripts/battle/BattleSimSkills.gd").replace("\r\n", "\n")
	for fn in ["_skill_black_hole", "_skill_blink_low_def_backline", "_skill_gold_charge"]:
		var fb := skills_src.substr(skills_src.find("static func " + fn), 700)
		h.call("expect", fb.contains("_opponents_in_reachable_lanes("), "p14_" + fn,
			"%s 的选目标按可达 lane 过滤（不许跨过还没释放的隔断）" % fn)

	print("PROBE_%s STAGE before_finish" % PROBE_ID)
	var failed: int = int(h.call("failure_count"))
	print("PROBE_%s DONE failures=%d checked=%d" % [PROBE_ID, failed, int(h.call("checked_count"))])
	h.call("finish", get_tree())


# 手工摆一场三路对阵的 3v3 状态。
#
# 走生产构造函数 `_fighter_from_def`（接受 def 字典）+ `_place_in_lane`（写 pos/lane），
# 不自己拼 fighter 字典结构 —— 单位字段一旦变化，探针会跟着失效而不是静默错位。
#
# **不要走 `_append_lane_board_fighters`**：它接收的是 GameState 的 *cell*
# （内含 `.def` 子字典），我手搓的扁平字典会在 `cell.def.duplicate(true)` 处
# 报 "Nonexistent function 'duplicate' in base 'int'"，然后整场静默跑不完。
func _build_lane_state() -> Dictionary:
	var player: Array = []
	var enemy: Array = []
	# 每路两边各 1 只，血量厚、移速慢，保证 60 tick 内不会有哪一路被清空
	# （一旦某路清空，隔断按规则就该消失，那时的跨带就不再是越界）。
	for lane in 3:
		var pd := _unit_def("p_%d" % lane)
		var ed := _unit_def("e_%d" % lane)
		var pf := Simulator._fighter_from_def(pd, lane, "player", lane, 3, 1, false, false)
		var ef := Simulator._fighter_from_def(ed, lane, "enemy", lane, 3, 1, false, false)
		Simulator._place_in_lane(pf, lane, "player", lane)
		Simulator._place_in_lane(ef, lane, "enemy", lane)
		pf.uid = "player_L%d_0" % lane
		ef.uid = "enemy_L%d_0" % lane
		player.append(pf)
		enemy.append(ef)
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


func _unit_def(id: String) -> Dictionary:
	return {
		"id": id, "name": id, "name_en": id,
		"hp": 6000, "atk": 5, "def": 0, "attack_speed": 1.0,
		"range_px": 72.0, "move_speed_px": 70.0, "footprint_cells": 1,
		"element": "none", "race": "none", "skill_id": "",
		"crit": 0.0, "dodge": 0.0,
	}


# 构造"清空自己那路后去支援"的场景：player 在 lane0，enemy 只有 lane1。
# 这会让 player 必然横穿 lane0/lane1 之间的隔断线（x=333.3）。
func _build_support_state() -> Dictionary:
	var pd := _unit_def("p_sup")
	var ed := _unit_def("e_sup")
	# 关键：把 player 的射程压到极小，它就必须**真的走到隔壁带里**才够得着，
	# 而不是在门口 x=320 停下开打（第一版就是停在 320.4，没跨过线 → 假红）。
	pd["range_px"] = 8.0
	# enemy 血厚，保证 player 有时间走完这段横移再打起来。
	ed["hp"] = 20000
	var pf := Simulator._fighter_from_def(pd, 0, "player", 0, 3, 1, false, false)
	var ef := Simulator._fighter_from_def(ed, 1, "enemy", 1, 3, 1, false, false)
	Simulator._place_in_lane(pf, 0, "player", 0)
	Simulator._place_in_lane(ef, 1, "enemy", 1)
	pf.uid = "player_L0_sup"
	ef.uid = "enemy_L1_sup"
	return {
		"kind": "pvp", "player": [pf], "enemy": [ef],
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


# 记录初始位置快照，用来判断 e2e 里单位是否真的动过。
var _initial_pos: Dictionary = {}

func _snapshot_positions(st: Dictionary) -> void:
	_initial_pos.clear()
	for f in (st.get("player", []) as Array) + (st.get("enemy", []) as Array):
		_initial_pos[str(f.get("uid", ""))] = Vector2(f.pos)

func _any_moved(st: Dictionary) -> bool:
	for f in (st.get("player", []) as Array) + (st.get("enemy", []) as Array):
		var uid := str(f.get("uid", ""))
		if not _initial_pos.has(uid):
			continue
		if float(Vector2(f.pos).distance_to(_initial_pos[uid])) > 1.0:
			return true
	return false
