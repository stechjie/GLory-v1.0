#!/usr/bin/env bash
# 在真机上跑 D0 固定战斗基线，并与同一 commit 的桌面结果逐条比对哈希。
#
# 这是 README C4 验收第 3 条（桌面/Android digest 一致）与 Director D0/D5/D6
# 「实机演出指标」缺的那一步。为什么必须是同一 commit 的两次运行，而不是拿设备
# 结果去比对证据目录里的旧哈希：那些哈希是历史提交的产物，对不上时你分不清是
# 跨平台不一致，还是这中间有人改了战斗——而这两件事的处理方式完全相反。
#
# 设备侧入口见 tools/DeviceHarness.gd：出包后既不能用位置参数覆盖主场景，也不能靠
# `am start --esa command_line` 传参（导出入口是 GodotAppLauncher，转发时丢 extras），
# 所以改成用 run-as 往 user://device_harness.json 写标记文件来触发。
#
# 用法：
#   bash tools/android_baseline.sh --serial <serial> [--rounds 1] [--skip-desktop]
#   bash tools/android_baseline.sh --serial <serial> --rounds 5,20,21   # Boss 与满配样本
#   bash tools/android_baseline.sh --serial <serial> --cold-cache        # 先清着色器缓存，量首启

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="glory.beta001"
LAUNCH_ACTIVITY="com.godot.game.GodotAppLauncher"
SERIAL=""
ADB_BIN=""
GODOT_BIN=""
ROUNDS="1"
OUT_DIR=""
SKIP_DESKTOP=0
COLD_CACHE=0
DEVICE_TIMEOUT_SEC=2400   # 多回合样本（第 21 回合满配 18 个敌人）在真机上要跑很久

FAILURES=()

note() { echo "[android_baseline] $*"; }
fail() { FAILURES+=("$1"); note "FAIL $1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --serial) SERIAL="$2"; shift 2 ;;
        --adb) ADB_BIN="$2"; shift 2 ;;
        --godot) GODOT_BIN="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --skip-desktop) SKIP_DESKTOP=1; shift ;;
        --cold-cache) COLD_CACHE=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# --- 环境 ---------------------------------------------------------------------
if [ -z "$ADB_BIN" ]; then
    for candidate in \
        "/c/Users/${USERNAME:-${USER:-none}}/AppData/Local/Android/Sdk/platform-tools/adb.exe" \
        "$(command -v adb || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && ADB_BIN="$candidate" && break
    done
fi
[ -x "$ADB_BIN" ] || { echo "找不到 adb，用 --adb 指定" >&2; exit 2; }
[ -n "$SERIAL" ] && export ANDROID_SERIAL="$SERIAL"

if [ -z "$GODOT_BIN" ]; then
    GODOT_BIN="$(ls /c/Users/*/Desktop/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64.exe 2>/dev/null | head -1)"
fi

COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
STAMP="$(date +%Y%m%d_%H%M%S)"
[ -n "$OUT_DIR" ] || OUT_DIR="$PROJECT_ROOT/../build/android/baseline_${STAMP}_${COMMIT}"
mkdir -p "$OUT_DIR/device" "$OUT_DIR/desktop"

PROJECT_ROOT_WIN="$(cygpath -m "$PROJECT_ROOT" 2>/dev/null || echo "$PROJECT_ROOT")"
OUT_DIR_WIN="$(cygpath -m "$OUT_DIR" 2>/dev/null || echo "$OUT_DIR")"

note "commit=$COMMIT dirty_tracked=$DIRTY rounds=$ROUNDS"
note "out=$OUT_DIR"

# --- 桌面侧 -------------------------------------------------------------------
# 先跑桌面：设备那边失败时，至少手上有一份可比对的当前基线。
if [ "$SKIP_DESKTOP" -eq 0 ]; then
    if [ ! -x "$GODOT_BIN" ]; then
        fail "no_godot: 找不到 Godot，无法产出桌面对照（可用 --skip-desktop 跳过）"
    else
        note "桌面基线运行中 ..."
        # 这里不能加 MSYS_NO_PATHCONV：Godot 是 Windows 程序，读不懂 /c/Users/...
        # 这种 MSYS 路径。设备侧路径要禁止转换，本机路径要转换——方向正好相反。
        "$GODOT_BIN" --headless --path "$PROJECT_ROOT_WIN" \
            res://tools/battle_presentation_baseline.tscn -- \
            --out "$OUT_DIR_WIN/desktop" --rounds "$ROUNDS" --no-screenshots \
            > "$OUT_DIR/desktop_run.log" 2>&1
        # "跑完了但报了缺陷"和"根本没跑完"要分开。前者的摘要依然有效、依然可比对，
        # 只是记录到了演出层的问题；后者根本没有可比的东西。混成一条的话，一个已知
        # 缺陷会让人以为跨平台比对本身失败了。
        if grep -q 'complete passed=true' "$OUT_DIR/desktop_run.log"; then
            :
        elif grep -q 'D0BASELINE. complete' "$OUT_DIR/desktop_run.log"; then
            fail "desktop_recorder_reported_defects: 桌面基线跑完且摘要有效，但记录器报告了缺陷（见 desktop_run.log）"
        else
            fail "desktop_baseline_incomplete: 桌面基线没跑完（见 desktop_run.log）"
        fi
    fi
fi

# --- 设备侧 -------------------------------------------------------------------
DEVICE_STATE="$("$ADB_BIN" get-state 2>/dev/null | tr -d '\r')"
if [ "$DEVICE_STATE" != "device" ]; then
    fail "no_device: adb 状态是 '${DEVICE_STATE:-<空>}'"
else
    DEVICE_MODEL="$("$ADB_BIN" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
    DEVICE_ABI="$("$ADB_BIN" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
    note "device=$DEVICE_MODEL abi=$DEVICE_ABI"

    # 上一轮的产物必须先删干净。留着的话，本轮如果根本没跑起来，拉回来的会是
    # 上一次的结果 —— 一份看起来完整、其实来自别的构建的证据。
    "$ADB_BIN" shell run-as "$PACKAGE" rm -rf files/battle_presentation_baseline >/dev/null 2>&1

    # 冷缓存：着色器缓存留在 files/shader_cache 里，跨安装存活。不清掉的话量到的
    # 永远是"暖缓存"，代表不了玩家首次安装后的体验 —— 而首启正是最慢、最该量的那次。
    if [ "$COLD_CACHE" -eq 1 ]; then
        note "清空设备着色器缓存（冷缓存测量）"
        "$ADB_BIN" shell run-as "$PACKAGE" rm -rf files/shader_cache >/dev/null 2>&1
        REMAIN="$("$ADB_BIN" shell run-as "$PACKAGE" ls files 2>/dev/null | tr -d '\r' | grep -c shader_cache)"
        [ "${REMAIN:-0}" -eq 0 ] || fail "cold_cache_not_cleared: shader_cache 没删掉，量到的仍是暖缓存"
    fi

    "$ADB_BIN" shell am force-stop "$PACKAGE" >/dev/null 2>&1
    "$ADB_BIN" logcat -c >/dev/null 2>&1

    # 用标记文件而不是 am start 的 command_line extra：后者在这个包上到不了 Godot
    # （导出入口是 GodotAppLauncher，真正的 GodotApp 没 exported，转发时丢了 extras）。
    # 详见 tools/DeviceHarness.gd 顶部记录的三次验证。
    #
    # 设备侧刻意**不**加 --no-screenshots。记录器会截战斗的 start/mid/end，那正是
    # A4 验收要的「首场战斗截图」，而且它直接渲染 BattleScreen，完全不经过备战 UI ——
    # 也就不会碰到同事正在拆的 PrepScreen。桌面那边关掉截图纯粹是为了跑得快，
    # 截图不参与哈希。
    TRIGGER_JSON="{\"tool_args\": [\"--rounds\", \"${ROUNDS}\"]}"
    note "写触发文件：files/device_harness.json = $TRIGGER_JSON"
    printf '%s' "$TRIGGER_JSON" | "$ADB_BIN" shell run-as "$PACKAGE" sh -c \
        "'cat > files/device_harness.json'" 2>>"$OUT_DIR/launch.log"
    WROTE="$("$ADB_BIN" shell run-as "$PACKAGE" cat files/device_harness.json 2>/dev/null | tr -d '\r')"
    if [ -z "$WROTE" ]; then
        fail "trigger_write_failed: 标记文件没写进去，设备侧不会接管"
    else
        note "拉起 app ..."
        "$ADB_BIN" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 \
            > "$OUT_DIR/launch.log" 2>&1
    fi

    # 完成信号取磁盘产物，不取 logcat。这台设备每 16 ms 刷一条 CompositionEngine，
    # 几分钟就把环形缓冲挤爆 —— 2026-08-20 第一次跑时引擎日志被全部驱逐，导致
    # 分不清"没跑起来"和"跑了但看不到"。manifest.json 是记录器最后写的东西，
    # 它存在就等于跑完了，而且不会被任何东西驱逐。
    note "等待设备侧完成（最多 ${DEVICE_TIMEOUT_SEC}s）..."
    DEADLINE=$((SECONDS + DEVICE_TIMEOUT_SEC))
    DEVICE_DONE=0
    while [ $SECONDS -lt $DEADLINE ]; do
        if "$ADB_BIN" shell run-as "$PACKAGE" \
                test -f files/battle_presentation_baseline/manifest.json 2>/dev/null; then
            DEVICE_DONE=1
            break
        fi
        sleep 5
    done
    # logcat 按 tag 过滤后再存：不过滤的话正事全被刷屏埋掉。
    "$ADB_BIN" logcat -d -s godot > "$OUT_DIR/device_logcat.log" 2>/dev/null

    if [ "$DEVICE_DONE" -ne 1 ]; then
        if grep -q 'DEVICE_HARNESS. 已接管' "$OUT_DIR/device_logcat.log" 2>/dev/null; then
            fail "device_run_incomplete: harness 接管了但没跑完（见 device_logcat.log）"
        elif grep -q 'DEVICE_HARNESS. 未接管' "$OUT_DIR/device_logcat.log" 2>/dev/null; then
            fail "trigger_not_seen: 标记文件写进去了，但 app 启动时没读到（见 device_logcat.log）"
        else
            fail "harness_never_ran: 日志里没有 DEVICE_HARNESS —— 设备上的包多半不含本次改动"
        fi
    else
        note "设备侧完成，取回产物 ..."
        # run-as + tar 而不是 adb pull：user:// 在应用私有目录里，pull 没有权限。
        "$ADB_BIN" exec-out run-as "$PACKAGE" tar cf - files/battle_presentation_baseline \
            > "$OUT_DIR/device_files.tar" 2>/dev/null
        if [ -s "$OUT_DIR/device_files.tar" ]; then
            tar xf "$OUT_DIR/device_files.tar" -C "$OUT_DIR/device" --strip-components=2 2>/dev/null \
                || fail "device_extract_failed: tar 解不开"
            rm -f "$OUT_DIR/device_files.tar"
        else
            fail "device_pull_failed: 取回的 tar 是空的"
        fi
    fi
fi

# --- 比对 ---------------------------------------------------------------------
COMPARE_JSON="$OUT_DIR/digest_comparison.json"
DESKTOP_DIR="$OUT_DIR/desktop" DEVICE_DIR="$OUT_DIR/device" OUT_JSON="$COMPARE_JSON" \
COMMIT="$COMMIT" ROUNDS="$ROUNDS" PYTHONIOENCODING=utf-8 python - <<'PY' 2>&1 | tee "$OUT_DIR/compare.log"
import io, json, os, sys

desktop, device = os.environ["DESKTOP_DIR"], os.environ["DEVICE_DIR"]
# 只比 digest，不比性能：帧率和内存在两个平台上本来就不同，那不是不一致。
# 要证明的是"同一份回放在两边算出同一个结果"。
KEYS = ["roster_sha256", "replay_sha256", "frame_events_sha256", "final_state_sha256", "repeatable"]

def load(root, rnd):
    p = os.path.join(root, "round_%02d" % rnd, "hashes.json")
    if not os.path.exists(p):
        return None
    return json.load(io.open(p, encoding="utf-8"))

rounds = [int(r) for r in os.environ["ROUNDS"].split(",") if r.strip().isdigit()]
out = {"commit": os.environ["COMMIT"], "rounds": {}, "match": True, "notes": []}

for rnd in rounds:
    a, b = load(desktop, rnd), load(device, rnd)
    entry = {"desktop_present": a is not None, "device_present": b is not None, "fields": {}}
    if a is None or b is None:
        entry["verdict"] = "missing"
        out["match"] = False
        out["notes"].append("round %d: %s 缺结果" % (
            rnd, "两侧都" if a is None and b is None else ("桌面" if a is None else "设备")))
    else:
        same = True
        for k in KEYS:
            av, bv = a.get(k), b.get(k)
            entry["fields"][k] = {"desktop": av, "device": bv, "equal": av == bv}
            if av != bv:
                same = False
        entry["verdict"] = "identical" if same else "differs"
        if not same:
            out["match"] = False
    out["rounds"][str(rnd)] = entry

io.open(os.environ["OUT_JSON"], "w", encoding="utf-8", newline="\n").write(
    json.dumps(out, ensure_ascii=False, indent=2) + "\n")

for rnd, entry in sorted(out["rounds"].items()):
    print("round %s: %s" % (rnd, entry["verdict"]))
    for k, v in entry.get("fields", {}).items():
        mark = "OK " if v["equal"] else "DIFF"
        print("  %s %-20s desktop=%s" % (mark, k, str(v["desktop"])[:20]))
        if not v["equal"]:
            print("       %-20s device =%s" % ("", str(v["device"])[:20]))
for n in out["notes"]:
    print("note:", n)

# 退出码要分清"比过了但不一样"和"根本没得比"。混成一个的话，设备侧压根没跑起来
# 会被读成跨平台不一致，然后有人去查一个并不存在的确定性问题。
if out["match"]:
    sys.exit(0)
sys.exit(2 if any(e["verdict"] == "missing" for e in out["rounds"].values()) else 1)
PY
COMPARE_RC=${PIPESTATUS[0]}
case "$COMPARE_RC" in
    0) ;;
    2) fail "digest_incomparable: 有一侧没有结果，没能做成比对（见 digest_comparison.json）" ;;
    *) fail "digest_mismatch: 同一 commit 下桌面与设备的回放摘要不一致（见 digest_comparison.json）" ;;
esac

# --- 收尾 ---------------------------------------------------------------------
note "----- 结果 -----"
note "证据 $OUT_DIR"
if [ ${#FAILURES[@]} -eq 0 ]; then
    note "PASS：同一 commit 下桌面与设备的回放摘要逐字段一致"
    exit 0
fi
note "FAIL: ${FAILURES[*]}"
exit 1
