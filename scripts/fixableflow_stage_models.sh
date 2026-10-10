#!/usr/bin/env bash
# First-run staging for FixableFlow.
# This intentionally follows upstream model URLs and records exact size/SHA256.
# After a successful RunPod validation, promote those observed hashes into registry.yaml.
set -Eeuo pipefail
umask 077

COMFY_ROOT="${COMFY_ROOT:-/workspace/runtime/ComfyUI}"
MODELS_ROOT="$COMFY_ROOT/models"
MANIFEST="${FIXABLEFLOW_MANIFEST:-/workspace/runtime/fixableflow-model-manifest.tsv}"

[[ -d "$COMFY_ROOT" ]] || { echo "[FAILED] ComfyUI not found: $COMFY_ROOT" >&2; exit 2; }
command -v sha256sum >/dev/null || { echo '[FAILED] sha256sum is required.' >&2; exit 2; }

mkdir -p "$MODELS_ROOT" "$(dirname "$MANIFEST")"
printf 'filename\tbytes\tsha256\tsource\n' > "$MANIFEST"

fetch() {
    local dest_rel="$1"
    local url="$2"
    local target="$MODELS_ROOT/$dest_rel"
    local tmp="${target}.part"
    mkdir -p "$(dirname "$target")"

    if [[ ! -s "$target" ]]; then
        echo "[DOWNLOAD] $dest_rel"
        if command -v aria2c >/dev/null 2>&1; then
            aria2c --continue=true --max-tries=5 --retry-wait=5 --connect-timeout=30 \
                --timeout=60 --max-connection-per-server=4 --split=4 \
                --dir="$(dirname "$tmp")" --out="$(basename "$tmp")" "$url"
        else
            curl --fail --location --retry 5 --retry-delay 5 --connect-timeout 30 \
                --continue-at - --output "$tmp" "$url"
        fi
        mv -f "$tmp" "$target"
    else
        echo "[SKIP] $dest_rel already exists"
    fi

    local bytes sha
    bytes="$(stat -c '%s' "$target")"
    sha="$(sha256sum "$target" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\n' "$dest_rel" "$bytes" "$sha" "$url" >> "$MANIFEST"
    echo "[VERIFIED] $dest_rel bytes=$bytes sha256=$sha"
}

# Prepared-lineart workflow: lineart generation LoRA is intentionally omitted.
# Animagine + LineartXL are retained for the lineart -> bucket/flat preparation stage.
fetch 'checkpoints/animagine-xl-3.1.safetensors' \
  'https://huggingface.co/cagliostrolab/animagine-xl-3.1/resolve/main/animagine-xl-3.1.safetensors'
fetch 'loras/sdxl-flat.safetensors' \
  'https://huggingface.co/2vXpSwA7/iroiro-lora/resolve/main/sdxl/sdxl-flat.safetensors'
fetch 'loras/image2flat_V1_1024_dim4-000040.safetensors' \
  'https://huggingface.co/tori29umai/FramePack_LoRA/resolve/main/image2flat_V1_1024_dim4-000040.safetensors'
fetch 'controlnet/Katarag_lineartXL-fp16.safetensors' \
  'https://huggingface.co/kataragi/ControlNet-LineartXL/resolve/main/Katarag_lineartXL-fp16.safetensors'
fetch 'vae/sdxl_vae.safetensors' \
  'https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors'
fetch 'vae/diffusion_pytorch_model.safetensors' \
  'https://huggingface.co/hunyuanvideo-community/HunyuanVideo/resolve/main/vae/diffusion_pytorch_model.safetensors'
fetch 'clip/clip_l.safetensors' \
  'https://huggingface.co/maybleMyers/framepack_h1111/resolve/main/clip_l.safetensors'
fetch 'clip/llava_llama3_fp16.safetensors' \
  'https://huggingface.co/maybleMyers/framepack_h1111/resolve/main/llava_llama3_fp16.safetensors'
fetch 'diffusion_models/FramePackI2V_HY_bf16.safetensors' \
  'https://huggingface.co/maybleMyers/framepack_h1111/resolve/main/FramePackI2V_HY_bf16.safetensors'
fetch 'loras/shade-adder-lora.safetensors' \
  'https://huggingface.co/mattyamonaca/framepack-shade-adder_lora/resolve/main/shade-adder-lora.safetensors'
fetch 'loras/fpack_highlight_lora.safetensors' \
  'https://huggingface.co/mattyamonaca/fixableflow/resolve/main/fpack_highlight_lora.safetensors?download=true'

workflow_src="$COMFY_ROOT/custom_nodes/ComfyUI-fixableflow/workflows"
workflow_dst="$COMFY_ROOT/user/default/workflows"
mkdir -p "$workflow_dst"
for workflow in \
    fixable-workflow-comfyui-lineart-bucket.json \
    fixable-workflow-comfyui-highlight.json; do
    [[ -f "$workflow_src/$workflow" ]] || { echo "[FAILED] Missing upstream workflow: $workflow" >&2; exit 3; }
    cp -f "$workflow_src/$workflow" "$workflow_dst/$workflow"
    echo "[WORKFLOW] $workflow"
done

echo
printf '%s\n' \
  '[FIXABLEFLOW ASSETS READY]' \
  "Manifest: $MANIFEST" \
  'Use the lineart-bucket workflow for prepared lineart, then the highlight workflow as needed.' \
  'Reload the ComfyUI browser; restart ComfyUI only if model dropdowns do not refresh.'
