#!/bin/bash
# Swift backend tests (BackendCore/Segmenter/VAD/planner/cache), mirroring tests/test_core.py etc.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build/backend-tests
bin=$(swift build --show-bin-path)
swift build --target Cwebrtcvad >/dev/null
objects=$(find "$bin/Cwebrtcvad.build" -name '*.o')
swiftc \
  Sources/Recorder/Backend/*.swift \
  tests/BackendTests.swift \
  $objects \
  -Xcc -fmodule-map-file="$bin/Cwebrtcvad.build/module.modulemap" \
  -I Sources/Cwebrtcvad/include \
  -module-cache-path "$PWD/.build/module-cache" \
  -o .build/backend-tests/backend-tests
.build/backend-tests/backend-tests
