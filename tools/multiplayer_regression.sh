#!/usr/bin/env bash
# 联机回归网：把每个探针的**每个模式**都真正跑一遍。
#
# 为什么需要这个脚本：三个探针有必须显式驱动的模式，裸跑 .tscn 只会跑默认那个 ——
#
#   handshake_check  --hs-case=ok|bad|silent        裸跑只有 ok
#   persist_check    --persist-phase=save|load      裸跑只有 save，load 那一半从没跑过
#   channel_check    --ch-role=server|client        裸跑只有 server，没有客户端连上来
#
# 2026-08-20 实测这不是理论问题：把 NetworkService 的握手拒绝原因从 protocol_mismatch
# 改成别的，裸跑 handshake_check 照样退出 0；只有 --hs-case=bad 那一路会报
# "rejected=broken_on_purpose (want protocol_mismatch)"。也就是说 D1 抽 NetworkTransport
# 时，真正能抓到握手被抽坏的那个用例，仓库里没有任何东西在驱动它。
#
# 各探针文件头都写了正确的调用方式，缺的只是一个去执行它们的东西。这就是那个东西。
#
# 注意参数形式是 `--key=value`：`--key value` 会被静默忽略并退回默认值
# （tools/handshake_check_node.gd 的 _arg() 里对此有说明）。
#
# 用法：
#   bash tools/multiplayer_regression.sh [--godot <path>] [--only <name>]

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN=""
ONLY=""
TIMEOUT_SEC=240

while [ $# -gt 0 ]; do
    case "$1" in
        --godot) GODOT_BIN="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$GODOT_BIN" ]; then
    GODOT_BIN="$(ls /c/Users/*/Desktop/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64.exe 2>/dev/null | head -1)"
fi
[ -x "$GODOT_BIN" ] || { echo "找不到 Godot，用 --godot 指定" >&2; exit 2; }

PROJECT_ROOT_WIN="$(cygpath -m "$PROJECT_ROOT" 2>/dev/null || echo "$PROJECT_ROOT")"
LOG_DIR="$(mktemp -d 2>/dev/null || echo /tmp/mp_regression)"
mkdir -p "$LOG_DIR"

PASSED=()
FAILED=()

# 起真服务器的探针（persist / channel）要一把出战名片公钥，服务器才肯启动。
# 探针自己现场生成，写到这条**测试专用**路径 —— 不碰默认路径，理由见 tools/battle_card_test_keys.gd。
CARD_KEY_ARG="--battle-card-key=user://test_battle_card_public.pem"

_skip() { [ -n "$ONLY" ] && [ "$ONLY" != "$1" ]; }

# 跑一个模式。判定只看退出码：这些探针有的用 CheckHarness（退出码 0/1），有的自己
# quit(非零)，但两类都保证"失败时退出码非零"，所以退出码是唯一两类都认的信号。
run_mode() {
    local label="$1"; shift
    local log="$LOG_DIR/${label//[^a-zA-Z0-9_]/_}.log"
    timeout "$TIMEOUT_SEC" "$GODOT_BIN" --headless --path "$PROJECT_ROOT_WIN" "$@" > "$log" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        PASSED+=("$label")
        printf '  %-40s PASS\n' "$label"
    else
        FAILED+=("$label (rc=$rc)")
        printf '  %-40s FAIL rc=%s\n' "$label" "$rc"
        grep -iE 'FAIL|ERROR|CHECK_RESULT' "$log" | head -3 | sed 's/^/        /'
    fi
    return 0
}

echo "[mp_regression] Godot: $GODOT_BIN"
echo "[mp_regression] 日志: $LOG_DIR"
echo

# --- 单模式探针 ---------------------------------------------------------------
echo "单模式探针："
for s in reconnect_check reconnect_backoff_check connection_health_check \
         rate_limit_check client_log_check merge_rule_parity_check \
         room_service_check reconnect_service_check dedicated_server_check \
         replay_transfer_check network_transport_check match_state_check \
         determinism_check; do
    _skip "$s" && continue
    run_mode "$s" "res://tools/$s.tscn"
done

# --- handshake：三个用例都要跑 ------------------------------------------------
# bad 是唯一能抓到"拒绝原因被改坏"的那一个，silent 覆盖超时路径。
if ! _skip handshake_check; then
    echo
    echo "handshake_check（三个用例）："
    for c in ok bad silent; do
        run_mode "handshake_check --hs-case=$c" "res://tools/handshake_check.tscn" -- "--hs-case=$c"
    done
fi

# --- persist：两阶段，顺序不能反 ----------------------------------------------
# save 写快照、load 读回来比对。只跑 save 等于只验证了"写得出去"，
# 而房间持久化真正会坏的地方是"读回来对不对"。
if ! _skip persist_check; then
    echo
    echo "persist_check（save 然后 load）："
    # 先清掉分片 7 的旧快照。save 阶段是**往已有快照里加房间**，不是从头写，
    # 所以上一次运行留下的房间会累加进来：第一次跑完 load 期望 2 个房间、实际看到 4 个，
    # 报出来的 FAIL 长得很像持久化坏了，其实只是上一轮的残留。
    # 判定依赖磁盘状态的检查，必须自己先把磁盘弄干净，否则它是顺序相关的。
    USER_DIR="$(ls -d /c/Users/*/AppData/Roaming/Godot/app_userdata/'Glory Beta 0.04' 2>/dev/null | head -1)"
    if [ -n "$USER_DIR" ]; then
        rm -f "$USER_DIR/server_rooms.bin.7" "$USER_DIR/server_rooms.bin.7.bak"
        note_cleared=1
    fi
    run_mode "persist_check --persist-phase=save" "res://tools/persist_check.tscn" -- "--persist-phase=save" "$CARD_KEY_ARG"
    run_mode "persist_check --persist-phase=load" "res://tools/persist_check.tscn" -- "--persist-phase=load" "$CARD_KEY_ARG"
fi

# --- channel：两个进程必须同时在 ----------------------------------------------
# 通道号写错的后果不是抛错，是包被静默丢弃，所以只能真的过一遍 ENet。
# server 后台起、client 前台判定；server 自己有 90 秒寿命，跑完直接收掉。
if ! _skip channel_check; then
    echo
    echo "channel_check（server 后台 + client 前台）："
    "$GODOT_BIN" --headless --path "$PROJECT_ROOT_WIN" res://tools/channel_check.tscn -- --ch-role=server "$CARD_KEY_ARG" \
        > "$LOG_DIR/channel_server.log" 2>&1 &
    CH_SERVER_PID=$!
    sleep 5
    run_mode "channel_check --ch-role=client" "res://tools/channel_check.tscn" -- "--ch-role=client"
    kill "$CH_SERVER_PID" 2>/dev/null
    wait "$CH_SERVER_PID" 2>/dev/null

    # --- 分块模式：同样两个进程，但回放走 _send_replay_to_peer 的分块路径 -------
    # 为什么必须单独跑一遍：实测最坏一场压缩后 61.8 KB，低于 192 KiB 阈值，
    # 也就是**生产里永远走不到分块**。不强制跑一遍的话，分块/确认/重试三件事
    # 在真实网络上等于没验过 —— 同进程单测测不到"包过不过得了 ENet"。
    "$GODOT_BIN" --headless --path "$PROJECT_ROOT_WIN" res://tools/channel_check.tscn -- --ch-role=server --ch-chunked=1 "$CARD_KEY_ARG" > "$LOG_DIR/channel_server_chunked.log" 2>&1 &
    CH_CHUNK_PID=$!
    sleep 5
    run_mode "channel_check --ch-chunked=1 (client)" "res://tools/channel_check.tscn" --         "--ch-role=client" "--ch-chunked=1"
    # 服务端在收到确认时会自己退出并打印 ack_ok=true。等它一会儿再收。
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$CH_CHUNK_PID" 2>/dev/null || break
        sleep 1
    done
    kill "$CH_CHUNK_PID" 2>/dev/null
    wait "$CH_CHUNK_PID" 2>/dev/null
    # 确认链路：客户端收齐后回 _rpc_replay_ack，服务端据此清掉下发条目。
    # 这是唯一能在真实网络上证明"确认"跑通的观测点。
    if grep -q 'ack_ok=true' "$LOG_DIR/channel_server_chunked.log" 2>/dev/null; then
        PASSED+=("channel_check chunked ack")
        printf '  %-40s PASS
' "channel_check chunked ack"
    else
        FAILED+=("channel_check chunked ack (服务端没收到确认)")
        printf '  %-40s FAIL
' "channel_check chunked ack"
        grep -iE 'CH\]' "$LOG_DIR/channel_server_chunked.log" 2>/dev/null | tail -3 | sed 's/^/        /'
    fi
fi

# --- 收尾 ---------------------------------------------------------------------
echo
echo "[mp_regression] ----- 结果 -----"
echo "[mp_regression] 通过 ${#PASSED[@]} 项"
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "[mp_regression] PASS"
    exit 0
fi
echo "[mp_regression] 失败 ${#FAILED[@]} 项："
for f in "${FAILED[@]}"; do echo "    $f"; done
echo "[mp_regression] 日志在 $LOG_DIR"
exit 1
