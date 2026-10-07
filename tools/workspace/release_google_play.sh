#!/usr/bin/env bash
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GLORY_ROOT="$(cd "$GLORY_TOOLS/../../.." && pwd -P)"
exec "${PYTHON3:-$GLORY_ROOT/.glory-tools/venv/bin/python}" -B "$GLORY_TOOLS/glory_play.py" "$@"
