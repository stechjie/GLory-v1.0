#!/usr/bin/env bash
# --sync 先更新 Git 和 Drive，再将 GLory-v1.0 + res 合并到隔离目录构建 APK。
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GLORY_ROOT="$(cd "$GLORY_TOOLS/../../.." && pwd -P)"
exec "${PYTHON3:-python3}" "$GLORY_ROOT/tools/glory_build.py" "$@"
