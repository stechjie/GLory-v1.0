extends Node

# 9.24 探针 —— 锁死用户后两次回执里的四条：
#
#   ① 神王（god_king / skill_id = global_divine_blast）技能特效无显示；
#      要求「和裁决者用同一落雷特效，区别只在于神王的目标是多个敌人，
#      在所有技能目标身上都触发落雷」。
#   ② 末日守卫（dark_doom / skill_id = shared_hp_link）把被连接目标**永久**变成我方棋子，
#      这个变化**不随守卫死亡而停止**；而"我方棋子应该以绿色血条表示"。
#   ③ （第四轮）神王落雷**劈到了非技能目标**：「非技能目标也出现了落雷」。
#      根因不是模块选错，而是目标集合由表现层自己猜，两个猜法与模拟器实际选中都不一致。
#
# 为什么必须写这个探针 —— 同一类错已经连犯四次：
#   * ② 「对换」写在**死表**上（玩家棋子走 OGA 路由，早返回）→ 编译绿、门禁绿、肉眼看不出；
#   * ⑩ 「金属箭」同一个死表；
#   * ⑨（法师首技能）根因也不是最初推测的那条；
#   * ③ 模块接对了，但**目标集合**是猜的 —— 编译绿、门禁绿、用户一眼看出雷劈错人。
# 四次的共同点：**改动落在了一条走不到的路上 / 判据落在了一个猜出来的值上，
# 而没有任何门禁会红。**
# 所以这里针对每条各写可证伪读数。
#
# 探针设计原则（沿用 probe_parasite_bind_920 的教训）：
#   * 直接调**生产实现**，不自己复刻一份；复刻会随生产漂移。
#   * 重型 3D 场景不 instantiate（headless 会挂死）：只 `.new()` + 按需 add_child。
#   * 行为读数优先，源码文本断言只用于补"接线有没有被删掉 / 被注释掉"。
#   * 需要自证的判据要**独立**算期望值（如 Part 5 用 lane 自己数，不借 `_can_target`）。

const COMPOSER := preload("res://effects/vfx3d/units/UnitSkillVFXComposer3D.gd")
const SCREEN := preload("res://scenes/battle/BattleScreen.gd")
const VFX := preload("res://scenes/battle/BattleVfx.gd")
const SIM := preload("res://officetest/OfficeTestSim.gd")

const DOOM := "dark_doom"
const KING := "god_king"
const MIL := "human_militia"

var _fail := 0
var _checks := 0
var _saved_team_mode := false


func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	_saved_team_mode = GameState.team_mode
	GameState.team_mode = true

	print("=== Part 1: 落雷（神王全员 / 裁决者单体）—— 直接跑 composer ===")
	await _part_thunder()

	print("\n=== Part 2: 血之契约策反 —— 真实 state 逐步推进 ===")
	await _part_convert_live()

	print("\n=== Part 3: 策反跨回放边界 —— 真实 replay ===")
	await _part_convert_replay()

	print("\n=== Part 4: 写回行为（直接跑生产实现 apply_latched_team）===")
	_part_writeback_behavior()

	print("\n=== Part 5: 神王目标集合 —— 跑生产实现 _skill_god_king ===")
	await _part_god_king_record()

	print("\n=== Part 6: 目标解析（直接跑生产实现 resolve_skill_target_positions）===")
	_part_target_resolution()

	print("\n=== Part 7: 接线文本断言（只证「写了」，不证「对」）===")
	_part_wiring()

	GameState.team_mode = _saved_team_mode
	if _fail == 0:
		print("\nPROBE_DONE checks=%d fail=0" % _checks)
	else:
		print("\nPROBE_DONE checks=%d fail=%d" % [_checks, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- Part 1: 落雷 -------------------------------------------------------------

func _part_thunder() -> void:
	var composer: Node3D = COMPOSER.new()
	add_child(composer)
	await get_tree().process_frame

	var origin := Vector3(0.0, 0.0, 0.0)
	var t1 := Vector3(1.0, 0.0, 1.0)
	var t2 := Vector3(2.0, 0.0, 2.0)
	var t3 := Vector3(3.0, 0.0, 3.0)

	# 神王：3 个目标 → 每个目标各一道。上限由 VFXQualityBudget 决定，按它算期望值。
	var want_group: int = mini(3, VFXQualityBudget.max_aoe_targets(3))
	var before := composer.get_child_count()
	composer.call("play_skill", "global_divine_blast", origin, t1, {"targets": [t1, t2, t3]})
	var king_arcs := _count_arcs(composer) - _count_arcs_upto(composer, before)
	print("  [diag] 神王 3 目标 -> %d 道雷（期望 %d，画质档上限）" % [king_arcs, want_group])
	_expect(king_arcs, want_group, "神王：3 个技能目标 -> 每个目标各落一道雷（不是只放一次）")
	# ★ 关键：要看**新加的那些**是不是 VFXLightningArc。
	# 不能靠节点名 —— 同级重名会被 Godot 自动改成 @Node3D@N，只有第一个保住原名。
	_expect(_new_arcs_all_lightning(composer, before), true, "神王落雷用的是 VFXLightningArc 模块")

	# 神王：1 个目标 -> 1 道（不能因为"全员技"就固定放好几道）
	var before1 := composer.get_child_count()
	composer.call("play_skill", "global_divine_blast", origin, t1, {"targets": [t1]})
	_expect(_count_arcs(composer) - _count_arcs_upto(composer, before1), 1,
		"神王：只有 1 个技能目标 -> 只落 1 道")

	# 裁决者：单体（即使递 3 个目标也只落 1 道）。
	# ★「同一个落雷特效」这条不靠参数抄一致：两个 skill_id 都接到 `_aoe_thunder`，
	#   所以两者生成的是**同一种模块**。这里按模块类型断言，Part 4 再钉源码接线。
	var before2 := composer.get_child_count()
	composer.call("play_skill", "judgement_strike", origin, t1, {"targets": [t1, t2, t3]})
	_expect(_count_arcs(composer) - _count_arcs_upto(composer, before2), 1,
		"裁决者：即使给 3 个目标也只落 1 道（单体）")
	_expect(_new_arcs_all_lightning(composer, before2), true, "裁决者落雷用的是同一个 VFXLightningArc 模块")

	# 神王/裁决者的技能 id 必须真的是这两个（防止把「人王」又认成神王）
	var king_id := _skill_id_of(KING)
	var arbiter_id := _skill_id_of("god_arbiter")
	_expect(king_id, "global_divine_blast", "神王(god_king) 的技能 id")
	_expect(arbiter_id, "judgement_strike", "裁决者(god_arbiter) 的技能 id")
	_expect(_skill_id_of("human_king"), "unique_king_growth",
		"人王(human_king) 的技能 id —— 上一轮把它误当成神王")

	composer.queue_free()
	await get_tree().process_frame


func _count_arcs(composer: Node3D) -> int:
	var n := 0
	for c in composer.get_children():
		if c.has_method("play_arc"):
			n += 1
	return n


# 只数前 `n` 个子节点里的电弧 —— 用来算「本次调用新增了几道」。
func _count_arcs_upto(composer: Node3D, n: int) -> int:
	var count := 0
	var kids := composer.get_children()
	for i in mini(n, kids.size()):
		if kids[i].has_method("play_arc"):
			count += 1
	return count


# 本次调用新增的节点是否全是 VFXLightningArc（即"用的是同一套落雷模块"）。
func _new_arcs_all_lightning(composer: Node3D, before: int) -> bool:
	var kids := composer.get_children()
	var seen := 0
	for i in range(mini(before, kids.size()), kids.size()):
		seen += 1
		if not kids[i].has_method("play_arc"):
			return false
	return seen > 0


# --- Part 2: 策反（live）------------------------------------------------------

func _part_convert_live() -> void:
	var state: Dictionary = SIM.build_test_state(_cfg())
	var guard := _find_by_id(state, DOOM)
	if not _expect(not guard.is_empty(), true, "[live] 场上有末日守卫"):
		return
	var guard_team := str(guard.get("team", ""))
	var guard_uid := str(guard.get("uid", ""))
	# ★ 契约**不是** build 时就生效的：实测回放第 5 帧才锁上（见 Part 3 读数）。
	#   所以这里必须真的推进 tick，不能假设"开局技已经在 state 里了"。
	var linked := ""
	for i in 400:
		linked = str(_find_by_id(state, DOOM).get("shared_link_uid", ""))
		if not linked.is_empty():
			break
		BattleSimulator.step_state(state)
	print("  [diag] 守卫 team=%s uid=%s 契约目标 uid=%s" % [guard_team, guard_uid, linked])
	if not _expect(not linked.is_empty(), true, "[live] 守卫锁定了契约目标"):
		return

	var conv := _find_uid(state, linked)
	if not _expect(not conv.is_empty(), true, "[live] 目标还在场上"):
		return
	var conv_team := str(conv.get("team", ""))
	var conv_unit := str(conv.get("id", ""))
	print("  [diag] 被策反单位 id=%s team=%s" % [conv_unit, conv_team])

	_expect(conv_team, guard_team, "[live] 目标队伍已被改成与守卫同队")
	_expect(guard_team, "player", "[live] 本例守卫在己方 -> 策反后应为 player")
	_expect(_in_team(state, "player", linked), true, "[live] 目标已进入 player 数组")
	_expect(_in_team(state, "enemy", linked), false, "[live] 目标已从 enemy 数组移除")

	# ★ 核心：守卫死亡**不**回退策反。
	#
	# 这里**直接把守卫打到 0 血**，而不是"等一场战斗自然把它打死"：
	#   * 第一版就是等的 —— 结果一场 6000 tick 的仗打完守卫还活着，于是
	#     "策反不回退"这条**空过**了（守卫根本没死，当然不回退）。假绿比红更危险。
	#   * 要验证的是「守卫死亡」这个**状态**下的行为，不是"某场特定对局会打死它"。
	var g: Dictionary = _find_by_id(state, DOOM)
	g["hp"] = 0
	BattleSimulator.step_state(state)
	for i in 20:
		BattleSimulator.step_state(state)
	var guard_now := _find_by_id(state, DOOM)
	var guard_dead := guard_now.is_empty() or not bool(guard_now.get("alive", false))
	print("  [diag] 强制守卫阵亡后：alive=%s；被策反单位 team=%s"
		% [str(false if guard_now.is_empty() else guard_now.get("alive", false)),
			str(_find_uid(state, linked).get("team", ""))])
	if not _expect(guard_dead, true, "[live] 守卫确实处于阵亡状态（否则下一条会空过）"):
		return
	var after := str(_find_uid(state, linked).get("team", ""))
	_expect(after, guard_team, "[live] ★ 守卫死亡后策反**不回退**（用户口径：这种变化不随死亡停止）")


# --- Part 3: 策反（跨回放边界）------------------------------------------------

func _part_convert_replay() -> void:
	var replay: Dictionary = await SIM.compute_test_replay_async(_cfg())
	var roster: Dictionary = replay.get("roster", {})
	var frames: Array = replay.get("frames", [])
	if not _expect(frames.size() > 0, true, "[replay] 拿到回放帧"):
		return

	var guard_uid := ""
	var guard_team := ""
	for uid in roster:
		var r: Dictionary = roster[uid]
		if str(r.get("id", "")) == DOOM:
			guard_uid = str(uid)
			guard_team = str(r.get("team", ""))
	if not _expect(not guard_uid.is_empty(), true, "[replay] roster 里有末日守卫"):
		return

	# 逐帧跑**生产实现**的锁存函数，找到策反发生的那一帧。
	var by_uid: Dictionary = {}
	for uid in roster:
		var r: Dictionary = roster[uid]
		by_uid[str(uid)] = {"def": r.get("def", {}), "team": str(r.get("team", ""))}
	var converted_uid := ""
	var converted_frame := -1
	var latched_ever: Dictionary = {}
	for i in frames.size():
		var got: Dictionary = SCREEN.latched_conversions_in_frame(frames[i], by_uid)
		for k in got:
			if not latched_ever.has(k):
				converted_uid = str(k)
				converted_frame = i
			latched_ever[k] = got[k]
	if not _expect(converted_frame >= 0, true,
			"[replay] 从回放里还原出策反关系（生产实现 latched_conversions_in_frame）"):
		return
	print("  [diag] 回放第 %d 帧还原出策反：%s -> %s" % [converted_frame, converted_uid, str(latched_ever[converted_uid])])
	_expect(str(latched_ever[converted_uid]), guard_team, "[replay] 策反后队伍 == 守卫队伍")

	# ★ 红：roster 是**首帧快照**，它对被策反单位的说法永远是原队伍。
	#   所以表现层若只看 roster，血条永远上不了"我方"色 —— 这就是用户看到的红条。
	var roster_team := str((roster.get(converted_uid, {}) as Dictionary).get("team", ""))
	print("  [diag] roster 对该单位的说法 team=%s（首帧快照，永不更新）" % roster_team)
	_expect(roster_team != guard_team, true,
		"[replay] ★ roster 与真实归属**不一致** —— 证明「只看 roster 的配色」必然错")

	# ★ 红：frame 里**没有** team 列，所以表现层不可能自己发现队伍变了。
	var sizes := {}
	for entry in frames[frames.size() - 1]:
		if typeof(entry) == TYPE_ARRAY:
			sizes[(entry as Array).size()] = true
	print("  [diag] 末帧 entry 列数集合=%s" % str(sizes.keys()))
	_expect(sizes.size() == 1 and sizes.has(13), true,
		"[replay] ★ frame 仍是 13 列、**没有 team 列** —— 所以策反必须靠锁存，不能靠新增列")


# --- Part 4: 写回行为 ---------------------------------------------------------

# 为什么把这两行抽成纯函数、又在这里**直接调它**：
# 第一版把 `f.team = converted_team` 内联在 `_apply_replay_frame` 里，于是探针只能靠
# **源码文本断言**兜底。文本断言挡不住 `if false and ...` —— 变异测试实测：把条件
# 改成 `if false`，源码里那两行**一个字都没变**，探针照样全绿。假绿。
# 抽成 static 纯函数后，判据能落在**行为**上：给一个 team="enemy" 的 fighter，
# 调用后它必须变成守卫的队伍。这才是"接线真的生效"。
func _part_writeback_behavior() -> void:
	var conversions := {"u_enemy_1": "player"}
	var f := {"uid": "u_enemy_1", "team": "enemy", "hp": 100}

	SCREEN.apply_latched_team(f, "u_enemy_1", conversions)
	_expect(str(f.get("team", "")), "player",
		"写回行为：被策反后 team 由 enemy 变 player（直接调生产实现）")
	# 幂等：同一帧重复调用不该翻转或清空。
	SCREEN.apply_latched_team(f, "u_enemy_1", conversions)
	_expect(str(f.get("team", "")), "player", "写回行为：重复调用幂等")

	# 没被策反的单位**不能**被误改 —— 否则全队血条会一起变色。
	var g := {"uid": "u_other", "team": "enemy", "hp": 100}
	SCREEN.apply_latched_team(g, "u_other", conversions)
	_expect(str(g.get("team", "")), "enemy", "写回行为：未被策反的单位队伍原样不动")

	# 锁存表里没有它时（策反尚未发生）也不能动。
	var h := {"uid": "u_enemy_1", "team": "enemy", "hp": 100}
	SCREEN.apply_latched_team(h, "u_enemy_1", {})
	_expect(str(h.get("team", "")), "enemy", "写回行为：空锁存表 = 不改任何队伍")

	# 防御：uid 传空字符串时，不能把 conversions 里任一条误用上。
	var k := {"uid": "", "team": "enemy", "hp": 100}
	SCREEN.apply_latched_team(k, "", conversions)
	_expect(str(k.get("team", "")), "enemy", "写回行为：空 uid 不会被误写")


# --- Part 5: 神王的目标集合（第四轮：用户报「非技能目标也出现了落雷」）-----------
#
# 为什么必须验到这一层：第三轮我把「神王落雷」接对了单位、也接对了模块，但**目标集合
# 是表现层自己猜的**，猜法有两个来源，两个都和模拟器的实际选中不一致：
#   ① 本帧的伤害事件 —— **帧级**的，混着别的单位打出的伤害（谁掉血谁头上落雷）；
#   ② 取不到就退回「全部存活敌人」—— 无视 `_can_target` 的**路数限制**，多目标技
#      直接变成全屏技。
# 两道雷都劈到了非技能目标上，正是用户截图里看到的现象。
#
# 现在改成：**在判定发生的地方把结果记下来**（`BattleSimSkills._skill_god_king`
# 里的 `_mark_vfx_targets`），表现层照抄。所以这里直接调生产实现的那个函数，
# 再用**独立算出来的路数**去核对它的记录 —— 不借 `_can_target` 自证。
func _part_god_king_record() -> void:
	# slot % TEAM_SIDE_SIZE(3) = lane，所以 slot 3/4/5 分别落在敌方 0/1/2 路。
	# 神王放 slot 0（我方 0 路），敌方三路各放一只 —— 这样「本路有活敌」与
	# 「他路也有活敌」同时成立，跨路回退**不该**被触发。
	var state: Dictionary = SIM.build_test_state({
		"placements": [
			{"slot": 0, "cell": 2, "kind": "piece", "unit_id": KING, "star": 1},
			{"slot": 0, "cell": 1, "kind": "piece", "unit_id": MIL, "star": 1},
			{"slot": 3, "cell": 2, "kind": "piece", "unit_id": MIL, "star": 1},
			{"slot": 4, "cell": 2, "kind": "piece", "unit_id": MIL, "star": 1},
			{"slot": 5, "cell": 2, "kind": "piece", "unit_id": MIL, "star": 1},
		],
		"slot_treasures": {},
	})
	var king := _find_by_id(state, KING)
	if not _expect(not king.is_empty(), true, "[record] 场上有神王(god_king)"):
		return
	var king_lane := int(king.get("lane", -1))
	var enemies: Array = state.get("enemy", [])

	# 独立统计：本路活敌 / 他路活敌（只用 lane 与 alive，不碰 _can_target）
	var same_lane := 0
	var other_lane := 0
	for e in enemies:
		if typeof(e) != TYPE_DICTIONARY or not bool((e as Dictionary).get("alive", false)):
			continue
		if int((e as Dictionary).get("lane", -1)) == king_lane:
			same_lane += 1
		else:
			other_lane += 1
	print("  [diag] 神王 lane=%d；敌方本路活敌=%d，他路活敌=%d" % [king_lane, same_lane, other_lane])
	# 这两条是**判据有意义的前提**，不是结论：前提不成立时下面的断言会变成假绿。
	if not _expect(other_lane > 0, true, "[record] 本例敌方**跨了多路**（前提：否则跨路判据无意义）"):
		return
	if not _expect(same_lane > 0, true, "[record] 本路也有活敌（前提：否则会走跨路回退）"):
		return

	king.erase("vfx_skill_target_uid")
	BattleSimSkills._skill_god_king(king, enemies, king.get("def", {}))
	var rec := _uids_of(str(king.get("vfx_skill_target_uid", "")))
	print("  [diag] 记录到 %d 个目标：%s" % [rec.size(), str(rec)])
	if not _expect(rec.size() > 0, true, "[record] 生产实现确实写下了技能目标"):
		return

	# ★ 核心回归判据：记录里的每一个 uid 都必须在**神王那一路**。
	var crossed := 0
	for uid in rec:
		var e := _find_uid(state, uid)
		if e.is_empty() or int(e.get("lane", -1)) != king_lane:
			crossed += 1
	_expect(crossed, 0, "[record] ★ 记录的每个目标都在神王那一路（非技能目标不得入册）")
	_expect(rec.size(), same_lane, "[record] 记录条数 == 本路存活敌人数（不多不少）")

	# 被闪避 / 被盾全吸收的目标也算技能目标 —— 只要 `_can_target` 放行就必须记。
	# 断言方式：把本路敌人的闪避拉满，让它必定被闪避；记录条数不应因此变少。
	for e in enemies:
		if typeof(e) == TYPE_DICTIONARY and int((e as Dictionary).get("lane", -1)) == king_lane:
			(e as Dictionary)["dodge"] = 1.0
	king.erase("vfx_skill_target_uid")
	BattleSimSkills._skill_god_king(king, enemies, king.get("def", {}))
	_expect(_uids_of(str(king.get("vfx_skill_target_uid", ""))).size(), same_lane,
		"[record] 被闪避的目标仍然入册（口径是「技能目标」而不是「掉血的」）")

	# 反面：本路敌人全部阵亡时，`_can_target` 的**既有回退**必须仍然允许跨路。
	# 防的是「为了修这个 bug 就简单地锁死 lane == caster.lane」这种过度收窄。
	for e in enemies:
		if typeof(e) == TYPE_DICTIONARY and int((e as Dictionary).get("lane", -1)) == king_lane:
			(e as Dictionary)["alive"] = false
			(e as Dictionary)["hp"] = 0
	king.erase("vfx_skill_target_uid")
	BattleSimSkills._skill_god_king(king, enemies, king.get("def", {}))
	var rec2 := _uids_of(str(king.get("vfx_skill_target_uid", "")))
	print("  [diag] 本路清空后记录到 %d 个目标（期望 >0：跨路回退仍生效）" % rec2.size())
	_expect(rec2.size() > 0, true, "[record] 本路无活敌时仍会跨路选目标（既有回退未被破坏）")


# --- Part 6: 目标解析（纯函数）-------------------------------------------------
#
# 这一层是「记录 → 落点」的翻译。之所以抽成 static 纯函数并在这里直接调：
# 上一轮的血条教训 —— 文本断言挡不住 `if false and ...`。判据必须落在**行为**上。
func _part_target_resolution() -> void:
	var current := {
		"a": {"sim_uid": "e1", "alive": true, "world_foot": Vector3(1.0, 0.0, 1.0)},
		"b": {"sim_uid": "e2", "alive": true, "world_foot": Vector3(2.0, 0.0, 2.0)},
		"c": {"sim_uid": "e3", "alive": true, "world_foot": Vector3(3.0, 0.0, 3.0)},
	}

	# ★ 回归判据：记录里只有 e1 → **只准出 1 个落点**。场上另外两只（e2/e3）是
	#   非技能目标，一个都不许出现在落点里 —— 这正是用户截图里的现象。
	var one: Array = VFX.resolve_skill_target_positions(current, "e1")
	_expect(one.size(), 1, "解析：记录 1 个 uid → 只出 1 个落点（非技能目标不得落雷）")
	_expect(str(one[0]), str(Vector3(1.0, 0.0, 1.0)), "解析：落点取该目标自己的 world_foot")

	var two: Array = VFX.resolve_skill_target_positions(current, "e1,e2")
	_expect(two.size(), 2, "解析：逗号连接的多目标记录 → 两个落点")
	_expect(str(two[0]) == str(Vector3(1.0, 0.0, 1.0)) and str(two[1]) == str(Vector3(2.0, 0.0, 2.0)), true,
		"解析：落点顺序与记录顺序一致")

	_expect(VFX.resolve_skill_target_positions(current, "e1,nope").size(), 1, "解析：认不得的 uid 跳过")
	_expect(VFX.resolve_skill_target_positions(current, "e1,").size(), 1, "解析：尾随逗号不产生空目标")
	_expect(VFX.resolve_skill_target_positions(current, "").size(), 0, "解析：空记录 → 无落点")

	# ★ 被**本技能的雷**劈死的目标：记录里在，但 alive=false。
	#   那道雷恰恰是最该看见的一道（目标倒下 + 头顶落雷），所以**不许**按 alive 过滤。
	var dead: Dictionary = current.duplicate(true)
	(dead["a"] as Dictionary)["alive"] = false
	_expect(VFX.resolve_skill_target_positions(dead, "e1").size(), 1,
		"解析：★ 被劈死的目标仍出落点（劈死它的那道雷不能消失）")


# --- Part 7: 接线 -------------------------------------------------------------

func _part_wiring() -> void:
	var screen_src := FileAccess.get_file_as_string("res://scenes/battle/BattleScreen.gd").replace("\r\n", "\n")
	var vfx_src := FileAccess.get_file_as_string("res://scenes/battle/BattleVfx.gd").replace("\r\n", "\n")
	var rend_src := FileAccess.get_file_as_string("res://scenes/battle/BattleRenderer.gd").replace("\r\n", "\n")
	var comp_src := FileAccess.get_file_as_string("res://effects/vfx3d/units/UnitSkillVFXComposer3D.gd").replace("\r\n", "\n")

	# 神王 / 裁决者 都要走同一个 _aoe_thunder
	_expect(comp_src.contains("\"global_divine_blast\":_aoe_thunder(origin,target,context)"), true,
		"composer：神王技能接到 _aoe_thunder")
	_expect(comp_src.contains("\"judgement_strike\":_aoe_thunder(origin,target,{}"), true,
		"composer：裁决者技能接到 _aoe_thunder")
	_expect(comp_src.contains("arc.play_arc(at + Vector3(0.0, 2.85, 0.0), at, HOLY_THUNDER_PALETTE)"), true,
		"composer：落雷用白芯暖金配色（不是默认冷蓝）")
	# 人王那条必须已经还原（不能再是落雷）
	_expect(comp_src.contains("\"unique_king_growth\":_king_attack(origin,target,context)"), true,
		"composer：人王的技能/普攻表现已还原成天剑（不再是落雷）")

	# 策反接线（文本层只补"调用点有没有被删掉 / 被注释掉"——行为由 Part 4 直接验）
	_expect(screen_src.contains("latched_conversions_in_frame(frames[i], _replay_by_uid)"), true,
		"BattleScreen：解码时调用锁存函数")
	# ★ 用 `_has_live_code` 而不是裸 `contains`：裸 `contains` 连**注释掉**的行也算数。
	#   变异测试实测过这个假绿 —— 把调用点改成 `# apply_latched_team(...)`，
	#   子串照样匹配、探针照样全绿。文本断言必须能看穿注释。
	_expect(_has_live_code(screen_src, "apply_latched_team(f, str(entry[0]), _converted_ally_ids)"), true,
		"BattleScreen：解码时把锁存队伍写回（调用点存在且**未被注释**）")
	_expect(_has_live_code(screen_src, "_converted_ally_ids[linked_uid] = frame_conversions[linked_uid]"), true,
		"BattleScreen：锁存结果真的写进 _converted_ally_ids（未被注释）")
	_expect(rend_src.contains("var want_color: Color = _hp_color_for_team(_display_team(f))"), true,
		"BattleRenderer：每帧按当前队伍重算血条颜色")
	_expect(vfx_src.contains("_apply_shared_link_bar_tint"), false,
		"BattleVfx：旧的「血条染契约色」已删除（它会和队伍色打架）")
	_expect(vfx_src.contains("var _hp_bar_base_colors"), false, "BattleVfx：旧的契约色缓存已删除")

	# --- 第四轮：神王目标集合的接线 ---
	var skills_src := FileAccess.get_file_as_string("res://scripts/battle/BattleSimSkills.gd").replace("\r\n", "\n")
	_expect(_has_live_code(skills_src, "_mark_vfx_targets(caster, struck)"), true,
		"BattleSimSkills：神王技能把**真实选中**的目标记进 vfx_skill_target_uid（未被注释）")
	_expect(_has_live_code(vfx_src, "resolve_skill_target_positions(current,recorded)"), true,
		"BattleVfx：神王分支的目标集合来自**记录**，不再自己猜（未被注释）")
	# ★ 这条是「非技能目标也落雷」的**结构性**防线：退回旧口径必须被 `recorded.is_empty()`
	#   锁住。变异测试会把它改成 `if true:`，那时文本这一条就会红。
	_expect(_has_live_code(vfx_src, "if recorded.is_empty():"), true,
		"BattleVfx：只有**没有记录**时才退回旧口径（有记录时不许退）")


# --- 辅助 ---------------------------------------------------------------------

# 该子串是否出现在**未被注释**的行上。
#
# 为什么需要：`src.contains(x)` 会把 `# x` 也算成"有"。变异测试实测过：
# 把调用点整行注释掉，裸 contains 依然绿 —— 于是"接线还在不在"这条判据形同虚设。
# 这里按行判断，剔除以 `#` 开头的行（其前面的空白也算）。
func _has_live_code(src: String, needle: String) -> bool:
	for line in src.split("\n"):
		if not line.contains(needle):
			continue
		if line.strip_edges().begins_with("#"):
			continue
		return true
	return false


# 逗号连接的 uid 记录 → 数组（尾随/连续逗号产生的空项丢掉）。
func _uids_of(raw: String) -> Array:
	var out: Array = []
	for part in raw.split(",", false):
		if not str(part).is_empty():
			out.append(str(part))
	return out


func _cfg() -> Dictionary:
	return {
		"placements": [
			{"slot": 0, "cell": 2, "kind": "piece", "unit_id": DOOM, "star": 4},
			{"slot": 0, "cell": 1, "kind": "piece", "unit_id": MIL, "star": 1},
			{"slot": 3, "cell": 0, "kind": "piece", "unit_id": MIL, "star": 1},
			{"slot": 3, "cell": 1, "kind": "piece", "unit_id": MIL, "star": 1},
		],
		"slot_treasures": {},
	}


# 直接读数据文件，不猜 DataRegistry 的 API（猜错会让整段静默返回 ""，看着像"没配技能"）。
func _skill_id_of(unit_id: String) -> String:
	var raw := FileAccess.get_file_as_string("res://data/units/race_units.json")
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return "<json-unreadable>"
	var units: Variant = (parsed as Dictionary).get("units", [])
	if not (units is Array):
		return "<no-units>"
	for u in (units as Array):
		if u is Dictionary and str((u as Dictionary).get("id", "")) == unit_id:
			return str((u as Dictionary).get("skill_id", ""))
	return "<not-found>"


func _find_uid(state: Dictionary, uid: String) -> Dictionary:
	for side in ["player", "enemy"]:
		for f in state.get(side, []):
			if typeof(f) == TYPE_DICTIONARY and str((f as Dictionary).get("uid", "")) == uid:
				return f
	return {}


func _find_by_id(state: Dictionary, unit_id: String) -> Dictionary:
	for side in ["player", "enemy"]:
		for f in state.get(side, []):
			if typeof(f) == TYPE_DICTIONARY and str((f as Dictionary).get("id", "")) == unit_id:
				return f
	return {}


func _in_team(state: Dictionary, side: String, uid: String) -> bool:
	for f in state.get(side, []):
		if typeof(f) == TYPE_DICTIONARY and str((f as Dictionary).get("uid", "")) == uid:
			return true
	return false


func _expect(got, want, label: String) -> bool:
	_checks += 1
	var ok: bool = got == want
	if not ok:
		_fail += 1
	print("  %s %-58s got=%s want=%s" % ["PASS" if ok else "FAIL", label, str(got), str(want)])
	return ok
