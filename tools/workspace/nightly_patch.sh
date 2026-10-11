#!/usr/bin/env bash
# Daily Drive/Git sync → cumulative Android/iOS patch build → verified internal publication.
set -euo pipefail
GLORY_ROOT="/Volumes/repository/github/GLory"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
cd "$GLORY_ROOT"
exec "$GLORY_ROOT/.glory-tools/venv/bin/python" -B \
  "$GLORY_ROOT/GLory-v1.0/tools/workspace/glory_patch_nightly.py" --sync --publish "$@"
