#!/usr/bin/env bash
# 更新 GitHub / Drive → App Store IPA → Apple → 现有内部测试组。
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GLORY_ROOT="$(cd "$GLORY_TOOLS/../../.." && pwd -P)"
if [[ -f /Volumes/repository/glory-ios-dev/env.sh ]]; then
  source /Volumes/repository/glory-ios-dev/env.sh
fi
exec "${PYTHON3:-python3}" -B "$GLORY_ROOT/tools/glory_testflight.py" "$@"
