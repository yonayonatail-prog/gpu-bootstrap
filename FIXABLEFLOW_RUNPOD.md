# FixableFlow on RunPod

Initial integration for validating a reproducible FixableFlow setup on a disposable RunPod Pod.

The `fixableflow` profile currently pins ComfyUI and all required Custom Node repositories. The large model set is staged separately on the **first validation run** so the exact downloaded byte sizes and SHA-256 values can be recorded before they are promoted into `registry.yaml`.

## 1. Validate the Pod

```bash
curl -fsSL https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/runpod-doctor.sh -o runpod-doctor.sh
bash runpod-doctor.sh
```

Continue only when `[POD STATUS] USABLE` is shown.

## 2. Bootstrap the pinned node environment

Use a plain CUDA / PyTorch RunPod template, expose port 8188, and give the container about **100 GB or more** of storage. Upstream recommends **32 GB VRAM**, but RTX 4090 / 24 GB is worth validating with the FramePack memory-saving settings before moving to a larger GPU.

```bash
curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 \
  https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/bootstrap.sh -o bootstrap.sh
bash bootstrap.sh fixableflow
```

Wait for `[READY]` in:

```bash
tail -f /workspace/runtime/logs/bootstrap.log
```

## 3. Stage the first-run model set

This first-run helper follows the current upstream FixableFlow model URLs, resumes partial downloads, copies the prepared-lineart workflows, and writes exact size/SHA-256 observations to a manifest.

```bash
curl --fail --silent --show-error --location --retry 3 \
  https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/scripts/fixableflow_stage_models.sh \
  -o fixableflow_stage_models.sh
bash fixableflow_stage_models.sh
```

Manifest:

```text
/workspace/runtime/fixableflow-model-manifest.tsv
```

Keep that file after the first successful generation. Its values are the evidence needed to replace the temporary `resolve/main` staging URLs with normal pinned `registry.yaml` entries.

## Prepared-lineart workflow

This profile assumes lineart is prepared outside FixableFlow. Therefore the lineart-generation LoRA is deliberately not downloaded.

The staging helper copies these upstream workflows into ComfyUI:

```text
fixable-workflow-comfyui-lineart-bucket.json
fixable-workflow-comfyui-highlight.json
```

Expected production path:

```text
prepared lineart
  -> bucket / flat
  -> 1 shade
  -> highlight
  -> layered PSD
```

The first validation target is not image quality. Confirm these observable facts first:

```text
1. No missing Custom Nodes
2. Both workflows open without red nodes
3. Prepared lineart reaches flat generation
4. Shade generation completes
5. Highlight generation completes
6. Layered PSD downloads and opens correctly
7. Record peak VRAM and per-stage elapsed time
8. Preserve fixableflow-model-manifest.tsv
```

After that result is stable, the model manifest should be moved into `registry.yaml` so `bash bootstrap.sh fixableflow` becomes a true one-command restore with no mutable model URLs.
