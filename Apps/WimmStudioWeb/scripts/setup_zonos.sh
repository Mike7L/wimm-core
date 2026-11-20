#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -sm)" != 'Darwin arm64' ]]; then
  echo 'The Wimm ZONOS3-Mini installer requires an Apple Silicon Mac.' >&2
  exit 1
fi

for tool in uv hf; do
  if ! command -v "$tool" >/dev/null; then
    echo "Install $tool and rerun this script." >&2
    exit 1
  fi
done

web_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="$web_dir/.cache/zonos3"
revision=a50e14117d99181ba7f28047b451ba03ba1a09a9
mkdir -p "$web_dir/.cache"
if [[ ! -d "$runtime/.git" ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/Zyphra/ZONOS3-Mini.git "$runtime"
fi
if ! git -C "$runtime" cat-file -e "$revision^{commit}"; then
  git -C "$runtime" fetch origin "$revision"
fi
git -C "$runtime" checkout --detach "$revision"
git -C "$runtime" submodule update --init third_party/fusealign-multilingual

UV_CACHE_DIR="$web_dir/.cache/uv" UV_PYTHON_INSTALL_DIR="$web_dir/.cache/python" \
  uv --directory "$runtime" sync --frozen --no-default-groups --package zonos3-mlx
HF_HUB_DISABLE_IMPLICIT_TOKEN=1 hf download Zyphra/ZONOS3-Mini \
  --revision 2921b8821772b0bd10a04456863d21abf9d2f283 \
  --include gguf/backbone-ptq.gguf --include gguf/zac-keep2.gguf --include 'gguf/voices/*' \
  --local-dir "$runtime/servers/ggml"
touch "$runtime/.wimm-ready"
