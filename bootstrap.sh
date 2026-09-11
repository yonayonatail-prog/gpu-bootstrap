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
mkdir -p "$RUNTIME_ROOT/logs"
if [[ "${GPU_BOOTSTRAP_WORKER:-0}" != 1 ]]; then
    # Use a unique copy so a second invocation cannot overwrite a running shell script.
    launcher=$(mktemp "$RUNTIME_ROOT/launcher.XXXXXX.sh")
    cp -- "${BASH_SOURCE[0]}" "$launcher"
    GPU_BOOTSTRAP_WORKER=1 nohup bash "$launcher" "$profile" </dev/null >>"$RUNTIME_ROOT/logs/bootstrap.log" 2>&1 &
    echo "[STARTED] Profile: $profile; PID: $!"
    echo "Progress: tail -f '$RUNTIME_ROOT/logs/bootstrap.log'"
    echo 'You may close this terminal. Look for [READY] or [FAILED] in the log.'
    exit 0
fi
stage=bootstrap
askpass=''
cleanup() { [[ -z "$askpass" ]] || rm -f -- "$askpass"; }
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
"${privilege[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
"${privilege[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-venv python3-pip git curl tree ca-certificates aria2 ffmpeg build-essential libgl1 libglib2.0-0
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
"$controller/bin/python" -u "$repo/orchestrator.py" "$profile" --runtime-root "$RUNTIME_ROOT"
