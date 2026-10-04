#!/usr/bin/env bash
# EXPERIMENTAL hotfix runner for qwen2509_multiangles.sh
# Patches the PyTorch install step to avoid resolver failures seen on some Runpod images.
set -Eeuo pipefail
umask 077

BRANCH="experiment/qwen2509-multiangles"
RAW="https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/${BRANCH}/experiments/qwen2509_multiangles.sh"
TMP="$(mktemp /tmp/qwen2509_multiangles_v2.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 "$RAW" -o "$TMP"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = '''"${PIP[@]}" install --disable-pip-version-check -q \\
  torch==2.7.1 torchvision==0.22.1 torchaudio==2.7.1 \\
  --index-url https://download.pytorch.org/whl/cu128
"${PIP[@]}" install --disable-pip-version-check -q \\
  -r "$COMFY/requirements.txt" -c "$CONSTRAINTS"
"${PIP[@]}" install --disable-pip-version-check -q 'huggingface_hub[hf_xet]>=0.34'

"$PY" - <<'PY'
import torch
assert torch.cuda.is_available(), "PyTorch installed but CUDA is unavailable"
x = torch.tensor([2.0], device="cuda")
assert (x * 3).item() == 6.0
print("[CUDA] tensor smoke test PASS:", torch.cuda.get_device_name(0))
PY
'''
new = '''"$PY" - <<'PY'
import sys
print("[PYTHON]", sys.version.replace("\\n", " "))
if not ((3, 10) <= sys.version_info < (3, 14)):
    raise SystemExit("Python 3.10-3.13 is required for this experiment")
PY

# Install torch with its CUDA dependencies first. Some Runpod images make pip's
# resolver fail when torch/vision/audio are requested as one transaction.
"${PIP[@]}" install --disable-pip-version-check -q \\
  torch==2.7.1 \\
  --index-url https://download.pytorch.org/whl/cu128
"${PIP[@]}" install --disable-pip-version-check -q --no-deps \\
  torchvision==0.22.1 torchaudio==2.7.1 \\
  --index-url https://download.pytorch.org/whl/cu128

"$PY" - <<'PY'
import torch, torchvision, torchaudio
assert torch.__version__.startswith("2.7.1"), torch.__version__
assert torchvision.__version__.startswith("0.22.1"), torchvision.__version__
assert torchaudio.__version__.startswith("2.7.1"), torchaudio.__version__
assert torch.cuda.is_available(), "PyTorch installed but CUDA is unavailable"
x = torch.tensor([2.0], device="cuda")
assert (x * 3).item() == 6.0
print("[PYTORCH]", torch.__version__, torchvision.__version__, torchaudio.__version__)
print("[CUDA] tensor smoke test PASS:", torch.cuda.get_device_name(0))
PY

"${PIP[@]}" install --disable-pip-version-check -q \\
  -r "$COMFY/requirements.txt" -c "$CONSTRAINTS" \\
  --extra-index-url https://download.pytorch.org/whl/cu128
"${PIP[@]}" install --disable-pip-version-check -q 'huggingface_hub[hf_xet]>=0.34'
'''
if old not in text:
    raise SystemExit("Hotfix target block not found; experimental source changed")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY

chmod 700 "$TMP"
exec bash "$TMP"
