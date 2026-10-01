#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
# The app target must be built with the default CommandLineTools chain: SwiftPM under the Xcode
# toolchain stamps the package's declared deployment target into LC_BUILD_VERSION's sdk field
# (14.0 here), while the CLT chain stamps the real SDK — macOS gates the Liquid Glass look
# (traffic lights included) on a linked SDK >= 26. build_metallib.sh picks Xcode on its own.
env -u DEVELOPER_DIR swift build -c release --disable-sandbox --product Recorder
metallib=$(scripts/build_metallib.sh)
app="$PWD/dist/声笺.app"
# Start from an empty bundle: earlier builds carried the Python runtime and backend/.
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
<key>NSMicrophoneUsageDescription</key><string>声笺仅在你主动开始转写时使用麦克风；本地识别不上传音频，选择 API 识别或 LiveTranslate 时会发送音频到所选服务。应用不保存录音。</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
printf 'Built: %s\n' "$app"
