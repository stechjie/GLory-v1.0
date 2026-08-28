extends Node

# ReconnectService 的独立门禁（D1 验收条款：每个子服务有独立 headless 测试）。
#
# 覆盖 README 给这个服务定的三件事：token / 宽限 / AI 接管。
#
# 为什么值得单独测：这三件事的失败都是**线上才会暴露**的类型 ——
#   * 短码清洗漏了 -> 客户端自报任意字符串就能当映射键，覆盖别人的重连凭证（A12）
#   * 短码生成无界重试 -> 空间占满时服务器在循环里卡死
#   * 宽限窗口起错 -> 要么别人白等、要么本人还没断线就被判掉线
#   * suspended 房间也转 AI -> 房里没有真人却启动一场纯 AI 战斗烧 CPU（B11/R2）
#   * 接管不清 reserved -> 座位永远停在保留态，本人回来也接不回去
#
# 时钟走注入的假时钟：宽限是时间语义，不能靠 sleep 去碰运气。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ReconnectServiceScript := preload("res://scripts/multiplayer/ReconnectService.gd")
const CHECK_NAME := "reconnect_service"

var _h: RefCounted
var _now := 1000.0
var _logs: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_session_token()
	_check_public_token_generation()
	_check_public_id_sanitize()
	_check_reserve_window()
	_check_release()
	_check_expiry_and_takeover()
	_check_suspended_room_is_skipped()
	_check_takeover_state()
	_check_token_index()
	_h.finish(get_tree())


func _make() -> RefCounted:
	var svc: RefCounted = ReconnectServiceScript.new()
	svc.configure(
		func() -> float: return _now,
		func(msg: String) -> void: _logs.append(msg),
		{"reserve_grace_sec": 20.0})
	return svc


func _room() -> Dictionary:
	return {
		"id": 4242,
		"slot_states": ["player", "player", "empty", "empty", "empty", "empty"],
		"ready": [false, false, false, false, false, false],
		"reserved": {},
		"reserve_deadline": {},
		"suspended": false,
	}


# --- token --------------------------------------------------------------------

func _check_session_token() -> void:
	var svc := _make()
	var a := str(svc.make_token())
	var b := str(svc.make_token())
	_h.expect(a.length() == 64, "session_token_length",
		"会话 token 应是 32 字节的 hex（64 字符），实际 %d" % a.length())
	_h.expect(a != b, "session_token_repeats", "两次签发的会话 token 不该相同")
	for ch in a:
		_h.expect("0123456789abcdef".contains(ch), "session_token_hex", "会话 token 含非 hex 字符 '%s'" % ch)


# 这段此前一直没有真正执行过：它按 make_public_token(查重回调) 写，而服务的签名是
# 无参的 —— 查重走内部的 public_token_seat，可注入的 seam 是 set_random_source()
# （见 ReconnectService.gd 顶部那段注释）。GDScript 的参数不符只中止当前函数，_run()
# 继续往下走，检查最后照样打印 status=PASS checked=100。2026-08-28 由
# tools/run_check.ps1 的引擎级错误检测首次发现。
#
# 重写时保留了原来三条断言的意图，换成真实 API：
#   长度 / 字母表   直接调无参版本即可
#   占满时放弃      随机源钉死 -> 每次生成同一个 id -> 预先占用它，必然次次撞上
#   正好试 N 次     数随机源被调用的次数 —— 每试一次取一次随机字节，是等价的观测点
func _check_public_token_generation() -> void:
	var svc := _make()
	var id := str(svc.make_public_token())
	_h.expect(id.length() == ReconnectServiceScript.PUBLIC_TOKEN_LENGTH,
		"public_token_length", "短码长度应为 %d，实际 %d" % [ReconnectServiceScript.PUBLIC_TOKEN_LENGTH, id.length()])
	for ch in id:
		_h.expect(ReconnectServiceScript.PUBLIC_TOKEN_ALPHABET.contains(ch),
			"public_token_alphabet", "短码含字母表外的字符 '%s'（0/O/1/I 易混，已刻意排除）" % ch)

	# 空间占满：必须放弃并返回空串，而不是转不出来。
	# 计数器用数组而不是 int：GDScript 的 lambda **按值捕获**局部整数，
	# 写成 `var tries := 0` 再在闭包里 `tries += 1`，改的是副本，外面永远读到 0。
	var exhausted_svc := _make()
	var tries := [0]
	exhausted_svc.set_random_source(func(n: int) -> PackedByteArray:
		tries[0] += 1
		var out := PackedByteArray()
		for _i in n:
			out.append(7)
		return out)
	# 先把那个必然生成的 id 占掉，之后每一次重试都会撞上它。
	var collide := str(exhausted_svc.make_public_token())
	_h.expect(not collide.is_empty(), "public_token_fixed_source",
		"固定随机源下第一次应能签发短码")
	exhausted_svc.public_token_seat[collide] = "tok_taken"

	tries[0] = 0
	var exhausted := str(exhausted_svc.make_public_token())
	_h.expect(exhausted.is_empty(),
		"public_token_unbounded", "短码空间占满时应返回空串放弃，实际返回 '%s'" % exhausted)
	_h.expect(int(tries[0]) == ReconnectServiceScript.PUBLIC_TOKEN_MAX_TRIES,
		"public_token_try_count", "应正好试 %d 次就放弃，实际 %d 次 —— 无界循环会把服务器卡死"
			% [ReconnectServiceScript.PUBLIC_TOKEN_MAX_TRIES, int(tries[0])])


# 客户端上报的短码必须先过清洗（A12）：此前任意字符串都能当映射键，
# 等于任何人都能把别人的重连凭证指向自己的座位。
func _check_public_id_sanitize() -> void:
	var svc := _make()
	_h.expect(str(svc.sanitize_public_id("abcdefghjk")) == "ABCDEFGHJK",
		"sanitize_upper", "合法短码应转成大写后原样返回")
	_h.expect(str(svc.sanitize_public_id("  ABCDEFGHJK  ")) == "ABCDEFGHJK",
		"sanitize_trim", "两端空白应被去掉")
	for bad in ["", "ABC DEF", "ABC-DEF", "ABCDEFGHI0", "ABCDEFGHIO", "ABCDEFGHI1", "ABCDEFGHII",
			"A".repeat(ReconnectServiceScript.MAX_PUBLIC_ID_LEN + 1)]:
		_h.expect(str(svc.sanitize_public_id(bad)).is_empty(),
			"sanitize_accepted_bad", "非法短码 %s 应被拒成空串" % [bad if bad != "" else "<空串>"])


# --- 宽限 ---------------------------------------------------------------------

func _check_reserve_window() -> void:
	var svc := _make()
	var room := _room()
	svc.reserve_seat(room, 1)
	var reserved: Dictionary = room.get("reserved", {})
	var deadline: Dictionary = room.get("reserve_deadline", {})
	_h.expect(reserved.has(1), "reserve_no_entry", "掉线座位应进保留态")
	_h.expect(is_equal_approx(float((reserved[1] as Dictionary).get("reserved_at", -1.0)), _now),
		"reserve_at_time", "reserved_at 应记注入时钟的当前值")
	_h.expect(is_equal_approx(float(deadline.get(1, -1.0)), _now + 20.0),
		"reserve_deadline_window", "宽限截止应是 now + reserve_grace_sec（20 秒），实际 %s"
			% str(deadline.get(1, -1.0)))
	_h.expect(not deadline.has(0), "reserve_touched_others", "不该动别的座位")


func _check_release() -> void:
	var svc := _make()
	var room := _room()
	svc.reserve_seat(room, 0)
	svc.reserve_seat(room, 1)
	svc.release_reservation(room, 0)
	_h.expect(not (room.get("reserved", {}) as Dictionary).has(0),
		"release_reserved", "撤保留态应清掉 reserved 条目 —— 留着会让座位永远停在保留态")
	_h.expect(not (room.get("reserve_deadline", {}) as Dictionary).has(0),
		"release_deadline", "撤保留态应清掉宽限截止")
	_h.expect((room.get("reserved", {}) as Dictionary).has(1),
		"release_touched_others", "不该动别的座位的保留态")


# --- 到期与接管 ---------------------------------------------------------------

func _check_expiry_and_takeover() -> void:
	var svc := _make()
	var room := _room()
	var rooms := {int(room.id): room}
	svc.reserve_seat(room, 0)
	svc.reserve_seat(room, 1)
	# 只让 0 号到期
	(room.get("reserve_deadline", {}) as Dictionary)[0] = _now - 1.0

	var taken: Array[int] = []
	svc.tick_reserved_seats(rooms, func(_r: Dictionary, slot: int) -> void: taken.append(slot))
	_h.expect(taken == [0], "expiry_wrong_seat", "只有到期的座位该被接管，实际 %s" % str(taken))
	_h.expect(not (room.get("reserve_deadline", {}) as Dictionary).has(0),
		"expiry_deadline_kept", "到期座位应从 reserve_deadline 移除，否则会被反复接管")
	_h.expect((room.get("reserve_deadline", {}) as Dictionary).has(1),
		"expiry_early_seat", "未到期的座位不得被移除")

	# 时间往前走，另一个也该到期
	taken.clear()
	_now += 100.0
	svc.tick_reserved_seats(rooms, func(_r: Dictionary, slot: int) -> void: taken.append(slot))
	_h.expect(taken == [1], "expiry_second", "时间过去后另一个座位也该到期，实际 %s" % str(taken))
	_now -= 100.0


# suspended：房里一个真人都没有，转 AI 只会启动纯 AI 战斗烧 CPU，
# 而座位主人还在 300 秒恢复窗口内可能回来（B11/R2）。
func _check_suspended_room_is_skipped() -> void:
	var svc := _make()
	var room := _room()
	room.suspended = true
	svc.reserve_seat(room, 0)
	(room.get("reserve_deadline", {}) as Dictionary)[0] = _now - 1.0
	var taken: Array[int] = []
	svc.tick_reserved_seats({int(room.id): room}, func(_r: Dictionary, slot: int) -> void: taken.append(slot))
	_h.expect(taken.is_empty(), "suspended_taken_over",
		"suspended 房间的到期座位不得转 AI，实际 %s" % str(taken))
	_h.expect((room.get("reserve_deadline", {}) as Dictionary).has(0),
		"suspended_deadline_cleared", "suspended 房间的宽限截止也不该被清掉 —— 本人还可能回来")


func _check_takeover_state() -> void:
	var svc := _make()
	var room := _room()
	svc.reserve_seat(room, 1)
	svc.apply_ai_takeover(room, 1)
	_h.expect(str((room.get("slot_states", []) as Array)[1]) == "dummy",
		"takeover_not_dummy", "接管后座位应转 dummy，否则本回合会一直等一个不在的人")
	_h.expect(bool((room.get("ready", []) as Array)[1]),
		"takeover_not_ready", "接管后该座位应视为已准备，否则开局仍被卡住")
	_h.expect(not (room.get("reserved", {}) as Dictionary).has(1),
		"takeover_reserved_kept", "接管后应清掉 reserved —— 留着会让座位永远停在保留态")
	_h.expect(str((room.get("slot_states", []) as Array)[0]) == "player",
		"takeover_touched_others", "不该动别的座位")
	var hit := false
	for line in _logs:
		if line.contains("AI takeover"):
			hit = true
	_h.expect(hit, "takeover_not_logged", "接管应留一条日志 —— 线上排查掉线纠纷时这是唯一线索")


# --- token 索引 ---------------------------------------------------------------

# 三份索引按原始 README 字面归本服务（"ReconnectService（token/宽限/AI 接管）"）。
# 它们决定"带着 token 回来的人能不能认回自己的座位"，写坏的症状是重连落到别人的
# 座位、或者永远认不回来 —— 两种都只在线上出现。
func _check_token_index() -> void:
	var svc := _make()
	_h.expect(svc.token_seat.is_empty() and svc.public_token_seat.is_empty()
			and svc.peer_public_token.is_empty(),
		"token_index_not_empty", "新建服务时三份索引都应为空")

	# 查重要用**固定**随机源才测得到：随机源下每次生成的 id 本来就不同，
	# 断言"两次结果不一样"无论查重是否生效都成立 —— 那是空断言，第一版就是这么写的。
	# 这里把随机源钉死成同一串字节，于是两次生成的 id 必然相同，查重是唯一的差别。
	var fixed: RefCounted = ReconnectServiceScript.new()
	fixed.configure(func() -> float: return _now, func(_m: String) -> void: pass, {})
	var seq := [7]
	fixed.set_random_source(func(n: int) -> PackedByteArray:
		var out := PackedByteArray()
		for i in n:
			out.append(int(seq[0]))
		return out)
	var id := str(fixed.make_public_token())
	_h.expect(not id.is_empty(), "fixed_token_empty", "固定随机源下应能签发短码")
	fixed.public_token_seat[id] = "tok_a"
	var again := str(fixed.make_public_token())
	_h.expect(again.is_empty(), "public_token_reissued_taken",
		"固定随机源下必然撞上已占用的短码，应重试到上限后放弃返回空串，实际返回 '%s'" % again)

	svc.token_seat["tok_a"] = {"room_id": 7, "slot": 2}
	svc.peer_public_token[900] = id
	svc.clear_tokens()
	_h.expect(svc.token_seat.is_empty(), "clear_token_seat", "clear_tokens 应清空 token_seat")
	_h.expect(svc.public_token_seat.is_empty(), "clear_public_token_seat", "clear_tokens 应清空 public_token_seat")
	_h.expect(svc.peer_public_token.is_empty(), "clear_peer_public_token", "clear_tokens 应清空 peer_public_token")
