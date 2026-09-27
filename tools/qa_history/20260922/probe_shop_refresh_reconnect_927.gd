extends Node

# 9.27 调查探针：备战期「刷过商店 → 掉线重连 → 刷新变便宜」。
#
# 用户要的是**判定存不存在**，不是修。所以这个探针只做一件事：
#   把「掉线重连」这条链上**每一个会写 `GameState.shop_refresh_uses_this_round`
#   的地方**都单独驱动一遍，看它会不会把这个计数打回 0。
#
# 关键：费用公式是 `shop_refresh_cost(uses)`：
#   uses=0 → 0（首刷免费） / 1 → 10 / 2 → 20 / 3 → 40 / 4 → 80 …
# 所以只要 uses 被重置成 0，下一刷就**从 40 变回 0** —— 这正是玩家看到的"费用变少"。
#
# 探针原则（沿用本仓约定）：
#   · 只驱动**生产实现**，不在探针里复刻一份逻辑
#   · 每个"安全"结论都要有对应的**反例断言**证明它不是因为没跑到而假绿
#   · 判据不自证：期望值由费用公式独立算出

const Harness := preload("res://tools/CheckHarness.gd")
const Rules := preload("res://scripts/economy/CarrotEconomy.gd")

const PROBE_ID := "shop_refresh_reconnect_927"

var h: RefCounted
var report: Array = []

func _r(tag: String, value: String) -> void:
	report.append("%s=%s" % [tag, value])
	print("PROBE_%s %s=%s" % [PROBE_ID, tag, value])

func _cost(uses: int) -> int:
	# 独立算：不借被测的 GameState，直接走生产纯函数。
	return EconomyService.shop_refresh_cost(uses, TutorialMode.shop_refresh_all_free())

func _ready() -> void:
	h = Harness.new(PROBE_ID)

	# ---------- 0. 先把费用曲线钉死，后面的"变少"才可解释 ----------
	_r("cost_at_0", str(_cost(0)))
	_r("cost_at_1", str(_cost(1)))
	_r("cost_at_2", str(_cost(2)))
	_r("cost_at_3", str(_cost(3)))
	h.call("expect", _cost(0) == 0, "cost_0_free", "首刷 0 金（uses=0）")
	h.call("expect", _cost(1) == 10 and _cost(2) == 20 and _cost(3) == 40,
		"cost_curve", "曲线 0/10/20/40 —— uses 归零即等于费用变少")

	# ---------- 1. 唯一写入点盘点（结构） ----------
	var ns_src := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	var pbc_src := FileAccess.get_file_as_string("res://scenes/prep/PrepBoardController.gd")
	var gs_src := FileAccess.get_file_as_string("res://scripts/autoload/GameState.gd")
	var main_src := FileAccess.get_file_as_string("res://scenes/main/Main.gd")

	var W := "shop_refresh_uses_this_round"
	_r("writes_ns", str(ns_src.count(W + " =")))
	_r("writes_pbc", str(pbc_src.count(W + " +=") + pbc_src.count(W + " =")))
	_r("writes_gs", str(gs_src.count(W + " =")))
	_r("writes_main", str(main_src.count(W + " =")))
	# 反向：Main.gd **不得**直接写这个字段（它只该调 reset_shop_refreshes()）。
	h.call("expect", not main_src.contains(W + " ="), "main_no_direct_write",
		"Main.gd 不直接写该字段（只经 reset_shop_refreshes）")
	# 9.27：修**前** NetworkService 里只有 receipt 一处写（room_state 不恢复它）→ 重连丢计数。
	# 修**后**应有**两处**：receipt 分支 + _apply_server_shop 的 room_state 同步通道。
	# 把期望写成确切的 2 而不是 ">=1"，是为了让"第三处悄悄出现"也立刻红。
	_r("ns_write_count", str(ns_src.count(W + " =")))
	h.call("expect", ns_src.count(W + " =") == 2, "ns_two_write_points",
		"NetworkService 里该字段恰有两处赋值：receipt 分支 + room_state 同步（修前只有 1 处）")

	# ---------- 2. 正常刷新：计数递增、费用爬升 ----------
	GameState.tutorial_mode = false
	GameState.gold = 1000
	GameState.reset_shop_refreshes()
	_r("after_reset", str(GameState.shop_refresh_uses_this_round))
	var c1 := _cost(GameState.shop_refresh_uses_this_round)
	GameState.gold -= c1
	GameState.shop_refresh_uses_this_round += 1
	var c2 := _cost(GameState.shop_refresh_uses_this_round)
	GameState.gold -= c2
	GameState.shop_refresh_uses_this_round += 1
	var c3 := _cost(GameState.shop_refresh_uses_this_round)
	GameState.gold -= c3
	GameState.shop_refresh_uses_this_round += 1
	_r("uses_after_3_refresh", str(GameState.shop_refresh_uses_this_round))
	_r("costs_sequence", "%d,%d,%d" % [c1, c2, c3])
	h.call("expect", GameState.shop_refresh_uses_this_round == 3, "three_uses", "刷三次 → uses=3")
	h.call("expect", c1 == 0 and c2 == 10 and c3 == 20, "seq_0_10_20", "三次花费 0/10/20")

	# 此刻"下一次刷新"是第 4 次，应付 40。
	var next_cost_before := _cost(GameState.shop_refresh_uses_this_round)
	_r("next_cost_before_reconnect", str(next_cost_before))
	h.call("expect", next_cost_before == 40, "next_40", "重连前下一次刷新应付 40")

	# ---------- 3. 掉线重连候选路径 A：_begin_reconnect（活着的瞬断） ----------
	# 这条路径**故意不调 reset()**，只 reset_peer_only()。验证它不动这个计数。
	NetworkService.team_active = true
	NetworkService.session_token = "probe-token"
	NetworkService.reconnect_address = "127.0.0.1"
	NetworkService.call("_begin_reconnect", "probe")
	_r("after_begin_reconnect", str(GameState.shop_refresh_uses_this_round))
	h.call("expect", GameState.shop_refresh_uses_this_round == 3, "A_begin_reconnect_keeps",
		"瞬断重连(_begin_reconnect) 不动 shop_refresh_uses_this_round")

	# ---------- 4. 掉线重连候选路径 B：NetworkService.reset() ----------
	# app 被杀重开 / begin_resume_from_disk() 会走这里。它清了 four_star 版本等一票会话态，
	# 检查它**是否**顺手清掉刷新计数（若清了 = 直接命中用户的报告）。
	NetworkService.reset()
	_r("after_ns_reset", str(GameState.shop_refresh_uses_this_round))
	h.call("expect", GameState.shop_refresh_uses_this_round == 3, "B_ns_reset_keeps",
		"NetworkService.reset() 不清 GameState 的刷新计数（GameState 不归它管）")

	# ---------- 5. 掉线重连候选路径 C：GameState.reset_run() ----------
	# 这是"换了一本账"，会清零。关键是：重连**不该**走到这里。
	var gs_reset_src := gs_src
	h.call("expect", gs_reset_src.contains(W + " = 0"), "C_reset_run_zeroes",
		"GameState.reset_run() 会清零（本回合计数）—— 它若在重连时被调到就是缺陷")

	# ---------- 6. 掉线重连候选路径 D：结算 apply ----------
	# Main._apply_team_match_state_payload 会调 reset_shop_refreshes()，但**只在
	# result 非空**时（即真的打完一场）。查这个守卫还在不在。
	var settle_guard := main_src.contains("if not result.is_empty():")
	h.call("expect", settle_guard, "D_settle_guard",
		"结算清零受 `if not result.is_empty()` 守卫 —— 纯 match_state 不触发")
	# 反向：_on_network_match_state_received 调 apply 时**不传 result**。
	h.call("expect", main_src.contains("_apply_team_match_state_payload(state_payload)")
		and not main_src.contains("_apply_team_match_state_payload(state_payload, {}"),
		"D_reconnect_no_result",
		"重连路径 _on_network_match_state_received 调用时不带 result → 不清零")

	# ---------- 7. 掉线重连候选路径 E：SaveManager.load_run() 恢复 ----------
	# 磁盘存档**带** shop_refresh_uses_this_round（SaveManager.gd:281/332）。
	# 若重连走了 load_run()，计数会回到"存档那一刻"的值 —— 存档是在每次刷新后写的，
	# 所以这里应当一致、不会变小。但要注意它依赖「存档是否最新」。
	var sm_src := FileAccess.get_file_as_string("res://scripts/autoload/SaveManager.gd")
	h.call("expect", sm_src.contains("\"shop_refresh_uses_this_round\": GameState.shop_refresh_uses_this_round"),
		"E_save_writes", "存档会写出该计数")
	h.call("expect", sm_src.contains("GameState.shop_refresh_uses_this_round = int(parsed.get(\"shop_refresh_uses_this_round\", 0))"),
		"E_load_restores", "读档会恢复该计数（缺字段时才回落 0）")
	# 关键：刷新成功后是否立刻落盘？否则"刷新→立刻掉线"会读到旧存档。
	h.call("expect", pbc_src.contains("SaveManager.save_run()"), "E_save_after_refresh",
		"刷新流程内确实调了 save_run()")

	# ---------- 8. 最要紧的一条：重连时 load_run() 到底跑不跑 ----------
	# Main.gd:384 `if _team_run_state_is_fresh(): SaveManager.load_run()`
	# _team_run_state_is_fresh() 在**棋盘/备战席任一格非空时返回 false**。
	var fresh_fn_ok := main_src.contains("func _team_run_state_is_fresh() -> bool:")
	_r("has_fresh_fn", str(fresh_fn_ok))
	h.call("expect", fresh_fn_ok and main_src.contains("if _team_run_state_is_fresh():"),
		"F_fresh_gate", "重连时是否读盘受 _team_run_state_is_fresh() 闸门控制")
	# 结论（结构）：棋盘上有子 → false → **不读盘** → 计数沿用内存值。
	h.call("expect", main_src.contains("for cell in GameState.board_slots:")
		and main_src.contains("\t\t\treturn false"),
		"F_fresh_returns_false_on_board",
		"棋盘/备战席有子即 false（mid-match 常态）→ 不读盘")

	# ---------- 9. 反例断言：证明上面不是「没跑到」 ----------
	# 手动把计数打回 0，看费用是否真的变少 —— 证明这条链"能"产生该症状。
	GameState.shop_refresh_uses_this_round = 0
	var cost_if_zeroed := _cost(GameState.shop_refresh_uses_this_round)
	_r("cost_if_zeroed", str(cost_if_zeroed))
	h.call("expect", cost_if_zeroed == 0 and cost_if_zeroed < next_cost_before,
		"G_negative_control",
		"反例：计数归 0 则费用 40→0，症状可复现（证明断言非空过）")

	# ---------- 10. ★ 主结论（9.27 已修）：服务端的 refresh_uses 必须回流到 GameState ----------
	# 服务端是**费用权威**：EconomyLedger._shop_refresh 读自己的 prep.shop.refresh_uses
	# 算价并 +1，把结果放回执 result.refresh_uses。
	#
	# 9.27 修**前**：只有 receipt 分支写 GameState；room_state（重连恢复的主通道）带来的
	# `economy.shop.refresh_uses` 只被存进 server_shop 副本、**不回流** —— 于是
	# 「备战期刷过商店 → 掉线/杀进程重连 → 价签显示 0、服务端照 40 收」。
	# 9.27 修**后**：_apply_server_shop 顺手同步 —— 两条通道都能把权威次数送到 UI。
	var elf := "refresh_uses"
	_r("ns_reads_refresh_uses", str(ns_src.count(elf)))
	# (a) 结构：回执分支仍在写（不能因为新加了 room_state 通道就退化）
	var writes_state_from_receipt := ns_src.contains(W + " = int(result.get(\"" + elf + "\"")
	_r("ns_receipt_write", str(writes_state_from_receipt))
	h.call("expect", writes_state_from_receipt, "H_receipt_write_exists",
		"回执分支仍把 result.refresh_uses 写进 GameState")
	# (b) 结构：room_state 通道也必须写（这是本次新增的那一行）
	var writes_state_from_shop := ns_src.contains(W + " = maxi(0, int((shop")
	_r("ns_roomstate_write", str(writes_state_from_shop))
	h.call("expect", writes_state_from_shop, "H_roomstate_sync_exists",
		"★ _apply_server_shop 把 shop.refresh_uses 同步进 GameState（重连通道已修）")
	# (c) 结构：同步必须受 has() 守卫 —— 回执路径传进来的 shop 不带该键，无守卫就会
	#     把刚写好的计数覆盖成 0（本次改动真正的回归风险）。
	var guarded := ns_src.contains("if (shop as Dictionary).has(\"refresh_uses\")")
	_r("ns_roomstate_guarded", str(guarded))
	h.call("expect", guarded, "H_roomstate_sync_guarded",
		"同步被 has(refresh_uses) 守卫 —— 回执路径（不带该键）不会被覆盖成 0")

	# ---------- 11. ★ 行为：重连后客户端计数必须采纳服务端的值 ----------
	# 服务端侧（权威）：
	var srv_prep := {"shop": {"refresh_uses": 0, "offer_id": "o0", "offers": [], "sold": []},
		"gold": 1000}
	var srv_costs: Array = []
	for _i in 3:
		var rc: Dictionary = EconomyLedger._shop_refresh(srv_prep, {}, {
			"owned_treasures": [], "offer_id": "o%d" % _i, "rolled_offers": [{}]})
		srv_costs.append(int(rc.get("result", {}).get("cost", -1)))
	var srv_uses := int(srv_prep["shop"]["refresh_uses"])
	_r("srv_costs", str(srv_costs))
	_r("srv_uses", str(srv_uses))
	h.call("expect", srv_costs == [0, 10, 20] and srv_uses == 3, "srv_authoritative",
		"服务端权威：三次 0/10/20，refresh_uses=3")

	# 客户端侧：模拟「回执没到」→ GameState 计数从未被推进（停在 0）。
	GameState.shop_refresh_uses_this_round = 0
	# 反例先钉住：不带 refresh_uses 的 shop（= 回执路径的形状）**不得**改动计数。
	NetworkService._apply_server_shop({"shop": {"offer_id": "o2", "offers": [{}], "sold": [false]}})
	_r("client_after_keyless_shop", str(GameState.shop_refresh_uses_this_round))
	h.call("expect", GameState.shop_refresh_uses_this_round == 0, "H_keyless_no_clobber",
		"反例：shop 不带 refresh_uses 时计数不动（回执路径不会被覆盖成 0）")
	# 重连：room_state 带来服务端的 refresh_uses=3 → 必须被采纳。
	NetworkService._apply_server_shop({"shop": {
		"offer_id": "o2", "offers": [{}], "sold": [false], "refresh_uses": srv_uses}})
	NetworkService._apply_carrot_state({"carrot_authoritative": true, "shop": {
		"offer_id": "o2", "offers": [{}], "sold": [false], "refresh_uses": srv_uses}})
	_r("client_after_reconnect", str(GameState.shop_refresh_uses_this_round))
	# 注意形状：`_apply_server_shop` 把传入的 `state["shop"]` 整份赋给 server_shop，
	# 所以字段在 **server_shop 顶层**（不是 server_shop["shop"]）。
	_r("server_shop_refresh_uses", str(int(NetworkService.server_shop.get("refresh_uses", -1))))
	h.call("expect", GameState.shop_refresh_uses_this_round == 3, "H_client_now_synced",
		"★ 重连后客户端计数采纳服务端的 3（修前停在 0）")
	h.call("expect", int(NetworkService.server_shop.get("refresh_uses", -1)) == 3,
		"H_server_shop_has_3", "server_shop 里带着服务端的 3（与 GameState 同步）")

	# 价签与服务端实收必须一致：下一刷两边都算 40。
	var client_next := _cost(GameState.shop_refresh_uses_this_round)
	var server_next: int = EconomyService.shop_refresh_cost(srv_uses, false)
	_r("client_next_cost", str(client_next))
	_r("server_next_cost", str(server_next))
	h.call("expect", client_next == 40 and server_next == 40, "H_cost_in_sync",
		"★ 客户端显示 40 / 服务端应收 40（修前是 0 vs 40，即『刷新费用变少』）")
	# 反向对照：**若不采纳**服务端的 3（旧口径），费用就是 0 —— 证明上面那条非空过。
	h.call("expect", _cost(0) == 0, "H_negative_control_kept",
		"反例保留：计数若仍是 0 则费用为 0（对照 H_cost_in_sync 非空过）")

	# ---------- 12. ★ 触发是确定性的：reset() 清等待表 ⇒ in-flight 回执必被丢 ----------
	# _rpc_economy_receipt 开头 `if not _tx_consume(request_id): return`；
	# _tx_consume 查 _tx_pending；而 reset() 里 `_tx_pending.clear()`。
	# ⇒ 走 reset() 的重连（app 被杀重开）下，刷新回执**必然**被丢弃。
	h.call("expect", ns_src.contains("func _tx_consume("), "I_consume_exists", "存在交易幂等闸")
	h.call("expect", ns_src.contains("if not _tx_consume(request_id):"), "I_receipt_gated",
		"回执入口受 _tx_consume 门控（不在等待表即丢弃）")
	h.call("expect", ns_src.contains("_tx_pending.clear()"), "I_reset_clears_pending",
		"reset() 清空等待表 ⇒ in-flight 回执必丢（确定性触发）")
	# 行为验证：reset() 之后，一个刚登记的单子再也收不下回执。
	# 直接驱动 `_tx_begin` / `_tx_consume`（真正的幂等机制），不绕 request_economy ——
	# 后者在无头环境因 multiplayer_peer == null 会直接返回 ""，断言会变成空过。
	var rid: String = NetworkService.call("_tx_begin", "economy", ["shop_refresh", {"gold": 500}])
	_r("rid_after_begin", rid)
	h.call("expect", not rid.is_empty(), "I_rid_issued",
		"前置：交易单子确实登记进等待表（否则下面的断言是空过）")
	_r("consume_before_reset", str(NetworkService.call("_tx_consume", rid)))
	NetworkService.call("_tx_begin", "economy", ["shop_refresh", {"gold": 500}])   # 再造一张
	NetworkService.reset()
	# 注意：上面第一张 rid 已被 consume_before_reset 消费掉，这里用第二张验证。
	var rid2: String = NetworkService.call("_tx_begin", "economy", ["shop_refresh", {"gold": 1}])
	NetworkService.reset()
	var consumed: bool = NetworkService.call("_tx_consume", rid2)
	_r("consume_after_reset", str(consumed))
	h.call("expect", not consumed, "I_receipt_dropped_deterministic",
		"★ reset() 后旧 request_id 的 _tx_consume 返回 false ⇒ 回执必被丢弃")

	# 收尾：还原
	GameState.gold = 0
	GameState.tutorial_mode = false
	GameState.reset_shop_refreshes()
	NetworkService.team_active = false
	NetworkService.session_token = ""
	NetworkService.reconnect_address = ""

	print("PROBE_REPORT_%s BEGIN" % PROBE_ID)
	for line in report:
		print("PROBE_REPORT_%s %s" % [PROBE_ID, line])
	print("PROBE_REPORT_%s END" % PROBE_ID)

	var checked: int = h.call("checked_count")
	var failed: int = h.call("failure_count")
	print("PROBE_DONE %s checked=%d failed=%d" % [PROBE_ID, checked, failed])
	h.call("finish", get_tree())
