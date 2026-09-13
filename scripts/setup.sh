#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export UV_CACHE_DIR="$PWD/.uv-cache"
export UV_PYTHON_INSTALL_DIR="$PWD/.python"
if [ ! -x .bootstrap/bin/uv ]; then
    python3 -m venv .bootstrap
    .bootstrap/bin/pip install 'uv==0.12.10'
fi
.bootstrap/bin/uv venv --python 3.12.14 .venv --allow-existing
.bootstrap/bin/uv pip sync --python .venv/bin/python requirements.lock
