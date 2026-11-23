#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/feature-tests
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
    Sources/Recorder/DialogueTurns.swift Sources/Recorder/LiveHandoffAudio.swift tests/DialogueTests.swift -o .build/feature-tests/dialogue-tests
.build/feature-tests/dialogue-tests
