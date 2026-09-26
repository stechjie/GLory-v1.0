extends Node

# D1 第 6 刀的验收：scripts/multiplayer/ConnectionHealth.gd 的行为用例。
#
# 抽出来之前的覆盖现状：`adversarial_client` 只覆盖了空闲回收的**一个**用例，
# 心跳超时与僵尸回收零覆盖。这几个阈值判错的后果都很实在：
#   * 超时判太松 → 掉线的人一直占着座位，别人进不来
#   * 判太紧     → 网络抖一下就把正常玩家踢下线
#   * 预警线 >= 超时线 → 预警永远不会触发，等于没做
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/connection_health_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ConnectionHealth := preload("res://scripts/multiplayer/ConnectionHealth.gd")

const CHECK_NAME := "connection_health"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_thresholds_ordered()
	_case_timeout_boundary()
	_case_timeout_picks_only_stale()
	_case_unjoined_partition()
	_case_unjoined_in_room_never_dropped()
	_case_silence_warning()
	_case_rtt_logging()
	_case_ping_interval()
	_case_empty_inputs()
	_case_resume_holder()
	_h.finish(get_tree())


func _case_resume_holder() -> void:
	var health := ConnectionHealth.new()
	var now := 1000.0
	var stale_after: float = ConnectionHealth.RESUME_STALE_SEC
	_h.expect(stale_after < ConnectionHealth.HEARTBEAT_TIMEOUT_SEC,
		"resume_before_disconnect", "Authenticated recovery precedes full timeout")
	_h.expect(not health.resume_holder_stale({}, 12, now),
		"resume_unknown_holder", "Missing heartbeat evidence does not evict a holder")
	_h.expect(not health.resume_holder_stale({12: now - stale_after + 0.001}, 12, now),
		"resume_fresh_holder", "Recently responsive holder remains protected")
	_h.expect(health.resume_holder_stale({12: now - stale_after}, 12, now),
		"resume_stale_holder", "Half-open holder can be replaced at the recovery deadline")
	_h.expect(not health.resume_holder_stale({12: now + 1.0}, 12, now),
		"resume_clock_boundary", "Clock regression cannot evict the holder")


# 阈值之间的相对关系必须成立，否则某些分支永远进不去。
# 这类"配置本身自相矛盾"的错误，单看任何一个常量都发现不了。
func _case_thresholds_ordered() -> void:
	var warn: float = ConnectionHealth.PONG_GAP_WARN_SEC
	var timeout: float = ConnectionHealth.HEARTBEAT_TIMEOUT_SEC
	var interval: float = ConnectionHealth.HEARTBEAT_INTERVAL_SEC
	_h.expect(warn < timeout, "warn_not_before_timeout",
		"静默预警线 %.1fs 不早于超时线 %.1fs —— 预警永远不会触发" % [warn, timeout])
	_h.expect(interval < warn, "interval_not_before_warn",
		"心跳间隔 %.1fs 不早于预警线 %.1fs —— 正常心跳就会触发预警" % [interval, warn])
	_h.expect(timeout > interval * 2.0, "timeout_too_tight",
		"超时线 %.1fs 不足心跳间隔 %.1fs 的两倍 —— 丢一个包就判掉线" % [timeout, interval])


# 边界：恰好等于超时线不算超时，超过才算（原实现用的是 >）。
func _case_timeout_boundary() -> void:
	var h := ConnectionHealth.new()
	var now := 1000.0
	var t: float = ConnectionHealth.HEARTBEAT_TIMEOUT_SEC
	_h.expect(h.timed_out_peers({1: now - t}, now).is_empty(),
		"boundary_too_eager", "静默恰好 %.1fs 就被判超时（应为严格大于）" % t)
	_h.expect(h.timed_out_peers({1: now - t - 0.1}, now).size() == 1,
		"boundary_too_lax", "静默超过 %.1fs 仍未判超时" % t)


func _case_timeout_picks_only_stale() -> void:
	var h := ConnectionHealth.new()
	var now := 1000.0
	var t: float = ConnectionHealth.HEARTBEAT_TIMEOUT_SEC
	var last_ping := {
		10: now - 1.0,          # 刚 ping 过
		11: now - t - 5.0,      # 早就没声了
		12: now - t / 2.0,      # 一半，还不算
		13: now - t - 0.5,      # 刚超
	}
	var stale: Array = h.timed_out_peers(last_ping, now)
	stale.sort()
	_h.expect(stale == [11, 13], "wrong_stale_set",
		"超时集合应为 [11, 13]，实际 %s" % str(stale))


func _case_unjoined_partition() -> void:
	var h := ConnectionHealth.new()
	var now := 1000.0
	var ttl: float = ConnectionHealth.UNJOINED_PEER_TTL_SEC
	var connected_at := {
		20: now - ttl - 1.0,   # 超时未进房 -> drop
		21: now - 5.0,         # 刚连上 -> 什么都不做
		22: now - ttl - 2.0,   # 超时但已在房间 -> forget，不能 drop
	}
	var peer_room := {22: 12345}
	var parts: Dictionary = h.partition_unjoined(connected_at, peer_room, now)
	var drop: Array = parts["drop"]
	var forget: Array = parts["forget"]
	_h.expect(drop == [20], "wrong_drop_set", "该断开的应为 [20]，实际 %s" % str(drop))
	_h.expect(forget == [22], "wrong_forget_set", "该摘除的应为 [22]，实际 %s" % str(forget))


# 关键：已经进房间的 peer 无论连多久都不能被这个清道夫断开。
# 两组混在一起写就会踢掉正常在打的人。
func _case_unjoined_in_room_never_dropped() -> void:
	var h := ConnectionHealth.new()
	var now := 100000.0
	var connected_at := {}
	var peer_room := {}
	for i in 5:
		connected_at[30 + i] = 0.0      # 连了极久
		peer_room[30 + i] = 999         # 但都在房间里
	var parts: Dictionary = h.partition_unjoined(connected_at, peer_room, now)
	_h.expect((parts["drop"] as Array).is_empty(), "in_room_dropped",
		"在房间里的 peer 被空闲清道夫断开了：%s" % str(parts["drop"]))
	_h.expect((parts["forget"] as Array).size() == 5, "in_room_not_forgotten",
		"在房间里的 peer 应从 connected_at 摘除，实际摘了 %d 个" % (parts["forget"] as Array).size())


func _case_silence_warning() -> void:
	var h := ConnectionHealth.new()
	var w: float = ConnectionHealth.PONG_GAP_WARN_SEC
	_h.expect(not h.should_warn_silence(w - 0.1), "warn_too_eager", "未到预警线就预警")
	_h.expect(h.should_warn_silence(w), "warn_at_line_missed", "到达预警线未预警")
	_h.expect(h.should_warn_silence(w + 10.0), "warn_beyond_missed", "超过预警线未预警")


func _case_rtt_logging() -> void:
	var h := ConnectionHealth.new()
	var t: int = ConnectionHealth.PING_RTT_LOG_MS
	_h.expect(not h.should_log_rtt(t - 1), "rtt_log_spam",
		"正常 RTT 也记日志会刷屏（阈值 %d）" % t)
	_h.expect(h.should_log_rtt(t), "rtt_log_missed", "达到阈值未记录")


func _case_ping_interval() -> void:
	var h := ConnectionHealth.new()
	var i: float = ConnectionHealth.HEARTBEAT_INTERVAL_SEC
	_h.expect(not h.should_send_ping(i - 0.01), "ping_too_frequent", "未到间隔就发心跳")
	_h.expect(h.should_send_ping(i), "ping_missed", "到达间隔未发心跳")


# 空输入不能炸，也不能误判出内容。
func _case_empty_inputs() -> void:
	var h := ConnectionHealth.new()
	_h.expect(h.timed_out_peers({}, 1000.0).is_empty(), "empty_timeout", "空输入却判出超时 peer")
	var parts: Dictionary = h.partition_unjoined({}, {}, 1000.0)
	_h.expect((parts["drop"] as Array).is_empty() and (parts["forget"] as Array).is_empty(),
		"empty_partition", "空输入却判出待处理 peer")
