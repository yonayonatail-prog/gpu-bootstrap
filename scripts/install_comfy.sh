#!/usr/bin/env bash
set -Eeuo pipefail
comfy_dir=$1
venv_dir=$2
[[ -x "$venv_dir/bin/python" ]] || python3 -m venv "$venv_dir"
py="$venv_dir/bin/python"
"$py" -m pip install --disable-pip-version-check 'pip==25.2'
"$py" -m pip install --disable-pip-version-check torch==2.7.1 torchvision==0.22.1 torchaudio==2.7.1 --index-url https://download.pytorch.org/whl/cu128
"$py" -m pip install --disable-pip-version-check -r "$comfy_dir/requirements.txt" -c "$(dirname "$0")/torch-constraints.txt"
"$py" -m pip check
"$py" -c 'import torch; assert torch.cuda.is_available(), "CUDA unavailable. Check NVIDIA driver and GPU template."; print("CUDA READY:", torch.cuda.get_device_name(0))'
