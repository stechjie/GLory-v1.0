extends Node

# 2026-10-07：人王 / 老虎的成长改记在每枚棋子上（scripts/units/UnitGrowth.gd）。
#
# 用户定的规则，每条都走真代码验：
#   1. 老虎：每次升星（合成 / 升四星），当时手上（棋盘 + 待命区）每一枚一阶棋子 +5%，累计；
#      之后才买的不吃；合成出来的那一枚继承被合掉的几枚里最高的层数，再吃这一次的 +5%。
#   2. 人王：PvE / Boss / PvP 活过一场就长一层，阵亡移出棋盘。按「主人座位 + 棋子 uid」认，
#      不再按格子号（三路同一个格子号分不清是谁的）。
#   3. 摆放界面看到的数 = 实战里乘上去的数（详情和战斗读同一个 UnitGrowth.stat_multiplier）。
# 加两条联网的：成长随棋盘提交，过 NetProtocol 的结构上限和服务器账本上限；而且战斗读棋盘的
# 那条路（extract_board → sanitize_cell）不能把它丢掉 —— 以前人王的成长就丢在这一步，
# 线上一层都没生效过。
#
# 运行：
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . tools/unit_growth_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const UnitGrowth := preload("res://scripts/units/UnitGrowth.gd")
const MainScript := preload("res://scenes/main/Main.gd")

const CHECK_NAME := "unit_growth"
const TIGER := "pet_tiger"
const KING := "human_king"
const TIER1_A := "god_priest"
const TIER1_B := "dark_imp"
const TIER1_C := "god_priestess"
const TIER2 := "god_guard"
const PVE_ROUND := 3
const PVP_ROUND := 6

var _h: CheckHarness
var _saved := {}


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_save_globals()
	_case_tiger_starup_per_piece()
	await _case_merges_through_prep_screen()
	_case_king_growth_rules()
	_case_fighter_applies_growth()
	_case_display_matches_battle()
	_case_wire_and_structural_clamps()
	_case_server_ledger_clamp()
	_case_carrot_state_follows_server_count()
	_case_king_outcomes_by_piece()
	_case_main_applies_outcomes()
	_case_team_battle_end_to_end(PVE_ROUND)
	_case_team_battle_end_to_end(PVP_ROUND)
	_restore_globals()
	_h.finish(get_tree())


# --- 1. 老虎：一次升星，手上每一枚一阶棋子 +1 层 ------------------------------------

func _case_tiger_starup_per_piece() -> void:
	GameState.reset_run()
	PlayerProfile.active_pet = TIGER
	var on_board := _cell(TIER1_A, "a")
	var on_bench := _cell(TIER1_B, "b", 2)   # 二星也算：阶级是购买阶级，升星不改
	var tier2 := _cell(TIER2, "c")
	GameState.board_slots[0] = on_board
	GameState.board_slots[1] = tier2
	GameState.bench_slots[0] = on_bench
	GameState.record_tiger_starup()
	GameState.record_tiger_starup()
	_h.expect(GameState.tiger_starup_count == 2, "tiger_count",
		"两次升星后次数应为 2，实际 %d" % GameState.tiger_starup_count)
	_h.expect(UnitGrowth.tiger_stacks(on_board) == 2, "tiger_board_tier1",
		"棋盘上的一阶棋子应有 2 层，实际 %d" % UnitGrowth.tiger_stacks(on_board))
	_h.expect(UnitGrowth.tiger_stacks(on_bench) == 2, "tiger_bench_tier1",
		"待命区的一阶棋子也要吃（用户原话「包括待命区」），实际 %d 层" % UnitGrowth.tiger_stacks(on_bench))
	_h.expect(int(tier2.get(UnitGrowth.TIGER_STACKS, 0)) == 0, "tiger_tier2_skipped",
		"二阶棋子不该有老虎层数")
	_h.expect(not UnitGrowth.tiger_eligible({"def": {"tier": 1}, "is_mercenary": true}),
		"tiger_merc_skipped", "佣兵不该吃老虎")
	# 之后才买的从 0 开始（用户定「之后买的不算」），下一次升星才 +1。
	var late := _cell(TIER1_C, "d")
	GameState.bench_slots[1] = late
	_h.expect(UnitGrowth.tiger_stacks(late) == 0, "tiger_late_buy_zero",
		"之后才买的棋子不该带着以前的层数")
	GameState.record_tiger_starup()
	_h.expect(UnitGrowth.tiger_stacks(late) == 1 and UnitGrowth.tiger_stacks(on_board) == 3,
		"tiger_late_buy_from_now", "第三次升星后：后买的应为 1 层、先前那枚应为 3 层，实际 %d / %d"
			% [UnitGrowth.tiger_stacks(late), UnitGrowth.tiger_stacks(on_board)])
	# 出战宠物不是老虎：次数和层数都不动。
	PlayerProfile.active_pet = "pet_cat"
	GameState.record_tiger_starup()
	_h.expect(GameState.tiger_starup_count == 3 and UnitGrowth.tiger_stacks(on_board) == 3,
		"tiger_other_pet_noop", "出战宠物不是老虎时升星不该加层")
	PlayerProfile.active_pet = TIGER


# --- 2. 合成：走摆放界面真的合成代码 --------------------------------------------------

func _case_merges_through_prep_screen() -> void:
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "prep_scene_load", "PrepScreen.tscn 无法加载"):
		return
	GameState.reset_run()
	NetworkService.team_active = false
	NetworkService.is_host = false
	PlayerProfile.active_pet = TIGER
	var screen: Node = packed.instantiate()
	add_child(screen)
	await get_tree().process_frame

	# (a) 自动合成：两枚一星 god_priest（0 层、2 层），旁边一枚一阶 1 层、一枚二阶。
	#     留下来的是待命区第一格那枚（0 层）—— 继承判据只有它是低的那枚时才测得出来。
	_clear_slots()
	GameState.tiger_starup_count = 2
	GameState.bench_slots[0] = _cell(TIER1_A, "pb")
	GameState.bench_slots[1] = _cell(TIER1_A, "pa", 1, {UnitGrowth.TIGER_STACKS: 2})
	var neighbour := _cell(TIER1_B, "pc", 1, {UnitGrowth.TIGER_STACKS: 1})
	var tier2 := _cell(TIER2, "pd")
	GameState.board_slots[0] = neighbour
	GameState.board_slots[1] = tier2
	screen.call("_auto_combine_all")
	var merged := _find_uid(["pa", "pb"])
	if _h.expect(not merged.is_empty() and int(merged.get("star", 1)) == 2, "auto_merge_happened",
			"两枚一星 %s 没合成二星" % TIER1_A):
		_h.expect(UnitGrowth.tiger_stacks(merged) == 3, "merge_inherits_max_plus_one",
			"合成出来的应继承最高的 2 层再 +1 = 3 层，实际 %d" % UnitGrowth.tiger_stacks(merged))
	_h.expect(UnitGrowth.tiger_stacks(neighbour) == 2, "merge_bumps_neighbours",
		"合成也是一次升星：手上其他一阶棋子 +1（应 2 层），实际 %d" % UnitGrowth.tiger_stacks(neighbour))
	_h.expect(int(tier2.get(UnitGrowth.TIGER_STACKS, 0)) == 0, "merge_tier2_skipped", "二阶棋子不该因合成得到老虎层数")
	_h.expect(GameState.tiger_starup_count == 3, "merge_counts_starup",
		"合成后升星次数应为 3，实际 %d" % GameState.tiger_starup_count)

	# (b) 手动合成（拖到同名棋子上）：目标 0 层、拖来的 4 层 → 继承 4 再 +1。
	_clear_slots()
	var target := _cell(TIER1_C, "ta")
	var incoming := _cell(TIER1_C, "tb", 1, {UnitGrowth.TIGER_STACKS: 4})
	GameState.board_slots[0] = target
	var ok := bool(screen.call("_merge_copies_into_cell", target, incoming))
	if _h.expect(ok, "manual_merge_happened", "手动合成没成功"):
		_h.expect(UnitGrowth.tiger_stacks(target) == 5, "manual_merge_inherits",
			"手动合成应继承拖来的 4 层再 +1 = 5，实际 %d" % UnitGrowth.tiger_stacks(target))

	# (c) 人王合成：留下来的那一枚带走成长最多的那一份（层数 + 倍率），否则长满再合能从 0 层重来。
	_clear_slots()
	GameState.bench_slots[0] = _cell(KING, "kfresh")
	GameState.bench_slots[1] = _cell(KING, "kgrown", 1, {UnitGrowth.KING_STACKS: 3, UnitGrowth.KING_MULT: 1.728})
	screen.call("_auto_combine_all")
	var king := _find_uid(["kfresh", "kgrown"])
	if _h.expect(not king.is_empty() and int(king.get("star", 1)) == 2, "king_merge_happened", "两枚一星人王没合成"):
		_h.expect(UnitGrowth.king_stacks(king) == 3 and is_equal_approx(UnitGrowth.king_mult(king), 1.728),
			"king_merge_keeps_growth", "合成后人王应带走 3 层 / ×1.728，实际 %d 层 / ×%.3f"
				% [UnitGrowth.king_stacks(king), UnitGrowth.king_mult(king)])

	# (d) 联机客机的自动合成要报给服务器账本（10-07 真机：买进空格 → 自动合成成二星，
	#     服务器一次都没看见，升星次数停在 0，老虎层数被截成 0、实战没加成）。
	#     截下真的发出去的合成意图，再交给真的账本，看服务器的升星次数会不会 +1。
	_clear_slots()
	GameState.board_slots[0] = _cell(TIER1_A, "x1")
	GameState.bench_slots[0] = _cell(TIER1_A, "x2")
	var pending_before: Array = NetworkService._tx_pending.keys()
	NetworkService.team_active = true
	NetworkService.is_host = false
	screen.call("_auto_combine_all")
	NetworkService.team_active = false
	var merges: Array = []
	for rid in NetworkService._tx_pending.keys():
		if pending_before.has(rid):
			continue
		var tx: Dictionary = NetworkService._tx_pending[rid]
		var args: Array = tx.get("args", [])
		if str(tx.get("kind", "")) == "economy" and args.size() == 2 and str(args[0]) == "merge":
			merges.append(args[1])
		NetworkService._tx_pending.erase(rid)
	if _h.expect(merges.size() == 1, "auto_merge_reported",
			"联机时自动合成应向服务器账本发 1 条合成意图，实际 %d 条" % merges.size()):
		var payload: Dictionary = merges[0]
		var uids: Array = (payload.get("uids", []) as Array).duplicate()
		uids.sort()
		_h.expect(uids == ["x1", "x2"] and str(payload.get("keeper_uid", "")) == "x1", "auto_merge_payload",
			"合成意图应是 x1 + x2、留下棋盘上那枚 x1，实际 %s / %s" % [str(uids), str(payload.get("keeper_uid", ""))])
		var prep := EconomyLedger.new_prep(100)
		prep["roster"] = {
			"x1": {"unit_id": TIER1_A, "star": 1, "cost_basis": 20, "kind": "unit"},
			"x2": {"unit_id": TIER1_A, "star": 1, "cost_basis": 20, "kind": "unit"},
		}
		var receipt := EconomyLedger.apply(prep, "merge", payload, {"tiger_growth_rate": PetService.tier1_growth_rate(TIGER)})
		_h.expect(bool(receipt.get("ok", false)) and int(prep.get("tiger_starup_count", 0)) == 1, "auto_merge_counts_on_server",
			"服务器账本按这条意图合成后升星次数应为 1（%s，次数 %d）"
				% [str(receipt.get("error", "ok")), int(prep.get("tiger_starup_count", 0))])
	screen.queue_free()
	await get_tree().process_frame


# --- 3. 人王：封顶、四星不追溯 ------------------------------------------------------

func _case_king_growth_rules() -> void:
	var k := _cell(KING, "k", 3)
	for _i in 6:
		UnitGrowth.grow_king(k)
	_h.expect(UnitGrowth.king_stacks(k) == 5 and is_equal_approx(UnitGrowth.king_mult(k), pow(1.2, 5)),
		"king_cap_three_star", "三星人王应在 5 层封顶、×1.2^5，实际 %d 层 / ×%.4f"
			% [UnitGrowth.king_stacks(k), UnitGrowth.king_mult(k)])
	k["star"] = 4
	for _i in 4:
		UnitGrowth.grow_king(k)
	var expected := pow(1.2, 5) * pow(1.3, 3)
	_h.expect(UnitGrowth.king_stacks(k) == 8 and is_equal_approx(UnitGrowth.king_mult(k), expected),
		"king_four_star_not_retroactive", "升四星后再长 3 层（共 8 层），倍率应为 1.2^5×1.3^3=%.4f（之前的不追溯），实际 %d 层 / ×%.4f"
			% [expected, UnitGrowth.king_stacks(k), UnitGrowth.king_mult(k)])
	var piece := _cell(TIER1_A, "p")
	_h.expect(not UnitGrowth.grow_king(piece) and not piece.has(UnitGrowth.KING_STACKS),
		"king_only_king", "不是人王的棋子不该长")
	# 老存档：成长已经乘在 def 上、没有 king_mult —— 按 1 算，不重复乘。
	var legacy := _cell(KING, "old", 3, {UnitGrowth.KING_STACKS: 2})
	_h.expect(is_equal_approx(UnitGrowth.king_mult(legacy), 1.0), "king_legacy_not_doubled",
		"老存档的人王没有 king_mult，倍率应按 1")


# --- 4. 战斗：建 fighter 时乘上去 --------------------------------------------------

func _case_fighter_applies_growth() -> void:
	var rate := PetService.tier1_growth_rate(TIGER)
	_h.expect(is_equal_approx(rate, 0.05), "tiger_rate", "老虎成长率应为 5%%，数据表里是 %.2f" % rate)
	var base := BattleSimShared._fighter_from_cell(_cell(TIER1_A, "x", 2), 0, "player", false, rate)
	var grown := BattleSimShared._fighter_from_cell(_cell(TIER1_A, "x", 2, {UnitGrowth.TIGER_STACKS: 4}), 0, "player", false, rate)
	_h.expect(int(grown.max_hp) == int(round(float(base.max_hp) * 1.2))
			and int(grown.atk) == int(round(float(base.atk) * 1.2))
			and int(grown.defense) == int(round(float(base.defense) * 1.2)),
		"fighter_tiger", "4 层老虎应让生命 / 攻击 / 防御 ×1.2：%d/%d/%d → %d/%d/%d"
			% [base.max_hp, base.atk, base.defense, grown.max_hp, grown.atk, grown.defense])
	_h.expect(is_equal_approx(float(grown.attack_speed), float(base.attack_speed)), "fighter_tiger_no_aspd",
		"攻速不该跟着涨（四星规格 §1）")
	_h.expect(str(grown.get("piece_uid", "")) == "x" and str(grown.get("piece_team", "")) == "player",
		"fighter_piece_identity", "fighter 要带棋子 uid 与出场阵营（战后认人王死活用）")
	var cat := BattleSimShared._fighter_from_cell(_cell(TIER1_A, "x", 2, {UnitGrowth.TIGER_STACKS: 4}), 0, "player", false,
		PetService.tier1_growth_rate("pet_cat"))
	_h.expect(int(cat.max_hp) == int(base.max_hp), "fighter_owner_not_tiger",
		"主人的宠物不是老虎时，层数不该起作用")
	var k0 := BattleSimShared._fighter_from_cell(_cell(KING, "k", 3), 0, "player")
	var k2 := BattleSimShared._fighter_from_cell(_cell(KING, "k", 3, {UnitGrowth.KING_STACKS: 2, UnitGrowth.KING_MULT: 1.44}), 0, "player")
	_h.expect(int(k2.max_hp) == int(round(float(k0.max_hp) * 1.44)) and int(k2.atk) == int(round(float(k0.atk) * 1.44))
			and int(k2.defense) == int(round(float(k0.defense) * 1.44)),
		"fighter_king", "人王 ×1.44：%d/%d/%d → %d/%d/%d"
			% [k0.max_hp, k0.atk, k0.defense, k2.max_hp, k2.atk, k2.defense])


# --- 5. 摆放界面看到的 = 实战乘上去的 ------------------------------------------------

func _case_display_matches_battle() -> void:
	PlayerProfile.active_pet = TIGER
	GameState.tiger_starup_count = 3
	var cell := _cell(TIER1_A, "v", 2, {UnitGrowth.TIGER_STACKS: 3})
	var shown := UnitDetailFormat.grown_def(cell.def, 2, cell)
	var fighter := BattleSimShared._fighter_from_cell(cell, 0, "player", false, PetService.tier1_growth_rate(TIGER))
	var fd: Dictionary = fighter.def
	_h.expect(int(shown.hp) == int(fd.hp) and int(shown.atk) == int(fd.atk) and int(shown.def) == int(fd.def),
		"display_matches_battle_tiger", "详情 %d/%d/%d ≠ 实战 %d/%d/%d"
			% [shown.hp, shown.atk, shown.def, fd.hp, fd.atk, fd.def])
	var text := UnitDetailFormat.format_unit_def(cell.def, 2, cell)
	_h.expect(text.contains(str(int(shown.hp))) and text.contains("+15%"), "display_tiger_line",
		"详情里要直接显示加成后的生命 %d 和老虎 +15%%" % int(shown.hp))
	var plain := UnitFactory.apply_star_stats(cell.def, 2)
	_h.expect(int(shown.hp) > int(plain.hp), "display_shows_grown", "详情的生命应高于没成长的 %d" % int(plain.hp))
	# 层数按升星次数截（联机时次数跟服务器账本走）：截到 2 层就只显示 +10%。
	GameState.tiger_starup_count = 2
	var capped := UnitDetailFormat.grown_def(cell.def, 2, cell)
	_h.expect(int(capped.hp) == int(round(float(plain.hp) * 1.10)), "display_capped_by_count",
		"升星次数只有 2 时应只显示 2 层（生命 %d），实际 %d" % [int(round(float(plain.hp) * 1.10)), int(capped.hp)])
	var king := _cell(KING, "kk", 3, {UnitGrowth.KING_STACKS: 2, UnitGrowth.KING_MULT: 1.44})
	var kshown := UnitDetailFormat.grown_def(king.def, 3, king)
	var kf := BattleSimShared._fighter_from_cell(king, 0, "player")
	_h.expect(int(kshown.hp) == int((kf.def as Dictionary).hp), "display_matches_battle_king",
		"人王详情生命 %d ≠ 实战 %d" % [int(kshown.hp), int((kf.def as Dictionary).hp)])
	_h.expect(UnitDetailFormat.format_unit_def(king.def, 3, king).contains("2/5"), "display_king_line",
		"人王详情里要写当前层数 2/5")


# --- 6. 提交 + 结构上限 + 战斗读棋盘那条路 -------------------------------------------

func _case_wire_and_structural_clamps() -> void:
	var board := [
		_cell(KING, "K", 3, {UnitGrowth.KING_STACKS: 2, UnitGrowth.KING_MULT: 1.44}),
		_cell(TIER1_A, "T", 1, {UnitGrowth.TIGER_STACKS: 3}),
		_cell(TIER2, "U", 1, {UnitGrowth.TIGER_STACKS: 3}),
	]
	var wire := NetProtocol._minimal_slots(board, false)
	_h.expect(int((wire[0] as Dictionary).get(UnitGrowth.KING_STACKS, 0)) == 2
			and is_equal_approx(float((wire[0] as Dictionary).get(UnitGrowth.KING_MULT, 0.0)), 1.44),
		"wire_king", "提交的棋盘里人王要带层数和倍率")
	_h.expect(int((wire[1] as Dictionary).get(UnitGrowth.TIGER_STACKS, 0)) == 3, "wire_tiger", "提交的棋盘里一阶棋子要带老虎层数")
	_h.expect(not (wire[2] as Dictionary).has(UnitGrowth.TIGER_STACKS), "wire_tier2_clean", "二阶棋子不该提交老虎层数")
	# 伪造：人王 9 层 ×50、一阶 10 万层、二阶 7 层。第 3 回合交（只打完 2 场）。
	var forged: Array = wire.duplicate(true)
	forged[0][UnitGrowth.KING_STACKS] = 9
	forged[0][UnitGrowth.KING_MULT] = 50.0
	forged[1][UnitGrowth.TIGER_STACKS] = 100000
	forged[2][UnitGrowth.TIGER_STACKS] = 7
	var v := NetProtocol.validate_team_snapshot(_submission(forged, 3), 3)
	if not _h.expect(bool(v.get("ok", false)), "submit_ok", "合法结构的提交被拒：%s" % str(v.get("reason", ""))):
		return
	var clean: Array = (v.snapshot as Dictionary).board
	_h.expect(int((clean[0] as Dictionary).get(UnitGrowth.KING_STACKS, 0)) == 2, "clamp_king_by_rounds",
		"第 3 回合交的人王最多 2 层（只打完 2 场），实际 %d" % int((clean[0] as Dictionary).get(UnitGrowth.KING_STACKS, 0)))
	_h.expect(float((clean[0] as Dictionary).get(UnitGrowth.KING_MULT, 99.0)) <= pow(1.2, 2) + 0.0001, "clamp_king_mult",
		"2 层三星人王倍率最多 1.2^2，实际 %.3f" % float((clean[0] as Dictionary).get(UnitGrowth.KING_MULT, 99.0)))
	_h.expect(int((clean[1] as Dictionary).get(UnitGrowth.TIGER_STACKS, 0)) == UnitGrowth.MAX_TIGER_STACKS, "clamp_tiger_structural",
		"老虎层数结构上限 %d，实际 %d" % [UnitGrowth.MAX_TIGER_STACKS, int((clean[1] as Dictionary).get(UnitGrowth.TIGER_STACKS, 0))])
	_h.expect(not (clean[2] as Dictionary).has(UnitGrowth.TIGER_STACKS), "clamp_tier2_stripped", "二阶棋子的老虎层数要被丢掉")
	# 战斗读棋盘走 extract_board → sanitize_cell：成长必须还在（以前人王的成长就丢在这一步）。
	var read := NetProtocol.extract_board(v.snapshot)
	_h.expect(int((read[0] as Dictionary).get(UnitGrowth.KING_STACKS, 0)) == 2
			and int((read[1] as Dictionary).get(UnitGrowth.TIGER_STACKS, 0)) == UnitGrowth.MAX_TIGER_STACKS,
		"sim_read_keeps_growth", "战斗读棋盘（extract_board）把成长丢了")
	# 坏数：NaN 倍率按 1、字符串层数按 0、佣兵不带。
	var bad: Array = wire.duplicate(true)
	bad[0][UnitGrowth.KING_MULT] = NAN
	bad[1][UnitGrowth.TIGER_STACKS] = "lots"
	var vb := NetProtocol.validate_team_snapshot(_submission(bad, 3), 3)
	if _h.expect(bool(vb.get("ok", false)), "submit_bad_ok", "带坏数的提交应被清洗而不是整份拒收"):
		var cb: Array = (vb.snapshot as Dictionary).board
		_h.expect(is_equal_approx(float((cb[0] as Dictionary).get(UnitGrowth.KING_MULT, 0.0)), 1.0), "clamp_nan_mult",
			"NaN 倍率应按 1")
		_h.expect(not (cb[1] as Dictionary).has(UnitGrowth.TIGER_STACKS), "clamp_string_tiger", "字符串层数应按 0")
	var merc_wire := NetProtocol._minimal_slots([{"id": "x", "uid": "m", "star": 1, UnitGrowth.TIGER_STACKS: 5,
		"def": {"tier": 1, "is_mercenary": true}, "is_mercenary": true}], true)
	_h.expect(not (merc_wire[0] as Dictionary).has(UnitGrowth.TIGER_STACKS), "wire_merc_clean", "佣兵不该提交老虎层数")
	var old := _submission(wire, 3)
	old["version"] = 4
	_h.expect(str(NetProtocol.validate_team_snapshot(old, 3).get("reason", "")) == "snapshot_version_mismatch",
		"old_snapshot_rejected", "旧版本（v4）棋盘快照必须被拒，不能按新语义读")


# --- 7. 服务器账本上限 ---------------------------------------------------------------

func _case_server_ledger_clamp() -> void:
	var prep := EconomyLedger.new_prep(100)
	prep["tiger_starup_count"] = 2
	var room := {"prep": {0: prep}}
	var cell := _cell(TIER1_A, "T", 1, {UnitGrowth.TIGER_STACKS: 100})
	var snap := {"board": [cell, null]}
	NetworkService._room_clamp_growth(room, 0, snap)
	_h.expect(UnitGrowth.tiger_stacks(cell) == 2, "ledger_clamp",
		"服务器账本只数到 2 次升星，老虎层数应截到 2，实际 %d" % UnitGrowth.tiger_stacks(cell))
	prep["tiger_starup_count"] = 0
	NetworkService._room_clamp_growth(room, 0, snap)
	_h.expect(not cell.has(UnitGrowth.TIGER_STACKS), "ledger_clamp_zero", "账本 0 次升星（比如出战宠物不是老虎）时层数应清掉")
	# 收棋盘与读缓存两条路都要截（源码层：这两处是 RPC / 跨回合缓存，门禁里拉不起真连接）。
	var src := FileAccess.get_file_as_string("res://scripts/autoload/NetworkService.gd")
	var submit := _fn_body(src, "func _rpc_team_submit_board(")
	var clamp_at := submit.find("_room_clamp_growth(room, slot, accepted_snapshot)")
	var store_at := submit.find("boards[slot] = accepted_snapshot")
	_h.expect(clamp_at >= 0 and store_at > clamp_at, "submit_calls_clamp", "收棋盘时没在存进 boards 之前截老虎层数")
	_h.expect(_fn_body(src, "func _restamp_cached_board(").contains("_room_clamp_growth("), "restamp_calls_clamp",
		"掉线代打复用缓存棋盘时也要截老虎层数")


# --- 8. 升星次数跟服务器账本走 -------------------------------------------------------

func _case_carrot_state_follows_server_count() -> void:
	GameState.reset_run()
	PlayerProfile.active_pet = TIGER
	var upgraded := _cell(TIER1_A, "R1", 3, {UnitGrowth.TIGER_STACKS: 1})
	var other := _cell(TIER1_B, "T2", 1, {UnitGrowth.TIGER_STACKS: 1})
	GameState.board_slots[0] = upgraded
	GameState.bench_slots[0] = other
	GameState.tiger_starup_count = 1
	var stones: Dictionary = GameState.team_upgrade_stones.duplicate(true)
	# 升四星的回执丢了、靠 room_state 里的 four_star_grants 补上：这也是一次升星。
	NetworkService._apply_carrot_state({"carrot_authoritative": true,
		"last_harvest_round": GameState.last_harvest_round, "tiger_starup_count": 2,
		"team_upgrade_stones": stones, "four_star_grants": {"R1": {"unit_id": TIER1_A, "cost": 0}}})
	_h.expect(int(upgraded.get("star", 1)) == GameState.MAX_UNIT_STAR, "recovered_four_star", "补回的升四星没落到棋子上")
	_h.expect(UnitGrowth.tiger_stacks(upgraded) == 2 and UnitGrowth.tiger_stacks(other) == 2, "recovered_starup_stacks",
		"补回的升四星也要给手上一阶棋子 +1 层，实际 %d / %d" % [UnitGrowth.tiger_stacks(upgraded), UnitGrowth.tiger_stacks(other)])
	_h.expect(GameState.tiger_starup_count == 2, "count_after_recovery", "次数应落成服务器的 2，实际 %d" % GameState.tiger_starup_count)
	# 影子账本拒过一次合成，服务器只数到 1：本地跟着落成 1，详情也只显示 1 层。
	NetworkService._apply_carrot_state({"carrot_authoritative": true,
		"last_harvest_round": GameState.last_harvest_round, "tiger_starup_count": 1, "team_upgrade_stones": stones})
	_h.expect(GameState.tiger_starup_count == 1, "count_follows_server", "升星次数要跟服务器账本走（影子期也一样）")
	var plain := UnitFactory.apply_star_stats(other.def, 1)
	_h.expect(int(UnitDetailFormat.grown_def(other.def, 1, other).hp) == int(round(float(plain.hp) * 1.05)),
		"display_follows_server_count", "服务器只认 1 次升星时，详情应只显示 1 层")


# --- 9. 人王死活：按棋子认，寄生复制品不算 -------------------------------------------

func _case_king_outcomes_by_piece() -> void:
	var dead := {"def": {"skill_id": UnitGrowth.KING_SKILL}, "piece_uid": "K", "piece_team": "player",
		"team": "player", "owner_slot": 0, "alive": false, "hp": 0}
	var phoenix := dead.duplicate(true)
	phoenix["alive"] = true
	phoenix["hp"] = 10
	var parasite := dead.duplicate(true)
	parasite["team"] = "enemy"
	parasite["alive"] = true
	parasite["hp"] = 5
	var other_seat := dead.duplicate(true)
	other_seat["owner_slot"] = 3
	other_seat["alive"] = true
	other_seat["hp"] = 9
	var by_parasite := BattleSimShared._king_outcomes([dead, parasite])
	_h.expect(by_parasite.size() == 1 and not bool((by_parasite[0] as Dictionary).alive), "outcome_parasite_not_alive",
		"人王阵亡、只剩被寄生复制到对面的那份活着 —— 应算阵亡")
	var by_phoenix := BattleSimShared._king_outcomes([dead, phoenix])
	_h.expect(by_phoenix.size() == 1 and bool((by_phoenix[0] as Dictionary).alive), "outcome_phoenix_alive",
		"凤凰复活体（同阵营）活着 —— 应算活下来")
	var two := BattleSimShared._king_outcomes([dead, other_seat])
	var alive_by_slot := {}
	for entry in two:
		alive_by_slot[int((entry as Dictionary).owner_slot)] = bool((entry as Dictionary).alive)
	_h.expect(two.size() == 2 and alive_by_slot.get(0, true) == false and alive_by_slot.get(3, false) == true,
		"outcome_per_seat", "两个座位的人王各算各的")


# --- 10. Main：活的长一层、死的移出棋盘、只认自己座位 ---------------------------------

func _case_main_applies_outcomes() -> void:
	var main = MainScript.new()
	GameState.reset_run()
	NetworkService.team_active = true
	NetworkService.team_local_slot = 1
	var mine := _cell(KING, "K", 3)
	GameState.board_slots[2] = mine
	# 别的座位那条故意排在后面：不按座位过滤的话，后面那条会盖掉自己的。
	main._apply_post_battle_unit_outcomes({"king_outcomes": [
		{"owner_slot": 1, "uid": "K", "alive": true}, {"owner_slot": 0, "uid": "K", "alive": false}]})
	_h.expect(GameState.board_slots[2] != null and UnitGrowth.king_stacks(mine) == 1
			and is_equal_approx(UnitGrowth.king_mult(mine), 1.2),
		"main_grows_own_king", "自己的人王活下来应长一层（×1.2），别的座位同 uid 的结局不算")
	main._apply_post_battle_unit_outcomes({"king_outcomes": [
		{"owner_slot": 1, "uid": "K", "alive": false}, {"owner_slot": 0, "uid": "K", "alive": true}]})
	_h.expect(GameState.board_slots[2] == null, "main_removes_dead_king", "自己的人王阵亡应移出棋盘")
	var benched := _cell(KING, "K2", 3)
	GameState.board_slots[2] = benched
	main._apply_post_battle_unit_outcomes({"king_outcomes": [{"owner_slot": 1, "uid": "K", "alive": true}]})
	_h.expect(GameState.board_slots[2] != null and UnitGrowth.king_stacks(benched) == 0, "main_ignores_absent",
		"这一场没出场的人王不该长也不该删")
	main._apply_post_battle_unit_outcomes({"player_wins": true})
	_h.expect(GameState.board_slots[2] != null, "main_ignores_forced", "没有 king_outcomes 的结果（强制结束）不该动人王")
	main.free()


# --- 11. 端到端：服务器那条路（提交 → 校验 → 读棋盘 → 开打 → 结果） --------------------

func _case_team_battle_end_to_end(round_index: int) -> void:
	var kind := RoundService.schedule_kind_for_round(round_index)
	GameState.reset_run()
	GameState.team_mode = true
	GameState.round_index = round_index
	GameState.team_hp = GameState.START_FORMATION_HP
	GameState.enemy_team_hp = GameState.START_FORMATION_HP
	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = 424242 + round_index
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	var boards: Dictionary = {}
	for slot in 6:
		var rng := RandomNumberGenerator.new()
		rng.seed = 7700 + round_index * 10 + slot
		boards[slot] = {"version": NetProtocol.SNAPSHOT_VERSION, "round": round_index,
			"board": BattleSimShared.build_dummy_board(rng), "mercenaries": [], "treasures": [], "syn": {}, "pet": ""}
	# 座位 0（红）和座位 3（蓝）各摆一个长过的人王；座位 0 再摆一枚 2 层老虎的一阶棋子。
	for seat in [0, 3]:
		var mine: Array = [
			_cell(KING, "K%d" % seat, 3, {UnitGrowth.KING_STACKS: 2, UnitGrowth.KING_MULT: 1.44}),
			_cell(TIER1_A, "T%d" % seat, 1, {UnitGrowth.TIGER_STACKS: 2}),
		]
		var v := NetProtocol.validate_team_snapshot(_submission(NetProtocol._minimal_slots(mine, false), round_index), round_index)
		if not _h.expect(bool(v.get("ok", false)), "e2e_submit_%s" % kind, "端到端提交被拒：%s" % str(v.get("reason", ""))):
			return
		var accepted: Dictionary = v.snapshot
		accepted["pet"] = TIGER
		var prep := EconomyLedger.new_prep(100)
		prep["tiger_starup_count"] = 2
		NetworkService._room_clamp_growth({"prep": {seat: prep}}, seat, accepted)
		boards[seat] = accepted
	NetworkService.team_boards = boards
	var state := BattleSimulator.prepare_team_state(0)
	var king_fighter := _fighter_by_piece(state, "K0")
	var tiger_fighter := _fighter_by_piece(state, "T0")
	var king_plain := UnitFactory.apply_star_stats(_def(KING), 3)
	var tier1_plain := UnitFactory.apply_star_stats(_def(TIER1_A), 1)
	if _h.expect(not king_fighter.is_empty(), "e2e_king_fighter_%s" % kind, "%s：没找到座位 0 的人王 fighter" % kind):
		_h.expect(int((king_fighter.def as Dictionary).hp) == int(round(float(king_plain.hp) * 1.44)),
			"e2e_king_grown_%s" % kind, "%s：开打时人王生命应为 %d（×1.44），实际 %d"
				% [kind, int(round(float(king_plain.hp) * 1.44)), int((king_fighter.def as Dictionary).hp)])
	if _h.expect(not tiger_fighter.is_empty(), "e2e_tiger_fighter_%s" % kind, "%s：没找到座位 0 的一阶 fighter" % kind):
		_h.expect(int((tiger_fighter.def as Dictionary).hp) == int(round(float(tier1_plain.hp) * 1.10)),
			"e2e_tiger_grown_%s" % kind, "%s：开打时 2 层老虎的一阶棋子生命应为 %d，实际 %d"
				% [kind, int(round(float(tier1_plain.hp) * 1.10)), int((tiger_fighter.def as Dictionary).hp)])
	var steps := 0
	while not bool(state.get("finished", false)) and steps < 4000:
		BattleSimulator.step_state(state)
		steps += 1
	var result := BattleSimulator.result_from_state(state)
	var seats := {}
	for entry in result.get("king_outcomes", []):
		seats[int((entry as Dictionary).get("owner_slot", -1))] = str((entry as Dictionary).get("uid", ""))
	_h.expect(seats.get(0, "") == "K0", "e2e_outcome_mine_%s" % kind,
		"%s：战斗结果里没有座位 0 的人王结局（%s）" % [kind, str(result.get("king_outcomes", []))])
	if kind == "pvp":
		_h.expect(seats.get(3, "") == "K3", "e2e_outcome_rival_pvp",
			"PvP：同一份结果里也要有蓝队人王的结局（不用再换边）")
	_h.expect(not result.has("player_survivor_slots"), "e2e_no_slot_survivors_%s" % kind,
		"旧的格子号存活表还在结果里")


# --- 夹具 ---------------------------------------------------------------------

func _save_globals() -> void:
	_saved = {
		"pet": PlayerProfile.active_pet,
		"team_active": bool(NetworkService.team_active),
		"is_host": bool(NetworkService.is_host),
		"local_slot": int(NetworkService.team_local_slot),
		"team_boards": NetworkService.team_boards.duplicate(true),
		"slot_states": (NetworkService.team_slot_states as Array).duplicate(),
		"seed": NetworkService.shared_seed,
		"cost_version": NetworkService.server_four_star_cost_version,
	}


func _restore_globals() -> void:
	PlayerProfile.active_pet = str(_saved.pet)
	NetworkService.team_active = bool(_saved.team_active)
	NetworkService.is_host = bool(_saved.is_host)
	NetworkService.team_local_slot = int(_saved.local_slot)
	NetworkService.team_boards = _saved.team_boards
	NetworkService.team_slot_states = _saved.slot_states
	NetworkService.shared_seed = _saved.seed
	NetworkService.server_four_star_cost_version = _saved.cost_version
	GameState.team_mode = false
	GameState.reset_run()


func _def(id: String) -> Dictionary:
	for row in DataRegistry.get_table("race_units").get("units", []):
		if typeof(row) == TYPE_DICTIONARY and str((row as Dictionary).get("id", "")) == id:
			return (row as Dictionary).duplicate(true)
	_h.fail("fixture_unit_missing", "数据表里没有 %s" % id)
	return {}


func _cell(id: String, uid: String, star: int = 1, extra: Dictionary = {}) -> Dictionary:
	var c := {"id": id, "uid": uid, "star": star, "def": _def(id)}
	c.merge(extra, true)
	return c


func _clear_slots() -> void:
	for i in GameState.board_slots.size():
		GameState.board_slots[i] = null
	for i in GameState.bench_slots.size():
		GameState.bench_slots[i] = null


func _find_uid(uids: Array) -> Dictionary:
	for slots in [GameState.board_slots, GameState.bench_slots]:
		for cell in slots:
			if typeof(cell) == TYPE_DICTIONARY and uids.has(str((cell as Dictionary).get("uid", ""))):
				return cell
	return {}


func _fighter_by_piece(state: Dictionary, uid: String) -> Dictionary:
	for f in (state.get("player", []) as Array) + (state.get("enemy", []) as Array):
		if typeof(f) == TYPE_DICTIONARY and str((f as Dictionary).get("piece_uid", "")) == uid \
				and int((f as Dictionary).get("owner_slot", -1)) >= 0:
			return f
	return {}


func _submission(board_entries: Array, round_index: int) -> Dictionary:
	return {"version": NetProtocol.SNAPSHOT_VERSION, "protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"round": round_index, "gold": 10, "board": board_entries, "mercenaries": [], "treasures": []}


# 取一个函数的函数体（统一成 LF 再找，行尾不一致不能让断言静默判假）。
func _fn_body(source: String, signature: String) -> String:
	var normalized := source.replace("\r\n", "\n")
	var at := normalized.find(signature)
	if at < 0:
		return ""
	var rest := normalized.substr(at + signature.length())
	var nxt := rest.find("\nfunc ")
	return rest if nxt < 0 else rest.substr(0, nxt)
