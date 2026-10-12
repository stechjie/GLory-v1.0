#!/usr/bin/env bash
# 默认构建签名精简 Release APK；--sync 才更新 Git/Drive，--debug 仅用于诊断。
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GLORY_ROOT="$(cd "$GLORY_TOOLS/../../.." && pwd -P)"
exec "${PYTHON3:-python3}" "$GLORY_TOOLS/glory_build.py" "$@"
