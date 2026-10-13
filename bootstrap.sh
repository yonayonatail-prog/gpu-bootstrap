#!/usr/bin/env bash
# Download this file first, then run: bash bootstrap.sh base
set -Eeuo pipefail
umask 077
export RUNTIME_ROOT="${RUNTIME_ROOT:-/workspace/runtime}"
export GPU_BOOTSTRAP_REPO="${GPU_BOOTSTRAP_REPO:-yonayonatail-prog/gpu-bootstrap}"
export GPU_BOOTSTRAP_REF="${GPU_BOOTSTRAP_REF:-main}"
profile="${1:-base}"
[[ "$profile" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo '[FAILED] Invalid profile name'; exit 1; }
[[ "$RUNTIME_ROOT" == /* && "$RUNTIME_ROOT" != / ]] || { echo '[FAILED] RUNTIME_ROOT must be an absolute non-root path'; exit 1; }
[[ "$GPU_BOOTSTRAP_REPO" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || exit 1

cuda_driver_precheck() {
    local probe_output probe_rc
    if ! command -v python3 >/dev/null 2>&1; then
        printf '%s\n' \
            '[GPU PRECHECK FAILED]' \
            'Reason: python3 is required for the CUDA driver probe.' \
            'Action: use a supported Ubuntu/Python GPU template.' \
            'No models were downloaded.' >&2
        return 23
    fi

    set +e
    if command -v timeout >/dev/null 2>&1; then
        probe_output=$(timeout --foreground 15 python3 - <<'PY' 2>&1
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
PY
)
        probe_rc=$?
    else
        probe_output=$(python3 - <<'PY' 2>&1
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
PY
)
        probe_rc=$?
    fi
    set -e

    case "$probe_rc" in
        0)
            printf '[CUDA DRIVER PRECHECK PASS]\n%s\n' "$probe_output"
            ;;
        20)
            printf '%s\n' \
                '[GPU PRECHECK FAILED]' \
                "Reason: libcuda.so.1 could not be loaded: ${probe_output//$'\n'/ }" \
                'Action: terminate this Pod and rent another GPU Pod.' \
                'No models were downloaded.' >&2
            return 24
            ;;
        21)
            printf '%s\n' \
                '[GPU PRECHECK FAILED]' \
                "Reason: CUDA driver initialization failed although nvidia-smi works: ${probe_output//$'\n'/ }" \
                'Action: terminate this Pod and rent another GPU Pod.' \
                'No models were downloaded.' >&2
            return 25
            ;;
        22)
            printf '%s\n' \
                '[GPU PRECHECK FAILED]' \
                "Reason: CUDA initialized but reports no compute devices: ${probe_output//$'\n'/ }" \
                'Action: terminate this Pod and rent another GPU Pod.' \
                'No models were downloaded.' >&2
            return 26
            ;;
        124)
            printf '%s\n' \
                '[GPU PRECHECK FAILED]' \
                'Reason: CUDA driver initialization timed out.' \
                'Action: terminate this Pod and rent another GPU Pod.' \
                'No models were downloaded.' >&2
            return 27
            ;;
        *)
            printf '%s\n' \
                '[GPU PRECHECK FAILED]' \
                "Reason: CUDA driver probe failed unexpectedly (exit $probe_rc): ${probe_output//$'\n'/ }" \
                'Action: terminate this Pod and rent another GPU Pod.' \
                'No models were downloaded.' >&2
            return 28
            ;;
    esac
}

gpu_precheck() {
    local output first gpu_name gpu_mem_mib driver
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        printf '%s\n' \
            '[GPU PRECHECK FAILED]' \
            'Reason: nvidia-smi is not available in this Pod.' \
            'Action: terminate this Pod and rent another GPU Pod.' \
            'No models were downloaded.' >&2
        return 20
    fi
    if command -v timeout >/dev/null 2>&1; then
        if ! output=$(timeout --foreground 15 nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>&1); then
            printf '%s\n' \
                '[GPU PRECHECK FAILED]' \
                "Reason: nvidia-smi could not query the GPU: ${output//$'\n'/ }" \
                'Action: terminate this Pod and rent another GPU Pod.' \
                'No models were downloaded.' >&2
            return 21
        fi
    elif ! output=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>&1); then
        printf '%s\n' \
            '[GPU PRECHECK FAILED]' \
            "Reason: nvidia-smi could not query the GPU: ${output//$'\n'/ }" \
            'Action: terminate this Pod and rent another GPU Pod.' \
            'No models were downloaded.' >&2
        return 21
    fi
    first=$(printf '%s\n' "$output" | sed -n '1p')
    IFS=',' read -r gpu_name gpu_mem_mib driver <<<"$first"
    gpu_name=$(printf '%s' "${gpu_name:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    gpu_mem_mib=$(printf '%s' "${gpu_mem_mib:-}" | sed 's/[[:space:]]//g')
    driver=$(printf '%s' "${driver:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "$gpu_name" || ! "$gpu_mem_mib" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk "BEGIN { exit !($gpu_mem_mib > 0) }"; then
        printf '%s\n' \
            '[GPU PRECHECK FAILED]' \
            'Reason: GPU metadata is invalid or reports zero VRAM.' \
            'Action: terminate this Pod and rent another GPU Pod.' \
            'No models were downloaded.' >&2
        return 22
    fi
    printf '[NVIDIA-SMI PRECHECK PASS]\nGPU: %s\nVRAM: %.1f GiB\nDriver: %s\n' \
        "$gpu_name" "$(awk "BEGIN { print $gpu_mem_mib / 1024 }")" "$driver"
    cuda_driver_precheck
    printf '[GPU PRECHECK PASS]\nGPU compute initialization: PASS\n'
}

sanitize_pip_environment() {
    local cleared=()
    local name
    for name in PIP_CONSTRAINT PIP_REQUIREMENT PIP_CONFIG_FILE PIP_EXTRA_INDEX_URL PIP_NO_INDEX PIP_FIND_LINKS; do
        if [[ -n "${!name-}" ]]; then
            cleared+=("$name")
        fi
        unset "$name" || true
    done
    if ((${#cleared[@]})); then
        printf '[PIP ENV] cleared inherited controls: %s\n' "${cleared[*]}"
    fi
}

start_ready_alert() {
    local log_file=$1 log_offset=$2 alert_profile=$3 alert_tty=$4
    [[ "${GPU_BOOTSTRAP_READY_BELL:-1}" != 0 ]] || return 0
    [[ -n "$alert_tty" && -w "$alert_tty" ]] || return 0
    (
        tail -c "+$((log_offset + 1))" -F "$log_file" 2>/dev/null |
        while IFS= read -r line; do
            case "$line" in
                '[READY]')
                    printf '\a\n[READY ALERT] %s is ready.\n' "$alert_profile" >"$alert_tty" 2>/dev/null || true
                    break
                    ;;
                '[FAILED]'|'[BUSY]'*)
                    break
                    ;;
            esac
        done
    ) >/dev/null 2>&1 &
}

start_status_heartbeat() {
    local target_pid=$1 status_file=$2
    local interval="${GPU_BOOTSTRAP_HEARTBEAT_SECONDS:-30}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=30
    (( interval > 0 )) || return 0
    (( interval >= 5 )) || interval=5
    (
        local started=$SECONDS current_stage detail
        local iface='' rx_prev='' rx_now='' tick_prev=$SECONDS tick_now delta_seconds net_rate='n/a'
        local log_file='' log_age='' pip_state='' current_activity='' extra=''
        if command -v ip >/dev/null 2>&1; then
            iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)
        fi
        if [[ -n "$iface" && -r "/sys/class/net/$iface/statistics/rx_bytes" ]]; then
            rx_prev=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || true)
        fi
        while sleep "$interval"; do
            kill -0 "$target_pid" 2>/dev/null || break
            current_stage=orchestrator
            if [[ -f "$status_file" ]]; then
                current_stage=$(sed -n 's/^[[:space:]]*"stage":[[:space:]]*"\([^"]*\)".*/\1/p' "$status_file" | head -n 1)
                [[ -n "$current_stage" ]] || current_stage=orchestrator
            fi
            case "$current_stage" in
                environment) detail="$RUNTIME_ROOT/logs/dependencies.log" ;;
                service_start|service_health) detail="$RUNTIME_ROOT/logs/comfyui.log" ;;
                model_download) detail="$RUNTIME_ROOT/logs/downloads.jsonl + model logs" ;;
                *) detail="$RUNTIME_ROOT/status.json" ;;
            esac

            tick_now=$SECONDS
            delta_seconds=$((tick_now - tick_prev))
            net_rate='n/a'
            if [[ -n "$iface" && -r "/sys/class/net/$iface/statistics/rx_bytes" && -n "$rx_prev" && "$delta_seconds" -gt 0 ]]; then
                rx_now=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || true)
                if [[ "$rx_now" =~ ^[0-9]+$ && "$rx_prev" =~ ^[0-9]+$ && "$rx_now" -ge "$rx_prev" ]]; then
                    net_rate=$(awk -v a="$rx_prev" -v b="$rx_now" -v s="$delta_seconds" 'BEGIN { printf "%.2f", (b-a)/s/1024/1024 }')
                    rx_prev=$rx_now
                fi
            fi
            tick_prev=$tick_now

            extra=''
            if [[ "$net_rate" != n/a ]]; then
                extra="; net RX ${net_rate} MB/s"
            fi
            if [[ "$current_stage" == environment ]]; then
                log_file="$RUNTIME_ROOT/logs/dependencies.log"
                pip_state='pip inactive'
                if pgrep -af '[p]ip install' >/dev/null 2>&1; then
                    pip_state='pip active'
                fi
                log_age='unknown'
                if [[ -f "$log_file" ]]; then
                    log_mtime=$(stat -c %Y "$log_file" 2>/dev/null || true)
                    now_epoch=$(date +%s)
                    if [[ "$log_mtime" =~ ^[0-9]+$ ]]; then
                        log_age="$((now_epoch - log_mtime))s"
                    fi
                    current_activity=$(grep -E '^(Collecting|  Downloading|Installing collected packages|Successfully installed|CUDA READY:)' "$log_file" 2>/dev/null | tail -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]][[:space:]]*/ /g' | cut -c1-160 || true)
                else
                    current_activity=''
                fi
                extra+="; $pip_state; detail log age ${log_age}"
                if [[ -n "$current_activity" ]]; then
                    extra+="; current: $current_activity"
                fi
            fi
            printf '[WORKING] %s: %ss elapsed; process alive%s; details: %s\n' \
                "$current_stage" "$((SECONDS - started))" "$extra" "$detail"
        done
    ) &
    heartbeat_pid=$!
}

# Run the cheapest failure check in the foreground, before APT, pip, Git, or model downloads.
if [[ "$profile" == doctor ]]; then
    gpu_precheck
    mkdir -p "$RUNTIME_ROOT"
    free_kib=$(df -Pk "$RUNTIME_ROOT" | awk 'NR==2 {print $4}')
    printf 'Disk free: %.1f GiB\n[POD STATUS] USABLE\n' "$(awk "BEGIN { print $free_kib / 1048576 }")"
    exit 0
fi

if [[ "${GPU_BOOTSTRAP_WORKER:-0}" != 1 ]]; then
    gpu_precheck
    sanitize_pip_environment
    mkdir -p "$RUNTIME_ROOT/logs"
    log_file="$RUNTIME_ROOT/logs/bootstrap.log"
    touch "$log_file"
    log_offset=$(wc -c <"$log_file")
    alert_tty=''
    if [[ -t 1 ]]; then
        alert_tty=$(tty 2>/dev/null || true)
    fi
    # Use a unique copy so a second invocation cannot overwrite a running shell script.
    launcher=$(mktemp "$RUNTIME_ROOT/launcher.XXXXXX.sh")
    cp -- "${BASH_SOURCE[0]}" "$launcher"
    GPU_BOOTSTRAP_WORKER=1 GPU_BOOTSTRAP_PRECHECKED=1 nohup bash "$launcher" "$profile" </dev/null >>"$log_file" 2>&1 &
    worker_pid=$!
    start_ready_alert "$log_file" "$log_offset" "$profile" "$alert_tty"
    echo "[STARTED] Profile: $profile; PID: $worker_pid"
    echo "Progress: tail -f '$log_file'"
    if [[ "${GPU_BOOTSTRAP_READY_BELL:-1}" != 0 && -n "$alert_tty" ]]; then
        echo 'Ready alert: terminal bell enabled (set GPU_BOOTSTRAP_READY_BELL=0 to disable).'
    fi
    echo 'You may close this terminal. Look for [READY] or [FAILED] in the log.'
    exit 0
fi

mkdir -p "$RUNTIME_ROOT/logs"
if [[ "${GPU_BOOTSTRAP_PRECHECKED:-0}" != 1 ]]; then
    gpu_precheck
fi
sanitize_pip_environment

stage=bootstrap
askpass=''
heartbeat_pid=''
cleanup() {
    [[ -z "$askpass" ]] || rm -f -- "$askpass"
    if [[ -n "$heartbeat_pid" ]]; then
        kill "$heartbeat_pid" 2>/dev/null || true
        wait "$heartbeat_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'code=$?; printf "\n[FAILED]\nStage: %s\nExit: %s\nAction: Check this log and rerun the same command.\n" "$stage" "$code"; exit "$code"' ERR
command -v flock >/dev/null || { echo '[FAILED] Ubuntu util-linux (flock) is required'; exit 1; }
exec 9>"$RUNTIME_ROOT/bootstrap.lock"
flock -n 9 || { echo '[BUSY] A bootstrap is already running for this RUNTIME_ROOT'; exit 0; }
echo "===== $(date -u +%FT%TZ) PROFILE: $profile ====="
stage=system_dependencies
if [[ $(id -u) == 0 ]]; then
    privilege=()
else
    command -v sudo >/dev/null && sudo -n true
    privilege=(sudo -n)
fi
command -v apt-get >/dev/null || { echo '[FAILED] Ubuntu/Debian with apt-get is required'; exit 1; }
echo '[STAGE] system_dependencies: apt-get update (timeout 600s; per-connection timeout 30s; retries 3)'
"${privilege[@]}" env DEBIAN_FRONTEND=noninteractive timeout --foreground 600 apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    update
echo '[DONE] system_dependencies: apt-get update'
echo '[STAGE] system_dependencies: apt-get install (timeout 900s)'
"${privilege[@]}" env DEBIAN_FRONTEND=noninteractive timeout --foreground 900 apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    install -y -qq python3 python3-venv python3-pip git curl tree ca-certificates aria2 ffmpeg build-essential libgl1 libglib2.0-0
echo '[DONE] system_dependencies: apt packages installed'
python3 -c 'import sys; assert (3,10) <= sys.version_info < (3,14), "Use Python 3.10 through 3.13 (recommended: Ubuntu 22.04/24.04)"'
stage=repository
askpass=$(mktemp "$RUNTIME_ROOT/askpass.XXXXXX")
cat >"$askpass" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
    *Username*) printf '%s\n' x-access-token ;;
    *Password*) printf '%s\n' "${GH_TOKEN:-}" ;;
esac
ASKPASS
chmod 700 "$askpass"
export GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0
repo="$RUNTIME_ROOT/repository"
if [[ ! -d "$repo/.git" ]]; then
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" remote add origin "https://github.com/$GPU_BOOTSTRAP_REPO.git"
fi
[[ $(git -C "$repo" remote get-url origin) == "https://github.com/$GPU_BOOTSTRAP_REPO.git" ]] || { echo '[FAILED] Repository origin differs'; exit 1; }
[[ -z $(git -C "$repo" status --porcelain) ]] || { echo '[FAILED] Runtime repository has local edits. Commit/save them before retrying.'; exit 1; }
git -c credential.helper= -C "$repo" fetch --depth 1 origin "$GPU_BOOTSTRAP_REF"
git -C "$repo" checkout --detach -q FETCH_HEAD
cleanup
askpass=''
unset GH_TOKEN GITHUB_TOKEN GIT_ASKPASS
stage=controller_dependencies
controller="$RUNTIME_ROOT/controller-venv"
[[ -x "$controller/bin/python" ]] || python3 -m venv "$controller"
signature=$(sha256sum "$repo/requirements.txt" | cut -d' ' -f1)
if [[ ! -f "$controller/requirements.stamp" || $(cat "$controller/requirements.stamp") != "$signature" ]]; then
    "$controller/bin/python" -m pip install --disable-pip-version-check -r "$repo/requirements.txt"
    printf '%s' "$signature" >"$controller/requirements.stamp"
fi
stage=orchestrator
if [[ "$profile" == agent ]]; then
    exec bash "$repo/scripts/install_llm.sh" "$RUNTIME_ROOT"
fi
"$controller/bin/python" -u "$repo/orchestrator.py" "$profile" --runtime-root "$RUNTIME_ROOT" &
orchestrator_pid=$!
start_status_heartbeat "$orchestrator_pid" "$RUNTIME_ROOT/status.json"
wait "$orchestrator_pid"
if [[ -n "$heartbeat_pid" ]]; then
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
    heartbeat_pid=''
fi
