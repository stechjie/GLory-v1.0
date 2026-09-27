#!/bin/bash
set -euo pipefail
GLORY_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$GLORY_TOOLS/../../.." && pwd -P)"
PY="$ROOT/.glory-tools/venv/bin/python"
if [[ ! -x "$PY" ]]; then
  for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3,10))'; then
      "$candidate" -m venv "$ROOT/.glory-tools/venv"
      break
    fi
  done
fi
if [[ ! -x "$PY" ]]; then
  echo '需要 Python 3.10 或更新版本。macOS 可运行 brew install python，然后重试。' >&2
  exit 1
fi
if ! "$PY" -c 'import requests, bs4' >/dev/null 2>&1; then
  "$PY" -m pip install 'requests>=2.32,<3' 'beautifulsoup4>=4.12,<5'
fi
exec "$PY" "$ROOT/tools/glory_sync.py" "$@"
