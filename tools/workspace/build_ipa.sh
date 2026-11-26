#!/usr/bin/env bash
# 本地代码 + res 生成精简 Release IPA；--update 才更新当前分支和云端资源。
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GLORY_ROOT="${GLORY_WORKSPACE:-$(cd "$GLORY_TOOLS/../../.." && pwd -P)}"
# Preserve an explicitly selected Xcode even when loading the legacy dev env.
GLORY_REQUESTED_DEVELOPER_DIR="${DEVELOPER_DIR:-}"
if [[ -f "$GLORY_ROOT/glory-ios-dev/env.sh" ]]; then
  source "$GLORY_ROOT/glory-ios-dev/env.sh"
fi
if [[ -n "$GLORY_REQUESTED_DEVELOPER_DIR" ]]; then
  export DEVELOPER_DIR="$GLORY_REQUESTED_DEVELOPER_DIR"
fi
exec "${PYTHON3:-python3}" -B "$GLORY_TOOLS/glory_ios_build.py" "$@"
