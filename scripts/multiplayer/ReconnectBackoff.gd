extends RefCounted

# D1 第 5 刀：从 NetworkService 抽出的重连退避策略。
#
# **为什么只抽这一小块，而不是整个 ReconnectService。**
# 勘测结果：触碰重连变量的 24 个函数、509 行里，绝大多数是**会话状态机编排** ——
# `_begin_reconnect` 写 `state` / `last_error` / 发 `session_changed`、
# `_tick_reconnect` 调发包、5 个 `@rpc` 入口必须挂在 Node 上。
# 把这些搬进服务，服务就要为每次状态变更和每次发包回调门面，
# 那不是解耦，只是把耦合换个地方写（与 PR4 剩余部分同理）。
#
# 真正独立、且值得单独守住的，是**退避的算法本身**：
#   capped exponential backoff + full jitter。
# 它有实际逻辑（上限、指数、抖动、尝试次数钳制），却**在抽出来之前零测试覆盖** ——
# 全仓 tools/ 里搜不到一处 backoff 用例。而它一旦写错，症状是"服务器刚恢复就被
# 全服同步重试再打垮一次"，那是最难在本地复现、也最贵的一类故障。
#
# 不用 class_name：make_server_zip.ps1 会打包 .godot/global_script_class_cache.cfg，
# 新增全局类若未先重建缓存就打包，服务器会在解析阶段直接挂（见 docs/CHECKS.md）。

const ATTEMPT_TIMEOUT_SEC := 15.0   # 单次尝试（握手 + resume）的上限
const BACKOFF_BASE_SEC := 2.0
const BACKOFF_MAX_SEC := 30.0
# 指数的尝试次数上限：超过之后间隔不再增长，稳定在 BACKOFF_MAX_SEC 附近。
const ATTEMPT_EXPONENT_CAP := 5

# 注入随机源：默认用 randf()，测试注入固定值以确定性验证边界。
var _rand_fn: Callable = Callable()


func configure(rand_fn: Callable = Callable()) -> void:
	_rand_fn = rand_fn


# 第 attempt 次尝试之前应该等多久。
#
# capped exponential full jitter。固定间隔会让全服客户端同步重试，把刚解冻的
# 服务器再打垮一次（服务器冻结时所有人同时判超时，波峰完全叠加）。
# full jitter = 在 [0, cap] 上均匀取值，而不是 cap 附近抖动 —— 前者把重试
# 摊得最平（AWS 那篇 backoff-and-jitter 的结论）。
func wait_seconds(attempt: int) -> float:
	return _rand() * cap_for_attempt(attempt)


# 该次尝试的间隔上限。attempt 超过 ATTEMPT_EXPONENT_CAP 之后不再增长。
func cap_for_attempt(attempt: int) -> float:
	var clamped := mini(maxi(attempt, 0), ATTEMPT_EXPONENT_CAP)
	return minf(BACKOFF_MAX_SEC, BACKOFF_BASE_SEC * pow(2.0, float(clamped)))


# 单次尝试的超时截止时间。整次尝试（握手 + resume）**绝不能拆**：
# 只有整体超时才放弃重来，否则握手到一半被判超时会白白丢掉一次可用连接。
func deadline_from(now: float) -> float:
	return now + ATTEMPT_TIMEOUT_SEC


func _rand() -> float:
	if _rand_fn.is_valid():
		return float(_rand_fn.call())
	return randf()
