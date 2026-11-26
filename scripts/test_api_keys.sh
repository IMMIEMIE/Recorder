#!/bin/bash
# APIKeyStore file storage and legacy Keychain migration (issue #50); temporary directories and a fake Keychain only.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build/feature-tests
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" Sources/Recorder/AIClient.swift tests/APIKeyStoreTests.swift \
  -o .build/feature-tests/api-key-tests
.build/feature-tests/api-key-tests
