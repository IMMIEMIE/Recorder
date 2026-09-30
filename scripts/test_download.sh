#!/bin/bash
# ModelDownloader tests against tests/mock_hub_server.py (no network).
#   ./scripts/test_download.sh                          mock hub tests
#   ./scripts/test_download.sh hub <model_id> [--full]  compare with a real cache in models/ written by
#                                                       huggingface_hub (e.g. the Python builds; network)
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build/download-tests
bin=$(swift build --show-bin-path)
swift build --target Cwebrtcvad >/dev/null
objects=$(find "$bin/Cwebrtcvad.build" -name '*.o')
swiftc \
  Sources/RecorderBackend/*.swift \
  tests/DownloaderTests.swift \
  $objects \
  -Xcc -fmodule-map-file="$bin/Cwebrtcvad.build/module.modulemap" \
  -I Sources/Cwebrtcvad/include \
  -module-cache-path "$PWD/.build/module-cache" \
  -o .build/download-tests/download-tests

if [ "${1:-}" = "hub" ]; then
  [ $# -ge 2 ] || { echo "用法: $0 hub <model_id> [--full]" >&2; exit 2; }
  exec .build/download-tests/download-tests hub "$2" models "${@:3}"
fi

work=$(mktemp -d /tmp/recorder-hub.XXXXXX)
python3 tests/mock_hub_server.py "$work/port" &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true; rm -rf "$work"' EXIT
for attempt in {1..50}; do
  if ! kill -0 "$mock_pid" 2>/dev/null; then exit 1; fi
  if [ -s "$work/port" ]; then break; fi
  sleep 0.1
done
[ -s "$work/port" ] || exit 1
export RECORDER_MOCK_URL="http://127.0.0.1:$(cat "$work/port")"

.build/download-tests/download-tests
