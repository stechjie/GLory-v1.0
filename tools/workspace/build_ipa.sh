#!/usr/bin/env bash
# 本地代码 + res 生成精简 Release IPA；--update 才更新当前分支和云端资源。
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GLORY_ROOT="$(cd "$GLORY_TOOLS/../../.." && pwd -P)"
if [[ -f "$GLORY_ROOT/glory-ios-dev/env.sh" ]]; then
  source "$GLORY_ROOT/glory-ios-dev/env.sh"
fi
exec "${PYTHON3:-python3}" -B "$GLORY_TOOLS/glory_ios_build.py" "$@"
