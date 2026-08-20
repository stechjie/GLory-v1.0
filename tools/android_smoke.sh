#!/usr/bin/env bash
# README A4 — Android 出包与设备回归门禁。
#
# 为什么不用 Godot 编辑器的 Remote Deploy：它只回答"能不能跑起来"，装的是临时
# APK，装完即弃 —— 没有哈希、没有 commit 关联、没有 logcat、没有截图。而 A4 的
# 全部意义在于可追溯性："每一份 QA APK 都能反查到源码 commit 和资源 manifest"。
# README 的「不应被误判为完成的事项」第一条正是 "BetaV9.apk 的文件存在不等于它
# 来自本次源码"。
#
# 本脚本每次运行都产出一份自洽的证据包：APK 本身、它的 SHA-256、来源 commit、
# 资源 manifest 指纹、Godot 版本、安装结果、冷启动 logcat 与截图。
#
# 用法：
#   tools/android_smoke.sh [--out DIR] [--godot PATH] [--adb PATH]
#                          [--preset NAME] [--skip-export] [--keep N]
#
# 退出码：0 通过；1 有失败项。绝不因为"进程退出了"就算通过 —— 见 README A3。

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR=""
GODOT_BIN=""
ADB_BIN=""
PRESET="Android"
SERIAL=""
SKIP_EXPORT=0
SKIP_INSTALL=0
KEEP=5
LAUNCH_WAIT_SEC=25
INSTALL_TIMEOUT_SEC=180

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        --godot) GODOT_BIN="$2"; shift 2 ;;
        --adb) ADB_BIN="$2"; shift 2 ;;
        --preset) PRESET="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        --skip-export) SKIP_EXPORT=1; shift ;;
        --skip-install) SKIP_INSTALL=1; shift ;;
        --keep) KEEP="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

FAILURES=()
fail() { FAILURES+=("$1"); echo "[android_smoke] FAIL $1" >&2; }
note() { echo "[android_smoke] $1"; }

# --- 工具定位 -----------------------------------------------------------------
if [ -z "$GODOT_BIN" ]; then
    for candidate in \
        "$HOME/Desktop/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe" \
        "$(command -v godot 2>/dev/null)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && GODOT_BIN="$candidate" && break
    done
fi
if [ -z "$ADB_BIN" ]; then
    for candidate in \
        "$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe" \
        "$(command -v adb 2>/dev/null)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && ADB_BIN="$candidate" && break
    done
fi
[ -x "$GODOT_BIN" ] || { echo "Godot not found; pass --godot <path>" >&2; exit 2; }
[ -x "$ADB_BIN" ] || { echo "adb not found; pass --adb <path>" >&2; exit 2; }

if [ -n "$SERIAL" ]; then
    export ANDROID_SERIAL="$SERIAL"
    note "targeting serial $SERIAL"
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
COMMIT_FULL="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | grep -cv '^??' || true)"
[ -z "$OUT_DIR" ] && OUT_DIR="$PROJECT_ROOT/../build/android"
mkdir -p "$OUT_DIR"
RUN_DIR="$OUT_DIR/smoke_${STAMP}_${COMMIT}"
mkdir -p "$RUN_DIR"
APK="$OUT_DIR/glory-${COMMIT}-${STAMP}.apk"

# 资源 manifest 指纹：这是 APK 与资源版本的唯一绑定点。
MANIFEST_SHA="$(MANIFEST_PATH="$PROJECT_ROOT/assets.manifest.json" python -c 'import json,io,os;print(json.load(io.open(os.environ["MANIFEST_PATH"],encoding="utf-8"))["inventory_sha256"])' 2>/dev/null || echo unknown)"
GODOT_VERSION="$("$GODOT_BIN" --version 2>/dev/null | tr -d '\r' | tail -1)"

note "commit=$COMMIT dirty_tracked_files=$DIRTY godot=$GODOT_VERSION"
note "manifest=$MANIFEST_SHA"
note "out=$RUN_DIR"

# --- 设备 ---------------------------------------------------------------------
if [ -n "$SERIAL" ]; then
    DEVICES="$("$ADB_BIN" devices | grep -c "^$SERIAL[[:space:]]*device$" || true)"
else
    DEVICES="$("$ADB_BIN" devices | tail -n +2 | grep -c 'device$' || true)"
fi
if [ "$DEVICES" -lt 1 ]; then
    fail "no_device: adb 没有看到已授权的设备"
    echo "{\"passed\":false,\"failures\":[\"no_device\"]}" > "$RUN_DIR/smoke.json"
    exit 1
fi
DEVICE_MODEL="$("$ADB_BIN" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
DEVICE_RELEASE="$("$ADB_BIN" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
DEVICE_SDK="$("$ADB_BIN" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
DEVICE_ABI="$("$ADB_BIN" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
note "device=$DEVICE_MODEL android=$DEVICE_RELEASE api=$DEVICE_SDK abi=$DEVICE_ABI"

# 包名从预设读，不写死：改了预设而脚本没跟上，是最容易装错包的方式。
PACKAGE="$(grep -m1 'package/unique_name=' "$PROJECT_ROOT/export_presets.cfg" | sed 's/.*="\(.*\)"/\1/')"
[ -n "$PACKAGE" ] || { fail "no_package_name: 从 export_presets.cfg 读不到 package/unique_name"; PACKAGE="unknown"; }
note "package=$PACKAGE"

# --- 导出 ---------------------------------------------------------------------
EXPORT_LOG="$RUN_DIR/export.log"
if [ "$SKIP_EXPORT" -eq 0 ]; then
    # export_presets.cfg 在 .gitignore 里（将来的 Release 预设会带 keystore 口令），
    # 所以 A5 设的 exclude_filter 不随仓库走。新克隆一份代码出包，过滤器是空的，
    # backups/ 和 *.bak 会被静默打进 APK —— 导出照样"成功"，只是包大了几百 MB。
    # 这正是本脚本要防的那类假绿，所以宁可在导出前就停。
    if ! grep -q 'exclude_filter="[^"]' "$PROJECT_ROOT/export_presets.cfg" 2>/dev/null; then
        note "FAIL empty_exclude_filter: export_presets.cfg 的 exclude_filter 是空的"
        note "它不在 git 里（见 .gitignore），需要照 README A5 手动补上，否则会把 backups/ 打进包"
        cat > "$RUN_DIR/smoke.json" <<GUARD
{
  "passed": false,
  "failures": ["empty_exclude_filter: export_presets.cfg has no exclude_filter"],
  "stopped_before": "export",
  "reason": "export_presets.cfg is gitignored, so a fresh clone has an empty exclude_filter; exporting would silently pack backups/ into the APK"
}
GUARD
        exit 1
    fi
    note "exporting preset '$PRESET' ..."
    "$GODOT_BIN" --headless --path "$PROJECT_ROOT" --export-debug "$PRESET" "$APK" > "$EXPORT_LOG" 2>&1
    EXPORT_RC=$?
    # Godot 的导出退出码不可靠（见 README A3），所以以产物是否存在为准。
    if [ ! -f "$APK" ]; then
        fail "export_failed: 没有产出 APK（rc=$EXPORT_RC，见 export.log）"
        tail -20 "$EXPORT_LOG" >&2
        echo "{\"passed\":false,\"failures\":[\"export_failed\"]}" > "$RUN_DIR/smoke.json"
        exit 1
    fi
    # 导出日志里的缺资源/缺脚本错误不该被"出包成功"掩盖。
    EXPORT_ERRORS="$(grep -icE 'ERROR|Failed to load|Can.t open|No loader found' "$EXPORT_LOG" || true)"
    [ "$EXPORT_ERRORS" -gt 0 ] && note "export.log 中有 $EXPORT_ERRORS 行错误/告警，已保留全文"
else
    APK="$(ls -t "$OUT_DIR"/*.apk 2>/dev/null | head -1)"
    [ -f "$APK" ] || { fail "no_apk_to_install"; exit 1; }
    note "skip-export，复用 $APK"
    EXPORT_ERRORS=0
fi

APK_BYTES="$(stat -c %s "$APK" 2>/dev/null || echo 0)"
APK_MIB="$(python -c "print('%.1f' % ($APK_BYTES/1048576.0))" 2>/dev/null || echo 0)"
APK_SHA="$(sha256sum "$APK" | cut -d' ' -f1)"
note "apk=$(basename "$APK") size=${APK_MIB} MiB sha256=$APK_SHA"

# --- 安装（增量挂起时回退）----------------------------------------------------
# vivo 上实测过 adb install 在增量会话里停滞。先直连装，超时就推到设备本地再让
# pm install 装 —— 后者失败时的报错也更能诊断。
INSTALL_LOG="$RUN_DIR/install.log"
INSTALL_METHOD="adb_install"
# 实测：694 MB 的导出要几分钟，设备会在这期间掉线（transport_id 会变）。
# 直接判失败是误判，先给它一段时间重新上线。
"$ADB_BIN" wait-for-device >/dev/null 2>&1 &
WAIT_PID=$!
for _ in $(seq 1 30); do
    [ "$("$ADB_BIN" devices | tail -n +2 | grep -c 'device$' || true)" -ge 1 ] && break
    sleep 2
done
kill $WAIT_PID 2>/dev/null
APK_WIN="$(cygpath -w "$APK" 2>/dev/null || echo "$APK")"

# MSYS_NO_PATHCONV：见上。设备侧路径必须原样传过去。
_push_install() {
    local remote="/data/local/tmp/$(basename "$APK")"
    MSYS_NO_PATHCONV=1 "$ADB_BIN" push "$APK_WIN" "$remote" >> "$INSTALL_LOG" 2>&1
    MSYS_NO_PATHCONV=1 timeout "$INSTALL_TIMEOUT_SEC" "$ADB_BIN" shell pm install -r "$remote" >> "$INSTALL_LOG" 2>&1
    INSTALL_RC=$?
    MSYS_NO_PATHCONV=1 "$ADB_BIN" shell rm -f "$remote" >> "$INSTALL_LOG" 2>&1
}

# 大包直接走 push + pm install，不先试 adb install。实测 694 MB 的 streamed
# install 会把设备的 adbd 拖挂成 offline，之后连 shell 都执行不了，只能在手机上
# 重开 USB 调试才能恢复。小包才值得先试更快的直连安装。
# --skip-install 存在的唯一理由是大包重推会把 adbd 拖挂，而不是为了图快跳过验证。
# 因此它不许无条件相信设备上那一份：先算机上 base.apk 的 SHA-256，与本地 APK 逐
# 位比对，不一致就判失败。A4 的全部意义是"每一份 QA APK 都能反查到源码 commit"，
# 跳过安装可以，跳过"机上跑的确实是这一份"不行。
if [ "$SKIP_INSTALL" -eq 1 ]; then
    INSTALL_METHOD="skipped_verified_by_hash"
    note "skip-install：改为校验设备上已装的那一份"
    ON_DEVICE_PATH="$("$ADB_BIN" shell pm path "$PACKAGE" 2>/dev/null | tr -d '\r' | head -1)"
    ON_DEVICE_PATH="${ON_DEVICE_PATH#package:}"
    if [ -z "$ON_DEVICE_PATH" ]; then
        fail "skip_install_not_installed: 设备上没有 $PACKAGE，无从校验"
        echo "no package on device" > "$INSTALL_LOG"
    else
        ON_DEVICE_SHA="$(MSYS_NO_PATHCONV=1 "$ADB_BIN" shell sha256sum "$ON_DEVICE_PATH" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
        echo "skip-install path=$ON_DEVICE_PATH sha256=$ON_DEVICE_SHA local=$APK_SHA" > "$INSTALL_LOG"
        if [ "$ON_DEVICE_SHA" = "$APK_SHA" ]; then
            note "机上 APK 与本地逐字节一致（$ON_DEVICE_PATH）"
            echo "Success (verified by sha256)" >> "$INSTALL_LOG"
        else
            fail "skip_install_hash_mismatch: 机上 ${ON_DEVICE_SHA:-<读不到>} != 本地 $APK_SHA"
        fi
    fi
else
    APK_MIB_INT="${APK_MIB%%.*}"
    if [ "${APK_MIB_INT:-0}" -ge 300 ]; then
        note "APK ${APK_MIB} MiB 偏大，跳过 streamed install，直接 push + pm install"
        INSTALL_METHOD="push_pm_install"
        _push_install
    else
        timeout "$INSTALL_TIMEOUT_SEC" "$ADB_BIN" install -r "$APK_WIN" > "$INSTALL_LOG" 2>&1
        INSTALL_RC=$?
    fi
    if [ $INSTALL_RC -ne 0 ] || ! grep -qi 'Success' "$INSTALL_LOG"; then
        note "首次安装未成功（rc=$INSTALL_RC），回退为 push + pm install"
        INSTALL_METHOD="push_pm_install"
        _push_install
    fi
    if grep -qi 'Success' "$INSTALL_LOG"; then
        note "install ok via $INSTALL_METHOD"
    else
        fail "install_failed: 两种方式都没装上（见 install.log）"
        tail -10 "$INSTALL_LOG" >&2
    fi

fi

# 推完 694 MiB 后 adbd 常常要缓一阵，期间任何 shell 都以 "device offline" 失败。
# 不区分这一点，通道抖动就会被写成 not_installed —— 2026-08-20 的一次运行正是如此：
# pm install 报了 Success、设备上 lastUpdateTime 也确实更新了，脚本却判了没装上。
# 假的失败和假的通过一样不能要，它会让下一个人去查一个并不存在的安装问题。
_wait_transport() {
    local deadline=$((SECONDS + 60))
    while [ $SECONDS -lt $deadline ]; do
        [ "$("$ADB_BIN" get-state 2>/dev/null | tr -d '\r')" = "device" ] && return 0
        "$ADB_BIN" reconnect >/dev/null 2>&1 || true
        sleep 3
    done
    return 1
}

if _wait_transport; then
    INSTALLED_VERSION="$("$ADB_BIN" shell dumpsys package "$PACKAGE" 2>/dev/null | tr -d '\r' | grep -m1 'versionName' | sed 's/.*versionName=//')"
    INSTALLED_PATH="$("$ADB_BIN" shell pm path "$PACKAGE" 2>/dev/null | tr -d '\r' | head -1)"
    [ -n "$INSTALLED_PATH" ] || fail "not_installed: pm path 查不到 $PACKAGE"
else
    fail "device_lost_after_install: 推包后 60 秒内 adb 通道没恢复，无法确认安装结果（这不等于没装上）"
fi

# --- 冷启动 -------------------------------------------------------------------
# 安装没成功就必须停在这里。设备上可能装着同名的旧版本，继续走下去 monkey 会把
# 旧 app 拉起来，报出一份漂亮的 pid/内存/无错误 —— 一次失败的安装会被读成通过。
if [ ${#FAILURES[@]} -gt 0 ]; then
    note "安装未成功，跳过冷启动：继续下去只会测到设备上的旧版本"
    FAIL_JSON_EARLY="$(printf "%s\n" "${FAILURES[@]}" | python -c "import sys,json;sys.stdout.buffer.write(json.dumps([l.strip() for l in sys.stdin.buffer.read().decode('utf-8','replace').splitlines() if l.strip()],ensure_ascii=False).encode('utf-8'))" 2>/dev/null)"
    [ -n "$FAIL_JSON_EARLY" ] || FAIL_JSON_EARLY='["failure_list_encoding_error"]'
    cat > "$RUN_DIR/smoke.json" <<EARLY
{
  "passed": false,
  "failures": $FAIL_JSON_EARLY,
  "stopped_before": "launch",
  "reason": "install did not succeed; launching would have measured the previously installed build",
  "source": {"commit": "$COMMIT_FULL", "assets_manifest_inventory_sha256": "$MANIFEST_SHA", "godot": "$GODOT_VERSION"},
  "apk": {"file": "$(basename "$APK")", "bytes": $APK_BYTES, "mib": $APK_MIB, "sha256": "$APK_SHA", "package": "$PACKAGE"},
  "device": {"model": "$DEVICE_MODEL", "android": "$DEVICE_RELEASE", "api": $DEVICE_SDK, "abi": "$DEVICE_ABI"}
}
EARLY
    note "FAIL: ${FAILURES[*]}"
    exit 1
fi

"$ADB_BIN" shell am force-stop "$PACKAGE" >/dev/null 2>&1
"$ADB_BIN" logcat -c >/dev/null 2>&1
LAUNCH_MS_START="$(date +%s%3N)"
"$ADB_BIN" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 > "$RUN_DIR/launch.log" 2>&1
sleep "$LAUNCH_WAIT_SEC"
LAUNCH_MS="$(( $(date +%s%3N) - LAUNCH_MS_START ))"

"$ADB_BIN" logcat -d -v brief > "$RUN_DIR/logcat_full.log" 2>&1
grep -aE 'FATAL EXCEPTION|E Godot|SCRIPT ERROR|ANR in' "$RUN_DIR/logcat_full.log" > "$RUN_DIR/logcat_errors.log" 2>/dev/null
FATAL_COUNT="$(grep -ac 'FATAL EXCEPTION' "$RUN_DIR/logcat_errors.log" || true)"
SCRIPT_ERR_COUNT="$(grep -ac 'SCRIPT ERROR' "$RUN_DIR/logcat_errors.log" || true)"
[ "$FATAL_COUNT" -gt 0 ] && fail "fatal_exception: logcat 中有 $FATAL_COUNT 条 FATAL EXCEPTION"
[ "$SCRIPT_ERR_COUNT" -gt 0 ] && fail "script_error: logcat 中有 $SCRIPT_ERR_COUNT 条 SCRIPT ERROR"

PID="$("$ADB_BIN" shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r')"
[ -n "$PID" ] || fail "process_dead: 冷启动 ${LAUNCH_WAIT_SEC}s 后进程不在了"

"$ADB_BIN" exec-out screencap -p > "$RUN_DIR/launch.png" 2>/dev/null
SHOT_BYTES="$(stat -c %s "$RUN_DIR/launch.png" 2>/dev/null || echo 0)"
[ "$SHOT_BYTES" -gt 1024 ] || fail "screenshot_failed: 截图为空"

MEM_KB="$("$ADB_BIN" shell dumpsys meminfo "$PACKAGE" 2>/dev/null | tr -d '\r' | grep -m1 'TOTAL PSS' | awk '{print $3}')"
[ -n "$MEM_KB" ] || MEM_KB=0

# --- 结果 ---------------------------------------------------------------------
PASSED=true
[ ${#FAILURES[@]} -gt 0 ] && PASSED=false
FAIL_JSON="$(printf "%s\n" "${FAILURES[@]:-}" | python -c "import sys,json;sys.stdout.buffer.write(json.dumps([l.strip() for l in sys.stdin.buffer.read().decode('utf-8','replace').splitlines() if l.strip()],ensure_ascii=False).encode('utf-8'))" 2>/dev/null)"
[ -n "$FAIL_JSON" ] || FAIL_JSON='["failure_list_encoding_error"]'

cat > "$RUN_DIR/smoke.json" <<JSON
{
  "passed": $PASSED,
  "failures": $FAIL_JSON,
  "generated": "$STAMP",
  "source": {
    "commit": "$COMMIT_FULL",
    "commit_short": "$COMMIT",
    "uncommitted_tracked_files": $DIRTY,
    "assets_manifest_inventory_sha256": "$MANIFEST_SHA",
    "godot": "$GODOT_VERSION"
  },
  "apk": {
    "file": "$(basename "$APK")",
    "bytes": $APK_BYTES,
    "mib": $APK_MIB,
    "sha256": "$APK_SHA",
    "package": "$PACKAGE",
    "export_log_error_lines": $EXPORT_ERRORS
  },
  "device": {
    "serial": "${SERIAL:-usb}",
    "model": "$DEVICE_MODEL",
    "android": "$DEVICE_RELEASE",
    "api": $DEVICE_SDK,
    "abi": "$DEVICE_ABI"
  },
  "install": {
    "method": "$INSTALL_METHOD",
    "installed_path": "$INSTALLED_PATH",
    "version_name": "$INSTALLED_VERSION"
  },
  "launch": {
    "wait_sec": $LAUNCH_WAIT_SEC,
    "elapsed_ms": $LAUNCH_MS,
    "pid": "$PID",
    "fatal_exception_count": $FATAL_COUNT,
    "script_error_count": $SCRIPT_ERR_COUNT,
    "total_pss_kb": $MEM_KB,
    "screenshot_bytes": $SHOT_BYTES
  },
  "note": "Debug 构建，仅用于 QA。不得当作 Release 验收：没有私有 keystore 签名、没有体积门槛、没有低端机与双设备联机验收。"
}
JSON

if ! SMOKE_JSON="$RUN_DIR/smoke.json" python -c 'import json,io,os;json.load(io.open(os.environ["SMOKE_JSON"],encoding="utf-8"))' 2>/dev/null; then
    fail "evidence_unparseable: smoke.json 不是合法 JSON —— 读不出来的证据等于没有证据"
fi

note "----- 结果 -----"
note "apk       ${APK_MIB} MiB  sha256=${APK_SHA:0:16}"
note "device    $DEVICE_MODEL  Android $DEVICE_RELEASE (api $DEVICE_SDK, $DEVICE_ABI)"
note "install   $INSTALL_METHOD  path=$INSTALLED_PATH"
note "launch    pid=$PID  fatal=$FATAL_COUNT  script_error=$SCRIPT_ERR_COUNT  pss=${MEM_KB}KB"
note "evidence  $RUN_DIR"

# 旧构建清理，只留最近 N 份。
ls -t "$OUT_DIR"/*.apk 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do rm -f "$old"; done

if [ ${#FAILURES[@]} -eq 0 ]; then
    note "PASS"
    exit 0
fi
note "FAIL: ${FAILURES[*]}"
exit 1
