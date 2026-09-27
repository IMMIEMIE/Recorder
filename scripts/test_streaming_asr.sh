#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
port_file=$(mktemp /tmp/recorder-streaming-port.XXXXXX)
.venv/bin/python tests/mock_streaming_asr_server.py "$port_file" &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true; rm -f "$port_file"' EXIT
for attempt in {1..50}; do
  if ! kill -0 "$mock_pid" 2>/dev/null; then exit 1; fi
  if [ -s "$port_file" ]; then break; fi
  sleep 0.1
done
[ -s "$port_file" ] || exit 1
export RECORDER_STREAMING_MOCK="ws://127.0.0.1:$(cat "$port_file")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
mkdir -p .build/feature-tests
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" Sources/Recorder/AIClient.swift Sources/Recorder/StreamingASR.swift tests/StreamingASRTests.swift -o .build/feature-tests/streaming-tests
.build/feature-tests/streaming-tests
