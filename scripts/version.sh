#!/bin/bash
# The one place that reads and interprets the release version (shared by build.sh, package.sh,
# publish_mac_release.sh and check_version.sh).
# Usage: scripts/version.sh [version|build] [x.y.z]
#   version  prints the version (default)         0.5.0
#   build    prints the integer build number      500   (major*10000 + minor*100 + patch, same as Android's versionCode)
# Without a second argument the version comes from the root VERSION file. Exits non-zero unless it is x.y.z.
set -euo pipefail

what="${1:-version}"
if [ "$#" -ge 2 ]; then
  version="$2"
else
  version=$(tr -d '[:space:]' < "$(dirname "$0")/../VERSION")
fi

if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  printf 'VERSION 必须是 x.y.z：%s\n' "$version" >&2
  exit 1
fi
major=$((10#${BASH_REMATCH[1]}))
minor=$((10#${BASH_REMATCH[2]}))
patch=$((10#${BASH_REMATCH[3]}))
if [ "$minor" -gt 99 ] || [ "$patch" -gt 99 ]; then
  printf '次版本号和修订号不能超过 99（构建号 major*10000 + minor*100 + patch）：%s\n' "$version" >&2
  exit 1
fi

case "$what" in
  version) printf '%s\n' "$version" ;;
  build) printf '%s\n' $(( major * 10000 + minor * 100 + patch )) ;;
  *) printf '用法：version.sh [version|build] [x.y.z]\n' >&2; exit 2 ;;
esac
