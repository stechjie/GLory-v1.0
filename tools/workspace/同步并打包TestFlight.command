#!/bin/bash
GLORY_TOOLS="$(cd "$(dirname "$0")" && pwd -P)"
cd "$GLORY_TOOLS/../../.." || exit 1
./tools/release_testflight.sh "$@"
glory_result=$?
echo
if [[ "$glory_result" -eq 0 ]]; then
  open "$(pwd)/build/ipa"
  echo 'TestFlight 流程已完成，请查看上方结果。按回车关闭窗口。'
else
  echo 'TestFlight 流程未完成，请查看上方错误和续传命令。按回车关闭窗口。'
fi
read -r _
exit "$glory_result"
