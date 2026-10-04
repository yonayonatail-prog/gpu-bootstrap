#!/usr/bin/env bash
# EXPERIMENTAL: Qwen-Image-Edit-2509 + Multiple-Angles LoRA on Runpod
# Candidate only. Promote to gpu-bootstrap profile after a real generation succeeds.
set -Eeuo pipefail
umask 077

ROOT="${ROOT:-/workspace/qwen2509-multiangles-exp}"
LOG="$ROOT/setup.log"
PORT="${PORT:-8188}"
MIN_VRAM_MIB="${MIN_VRAM_MIB:-23000}"
MIN_FREE_GIB="${MIN_FREE_GIB:-55}"

COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFY_REV="72212fef660bcd7d9702fa52011d089c027a64d8" # v0.3.59
EASY_REPO="https://github.com/yolain/ComfyUI-Easy-Use.git"
EASY_REV="8ecc929cd41cf0f7ef6fcc45d4bbc5729c6f287f"
RGTHREE_REPO="https://github.com/rgthree/rgthree-comfy.git"
RGTHREE_REV="42e73c3c48e8268129a6a1ea6d9766913bfc5435"

fail() {
  printf '\n[FAILED]\n%s\n' "$*" >&2
  exit 1
}

gpu_precheck() {
  command -v nvidia-smi >/dev/null || fail "nvidia-smi not found. This Pod cannot use the GPU. Terminate it before downloading models."
  local q name vram driver
  q="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>&1)" ||
    fail "nvidia-smi failed: $q
This Community Cloud Pod exposes no usable NVIDIA GPU. Terminate it. No models were downloaded."
  name="$(printf '%s\n' "$q" | head -n1 | cut -d, -f1 | xargs)"
  vram="$(printf '%s\n' "$q" | head -n1 | cut -d, -f2 | xargs)"
  driver="$(printf '%s\n' "$q" | head -n1 | cut -d, -f3 | xargs)"
  [[ "$vram" =~ ^[0-9]+$ ]] || fail "Could not parse GPU VRAM from nvidia-smi: $q"
  (( vram >= MIN_VRAM_MIB )) || fail "GPU is alive but has too little VRAM.
Detected: $name / ${vram} MiB
Required: >= ${MIN_VRAM_MIB} MiB (24 GB class recommended)."
  printf '[GPU] %s | %s MiB | driver %s | PASS\n' "$name" "$vram" "$driver"
}

disk_precheck() {
  mkdir -p "$ROOT"
  local free_kib free_gib
  free_kib="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
  [[ "$free_kib" =~ ^[0-9]+$ ]] || fail "Could not read free disk space."
  free_gib=$(( free_kib / 1024 / 1024 ))
  (( free_gib >= MIN_FREE_GIB )) || fail "Not enough free disk.
Free: ${free_gib} GiB
Required before setup: >= ${MIN_FREE_GIB} GiB
Recommended Runpod Container Disk: 70 GB."
  printf '[DISK] %s GiB free | PASS\n' "$free_gib"
}

gpu_precheck
disk_precheck

if [[ "${QWEN2509_EXP_WORKER:-0}" != 1 ]]; then
  mkdir -p "$ROOT"
  launcher="$ROOT/launcher.sh"
  cp -- "${BASH_SOURCE[0]}" "$launcher"
  chmod 700 "$launcher"
  : >"$LOG"
  QWEN2509_EXP_WORKER=1 nohup bash "$launcher" </dev/null >>"$LOG" 2>&1 &
  echo "[STARTED] Qwen-Image-Edit-2509 + Multiple-Angles experimental setup"
  echo "PID: $!"
  echo "Progress: tail -f '$LOG'"
  echo "Wait for [READY] or [FAILED]."
  exit 0
fi

trap 'code=$?; printf "\n[FAILED]\nExit: %s\nCheck: %s\n" "$code" "$LOG"; exit "$code"' ERR
mkdir -p "$ROOT"
command -v flock >/dev/null || fail "flock is unavailable in this template."
exec 9>"$ROOT/setup.lock"
flock -n 9 || fail "Another experimental setup is already running in $ROOT."

echo "===== $(date -u +%FT%TZ) QWEN2509 MULTIANGLES EXPERIMENT ====="
gpu_precheck
disk_precheck

if [[ "$(id -u)" == 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null || fail "sudo is required when not root."
  sudo -n true || fail "Passwordless sudo is required."
  SUDO=(sudo -n)
fi

echo "[STAGE] system packages"
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  python3 python3-venv python3-pip git curl ca-certificates ffmpeg \
  build-essential libgl1 libglib2.0-0
command -v flock >/dev/null || fail "flock is unavailable."

COMFY="$ROOT/ComfyUI"
VENV="$ROOT/venv"
TMP="$ROOT/downloads"
mkdir -p "$TMP"

clone_pinned() {
  local repo="$1" rev="$2" dir="$3"
  if [[ ! -d "$dir/.git" ]]; then
    rm -rf "$dir"
    git clone --filter=blob:none --no-checkout "$repo" "$dir"
  fi
  git -C "$dir" fetch --depth 1 origin "$rev"
  git -C "$dir" checkout --detach -q "$rev"
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$rev" ]] || fail "Revision mismatch for $dir"
}

echo "[STAGE] ComfyUI v0.3.59"
clone_pinned "$COMFY_REPO" "$COMFY_REV" "$COMFY"

echo "[STAGE] Python environment"
[[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
PY="$VENV/bin/python"
PIP=("$PY" -m pip)
"${PIP[@]}" install --disable-pip-version-check -q 'pip==25.2'

CONSTRAINTS="$ROOT/constraints.txt"
cat >"$CONSTRAINTS" <<'EOF'
torch==2.7.1
torchvision==0.22.1
torchaudio==2.7.1
EOF

"${PIP[@]}" install --disable-pip-version-check -q \
  torch==2.7.1 torchvision==0.22.1 torchaudio==2.7.1 \
  --index-url https://download.pytorch.org/whl/cu128
"${PIP[@]}" install --disable-pip-version-check -q \
  -r "$COMFY/requirements.txt" -c "$CONSTRAINTS"
"${PIP[@]}" install --disable-pip-version-check -q 'huggingface_hub[hf_xet]>=0.34'

"$PY" - <<'PY'
import torch
assert torch.cuda.is_available(), "PyTorch installed but CUDA is unavailable"
x = torch.tensor([2.0], device="cuda")
assert (x * 3).item() == 6.0
print("[CUDA] tensor smoke test PASS:", torch.cuda.get_device_name(0))
PY

echo "[STAGE] Custom Nodes"
EASY="$COMFY/custom_nodes/ComfyUI-Easy-Use"
RGTHREE="$COMFY/custom_nodes/rgthree-comfy"
clone_pinned "$EASY_REPO" "$EASY_REV" "$EASY"
clone_pinned "$RGTHREE_REPO" "$RGTHREE_REV" "$RGTHREE"

if [[ -f "$EASY/requirements.txt" ]]; then
  "${PIP[@]}" install --disable-pip-version-check -q -r "$EASY/requirements.txt" -c "$CONSTRAINTS"
fi
if [[ -f "$RGTHREE/requirements.txt" ]]; then
  "${PIP[@]}" install --disable-pip-version-check -q -r "$RGTHREE/requirements.txt" -c "$CONSTRAINTS"
fi
"${PIP[@]}" check

HF="$VENV/bin/hf"
export HF_HOME="$ROOT/hf-cache"
export HF_XET_CHUNK_CACHE_SIZE_BYTES=0
export HF_HUB_DOWNLOAD_TIMEOUT=180

hf_to() {
  local repo="$1" rev="$2" remote="$3" dest="$4" sha="$5"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]] && printf '%s  %s\n' "$sha" "$dest" | sha256sum -c - >/dev/null 2>&1; then
    echo "[MODEL] $(basename "$dest") SKIP"
    return
  fi
  local local_dir="$TMP/$(printf '%s' "$repo-$rev-$remote" | sha256sum | cut -c1-16)"
  rm -rf "$local_dir"
  mkdir -p "$local_dir"
  echo "[MODEL] downloading $(basename "$dest")"
  "$HF" download "$repo" "$remote" --revision "$rev" --local-dir "$local_dir"
  src="$local_dir/$remote"
  [[ -f "$src" ]] || fail "hf download completed but file is missing: $remote"
  printf '%s  %s\n' "$sha" "$src" | sha256sum -c -
  mv -f "$src" "$dest"
  rm -rf "$local_dir"
}

echo "[STAGE] Models"
hf_to \
  "Comfy-Org/Qwen-Image-Edit_ComfyUI" \
  "87c96660003fddb262d73ed7539e823edecf59d4" \
  "split_files/diffusion_models/qwen_image_edit_2509_fp8_e4m3fn.safetensors" \
  "$COMFY/models/diffusion_models/qwen_image_edit_2509_fp8_e4m3fn.safetensors" \
  "318568f61951ab9da21100c7b896e3c1da67f0d2efad6421545e022cfaa2b2b4"

hf_to \
  "Comfy-Org/Qwen-Image_ComfyUI" \
  "25608066f9bf5cdc28020836ce9549587053f346" \
  "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors" \
  "$COMFY/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors" \
  "cb5636d852a0ea6a9075ab1bef496c0db7aef13c02350571e388aea959c5c0b4"

hf_to \
  "Comfy-Org/Qwen-Image_ComfyUI" \
  "25608066f9bf5cdc28020836ce9549587053f346" \
  "split_files/vae/qwen_image_vae.safetensors" \
  "$COMFY/models/vae/qwen_image_vae.safetensors" \
  "a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f"

hf_to \
  "Comfy-Org/Qwen-Image-Edit_ComfyUI" \
  "cab5c1c8eade88234986617ada53c1df0abde3a0" \
  "split_files/loras/Qwen-Edit-2509-Multiple-angles.safetensors" \
  "$COMFY/models/loras/Qwen-Edit-2509-Multiple-angles.safetensors" \
  "e0cea9508025a39e41f50da0e7d10fbd9db182d057c745136a42ef8829914c8f"

hf_to \
  "lightx2v/Qwen-Image-Lightning" \
  "813e69cd4c5627f2c7b921667f79690a0e12bd4e" \
  "Qwen-Image-Lightning-8steps-V1.1.safetensors" \
  "$COMFY/models/loras/Qwen-Image-Lightning-8steps-V1.1.safetensors" \
  "c5f33b60c0e3308b7c7688f5180457dfabbc09e4f4a4c4801d780d79b706a508"

echo "[STAGE] Author workflow"
WF_DIR="$COMFY/user/default/workflows"
WF="$WF_DIR/qwen2509_multiangles_runpod.json"
mkdir -p "$WF_DIR"

curl --fail --location --retry 3 --connect-timeout 30 --max-time 180 \
  "https://huggingface.co/dx8152/Qwen-Edit-2509-Multiple-angles/resolve/7972ee177a5fbab4eb778fbb4c3847815a14ac37/Qwen-Edit-2509-%E5%A4%9A%E8%A7%92%E5%BA%A6%E5%88%87%E6%8D%A2.json" \
  -o "$WF"

"$PY" - "$WF" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
repl = {
    "Qwen-Image-Edit-2509_fp8_e4m3fn.safetensors": "qwen_image_edit_2509_fp8_e4m3fn.safetensors",
    "qwen_2.5_vl_7b.safetensors": "qwen_2.5_vl_7b_fp8_scaled.safetensors",
    "镜头切换.safetensors": "Qwen-Edit-2509-Multiple-angles.safetensors",
    "镜头转换.safetensors": "Qwen-Edit-2509-Multiple-angles.safetensors",
    "Qwen-Image-Lightning-8steps-V1.0.safetensors": "Qwen-Image-Lightning-8steps-V1.1.safetensors",
}
def walk(v):
    if isinstance(v, dict):
        return {k: walk(x) for k, x in v.items()}
    if isinstance(v, list):
        return [walk(x) for x in v]
    if isinstance(v, str):
        return repl.get(v, v)
    return v
data = walk(data)
path.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
print("[WORKFLOW] patched for Linux + FP8 text encoder")
PY

echo "[STAGE] Start ComfyUI"
PIDFILE="$ROOT/comfy.pid"
if [[ -f "$PIDFILE" ]]; then
  oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then
    kill "$oldpid" || true
    for _ in $(seq 1 20); do
      kill -0 "$oldpid" 2>/dev/null || break
      sleep 1
    done
  fi
fi

cmd=("$PY" "$COMFY/main.py" --listen 0.0.0.0 --port "$PORT")
if [[ "${RUNPOD_POD_ID:-}" =~ ^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]]; then
  cmd+=(--enable-cors-header "https://${RUNPOD_POD_ID}-${PORT}.proxy.runpod.net")
fi
nohup "${cmd[@]}" </dev/null >>"$ROOT/comfyui.log" 2>&1 &
echo $! >"$PIDFILE"

echo "[STAGE] Health check"
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
  if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    tail -n 80 "$ROOT/comfyui.log" || true
    fail "ComfyUI exited during startup."
  fi
  if curl --fail --silent "http://127.0.0.1:${PORT}/system_stats" -o "$ROOT/system_stats.json"; then
    break
  fi
  sleep 2
done
[[ -s "$ROOT/system_stats.json" ]] || fail "ComfyUI did not become healthy within 600 seconds."

curl --fail --silent "http://127.0.0.1:${PORT}/object_info" -o "$ROOT/object_info.json"
"$PY" - "$ROOT/system_stats.json" "$ROOT/object_info.json" <<'PY'
import json, sys
stats = json.load(open(sys.argv[1], encoding="utf-8"))
nodes = json.load(open(sys.argv[2], encoding="utf-8"))
devices = stats.get("devices", [])
assert any(d.get("type") == "cuda" for d in devices), "ComfyUI sees no CUDA device"
required = {
    "TextEncodeQwenImageEditPlus",
    "easy imageSize",
    "easy promptLine",
    "Image Comparer (rgthree)",
}
missing = sorted(required - set(nodes))
assert not missing, f"Missing workflow nodes: {missing}"
print("[HEALTH] CUDA + required nodes PASS")
PY

echo
echo "[READY]"
echo "Workflow: qwen2509_multiangles_runpod.json"
echo "ComfyUI port: $PORT"
if [[ -n "${RUNPOD_POD_ID:-}" ]]; then
  echo "Runpod URL: https://${RUNPOD_POD_ID}-${PORT}.proxy.runpod.net"
fi
echo "Upload your source image in the LoadImage node, then Queue."
echo "Outputs: $COMFY/output"
echo "ComfyUI log: $ROOT/comfyui.log"
