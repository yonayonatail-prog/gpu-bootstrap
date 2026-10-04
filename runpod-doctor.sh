#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

RUNTIME_ROOT="${RUNTIME_ROOT:-/workspace/runtime}"
REPORT="$RUNTIME_ROOT/runpod-support-report.txt"
mkdir -p "$RUNTIME_ROOT"

utc_now() { date -u +%FT%TZ; }

cuda_probe() {
  python3 - <<'PY'
import ctypes

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
PY
}

SMI_QUERY=""
SMI_FULL=""
GPU_NODES=""
CUDA_OUTPUT=""
CUDA_RC=0
FAIL_REASON=""

if command -v nvidia-smi >/dev/null 2>&1; then
  set +e
  SMI_QUERY="$(timeout --foreground 15 nvidia-smi --query-gpu=index,name,uuid,memory.total,driver_version --format=csv,noheader,nounits 2>&1)"
  SMI_RC=$?
  SMI_FULL="$(timeout --foreground 15 nvidia-smi 2>&1)"
  set -e
else
  SMI_RC=127
  SMI_QUERY="nvidia-smi not found"
  SMI_FULL="$SMI_QUERY"
fi

GPU_NODES="$(ls -l /dev/nvidia* 2>&1 || true)"

if command -v python3 >/dev/null 2>&1; then
  set +e
  CUDA_OUTPUT="$(timeout --foreground 15 bash -c 'cuda_probe() { python3 - <<'"'"'PY'"'"'
import ctypes
try:
    cuda = ctypes.CDLL("libcuda.so.1")
except OSError as exc:
    print("CUDA_DRIVER_LOAD_FAILED", repr(exc)); raise SystemExit(20)
cuda.cuInit.argtypes=[ctypes.c_uint]; cuda.cuInit.restype=ctypes.c_int
cuda.cuDeviceGetCount.argtypes=[ctypes.POINTER(ctypes.c_int)]; cuda.cuDeviceGetCount.restype=ctypes.c_int
rc=cuda.cuInit(0); print("CUINIT_RC", rc)
if rc != 0:
    try:
        cuda.cuGetErrorName.argtypes=[ctypes.c_int,ctypes.POINTER(ctypes.c_char_p)]; cuda.cuGetErrorName.restype=ctypes.c_int
        cuda.cuGetErrorString.argtypes=[ctypes.c_int,ctypes.POINTER(ctypes.c_char_p)]; cuda.cuGetErrorString.restype=ctypes.c_int
        name=ctypes.c_char_p(); desc=ctypes.c_char_p(); cuda.cuGetErrorName(rc,ctypes.byref(name)); cuda.cuGetErrorString(rc,ctypes.byref(desc))
        print("CUINIT_ERROR", name.value.decode() if name.value else "unknown", desc.value.decode() if desc.value else "")
    except Exception: pass
    raise SystemExit(21)
count=ctypes.c_int(); rc2=cuda.cuDeviceGetCount(ctypes.byref(count)); print("CUDEVICEGETCOUNT_RC",rc2); print("CUDA_DEVICE_COUNT",count.value)
if rc2 != 0 or count.value < 1: raise SystemExit(22)
PY
}; cuda_probe' 2>&1)"
  CUDA_RC=$?
  set -e
else
  CUDA_RC=23
  CUDA_OUTPUT="python3 not found"
fi

if [[ $SMI_RC -ne 0 ]]; then
  FAIL_REASON="nvidia-smi failed or timed out (exit $SMI_RC)"
elif [[ $CUDA_RC -ne 0 ]]; then
  FAIL_REASON="CUDA Driver API probe failed (exit $CUDA_RC) while nvidia-smi was available"
fi

if [[ -n "$FAIL_REASON" ]]; then
  POD_ID="${RUNPOD_POD_ID:-unknown}"
  DC_ID="${RUNPOD_DC_ID:-unknown}"
  HOST="$(hostname 2>/dev/null || echo unknown)"
  KERNEL="$(uname -a 2>/dev/null || echo unknown)"
  cat >"$REPORT" <<EOF
Subject: Community Cloud Pod exposed GPU via nvidia-smi but CUDA compute was unusable

Hello Runpod Support,

I rented a Community Cloud Pod that appeared to have an NVIDIA GPU, but CUDA compute was not usable. I terminated the Pod after confirming the failure.

Please review the billing for this unusable Pod period and apply an account credit if appropriate.

Pod ID: $POD_ID
Datacenter ID: $DC_ID
UTC timestamp: $(utc_now)
Hostname: $HOST
Kernel: $KERNEL
Failure: $FAIL_REASON

--- nvidia-smi query ---
$SMI_QUERY

--- CUDA Driver API probe ---
$CUDA_OUTPUT

--- NVIDIA device nodes ---
$GPU_NODES

--- selected CUDA environment ---
CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES-<unset>}
NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES-<unset>}
CUDA_HOME=${CUDA_HOME-<unset>}
CUDA_PATH=${CUDA_PATH-<unset>}
LD_LIBRARY_PATH=${LD_LIBRARY_PATH-<unset>}
VIRTUAL_ENV=${VIRTUAL_ENV-<unset>}

--- full nvidia-smi ---
$SMI_FULL

No model downloads were started by this doctor.
EOF

  echo
  echo '================ RUNPOD SUPPORT REPORT ================'
  cat "$REPORT"
  echo '================ END SUPPORT REPORT ==================='
  echo
  echo "[POD STATUS] UNUSABLE"
  echo "Saved: $REPORT"
  echo "Copy the report above into a Runpod support ticket before terminating the Pod."
  exit 42
fi

printf '%s\n' "$SMI_QUERY"
printf '%s\n' "$CUDA_OUTPUT"
free_kib="$(df -Pk "$RUNTIME_ROOT" | awk 'NR==2 {print $4}')"
printf 'Disk free: %.1f GiB\n[POD STATUS] USABLE\n' "$(awk "BEGIN { print $free_kib / 1048576 }")"
