#!/usr/bin/env bash
set -Eeuo pipefail
comfy_dir=$1
venv_dir=$2
[[ -x "$venv_dir/bin/python" ]] || python3 -m venv "$venv_dir"
py="$venv_dir/bin/python"

# Keep dependency stacks tied to the pinned ComfyUI revision. Existing profiles
# stay on the older, proven stack; MiniMax H3 uses the stack validated on the
# v0.38.0 experiment (RTX 5090 / cu128).
comfy_revision=$(git -C "$comfy_dir" rev-parse HEAD)
torch_version=2.7.1
torchvision_version=0.22.1
torchaudio_version=2.7.1
constraints="$(dirname "$0")/torch-constraints.txt"

if [[ "$comfy_revision" == "6b747c0428c343e1417219641db93a4fb7cb69ae" ]]; then
  torch_version=2.8.0
  torchvision_version=0.23.0
  torchaudio_version=2.8.0
  constraints="$venv_dir/comfy-v0.38.0-constraints.txt"
  cat >"$constraints" <<'EOF'
torch==2.8.0
torchvision==0.23.0
torchaudio==2.8.0
huggingface-hub==1.30.0
tokenizers==0.23.2
EOF
fi

"$py" -m pip install --disable-pip-version-check 'pip==25.2'
"$py" -m pip install --disable-pip-version-check \
  "torch==$torch_version" "torchvision==$torchvision_version" "torchaudio==$torchaudio_version" \
  --index-url https://download.pytorch.org/whl/cu128
"$py" -m pip install --disable-pip-version-check -r "$comfy_dir/requirements.txt" -c "$constraints"
site_packages=$("$py" -c 'import site; print(site.getsitepackages()[0])')
install -m 0644 "$(dirname "$0")/comfy_sitecustomize.py" "$site_packages/sitecustomize.py"
"$py" -m pip check
"$py" -c 'import torch; assert torch.cuda.is_available(), "CUDA unavailable. Check NVIDIA driver and GPU template."; print("CUDA READY:", torch.cuda.get_device_name(0))'
