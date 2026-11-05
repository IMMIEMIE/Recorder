#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REV=d38e66aac7bb18101f417338b795e4546a5a1a59
ARCHIVE_SHA=b98417108e06f5d70dbc5e9f3dc72cb145efecfaef5c7e602c1edff328bb3e24
SOURCE="$ROOT/.build/hy-runtime-src"
ARCHIVE="$ROOT/.build/hy-downloads/llama-hyv3-d38e66a.tar.gz"
CMAKE="$ROOT/.build/hy-tools/bin/cmake"
if [[ ! -f "$ARCHIVE" ]]; then
  mkdir -p "$(dirname "$ARCHIVE")"
  curl -fL --retry 3 "https://codeload.github.com/lihy715/llama.cpp.Hyv3Speech/tar.gz/$REV" -o "$ARCHIVE" >&2
fi
ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
[[ "$ACTUAL" == "$ARCHIVE_SHA" ]] || { echo 'Hy runtime source checksum mismatch' >&2; exit 1; }
if [[ ! -f "$SOURCE/.recorder-source-revision" ]]; then
  mkdir -p "$SOURCE"
  tar -xzf "$ARCHIVE" -C "$SOURCE" --strip-components=1
  echo "$REV" > "$SOURCE/.recorder-source-revision"
fi
[[ "$(cat "$SOURCE/.recorder-source-revision")" == "$REV" ]] || { echo 'Unexpected Hy runtime source revision' >&2; exit 1; }
if [[ ! -x "$CMAKE" ]]; then
  python3 -m venv "$ROOT/.build/hy-tools"
  "$ROOT/.build/hy-tools/bin/python" -m pip install 'cmake==4.2.3' >&2
fi
mkdir -p "$ROOT/.build/hy-runtime"
python3 - "$SOURCE/tools/mtmd/mtmd-cli.cpp" "$ROOT/.build/hy-runtime/reference-cli.cpp" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
needle = '            const llama_token tok = common_sampler_sample(ctx.smpl, ctx.lctx, -1);'
assert source.count(needle) == 1, 'Pinned reference CLI changed'
source = source.replace(needle, needle + '\n            std::fprintf(stderr, "HY_REFERENCE_TOKEN %d %d\\n", turn, tok);')
output = pathlib.Path(sys.argv[2])
if not output.exists() or output.read_text() != source:
    output.write_text(source)
PY
# ggml reads the enclosing repository's commit with git even when one is given; that is this
# repository, so every commit would change the helper. native/HySimulMT/CMakeLists.txt pins it.
python3 - "$SOURCE/ggml/CMakeLists.txt" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
pinned = 'if(GIT_EXE AND NOT HY_PINNED_BUILD_INFO)'
if pinned not in source:
    needle = 'find_program(GIT_EXE NAMES git git.exe NO_CMAKE_FIND_ROOT_PATH)\nif(GIT_EXE)'
    assert source.count(needle) == 1, 'Pinned ggml build info changed'
    path.write_text(source.replace(needle, needle[:-len('if(GIT_EXE)')] + pinned))
PY
"$CMAKE" -S "$ROOT/native/HySimulMT" -B "$ROOT/.build/hy-runtime" \
  -DHY_LLAMA_SOURCE="$SOURCE" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >&2
"$CMAKE" --build "$ROOT/.build/hy-runtime" --target HySimulMTHelper HySimulMTReferenceCLI -j "${HY_BUILD_JOBS:-8}" >&2
"$ROOT/.build/hy-runtime/bin/HySimulMTHelper" --self-test >&2
echo "$ROOT/.build/hy-runtime/bin/HySimulMTHelper"
