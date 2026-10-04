#!/usr/bin/env bash
# EXPERIMENTAL wrapper: distinguish broken Community Cloud GPU from local env issues.
set -Eeuo pipefail
umask 077

BRANCH="experiment/qwen2509-multiangles"
V3="https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/${BRANCH}/experiments/qwen2509_multiangles_v3.sh"
TMP="$(mktemp /tmp/qwen2509_multiangles_v4.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

fail() {
  printf '\n[POD GPU COMPUTE FAILED]\n%s\n' "$*" >&2
  exit 42
}

command -v nvidia-smi >/dev/null || fail "nvidia-smi is missing. Terminate this Pod."
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || fail "nvidia-smi failed. Terminate this Pod."

printf '[GPU DEVICES]\n'
ls -l /dev/nvidia* 2>/dev/null || true
[[ -e /dev/nvidiactl ]] || fail "/dev/nvidiactl is missing although nvidia-smi works. Terminate this Pod."
[[ -e /dev/nvidia-uvm ]] || fail "/dev/nvidia-uvm is missing although nvidia-smi works. Terminate this Pod."
shopt -s nullglob
gpu_nodes=(/dev/nvidia[0-9]*)
shopt -u nullglob
((${#gpu_nodes[@]} > 0)) || fail "No /dev/nvidia<N> compute device is exposed although nvidia-smi works. Terminate this Pod."
printf '[GPU DEVICE NODES] %s\n' "${gpu_nodes[*]}"

printf '[CUDA ENV]\n'
for name in CUDA_VISIBLE_DEVICES NVIDIA_VISIBLE_DEVICES CUDA_HOME CUDA_PATH LD_LIBRARY_PATH; do
  printf '%s=%s\n' "$name" "${!name-<unset>}"
done

# The Runpod Slim template ships a prebuilt cu128 environment. Probe that first.
# Physical device nodes do not have to be named /dev/nvidia0 inside a container;
# the only reliable test is whether CUDA can actually allocate and compute.
BASE_PY="${RUNPOD_BASE_CUDA_PY:-/workspace/runpod-slim/.venv-cu128/bin/python}"
if [[ -x "$BASE_PY" ]]; then
  echo "[BASE CUDA PROBE] $BASE_PY"
  set +e
  "$BASE_PY" - <<'PY'
import sys
try:
    import torch
except Exception as exc:
    print("BASE_TORCH_IMPORT_FAILED", repr(exc))
    raise SystemExit(3)
print("BASE_TORCH", torch.__version__, "built_cuda=", torch.version.cuda)
print("BASE_CUDA_AVAILABLE", torch.cuda.is_available())
print("BASE_DEVICE_COUNT", torch.cuda.device_count())
if not torch.cuda.is_available():
    raise SystemExit(4)
x = torch.tensor([2.0], device="cuda")
print("BASE_CUDA_TENSOR", (x * 3).item())
print("BASE_GPU", torch.cuda.get_device_name(0))
PY
  rc=$?
  set -e
  if [[ $rc -eq 4 ]]; then
    fail "Runpod's own prebuilt cu128 PyTorch cannot initialize CUDA, while nvidia-smi succeeds.
This is a bad Community Cloud Pod/host GPU exposure. Do not download models; terminate it and rent another Pod."
  elif [[ $rc -ne 0 ]]; then
    echo "[BASE CUDA PROBE] inconclusive (base environment could not be used); continuing with isolated experiment probe."
  else
    echo "[BASE CUDA PROBE] PASS"
  fi
else
  echo "[BASE CUDA PROBE] skipped: $BASE_PY not found"
fi

curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 "$V3" -o "$TMP"
chmod 700 "$TMP"
exec bash "$TMP"
