#!/bin/bash
GLORY_TOOLS="$(cd "$(dirname "$0")" && pwd -P)"
cd "$GLORY_TOOLS/../../.." || exit 1
./tools/sync_res.sh
result=$?
echo
if [[ "$result" -eq 0 ]]; then
  echo '资源同步完成。按回车关闭窗口。'
else
  echo '同步未完成，请查看上方错误；重新双击可继续。按回车关闭窗口。'
fi
read -r _
exit "$result"
