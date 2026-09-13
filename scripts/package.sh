#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/dist/声笺.app"
output="$PWD/dist/声笺-0.3.1-arm64.dmg"
if [ ! -d "$app" ]; then
  printf '请先运行 ./scripts/build.sh\n' >&2
  exit 1
fi
if [ -e "$output" ]; then
  printf '安装包已存在：%s（请先移动旧版本）\n' "$output" >&2
  exit 1
fi
codesign --verify --deep --strict "$app"
# Model weights must remain in the user's cache, never inside the installer.
.venv/bin/python - "$app" <<'PYCODE'
from pathlib import Path
import sys
root = Path(sys.argv[1])
weights = list(root.rglob('*.safetensors')) + list(root.rglob('weights.npz')) + list(root.rglob('*.gguf'))
if weights:
    raise SystemExit('拒绝打包：应用中包含模型权重')
PYCODE
staging=$(mktemp -d "$PWD/dist/package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/声笺.app"
ln -s /Applications "$staging/Applications"
cat > "$staging/安装说明.txt" <<'TXT'
声笺 0.3.1 · Apple Silicon macOS

安装：
1. 先退出正在运行的声笺。
2. 将「声笺.app」拖入「Applications」（应用程序）。
3. 从「应用程序」打开声笺，随后推出此磁盘映像。
4. 点击「加载模型」，再点击「开始转写」，按系统提示允许麦克风。

本机已安装默认模型缓存，可直接加载，无需重复下载。
设置中可选择 Qwen3-ASR 1.7B 或 Whisper Large v3 Turbo，首次使用先点击「下载模型」。
Qwen 约 4.08 GB，Whisper 约 1.61 GB；下载后可离线切换。
本安装包包含 Python 和推理依赖，模型独立存放，不包含在安装包内。
模型和配置目录：~/Library/Application Support/LocalRecorder/
默认快捷键：Control + Option + Space。

此版本仅支持 Apple Silicon，要求 macOS 14 或更新；已实测 macOS 26.5.1。
本机试用构建使用临时签名，未通过 Apple 开发者签名与公证。
不保存录音和文字历史，不上传音频。退出前可将文字另存为 TXT。
「AI 提问」支持摘要、翻译与自定义问题，在「设置 → AI 服务」中填写 Base URL、模型 ID 和 API Key。
点击发送后原文会发给所选 AI 服务，可能产生服务商费用；API Key 保存在系统钥匙串。
TXT
hdiutil create -volname '声笺 0.3.1' -srcfolder "$staging" -format UDZO -ov "$output"
hdiutil verify "$output"
shasum -a 256 "$output" > "$output.sha256"
printf '已生成：%s\n' "$output"
