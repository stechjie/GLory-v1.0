class_name NetError
extends RefCounted

# 网络错误的统一分级（状态信封 E1，对应审计文档 B8 / B13）。
#
# 这条区分是整份整改里最省事、也最容易被写反的一条：
#
#   把**可恢复的传输故障**当成**凭证失效**来处理，就会把一个几秒后能自愈的问题
#   升级成"玩家永久回不去这局"。`disconnect_session()` 早期正是这么干的 ——
#   replay 等超时 → 清 token → 回主菜单，而服务器那边座位还好好留着。
#
# 反过来（把真失效当成可重试）代价小得多：客户端多退避几次，最后还是会拿到终局错误。
# **所以有疑问时归 RETRYABLE，不要归 TERMINAL。**

enum {
	TERMINAL = 0,    # 凭证确实没用了 -> 清 token、回主菜单
	RETRYABLE = 1,   # 这一刻接不上，但凭证仍有效 -> 保留 token、退避重试
	TRANSPORT = 2,   # 传输层失败，权威状态没问题 -> 保留 token、进可恢复状态
}

# 未登记的错误码按什么处理。选 RETRYABLE 而不是 TERMINAL：
# 新加一个错误码时忘了登记，最坏是客户端多重试几次；反过来是玩家直接出局。
const DEFAULT_CLASS := RETRYABLE

const CLASSES := {
	# --- 终局：凭证/对局确实没了 ---
	"token_unknown": TERMINAL,        # 服务端不认识这个 token
	"token_id_unknown": TERMINAL,     # 短码查不到
	"token_too_long": TERMINAL,
	"room_gone": TERMINAL,            # 房间已回收
	"match_over": TERMINAL,           # 对局已终局
	"bad_slot": TERMINAL,
	"kicked": TERMINAL,
	"protocol_mismatch": TERMINAL,    # 版本对不上，重试多少次都一样
	"version_mismatch": TERMINAL,
	"data_mismatch": TERMINAL,
	"auth_timeout": TERMINAL,
	"empty_lobby": TERMINAL,
	"prep_timeout": TERMINAL,
	"battle_timeout": TERMINAL,
	"empty_no_tokens": TERMINAL,
	"suspend_expired": TERMINAL,

	# --- 可重试：现在不行，等会儿行 ---
	"seat_busy": RETRYABLE,           # 旧 peer 还活着占着座位（B13）
	"server_busy": RETRYABLE,         # 房间数熔断
	"room_full": RETRYABLE,
	"token_unavailable": RETRYABLE,   # 短码空间暂时摇不出来
	"already_in_match": RETRYABLE,
	"room_not_found": RETRYABLE,      # 可能是分片路由到早了
	"room_started": RETRYABLE,

	# --- 传输：权威状态没问题，只是这次没送到 ---
	"replay_timeout": TRANSPORT,
	"replay_unpack_failed": TRANSPORT,
	"invalid_replay": TRANSPORT,
	"match_state_timeout": TRANSPORT,
}

static func class_of(code: String) -> int:
	return int(CLASSES.get(code, DEFAULT_CLASS))

static func is_terminal(code: String) -> bool:
	return class_of(code) == TERMINAL

# 只有终局错误才允许清掉重连凭证。这一条是整个分级的目的。
static func should_clear_credentials(code: String) -> bool:
	return is_terminal(code)

static func class_name_of(code: String) -> String:
	match class_of(code):
		TERMINAL:
			return "terminal"
		RETRYABLE:
			return "retryable"
		_:
			return "transport"
