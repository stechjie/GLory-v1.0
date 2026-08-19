extends Node

# D1 第 5 刀的验收：scripts/multiplayer/ReconnectBackoff.gd 的行为用例。
#
# 抽出来之前，重连退避在整个仓库里**零测试覆盖**（tools/ 下搜不到一处 backoff 用例）。
# 而它写错的症状是「服务器刚恢复就被全服同步重试再打垮一次」——
# 服务器冻结时所有客户端同时判超时，若间隔固定，波峰会完全叠加。
# 这类故障本地几乎复现不出来，只会在真实事故里暴露，所以必须有确定性用例守住。
#
# 随机源注入，用固定值验证边界，不靠"跑几次看起来差不多"。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const ReconnectBackoff := preload("res://scripts/multiplayer/ReconnectBackoff.gd")

const CHECK_NAME := "reconnect_backoff"

var _h: CheckHarness
var _rand_value := 0.5


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_exponential_growth()
	_case_capped()
	_case_attempt_clamped()
	_case_full_jitter_range()
	_case_jitter_is_full_not_partial()
	_case_negative_attempt()
	_case_deadline()
	_case_rand_injected()
	_h.finish(get_tree())


func _new() -> RefCounted:
	var b := ReconnectBackoff.new()
	b.configure(_fake_rand)
	return b


func _fake_rand() -> float:
	return _rand_value


# 间隔按 2 的幂增长：base * 2^attempt。
func _case_exponential_growth() -> void:
	var b := _new()
	var base: float = ReconnectBackoff.BACKOFF_BASE_SEC
	for attempt in 4:
		var want: float = base * pow(2.0, float(attempt))
		var got: float = b.cap_for_attempt(attempt)
		_h.expect(abs(got - want) < 0.001, "growth_wrong",
			"attempt=%d 的上限应为 %.1f，实际 %.1f" % [attempt, want, got])


# 无论尝试多少次，都不超过 BACKOFF_MAX_SEC。
func _case_capped() -> void:
	var b := _new()
	var maxs: float = ReconnectBackoff.BACKOFF_MAX_SEC
	for attempt in [5, 8, 20, 1000]:
		var got: float = b.cap_for_attempt(int(attempt))
		_h.expect(got <= maxs + 0.001, "cap_exceeded",
			"attempt=%d 的上限 %.1f 超过了 %.1f" % [int(attempt), got, maxs])


# 指数的尝试次数被钳制：超过 ATTEMPT_EXPONENT_CAP 之后不再增长，
# 否则 pow(2, 大数) 会溢出成 inf，间隔变成 NaN/inf，重连直接死掉。
func _case_attempt_clamped() -> void:
	var b := _new()
	var at_cap: float = b.cap_for_attempt(ReconnectBackoff.ATTEMPT_EXPONENT_CAP)
	var beyond: float = b.cap_for_attempt(ReconnectBackoff.ATTEMPT_EXPONENT_CAP + 50)
	_h.expect(abs(at_cap - beyond) < 0.001, "not_clamped",
		"超过钳制点后上限仍在变：%.3f vs %.3f" % [at_cap, beyond])
	_h.expect(is_finite(beyond), "not_finite",
		"大 attempt 下上限不是有限数（%.3f）——pow 溢出会让重连彻底卡死" % beyond)


# full jitter：等待时间落在 [0, cap] 内。
func _case_full_jitter_range() -> void:
	var b := _new()
	for r in [0.0, 0.25, 0.5, 0.999]:
		_rand_value = float(r)
		var attempt := 3
		var cap: float = b.cap_for_attempt(attempt)
		var wait: float = b.wait_seconds(attempt)
		_h.expect(wait >= 0.0 and wait <= cap + 0.001, "jitter_out_of_range",
			"rand=%.3f 时等待 %.3f 不在 [0, %.3f] 内" % [float(r), wait, cap])
	_rand_value = 0.5


# 关键：必须是 **full** jitter（[0, cap] 均匀），不是"cap 附近小幅抖动"。
# 后者仍会让全服重试挤在同一时刻，等于没做抖动。
# 判据：rand=0 必须给出 0 等待；rand≈1 必须给出接近 cap 的等待。
func _case_jitter_is_full_not_partial() -> void:
	var b := _new()
	var attempt := 3
	var cap: float = b.cap_for_attempt(attempt)
	_rand_value = 0.0
	var low: float = b.wait_seconds(attempt)
	_rand_value = 1.0
	var high: float = b.wait_seconds(attempt)
	_rand_value = 0.5
	_h.expect(low < 0.001, "jitter_not_full_low",
		"rand=0 应给出 0 等待，实际 %.3f（说明不是 full jitter）" % low)
	_h.expect(abs(high - cap) < 0.001, "jitter_not_full_high",
		"rand=1 应给出 cap=%.3f，实际 %.3f" % [cap, high])
	_h.expect(high - low > cap * 0.9, "jitter_span_too_narrow",
		"抖动跨度只有 %.3f，不足 cap 的九成——全服重试仍会叠加" % (high - low))


# attempt 为负（不该发生，但状态机重置时可能出现）不能炸。
func _case_negative_attempt() -> void:
	var b := _new()
	var got: float = b.cap_for_attempt(-3)
	_h.expect(got > 0.0 and is_finite(got), "negative_attempt_broken",
		"attempt=-3 时上限为 %.3f，应为正的有限数" % got)


func _case_deadline() -> void:
	var b := _new()
	var now := 1000.0
	var want: float = now + ReconnectBackoff.ATTEMPT_TIMEOUT_SEC
	var got: float = b.deadline_from(now)
	_h.expect(abs(got - want) < 0.001, "deadline_wrong",
		"截止时间应为 %.1f，实际 %.1f" % [want, got])


# 随机源确实来自注入：同一个 rand 值必须给出同一个等待时间。
# 若服务偷偷用了 randf()，两次调用几乎不可能相等。
func _case_rand_injected() -> void:
	var b := _new()
	_rand_value = 0.375
	var a: float = b.wait_seconds(2)
	var c: float = b.wait_seconds(2)
	_rand_value = 0.5
	_h.expect(abs(a - c) < 0.000001, "rand_not_injected",
		"固定随机源下两次结果不同（%.6f vs %.6f），说明用的不是注入的随机源" % [a, c])
