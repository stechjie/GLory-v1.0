#!/bin/bash
GLORY_TOOLS="$(cd "$(dirname "$0")" && pwd -P)"
cd "$GLORY_TOOLS/../../.." || exit 1
"$GLORY_TOOLS/build_apk.sh" --sync "$@"
result=$?
if [[ ! -t 0 ]]; then exit "$result"; fi
for glory_arg in "$@"; do
  case "$glory_arg" in --check|--help|-h|--dry-run) exit "$result" ;; esac
done
echo
if [[ "$result" -eq 0 ]]; then
  open "$(pwd)/build/apk"
  echo 'APK 已生成。按回车关闭窗口。'
else
  echo '打包未完成，请查看上方错误。按回车关闭窗口。'
fi
read -r _
exit "$result"
