#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

RUNTIME_ROOT="${RUNTIME_ROOT:-/workspace/runtime}"
COMFY_ROOT="${COMFY_ROOT:-$RUNTIME_ROOT/ComfyUI}"
DEST_DIR="$COMFY_ROOT/models/upscale_models"
MODEL_NAME="RealESRGAN_x4plus_anime_6B.pth"
DEST="$DEST_DIR/$MODEL_NAME"
PART="$DEST.part"
URL="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth"
SHA256="f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da"

command -v curl >/dev/null 2>&1 || { echo '[FAILED] curl is required' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo '[FAILED] sha256sum is required' >&2; exit 1; }
[[ -d "$COMFY_ROOT" ]] || { echo "[FAILED] ComfyUI not found: $COMFY_ROOT" >&2; exit 1; }

mkdir -p "$DEST_DIR"

if [[ -f "$DEST" ]]; then
    current="$(sha256sum "$DEST" | awk '{print $1}')"
    if [[ "$current" == "$SHA256" ]]; then
        echo "[READY] Upscaler already installed: $DEST"
        exit 0
    fi
    echo "[WARN] Existing model checksum mismatch; replacing it."
    mv -f "$DEST" "$DEST.bad.$(date -u +%Y%m%dT%H%M%SZ)"
fi

rm -f "$PART"
echo "[DOWNLOAD] $MODEL_NAME"
curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 600 \
    "$URL" -o "$PART"

actual="$(sha256sum "$PART" | awk '{print $1}')"
if [[ "$actual" != "$SHA256" ]]; then
    rm -f "$PART"
    echo "[FAILED] SHA256 mismatch: expected $SHA256, got $actual" >&2
    exit 2
fi

mv -f "$PART" "$DEST"
echo "[READY] Installed: $DEST"
echo "Model: $MODEL_NAME"
echo "Use ComfyUI nodes: Load Upscale Model -> Image Upscale with Model"
echo "If the model is not listed immediately, reload the ComfyUI page."
