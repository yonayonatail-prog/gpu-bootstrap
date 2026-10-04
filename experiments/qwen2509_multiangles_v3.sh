#!/usr/bin/env bash
# EXPERIMENTAL wrapper for Runpod images that export global pip constraints.
set -Eeuo pipefail
umask 077

BRANCH="experiment/qwen2509-multiangles"
RAW="https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/${BRANCH}/experiments/qwen2509_multiangles_v2.sh"
TMP="$(mktemp /tmp/qwen2509_multiangles_v3.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

# Runpod slim images can export pip policy variables from their prebuilt env.
# Those variables are inherited by newly-created virtualenvs and can force a
# different torch stack, making even `pip install torch==2.7.1` fail.
set_vars=()
for name in PIP_CONSTRAINT PIP_REQUIREMENT PIP_CONFIG_FILE PIP_EXTRA_INDEX_URL PIP_NO_INDEX PIP_FIND_LINKS; do
  if [[ -n "${!name-}" ]]; then
    set_vars+=("$name")
  fi
done
if ((${#set_vars[@]})); then
  printf '[PIP ENV] clearing inherited controls: %s\n' "${set_vars[*]}"
else
  echo '[PIP ENV] no inherited constraint variables detected'
fi
unset PIP_CONSTRAINT PIP_REQUIREMENT PIP_CONFIG_FILE PIP_EXTRA_INDEX_URL PIP_NO_INDEX PIP_FIND_LINKS
export PIP_INDEX_URL="https://pypi.org/simple"

curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 "$RAW" -o "$TMP"
chmod 700 "$TMP"
exec bash "$TMP"
