#!/usr/bin/env bash
# Update the tracked branch and canonical Drive assets, preserving local work.
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${PYTHON3:-python3}" -B "$GLORY_TOOLS/glory_update.py" "$@"
