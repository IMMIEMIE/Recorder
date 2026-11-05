#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
if python3 -c 'import json,pathlib; p=pathlib.Path("docs/hy-runtime-verification.json"); raise SystemExit(0 if p.exists() and json.loads(p.read_text()).get("passed") is True else 1)' 2>/dev/null; then
  ./scripts/build_hy_runtime.sh
fi
# Native SwiftPM preserves the .build/<configuration> layout used by packaging
# and tests. Use the selected toolchain consistently (this Mac's CLT SDK lacks
# the SwiftUI macro plugin required by macOS 27; full Xcode supplies it).
swift build --build-system native -c release --disable-sandbox --product Recorder
metallib=$(scripts/build_metallib.sh)
app="$PWD/dist/声笺.app"
# Start from an empty bundle, including any previously verified Hy helper.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp .build/release/Recorder "$app/Contents/MacOS/Recorder"
# Metal kernels for mlx-swift; LocalBackend points MLX at this file.
cp "$metallib" "$app/Contents/Resources/mlx.metallib"
# Whisper's mel filters and tiktoken vocabularies (mlx-whisper 0.4.3, MIT); weights stay in the user cache.
cp -R assets/whisper "$app/Contents/Resources/whisper"
rm -f "$app/Contents/Resources/whisper/README.md"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Recorder</string>
<key>CFBundleIdentifier</key><string>local.shengjian.recorder</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>声笺</string>
<key>CFBundleDisplayName</key><string>声笺</string>
<key>CFBundleVersion</key><string>5</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>声笺仅在你选择系统声音并开始转写时采集系统音频，不保存屏幕画面。</string>
<key>NSMicrophoneUsageDescription</key><string>声笺仅在你主动开始转写时使用麦克风；本地识别和本地 Hy-SimulMT 不上传音频，选择 API 识别或云端 LiveTranslate 时会发送音频到所选服务。应用不保存录音。</string>
</dict></plist>
PLIST
python3 scripts/bundle_hy_runtime.py --app "$app"
# The helper was signed before its hash was recorded; sign the outer bundle only.
codesign --force --sign - "$app"
printf 'Built: %s\n' "$app"
