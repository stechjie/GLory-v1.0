extends Node

# D1 第 1 刀的验收：scripts/multiplayer/RateLimitService.gd 的行为用例。
#
# 为什么必须新写：抽这块之前，限流在整个仓库里**没有任何自动化覆盖** ——
# handshake / persist / reconnect / channel / adversarial 五个探针里只有一句注释
# 提到 `_rate_ok`，没有一个用例真正驱动过它。也就是说那几个探针全绿，
# 对"限流有没有被抽坏"这件事零信息量。拿它们当验收就是假绿。
#
# 用注入的假时钟而不是真实时间：窗口过期这类行为必须能确定性地测，
# 靠 sleep 等 10 秒既慢又不稳。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/rate_limit_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RateLimitService := preload("res://scripts/multiplayer/RateLimitService.gd")

const CHECK_NAME := "rate_limit"

var _h: CheckHarness
var _clock := 0.0
var _logs: Array[String] = []
var _kicked: Array[int] = []


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_under_limit()
	_case_over_limit()
	_case_window_expiry()
	_case_strikes_kick()
	_case_soft_no_strike()
	_case_forget_resets()
	_case_peers_isolated()
	_case_actions_isolated()
	_case_unknown_action_default()
	_case_clock_injected()
	_h.finish(get_tree())


func _new_service() -> RefCounted:
	_clock = 100.0
	_logs.clear()
	_kicked.clear()
	var service := RateLimitService.new()
	service.configure(_fake_now, _record_log, _record_kick)
	return service


func _fake_now() -> float:
	return _clock


func _record_log(message: String) -> void:
	_logs.append(message)


func _record_kick(peer_id: int) -> void:
	_kicked.append(peer_id)


# --- 用例 ---------------------------------------------------------------------

# create_room 配额是 3：前 3 次必须放行。
func _case_under_limit() -> void:
	var s := _new_service()
	for i in 3:
		_h.expect(s.allow(1, "create_room"), "under_limit_denied",
			"配额内第 %d 次 create_room 被拒" % (i + 1))


func _case_over_limit() -> void:
	var s := _new_service()
	for _i in 3:
		s.allow(1, "create_room")
	_h.expect(not s.allow(1, "create_room"), "over_limit_allowed",
		"超出配额（第 4 次 create_room）仍被放行")


# 窗口滚动：过了 WINDOW_SEC 之后计数重置。
func _case_window_expiry() -> void:
	var s := _new_service()
	for _i in 4:
		s.allow(1, "create_room")
	_h.expect(not s.allow(1, "create_room"), "pre_expiry_allowed", "窗口内仍应拒绝")
	_clock += RateLimitService.WINDOW_SEC + 0.1
	_h.expect(s.allow(1, "create_room"), "post_expiry_denied",
		"窗口已过（+%.1fs）但计数没有重置" % (RateLimitService.WINDOW_SEC + 0.1))


# 连续超限累计 strike，达到 STRIKES_BEFORE_KICK 时踢人；且只踢那个 peer。
func _case_strikes_kick() -> void:
	var s := _new_service()
	for _i in 3:
		s.allow(7, "create_room")
	for _i in RateLimitService.STRIKES_BEFORE_KICK:
		s.allow(7, "create_room")
	_h.expect(_kicked.size() >= 1, "kick_not_fired",
		"连续超限 %d 次后没有触发断开" % RateLimitService.STRIKES_BEFORE_KICK)
	if not _kicked.is_empty():
		_h.expect(_kicked[0] == 7, "kick_wrong_peer",
			"踢错了 peer：踢了 %d，应为 7" % _kicked[0])


# count_strike=false（心跳走这条）：超限要拒绝，但不累计 strike、不踢人，
# 且软日志在同一个窗口内只记一次 —— 否则高频动作超限本身会变成日志放大器。
func _case_soft_no_strike() -> void:
	var s := _new_service()
	var limit := int(RateLimitService.LIMITS.get("ping", 20))
	for _i in limit:
		s.allow(2, "ping", false)
	for _i in 5:
		_h.expect(not s.allow(2, "ping", false), "soft_over_limit_allowed",
			"ping 超出配额仍被放行")
	_h.expect(_kicked.is_empty(), "soft_kicked",
		"count_strike=false 不应踢人，却踢了 %d 次" % _kicked.size())
	var soft_lines := 0
	for line in _logs:
		if line.contains("(soft)"):
			soft_lines += 1
	_h.expect(soft_lines == 1, "soft_log_spam",
		"软限流日志应只记 1 行，实际 %d 行" % soft_lines)


func _case_forget_resets() -> void:
	var s := _new_service()
	for _i in 4:
		s.allow(3, "create_room")
	_h.expect(not s.allow(3, "create_room"), "pre_forget_allowed", "forget 前应仍被拒")
	s.forget(3)
	_h.expect(s.allow(3, "create_room"), "forget_did_not_reset",
		"forget() 之后配额没有重置")


func _case_peers_isolated() -> void:
	var s := _new_service()
	for _i in 4:
		s.allow(10, "create_room")
	_h.expect(not s.allow(10, "create_room"), "peer_a_allowed", "peer 10 应已超限")
	_h.expect(s.allow(11, "create_room"), "peer_isolation_broken",
		"peer 11 被 peer 10 的用量牵连（配额没有按 peer 隔离）")


func _case_actions_isolated() -> void:
	var s := _new_service()
	for _i in 4:
		s.allow(20, "create_room")
	_h.expect(not s.allow(20, "create_room"), "action_a_allowed", "create_room 应已超限")
	_h.expect(s.allow(20, "join_room"), "action_isolation_broken",
		"join_room 被 create_room 的用量牵连（配额没有按 action 隔离）")


# 表里没有的 action 用默认 20。
func _case_unknown_action_default() -> void:
	var s := _new_service()
	_h.expect(not RateLimitService.LIMITS.has("no_such_action"),
		"fixture_stale", "夹具失效：LIMITS 里居然有 no_such_action")
	for i in 20:
		_h.expect(s.allow(30, "no_such_action"), "default_limit_too_low",
			"未知 action 默认配额应为 20，第 %d 次就被拒" % (i + 1))
	_h.expect(not s.allow(30, "no_such_action"), "default_limit_too_high",
		"未知 action 第 21 次仍被放行，默认配额不是 20")


# 时钟确实来自注入：不推进假时钟，窗口就永远不过期。
# 这条守的是"注入没接上、服务偷偷用真实时间"这种沉默失效。
func _case_clock_injected() -> void:
	var s := _new_service()
	for _i in 4:
		s.allow(40, "create_room")
	_h.expect(not s.allow(40, "create_room"), "clock_pre", "应已超限")
	# 真实时间会流逝，但假时钟不动 —— 若服务用的是真实时钟，这里就可能放行。
	_clock += 0.0
	_h.expect(not s.allow(40, "create_room"), "clock_not_injected",
		"假时钟未推进但配额被重置，说明服务用的不是注入的时钟")
