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
[[ -e /dev/nvidiactl ]] || fail "/dev/nvidiactl is missing although nvidia-smi works."
[[ -e /dev/nvidia-uvm ]] || fail "/dev/nvidia-uvm is missing although nvidia-smi works."
mapfile -t GPU_NODES < <(compgen -G '/dev/nvidia[0-9]*' || true)
((${#GPU_NODES[@]} > 0)) || fail "No /dev/nvidia<N> compute device is exposed."
printf '[GPU DEVICE NODES] %s\n' "${GPU_NODES[*]}"

printf '[CUDA ENV]\n'
for name in CUDA_VISIBLE_DEVICES NVIDIA_VISIBLE_DEVICES CUDA_HOME CUDA_PATH LD_LIBRARY_PATH VIRTUAL_ENV; do
  printf '%s=%s\n' "$name" "${!name-<unset>}"
done

# Probe the CUDA Driver API directly. nvidia-smi uses NVML and may still work on
# a Pod where CUDA compute initialization is broken.
echo '[CUDA DRIVER PROBE] libcuda.so.1 -> cuInit(0)'
set +e
python3 - <<'PY'
import ctypes
import sys

try:
    cuda = ctypes.CDLL("libcuda.so.1")
except OSError as exc:
    print("CUDA_DRIVER_LOAD_FAILED", repr(exc))
    raise SystemExit(20)

cuda.cuInit.argtypes = [ctypes.c_uint]
cuda.cuInit.restype = ctypes.c_int
cuda.cuDeviceGetCount.argtypes = [ctypes.POINTER(ctypes.c_int)]
cuda.cuDeviceGetCount.restype = ctypes.c_int

rc = cuda.cuInit(0)
print("CUINIT_RC", rc)
if rc != 0:
    try:
        cuda.cuGetErrorName.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)]
        cuda.cuGetErrorName.restype = ctypes.c_int
        cuda.cuGetErrorString.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)]
        cuda.cuGetErrorString.restype = ctypes.c_int
        name = ctypes.c_char_p()
        desc = ctypes.c_char_p()
        cuda.cuGetErrorName(rc, ctypes.byref(name))
        cuda.cuGetErrorString(rc, ctypes.byref(desc))
        print("CUINIT_ERROR", name.value.decode() if name.value else "unknown", desc.value.decode() if desc.value else "")
    except Exception:
        pass
    raise SystemExit(21)

count = ctypes.c_int()
rc2 = cuda.cuDeviceGetCount(ctypes.byref(count))
print("CUDEVICEGETCOUNT_RC", rc2)
print("CUDA_DEVICE_COUNT", count.value)
if rc2 != 0 or count.value < 1:
    raise SystemExit(22)
print("[CUDA DRIVER PROBE] PASS")
PY
rc=$?
set -e
case "$rc" in
  0) ;;
  20) fail "libcuda.so.1 cannot be loaded. The Pod exposes nvidia-smi but not the CUDA driver library; terminate this Pod." ;;
  21) fail "CUDA driver API cuInit(0) failed while nvidia-smi succeeds. This is a bad Community Cloud GPU exposure; terminate this Pod." ;;
  22) fail "CUDA driver initialized but reports no compute devices. Terminate this Pod." ;;
  *) fail "CUDA driver probe failed unexpectedly with exit $rc." ;;
esac

# Prefer the actually-active Python environment instead of assuming where the
# Runpod template stored .venv-cu128.
BASE_PY="${RUNPOD_BASE_CUDA_PY:-}"
if [[ -z "$BASE_PY" && -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python" ]]; then
  BASE_PY="${VIRTUAL_ENV}/bin/python"
fi
if [[ -z "$BASE_PY" ]]; then
  candidate="$(command -v python 2>/dev/null || true)"
  [[ -x "$candidate" ]] && BASE_PY="$candidate"
fi

if [[ -n "$BASE_PY" && -x "$BASE_PY" ]]; then
  echo "[BASE CUDA PROBE] $BASE_PY"
  set +e
  "$BASE_PY" - <<'PY'
try:
    import torch
except Exception as exc:
    print("BASE_TORCH_IMPORT_FAILED", repr(exc))
    raise SystemExit(3)
print("BASE_TORCH", torch.__version__, "built_cuda=", torch.version.cuda)
if torch.version.cuda is None:
    print("BASE_TORCH_CPU_ONLY")
    raise SystemExit(5)
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
    fail "The active CUDA-enabled PyTorch cannot initialize CUDA, while the direct CUDA driver probe passed. This points to the template Python environment rather than the GPU device itself."
  elif [[ $rc -eq 5 ]]; then
    echo "[BASE CUDA PROBE] inconclusive: active Python has CPU-only torch; direct CUDA driver probe already passed."
  elif [[ $rc -ne 0 ]]; then
    echo "[BASE CUDA PROBE] inconclusive (active environment could not be used); direct CUDA driver probe already passed."
  else
    echo "[BASE CUDA PROBE] PASS"
  fi
else
  echo "[BASE CUDA PROBE] skipped: no active Python found"
fi

curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 "$V3" -o "$TMP"
chmod 700 "$TMP"
exec bash "$TMP"
