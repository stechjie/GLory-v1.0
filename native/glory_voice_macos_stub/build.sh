#!/bin/bash
set -euo pipefail

# Usage: bash build.sh /absolute/path/to/Godot.app/Contents/MacOS/Godot
# Generate the ABI header from the installed engine; no downloaded SDK needed.
voice_stub_root="$(cd -- "$(dirname -- "$0")" && pwd)"
voice_stub_engine="${1:?Pass the absolute Godot executable path}"
voice_stub_tmp="$(mktemp -d)"
trap 'rm -rf "$voice_stub_tmp"' EXIT
(
  cd "$voice_stub_tmp"
  "$voice_stub_engine" --headless --dump-gdextension-interface
)
xcrun clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -Wall -Wextra -Werror -fvisibility=hidden -I "$voice_stub_tmp" \
  "$voice_stub_root/glory_voice_macos_stub.c" \
  -o "$voice_stub_tmp/libglory_voice_unavailable.macos.dylib"
codesign --force --sign - "$voice_stub_tmp/libglory_voice_unavailable.macos.dylib"
voice_stub_output="$voice_stub_root/../../addons/glory_voice/bin/macos"
mkdir -p "$voice_stub_output"
cp "$voice_stub_tmp/libglory_voice_unavailable.macos.dylib" "$voice_stub_output/"
