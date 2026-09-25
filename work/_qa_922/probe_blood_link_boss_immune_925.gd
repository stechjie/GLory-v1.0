extends Node

# 9.25 探针 —— 锁死提交文档第 1 条：
#
#   「存在末日守卫技能可以对法阵boss生效的问题，法阵boss属于boss类单位，
#     应免疫末日守卫技能。」
#
# 用户补充确认过口径：**boss_* 与 ally_* 两者都免疫**（法阵 boss = 两者都要免疫）。
#
# 为什么这条必须单独探针，而不能靠「已有一条门禁覆盖了 boss」糊过去：
#   * `_is_boss_fighter` 只认 `is_boss` 字段与 `boss_` 前缀 —— ally_* 一个都抓不到；
#     法阵守护者既不是 boss_*、也不是玩家棋子，旧代码里它是**完全合法**的血链目标。
#   * 「候选池被过滤」这件事没有任何既有门禁会红：连上以后表现层照常画一条链，
#     只有实际对局里才会发现白送了一只 3200 血守护者。
#   * 而且它和「唯一棋子免疫」是**两条不同的规则**（unique_on_board 与法阵无关），
#     一条绿了不代表另一条绿。
#
# 探针设计原则（沿用 9.24 探针的教训）：
#   * 直接调**生产实现**（`build_test_state` / `_skill_shared_hp_link` /
#     `_nearest_non_boss` / `_link_targets_without_doom`），不复刻一份。
#   * 期望值**独立算**：我按「这个场景里合法目标只有 1 个」推出期望，而不是借
#     被测的那三个谓词去算；谓词本身只用 id 前缀这条**独立**线索交叉验证。
#   * 「不连接」这类否定断言最容易空过 —— 必须同时证明**技能真的跑到了**、
#     且守卫还活着（否则"没连上"只是因为守卫已经死了）。
#   * 文本断言只补「调用点被删掉 / 被注释掉」，用注释感知的 `_has_live_code`。

const SIM := preload("res://officetest/OfficeTestSim.gd")

const DOOM := "dark_doom"
const MIL := "human_militia"
const BOSS := "boss_thunder_core"
const ALLY := "ally_flame_claw"

var _fail := 0
var _checks := 0
var _saved_team_mode := false


func _ready() -> void:
	for i in 5:
		await get_tree().process_frame
	_saved_team_mode = GameState.team_mode
	GameState.team_mode = true

	print("=== Part 1: 谓词（真棋子，非手搓字典）—— boss_* / ally_* 都要被抓到 ===")
	_part_predicates()

	print("\n=== Part 2: 候选池与最近目标（直接跑生产实现）===")
	_part_pool_and_nearest()

	print("\n=== Part 3: 只放 boss / 只放 ally —— 技能跑过之后一条链都不许有 ===")
	_part_boss_only()
	_part_ally_only()

	print("\n=== Part 4: 混编（boss + ally + 1 个合法目标）—— 链只能落在合法目标上 ===")
	_part_mixed_live()

	print("\n=== Part 5: 接线文本断言（只证「写了且没被注释」，行为由上面几条验）===")
	_part_wiring()

	GameState.team_mode = _saved_team_mode
	if _fail == 0:
		print("\nPROBE_DONE checks=%d fail=0" % _checks)
	else:
		print("\nPROBE_DONE checks=%d fail=%d" % [_checks, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- Part 1: 谓词 -------------------------------------------------------------

# 被测的三个谓词各喂一只**真实** fighter（由 build_test_state 造，字段齐全），
# 期望值用 id 前缀独立推出来 —— 不走谓词自己。
func _part_predicates() -> void:
	var state: Dictionary = SIM.build_test_state(_cfg_mixed(), true)
	var boss := _find_by_id(state, BOSS)
	var ally := _find_by_id(state, ALLY)
	var mil := _find_by_id(state, MIL)
	var doom := _find_by_id(state, DOOM)
	if not _expect(not (boss.is_empty() or ally.is_empty() or mil.is_empty() or doom.is_empty()),
			true, "[pred] 四只单位都造出来了"):
		return

	print("  [diag] boss id=%s is_formation_ally=%s | ally id=%s is_formation_ally=%s"
		% [str(boss.get("id", "")), str(boss.get("is_formation_ally", false)),
			str(ally.get("id", "")), str(ally.get("is_formation_ally", false))])

	# 独立判据：id 前缀。boss_/ally_ 都必须被判为"不可连"。
	_expect(_is_boss_like(str(boss.get("id", ""))), true, "[pred] boss 的 id 确实以 boss_ 开头")
	_expect(_is_boss_like(str(ally.get("id", ""))), false, "[pred] ally 的 id **不是** boss_ 开头")
	_expect(_is_ally_like(str(ally.get("id", ""))), true, "[pred] ally 的 id 以 ally_ 开头")

	_expect(BattleSimulator._is_boss_fighter(boss), true, "[pred] _is_boss_fighter(boss) = true")
	_expect(BattleSimulator._is_boss_fighter(ally), false, "[pred] _is_boss_fighter(ally) = false（旧代码就栽在这）")
	_expect(BattleSimulator._is_formation_ally_fighter(boss), false, "[pred] _is_formation_ally_fighter(boss) = false")
	_expect(BattleSimulator._is_formation_ally_fighter(ally), true, "[pred] _is_formation_ally_fighter(ally) = true")
	_expect(BattleSimulator._is_formation_ally_fighter(mil), false, "[pred] 普通棋子不是法阵友军")
	_expect(BattleSimulator._is_formation_ally_fighter(doom), false, "[pred] 末日守卫本身不是法阵友军")


# --- Part 2: 候选池 / 最近目标 ------------------------------------------------

# 本场景敌方只有 boss + ally + 1 个民兵，所以「合法目标」**恰好只有 1 个**。
# 期望值就是那个民兵 —— 与谓词实现无关，纯场景结构推出来的。
func _part_pool_and_nearest() -> void:
	var state: Dictionary = SIM.build_test_state(_cfg_mixed(), true)
	var doom := _find_by_id(state, DOOM)
	var mil := _find_by_id(state, MIL)
	if not _expect(not (doom.is_empty() or mil.is_empty()), true, "[pool] 守卫与民兵都在场"):
		return
	var enemies: Array = state.get("enemy", [])
	_expect(enemies.size(), 3, "[pool] 敌方共 3 只（boss + ally + 民兵）")

	var pool: Array = BattleSimulator._link_targets_without_doom(doom, enemies)
	var pool_ids := _ids_of(pool)
	print("  [diag] 候选池 ids=%s" % str(pool_ids))
	_expect(pool.size(), 1, "[pool] 候选池只剩 1 只（boss 与 ally 都被排除）")
	_expect(pool_ids, [MIL], "[pool] 候选池里就是那只民兵")

	var nearest: Dictionary = BattleSimulator._nearest_non_boss(doom, enemies)
	var nearest_id := str(nearest.get("id", ""))
	print("  [diag] 最近合法目标 id=%s（敌方三只的独立判定：boss_ 前缀 / ally_ 前缀）" % nearest_id)
	_expect(nearest_id, MIL, "[pool] 最近目标就是那只民兵（不是 boss、也不是 ally）")


# --- Part 3: 只放 boss / 只放 ally -------------------------------------------

func _part_boss_only() -> void:
	_no_link_when_only_excluded("[boss]", [
		{"slot": 0, "cell": 2, "kind": "piece", "unit_id": DOOM, "star": 4},
		{"slot": 3, "cell": 1, "kind": "boss", "unit_id": BOSS, "star": 1},
	])


func _part_ally_only() -> void:
	_no_link_when_only_excluded("[ally]", [
		{"slot": 0, "cell": 2, "kind": "piece", "unit_id": DOOM, "star": 4},
		{"slot": 3, "cell": 1, "kind": "formation", "unit_id": ALLY, "star": 1},
	])


# 敌方只有一只"应免疫"的单位时，血链**一条都不该产生**。
#
# ★ 否定断言最容易空过：如果守卫在这一步已经死了，`_skill_shared_hp_link` 根本不会
#   跑，「没有链」就毫无意义。所以这里先**显式调用生产技能入口**（而不是靠
#   step_state 碰运气），跑完再断言守卫仍然活着、技能确实执行过。
func _no_link_when_only_excluded(tag: String, placements: Array) -> void:
	var state: Dictionary = SIM.build_test_state({
		"placements": placements,
		"slot_treasures": {},
	})
	var doom := _find_by_id(state, DOOM)
	var victim := _find_by_id(state, BOSS) if tag == "[boss]" else _find_by_id(state, ALLY)
	var victim_id := BOSS if tag == "[boss]" else ALLY
	if not _expect(not (doom.is_empty() or victim.is_empty()), true,
			"%s 守卫与目标(%s)都在场" % [tag, victim_id]):
		return

	# 清掉开局可能残留的链状态，让这次调用是"第一次释放"。
	doom.erase("shared_link_uid")
	doom.erase("shared_link_spent")
	doom.erase("shared_link_last_hp")

	var enemies: Array = state.get("enemy", [])
	_expect(enemies.size(), 1, "%s 敌方只有 1 只（%s）" % [tag, victim_id])
	BattleSimulator._skill_shared_hp_link(doom, enemies, {}, state)
	BattleSimulator.step_state(state)

	var guard_now := _find_by_id(state, DOOM)
	var guard_alive := not guard_now.is_empty() and bool(guard_now.get("alive", false))
	# 前提：守卫活着 —— 否则"没连上"可能只是因为技能压根没跑。
	if not _expect(guard_alive, true, "%s 守卫仍存活（前提：否则下面的否定断言会空过）" % tag):
		return

	var link := str(guard_now.get("shared_link_uid", ""))
	var victim_now := _find_by_id(state, victim_id)
	var victim_team := str(victim_now.get("team", ""))
	var victim_link := str(victim_now.get("shared_link_uid", ""))
	print("  [diag] %s 守卫 shared_link_uid=%s；目标 team=%s shared_link_uid=%s"
		% [tag, link, victim_team, victim_link])

	_expect(link, "", "%s ★ 守卫没有连上任何目标（只有应免疫单位可连）" % tag)
	_expect(victim_link, "", "%s ★ 目标身上没有链（没被当成连接对象）" % tag)
	_expect(victim_team, "enemy", "%s ★ 目标仍在敌方（没被策反）" % tag)
	_expect(str(guard_now.get("team", "")), "player", "%s 守卫仍在己方" % tag)


# --- Part 4: 混编端到端 -------------------------------------------------------

func _part_mixed_live() -> void:
	var state: Dictionary = SIM.build_test_state(_cfg_mixed())
	var doom := _find_by_id(state, DOOM)
	if not _expect(not doom.is_empty(), true, "[live] 场上有末日守卫"):
		return
	var mil := _find_by_id(state, MIL)
	var mil_uid := str(mil.get("uid", ""))
	var boss_uid := str(_find_by_id(state, BOSS).get("uid", ""))
	var ally_uid := str(_find_by_id(state, ALLY).get("uid", ""))
	var doom_lane := int(doom.get("lane", -1))

	# 真的推进 tick（契约不是 build 时就生效的，9.24 实测第 5 帧才锁上）。
	var linked := ""
	for i in 400:
		linked = str(_find_by_id(state, DOOM).get("shared_link_uid", ""))
		if not linked.is_empty():
			break
		BattleSimulator.step_state(state)

	print("  [diag] 守卫 lane=%d uid=%s；boss=%s ally=%s 民兵=%s；契约 uid=%s"
		% [doom_lane, str(doom.get("uid", "")), boss_uid, ally_uid, mil_uid, linked])
	_expect(not linked.is_empty(), true, "[live] 守卫锁定了契约目标（真的连上了，不是空场景）")
	_expect(linked, mil_uid, "[live] ★ 契约目标就是那只普通民兵（不是 boss、不是 ally）")
	_expect(linked == boss_uid, false, "[live] ★ 契约目标不是 boss")
	_expect(linked == ally_uid, false, "[live] ★ 契约目标不是法阵友军")

	# 两只应免疫单位：没链、没被换队。
	var boss_now := _find_by_id(state, BOSS)
	var ally_now := _find_by_id(state, ALLY)
	_expect(str(boss_now.get("shared_link_uid", "")), "", "[live] boss 身上没有链")
	_expect(str(ally_now.get("shared_link_uid", "")), "", "[live] ally 身上没有链")
	_expect(str(boss_now.get("team", "")), "enemy", "[live] boss 仍在敌方")
	_expect(str(ally_now.get("team", "")), "enemy", "[live] ally 仍在敌方")
	_expect(_in_team(state, "player", boss_uid), false, "[live] boss 没被挪进 player 数组")
	_expect(_in_team(state, "player", ally_uid), false, "[live] ally 没被挪进 player 数组")


# --- Part 5: 接线 -------------------------------------------------------------

func _part_wiring() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/battle/BattleSimulator.gd") \
		.replace("\r\n", "\n")

	# 三条排除点各一条存在性断言。用 `_has_live_code` 而不是裸 `contains`：
	# 裸 contains 连**注释掉**的行也算数，上一轮实测过这个假绿。
	_expect(_has_live_code(src,
			"if not bool(o.get(\"alive\", false)) or _is_boss_fighter(o) or _is_formation_ally_fighter(o) or not _can_target(f, o, opponents):"),
		true, "wiring：_nearest_non_boss 里 boss/法阵友军都在跳过条件里")
	_expect(_has_live_code(src,
			"if o == caster or _is_doom_guard_fighter(o) or _is_unique_fighter(o) or _is_boss_fighter(o) or _is_formation_ally_fighter(o):"),
		true, "wiring：_link_targets_without_doom 里 boss/法阵友军都排除了（防御性重复）")
	_expect(_has_live_code(src,
			"if _is_boss_fighter(current) or _is_formation_ally_fighter(current):"),
		true, "wiring：重连守卫会把已连上的 boss/法阵友军断开")
	_expect(_has_live_code(src, "func _is_formation_ally_fighter(fighter: Dictionary) -> bool:"),
		true, "wiring：_is_formation_ally_fighter 定义还在")

	# 谓词本体必须同时认 `is_formation_ally` 字段与 `ally_` 前缀兜底。
	var i := src.find("func _is_formation_ally_fighter")
	var body := src.substr(i, 320) if i >= 0 else ""
	_expect(body.contains("fighter.get(\"is_formation_ally\", false)"), true,
		"wiring：谓词读 is_formation_ally 字段")
	_expect(body.contains("id.begins_with(\"ally_\")"), true,
		"wiring：谓词补了 ally_ 前缀兜底")


# --- helpers -----------------------------------------------------------------

func _cfg_mixed() -> Dictionary:
	return {
		"placements": [
			{"slot": 0, "cell": 2, "kind": "piece", "unit_id": DOOM, "star": 4},
			{"slot": 3, "cell": 1, "kind": "formation", "unit_id": ALLY, "star": 1},
			{"slot": 3, "cell": 2, "kind": "boss", "unit_id": BOSS, "star": 1},
			{"slot": 3, "cell": 0, "kind": "piece", "unit_id": MIL, "star": 1},
		],
		"slot_treasures": {},
	}


func _is_boss_like(unit_id: String) -> bool:
	return unit_id.begins_with("boss_")


func _is_ally_like(unit_id: String) -> bool:
	return unit_id.begins_with("ally_")


func _ids_of(fighters: Array) -> Array:
	var out: Array = []
	for f in fighters:
		if typeof(f) == TYPE_DICTIONARY:
			out.append(str((f as Dictionary).get("id", "")))
	out.sort()
	return out


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


# 注释感知的存在性断言（与 9.24 探针同一实现）。
func _has_live_code(src: String, needle: String) -> bool:
	for line in src.split("\n"):
		if not line.contains(needle):
			continue
		if line.strip_edges().begins_with("#"):
			continue
		return true
	return false


func _expect(got, want, label: String) -> bool:
	_checks += 1
	var ok: bool = got == want
	if not ok:
		_fail += 1
	print("  %s %-58s got=%s want=%s"
		% ["PASS" if ok else "FAIL", label, str(got), str(want)])
	return ok
