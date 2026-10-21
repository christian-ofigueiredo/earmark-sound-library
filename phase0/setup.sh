#!/bin/bash
# One-time setup on a Mac (Apple Silicon). Creates .venv/ next to this file.
# Re-running it is safe; it only updates the environment.
set -euo pipefail
cd "$(dirname "$0")"

SKEY_COMMIT="918b83d273568d5041569bb8068843d19a335726"   # S-KEY (Deezer, MIT), pinned

if ! command -v uv >/dev/null 2>&1; then
  if [ -x "$HOME/.local/bin/uv" ]; then
    export PATH="$HOME/.local/bin:$PATH"
  else
    echo "Installing uv (a Python installer from astral.sh, ~30 MB, in ~/.local/bin)…"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi

echo "Creating the Python environment (Python 3.12)…"
uv venv --python 3.12 --allow-existing .venv
echo "Installing packages (PyTorch, transformers, audio libraries)… this takes a few minutes."
uv pip install --python .venv/bin/python -r requirements.txt
# S-KEY pins old versions of PyTorch/numpy that it doesn't need; install it without them.
if ! uv pip install --python .venv/bin/python --no-deps \
    "skey @ https://github.com/deezer/skey/archive/$SKEY_COMMIT.zip"; then
  echo "Download failed; trying with git instead…"
  uv pip install --python .venv/bin/python --no-deps "skey @ git+https://github.com/deezer/skey@$SKEY_COMMIT"
fi
chmod +x lab

.venv/bin/python - <<'PY'
import torch, transformers, skey, beat_this, umap  # noqa
print(f"\nInstalled. PyTorch {torch.__version__}, Apple GPU (MPS) available: {torch.backends.mps.is_available()}")
PY
echo
echo "Next: ./lab selftest      (downloads the AI models, ~11 GB, and checks everything)"
