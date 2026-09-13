"""Explicitly install this project's downloaded default model into app-owned storage."""
import json
import os
import subprocess
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = root / 'models/models--mlx-community--Qwen3-ASR-1.7B-bf16'
if not source.is_dir():
    sys.exit('开发模型不存在。可以直接在 App 中下载，无需执行本脚本。')
cache = Path.home() / 'Library/Application Support/LocalRecorder/models'
cache.mkdir(parents=True, exist_ok=True)
destination = cache / source.name
if destination.exists():
    print('缓存目录已存在；保留现有内容，不覆盖。')
else:
    subprocess.run(['cp', '-cR', str(source), str(destination)], check=True)
    print(f'模型已安装：{destination}')
