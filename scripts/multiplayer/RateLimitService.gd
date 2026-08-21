extends RefCounted

# D1 第 1 刀：从 NetworkService 抽出的 RPC 限流。
#
# 为什么先抽这块：它是全 4264 行里耦合最低的一块 —— 只有 2 个成员变量、2 个函数，
# 且除了 `_dedicated_server` 这个模式开关之外不碰任何其他成员状态（实测 foreign=1）。
# 拿它验证「服务对象 + NetworkService 当门面」这套做法能否在现有回归网下站住，
# 再去动 Room（32 个函数）那种真正难的。收益不在减行数，在验证机制。
#
# 不用 class_name：make_server_zip.ps1 会把 .godot/global_script_class_cache.cfg
# 一起打包，新增的全局类如果没先重建缓存就打包，服务器会在解析阶段直接挂
# （见 docs/CHECKS.md）。用 preload 就没有这个问题。
#
# 依赖全部注入，本类不认识 NetworkService、multiplayer、也不读全局状态：
#   now_fn  -> 单调秒（NetworkService._now）
#   log_fn  -> 日志（NetworkService._net_log）
#   kick_fn -> 断开某个 peer（NetworkService 里操作 multiplayer_peer）
#
# 能力边界（沿用原注释，A8）：这只挡回包放大。恶意客户端仍可无限高频发包，
# 反序列化与 handler 调用的开销照旧，连接也一直占着。
# 入包侧要靠连接准入（A13）和包级字节预算（R4）。

const WINDOW_SEC := 10.0

# action -> 每 WINDOW_SEC 内允许次数
const LIMITS := {
	"create_room": 3,
	"join_room": 6,
	"room_list": 10,
	"public_token": 3,
	"public_resume": 5,
	"client_log": 4,
	"set_ready": 30,
	"submit_board": 10,
	"prep_mercs": 40,
	"toggle_slot": 30,
	"kick": 10,
	"move": 30,
	"altar": 12,          # 每回合上限 3 次，留足重试余量
	"treasure_choice": 6, # 每个宝物轮只该选一次，留重试余量
	"treasure_refresh": 12,
	"result_ack": 8,      # 每回合一次，留重试余量
	# 回放分块的确认/缺块上报。每回合正常两条（本方 + 敌方各一次收齐确认），
	# 丢包时每次停滞多一条缺块上报。额度要宽到弱网下不会把诚实客户端限掉 ——
	# 回放收不齐本来就是弱网，再把它的重试限掉就永远收不齐了。
	"replay_ack": 20,
	"leave_intent": 6,
	# 经济 intent（P1）：备战期买卖合成刷新是玩家点得最快的一类操作，
	# 额度必须宽（正常连点会撞上限），但仍要有上限 —— 每条 intent 都会写账本。
	"economy": 60,
	# 心跳：客户端 3 秒一次，10 秒窗口正常 3~4 次，给一倍余量。
	# 注意它走 count_strike=false（不计 strike）——心跳超频更可能是客户端 bug 或时钟
	# 抖动，不是攻击；用累计 strike 去踢人等于拿自己人的连接赌。
	"ping": 8,
	# 重连：直连入口必须和短码入口共用同一个身份配额，否则客户端绕开
	# _rpc_public_resume_request 直接打 _rpc_resume_request 就把 A6 的保护全跳过了。
	"resume": 5,
}

const STRIKES_BEFORE_KICK := 3   # 连续超限这么多次就断开

var _buckets: Dictionary = {}    # peer_id -> {action: [count, window_start]}
var _strikes: Dictionary = {}    # peer_id -> int

var _now_fn: Callable = Callable()
var _log_fn: Callable = Callable()
var _kick_fn: Callable = Callable()


func configure(now_fn: Callable, log_fn: Callable, kick_fn: Callable) -> void:
	_now_fn = now_fn
	_log_fn = log_fn
	_kick_fn = kick_fn


# 与原 NetworkService._rate_ok 逐行等价，只是把 _now / _net_log / 断开操作换成注入的
# Callable。是否启用（原来的 `if not _dedicated_server: return true`）留在门面上判断，
# 这样本类完全不需要知道"专服模式"这个概念。
func allow(peer_id: int, action: String, count_strike: bool = true) -> bool:
	var limit := int(LIMITS.get(action, 20))
	var now := _time()
	var buckets: Dictionary = _buckets.get(peer_id, {})
	var entry: Array = buckets.get(action, [0, now])
	if now - float(entry[1]) >= WINDOW_SEC:
		entry = [0, now]
	entry[0] = int(entry[0]) + 1
	buckets[action] = entry
	_buckets[peer_id] = buckets
	if int(entry[0]) <= limit:
		return true
	if not count_strike:
		# 只在窗口内第一次超限时记一行，否则高频动作超限本身就成了日志放大器。
		if int(entry[0]) == limit + 1:
			_log("rate limit (soft) peer=%d action=%s count=%d/%d" % [peer_id, action, int(entry[0]), limit])
		return false
	var strikes := int(_strikes.get(peer_id, 0)) + 1
	_strikes[peer_id] = strikes
	_log("rate limit peer=%d action=%s count=%d/%d strike=%d" % [peer_id, action, int(entry[0]), limit, strikes])
	if strikes >= STRIKES_BEFORE_KICK:
		_log("rate limit exceeded -> disconnect peer=%d" % peer_id)
		if _kick_fn.is_valid():
			_kick_fn.call(peer_id)
	return false


func forget(peer_id: int) -> void:
	_buckets.erase(peer_id)
	_strikes.erase(peer_id)


func _time() -> float:
	# 没 configure 就退回自己取时钟：宁可限流仍然生效，也不要因为漏了一次注入
	# 就静默变成"永远不超限"——那是把一道防护悄悄关掉。
	if _now_fn.is_valid():
		return float(_now_fn.call())
	return float(Time.get_ticks_msec()) / 1000.0


func _log(message: String) -> void:
	if _log_fn.is_valid():
		_log_fn.call(message)
