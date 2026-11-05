#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build/feature-tests
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  Sources/RecorderBackend/BackendTypes.swift Sources/RecorderBackend/ConfigStore.swift \
  Sources/RecorderBackend/ModelDownloader.swift Sources/RecorderBackend/PinnedModelArtifact.swift \
  Sources/Recorder/AIClient.swift Sources/Recorder/LiveTranslate.swift \
  Sources/Recorder/HyModelStore.swift Sources/Recorder/LocalSpeechOutput.swift tests/LocalSpeechTests.swift \
  -o .build/feature-tests/local-speech-tests
.build/feature-tests/local-speech-tests
