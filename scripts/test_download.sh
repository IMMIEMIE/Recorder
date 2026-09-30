#!/bin/bash
# ModelDownloader tests against tests/mock_hub_server.py (no network). When .venv has huggingface_hub,
# backend/download.py downloads the same mock repo first and the two cache folders must be identical.
#   ./scripts/test_download.sh                          mock hub tests
#   ./scripts/test_download.sh hub <model_id> [--full]  compare with the real cache in models/ (network)
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build/download-tests
bin=$(swift build --show-bin-path)
swift build --target Cwebrtcvad >/dev/null
objects=$(find "$bin/Cwebrtcvad.build" -name '*.o')
swiftc \
  Sources/Recorder/Backend/*.swift \
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

python=.venv/bin/python
[ -x "$python" ] || python=python3
work=$(mktemp -d /tmp/recorder-hub.XXXXXX)
"$python" tests/mock_hub_server.py "$work/port" &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true; rm -rf "$work"' EXIT
for attempt in {1..50}; do
  if ! kill -0 "$mock_pid" 2>/dev/null; then exit 1; fi
  if [ -s "$work/port" ]; then break; fi
  sleep 0.1
done
[ -s "$work/port" ] || exit 1
export RECORDER_MOCK_URL="http://127.0.0.1:$(cat "$work/port")"

if [ -x .venv/bin/python ] && .venv/bin/python -c 'import huggingface_hub' 2>/dev/null; then
  HF_ENDPOINT="$RECORDER_MOCK_URL" HF_HOME="$work/hf-home" HF_HUB_DISABLE_TELEMETRY=1 \
    .venv/bin/python backend/download.py mock/tiny "" "$work/python-cache" >"$work/python.log"
  grep -q '"type": "downloaded"' "$work/python.log" || { cat "$work/python.log"; exit 1; }
  export RECORDER_PYTHON_CACHE="$work/python-cache"
fi
.build/download-tests/download-tests
