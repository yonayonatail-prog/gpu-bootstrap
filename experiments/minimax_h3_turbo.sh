#!/usr/bin/env bash
set -euo pipefail

# EXPERIMENTAL / NOT CANONICAL
# MiniMax H3 I2V + official 8-step Turbo LoRA for a disposable RunPod pod.
# Target tested first: RTX 5090, CUDA-capable pod, PyTorch/CUDA 12.8 template.

ROOT="/workspace/h3-experiment"
COMFY="$ROOT/ComfyUI"
VENV="$ROOT/venv"
LOG_DIR="$ROOT/logs"
COMFY_TAG="v0.38.0"
H3_REV="eb8a16107c595128b3a578f82d2ce2f75920c355"
TURBO_REV="d7ab616e3d6b5c6151f06544cc702aa602b453f3"
WORKFLOW_REV="e7cd011d4ded3411c2f481200544f0be6fdc962e"
WORKFLOW_NAME="minimax_h3_i2v_turbo_fp8.json"

unset PIP_CONSTRAINT PIP_REQUIREMENT PIP_CONFIG_FILE PIP_EXTRA_INDEX_URL PIP_NO_INDEX PIP_FIND_LINKS || true
mkdir -p "$ROOT" "$LOG_DIR"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found" >&2
  exit 20
fi

python3 - <<'PY'
import ctypes
lib = ctypes.CDLL("libcuda.so.1")
rc = lib.cuInit(0)
print("CUINIT_RC", rc)
if rc != 0:
    raise SystemExit(21)
count = ctypes.c_int()
rc2 = lib.cuDeviceGetCount(ctypes.byref(count))
print("CUDEVICEGETCOUNT_RC", rc2)
print("CUDA_DEVICE_COUNT", count.value)
if rc2 != 0 or count.value < 1:
    raise SystemExit(22)
PY

if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ffmpeg python3-venv >/dev/null
fi

if [[ ! -d "$COMFY/.git" ]]; then
  git clone --depth 1 --branch "$COMFY_TAG" https://github.com/Comfy-Org/ComfyUI.git "$COMFY"
else
  git -C "$COMFY" fetch --depth 1 origin "refs/tags/$COMFY_TAG:refs/tags/$COMFY_TAG"
  git -C "$COMFY" checkout --force "$COMFY_TAG"
fi

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv --system-site-packages "$VENV"
fi

"$VENV/bin/python" -m pip install -U pip wheel setuptools >/dev/null
"$VENV/bin/python" -m pip install -r "$COMFY/requirements.txt"
# tokenizers 0.23.x requires huggingface-hub < 2.0. Keep the CLI available
# without upgrading the environment to an incompatible huggingface-hub 2.x.
"$VENV/bin/python" -m pip install -U "huggingface_hub>=0.34,<2.0"

"$VENV/bin/python" - <<'PY'
import torch
import huggingface_hub
import tokenizers
print("TORCH", torch.__version__)
print("TORCH_CUDA", torch.version.cuda)
print("CUDA_AVAILABLE", torch.cuda.is_available())
print("HUGGINGFACE_HUB", huggingface_hub.__version__)
print("TOKENIZERS", tokenizers.__version__)
if not torch.cuda.is_available():
    raise SystemExit(23)
print("GPU", torch.cuda.get_device_name(0))
print("CAPABILITY", torch.cuda.get_device_capability(0))
PY

mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae" \
  "$COMFY/models/loras" \
  "$COMFY/user/default/workflows" \
  "$COMFY/input"

export HF_HUB_DOWNLOAD_TIMEOUT="120"

hf_retry() {
  local attempt=1
  local max_attempts=5
  while true; do
    if "$VENV/bin/hf" "$@"; then
      return 0
    fi
    if (( attempt >= max_attempts )); then
      echo "ERROR: Hugging Face download failed after $max_attempts attempts." >&2
      echo "If this is HTTP 429, run: $VENV/bin/hf auth login" >&2
      echo "Then rerun this script; downloads are resumable." >&2
      return 1
    fi
    local delay=$(( attempt * 45 ))
    echo "WARN: hf failed (attempt $attempt/$max_attempts); retrying in ${delay}s..." >&2
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
}

echo "[H3] downloading base files (~42.5 GB before Turbo LoRA)..."
hf_retry download Comfy-Org/MiniMax-H3 \
  diffusion_models/minimax_h3_fl2va_pruned_fp8_scaled.safetensors \
  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
  vae/minimax_h3_video_vae_fp16.safetensors \
  vae/minimax_h3_audio_vae_fp32.safetensors \
  --revision "$H3_REV" \
  --local-dir "$COMFY/models"

echo "[H3] downloading official 8-step Turbo LoRA (~1.96 GB)..."
hf_retry download lightx2v/Minimax-h3-Turbo \
  minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors \
  --revision "$TURBO_REV" \
  --local-dir "$COMFY/models/loras"

WORKFLOW_URL="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/${WORKFLOW_REV}/templates/video_minimax_h3_i2v.json"
curl --fail --location --retry 3 --connect-timeout 20 --max-time 120 \
  "$WORKFLOW_URL" \
  -o "$COMFY/user/default/workflows/$WORKFLOW_NAME"

"$VENV/bin/python" - "$COMFY/user/default/workflows/$WORKFLOW_NAME" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace(
    "minimax_h3_fl2va_pruned_int8_convrot.safetensors",
    "minimax_h3_fl2va_pruned_fp8_scaled.safetensors",
)
text = text.replace(
    "minimax_h3_video_vae_int8_convrot.safetensors",
    "minimax_h3_video_vae_fp16.safetensors",
)
path.write_text(text, encoding="utf-8")
print("WORKFLOW", path)
PY

# Optional sample image referenced by the official template. The user can replace
# it in LoadImage with their own character image.
curl --fail --location --retry 3 \
  "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/${WORKFLOW_REV}/input/transparent_rgb_gaming_mouse.png" \
  -o "$COMFY/input/transparent_rgb_gaming_mouse.png" || true

# Avoid mistaking an already-running copy from this experiment for a foreign service.
if [[ -f "$ROOT/comfy.pid" ]]; then
  OLD_PID="$(cat "$ROOT/comfy.pid" 2>/dev/null || true)"
  if [[ -n "${OLD_PID:-}" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" || true
    sleep 2
  fi
fi

cd "$COMFY"
nohup "$VENV/bin/python" main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --enable-cors-header \
  >"$LOG_DIR/comfy.log" 2>&1 &
echo $! > "$ROOT/comfy.pid"

# Readiness means both the API and the actual frontend root are served by this
# process. RunPod's HTTP proxy reaches ComfyUI as a cross-site browser request;
# --enable-cors-header disables ComfyUI's localhost-origin-only middleware that
# otherwise returns HTTP 403 when opening *.proxy.runpod.net from the console.
for _ in $(seq 1 90); do
  API_OK=0
  ROOT_OK=0
  if curl -fsS "http://127.0.0.1:8188/system_stats" >/dev/null 2>&1; then
    API_OK=1
  fi
  if curl -fsS "http://127.0.0.1:8188/" 2>/dev/null | grep -qi '<title>ComfyUI</title>'; then
    ROOT_OK=1
  fi
  if [[ "$API_OK" -eq 1 && "$ROOT_OK" -eq 1 ]]; then
    echo "[READY] MiniMax H3 experimental ComfyUI"
    echo "ComfyUI local: http://127.0.0.1:8188"
    if [[ -n "${RUNPOD_POD_ID:-}" ]]; then
      echo "ComfyUI proxy: https://${RUNPOD_POD_ID}-8188.proxy.runpod.net"
    fi
    echo "Workflow: $WORKFLOW_NAME"
    echo "Base: FP8 scaled (chosen because this experiment keeps the pod's CUDA 12.8/PyTorch stack)"
    echo "Turbo: official LightX2V 8-step LoRA"
    echo "Log: $LOG_DIR/comfy.log"
    exit 0
  fi
  sleep 2
done

echo "ERROR: ComfyUI did not become healthy on port 8188." >&2
echo "Local API: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8188/system_stats || true)" >&2
echo "Local root: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8188/ || true)" >&2
tail -n 120 "$LOG_DIR/comfy.log" >&2 || true
exit 30
