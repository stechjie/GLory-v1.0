#!/usr/bin/env bash
# Build, sign and validate a Google Play AAB in build/aab.
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${PYTHON3:-python3}" "$GLORY_TOOLS/glory_aab_build.py" "$@"
