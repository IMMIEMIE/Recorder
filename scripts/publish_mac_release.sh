#!/bin/bash
# Uploads the locally built macOS DMG to the GitHub Release for tag v<VERSION>, next to the CI-built APK.
# Prerequisites: scripts/build.sh and scripts/package.sh have produced dist/声笺-<ver>-arm64.dmg, the tag
# v<VERSION> already exists on origin (pushing it is what starts release.yml; this script never creates or
# pushes tags), and `gh` is logged in. A missing release is created as a DRAFT, never published.
# Usage: scripts/publish_mac_release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(scripts/version.sh version)
build_number=$(scripts/version.sh build)
tag="v$version"
dmg="dist/声笺-$version-arm64.dmg"
# ASCII asset name: GitHub Releases rewrites non-ASCII file names (the CI APK is Recorder-<ver>-android.apk).
asset="Recorder-$version-arm64.dmg"

if [ ! -f "$dmg" ]; then
  printf '找不到安装包：%s（先运行 scripts/build.sh 和 scripts/package.sh）\n' "$dmg" >&2
  exit 1
fi

# The DMG must hold a validly signed app of this version.
mount=$(mktemp -d "${TMPDIR:-/tmp}/publish-mac.XXXXXX")
mounted=0
cleanup() {
  if [ "$mounted" = 1 ]; then hdiutil detach -quiet "$mount" || true; fi
  rmdir "$mount" 2>/dev/null || true
  [ -z "${stage:-}" ] || rm -rf "$stage"
}
trap cleanup EXIT
hdiutil verify -quiet "$dmg" || { printf '安装包校验失败：%s\n' "$dmg" >&2; exit 1; }
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null
mounted=1
app="$mount/声笺.app"
if [ ! -d "$app" ]; then
  printf '安装包中没有 声笺.app：%s\n' "$dmg" >&2
  exit 1
fi
if ! codesign --verify --deep --strict "$app"; then
  printf '拒绝发布：声笺.app 签名校验失败\n' >&2
  exit 1
fi
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [ "$bundle_version" != "$version" ]; then
  printf '拒绝发布：应用版本 %s 与 VERSION %s 不一致\n' "$bundle_version" "$version" >&2
  exit 1
fi
# CFBundleVersion is the integer build number: major*10000 + minor*100 + patch (scripts/build.sh).
bundle_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
if [ "$bundle_build" != "$build_number" ]; then
  printf '拒绝发布：应用构建号 %s 应为 %s\n' "$bundle_build" "$build_number" >&2
  exit 1
fi

# The tag must already be on origin (checked remotely, not just locally).
if [ -z "$(git ls-remote --tags origin "refs/tags/$tag")" ]; then
  printf 'origin 上没有标签 %s；请先推送标签（同时触发安卓 APK 的构建）\n' "$tag" >&2
  exit 1
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/publish-mac.XXXXXX")
cp "$dmg" "$stage/$asset"
(cd "$stage" && shasum -a 256 "$asset" > "$asset.sha256")

if ! gh release view "$tag" >/dev/null 2>&1; then
  notes="docs/RELEASE-$version.md"
  if [ -f "$notes" ]; then set -- --notes-file "$notes"; else set -- --notes "声笺 $version（macOS + 安卓）"; fi
  gh release create "$tag" --draft --verify-tag --title "声笺 $version" "$@"
fi
gh release upload "$tag" --clobber "$stage/$asset" "$stage/$asset.sha256"
printf '已上传 %s 和 %s.sha256 到 %s（草稿状态保持不变，请在 GitHub 上检查后手动发布）\n' "$asset" "$asset" "$tag"
