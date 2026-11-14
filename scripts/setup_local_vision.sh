#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'Local photo descriptions require an Apple Silicon Mac.' >&2
  exit 1
fi
VISION_UV="${WIMM_UV:-$(command -v uv || true)}"
if [[ -z "$VISION_UV" && -x "$HOME/.local/bin/uv" ]]; then VISION_UV="$HOME/.local/bin/uv"; fi
if [[ -z "$VISION_UV" ]]; then echo 'Install uv, then rerun this script.' >&2; exit 1; fi
VISION_RUNTIME="$HOME/.cache/wimm/runtime/qwen35-vision"
if [[ ! -x "$VISION_RUNTIME/bin/python" ]]; then "$VISION_UV" venv --python 3.13 "$VISION_RUNTIME"; fi
"$VISION_UV" pip install --python "$VISION_RUNTIME/bin/python" 'mlx-vlm==0.7.10'
"$VISION_RUNTIME/bin/python" - <<'PY'
from pathlib import Path
from huggingface_hub import snapshot_download
snapshot_download('mlx-community/Qwen3.5-0.8B-4bit',
    revision='da28692b5f139cb0ec58a356b437486b7dac7462',
    local_dir=Path.home()/'.cache/wimm/models/Qwen3.5-0.8B-4bit',
    allow_patterns=['*.json', '*.jinja', '*.safetensors', '*.txt'])
print('Local photo model installed. Image processing runs offline.')
PY
