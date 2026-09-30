#!/bin/bash
# Real-model verification of the in-process (mlx-swift) backend: RecorderVerify with the cached
# models under models/ (Hugging Face cache layout) and the compiled Metal kernels.
#   ./scripts/verify_inprocess.sh                       # asr + translate + pipeline, default cached snapshots
#   ./scripts/verify_inprocess.sh asr [--language Chinese]
#   ./scripts/verify_inprocess.sh whisper [--language Chinese]   # needs a cached whisper-large-v3-turbo
#   ./scripts/verify_inprocess.sh translate [--target English]
#   ./scripts/verify_inprocess.sh pipeline [--asr <owner/model>] [--translator none] [--endpoint fixed]
# pipeline plays the fixtures in real time through BackendCore (endpointing, local translation, and a
# Qwen -> Whisper -> Qwen switch when Whisper is cached).
# Reports go to docs/model-verification-swift.json, docs/whisper-verification-swift.json,
# docs/translation-verification-swift.json and docs/pipeline-verification-swift.json.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --product RecorderVerify
bin="$(swift build -c release --show-bin-path)/RecorderVerify"
metallib=$(scripts/build_metallib.sh)

snapshot() {
  local found
  found=$(ls -dt models/models--"${1//\//--}"/snapshots/*/ 2>/dev/null | head -1)
  [ -n "$found" ] || { echo "未找到已缓存的模型 $1（models/ 下）" >&2; exit 1; }
  echo "${found%/}"
}

mode=${1:-all}
[ $# -gt 0 ] && shift
# Resolve snapshots into variables first: a failing command substitution inside an argument
# list doesn't trip set -e, and RecorderVerify would run with an empty model path.
if [ "$mode" = "asr" ] || [ "$mode" = "all" ]; then
  model="$(snapshot mlx-community/Qwen3-ASR-1.7B-bf16)"
  "$bin" asr --metallib "$metallib" --model "$model" "$@" \
    tests/fixtures/chinese.aiff tests/fixtures/english.aiff tests/fixtures/mixed.aiff
fi
if [ "$mode" = "whisper" ]; then
  model="$(snapshot mlx-community/whisper-large-v3-turbo)"
  "$bin" asr --metallib "$metallib" --assets assets/whisper --output docs/whisper-verification-swift.json \
    --model "$model" "$@" \
    tests/fixtures/chinese.aiff tests/fixtures/english.aiff tests/fixtures/mixed.aiff
fi
if [ "$mode" = "translate" ] || [ "$mode" = "all" ]; then
  model="$(snapshot mlx-community/Qwen3-4B-Instruct-2507-4bit)"
  "$bin" translate --metallib "$metallib" --model "$model" "$@" \
    "Good morning. Please remember the number one, two, three, four, five." \
    "This is a local speech recognition test."
fi
if [ "$mode" = "pipeline" ] || [ "$mode" = "all" ]; then
  switch=()
  if ls -d models/models--mlx-community--whisper-large-v3-turbo/snapshots/*/ >/dev/null 2>&1; then
    switch=(--switch mlx-community/whisper-large-v3-turbo)
  fi
  "$bin" pipeline --metallib "$metallib" --models models --assets assets/whisper ${switch[@]+"${switch[@]}"} "$@"
fi
