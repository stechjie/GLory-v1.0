#!/usr/bin/env bash
# Local resource patch only; defaults to current-android-production.json.
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${PYTHON3:-python3}" "$GLORY_TOOLS/glory_android_production_patch.py" "$@"
