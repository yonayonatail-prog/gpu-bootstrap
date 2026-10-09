# MiniMax H3 Turbo on RunPod

`h3-turbo` は MiniMax H3 の Image-to-Video を、ComfyUI v0.38.0 と 8-step Turbo LoRA で使う動画生成プロファイルです。初版は RunPod の RTX 5090 32GB / PyTorch 2.8.0 + cu128 で実生成を確認しています。

## Pod の目安

- 推奨GPU: RTX 5090 32GB
- RTX 4090 24GB: 候補。初版昇格時点では実Pod生成未確認
- Container disk: 100GB以上。120GBを推奨
- Volume: 不要
- HTTP port: 8188
- ComfyUI同梱テンプレートではなく、素のPyTorch / CUDA系テンプレートを推奨

最初にGPUを確認します。

```bash
curl -fsSL https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/runpod-doctor.sh -o runpod-doctor.sh
bash runpod-doctor.sh
```

`[POD STATUS] USABLE` の場合だけ続行します。

## 起動

```bash
curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 \
  https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
bash bootstrap.sh h3-turbo
```

進捗は次で確認します。

```bash
tail -f /workspace/runtime/logs/bootstrap.log
```

`[READY]` の後、RunPod の Connect → HTTP Service :8188 から ComfyUI を開きます。RunPod proxy 用の CORS Origin は `gpu-bootstrap` が自動指定します。

## モデル構成

自動取得するファイルは次の5個です。

- `minimax_h3_fl2va_pruned_fp8_scaled.safetensors`
- `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`
- `minimax_h3_video_vae_fp16.safetensors`
- `minimax_h3_audio_vae_fp32.safetensors`
- `minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors`

合計は約41.4 GiBです。cu130向け最適化を前提とする `int8_convrot` ではなく、実Podで生成確認した `fp8_scaled` + FP16 Video VAE を標準にしています。

## Workflow

構築時に Comfy-Org の公式 MiniMax H3 I2V workflow を固定commitから取得し、実Podで確認した FP8 / FP16 / 8-step Turbo 設定へ自動変換して、次へ配置します。

```text
/workspace/runtime/ComfyUI/user/default/workflows/h3_turbo_i2v.json
```

ComfyUI の Workflow 一覧から `h3_turbo_i2v.json` を開き、`LoadImage` を好きな入力画像へ差し替えれば使えます。標準設定は次のとおりです。

```text
unet_name: minimax_h3_fl2va_pruned_fp8_scaled.safetensors
clip_name: qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
vae_name: minimax_h3_video_vae_fp16.safetensors
audio_vae: minimax_h3_audio_vae_fp32.safetensors
turbo_mode: true
lora_name: minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors
turbo_model_strength: 1.0
turbo_steps: 8
duration: 5 seconds
resolution: 0.4 MPから開始
```

人物の小さな演技を試す場合の開始プロンプト例:

```text
The character always faces directly toward the camera.
Keep the original composition and pose similar to the input image.
Subtle blinking, small mouth movements, and slight head motion.
Minimal hand movement. Minimal body movement.
No camera movement. No profile view.
```

元画像と違うアスペクト比へ無理に寄せるより、最初は元画像に近い比率を選ぶ方が構図を維持しやすいです。

## 実機確認記録

初版昇格時の確認:

```text
GPU: RTX 5090 32GB
Driver: 580.173.02
CUDA Driver API: PASS (cuInit=0)
PyTorch: 2.8.0+cu128
ComfyUI: 0.38.0
DynamicVRAM: enabled
Turbo: 8-step
I2V MP4 generation: PASS (user-confirmed)
```

ComfyUI は cu130 以上を使うと一部の最適化 CUDA operations を利用できますが、初版は cu128 + eager fallback で実生成できた構成を正本にしています。

## Hugging Face 429

Community Cloud の共有IPでは公開モデルでも `429 Too Many Requests` になる場合があります。その場合は読み取りトークンでログインし、エラーに出た `Retry after` の時間以上待ってから同じbootstrapを再実行します。

```bash
/workspace/runtime/controller-venv/bin/hf auth login
/workspace/runtime/controller-venv/bin/hf auth whoami
bash bootstrap.sh h3-turbo
```

トークン自体はGitへ保存しないでください。途中まで正常取得したファイルは再実行時に再利用されます。

## トラブル時

- RunPod proxyでHTTP 403: 最新mainを使っているか確認。`RUNPOD_POD_ID` からproxy Originを自動設定します。
- `torch.OutOfMemoryError`: まず解像度を0.4MPへ戻し、durationを短くして再試行します。連続生成後だけ発生する場合はComfyUI再起動も候補です。
- `dependencies`: `/workspace/runtime/logs/dependencies.log` を確認します。
- `model_download`: `/workspace/runtime/logs/<model-id>.log` とHugging Face認証・レート制限を確認します。
- READYだがUIを開けない: Pod内で `curl -I http://127.0.0.1:8188/` と `curl http://127.0.0.1:8188/system_stats` を確認し、両方正常ならRunPod proxy側を切り分けます。

モデルの利用条件は配布元のライセンスに従ってください。`gpu-bootstrap` 本体のMIT Licenseとは別です。
