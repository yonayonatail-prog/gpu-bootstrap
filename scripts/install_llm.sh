#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

runtime="${1:?runtime root is required}"
model="${AGENT_MODEL:-Qwen/Qwen2.5-Coder-7B-Instruct}"
port="${AGENT_PORT:-8000}"
api_key="${AGENT_API_KEY:-change-me}"
venv="$runtime/llm-venv"
logs="$runtime/logs"
service_file="$runtime/llm-service.json"
stamp="$venv/package.stamp"

[[ "$runtime" == /* && "$runtime" != / ]] || { echo '[FAILED] runtime root must be an absolute non-root path' >&2; exit 1; }
[[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]] || { echo '[FAILED] AGENT_PORT must be between 1024 and 65535' >&2; exit 1; }
[[ "$api_key" != change-me && "$api_key" != *$'\n'* ]] || { echo '[FAILED] Set a non-default AGENT_API_KEY' >&2; exit 1; }
mkdir -p "$logs"

if [[ ! -x "$venv/bin/python" ]]; then
	python3 -m venv "$venv"
fi
vllm_package="${AGENT_VLLM_PACKAGE:-vllm}"
if [[ ! -f "$stamp" || "$(cat "$stamp")" != "$vllm_package" ]]; then
	"$venv/bin/python" -m pip install --disable-pip-version-check --upgrade "$vllm_package"
	printf '%s' "$vllm_package" >"$stamp"
fi

if [[ -f "$service_file" ]]; then
	pid=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pid"])' "$service_file" 2>/dev/null || true)
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		echo "[READY] LLM service is already running (PID $pid, port $port)"
		exit 0
	fi
fi

if command -v ss >/dev/null && ss -ltn "sport = :$port" | grep -q LISTEN; then
	echo "[FAILED] Port $port is already in use" >&2
	exit 1
fi

export HF_HOME="${HF_HOME:-$runtime/hf-cache}"
export VLLM_NO_USAGE_STATS=1
nohup "$venv/bin/python" -m vllm.entrypoints.openai.api_server \
	--host 127.0.0.1 \
	--port "$port" \
	--model "$model" \
	--served-model-name agent \
	--api-key "$api_key" \
	${AGENT_VLLM_ARGS:-} \
	</dev/null >>"$logs/llm.log" 2>&1 &
pid=$!
printf '{"pid":%s,"port":%s,"model":"%s"}\n' "$pid" "$port" "${model//\/\\}" >"$service_file"
echo "[STARTED] LLM service PID $pid"
echo "Progress: tail -f '$logs/llm.log'"
echo "SSH tunnel: ssh -N -L 8000:127.0.0.1:$port <runpod-host> -p <runpod-port>"
