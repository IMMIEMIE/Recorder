#!/bin/bash
# WindowServer-backed, model-free macOS probe. Use the same row count on both revisions.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
build="$PWD/.build/transcript-scroll"
mkdir -p "$build"
vad=Sources/Cwebrtcvad
cat > "$build/module.modulemap" <<EOF
module Cwebrtcvad { header "$PWD/$vad/include/webrtc_vad.h" export * }
EOF
objects=()
for source in "$vad"/webrtc/common_audio/{signal_processing,vad}/*.c; do
    object="$build/$(basename "${source%.c}").o"
    clang -mmacosx-version-min=14 -DWEBRTC_POSIX -DWEBRTC_MAC -I"$vad" -c "$source" -o "$object"
    objects+=("$object")
done
# The probe owns the entry point and hosts the real MainView in an inactive test window.
sed '/^@main$/d' Sources/Recorder/RecorderApp.swift > "$build/RecorderApp.swift"
sources=()
for source in Sources/Recorder/*.swift; do
    case "$source" in */RecorderApp.swift|*/LocalBackend.swift) continue ;; esac
    sources+=("$source")
done
swiftc -target "$(uname -m)-apple-macosx14.0" -parse-as-library -module-cache-path "$build/cache" \
    -Xcc -fmodule-map-file="$build/module.modulemap" "${sources[@]}" "$build/RecorderApp.swift" \
    Sources/RecorderBackend/*.swift tests/LocalBackendStub.swift tests/TranscriptScrollTests.swift \
    "${objects[@]}" -o "$build/probe"
"$build/probe" "$@"
