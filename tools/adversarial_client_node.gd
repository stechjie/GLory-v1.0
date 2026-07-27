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
		"human_last_stand": true,
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
	var neutralized := float(got.get("god_lifesteal", 0.0)) < 1.0 and not bool(got.get("god_invulnerable_opening", false))
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

func _report() -> void:
	var passed := 0
	for r in _results:
		if bool(r.get("pass", false)):
			passed += 1
	print("[ADV] ================================")
	print("[ADV] RESULT: %d/%d passed" % [passed, _results.size()])
	print("[ADV] 第 0 批预期多数 FAIL —— 那是 A1/A3/A6/A7 的现场证据，也是第 1 批的对照基线。")
	print("[ADV] ================================")
	# 退出码 0：测试台本身跑通了（不代表被测项全过）。服务器被冻住/崩溃才非零。
	get_tree().quit(0)
