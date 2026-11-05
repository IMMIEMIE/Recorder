#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build/feature-tests
bin=$(swift build --build-system native --show-bin-path)
swift build --build-system native --target Cwebrtcvad --disable-sandbox >/dev/null
objects=$(find "$bin/Cwebrtcvad.build" -name '*.o')
sources=()
for source in Sources/Recorder/*.swift; do
  if [[ "$source" != *RecorderApp.swift && "$source" != *LocalBackend.swift ]]; then sources+=("$source"); fi
done
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" "${sources[@]}" Sources/RecorderBackend/*.swift \
  tests/LocalBackendStub.swift tests/HyLiveTranslateTests.swift $objects \
  -Xcc -fmodule-map-file="$bin/Cwebrtcvad.build/module.modulemap" -I Sources/Cwebrtcvad/include \
  -o .build/feature-tests/hy-live-tests
.build/feature-tests/hy-live-tests
