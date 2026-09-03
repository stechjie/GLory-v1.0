#!/usr/bin/env bash
# V3 P0-10 真机验收：冷/热交替启动 soak。
#
# 与 tools/android_smoke.sh 的分工：smoke 出一次「这一版能不能启动 + T0..T4 各是
# 多少」的完整取证（含安装、清单指纹、截图）；这里只做**重复**——不装包、不出图，
# 反复启动同一版，看的是稳定性而不是单次耗时。清单要求的是
# 「20 次冷/热交替：20/20 到 T3，0 ANR / 0 fatal / 0 永久黑屏」。
#
# 「冷」的口径与 smoke 一致：am force-stop 之后再启动。进程是新的，但 page cache
# 和已解压的资源还在，所以这是 warm_after_force_stop，**不是**重启设备后的首启。
# 口径写进 JSON，别让读的人以为测的是首次安装后的冷启。
# 「热」是 HOME 切后台再回前台：进程不死，走的是 onResume 那条路。
#
# 只走无线 adb。用法：
#   tools/android_launch_soak.sh --serial 192.168.68.53:37833 --pairs 10
set -uo pipefail

ADB_BIN=""
SERIAL=""
PAIRS=10
COLD_WAIT=25
HOT_WAIT=6
OUT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --adb) ADB_BIN="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        --pairs) PAIRS="$2"; shift 2 ;;
        --cold-wait) COLD_WAIT="$2"; shift 2 ;;
        --hot-wait) HOT_WAIT="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "$ADB_BIN" ]; then
    for candidate in \
        "$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe" \
        "$(command -v adb 2>/dev/null)"; do
        [ -x "$candidate" ] && ADB_BIN="$candidate" && break
    done
fi
[ -x "$ADB_BIN" ] || { echo "adb not found; pass --adb <path>" >&2; exit 2; }

PACKAGE="$(grep -m1 'package/unique_name=' "$PROJECT_ROOT/export_presets.cfg" | sed 's/.*="\(.*\)"/\1/')"
[ -n "$PACKAGE" ] || { echo "cannot read package name from export_presets.cfg" >&2; exit 2; }

ADB=("$ADB_BIN")
[ -n "$SERIAL" ] && ADB=("$ADB_BIN" -s "$SERIAL")

STAMP="$(date +%Y%m%d_%H%M%S)"
[ -n "$OUT_DIR" ] || OUT_DIR="$PROJECT_ROOT/reports/android_soak_$STAMP"
mkdir -p "$OUT_DIR"

GIT_COMMIT="$(cd "$PROJECT_ROOT" && git rev-parse HEAD 2>/dev/null || echo unknown)"
DEVICE_MODEL="$("${ADB[@]}" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
ANDROID_REL="$("${ADB[@]}" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"

# 环形缓冲默认只有 64 KiB，框架每 16 ms 刷一条 CompositionEngine，
# 启动标记会在几十秒内被整体驱逐。调大它是取到证据的前提。
"${ADB[@]}" logcat -G 16M >/dev/null 2>&1 || true

echo "package=$PACKAGE device=$DEVICE_MODEL android=$ANDROID_REL pairs=$PAIRS"
echo "out=$OUT_DIR"

RESULTS=()
FAIL_COUNT=0

record() {
    # $1 kind, $2 index, $3 reached_t3, $4 t3_ms, $5 fatal, $6 anr, $7 marks, $8 black_ms
    RESULTS+=("{\"kind\":\"$1\",\"index\":$2,\"reached_t3\":$3,\"t3_ms\":$4,\"fatal\":$5,\"anr\":$6,\"startup_marks\":$7,\"max_black_ms\":$8}")
}

# logcat 里抠 GLORY_STARTUP 的某个标记的 ms 值。取不到回 -1。
#
# 路径要先过 cygpath：这里的 python 是 Windows 版，喂给它 MSYS 风格的
# /c/Users/... 会 FileNotFoundError，而 2>/dev/null 会把它吞掉 —— 表现是每一轮
# 都「取不到 T3」，看起来像启动失败。仓库路径带空格（Beta 0.04），
# 用相对路径试的时候恰好绕开了这个坑，所以它藏得住。
mark_ms() {
    local log="$1" mark="$2"
    if command -v cygpath >/dev/null 2>&1; then
        log="$(cygpath -m "$log")"
    fi
    python - "$log" "$mark" <<'PY' 2>/dev/null || echo -1
import json, sys
path, mark = sys.argv[1], sys.argv[2]
best = -1
with open(path, "rb") as f:
    for raw in f:
        line = raw.decode("utf-8", "replace")
        i = line.find("GLORY_STARTUP ")
        if i < 0:
            continue
        try:
            obj = json.loads(line[i + len("GLORY_STARTUP "):].strip())
        except Exception:
            continue
        if obj.get("mark") == mark:
            best = int(obj.get("ms", -1))
            break
print(best)
PY
}

for i in $(seq 1 "$PAIRS"); do
    # --- 冷（force-stop 后启动）---------------------------------------------
    "${ADB[@]}" shell am force-stop "$PACKAGE" >/dev/null 2>&1
    "${ADB[@]}" logcat -c >/dev/null 2>&1
    sleep 1
    "${ADB[@]}" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep "$COLD_WAIT"
    LOG="$OUT_DIR/cold_$i.log"
    "${ADB[@]}" logcat -d -v brief > "$LOG" 2>&1
    T3="$(mark_ms "$LOG" t3_first_input_ready)"
    MARKS="$(grep -ac 'GLORY_STARTUP' "$LOG" 2>/dev/null || true)"
    FATAL="$(grep -ac 'FATAL EXCEPTION' "$LOG" 2>/dev/null || true)"
    ANR="$(grep -ac 'ANR in ' "$LOG" 2>/dev/null || true)"
    REACHED=false
    [ "$T3" -ge 0 ] 2>/dev/null && REACHED=true
    if [ "$REACHED" != true ] || [ "$FATAL" -gt 0 ] || [ "$ANR" -gt 0 ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        # 通过的轮次不留 logcat：20 轮 × 数 MB 没有保留价值，失败的才留。
        rm -f "$LOG"
    fi
    record cold "$i" "$REACHED" "$T3" "$FATAL" "$ANR" "$MARKS" -1
    echo "  cold  #$i reached_t3=$REACHED t3=${T3}ms marks=$MARKS fatal=$FATAL anr=$ANR"

    # --- 热（HOME 切后台再回前台）-------------------------------------------
    "${ADB[@]}" logcat -c >/dev/null 2>&1
    "${ADB[@]}" shell input keyevent KEYCODE_HOME >/dev/null 2>&1
    sleep 2
    "${ADB[@]}" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep "$HOT_WAIT"
    HLOG="$OUT_DIR/hot_$i.log"
    "${ADB[@]}" logcat -d -v brief > "$HLOG" 2>&1
    HFATAL="$(grep -ac 'FATAL EXCEPTION' "$HLOG" 2>/dev/null || true)"
    HANR="$(grep -ac 'ANR in ' "$HLOG" 2>/dev/null || true)"
    # 热启动不重跑 StartupTrace（进程没死），所以判据是「回到前台且没崩」：
    # 进程还在 + 窗口是它 = 恢复成功。用 T3 判会永远取不到，那是假红。
    FOCUS="$("${ADB[@]}" shell dumpsys window 2>/dev/null | grep -a -m1 'mCurrentFocus' | tr -d '\r')"
    RESUMED=false
    case "$FOCUS" in *"$PACKAGE"*) RESUMED=true ;; esac
    if [ "$RESUMED" != true ] || [ "$HFATAL" -gt 0 ] || [ "$HANR" -gt 0 ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        rm -f "$HLOG"
    fi
    record hot "$i" "$RESUMED" -1 "$HFATAL" "$HANR" 0 -1
    echo "  hot   #$i resumed=$RESUMED fatal=$HFATAL anr=$HANR"
done

TOTAL=$((PAIRS * 2))
{
    echo "{"
    echo "  \"schema\": \"glory.android_launch_soak.v1\","
    echo "  \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"git_commit\": \"$GIT_COMMIT\","
    echo "  \"package\": \"$PACKAGE\","
    echo "  \"device_model\": \"$DEVICE_MODEL\","
    echo "  \"android_release\": \"$ANDROID_REL\","
    echo "  \"cache_condition\": \"warm_after_force_stop\","
    echo "  \"pairs\": $PAIRS,"
    echo "  \"total_launches\": $TOTAL,"
    echo "  \"failures\": $FAIL_COUNT,"
    echo "  \"note_cold\": \"冷 = am force-stop 后启动。进程是新的，page cache 与已解压资源仍在，不是重启设备后的首启。\","
    echo "  \"note_hot\": \"热 = HOME 切后台再回前台。进程不死，不重跑 StartupTrace，所以判据是回到前台且无 fatal/ANR，不是 T3。\","
    echo "  \"runs\": ["
    for idx in "${!RESULTS[@]}"; do
        sep=","
        [ "$idx" -eq $((${#RESULTS[@]} - 1)) ] && sep=""
        echo "    ${RESULTS[$idx]}$sep"
    done
    echo "  ]"
    echo "}"
} > "$OUT_DIR/soak.json"

echo
echo "total=$TOTAL failures=$FAIL_COUNT -> $OUT_DIR/soak.json"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
