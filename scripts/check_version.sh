#!/bin/bash
# Fails when the single version in VERSION and the places that must follow it disagree:
# the Android build script (versionName/versionCode), the macOS build/package scripts, version
# mentions in README.md, and (if present) an already built dist/声笺.app.
# Usage: scripts/check_version.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
bad() { printf '版本不一致：%s\n' "$1" >&2; fail=1; }

[ -f VERSION ] || { echo "缺少 VERSION 文件" >&2; exit 1; }
version=$(tr -d '[:space:]' < VERSION)
if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "VERSION 必须是 x.y.z：$version" >&2
  exit 1
fi
code=$(( BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100 + BASH_REMATCH[3] ))

# Android: versionName/versionCode must come from VERSION (not a literal), with the agreed formula.
gradle=android/app/build.gradle.kts
grep -q 'rootProject.file("../VERSION")' "$gradle" || bad "$gradle 没有读取 VERSION"
grep -Eq '^ *versionName = releaseVersion$' "$gradle" || bad "$gradle 的 versionName 不是取自 VERSION"
grep -Eq '^ *versionCode = releaseVersionCode$' "$gradle" || bad "$gradle 的 versionCode 不是取自 VERSION"
grep -Fq 'major.toInt() * 10000 + minor.toInt() * 100 + patch.toInt()' "$gradle" || bad "$gradle 的 versionCode 公式不是 major*10000 + minor*100 + patch"

# macOS: build.sh (Info.plist) and package.sh (DMG name, volume name, notes) read VERSION; no literal versions.
grep -Fq "tr -d '[:space:]' < VERSION" scripts/build.sh || bad "scripts/build.sh 没有读取 VERSION"
grep -Eq 'CFBundleVersion</key><string>__BUILD__' scripts/build.sh || bad "scripts/build.sh 的 CFBundleVersion 不是构建号占位符"
# shellcheck disable=SC2016
grep -Fq 'build_number=$(( BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100 + BASH_REMATCH[3] ))' scripts/build.sh || bad "scripts/build.sh 的构建号公式不是 major*10000 + minor*100 + patch"
grep -Eq 'CFBundleShortVersionString</key><string>__VERSION__' scripts/build.sh || bad "scripts/build.sh 的 CFBundleShortVersionString 不是取自 VERSION"
grep -Fq "tr -d '[:space:]' < VERSION" scripts/package.sh || bad "scripts/package.sh 没有读取 VERSION"
if grep -Eq '声笺[ -]v?[0-9]+\.[0-9]+\.[0-9]+' scripts/package.sh; then
  bad "scripts/package.sh 含有写死的版本号"
fi

# README.md: any macOS/Android release asset name or "声笺 x.y.z" mention must equal VERSION
# (the Windows x86 build has its own version and file names and is not checked).
while IFS= read -r found; do
  [ "$found" = "$version" ] || bad "README.md 提到 $found，VERSION 为 $version"
done < <(grep -Eo '(声笺-|Recorder-|声笺 v?)[0-9]+\.[0-9]+\.[0-9]+' README.md | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' || true)

# A built app (not required): CFBundleShortVersionString is VERSION, CFBundleVersion the integer build number
# (same formula as Android's versionCode).
plist="dist/声笺.app/Contents/Info.plist"
if [ -f "$plist" ] && command -v plutil >/dev/null 2>&1; then
  built=$(plutil -extract CFBundleShortVersionString raw -o - "$plist")
  [ "$built" = "$version" ] || bad "dist/声笺.app 的 CFBundleShortVersionString 是 $built，VERSION 为 $version（请重新运行 build.sh）"
  built=$(plutil -extract CFBundleVersion raw -o - "$plist")
  [ "$built" = "$code" ] || bad "dist/声笺.app 的 CFBundleVersion 是 $built，应为 $code（请重新运行 build.sh）"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf '版本一致：%s（Android versionCode %s）\n' "$version" "$code"
