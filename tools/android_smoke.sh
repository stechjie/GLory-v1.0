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
#                          [--assert-startup]
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
ASSERT_STARTUP=0

# Startup budgets from the V3 review. Reported by default, enforced only with
# --assert-startup.
#
# Why not enforced yet: these numbers were written before anything measured the
# phases they describe, and there is still no branded Bootstrap scene, so T1 is
# "whenever the renderer first presented", not "the Glory splash appeared". Turning
# them into a gate before a baseline exists just produces a red nobody believes.
# Take a baseline first, then flip this on in its own commit.
T1_MAX_MS=800
T3_MAX_MS=3000

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        --godot) GODOT_BIN="$2"; shift 2 ;;
        --adb) ADB_BIN="$2"; shift 2 ;;
        --preset) PRESET="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        --skip-export) SKIP_EXPORT=1; shift ;;
        --skip-install) SKIP_INSTALL=1; shift ;;
        --assert-startup) ASSERT_STARTUP=1; shift ;;
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

# 版本号在这里读一次，install 段复用。以前只在 install 段读，导出时写不进 build_info。
PRESET_VERSION_CODE="$(grep -m1 'version/code=' "$PROJECT_ROOT/export_presets.cfg" | sed 's/.*=\([0-9]*\).*/\1/')"
PRESET_VERSION_NAME="$(grep -m1 'version/name=' "$PROJECT_ROOT/export_presets.cfg" | sed 's/.*="\(.*\)"/\1/')"
[ -n "$PRESET_VERSION_CODE" ] || PRESET_VERSION_CODE=0

# --- 构建身份 -----------------------------------------------------------------
# res://build_info.json 在导出**之前**写，才会被打进包里。这一份是"所测即所构建"
# 的锚点：装机之后再从 APK 里读回来比对，不一致就说明测的不是刚出的那个包。
#
# 写在这里而不是用 GDScript 现算：commit / dirty / manifest 指纹 / 包身份这些值
# 本脚本上面已经全算过了，在引擎里再实现一遍只会多一份会各自漂移的逻辑。
#
# preset_template_sha256 取**已提交的模板**，不取本机 export_presets.cfg —— 后者带
# 机器本地路径、将来还会带 keystore 口令，既不可复现也不能进证据链。
BUILD_INFO_PATH="$PROJECT_ROOT/build_info.json"
TEMPLATE_SHA="$(sha256sum "$PROJECT_ROOT/export_presets.template.cfg" 2>/dev/null | cut -d' ' -f1)"
[ -n "$TEMPLATE_SHA" ] || TEMPLATE_SHA="unknown"
BUILD_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$BUILD_INFO_PATH" <<BUILDINFO
{
  "schema_version": 1,
  "git_commit": "$COMMIT_FULL",
  "git_commit_short": "$COMMIT",
  "dirty_tracked_files": $DIRTY,
  "build_utc": "$BUILD_UTC",
  "asset_inventory_sha256": "$MANIFEST_SHA",
  "preset_template_sha256": "$TEMPLATE_SHA",
  "preset": "$PRESET",
  "package_id": "$PACKAGE",
  "version_code": $PRESET_VERSION_CODE,
  "version_name": "$PRESET_VERSION_NAME",
  "godot_version": "$GODOT_VERSION"
}
BUILDINFO
if ! BUILD_INFO_PATH="$BUILD_INFO_PATH" python -c 'import json,io,os;json.load(io.open(os.environ["BUILD_INFO_PATH"],encoding="utf-8"))' 2>/dev/null; then
    fail "build_info_unparseable: 生成的 build_info.json 不是合法 JSON"
fi
cp "$BUILD_INFO_PATH" "$RUN_DIR/build_info.json" 2>/dev/null || true
note "build_info commit=$COMMIT dirty=$DIRTY template_sha=${TEMPLATE_SHA:0:16} version_code=$PRESET_VERSION_CODE"

# --- 导出 ---------------------------------------------------------------------
EXPORT_LOG="$RUN_DIR/export.log"
if [ "$SKIP_EXPORT" -eq 0 ]; then
    # export_presets.cfg 在 .gitignore 里（将来的 Release 预设会带 keystore 口令），
    # 所以 A5 设的 exclude_filter 不随仓库走。新克隆一份代码出包，过滤器是空的，
    # backups/ 和 *.bak 会被静默打进 APK —— 导出照样"成功"，只是包大了几百 MB。
    # 这正是本脚本要防的那类假绿，所以宁可在导出前就停。
    if ! grep -q 'exclude_filter="[^"]' "$PROJECT_ROOT/export_presets.cfg" 2>/dev/null; then
        note "FAIL empty_exclude_filter: export_presets.cfg 的 exclude_filter 是空的"
        note "它不在 git 里（见 .gitignore）。修法：cp export_presets.template.cfg export_presets.cfg"
        note "模板由 tools/export_presets_template.tscn 生成，漂移由 tools/export_presets_check.tscn 盯着"
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

# --- 包内构建身份回读 ---------------------------------------------------------
# 把刚写的 build_info.json 从 APK 里读回来比对。这一步才是"所测即所构建"真正的
# 闭环：前面写的那份只证明脚本算对了值，读回来的这份才证明它进了这个包。
# --skip-export 时两者本就可能不同（复用的是旧包），所以只报告不判失败。
APK_BUILD_INFO="$RUN_DIR/build_info_in_apk.json"
APK_BUILD_COMMIT="unknown"
APK_BUILD_MATCH="unknown"
if APK_PATH="$APK" OUT_PATH="$APK_BUILD_INFO" python -c '
import zipfile, os, sys
z = zipfile.ZipFile(os.environ["APK_PATH"])
# Godot keeps res:// paths under a leading assets/ segment.
for name in ("assets/build_info.json", "build_info.json"):
    if name in z.namelist():
        data = z.read(name)
        with open(os.environ["OUT_PATH"], "wb") as handle:
            handle.write(data)
        sys.exit(0)
sys.exit(3)
' 2>/dev/null; then
    APK_BUILD_COMMIT="$(BI="$APK_BUILD_INFO" python -c 'import json,io,os;print(json.load(io.open(os.environ["BI"],encoding="utf-8")).get("git_commit","unknown"))' 2>/dev/null || echo unknown)"
    if [ "$SKIP_EXPORT" -eq 1 ]; then
        APK_BUILD_MATCH="skipped_reused_apk"
        note "build_info 包内 commit=${APK_BUILD_COMMIT:0:12}（--skip-export，复用旧包，不判失败）"
    elif [ "$APK_BUILD_COMMIT" = "$COMMIT_FULL" ]; then
        APK_BUILD_MATCH="match"
        note "build_info 包内 commit 与本次一致（${APK_BUILD_COMMIT:0:12}）"
    else
        APK_BUILD_MATCH="mismatch"
        fail "build_info_mismatch: 包内 commit=${APK_BUILD_COMMIT:0:12}，本次构建 commit=${COMMIT_FULL:0:12} —— 这个 APK 不是本次源码出的"
    fi
else
    APK_BUILD_MATCH="absent"
    if [ "$SKIP_EXPORT" -eq 1 ]; then
        note "包内没有 build_info.json（--skip-export，复用的是加入该文件之前出的包）"
    else
        fail "build_info_absent: 刚导出的 APK 里没有 build_info.json —— 导出没把它带上，构建身份无法追溯"
    fi
fi

# --- APK 内容扫描 -------------------------------------------------------------
APK_SCAN_JSON="$RUN_DIR/apk_content_scan.json"
APK_SCAN_STATUS="unknown"
if python "$PROJECT_ROOT/tools/apk_content_scan.py" "$APK" --json "$APK_SCAN_JSON" > "$RUN_DIR/apk_content_scan.log" 2>&1; then
    APK_SCAN_STATUS="pass"
    note "apk 内容扫描通过"
else
    APK_SCAN_STATUS="fail"
    fail "apk_content_scan: APK 里有不该发布的内容，见 apk_content_scan.log"
    tail -20 "$RUN_DIR/apk_content_scan.log" >&2
fi

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

# Accept only PackageManager's result line. A loose case-insensitive search for
# "Success" also matches adb's "daemon started successfully" banner, which once
# turned a disconnected install into a false success.
_install_log_has_success() {
    grep -qiE '^Success([[:space:](]|$)' "$INSTALL_LOG"
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
    if [ $INSTALL_RC -ne 0 ] || ! _install_log_has_success; then
        note "首次安装未成功（rc=$INSTALL_RC），回退为 push + pm install"
        INSTALL_METHOD="push_pm_install"
        _push_install
    fi
    if _install_log_has_success; then
        note "pm install returned Success via $INSTALL_METHOD; waiting for on-device APK hash verification"
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

# Defaulted before the branch because the script runs under `set -u`: on the
# device-lost path these stay unset, and referencing an unset variable would abort
# the script outright instead of letting it report the failure it just recorded.
INSTALLED_VERSION=""
INSTALLED_PATH=""
INSTALLED_APK_PATH=""
INSTALLED_APK_SHA=""
INSTALL_IDENTITY_VERIFIED=false
INSTALLED_VERSION_CODE=0
EXPECTED_VERSION_CODE=0
RIVAL_PACKAGES=""

if _wait_transport; then
    INSTALLED_VERSION="$("$ADB_BIN" shell dumpsys package "$PACKAGE" 2>/dev/null | tr -d '\r' | grep -m1 'versionName' | sed 's/.*versionName=//')"
    INSTALLED_PATH="$("$ADB_BIN" shell pm path "$PACKAGE" 2>/dev/null | tr -d '\r' | head -1)"
    [ -n "$INSTALLED_PATH" ] || fail "not_installed: pm path 查不到 $PACKAGE"

    # `pm install` printing Success is only an acknowledgement from PackageManager,
    # not proof that the package now on disk is the APK produced by this run. The
    # transport can drop at exactly this point, leaving the old package installed;
    # versionCode cannot distinguish it because repeated QA builds reuse version 5.
    # Hash the installed base.apk and require byte identity before claiming success.
    INSTALLED_APK_PATH="${INSTALLED_PATH#package:}"
    if [ -n "$INSTALLED_APK_PATH" ]; then
        INSTALLED_APK_SHA="$(MSYS_NO_PATHCONV=1 "$ADB_BIN" shell sha256sum "$INSTALLED_APK_PATH" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
    fi
    if [ "$INSTALLED_APK_SHA" = "$APK_SHA" ]; then
        INSTALL_IDENTITY_VERIFIED=true
        note "install verified via on-device APK sha256 ($INSTALLED_APK_PATH)"
    else
        fail "installed_apk_hash_mismatch: 设备上 ${INSTALLED_APK_SHA:-<读不到>} != 本地 $APK_SHA"
    fi

    # versionCode, not just versionName: versionName is "" in this project's presets,
    # so it can never disagree with anything. The code is what actually distinguishes
    # the build that was just pushed from one already on the device.
    INSTALLED_VERSION_CODE="$("$ADB_BIN" shell dumpsys package "$PACKAGE" 2>/dev/null | tr -d '\r' | grep -m1 'versionCode=' | sed 's/.*versionCode=\([0-9]*\).*/\1/')"
    EXPECTED_VERSION_CODE="$PRESET_VERSION_CODE"
    [ -n "$INSTALLED_VERSION_CODE" ] || INSTALLED_VERSION_CODE=0
    [ -n "$EXPECTED_VERSION_CODE" ] || EXPECTED_VERSION_CODE=0
    if [ "$SKIP_INSTALL" -eq 0 ] && [ "$INSTALLED_VERSION_CODE" != "$EXPECTED_VERSION_CODE" ]; then
        fail "version_code_mismatch: 设备上是 versionCode=$INSTALLED_VERSION_CODE，预设是 $EXPECTED_VERSION_CODE —— 测的不是刚推上去的那个包"
    fi
    note "version   code=$INSTALLED_VERSION_CODE (preset $EXPECTED_VERSION_CODE) name=${INSTALLED_VERSION:-<empty>}"

    # 同机多包防混淆。设备上同时躺着 com.glory.game 与 glory.beta001，桌面图标还长得
    # 一样 —— 人肉复测最容易在这里测错对象。脚本自己按包名启动不会认错，但报告必须
    # 把这件事说出来，否则下一份"真机实测"截图可能来自另一个包。
    RIVAL_PACKAGES="$("$ADB_BIN" shell pm list packages 2>/dev/null | tr -d '\r' | sed 's/^package://' | grep -iE '(^|\.)glory' | grep -vx "$PACKAGE" | tr '\n' ' ' | sed 's/ *$//')"
    if [ -n "$RIVAL_PACKAGES" ]; then
        note "!! 设备上还装着其它 Glory 包：$RIVAL_PACKAGES"
        note "!! 本次只针对 $PACKAGE。人工复测请照包名确认，不要照桌面图标。"
    fi
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
  "identity": {"build_info_in_apk": "$APK_BUILD_MATCH", "build_info_apk_commit": "$APK_BUILD_COMMIT", "apk_content_scan": "$APK_SCAN_STATUS", "preset_template_sha256": "$TEMPLATE_SHA"},
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
# 第二路按 tag 过滤。实测这台设备（25028RN03A）的 main 环形缓冲默认只有 64 KiB，
# 而框架每 16 ms 刷一条 CompositionEngine —— 引擎日志会在几十秒内被整体驱逐，
# 于是 GLORY_STARTUP 标记连同证据一起消失，白出一次 694 MiB 的包。
# 出包前建议先 `adb logcat -G 16M`；这一路是即使没调也还能捞到标记的兜底。
"$ADB_BIN" logcat -d -s godot:V > "$RUN_DIR/logcat_godot.log" 2>&1 || true
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

# --- 启动时间线 ---------------------------------------------------------------
# 两个来源，因为没有任何一个能单独回答"玩家什么时候能点"：
#
#   Displayed   系统 server 记的，Android 把窗口放上屏幕的时刻。它是唯一能锚到真正
#               进程启动的数字，但窗口出现 ≠ 游戏能操作 —— 本项目实测这一步约 250 ms，
#               而语言页要再等几秒。
#   GLORY_STARTUP  进程内 StartupTrace 打的单行 JSON。它知道"第一个按钮可以按了"，
#               但时钟从引擎初始化起算，看不见引擎之前的那段（见该文件顶部）。
#
# 所以两个都记、都不换算成对方，报告里各自标明基准。
DISPLAYED_LINE="$(grep -a -m1 "Displayed $PACKAGE/" "$RUN_DIR/logcat_full.log" 2>/dev/null | tr -d '\r' || true)"
DISPLAYED_MS=-1
DISPLAYED_TOKEN="$(printf '%s' "$DISPLAYED_LINE" | grep -oE '\+([0-9]+s)?[0-9]+ms' | head -1 || true)"
if [ -n "$DISPLAYED_TOKEN" ]; then
    d_sec="$(printf '%s' "$DISPLAYED_TOKEN" | grep -oE '[0-9]+s' | tr -d 's' || true)"
    d_ms="$(printf '%s' "$DISPLAYED_TOKEN" | sed 's/.*[s+]\([0-9]*\)ms/\1/')"
    [ -n "$d_sec" ] || d_sec=0
    [ -n "$d_ms" ] || d_ms=0
    DISPLAYED_MS=$(( d_sec * 1000 + d_ms ))
fi

grep -haoE 'GLORY_(STARTUP|BUILD|ISSUE) \{.*\}' \
    "$RUN_DIR/logcat_full.log" "$RUN_DIR/logcat_godot.log" 2>/dev/null \
    | awk '!seen[$0]++' > "$RUN_DIR/startup_trace.jsonl" || true
STARTUP_MARK_COUNT="$(grep -ac . "$RUN_DIR/startup_trace.jsonl" 2>/dev/null || echo 0)"

# 用 python 解 JSON 而不是 sed：载荷是结构化的，字段顺序不保证，正则迟早看走眼。
# stdout 走 buffer.write 是因为 Windows 上文本管道会补 CR，混进 shell 变量里。
STARTUP_KV="$(STARTUP_JSONL="$RUN_DIR/startup_trace.jsonl" python -c '
import json, io, os, sys
marks = {}
try:
    with io.open(os.environ["STARTUP_JSONL"], encoding="utf-8", newline="") as handle:
        for raw in handle:
            line = raw.strip()
            prefix = "GLORY_STARTUP "
            if not line.startswith(prefix):
                continue
            try:
                payload = json.loads(line[len(prefix):])
            except ValueError:
                continue
            name = payload.get("mark", "")
            # First occurrence wins, matching StartupTrace: a duplicate line is a
            # re-mark, not a correction.
            if name and name not in marks:
                marks[name] = int(payload.get("ms", -1))
except (IOError, OSError):
    pass
wanted = ("t0_trace_ready", "t1_first_frame", "t2_godot_main_ready",
          "t3_first_input_ready", "t4_first_action_complete")
out = ["%s=%d" % (key, marks.get(key, -1)) for key in wanted]
sys.stdout.buffer.write(("\n".join(out)).encode("utf-8"))
' 2>/dev/null || true)"

T0_MS=-1; T1_MS=-1; T2_MS=-1; T3_MS=-1; T4_MS=-1
if [ -n "$STARTUP_KV" ]; then
    while IFS='=' read -r mark_key mark_value; do
        case "$mark_key" in
            t0_trace_ready) T0_MS="$mark_value" ;;
            t1_first_frame) T1_MS="$mark_value" ;;
            t2_godot_main_ready) T2_MS="$mark_value" ;;
            t3_first_input_ready) T3_MS="$mark_value" ;;
            t4_first_action_complete) T4_MS="$mark_value" ;;
        esac
    done <<EOF
$STARTUP_KV
EOF
fi

MISSING_MARKS=""
[ "$T1_MS" -ge 0 ] || MISSING_MARKS="$MISSING_MARKS t1_first_frame"
[ "$T2_MS" -ge 0 ] || MISSING_MARKS="$MISSING_MARKS t2_godot_main_ready"
[ "$T3_MS" -ge 0 ] || MISSING_MARKS="$MISSING_MARKS t3_first_input_ready"
MISSING_MARKS="$(printf '%s' "$MISSING_MARKS" | sed 's/^ *//')"

# t4 只在玩家做出第一个动作后才有，而本脚本不点屏幕，所以它缺席是正常的，不列入缺失。
if [ -n "$MISSING_MARKS" ]; then
    note "!! 启动标记缺失：$MISSING_MARKS（logcat 里只有 $STARTUP_MARK_COUNT 条 GLORY_STARTUP）"
    note "!! 缺标记通常意味着装的包比 StartupTrace 早，或进程在到达该阶段前就死了"
fi

STARTUP_VERDICT="reported_only"
if [ "$ASSERT_STARTUP" -eq 1 ]; then
    STARTUP_VERDICT="asserted"
    [ -n "$MISSING_MARKS" ] && fail "startup_marks_missing: $MISSING_MARKS"
    if [ "$T3_MS" -ge 0 ] && [ "$T3_MS" -gt "$T3_MAX_MS" ]; then
        fail "startup_t3_over_budget: 首个可交互界面 ${T3_MS}ms > ${T3_MAX_MS}ms（引擎初始化起算）"
    fi
    if [ "$T1_MS" -ge 0 ] && [ "$T1_MS" -gt "$T1_MAX_MS" ]; then
        fail "startup_t1_over_budget: 首帧 ${T1_MS}ms > ${T1_MAX_MS}ms（引擎初始化起算）"
    fi
fi

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
    "installed_apk_sha256": "$INSTALLED_APK_SHA",
    "expected_apk_sha256": "$APK_SHA",
    "identity_verified": $INSTALL_IDENTITY_VERIFIED,
    "version_name": "$INSTALLED_VERSION",
    "version_code": $INSTALLED_VERSION_CODE,
    "expected_version_code": $EXPECTED_VERSION_CODE,
    "other_glory_packages_on_device": "$RIVAL_PACKAGES"
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
  "identity": {
    "build_info_written": "build_info.json",
    "build_info_in_apk": "$APK_BUILD_MATCH",
    "build_info_apk_commit": "$APK_BUILD_COMMIT",
    "preset_template_sha256": "$TEMPLATE_SHA",
    "preset_version_code": $PRESET_VERSION_CODE,
    "preset_version_name": "$PRESET_VERSION_NAME",
    "apk_content_scan": "$APK_SCAN_STATUS",
    "note": "build_info_in_apk=match 才表示所测即所构建；skipped_reused_apk / absent 只在 --skip-export 下可接受。"
  },
  "startup": {
    "verdict": "$STARTUP_VERDICT",
    "budgets_ms": {"t1_first_frame": $T1_MAX_MS, "t3_first_input_ready": $T3_MAX_MS},
    "activity_displayed_ms": $DISPLAYED_MS,
    "activity_displayed_base": "android_process_start",
    "marks_base": "godot_engine_init",
    "marks_ms": {
      "t0_trace_ready": $T0_MS,
      "t1_first_frame": $T1_MS,
      "t2_godot_main_ready": $T2_MS,
      "t3_first_input_ready": $T3_MS,
      "t4_first_action_complete": $T4_MS
    },
    "mark_lines_in_logcat": $STARTUP_MARK_COUNT,
    "missing_marks": "$MISSING_MARKS",
    "trace_file": "startup_trace.jsonl",
    "note": "activity_displayed_ms 从 Android 进程启动起算；marks_ms 从 Godot 引擎初始化起算。两者基准不同，不可相减。t4 需要玩家动作，本脚本不点屏幕，缺席属正常。"
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
note "startup   displayed=${DISPLAYED_MS}ms (自进程启动)  t0=${T0_MS}ms t1=${T1_MS}ms t2=${T2_MS}ms t3=${T3_MS}ms t4=${T4_MS}ms (自引擎初始化，-1=没抓到)"
note "          t0 = 引擎自身启动开销（此前无任何游戏代码运行）；t0->t2 = autoload 构造 + 主场景"
note "          判定=$STARTUP_VERDICT  预算 t1<=${T1_MAX_MS}ms t3<=${T3_MAX_MS}ms"
note "identity  build_info_in_apk=$APK_BUILD_MATCH  apk_scan=$APK_SCAN_STATUS  template_sha=${TEMPLATE_SHA:0:16}"
note "evidence  $RUN_DIR"

# 旧构建清理，只留最近 N 份。
ls -t "$OUT_DIR"/*.apk 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do rm -f "$old"; done

if [ ${#FAILURES[@]} -eq 0 ]; then
    note "PASS"
    exit 0
fi
note "FAIL: ${FAILURES[*]}"
exit 1
