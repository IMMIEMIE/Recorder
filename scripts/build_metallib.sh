#!/bin/bash
# Compiles mlx-swift's Metal kernels into mlx.metallib (SwiftPM builds of mlx-swift carry none) and
# prints its path. mlx-swift builds MLX in JIT mode: only the kernels in
# Source/Cmlx/mlx-generated/metal are precompiled (the list mlx-swift's tools/fix-metal-includes.sh and
# its Xcode project use); every other kernel, including the macOS 26.2 NAX ones, is compiled at run
# time. Targeting macOS 14 therefore works on every supported system.
# Needs Xcode's Metal compiler (Xcode 26+: xcodebuild -downloadComponent MetalToolchain).
#   scripts/build_metallib.sh [output]     default .build/metallib/mlx.metallib, rebuilt when the sources change
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-.build/metallib/mlx.metallib}
src=.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal
[ -d "$src" ] || swift package resolve >&2
[ -d "$src" ] || { echo "未找到 $src，请确认 mlx-swift 依赖已解析" >&2; exit 1; }
# Xcode's Metal compiler (CommandLineTools has none): fall back to a full Xcode when the
# active developer directory lacks it, so callers need not export DEVELOPER_DIR themselves.
if ! xcrun --find metal >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! echo '' | xcrun -sdk macosx metal -x metal -E - >/dev/null 2>&1; then
  echo "缺少 Metal 编译器：请安装完整 Xcode（xcode-select 指向 Xcode），并执行 xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi
stamp=$(find "$src" -type f \( -name '*.metal' -o -name '*.h' \) -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
if [ -f "$out" ] && [ "$(cat "$out.stamp" 2>/dev/null)" = "$stamp" ]; then
  echo "$out"
  exit 0
fi
work=$(mktemp -d /tmp/recorder-metallib.XXXXXX)
trap 'rm -rf "$work"' EXIT
air=()
while IFS= read -r -d '' kernel; do
  name=${kernel#"$src"/}
  name=${name%.metal}
  name=${name//\//_}
  # Flags of mlx's kernels/CMakeLists.txt build_kernel_base.
  xcrun -sdk macosx metal -x metal -Wall -Wextra -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions \
    -mmacosx-version-min=14.0 -c "$kernel" -I "$src" -o "$work/$name.air" >&2
  air+=("$work/$name.air")
done < <(find "$src" -name '*.metal' -print0 | sort -z)
[ ${#air[@]} -gt 0 ] || { echo "$src 中没有 .metal 内核" >&2; exit 1; }
mkdir -p "$(dirname "$out")"
xcrun -sdk macosx metal -mmacosx-version-min=14.0 "${air[@]}" -o "$out" >&2
echo "$stamp" > "$out.stamp"
echo "$out"
