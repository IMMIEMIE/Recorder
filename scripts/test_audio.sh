#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/feature-tests
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" Sources/Recorder/AIClient.swift Sources/Recorder/AdditionalAudioInput.swift tests/AudioInputTests.swift -o .build/feature-tests/audio-tests
.build/feature-tests/audio-tests
