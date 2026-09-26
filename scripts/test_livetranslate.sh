#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
port_file=$(mktemp /tmp/recorder-live-port.XXXXXX)
.venv/bin/python tests/mock_livetranslate_server.py "$port_file" &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true; rm -f "$port_file"' EXIT
for attempt in {1..50}; do
  if ! kill -0 "$mock_pid" 2>/dev/null; then exit 1; fi
  if [ -s "$port_file" ]; then break; fi
  sleep 0.1
done
[ -s "$port_file" ] || exit 1
export RECORDER_LIVE_MOCK="ws://127.0.0.1:$(cat "$port_file")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
mkdir -p .build/feature-tests
sources=()
for source in Sources/Recorder/*.swift; do
  if [[ "$source" != *RecorderApp.swift ]]; then sources+=("$source"); fi
done
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" "${sources[@]}" tests/LiveTranslateTests.swift -o .build/feature-tests/live-tests
.build/feature-tests/live-tests
