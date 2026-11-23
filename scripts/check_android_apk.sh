#!/bin/bash
# Checks a release APK: size budget, and with --signed a valid v2/v3 signature that is not the debug key.
# Usage: scripts/check_android_apk.sh <apk> [--signed]
set -euo pipefail

apk="${1:?usage: check_android_apk.sh <apk> [--signed]}"
signed="${2:-}"
budget=$((10 * 1024 * 1024))

[ -f "$apk" ] || { echo "APK 不存在：$apk" >&2; exit 1; }
size=$(wc -c < "$apk" | tr -d ' ')
printf 'APK 大小：%s 字节（%.2f MB，上限 10 MB）\n' "$size" "$(echo "$size / 1048576" | bc -l)"
if [ "$size" -gt "$budget" ]; then
  echo "APK 超出 10 MB 体积上限" >&2
  exit 1
fi

if [ "$signed" = "--signed" ]; then
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [ -n "$sdk" ] || { echo "需要 ANDROID_HOME 来找到 apksigner" >&2; exit 1; }
  apksigner=$(ls -d "$sdk"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)
  [ -n "$apksigner" ] || { echo "在 $sdk/build-tools 中找不到 apksigner" >&2; exit 1; }
  certs=$("$apksigner" verify --verbose --print-certs "$apk")
  echo "$certs" | grep -E '^Verified using|^Signer #1 certificate (DN|SHA-256)'
  echo "$certs" | grep -q '^Verified using v2 scheme (APK Signature Scheme v2): true' \
    || { echo "APK 没有 v2 签名" >&2; exit 1; }
  if echo "$certs" | grep -q 'certificate DN: C=US, O=Android, CN=Android Debug'; then
    echo "APK 使用的是调试签名，不能发布" >&2
    exit 1
  fi
fi
