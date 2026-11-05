#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/feature-tests .build/module-cache
swiftc -module-cache-path "$PWD/.build/module-cache" \
  Sources/Recorder/HyRuntimeAvailability.swift tests/HyRuntimeAvailabilityTests.swift \
  -o .build/feature-tests/hy-gate-tests
.build/feature-tests/hy-gate-tests
