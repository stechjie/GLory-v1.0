#!/usr/bin/env bash
# Build only; never changes a running service. Requires Linux x86_64, C++ toolchain, Python venv.
set -euo pipefail
base=5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88
archive_sha=b3d705612228c09083d55a89ed3ea7381e6181387ecfdb74fd5cf9733b28eee6
# Current production is Ubuntu 22.04 / glibc 2.35. Building on newer glibc
# can silently require __isoc23 symbols unavailable in production.
test "$(uname -m)" = x86_64
. /etc/os-release
test "$ID:$VERSION_ID" = ubuntu:22.04
here=$(cd -- "$(dirname -- "$0")" && pwd)
work=${1:?Usage: build_linux.sh EMPTY_BUILD_DIRECTORY}
mkdir -p "$work"
work=$(cd "$work" && pwd)
test ! -e "$work/godot-$base"
curl -fL "https://codeload.github.com/godotengine/godot/tar.gz/$base" -o "$work/source.tar.gz"
printf '%s  %s\n' "$archive_sha" "$work/source.tar.gz" | sha256sum -c -
tar -xzf "$work/source.tar.gz" -C "$work"
cd "$work/godot-$base"
patch --fuzz=0 -p1 < "$here/godot-4.7-dtls-admission.patch"
c++ -std=c++17 -Wall -Wextra -Werror -I. "$here/tests/admission_test.cpp" -o "$work/admission_test"
"$work/admission_test"
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install 'scons==4.8.1'
BUILD_NAME=glory_dtls1 "$work/venv/bin/scons" platform=linuxbsd target=template_release arch=x86_64 -j"${BUILD_JOBS:-4}" debug_symbols=no optimize=speed lto=none x11=no wayland=no vulkan=no opengl3=no alsa=no pulseaudio=no dbus=no speechd=no udev=no fontconfig=no accesskit=no
sha256sum bin/godot.* > "$work/binary.sha256"
