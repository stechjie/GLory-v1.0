#!/bin/bash
GLORY_TOOLS="$(cd "$(dirname "$0")" && pwd -P)"
cd "$GLORY_TOOLS/../../.." || exit 1
"$GLORY_TOOLS/sync_res.sh" "$@"
result=$?
if [[ ! -t 0 ]]; then exit "$result"; fi
for glory_arg in "$@"; do
  case "$glory_arg" in --check|--help|-h|--dry-run) exit "$result" ;; esac
done
echo
if [[ "$result" -eq 0 ]]; then
  echo '资源同步完成。按回车关闭窗口。'
else
  echo '同步未完成，请查看上方错误；重新双击可继续。按回车关闭窗口。'
fi
read -r _
exit "$result"
