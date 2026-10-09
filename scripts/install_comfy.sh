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
is_h3=0

if [[ "$comfy_revision" == "6b747c0428c343e1417219641db93a4fb7cb69ae" ]]; then
  is_h3=1
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

if [[ "$is_h3" == 1 ]]; then
  workflow_dir="$comfy_dir/user/default/workflows"
  workflow="$workflow_dir/h3_turbo_i2v.json"
  workflow_revision=e7cd011d4ded3411c2f481200544f0be6fdc962e
  mkdir -p "$workflow_dir"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 \
    "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/$workflow_revision/templates/video_minimax_h3_i2v.json" \
    -o "$workflow"
  "$py" - "$workflow" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
matched = 0
for node in data.get("nodes", []):
    labels = {entry.get("label") for entry in node.get("inputs", []) if isinstance(entry, dict)}
    if "turbo_mode" not in labels or "turbo_steps" not in labels:
        continue
    values = node.get("widgets_values")
    named = node.get("widgets_values_named", {})
    if not isinstance(values, list) or len(values) < 13:
        raise SystemExit("MiniMax H3 template layout changed; refusing to patch unknown workflow")
    values[5] = "minimax_h3_fl2va_pruned_fp8_scaled.safetensors"
    values[7] = "minimax_h3_video_vae_fp16.safetensors"
    values[9] = True
    values[10] = "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"
    values[11] = 1.0
    values[12] = 8
    named["unet_name"] = values[5]
    named["vae_name"] = values[7]
    named["value"] = True
    named["lora_name"] = values[10]
    named["strength_model_1"] = 1.0
    named["value_2"] = 8
    matched += 1
if matched != 1:
    raise SystemExit(f"Expected one MiniMax H3 Turbo subgraph, found {matched}")
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("H3 WORKFLOW READY:", path)
PY
fi
