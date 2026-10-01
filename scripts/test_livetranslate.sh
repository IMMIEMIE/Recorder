#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
port_file=$(mktemp /tmp/recorder-live-port.XXXXXX)
python3 tests/mock_livetranslate_server.py "$port_file" &
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
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build/feature-tests
# AppModel is compiled with the real backend sources but a model-free LocalBackend (no MLX modules).
bin=$(swift build --show-bin-path)
swift build --target Cwebrtcvad >/dev/null
objects=$(find "$bin/Cwebrtcvad.build" -name '*.o')
sources=()
for source in Sources/Recorder/*.swift; do
  if [[ "$source" != *RecorderApp.swift && "$source" != *LocalBackend.swift ]]; then sources+=("$source"); fi
done
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" "${sources[@]}" Sources/RecorderBackend/*.swift \
  tests/LocalBackendStub.swift tests/LiveTranslateTests.swift $objects \
  -Xcc -fmodule-map-file="$bin/Cwebrtcvad.build/module.modulemap" -I Sources/Cwebrtcvad/include \
  -o .build/feature-tests/live-tests
.build/feature-tests/live-tests
