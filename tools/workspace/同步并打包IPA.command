#!/bin/bash
GLORY_TOOLS="$(cd "$(dirname "$0")" && pwd -P)"
cd "$GLORY_TOOLS/../../.." || exit 1
"$GLORY_TOOLS/build_ipa.sh" --update "$@"
glory_result=$?
if [[ ! -t 0 ]]; then exit "$glory_result"; fi
for glory_arg in "$@"; do
  case "$glory_arg" in --check|--help|-h|--dry-run) exit "$glory_result" ;; esac
done
echo
if [[ "$glory_result" -eq 0 ]]; then
  open "$(pwd)/build/ipa"
  echo 'Ad Hoc IPA 已生成。按回车关闭窗口。'
else
  echo 'IPA 打包未完成，请查看上方错误。按回车关闭窗口。'
fi
read -r _
exit "$glory_result"
