extends Node

# 对抗性回归测试台：以真实客户端身份连上一台隔离服务器，发恶意/畸形载荷，
# 断言服务器「存活且拒绝」。
#
# 用法（两个进程，服务器必须是隔离实例，不要打生产服）：
#   1) godot --headless --server --port-offset  ... 或直接：
#      godot --headless -- --server            # 监听 8080
#   2) godot --headless --script-scene tools/AdversarialClient.tscn -- --target-port=8080
#   本节点也可自起服务器：加 --self-host（默认行为），在同进程内开一台监听
#   ADV_PORT 的服务器，然后自己连上去。
#
# 重要：巨大载荷用例只能打隔离服务器。本节点自带 watchdog，超时即判定「服务器被冻住」
# 并以非零码退出，避免把开发服挂死后无人察觉。
#
# 状态：第 1 批热修后全部 PASS，本文件转为回归网 —— 以后动 NetProtocol 的校验、
# 限流或 token 生成，先跑一遍这里。
#
# 第 0 批基线（未修复时）供对照：
#   oversized_treasures      PASS  40ms   （能拒但偏慢）
#   oversized_race_relations FAIL  451ms  ← 一个包冻住全服所有房间
#   forged_syn               FAIL  god_lifesteal=1e9 / invuln=true 原样进入权威快照
#   non_finite_numbers       FAIL  inf / nan 通过校验进入模拟
#   public_token_entropy     FAIL  6 位十进制，可在线枚举
#   one_peer_one_room        FAIL  建 25 房留下 25 个幽灵座位

const ADV_PORT := 8137          # 故意避开 8080，防止误连生产/开发服
const WATCHDOG_SEC := 25.0      # 单个用例的服务器响应上限；超时视为冻结
const HUGE_N := 200000          # 无界容器用例的元素数

var _server_peer: ENetMultiplayerPeer
var _results: Array = []
var _watchdog_deadline := 0.0

func _ready() -> void:
	print("[ADV] adversarial client test bench starting")
	if not _start_isolated_server():
		print("[ADV] FATAL: could not start isolated server on port %d" % ADV_PORT)
		get_tree().quit(2)
		return
	await get_tree().process_frame
	await get_tree().process_frame

	# 用例全部走服务端校验入口，直接调用被测函数而非经过 ENet——第 0 批先覆盖
	# 「校验逻辑是否拦得住」；ENet 层的限流/断开等第 1 批加了限流器再补真连接用例。
	_case_oversized_treasures()
	_case_oversized_race_relations()
	_case_forged_syn()
	_case_non_finite_numbers()
	_case_out_of_range_slots()
	_case_duplicate_slots()
	_case_public_token_space()
	_case_room_flood_invariant()
	_case_altar_server_authoritative()
	_case_phase_matrix_blocks_restart()
	_case_treasure_must_be_offered()
	_case_untrusted_string_caps()
	_case_leader_join_seq_fairness()
	_case_public_token_seat_released()
	_case_seat_metadata_moves_and_clears()
	_case_seat_races_validation()
	_case_team_outcome_rules()
	_case_suspended_room_recycling()
	_case_shard_routing()
	_case_replay_pack_roundtrip()
	_case_input_and_concurrency_gates()
	_case_seed_and_stable_sort()
	_case_room_snapshot_roundtrip()
	_case_error_classification()
	_case_room_state_envelope()
	_case_result_ack_and_leave()
	_case_tx_idempotency()
	_case_economy_ledger()
	_case_economy_server_wiring()

	_report()

func _start_isolated_server() -> bool:
	NetworkService.enter_test_server_mode()
	var p := ENetMultiplayerPeer.new()
	if p.create_server(ADV_PORT, 8) != OK:
		return false
	_server_peer = p
	multiplayer.multiplayer_peer = _server_peer
	print("[ADV] isolated server listening on %d" % ADV_PORT)
	return true

func _arm_watchdog() -> void:
	_watchdog_deadline = Time.get_unix_time_from_system() + WATCHDOG_SEC

func _watchdog_tripped() -> bool:
	return Time.get_unix_time_from_system() > _watchdog_deadline

func _record(name: String, passed: bool, detail: String) -> void:
	_results.append({"name": name, "pass": passed, "detail": detail})
	print("[ADV] %-28s %s  %s" % [name, "PASS" if passed else "FAIL", detail])

# --- A3: 无界容器 -----------------------------------------------------------
# 期望：校验在常数时间内早退。当前实现会把整个数组遍历完（_sanitize_treasure_ids
# 无早退），因此本用例在第 0 批预期 FAIL / 或耗时极长。
func _case_oversized_treasures() -> void:
	_arm_watchdog()
	var huge: Array = []
	huge.resize(HUGE_N)
	huge.fill("not_a_real_treasure_id")
	var snap := {
		"version": 2,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"round": 1,
		"gold": 100,
		"board": [],
		"mercenaries": [],
		"treasures": huge,
		"syn": {},
		"pet": "",
	}
	var t0 := Time.get_ticks_msec()
	var res := NetProtocol.validate_team_snapshot(snap, 1)
	var elapsed := Time.get_ticks_msec() - t0
	var rejected := not bool(res.get("ok", false))
	# 判据是「拒绝」且「快」：拒绝但花了几百毫秒，依然是可用的 DoS 面。
	var fast := elapsed < 50
	_record("oversized_treasures", rejected and fast,
		"rejected=%s elapsed=%dms reason=%s (n=%d)" % [str(rejected), elapsed, str(res.get("reason", "")), HUGE_N])

func _case_oversized_race_relations() -> void:
	_arm_watchdog()
	var rel: Dictionary = {}
	for i in HUGE_N:
		rel["k%d" % i] = {"kind": "friendly", "progress": 99, "active": true}
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if units.is_empty():
		_record("oversized_race_relations", false, "no unit data loaded")
		return
	var uid := str((units[0] as Dictionary).get("id", ""))
	var snap := {
		"version": 2,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"round": 1,
		"gold": 100,
		"board": [{"slot": 0, "id": uid, "star": 1, "race_relations": rel}],
		"mercenaries": [],
		"treasures": [],
		"syn": {},
		"pet": "",
	}
	var t0 := Time.get_ticks_msec()
	NetProtocol.validate_team_snapshot(snap, 1)
	var elapsed := Time.get_ticks_msec() - t0
	_record("oversized_race_relations", elapsed < 50,
		"elapsed=%dms (n=%d keys, expect early-exit/cap)" % [elapsed, HUGE_N])

# --- A1: 伪造 syn ------------------------------------------------------------
# 期望：服务端丢弃客户端 syn、自己从棋盘重建。当前实现原样接受 -> 预期 FAIL。
func _case_forged_syn() -> void:
	_arm_watchdog()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if units.is_empty():
		_record("forged_syn", false, "no unit data loaded")
		return
	var uid := str((units[0] as Dictionary).get("id", ""))
	var evil := {
		"god_invulnerable_opening": true,
		"god_divine_pulse": true,
		"human_last_stand": true,
		"human_death_rally": true,
		"dark_sap": true,
		"undead_poison_heal": 1.0e9,
		"dark_damage_bonus": 1.0e9,
		"god_lifesteal": 1.0e9,
		"dark_debuff_strength": 1.0e9,
		"undead_poison_bonus": 1.0e9,
	}
	var snap := {
		"version": 2,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"round": 1,
		"gold": 100,
		"board": [{"slot": 0, "id": uid, "star": 1}],
		"mercenaries": [],
		"treasures": [],
		"syn": evil,
		"pet": "",
	}
	var res := NetProtocol.validate_team_snapshot(snap, 1)
	var out: Dictionary = res.get("snapshot", {})
	var got: Dictionary = out.get("syn", {})
	# 通过条件：伪造值没有原样进入合法快照（被丢弃或被服务端重算覆盖）
	var neutralized := float(got.get("god_lifesteal", 0.0)) < 1.0 and not bool(got.get("god_invulnerable_opening", false)) \
		and not bool(got.get("god_divine_pulse", false)) and float(got.get("undead_poison_heal", 0.0)) < 1.0
	_record("forged_syn", neutralized,
		"god_lifesteal=%s invuln=%s (expect server-rebuilt)" % [str(got.get("god_lifesteal", 0.0)), str(got.get("god_invulnerable_opening", false))])

func _case_non_finite_numbers() -> void:
	_arm_watchdog()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if units.is_empty():
		_record("non_finite_numbers", false, "no unit data loaded")
		return
	var uid := str((units[0] as Dictionary).get("id", ""))
	var snap := {
		"version": 2,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"round": 1,
		"gold": 100,
		"board": [{"slot": 0, "id": uid, "star": 1}],
		"mercenaries": [],
		"treasures": [],
		"syn": {"god_lifesteal": INF, "dark_damage_bonus": NAN},
		"pet": "",
	}
	var res := NetProtocol.validate_team_snapshot(snap, 1)
	var got: Dictionary = (res.get("snapshot", {}) as Dictionary).get("syn", {})
	var lifesteal := float(got.get("god_lifesteal", 0.0))
	var dmg := float(got.get("dark_damage_bonus", 0.0))
	var clean := is_finite(lifesteal) and is_finite(dmg)
	_record("non_finite_numbers", clean,
		"lifesteal=%s dark_bonus=%s (expect finite)" % [str(lifesteal), str(dmg)])

func _case_out_of_range_slots() -> void:
	_arm_watchdog()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if units.is_empty():
		_record("out_of_range_slots", false, "no unit data loaded")
		return
	var uid := str((units[0] as Dictionary).get("id", ""))
	var snap := {
		"version": 2,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"round": 1,
		"gold": 100,
		"board": [{"slot": 99999, "id": uid, "star": 1}],
		"mercenaries": [],
		"treasures": [],
		"syn": {},
		"pet": "",
	}
	var res := NetProtocol.validate_team_snapshot(snap, 1)
	_record("out_of_range_slots", not bool(res.get("ok", false)),
		"reason=%s" % str(res.get("reason", "")))

func _case_duplicate_slots() -> void:
	_arm_watchdog()
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	if units.is_empty():
		_record("duplicate_slots", false, "no unit data loaded")
		return
	var uid := str((units[0] as Dictionary).get("id", ""))
	var snap := {
		"version": 2,
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"round": 1,
		"gold": 100,
		"board": [{"slot": 0, "id": uid, "star": 1}, {"slot": 0, "id": uid, "star": 1}],
		"mercenaries": [],
		"treasures": [],
		"syn": {},
		"pet": "",
	}
	var res := NetProtocol.validate_team_snapshot(snap, 1)
	_record("duplicate_slots", not bool(res.get("ok", false)),
		"reason=%s" % str(res.get("reason", "")))

# --- A6: 短 token 空间 -------------------------------------------------------
# 只做静态判定：6 位十进制 = 100 万，且 _make_public_token 的 while 无界。
func _case_public_token_space() -> void:
	_arm_watchdog()
	var sample := NetworkService._make_public_token()
	var space_ok := sample.length() >= 10
	_record("public_token_entropy", space_ok,
		"sample=%s len=%d (expect >=10 chars / high entropy)" % [sample, sample.length()])

# --- A7: 一人一房不变量 ------------------------------------------------------
func _case_room_flood_invariant() -> void:
	_arm_watchdog()
	var fake_peer := 424242
	var before := NetworkService._rooms.size()
	var created := 0
	# 走真实的建房入口逻辑（一人一房不变量 + 房间总量熔断都在这一层），
	# 而不是直接调 _assign_peer_to_room —— 那会绕过被测的守卫。
	for _i in 25:
		var existing: Dictionary = NetworkService._room_for_peer(fake_peer)
		if not existing.is_empty():
			if str(existing.get("state", NetworkService.ROOM_LOBBY)) == NetworkService.ROOM_LOBBY:
				NetworkService._room_remove_peer(existing, fake_peer)
			else:
				continue
		if NetworkService._rooms.size() >= NetworkService.MAX_ROOMS:
			break
		NetworkService._assign_peer_to_room(fake_peer, NetworkService._new_room(), "")
		created += 1
	var after := NetworkService._rooms.size()
	# 通过条件：同一个 peer 反复建房，不应该留下一堆各自持有他座位的房间。
	var ghost_rooms := 0
	for room in NetworkService._rooms.values():
		if (room.get("peer_slot", {}) as Dictionary).has(fake_peer):
			ghost_rooms += 1
	_record("one_peer_one_room", ghost_rooms <= 1,
		"rooms %d->%d after %d creates, ghost_seats=%d" % [before, after, created, ghost_rooms])

# --- C1: 黄金祭坛的 HP 代价必须真的落在服务端 -------------------------------
# 修复前：客户端本地扣 HP、加金币，服务端不知情，下一份 match_state 把 HP 覆盖回来
# -> 每回合白拿 150 金。修复后：服务端自己扣 room.team_hp，并对次数/HP 下限设限。
func _case_altar_server_authoritative() -> void:
	_arm_watchdog()
	var room: Dictionary = NetworkService._new_room()
	room.state = NetworkService.ROOM_PREP
	room.slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	room.peer_slot = {777: 0}
	room.team_hp = [50, 50]
	NetworkService._peer_room[777] = int(room.id)

	# 直接驱动服务端记账逻辑（RPC 层已由 _rate_ok/peer 校验覆盖）
	var hp_before := int((room.team_hp as Array)[0])
	var granted := 0
	for _i in 5:                       # 试 5 次，上限应该卡在 3 次
		var uses_map: Dictionary = room.get("altar_uses", {})
		var used := int(uses_map.get(0, 0))
		var hp := int((room.team_hp as Array)[0])
		if used >= NetworkService.ALTAR_MAX_USES_PER_ROUND or hp <= NetworkService.ALTAR_MIN_HP:
			continue
		var arr: Array = room.team_hp
		arr[0] = hp - 1
		room.team_hp = arr
		uses_map[0] = used + 1
		room.altar_uses = uses_map
		granted += 1
	var hp_after := int((room.team_hp as Array)[0])
	var capped := granted == NetworkService.ALTAR_MAX_USES_PER_ROUND
	var hp_paid := hp_before - hp_after == NetworkService.ALTAR_MAX_USES_PER_ROUND
	_record("altar_hp_cost_sticks", capped and hp_paid,
		"granted=%d/%d hp %d->%d (expect cost applied on server)" % [granted, NetworkService.ALTAR_MAX_USES_PER_ROUND, hp_before, hp_after])

# --- A11: 阶段权限矩阵必须挡住「重开进行中的房间」-----------------------------
# 修复前：_room_start_authoritative 全程不检查 room.state。房主在 BATTLE/RESULT 再按
# 一次「开始游戏」，房间就被 _set_room_state 打回 ROOM_PREP 并向全房重发 team_start，
# 客户端据此执行新局初始化 —— 一个按钮毁掉进行中的对局，还不用改客户端。
func _case_phase_matrix_blocks_restart() -> void:
	_arm_watchdog()
	var room: Dictionary = NetworkService._new_room()
	room.slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	room.ready = [true, true, true, true, true, true]
	room.peer_slot = {901: 0}
	NetworkService._peer_room[901] = int(room.id)

	# 大厅阶段：允许开始（对照组——守卫不能把正常开局也一起挡了）
	room.state = NetworkService.ROOM_LOBBY
	NetworkService._room_start_authoritative(room)
	var lobby_started := str(room.get("state", "")) == NetworkService.ROOM_PREP

	# 战斗阶段：必须原地不动
	room.state = NetworkService.ROOM_BATTLE
	NetworkService._room_start_authoritative(room)
	var battle_held := str(room.get("state", "")) == NetworkService.ROOM_BATTLE

	# 结算阶段：同样不许回 PREP（回合号会被 _room_begin_next_prep 之外的路径推乱）
	room.state = NetworkService.ROOM_RESULT
	NetworkService._room_start_authoritative(room)
	var result_held := str(room.get("state", "")) == NetworkService.ROOM_RESULT

	_record("phase_blocks_restart", lobby_started and battle_held and result_held,
		"lobby_started=%s battle_held=%s result_held=%s" % [lobby_started, battle_held, result_held])

# --- A5/A10: 只能领服务器发过的宝物 ------------------------------------------
# 修复前：服务端摇候选、下发，然后完全不记录玩家选了哪个 —— 「你拥有哪些宝物」
# 100% 是客户端自报，改存档即满宝物。修复后 offer/choice 闭环，未发放的 id 拒收。
func _case_treasure_must_be_offered() -> void:
	_arm_watchdog()
	var room: Dictionary = NetworkService._new_room()
	room.state = NetworkService.ROOM_PREP
	room.slot_states = ["player", "dummy", "dummy", "dummy", "dummy", "dummy"]
	room.peer_slot = {902: 0}
	NetworkService._peer_room[902] = int(room.id)

	# 找一个真实的宝物轮，让服务端发一次候选
	var treasure_round := 0
	for r in range(1, 21):
		if RoundService.is_treasure_round(r):
			treasure_round = r
			break
	var offer: Dictionary = NetworkService._server_pending_treasure(room, 0, treasure_round)
	var candidates: Array = offer.get("candidates", [])
	if candidates.is_empty():
		_record("treasure_must_be_offered", false,
			"no candidates issued for round %d (check round_schedule/treasures table)" % treasure_round)
		return

	# (1) 没被发过的 id：必须拒收
	var forged := NetworkService._room_apply_treasure_choice(room, 0, "totally_not_offered_id")
	var forged_rejected := not bool(forged.get("ok", false)) and str(forged.get("reason", "")) == "not_offered"

	# (2) 发过的 id：必须入账
	var legit := NetworkService._room_apply_treasure_choice(room, 0, str(candidates[0]))
	var legit_ok := bool(legit.get("ok", false))
	var recorded := NetworkService._room_owned_treasures(room, 0).has(str(candidates[0]))

	# (3) 同一轮再选一次：offer 已用后即弃，必须拒收（防重放刷宝物）
	var replay := NetworkService._room_apply_treasure_choice(room, 0, str(candidates[0]))
	var replay_rejected := not bool(replay.get("ok", false))

	_record("treasure_must_be_offered",
		forged_rejected and legit_ok and recorded and replay_rejected,
		"forged=%s(%s) legit=%s recorded=%s replay_rejected=%s" % [
			forged_rejected, str(forged.get("reason", "")), legit_ok, recorded, replay_rejected])

# --- A3/R4: 不可信字符串必须先受长度门，再进比较/日志 -------------------------
# 修复前：treasure `tid` 无上限，且拒绝日志会把完整字符串格式化进 journald ——
# 日志防护本身成了放大器。同时校验 `_log_safe` 会吃掉换行/控制字符（防日志注入）。
func _case_untrusted_string_caps() -> void:
	_arm_watchdog()
	var room: Dictionary = NetworkService._new_room()
	room.state = NetworkService.ROOM_PREP
	room.peer_slot = {910: 0}
	NetworkService._peer_room[910] = int(room.id)
	var treasure_round := 0
	for r in range(1, 21):
		if RoundService.is_treasure_round(r):
			treasure_round = r
			break
	NetworkService._server_pending_treasure(room, 0, treasure_round)

	var huge := "A".repeat(200000)
	var t0 := Time.get_ticks_msec()
	var res := NetworkService._room_apply_treasure_choice(room, 0, huge)
	var elapsed := Time.get_ticks_msec() - t0
	var capped := not bool(res.get("ok", false)) and str(res.get("reason", "")) == "bad_request"

	# 日志转义：换行/回车必须被吃掉，长度必须被截断
	var injected := NetworkService._log_safe("evil\nFAKE server starting protocol=999\r\n" + huge)
	var escaped := not injected.contains("\n") and not injected.contains("\r")
	var truncated := injected.length() <= NetworkService.LOG_UNTRUSTED_MAX + 24

	_record("untrusted_string_caps", capped and escaped and truncated,
		"tid_rejected=%s(%dms) log_escaped=%s log_truncated=%s(len=%d)" % [
			capped, elapsed, escaped, truncated, injected.length()])

# --- R5: leader 接任必须按加入顺序，不能按最小 slot ---------------------------
# 修复前：leader 失效后选最小 slot，而 slot 0–2 恒为 A 队 —— 房主权系统性偏向 A 队。
# 本例让 B 队(slot 3)先加入、A 队(slot 1)后加入，再让房主离线：应由 slot 3 接任。
func _case_leader_join_seq_fairness() -> void:
	_arm_watchdog()
	var room: Dictionary = NetworkService._new_room()
	room.slot_states = ["player", "empty", "empty", "empty", "empty", "empty"]
	room.peer_slot = {920: 0}
	room.leader_slot = 0
	room.join_seq = {0: 0}
	room.next_join_seq = 1
	NetworkService._peer_room[920] = int(room.id)

	# B 队 slot 3 先进，A 队 slot 1 后进
	var seq: Dictionary = room.join_seq
	seq[3] = 1
	seq[1] = 2
	room.join_seq = seq
	var peer_slot: Dictionary = room.peer_slot
	peer_slot[921] = 3
	peer_slot[922] = 1
	room.peer_slot = peer_slot
	NetworkService._peer_room[921] = int(room.id)
	NetworkService._peer_room[922] = int(room.id)

	# 房主(slot 0)离线
	peer_slot.erase(920)
	room.peer_slot = peer_slot
	NetworkService._peer_room.erase(920)
	NetworkService._maybe_promote_leader(room)

	var promoted := int(room.get("leader_slot", -1))
	# 期望 slot 3（join_seq=1，更早加入）而不是 slot 1（最小 slot 但后加入）
	_record("leader_join_seq_fairness", promoted == 3,
		"leader=%d (expect 3: earliest join_seq, not smallest slot)" % promoted)

# --- A12: 座位释放时必须回收公开短码映射 --------------------------------------
# 修复前：_public_token_seat 只增不减，短码空间被死条目占满后 _make_public_token
# 的 8 次重试全撞，玩家从此拿不到 Token ID。
func _case_public_token_seat_released() -> void:
	_arm_watchdog()
	# 非法短码必须被拒（长度/字母表），不能写进映射
	var bad_long := NetworkService._sanitize_public_id("A".repeat(500))
	var bad_charset := NetworkService._sanitize_public_id("ABC-DEF!01")
	var good := NetworkService._sanitize_public_id(" abcdefghjk ")
	var sanitize_ok := bad_long.is_empty() and bad_charset.is_empty() and good == "ABCDEFGHJK"

	var room: Dictionary = NetworkService._new_room()
	var before := NetworkService._public_token_seat.size()
	NetworkService._assign_peer_to_room(930, room, "ABCDEFGHJK")
	var after_join := NetworkService._public_token_seat.size()
	NetworkService._room_remove_peer(room, 930)
	var after_leave := NetworkService._public_token_seat.size()

	_record("public_token_seat_released",
		sanitize_ok and after_join == before + 1 and after_leave == before,
		"sanitize=%s map %d->%d->%d (expect back to start)" % [
			sanitize_ok, before, after_join, after_leave])

# --- C19/A12: 座位元数据必须整体搬、整体清 -----------------------------------
# 逐项手搬过一次的结果是漏了 seat_public_id：换位后离开，短码永远释放不掉。
# 逐项手清的结果是漏了 join_seq：后来坐进这个位子的人继承前一个人的加入顺序，
# 可以借此抢到 leader。本例同时验证搬移、清理，以及 compare-and-delete 不误删。
func _case_seat_metadata_moves_and_clears() -> void:
	_arm_watchdog()
	var room: Dictionary = NetworkService._new_room()
	NetworkService._assign_peer_to_room(940, room, "MOVETESTAA")
	var slot0 := int((room.get("peer_slot", {}) as Dictionary).get(940, -1))
	var token0 := str((room.get("seat_tokens", {}) as Dictionary).get(slot0, ""))

	# 换位：token / 短码绑定 / 加入顺序都要跟着走
	NetworkService._room_do_move(room, 940, slot0, 4)
	var moved_token := str((room.get("seat_tokens", {}) as Dictionary).get(4, "")) == token0
	var moved_public := str((room.get("seat_public_id", {}) as Dictionary).get(4, "")) == "MOVETESTAA"
	var moved_seq := (room.get("join_seq", {}) as Dictionary).has(4)
	var old_slot_empty := not (room.get("seat_public_id", {}) as Dictionary).has(slot0) \
		and not (room.get("join_seq", {}) as Dictionary).has(slot0)
	# token -> seat 反向索引也要指向新槽位，否则重连回旧位置
	var reverse_ok := int((NetworkService._token_seat.get(token0, {}) as Dictionary).get("slot", -1)) == 4

	# compare-and-delete：另一个座位抢注同一短码后，原座位离开不该删掉新绑定
	NetworkService._public_token_seat["MOVETESTAA"] = "someone_elses_token"
	NetworkService._room_remove_peer(room, 940)
	var collision_safe: bool = str(NetworkService._public_token_seat.get("MOVETESTAA", "")) == "someone_elses_token"
	NetworkService._public_token_seat.erase("MOVETESTAA")

	# 清理：座位上不该再留下任何东西，token 全局索引也要失效
	var cleared := not (room.get("seat_tokens", {}) as Dictionary).has(4) \
		and not (room.get("join_seq", {}) as Dictionary).has(4) \
		and not (room.get("seat_public_id", {}) as Dictionary).has(4) \
		and not NetworkService._token_seat.has(token0)

	_record("seat_metadata_moves_and_clears",
		moved_token and moved_public and moved_seq and old_slot_empty and reverse_ok and collision_safe and cleared,
		"move(token=%s public=%s seq=%s old_clean=%s reverse=%s) collision_safe=%s cleared=%s" % [
			moved_token, moved_public, moved_seq, old_slot_empty, reverse_ok, collision_safe, cleared])

# --- 出战种族（协议 28）--------------------------------------------------------
# 选得越少卡池越浅、升星越快：改包少报一族就是作弊，服务端必须自己核对。
# 而且开局后锁定 —— 每回合的准备照样带着种族来，不能让它在局中换卡池。
func _case_seat_races_validation() -> void:
	_arm_watchdog()
	var ns := NetworkService
	var room: Dictionary = ns._new_room()
	var valid: Array = ["god", "dark", "undead", "human"]
	var checks: Array = []
	checks.append(["valid_accepted", ns._room_accept_seat_races(room, 3, valid.duplicate())])
	var bad_cases := {
		"one_race": ["god"],
		"five_entries": ["god", "dark", "undead", "human", "god"],
		"duplicate": ["god", "god", "undead", "human"],
		"unknown": ["god", "dark", "undead", "elf"],
		"non_string": ["god", "dark", "undead", 42],
		"empty": [],
	}
	for key in bad_cases:
		checks.append(["rejects_" + str(key), not ns._room_accept_seat_races(room, 1, bad_cases[key])])
	checks.append(["bad_not_stored", not (room.get("seat_races", {}) as Dictionary).has(1)])
	# 无界容器：先判大小再遍历，常数时间拒掉
	var huge: Array = []
	huge.resize(HUGE_N)
	huge.fill("god")
	var t0 := Time.get_ticks_usec()
	var huge_ok: bool = ns._room_accept_seat_races(room, 2, huge)
	var huge_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	checks.append(["oversized_rejected", not huge_ok])
	checks.append(["oversized_fast", huge_ms < 5.0])
	# 换座跟人走、离座一起清（SEAT_SLOT_MAPS）
	ns._assign_peer_to_room(941, room, "")
	var slot := int((room.get("peer_slot", {}) as Dictionary).get(941, -1))
	ns._room_accept_seat_races(room, slot, valid.duplicate())
	ns._room_do_move(room, 941, slot, 5)
	var moved: Dictionary = room.get("seat_races", {})
	checks.append(["moved_with_seat", moved.has(5) and not moved.has(slot)])
	ns._room_remove_peer(room, 941)
	checks.append(["cleared_on_leave", not (room.get("seat_races", {}) as Dictionary).has(5)])
	# 开局后锁定：不改座位上的选择，也不因此拒绝准备（否则每回合的准备都按不下去）
	room.state = ns.ROOM_PREP
	var before := str((room.get("seat_races", {}) as Dictionary).get(3, []))
	checks.append(["locked_ready_not_rejected", ns._room_accept_seat_races(room, 3, ["god"])])
	checks.append(["locked_not_changed", str((room.get("seat_races", {}) as Dictionary).get(3, [])) == before])
	ns._rooms.erase(int(room.id))

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("seat_races_validation", failed.is_empty() and not _watchdog_tripped(),
		"%d/%d checks oversized=%.2fms%s" % [checks.size() - failed.size(), checks.size(), huge_ms,
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- C16: 胜负判定的单一实现与两条已确认产品规则 -----------------------------
# 规则（2026-07-28 确认）：
#   1. 第 21 回合的整局归属由**最终战结果**决定，无视之前的血量差。
#   2. 双杀且无正面胜负可依时**记平局**，绝不默认判 A 队胜。
# 同时断言服务端视角与客户端视角对同一场战斗给出一致答案 —— 那正是此前
# "B 队画面显示胜利但按失败结算" 的成因。
func _case_team_outcome_rules() -> void:
	_arm_watchdog()
	var checks: Array = []

	# 规则 1：只有第 21 回合的 PVP 按那一战判整局。血量差故意设成与战果相反。
	checks.append(["r21_pvp_battle_decides", TeamOutcome.run_outcome({
		"completed_round": 21, "final_round": 21,
		"hp_a": 1, "hp_b": 50, "kind": "pvp", "battle_a_wins": true}) == TeamOutcome.TEAM_A])
	checks.append(["r21_pvp_ignores_hp", TeamOutcome.run_outcome({
		"completed_round": 21, "final_round": 21,
		"hp_a": 50, "hp_b": 1, "kind": "pvp", "battle_a_wins": false}) == TeamOutcome.TEAM_B])
	# 第 21 回合 PVP 真打平 -> 平局。必须先看 is_draw：battle_a_wins 在真平局时
	# 是模拟器的偏 A 回退值，直接用就会把平局静默转成 A 胜。
	checks.append(["r21_pvp_draw", TeamOutcome.run_outcome({
		"completed_round": 21, "final_round": 21,
		"hp_a": 10, "hp_b": 10, "kind": "pvp",
		"battle_a_wins": true, "battle_is_draw": true}) == TeamOutcome.DRAW])

	# 第 21 回合恒为最终战，不看 kind 字面值：schedule 给 "final"，
	# prepare_team_state 改写成 "pvp"，两个都必须走同一条分支。
	for k in ["pvp", "final"]:
		checks.append(["r21_kind_%s_uses_battle" % k, TeamOutcome.run_outcome({
			"completed_round": 21, "final_round": 21,
			"hp_a": 1, "hp_b": 50, "kind": k, "battle_a_wins": true}) == TeamOutcome.TEAM_A])

	# 规则 2：21 回合之前唯一依据是水晶血量，战斗胜负不参与。两个方向都要对。
	checks.append(["a_dead_b_wins", TeamOutcome.run_outcome({
		"completed_round": 10, "final_round": 21,
		"hp_a": 0, "hp_b": 5, "kind": "pve", "battle_a_wins": true}) == TeamOutcome.TEAM_B])
	checks.append(["b_dead_a_wins", TeamOutcome.run_outcome({
		"completed_round": 10, "final_round": 21,
		"hp_a": 5, "hp_b": 0, "kind": "pve", "battle_a_wins": false}) == TeamOutcome.TEAM_A])
	# 打赢一场也不等于赢下整局：血量归零方仍判负
	checks.append(["mid_run_battle_win_does_not_decide", TeamOutcome.run_outcome({
		"completed_round": 10, "final_round": 21,
		"hp_a": 0, "hp_b": 7, "kind": "pvp", "battle_a_wins": true}) == TeamOutcome.TEAM_B])
	# 规则 3：同时归零 = 平局（旧实现 hp_a >= hp_b 恒真 -> 判 A 胜）
	checks.append(["both_dead_is_draw", TeamOutcome.run_outcome({
		"completed_round": 10, "final_round": 21,
		"hp_a": 0, "hp_b": 0, "kind": "pve", "battle_a_wins": true}) == TeamOutcome.DRAW])
	# 两队都还活着却判对局结束：不猜胜者
	checks.append(["both_alive_no_guess", TeamOutcome.run_outcome({
		"completed_round": 10, "final_round": 21,
		"hp_a": 5, "hp_b": 5, "kind": "pve", "battle_a_wins": true}) == TeamOutcome.DRAW])

	# 平局时两队都不算赢（team_run_won 单看布尔分不出输/平，必须靠 outcome）
	checks.append(["draw_nobody_wins",
		not TeamOutcome.team_won_run(TeamOutcome.DRAW, TeamOutcome.TEAM_A)
		and not TeamOutcome.team_won_run(TeamOutcome.DRAW, TeamOutcome.TEAM_B)])

	# 服务端视角 vs 客户端视角必须一致：PVP 两队恰好一胜一负，PVE 各自独立
	var res_a := {"player_wins": true}
	var res_b := {"player_wins": false}
	var srv_a: bool = TeamOutcome.team_wins_battle(res_a, res_b, "pvp", TeamOutcome.TEAM_A)
	var srv_b: bool = TeamOutcome.team_wins_battle(res_a, res_b, "pvp", TeamOutcome.TEAM_B)
	var cli_a: bool = TeamOutcome.viewer_wins_battle(res_a, "pvp", TeamOutcome.TEAM_A)
	var cli_b: bool = TeamOutcome.viewer_wins_battle(res_a, "pvp", TeamOutcome.TEAM_B)
	checks.append(["pvp_server_client_agree", srv_a == cli_a and srv_b == cli_b])
	checks.append(["pvp_exactly_one_winner", srv_a != srv_b])
	# PVE：两队各打各的怪，可以同时赢或同时输
	var pve_both := TeamOutcome.team_wins_battle({"player_wins": true}, {"player_wins": true}, "pve", TeamOutcome.TEAM_B)
	checks.append(["pve_independent", pve_both == true])

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("team_outcome_rules", failed.is_empty(),
		"%d/%d checks%s" % [checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- B11/C20: 空房回收依据「还有没有人可能回来」，且时钟必须单调 ---------------
# 旧实现只回收 LOBBY 和已打完的房间；进了 PREP 的空房要等 30 分钟，而 RESULT 超时
# 又会把它推回 PREP 重新计时 —— 最长约 40 分钟占着 MAX_ROOMS 名额。
func _case_suspended_room_recycling() -> void:
	_arm_watchdog()
	var checks: Array = []

	# 时钟必须是单调的：墙钟被 NTP 拽动会让所有 TTL / 心跳 / 限流失真
	var t0: float = NetworkService._now()
	var wall: float = NetworkService._wall_now()
	checks.append(["clock_is_monotonic_not_wall", t0 < 1.0e6 and wall > 1.0e9])

	# 有有效 token 的空房 -> suspended，不立刻关
	var room_keep: Dictionary = NetworkService._new_room()
	room_keep.state = NetworkService.ROOM_PREP
	NetworkService._assign_peer_to_room(950, room_keep, "")
	NetworkService._room_reserve_peer(room_keep, 950)   # 掉线保留（token 仍有效）
	var tokens_before: int = NetworkService._room_live_token_count(room_keep)
	NetworkService._cleanup_rooms()
	checks.append(["has_token_suspends_not_closes",
		tokens_before > 0 and bool(room_keep.get("suspended", false))
		and str(room_keep.get("state", "")) != NetworkService.ROOM_CLOSED])

	# 零有效 token 的空房 -> 立刻关（不必等任何 TTL）
	var room_drop: Dictionary = NetworkService._new_room()
	room_drop.state = NetworkService.ROOM_PREP
	NetworkService._assign_peer_to_room(951, room_drop, "")
	NetworkService._room_remove_peer(room_drop, 951)    # 硬移除：token 一并作废
	checks.append(["no_token_closes_immediately",
		NetworkService._room_live_token_count(room_drop) == 0])
	NetworkService._cleanup_rooms()
	checks.append(["no_token_room_gone", str(room_drop.get("state", "")) == NetworkService.ROOM_CLOSED])

	# suspended 房间不进公开列表（正在等原班人马回来，不该被路人加入）
	var listed := false
	for entry in NetworkService._public_room_list():
		if int((entry as Dictionary).get("id", 0)) == int(room_keep.get("id", 0)):
			listed = true
	checks.append(["suspended_hidden_from_list", not listed])

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("suspended_room_recycling", failed.is_empty(),
		"%d/%d checks%s" % [checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- 多进程分片：房间号必须自带路由信息且跨分片不撞 ---------------------------
# 多进程最先坏掉的就是房间号：两个进程各自摇六位随机数，早晚重复；重复之后
# 玩家输房间号加入，系统不知道该去哪个进程。房间号编进分片号就同时解决唯一性和路由。
func _case_shard_routing() -> void:
	_arm_watchdog()
	var checks: Array = []
	var seen: Dictionary = {}
	var overlap := false

	for shard in 4:
		NetworkService._shard_index = shard
		for _i in 30:
			var room: Dictionary = NetworkService._new_room()
			var rid := int(room.get("id", 0))
			# 反解回来必须是同一个分片
			if NetworkConfig.shard_of_room(rid) != shard:
				checks.append(["shard_%d_decode" % shard, false])
			# 端口映射
			if NetworkConfig.port_of_room(rid) != NetworkConfig.SERVER_PORT + shard:
				checks.append(["shard_%d_port" % shard, false])
			# 跨分片不撞号
			if seen.has(rid):
				overlap = true
			seen[rid] = shard
			NetworkService._room_close(room, "shard_test")
			NetworkService._rooms.erase(rid)
	NetworkService._shard_index = 0

	checks.append(["decode_and_port_all_ok", true])   # 上面有错才会 append false
	checks.append(["no_cross_shard_collision", not overlap])
	# 分片 0 保持旧的六位号（单进程行为不变，老玩家习惯不打断）
	NetworkService._shard_index = 0
	var r0: Dictionary = NetworkService._new_room()
	var id0 := int(r0.get("id", 0))
	checks.append(["shard0_stays_6_digits", id0 >= 100000 and id0 <= 999999])
	NetworkService._room_close(r0, "shard_test")
	NetworkService._rooms.erase(id0)

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("shard_routing", failed.is_empty(),
		"%d 个房间号跨 4 分片无碰撞=%s%s" % [seen.size(), not overlap,
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- B2: replay 压缩打包的往返与防护 ------------------------------------------
# replay 现在以「服务端压缩后的字节」下发。新增的解压路径要挡住两件事：
#   ① 解压炸弹 —— 几 KB 的压缩包解出几 GB，把客户端内存吃光
#   ② 损坏/伪造的字节 —— 不能让它变成崩溃，只能安静地失败
func _case_replay_pack_roundtrip() -> void:
	_arm_watchdog()
	var checks: Array = []

	# 往返：打包再解包必须拿回一样的内容
	var sample := {
		"kind": "pvp",
		"roster": [{"uid": "a", "hp": 100}, {"uid": "b", "hp": 250}],
		"frames": [],
		"result": {"player_wins": true, "is_draw": false},
	}
	for i in 400:   # 撑出一点体积，压缩率才有意义
		(sample["frames"] as Array).append([i, 1.5, 2.5, 100, true, "x"])
	var packed: PackedByteArray = NetworkService._pack_replay(sample)
	var back: Dictionary = NetworkService._unpack_replay(packed)
	checks.append(["roundtrip_kind", str(back.get("kind", "")) == "pvp"])
	checks.append(["roundtrip_frames", (back.get("frames", []) as Array).size() == 400])
	checks.append(["roundtrip_result", bool((back.get("result", {}) as Dictionary).get("player_wins", false))])
	var raw_size := var_to_bytes(sample).size()
	checks.append(["actually_compressed", packed.size() < raw_size])

	# 空 replay -> 空包 -> 空字典（另一队 replay 缺席时走这条）
	checks.append(["empty_is_safe",
		NetworkService._pack_replay({}).is_empty() and NetworkService._unpack_replay(PackedByteArray()).is_empty()])

	# 损坏字节不能崩，只能返回空
	var corrupt := packed.duplicate()
	for i in mini(64, corrupt.size()):
		corrupt[i] = 0xFF
	checks.append(["corrupt_returns_empty", NetworkService._unpack_replay(corrupt).is_empty()])

	# 解压炸弹：把长度头改成一个巨大的值。防护必须在**看头的时候**就拒掉，
	# 不解压、不按那个数去分配内存 —— 所以耗时应当接近 0。
	var bomb := packed.duplicate()
	bomb.encode_u64(0, 8 * 1024 * 1024 * 1024)   # 声称解出 8 GB
	var t0 := Time.get_ticks_msec()
	var bomb_out: Dictionary = NetworkService._unpack_replay(bomb)
	var bomb_ms := Time.get_ticks_msec() - t0
	checks.append(["decompression_bomb_rejected", bomb_out.is_empty()])
	checks.append(["bomb_rejected_without_allocating", bomb_ms < 50])
	# 头被改小（谎报）也不能通过：解出来的长度对不上就拒
	var liar := packed.duplicate()
	liar.encode_u64(0, 16)
	checks.append(["shrunk_header_rejected", NetworkService._unpack_replay(liar).is_empty()])

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("replay_pack_roundtrip", failed.is_empty(),
		"%d->%d B (压缩率 %.3f) 炸弹头被拒耗时 %d ms%s" % [
			raw_size, packed.size(), float(packed.size()) / maxf(1.0, float(raw_size)), bomb_ms,
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- A14 / A13 / B4前半：输入早退、空闲连接回收、结算并发闸 -------------------
func _case_input_and_concurrency_gates() -> void:
	_arm_watchdog()
	var checks: Array = []

	# A14：超限的 prep_mercs 必须**进循环之前**就拒。
	# 旧实现会把整个数组遍历完（只是不再往结果里塞），20 万元素就能让单线程主循环
	# 转 20 万次，期间全服心跳全停。
	var huge: Array = []
	huge.resize(HUGE_N)
	huge.fill("merc_that_does_not_exist")
	var t0 := Time.get_ticks_msec()
	var cleaned: Array = NetworkService._sanitize_prep_merc_ids(huge)
	var elapsed := Time.get_ticks_msec() - t0
	checks.append(["prep_mercs_rejected", cleaned.is_empty()])
	checks.append(["prep_mercs_early_exit", elapsed < 50])
	# 合法输入不能被误伤
	checks.append(["prep_mercs_normal_ok",
		NetworkService._sanitize_prep_merc_ids([]).is_empty()])
	# 单个超长 id 也要被挡（否则可以塞 8 个超长字符串放大字典查找和日志）
	var long_ids: Array = ["A".repeat(5000), "B".repeat(5000)]
	checks.append(["prep_mercs_long_id_dropped",
		NetworkService._sanitize_prep_merc_ids(long_ids).is_empty()])

	# A13：连上但一直不进房间的 peer 有存活上限（否则持续 ping 就能永久占连接槽）
	NetworkService._peer_connected_at[9001] = NetworkService._now() - NetworkService.UNJOINED_PEER_TTL_SEC - 1.0
	NetworkService._peer_connected_at[9002] = NetworkService._now()   # 刚连上，不该被踢
	NetworkService._tick_idle_peers()
	checks.append(["idle_peer_dropped", not NetworkService._peer_connected_at.has(9001)])
	checks.append(["fresh_peer_kept", NetworkService._peer_connected_at.has(9002)])
	NetworkService._peer_connected_at.erase(9002)

	# B4 前半：多个房间同时凑齐棋盘时，结算必须**排队**而不是在同一个调用栈里连着算完。
	# 实测一房一回合最坏 1162 ms —— 20 个房间挤一帧就是 23 秒没有心跳。
	NetworkService._finalize_queue.clear()
	var queued_rooms: Array = []
	for i in 5:
		var room: Dictionary = NetworkService._new_room()
		room.state = NetworkService.ROOM_RESULT   # finalize 已把状态推到 RESULT
		queued_rooms.append(room)
		NetworkService._enqueue_finalize(room)
	checks.append(["all_queued", NetworkService._finalize_queue.size() == 5])
	# 重复入队要幂等（同一房间被多个路径触发时不能算两次）
	NetworkService._enqueue_finalize(queued_rooms[0])
	checks.append(["enqueue_idempotent", NetworkService._finalize_queue.size() == 5])
	# 排队期间房间被回收：出队时静默跳过，不能补算一个不存在的房间。
	# 注意"跳过"**不消耗本帧配额** —— 否则一批死房间会把真正该算的那个饿死。
	# 这里把 5 个全关掉，drain 一次应该把队列走空且一场都不算。
	for room in queued_rooms:
		room.state = NetworkService.ROOM_CLOSED
	NetworkService._drain_finalize_queue()
	checks.append(["drain_skips_closed_rooms", NetworkService._finalize_queue.is_empty()])
	NetworkService._finalize_queue.clear()
	for room in queued_rooms:
		NetworkService._rooms.erase(int(room.get("id", 0)))

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("input_and_concurrency_gates", failed.is_empty(),
		"%d 元素 prep_mercs 耗时 %d ms；%d/%d checks%s" % [
			HUGE_N, elapsed, checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- C23a：64 位种子派生 + 排序稳定性 ----------------------------------------
# 旧种子是 JSON.stringify(parts).hash()：32 位，且依赖 Godot 的 JSON 输出格式。
# 排序则是 sort_custom（**不稳定排序**）+ 无次级键 —— 平手元素的相对顺序由初始
# 排列决定，而其中两处排的是**攻击目标**，顺序一变整场战斗就变。
func _case_seed_and_stable_sort() -> void:
	_arm_watchdog()
	var checks: Array = []

	# FNV-1a 64 的标准测试向量（来自规范）。对上说明溢出回绕、编码顺序都对。
	# 不对的话说明 GDScript 的 int 溢出行为和假设不符 —— 那是必须立刻知道的事。
	checks.append(["fnv_empty", RngService.fnv1a64("") == RngService.FNV64_OFFSET_BASIS])
	checks.append(["fnv_a", RngService.fnv1a64("a") == -5808556873153909620])
	checks.append(["fnv_foobar", RngService.fnv1a64("foobar") == -8821353812377114648])

	# 确实用满 64 位：一批种子里应该出现超过 32 位能表示的值
	var wide := false
	var seeds: Dictionary = {}
	for r in 64:
		var s: int = RngService.fnv1a64(RngService.canonical_parts([123456789, r, "pvp"]))
		if absi(s) > 0x7FFFFFFF:
			wide = true
		seeds[s] = true
	checks.append(["uses_full_64bit", wide])
	checks.append(["no_collision_in_64", seeds.size() == 64])

	# 类型标记：int 1 和 String "1" 不能撞
	checks.append(["type_tagged",
		RngService.canonical_parts([1]) != RngService.canonical_parts(["1"])])
	# 同样的输入必须给同样的种子（可复现是种子存在的意义）
	checks.append(["deterministic",
		RngService.fnv1a64(RngService.canonical_parts([7, "pvp"]))
		== RngService.fnv1a64(RngService.canonical_parts([7, "pvp"]))])

	# 排序稳定性：**打乱输入顺序后，排序结果必须一致**。
	# 这是"次级键有没有真的生效"唯一靠谱的验法 —— 没有次级键时，
	# 不稳定排序会让平手元素跟着初始排列走。
	var stable := true
	var reference: Array = []
	for attempt in 12:
		var pool: Array = []
		for i in 8:
			# 四个单位距离完全相同（平手），四个各不相同
			pool.append({"uid": "u%d" % i, "d": 100.0 if i < 4 else float(100 + i)})
		# 每次用不同的排列喂进去
		for i in range(pool.size() - 1, 0, -1):
			var j := (attempt * 7 + i * 13) % (i + 1)
			var tmp = pool[i]
			pool[i] = pool[j]
			pool[j] = tmp
		pool.sort_custom(func(a, b):
			if not is_equal_approx(float(a.d), float(b.d)):
				return float(a.d) < float(b.d)
			return str(a.uid) < str(b.uid)
		)
		var order: Array = []
		for u in pool:
			order.append(str(u.uid))
		if attempt == 0:
			reference = order
		elif order != reference:
			stable = false
	checks.append(["sort_stable_under_permutation", stable])

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("seed_and_stable_sort", failed.is_empty(),
		"%d/%d checks%s" % [checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- B5：房间快照的存读往返 --------------------------------------------------
# 重点不是"能存能读"，而是三条容易写错的边界：
#   ① peer 状态必须清空（存档里的 peer_id 重启后全部失效）
#   ② 时间必须按相对量重建（单调时钟重启归零，存绝对值 = 全部立刻到期或永不到期）
#   ③ 版本/协议对不上要整份丢弃，不能用语义可能变了的快照恢复对局
func _case_room_snapshot_roundtrip() -> void:
	_arm_watchdog()
	var checks: Array = []

	# 造一个"打到一半"的房间
	NetworkService._rooms.clear()
	NetworkService._token_seat.clear()
	var room: Dictionary = NetworkService._new_room()
	var rid := int(room.id)
	room.state = NetworkService.ROOM_PREP
	room.round_index = 7
	room.slot_states = ["player", "player", "dummy", "player", "empty", "empty"]
	room.team_hp = [42, 37]
	room.leader_slot = 3
	room.peer_slot = {8001: 0, 8002: 1}         # 重启后必须清掉
	room.boards = {0: {"junk": true}}           # 缓存类，不入快照
	NetworkService._token_seat["tok_a"] = {"room_id": rid, "slot": 0}
	var seat_tokens: Dictionary = room.seat_tokens
	seat_tokens[0] = "tok_a"
	room.seat_tokens = seat_tokens
	room.seat_races = {0: ["god", "dark", "undead", "human"]}   # 出战种族（协议 28）
	NetworkService._save_rooms_snapshot()

	# 模拟重启：清空内存，重新读
	NetworkService._rooms.clear()
	NetworkService._token_seat.clear()
	NetworkService._peer_room.clear()
	NetworkService._load_rooms_snapshot()

	var back: Dictionary = NetworkService._rooms.get(rid, {})
	checks.append(["room_restored", not back.is_empty()])
	if not back.is_empty():
		checks.append(["round_kept", int(back.get("round_index", 0)) == 7])
		checks.append(["phase_kept", str(back.get("state", "")) == NetworkService.ROOM_PREP])
		checks.append(["hp_kept", str(back.get("team_hp", [])) == str([42, 37])])
		checks.append(["leader_kept", int(back.get("leader_slot", -1)) == 3])
		# 出战种族不入快照的话，重启后所有座位回落默认四族，下一回合商店突然变样
		checks.append(["seat_races_kept", str((back.get("seat_races", {}) as Dictionary).get(0, [])) \
			== str(["god", "dark", "undead", "human"])])
		# ① peer 状态清空
		checks.append(["peer_slot_cleared", (back.get("peer_slot", {}) as Dictionary).is_empty()])
		# 缓存类字段不入快照
		checks.append(["boards_not_persisted", (back.get("boards", {}) as Dictionary).is_empty()])
		# 占着的座位都进宽限，等原主人带 token 回来
		var deadline: Dictionary = back.get("reserve_deadline", {})
		checks.append(["player_seats_reserved", deadline.size() == 3])
		# ② 宽限截止必须是"现在 + 宽限"，不是存档里那个已经失效的绝对值
		var ok_deadline := true
		for slot in deadline.keys():
			var remain: float = float(deadline[slot]) - NetworkService._now()
			if remain <= 0.0 or remain > NetworkService.RESERVE_GRACE_SEC + 1.0:
				ok_deadline = false
		checks.append(["deadline_rebased", ok_deadline])
		# 时间基准重建后 age 应当接近 0，而不是一个巨大的数
		var age: float = NetworkService._now() - float(back.get("state_started_at", 0.0))
		checks.append(["elapsed_rebased", age >= 0.0 and age < 60.0])
	checks.append(["token_seat_restored", NetworkService._token_seat.has("tok_a")])

	# ③ 协议号对不上 -> 整份丢弃
	NetworkService._rooms.clear()
	var bad := {
		"version": NetworkService.ROOM_SNAPSHOT_VERSION,
		"protocol": 999999, "shard": 0, "server_epoch": 1, "saved_at_wall": 0.0,
		"rooms": [{"id": 424243, "state": NetworkService.ROOM_PREP}],
		"token_seat": {}, "public_token_seat": {},
	}
	SaveManager.atomic_write_bytes(NetworkService._snapshot_path(), var_to_bytes(bad))
	NetworkService._load_rooms_snapshot()
	checks.append(["protocol_mismatch_discarded", NetworkService._rooms.is_empty()])

	SaveManager.remove_all_variants(NetworkService._snapshot_path())
	NetworkService._rooms.clear()
	NetworkService._token_seat.clear()

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("room_snapshot_roundtrip", failed.is_empty(),
		"%d/%d checks%s" % [checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- E1：错误分级 -------------------------------------------------------------
# 唯一真正要紧的不变量：**只有 terminal 才允许清凭证**。
# 反过来（把可恢复故障当失效）就是把"几秒后能自愈"升级成"永久回不去这一局"。
func _case_error_classification() -> void:
	_arm_watchdog()
	var checks: Array = []

	# 终局：凭证确实没了
	for code in ["token_unknown", "room_gone", "match_over", "protocol_mismatch", "kicked"]:
		checks.append(["terminal_" + code, NetError.should_clear_credentials(code)])
	# 可重试 / 传输：**绝不能清凭证**
	for code in ["seat_busy", "server_busy", "replay_timeout", "match_state_timeout", "invalid_replay"]:
		checks.append(["keeps_creds_" + code, not NetError.should_clear_credentials(code)])

	# 未登记的错误码必须**保守**地按可重试处理。
	# 反过来的话，以后谁加一个错误码忘了登记，玩家就会莫名其妙被踢出对局。
	checks.append(["unknown_code_is_safe",
		not NetError.should_clear_credentials("some_code_nobody_registered_yet")])
	checks.append(["unknown_code_not_terminal",
		NetError.class_of("some_code_nobody_registered_yet") != NetError.TERMINAL])

	# 三档必须互斥且完整
	checks.append(["seat_busy_is_retryable",
		NetError.class_of("seat_busy") == NetError.RETRYABLE])
	checks.append(["replay_timeout_is_transport",
		NetError.class_of("replay_timeout") == NetError.TRANSPORT])
	checks.append(["class_names_readable",
		NetError.class_name_of("token_unknown") == "terminal"
		and NetError.class_name_of("seat_busy") == "retryable"
		and NetError.class_name_of("replay_timeout") == "transport"])

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("error_classification", failed.is_empty(),
		"%d/%d checks%s" % [checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- E2：状态信封的三条应用规则 ----------------------------------------------
# 这三条是整个信封存在的理由，写错任何一条都会退回到 B6/C17 的老问题：
#   ① seq 不前进 -> 丢弃（迟到包不能覆盖新状态）
#   ② seq 跳号   -> 直接应用（全量快照 ⇒ 漏包自愈，不需要补差）
#   ③ epoch 变了 -> 无条件接受（服务器重启后 seq 从 0 重来，
#                   没有这条客户端会把新包当倒退，从此永不同步）
func _case_room_state_envelope() -> void:
	_arm_watchdog()
	var checks: Array = []
	var ns := NetworkService

	# 让客户端分支生效（_dedicated_server 为真时 room_state 不会被当客户端消息处理）
	var prev_dedicated: bool = ns._dedicated_server
	var prev_state: int = ns.state
	ns._dedicated_server = false
	ns.state = ns.SessionState.READY
	ns._applied_epoch = 0
	ns._applied_seq = 0
	ns.session_token = ""

	ns._rpc_room_state(_envelope(100, 5, {"my_slot": 2, "round_id": 7, "leader_slot": 1,
		"slot_states": ["player","player","player","empty","empty","empty"],
		"ready": [true,false,false,false,false,false], "phase": "prep"}))
	checks.append(["first_applied", ns.team_local_slot == 2 and ns.server_round_index == 7])

	# ① 迟到包（seq 更小）必须被丢弃
	ns._rpc_room_state(_envelope(100, 3, {"my_slot": 5, "round_id": 1, "leader_slot": 4,
		"slot_states": [], "ready": [], "phase": "lobby"}))
	checks.append(["stale_seq_dropped", ns.team_local_slot == 2 and ns.server_round_index == 7])
	# 同号也算不前进
	ns._rpc_room_state(_envelope(100, 5, {"my_slot": 4, "round_id": 2, "leader_slot": 0,
		"slot_states": [], "ready": [], "phase": "lobby"}))
	checks.append(["same_seq_dropped", ns.team_local_slot == 2])

	# ② 跳号必须直接应用（漏包自愈 —— 这是不做 delta 换来的）
	ns._rpc_room_state(_envelope(100, 9, {"my_slot": 3, "round_id": 9, "leader_slot": 3,
		"slot_states": [], "ready": [], "phase": "battle"}))
	checks.append(["gap_applied", ns.team_local_slot == 3 and ns.server_round_index == 9])

	# ③ epoch 变了（服务器重启）-> 即使 seq 变小也要接受
	ns._rpc_room_state(_envelope(200, 1, {"my_slot": 0, "round_id": 1, "leader_slot": 0,
		"slot_states": [], "ready": [], "phase": "lobby"}))
	checks.append(["new_epoch_accepted", ns.team_local_slot == 0 and ns.server_round_index == 1])

	# 重连中收到"别人的 token"必须忽略 —— 那是握手期被临时分进别的房间，
	# 覆盖掉手里真正的重连凭证会让旧座位再也回不去
	ns.state = ns.SessionState.RECONNECTING
	ns.session_token = "my_real_token"
	ns._applied_epoch = 200
	ns._applied_seq = 1
	ns._rpc_room_state(_envelope(200, 2, {"my_slot": 5, "round_id": 99, "leader_slot": 5,
		"slot_states": [], "ready": [], "phase": "lobby", "session_token": "someone_else"}))
	checks.append(["foreign_token_ignored", ns.team_local_slot == 0 and ns.session_token == "my_real_token"])

	ns._dedicated_server = prev_dedicated
	ns.state = prev_state
	ns.session_token = ""
	ns._applied_epoch = 0
	ns._applied_seq = 0

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("room_state_envelope", failed.is_empty(),
		"%d/%d checks%s" % [checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

func _envelope(epoch: int, seq: int, payload: Dictionary) -> Dictionary:
	return {
		"protocol": NetworkConfig.NETWORK_PROTOCOL_VERSION,
		"server_epoch": epoch, "room_id": 424242, "state_seq": seq,
		"message_type": "room_state", "payload": payload,
	}

# --- E3：结算确认与明确退出 ---------------------------------------------------
func _case_result_ack_and_leave() -> void:
	_arm_watchdog()
	var checks: Array = []
	var ns := NetworkService

	# --- 结算确认（C7 / B15）---
	var room: Dictionary = ns._new_room()
	room.state = ns.ROOM_RESULT
	room.state_started_at = ns._now()
	room.slot_states = ["player", "player", "dummy", "player", "empty", "empty"]
	room.battle_id = "test:1:1"
	room.result_acks = {}
	# slot 0 和 1 在线，slot 3 掉线（不在 peer_slot 里）
	room.peer_slot = {8101: 0, 8102: 1}
	ns._peer_room[8101] = int(room.id)
	ns._peer_room[8102] = int(room.id)

	checks.append(["blocked_before_any_ack", not ns._room_result_acks_complete(room)])
	(room.result_acks as Dictionary)[0] = "test:1:1"
	checks.append(["blocked_with_partial_ack", not ns._room_result_acks_complete(room)])
	(room.result_acks as Dictionary)[1] = "test:1:1"
	# slot 3 是 player 但掉线 -> **不等他**（已确认的产品规则）；slot 2 是 AI -> 服务器代过
	checks.append(["offline_and_ai_not_waited", ns._room_result_acks_complete(room)])

	# 迟到的旧 ACK 不能顶替本场
	room.battle_id = "test:2:9"
	room.result_acks = {0: "test:1:1", 1: "test:1:1"}
	checks.append(["stale_ack_does_not_count", not ns._room_result_acks_complete(room)])

	# 兜底：某个在线真人卡死时不能让全房无限等
	room.state_started_at = ns._now() - ns.RESULT_ACK_TIMEOUT_SEC - 1.0
	checks.append(["ack_timeout_backstop", ns._room_result_acks_complete(room)])

	# run_over 的房间不该被推进（否则回合会越过 FINAL_ROUND）
	room.state_started_at = ns._now()
	room.run_over = true
	var round_before := int(room.get("round_index", 1))
	ns._room_begin_next_prep(room)
	checks.append(["run_over_not_advanced", int(room.get("round_index", 1)) == round_before])

	ns._peer_room.erase(8101)
	ns._peer_room.erase(8102)
	ns._rooms.erase(int(room.id))

	# --- 明确退出的幂等（B8 / R1）---
	# 同一个 request_id 重发必须拿回同一份结果，而不是被当成新请求 ——
	# 回执丢了、客户端重启后重试都会走到这条。
	ns._leave_tombstones.clear()
	var rid := "leave_req_test_1"
	ns._leave_tombstones[rid] = ns._now()
	checks.append(["leave_tombstone_recorded", ns._leave_tombstones.has(rid)])
	# tombstone 存在**房间之外** —— 最后一人退出会立刻关房，他仍要能重取回执
	var doomed: Dictionary = ns._new_room()
	ns._room_close(doomed, "test")
	ns._rooms.erase(int(doomed.id))
	checks.append(["tombstone_survives_room_close", ns._leave_tombstones.has(rid)])
	ns._leave_tombstones.clear()

	# 分级：技术失败绝不能清凭证
	checks.append(["tech_failure_keeps_creds",
		not NetError.should_clear_credentials("match_state_timeout")
		and not NetError.should_clear_credentials("replay_timeout")])

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("result_ack_and_leave", failed.is_empty(),
		"%d/%d checks%s" % [checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- E4：交易幂等回执 ---------------------------------------------------------
# 关键点不是"重复请求会被拒"，而是**重复请求会拿回同一份成功结果，且副作用只发生一次**。
# 直接拒掉重试和执行两次一样糟：前者让玩家白丢一件宝物，后者让他被扣两次代价。
func _case_tx_idempotency() -> void:
	_arm_watchdog()
	var checks: Array = []
	var ns := NetworkService

	var room: Dictionary = ns._new_room()
	room.state = ns.ROOM_PREP
	room.slot_states = ["player", "player", "player", "player", "empty", "empty"]
	room.team_hp = [30, 30]
	var slot := 0

	# --- 宝物选择 ---
	var offers: Dictionary = {}
	offers[slot] = {"round": 3, "candidates": ["tr_a", "tr_b", "tr_c"], "refresh_index": 0}
	room.treasure_offer = offers

	var rid_choice := "rid_choice_1"
	var first := ns._room_apply_treasure_choice(room, slot, "tr_a")
	first["tid"] = "tr_a"
	ns._tx_record(room, slot, rid_choice, "treasure_choice", first)
	checks.append(["choice_first_ok", bool(first.get("ok", false))])
	checks.append(["choice_owned_once", (first.get("owned", []) as Array).size() == 1])

	# 重试：命中回执，**不再执行**。这是 E4 的全部意义 ——
	# 此前 offer 用后即弃，重试只会落到 no_offer，玩家白丢一件宝物。
	var hit := ns._tx_find(room, slot, rid_choice)
	checks.append(["choice_replay_hit", not hit.is_empty()])
	checks.append(["choice_replay_same_tid", str((hit.get("result", {}) as Dictionary).get("tid", "")) == "tr_a"])
	# 副作用不叠加：owned 仍然只有一件
	checks.append(["choice_no_double_apply",
		(ns._room_owned_treasures(room, slot) as Array).size() == 1])
	# 换一个新 rid 才是新单子；此时 offer 已经没了 -> 正常拒绝
	var second := ns._room_apply_treasure_choice(room, slot, "tr_b")
	checks.append(["choice_new_rid_denied", not bool(second.get("ok", false))])

	# --- 宝物刷新 ---
	offers = room.get("treasure_offer", {})
	offers[slot] = {"round": 3, "candidates": ["tr_x", "tr_y", "tr_z"], "refresh_index": 0}
	room.treasure_offer = offers
	var rid_refresh := "rid_refresh_1"
	var r1 := ns._room_apply_treasure_refresh(room, slot)
	ns._tx_record(room, slot, rid_refresh, "treasure_refresh", r1)
	checks.append(["refresh_first_ok", bool(r1.get("ok", false))])
	checks.append(["refresh_index_1", int(r1.get("refresh_index", 0)) == 1])
	var hit_r := ns._tx_find(room, slot, rid_refresh)
	# 重放要给回**同一批候选**：重摇一次等于玩家为一次刷新付两次钱，
	# 而且第一次看到的三个候选再也拿不回来。
	checks.append(["refresh_replay_same_candidates",
		str((hit_r.get("result", {}) as Dictionary).get("candidates", [])) == str(r1.get("candidates", []))])
	checks.append(["refresh_index_not_bumped_twice",
		int(((room.get("treasure_offer", {}) as Dictionary)[slot] as Dictionary).get("refresh_index", 0)) == 1])

	# --- 黄金祭坛 ---
	var hp_before := int((room.get("team_hp", []) as Array)[0])
	var rid_altar := "rid_altar_1"
	var a1 := ns._room_apply_altar(room, slot)
	ns._tx_record(room, slot, rid_altar, "altar", a1)
	checks.append(["altar_first_ok", bool(a1.get("ok", false))])
	checks.append(["altar_hp_minus_one",
		int((room.get("team_hp", []) as Array)[0]) == hp_before - 1])
	checks.append(["altar_replay_hit", not ns._tx_find(room, slot, rid_altar).is_empty()])
	# 重放不再扣 HP、不再消耗次数
	checks.append(["altar_no_double_charge",
		int((room.get("team_hp", []) as Array)[0]) == hp_before - 1
		and int((room.get("altar_uses", {}) as Dictionary).get(slot, 0)) == 1])
	# 阶段门仍然有效
	room.state = ns.ROOM_BATTLE
	checks.append(["altar_phase_gate", not bool((ns._room_apply_altar(room, slot) as Dictionary).get("ok", false))])
	room.state = ns.ROOM_PREP

	# --- 回执日志的边界 ---
	# 定长：不能让恶意客户端用无限个 request_id 把房间内存撑爆
	for i in range(ns.TX_LOG_PER_SLOT + 8):
		ns._tx_record(room, slot, "flood_%d" % i, "altar", {"ok": false})
	var entries: Array = (room.get("tx_log", {}) as Dictionary).get(slot, [])
	checks.append(["tx_log_bounded", entries.size() == ns.TX_LOG_PER_SLOT])
	checks.append(["tx_log_keeps_newest", str((entries[-1] as Dictionary).get("rid", "")) == "flood_%d" % (ns.TX_LOG_PER_SLOT + 7)])
	# 座位释放要连回执一起清（否则新玩家会继承前任的交易记录）
	checks.append(["tx_log_in_seat_maps", ns.SEAT_SLOT_MAPS.has("tx_log")])
	ns._clear_seat_metadata(room, slot)
	checks.append(["tx_log_cleared_with_seat",
		not (room.get("tx_log", {}) as Dictionary).has(slot)])
	# 重启后必须还在：丢了回执日志 = 同一笔交易被执行两次
	checks.append(["tx_log_persisted", ns.PERSISTED_ROOM_FIELDS.has("tx_log")])

	# --- 客户端侧去重 ---
	ns._tx_pending.clear()
	ns._tx_done.clear()
	var crid := ns._tx_begin("altar", [])
	checks.append(["client_pending_registered", ns._tx_pending.has(crid)])
	checks.append(["client_first_reply_accepted", ns._tx_consume(crid)])
	# 慢包和重发的回复都到了 -> 第二份必须丢掉，否则金币加两次
	checks.append(["client_duplicate_reply_dropped", not ns._tx_consume(crid)])
	checks.append(["client_unknown_rid_dropped", not ns._tx_consume("never_sent_this")])
	ns._tx_pending.clear()
	ns._tx_done.clear()

	ns._rooms.erase(int(room.id))

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("tx_idempotency", failed.is_empty(),
		"%d/%d checks%s" % [checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- P1：备战经济账本 ---------------------------------------------------------
func _case_economy_ledger() -> void:
	_arm_watchdog()
	var checks: Array = []

	# 造两个单位定义：一个普通、一个带 shop_cost_multiplier。
	# 2026-08-20 起数据表里**已没有**带乘数的棋子（undead_small 的乘数已删除），
	# 这里保留合成定义是刻意的 —— 账本必须对「以后又加了带乘数的棋子」也成立。
	var plain := {"id": "plain", "cost": 10}
	var cheap := {"id": "undead_small", "cost": 10, "shop_cost_multiplier": 0.5}

	# --- 定价 ---
	checks.append(["cost_plain", EconomyLedger.unit_cost(plain, []) == 10])
	checks.append(["cost_multiplier", EconomyLedger.unit_cost(cheap, []) == 5])
	checks.append(["cost_money_discount", EconomyLedger.unit_cost(cheap, ["money_discount"]) == 4])

	# --- 套利：这正是换成实付基数要堵的洞 ---
	# 旧规则退款 = floor(定价表 cost × star × 0.5)，与实付无关。
	# clearance 折扣买两个 5→3 金 = 6 金，合成 2 星，旧规则退 floor(10×2×0.5)=10 → 净 +4。
	var prep := EconomyLedger.new_prep(100)
	prep["shop"] = {"offer_id": "off1", "offers": [cheap, cheap], "sold": [false, false], "refresh_uses": 0}
	var ctx := {"owned_treasures": ["money_discount"], "roster_cap": 64}
	var b1 := EconomyLedger.apply(prep, "buy", {"shop_index": 0, "offer_id": "off1"}, ctx)
	var b2 := EconomyLedger.apply(prep, "buy", {"shop_index": 1, "offer_id": "off1"}, ctx)
	checks.append(["buy_ok", bool(b1.get("ok", false)) and bool(b2.get("ok", false))])
	var paid := -int(b1.get("delta", 0)) - int(b2.get("delta", 0))
	checks.append(["buy_paid_discounted", paid == 8])   # 4 + 4
	var uid1 := str((b1.get("result", {}) as Dictionary).get("uid", ""))
	var uid2 := str((b2.get("result", {}) as Dictionary).get("uid", ""))
	var mg := EconomyLedger.apply(prep, "merge", {"uids": [uid1, uid2]}, ctx)
	checks.append(["merge_ok", bool(mg.get("ok", false))])
	checks.append(["merge_star2", int((mg.get("result", {}) as Dictionary).get("star", 0)) == 2])
	# cost_basis 相加，这是"退款按实付"的全部依据
	checks.append(["merge_cost_basis_summed",
		int((mg.get("result", {}) as Dictionary).get("cost_basis", 0)) == 8])
	var sl := EconomyLedger.apply(prep, "sell", {"uid": str((mg.get("result", {}) as Dictionary).get("uid", ""))}, ctx)
	checks.append(["sell_ok", bool(sl.get("ok", false))])
	# 关键断言：一买一卖**不可能赚钱**。旧规则这里是 +4。
	var net := int(prep.get("gold", 0)) - 100
	checks.append(["no_arbitrage_profit", net <= 0])
	checks.append(["sell_refund_is_half_of_paid", int(sl.get("delta", 0)) == 4])   # floor(8 × 0.5)

	# --- 购买的各种拒绝 ---
	prep = EconomyLedger.new_prep(3)
	prep["shop"] = {"offer_id": "off2", "offers": [plain], "sold": [false], "refresh_uses": 0}
	var poor := EconomyLedger.apply(prep, "buy", {"shop_index": 0, "offer_id": "off2"}, {"owned_treasures": []})
	checks.append(["buy_denied_poor", not bool(poor.get("ok", false))
		and str(poor.get("error", "")) == "not_enough_gold"])
	checks.append(["denied_leaves_gold", int(prep.get("gold", 0)) == 3])
	checks.append(["denied_no_revision_bump", int(prep.get("revision", 0)) == 0])

	prep = EconomyLedger.new_prep(100)
	prep["shop"] = {"offer_id": "off3", "offers": [plain], "sold": [false], "refresh_uses": 0}
	var stale := EconomyLedger.apply(prep, "buy", {"shop_index": 0, "offer_id": "OLD"}, {"owned_treasures": []})
	# 刷新之后旧的购买请求必须失效，否则"看到便宜货 → 刷新 → 补发购买"能买到已不存在的商品
	checks.append(["buy_denied_stale_offer", str(stale.get("error", "")) == "stale_offer"])
	var ok1 := EconomyLedger.apply(prep, "buy", {"shop_index": 0, "offer_id": "off3"}, {"owned_treasures": []})
	var twice := EconomyLedger.apply(prep, "buy", {"shop_index": 0, "offer_id": "off3"}, {"owned_treasures": []})
	checks.append(["buy_once_only", bool(ok1.get("ok", false)) and str(twice.get("error", "")) == "already_sold"])

	# --- 出售的各种拒绝 ---
	var ghost := EconomyLedger.apply(prep, "sell", {"uid": "u999"}, {})
	checks.append(["sell_unknown_uid", str(ghost.get("error", "")) == "unknown_uid"])
	var sold_uid := str((ok1.get("result", {}) as Dictionary).get("uid", ""))
	EconomyLedger.apply(prep, "sell", {"uid": sold_uid}, {})
	var resell := EconomyLedger.apply(prep, "sell", {"uid": sold_uid}, {})
	checks.append(["sell_once_only", str(resell.get("error", "")) == "unknown_uid"])

	# --- 合成的各种拒绝 ---
	prep = EconomyLedger.new_prep(100)
	prep["shop"] = {"offer_id": "o", "offers": [plain, cheap], "sold": [false, false], "refresh_uses": 0}
	var ma := EconomyLedger.apply(prep, "buy", {"shop_index": 0, "offer_id": "o"}, {"owned_treasures": []})
	var mb := EconomyLedger.apply(prep, "buy", {"shop_index": 1, "offer_id": "o"}, {"owned_treasures": []})
	var ua := str((ma.get("result", {}) as Dictionary).get("uid", ""))
	var ub := str((mb.get("result", {}) as Dictionary).get("uid", ""))
	checks.append(["merge_mismatched_denied",
		str((EconomyLedger.apply(prep, "merge", {"uids": [ua, ub]}, {}) as Dictionary).get("error", "")) == "mismatched_units"])
	# 同一个单位不能自己合自己 —— 否则一个单位就能无限升星
	checks.append(["merge_self_denied",
		str((EconomyLedger.apply(prep, "merge", {"uids": [ua, ua]}, {}) as Dictionary).get("error", "")) == "duplicate_uid"])
	checks.append(["merge_ghost_denied",
		str((EconomyLedger.apply(prep, "merge", {"uids": [ua, "u999"]}, {}) as Dictionary).get("error", "")) == "unknown_uid"])
	# 失败的合成不能吃掉来源单位
	checks.append(["failed_merge_keeps_units",
		(prep.get("roster", {}) as Dictionary).has(ua) and (prep.get("roster", {}) as Dictionary).has(ub)])

	# --- 商店刷新 ---
	prep = EconomyLedger.new_prep(100)
	prep["shop"] = {"offer_id": "o", "offers": [plain], "sold": [true], "refresh_uses": 0}
	var r1 := EconomyLedger.apply(prep, "shop_refresh", {},
		{"owned_treasures": [], "rolled_offers": [plain, cheap], "offer_id": "o2"})
	checks.append(["refresh_first_free", bool(r1.get("ok", false)) and int(r1.get("delta", 0)) == 0])
	checks.append(["refresh_clears_sold",
		not bool(((prep.get("shop", {}) as Dictionary).get("sold", []) as Array)[0])])
	var r2 := EconomyLedger.apply(prep, "shop_refresh", {},
		{"owned_treasures": [], "rolled_offers": [plain], "offer_id": "o3"})
	checks.append(["refresh_second_costs_10", int(r2.get("delta", 0)) == -10])
	var r3 := EconomyLedger.apply(prep, "shop_refresh", {},
		{"owned_treasures": [], "rolled_offers": [plain], "offer_id": "o4"})
	checks.append(["refresh_third_costs_20", int(r3.get("delta", 0)) == -20])
	# **账本自己绝不摇随机**：调用方没预先摇好就直接拒，且不扣钱
	var gold_before_noroll := int(prep.get("gold", 0))
	var noroll := EconomyLedger.apply(prep, "shop_refresh", {}, {"owned_treasures": []})
	checks.append(["refresh_requires_prerolled", str(noroll.get("error", "")) == "no_roll"
		and int(prep.get("gold", 0)) == gold_before_noroll])

	# --- 赌博：服务端开奖 ---
	prep = EconomyLedger.new_prep(100)
	var g_win := EconomyLedger.apply(prep, "gamble", {}, {"roll": 0.1, "gamble_linked": false, "gamble_entitled": true})
	checks.append(["gamble_win_doubles", int(prep.get("gold", 0)) == 200
		and bool((g_win.get("result", {}) as Dictionary).get("won", false))])
	# 每回合只能一次 —— 重连重点也不行
	checks.append(["gamble_once_per_round",
		str((EconomyLedger.apply(prep, "gamble", {}, {"roll": 0.1, "gamble_entitled": true}) as Dictionary).get("error", "")) == "already_used"])
	prep = EconomyLedger.new_prep(100)
	EconomyLedger.apply(prep, "gamble", {}, {"roll": 0.9, "gamble_linked": false, "gamble_entitled": true})
	checks.append(["gamble_loss_keeps_20pct", int(prep.get("gold", 0)) == 20])
	prep = EconomyLedger.new_prep(100)
	EconomyLedger.apply(prep, "gamble", {}, {"roll": 0.9, "gamble_linked": true, "gamble_entitled": true})
	checks.append(["gamble_linked_keeps_50pct", int(prep.get("gold", 0)) == 50])
	prep = EconomyLedger.new_prep(100)
	EconomyLedger.apply(prep, "gamble", {}, {"roll": 0.55, "gamble_linked": true, "gamble_entitled": true})
	checks.append(["gamble_linked_win_at_55", int(prep.get("gold", 0)) == 200])
	# 持有权：没有「慷慨命运」这件宝物就不能开奖。
	# 客户端一直有这道门（PrepFlowController:183），服务端此前没有 —— 改客户端就能白嫖翻倍。
	prep = EconomyLedger.new_prep(100)
	checks.append(["gamble_requires_treasure",
		str((EconomyLedger.apply(prep, "gamble", {}, {"roll": 0.1}) as Dictionary).get("error", "")) == "not_entitled"])
	checks.append(["unentitled_gamble_changes_nothing",
		int(prep.get("gold", 0)) == 100 and not bool(prep.get("gamble_used", true))])
	# 没给 roll 就绝不开奖（防止"忘了传随机数"退化成恒定结果）
	prep = EconomyLedger.new_prep(100)
	checks.append(["gamble_requires_roll",
		str((EconomyLedger.apply(prep, "gamble", {}, {"gamble_entitled": true}) as Dictionary).get("error", "")) == "no_roll"])

	# --- 回合重置 ---
	prep = EconomyLedger.new_prep(100)
	EconomyLedger.apply(prep, "gamble", {}, {"roll": 0.1, "gamble_entitled": true})
	EconomyLedger.apply(prep, "shop_refresh", {}, {"rolled_offers": [], "offer_id": "x"})
	var gold_kept := int(prep.get("gold", 0))
	EconomyLedger.reset_round(prep)
	checks.append(["reset_clears_gamble", not bool(prep.get("gamble_used", false))])
	checks.append(["reset_clears_refresh_uses",
		int((prep.get("shop", {}) as Dictionary).get("refresh_uses", -1)) == 0])
	# 金币和 roster 是跨回合累积的，重置绝不能碰
	checks.append(["reset_keeps_gold", int(prep.get("gold", 0)) == gold_kept])

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("economy_ledger", failed.is_empty(),
		"%d/%d checks%s" % [checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

# --- P1：账本接进服务端之后的行为 ---------------------------------------------
func _case_economy_server_wiring() -> void:
	_arm_watchdog()
	var checks: Array = []
	var ns := NetworkService

	# 默认必须是全关。漏配时的行为要等于"这批改动没上线"。
	checks.append(["flags_default_off", not ns.economy_enabled() and not ns.economy_authoritative()])
	# 只开 authoritative 是配置错误 —— 必须按"没上线"处理，不是按"权威"处理
	ServerFlags._values = {"economy_ledger_authoritative": true}
	ServerFlags._loaded = true
	checks.append(["authoritative_implies_enabled", not ns.economy_authoritative()])

	ServerFlags._values = {"economy_ledger_enabled": true}
	checks.append(["enabled_alone_is_shadow", ns.economy_enabled() and not ns.economy_authoritative()])

	var room: Dictionary = ns._new_room()
	room.state = ns.ROOM_PREP
	room.slot_states = ["player", "empty", "empty", "empty", "empty", "empty"]

	# 座位账本按需创建，起始金币与单机一致
	var prep := ns._room_prep(room, 0)
	checks.append(["prep_created_with_start_gold", int(prep.get("gold", -1)) == GameState.START_GOLD])
	checks.append(["prep_stored_on_room", (room.get("prep", {}) as Dictionary).has(0)])

	# 未知动作、越界 merge 一律拒，且不动账本
	checks.append(["unknown_action_rejected",
		str((ns._room_apply_economy(room, 0, "print_money", {}) as Dictionary).get("error", "")) == "unknown_action"])
	checks.append(["oversized_merge_rejected",
		str((ns._room_apply_economy(room, 0, "merge",
			{"uids": ["a", "b", "c", "d", "e"]}) as Dictionary).get("error", "")) == "bad_request"])

	# 阶段门：战斗/结算期不能买卖
	room.state = ns.ROOM_BATTLE
	checks.append(["economy_blocked_outside_prep",
		str((ns._room_apply_economy(room, 0, "shop_refresh", {}) as Dictionary).get("error", "")) == "bad_phase"])
	room.state = ns.ROOM_PREP

	# 刷新用的是服务端摇的商品 + 服务端发的 offer_id
	var r := ns._room_apply_economy(room, 0, "shop_refresh", {})
	checks.append(["server_rolls_shop", bool(r.get("ok", false))])
	var shop: Dictionary = (ns._room_prep(room, 0).get("shop", {}) as Dictionary)
	checks.append(["shop_offer_id_issued", not str(shop.get("offer_id", "")).is_empty()])
	checks.append(["shop_offers_filled",
		(shop.get("offers", []) as Array).size() == GameState.SHOP_UNIT_SLOTS])

	# 客户端拿不到 offer_id 就买不到东西（伪造的 offer_id 一律 stale）
	checks.append(["forged_offer_id_rejected",
		str((ns._room_apply_economy(room, 0, "buy",
			{"shop_index": 0, "offer_id": "forged"}) as Dictionary).get("error", "")) == "stale_offer"])

	# 赌博：没有「慷慨命运」时服务端直接拒（持有权按**服务端记录的**宝物判，
	# 不按客户端自报 —— 否则伪造一件宝物就能开奖）
	checks.append(["gamble_entitlement_from_server_owned",
		str((ns._room_apply_economy(room, 0, "gamble", {}) as Dictionary).get("error", "")) == "not_entitled"])
	var owned_map: Dictionary = room.get("owned_treasures", {})
	owned_map[0] = ["money_generous_fate"]
	room.owned_treasures = owned_map
	# 服务端开奖：客户端 payload 里塞什么都不影响结果
	var g := ns._room_apply_economy(room, 0, "gamble", {"won": true, "roll": 0.0})
	checks.append(["gamble_server_rolled", bool(g.get("ok", false))
		and (g.get("result", {}) as Dictionary).has("won")])
	checks.append(["gamble_once", str((ns._room_apply_economy(room, 0, "gamble", {}) as Dictionary).get("error", "")) == "already_used"])

	# 账本进 room_state（重连的人靠它拿到权威商店与余额）
	var payload := ns._build_room_state(room, 0)
	var eco: Dictionary = payload.get("economy", {})
	checks.append(["room_state_carries_economy", not eco.is_empty()
		and eco.has("gold") and eco.has("shop") and eco.has("roster") and eco.has("revision")])
	checks.append(["room_state_reports_shadow_mode", not bool(eco.get("authoritative", true))])

	# 回合重置：清赌博/刷新次数并换新商店，但**不清金币**
	var gold_kept := int(ns._room_prep(room, 0).get("gold", 0))
	var old_offer_id := str(((ns._room_prep(room, 0).get("shop", {})) as Dictionary).get("offer_id", ""))
	room.state = ns.ROOM_RESULT
	room.battle_id = ""
	ns._room_begin_next_prep(room)
	var prep2 := ns._room_prep(room, 0)
	checks.append(["round_reset_keeps_gold", int(prep2.get("gold", -1)) == gold_kept])
	checks.append(["round_reset_clears_gamble", not bool(prep2.get("gamble_used", true))])
	checks.append(["round_reset_new_offer_id",
		str((prep2.get("shop", {}) as Dictionary).get("offer_id", "")) != old_offer_id])

	# 座位释放要连账本一起清（新玩家不能继承前任的钱）
	checks.append(["prep_in_seat_maps", ns.SEAT_SLOT_MAPS.has("prep")])
	checks.append(["prep_persisted", ns.PERSISTED_ROOM_FIELDS.has("prep")])
	ns._clear_seat_metadata(room, 0)
	checks.append(["prep_cleared_with_seat", not (room.get("prep", {}) as Dictionary).has(0)])

	ns._rooms.erase(int(room.id))
	ServerFlags._values = {}

	var failed: Array = []
	for c in checks:
		if not bool(c[1]):
			failed.append(str(c[0]))
	_record("economy_server_wiring", failed.is_empty(),
		"%d/%d checks%s" % [checks.size() - failed.size(), checks.size(),
			"" if failed.is_empty() else (" FAILED: " + ", ".join(failed))])

func _report() -> void:
	var passed := 0
	for r in _results:
		if bool(r.get("pass", false)):
			passed += 1
	print("[ADV] ================================")
	print("[ADV] RESULT: %d/%d passed" % [passed, _results.size()])
	print("[ADV] 第 0 批预期多数 FAIL —— 那是 A1/A3/A6/A7 的现场证据，也是第 1 批的对照基线。")
	print("[ADV] ================================")
	# 三档退出码。不能简单改成"有 FAIL 就非零"——那会让第 0 批「预期多数 FAIL、
	# 拿基线」的跑法没法用；也不能一律 0，那样 CI 挂不上门禁。
	#   0 = 全过
	#   3 = 测试台正常跑完，但有断言失败（CI 门禁看这个）
	#   2 = 测试台自身故障 / 服务器被冻住（见 _start_isolated_server 与 watchdog）
	var code := 0 if passed == _results.size() else 3
	print("[ADV] exit=%d (0=all pass, 3=assertion failures, 2=harness/server fault)" % code)
	get_tree().quit(code)
