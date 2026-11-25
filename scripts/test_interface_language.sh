#!/bin/bash
# Exercise the production SwiftUI lookup path with all 9 lproj directories in a main app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_localization.py
app="$PWD/.build/feature-tests/InterfaceLanguageTests.app/Contents"
rm -rf "$app/Resources"
mkdir -p "$app/MacOS" "$app/Resources"
cp -R assets/localization/*.lproj "$app/Resources/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>InterfaceLanguageTests</string>
<key>CFBundleIdentifier</key><string>test.recorder.interface-language</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST
plutil -lint "$app"/Resources/*.lproj/*.strings
swiftc -module-cache-path "$PWD/.build/module-cache" Sources/Recorder/InterfaceLanguage.swift \
  tests/InterfaceLanguageTests.swift -o "$app/MacOS/InterfaceLanguageTests"
"$app/MacOS/InterfaceLanguageTests"
