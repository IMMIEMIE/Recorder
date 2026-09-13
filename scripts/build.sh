#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox
app="$PWD/dist/声笺.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp .build/release/Recorder "$app/Contents/MacOS/Recorder"
cp -R backend "$app/Contents/Resources/"
python_base=$(.venv/bin/python -c 'import sys; print(sys.base_prefix)')
if [ ! -d "$app/Contents/Resources/runtime" ]; then
  cp -R "$python_base" "$app/Contents/Resources/runtime"
fi
rsync -a .venv/lib/python3.12/site-packages/ "$app/Contents/Resources/runtime/lib/python3.12/site-packages/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Recorder</string>
<key>CFBundleIdentifier</key><string>local.shengjian.recorder</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>声笺</string>
<key>CFBundleDisplayName</key><string>声笺</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>声笺仅在你主动开始转写时使用麦克风，在本机识别语音，不保存或上传录音。</string>
</dict></plist>
PLIST
# Pin the locally verified revision; weights live in Application Support, never the bundle.
.venv/bin/python - "$app/Contents/Resources/initial-config.json" <<'PY'
import json, os, pathlib, sys
sys.path.insert(0, 'backend')
from core import Config
from dataclasses import asdict
root = pathlib.Path('models/models--mlx-community--Qwen3-ASR-1.7B-bf16/snapshots')
paths = sorted(root.glob('*/config.json'))
if os.environ.get('RECORDER_DISTRIBUTION') == '1':
    pathlib.Path(sys.argv[1]).unlink(missing_ok=True)
elif paths:
    c = Config(revision=paths[-1].parent.name)
    pathlib.Path(sys.argv[1]).write_text(json.dumps(asdict(c)))
PY
# Python must not mutate signed resources when running. Startup disables bytecode writes.
.venv/bin/python - "$app" <<'PYCODE'
import pathlib, shutil, sys
for folder in pathlib.Path(sys.argv[1]).rglob('__pycache__'):
    shutil.rmtree(folder)
PYCODE
codesign --force --deep --sign - "$app"
printf 'Built: %s\n' "$app"
