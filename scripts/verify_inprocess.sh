#!/bin/bash
# Real-model verification of the in-process (mlx-swift) model layer: Swift counterpart of
# scripts/verify_model.py (ASR fixtures) and scripts/verify_translation.py (local translation).
# Needs Apple Silicon, the cached default models under models/, and .venv (for mlx.metallib).
#   ./scripts/verify_inprocess.sh                       # both, default cached snapshots
#   ./scripts/verify_inprocess.sh asr [--language Chinese]
#   ./scripts/verify_inprocess.sh whisper [--language Chinese]   # needs a cached whisper-large-v3-turbo
#   ./scripts/verify_inprocess.sh translate [--target English]
# Reports go to docs/model-verification-swift.json, docs/whisper-verification-swift.json and
# docs/translation-verification-swift.json.
set -euo pipefail
cd "$(dirname "$0")/.."
export RECORDER_INPROCESS=1
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
metallib=.venv/lib/python3.12/site-packages/mlx/lib/mlx.metallib
[ -f "$metallib" ] || { echo "缺少 $metallib，请先运行 scripts/setup.sh" >&2; exit 1; }
swift build -c release --disable-sandbox --product RecorderVerify
bin="$(swift build -c release --show-bin-path)/RecorderVerify"

snapshot() {
  local found
  found=$(ls -dt models/models--"${1//\//--}"/snapshots/*/ 2>/dev/null | head -1)
  [ -n "$found" ] || { echo "未找到已缓存的模型 $1（models/ 下）" >&2; exit 1; }
  echo "${found%/}"
}

mode=${1:-all}
[ $# -gt 0 ] && shift
if [ "$mode" = "asr" ] || [ "$mode" = "all" ]; then
  "$bin" asr --metallib "$metallib" --model "$(snapshot mlx-community/Qwen3-ASR-1.7B-bf16)" "$@" \
    tests/fixtures/chinese.aiff tests/fixtures/english.aiff tests/fixtures/mixed.aiff
fi
if [ "$mode" = "whisper" ]; then
  "$bin" asr --metallib "$metallib" --assets assets/whisper --output docs/whisper-verification-swift.json \
    --model "$(snapshot mlx-community/whisper-large-v3-turbo)" "$@" \
    tests/fixtures/chinese.aiff tests/fixtures/english.aiff tests/fixtures/mixed.aiff
fi
if [ "$mode" = "translate" ] || [ "$mode" = "all" ]; then
  "$bin" translate --metallib "$metallib" --model "$(snapshot mlx-community/Qwen3-4B-Instruct-2507-4bit)" "$@" \
    "Good morning. Please remember the number one, two, three, four, five." \
    "This is a local speech recognition test."
fi
