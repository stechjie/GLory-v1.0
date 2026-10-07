#!/usr/bin/env bash
# Standalone Android sync, build and internal Play release. Secrets stay external.
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GLORY_ROOT="$(cd "$GLORY_TOOLS/../../.." && pwd -P)"
export GLORY_PLAY_CREDENTIALS="${GLORY_PLAY_CREDENTIALS:-$HOME/Library/Application Support/Glory-Android/play-service-account.json}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
cd "$GLORY_ROOT"
exec "${PYTHON3:-$GLORY_ROOT/.glory-tools/venv/bin/python}" -B "$GLORY_TOOLS/glory_nightly.py" --android-only "$@"
