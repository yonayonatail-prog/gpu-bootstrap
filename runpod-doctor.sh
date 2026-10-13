#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

RUNTIME_ROOT="${RUNTIME_ROOT:-/workspace/runtime}"
REPORT="$RUNTIME_ROOT/runpod-support-report.txt"
REPORT_JSON="$RUNTIME_ROOT/runpod-support-report.json"
NETWORK_JSON="$RUNTIME_ROOT/network-doctor.json"
mkdir -p "$RUNTIME_ROOT"

utc_now() { date -u +%FT%TZ; }

SMI_QUERY=""
SMI_FULL=""
GPU_NODES=""
CUDA_OUTPUT=""
CUDA_RC=0
FAIL_REASON=""
SMI_RC=0

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
  CUDA_OUTPUT="$(timeout --foreground 15 python3 - <<'PY' 2>&1
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
)"
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
  TIMESTAMP="$(utc_now)"

  cat >"$REPORT" <<EOF
Subject: Community Cloud Pod exposed GPU but CUDA compute was unusable

Hello Runpod Support,

I rented a Community Cloud Pod that appeared to have an NVIDIA GPU, but CUDA compute was not usable. I stopped using the Pod immediately after confirming the failure.

Please review the billing for this unusable Pod period and apply an account credit if appropriate.

Pod ID: $POD_ID
Datacenter ID: $DC_ID
UTC timestamp: $TIMESTAMP
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

  REPORT_JSON="$REPORT_JSON" POD_ID="$POD_ID" DC_ID="$DC_ID" TIMESTAMP="$TIMESTAMP" HOST="$HOST" KERNEL="$KERNEL" FAIL_REASON="$FAIL_REASON" SMI_QUERY="$SMI_QUERY" CUDA_OUTPUT="$CUDA_OUTPUT" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = {
    "pod_id": os.environ["POD_ID"],
    "datacenter_id": os.environ["DC_ID"],
    "utc_timestamp": os.environ["TIMESTAMP"],
    "hostname": os.environ["HOST"],
    "kernel": os.environ["KERNEL"],
    "failure": os.environ["FAIL_REASON"],
    "nvidia_smi_query": os.environ["SMI_QUERY"],
    "cuda_driver_probe": os.environ["CUDA_OUTPUT"],
}
Path(os.environ["REPORT_JSON"]).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

  echo
  echo '================ RUNPOD SUPPORT REPORT ================'
  cat "$REPORT"
  echo '================ END SUPPORT REPORT ==================='
  echo
  echo '[POD STATUS] UNUSABLE'
  echo "Saved text: $REPORT"
  echo "Saved JSON: $REPORT_JSON"
  echo 'Copy the report above into a Runpod support ticket before terminating the Pod.'
  exit 42
fi

probe_network() {
  local prefix="$1" label="$2" url="$3"
  local sample_bytes=$((8 * 1024 * 1024))
  local output rc speed bytes http_code seconds mbps status

  set +e
  output="$(curl --location --silent --show-error \
    --range "0-$((sample_bytes - 1))" \
    --connect-timeout 8 --max-time 12 \
    --output /dev/null \
    --write-out '%{speed_download} %{size_download} %{http_code} %{time_total}' \
    "$url" 2>/dev/null)"
  rc=$?
  set -e

  read -r speed bytes http_code seconds <<<"$output"
  speed="${speed:-0}"
  bytes="${bytes:-0}"
  http_code="${http_code:-000}"
  seconds="${seconds:-0}"

  if [[ ! "$speed" =~ ^[0-9]+([.][0-9]+)?$ || ! "$bytes" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    speed=0
    bytes=0
  fi

  mbps="$(awk -v s="$speed" 'BEGIN { printf "%.2f", s/1024/1024 }')"
  if awk -v b="$bytes" 'BEGIN { exit !(b < 262144) }'; then
    status="UNKNOWN"
  elif awk -v m="$mbps" 'BEGIN { exit !(m < 2) }'; then
    status="VERY_SLOW"
  elif awk -v m="$mbps" 'BEGIN { exit !(m < 5) }'; then
    status="SLOW"
  elif awk -v m="$mbps" 'BEGIN { exit !(m < 20) }'; then
    status="OK"
  else
    status="GOOD"
  fi

  printf '%-12s %8s MB/s  %-9s  sampled %.1f MiB in %.1fs  HTTP %s\n' \
    "$label" "$mbps" "$status" \
    "$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b/1024/1024 }')" "$seconds" "$http_code"

  printf -v "${prefix}_MBPS" '%s' "$mbps"
  printf -v "${prefix}_STATUS" '%s' "$status"
  printf -v "${prefix}_RC" '%s' "$rc"
  printf -v "${prefix}_HTTP" '%s' "$http_code"
}

network_diagnosis() {
  local slow_count=0 known_count=0
  local value
  for value in "$PYTORCH_MBPS" "$HF_MBPS" "$GITHUB_MBPS"; do
    if awk -v m="$value" 'BEGIN { exit !(m > 0) }'; then
      known_count=$((known_count + 1))
      if awk -v m="$value" 'BEGIN { exit !(m < 5) }'; then
        slow_count=$((slow_count + 1))
      fi
    fi
  done

  NETWORK_STATUS="UNKNOWN"
  NETWORK_NOTE="Could not collect enough throughput data. Treat provider download speed as unverified."

  if [[ $known_count -eq 3 && $slow_count -eq 3 ]]; then
    NETWORK_STATUS="HOST_EGRESS_SLOW"
    NETWORK_NOTE="All three provider paths are below 5 MB/s; this Pod/host egress or shared uplink is likely the bottleneck. Expect long environment/model downloads."
  elif awk -v p="$PYTORCH_MBPS" -v h="$HF_MBPS" -v g="$GITHUB_MBPS" 'BEGIN { exit !(p > 0 && p < 5 && h >= 10 && g >= 10) }'; then
    NETWORK_STATUS="PYTORCH_PATH_SLOW"
    NETWORK_NOTE="PyTorch CDN is slow while Hugging Face and GitHub are healthy; CUDA/PyTorch installation may be slow even if model downloads are fine."
  elif awk -v p="$PYTORCH_MBPS" -v h="$HF_MBPS" -v g="$GITHUB_MBPS" 'BEGIN { exit !(h > 0 && h < 5 && p >= 10 && g >= 10) }'; then
    NETWORK_STATUS="HUGGINGFACE_PATH_SLOW"
    NETWORK_NOTE="Hugging Face is the slow path; large model downloads may dominate setup time."
  elif awk -v p="$PYTORCH_MBPS" -v h="$HF_MBPS" -v g="$GITHUB_MBPS" 'BEGIN { exit !(g > 0 && g < 5 && p >= 10 && h >= 10) }'; then
    NETWORK_STATUS="GITHUB_PATH_SLOW"
    NETWORK_NOTE="GitHub is the slow path; repository/bootstrap fetches may be delayed while model/CDN traffic is healthier."
  elif [[ $known_count -eq 3 && $slow_count -eq 0 ]]; then
    NETWORK_STATUS="HEALTHY"
    NETWORK_NOTE="No sampled provider path is below 5 MB/s. Throughput can still vary during large downloads."
  elif [[ $known_count -gt 0 ]]; then
    NETWORK_STATUS="MIXED"
    NETWORK_NOTE="At least one sampled provider path is below 5 MB/s. Provider-specific routing or shared-host contention may affect setup time."
  fi
}

printf '%s\n' "$SMI_QUERY"
printf '%s\n' "$CUDA_OUTPUT"
free_kib="$(df -Pk "$RUNTIME_ROOT" | awk 'NR==2 {print $4}')"
printf 'Disk free: %.1f GiB\n' "$(awk "BEGIN { print $free_kib / 1048576 }")"

PYTORCH_MBPS=0 PYTORCH_STATUS=UNKNOWN PYTORCH_RC=0 PYTORCH_HTTP=000
HF_MBPS=0 HF_STATUS=UNKNOWN HF_RC=0 HF_HTTP=000
GITHUB_MBPS=0 GITHUB_STATUS=UNKNOWN GITHUB_RC=0 GITHUB_HTTP=000
NETWORK_STATUS="SKIPPED"
NETWORK_NOTE="Network benchmark disabled."

if [[ "${RUNPOD_DOCTOR_NETWORK:-1}" != 0 ]]; then
  echo
  echo '=== NETWORK DOCTOR (8 MiB samples; max 12s each) ==='
  if command -v curl >/dev/null 2>&1; then
    probe_network PYTORCH 'PyTorch CDN' 'https://download.pytorch.org/whl/cu128/torch-2.7.1%2Bcu128-cp312-cp312-manylinux_2_28_x86_64.whl'
    probe_network HF 'Hugging Face' 'https://huggingface.co/google-bert/bert-base-uncased/resolve/main/pytorch_model.bin'
    probe_network GITHUB 'GitHub' 'https://github.com/Comfy-Org/ComfyUI/archive/refs/tags/v0.38.0.tar.gz'
    network_diagnosis
  else
    NETWORK_STATUS="UNKNOWN"
    NETWORK_NOTE="curl is unavailable, so provider throughput was not measured."
  fi
  echo "[NETWORK STATUS] $NETWORK_STATUS"
  echo "Network note: $NETWORK_NOTE"
  echo 'Slow network does not make the GPU unusable; it is reported separately from POD STATUS.'
else
  echo '[NETWORK STATUS] SKIPPED (RUNPOD_DOCTOR_NETWORK=0)'
fi

if command -v python3 >/dev/null 2>&1; then
  NETWORK_JSON="$NETWORK_JSON" NETWORK_STATUS="$NETWORK_STATUS" NETWORK_NOTE="$NETWORK_NOTE" \
  PYTORCH_MBPS="$PYTORCH_MBPS" PYTORCH_STATUS="$PYTORCH_STATUS" PYTORCH_HTTP="$PYTORCH_HTTP" \
  HF_MBPS="$HF_MBPS" HF_STATUS="$HF_STATUS" HF_HTTP="$HF_HTTP" \
  GITHUB_MBPS="$GITHUB_MBPS" GITHUB_STATUS="$GITHUB_STATUS" GITHUB_HTTP="$GITHUB_HTTP" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

providers = {}
for key, label in (("PYTORCH", "PyTorch CDN"), ("HF", "Hugging Face"), ("GITHUB", "GitHub")):
    providers[key.lower()] = {
        "label": label,
        "mb_per_second": float(os.environ.get(f"{key}_MBPS", "0") or 0),
        "status": os.environ.get(f"{key}_STATUS", "UNKNOWN"),
        "http_code": os.environ.get(f"{key}_HTTP", "000"),
    }
payload = {
    "utc_timestamp": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
    "status": os.environ.get("NETWORK_STATUS", "UNKNOWN"),
    "note": os.environ.get("NETWORK_NOTE", ""),
    "providers": providers,
}
Path(os.environ["NETWORK_JSON"]).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
  echo "Network JSON: $NETWORK_JSON"
fi

printf '[POD STATUS] USABLE\n'
