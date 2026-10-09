# 画像・動画生成ワークフロー

比較用の画像生成ワークフローに加え、`h3-turbo` では MiniMax H3 I2V の実機確認済みTurboワークフローを構築時に用意します。

| 用途 | JSON / Workflow | 入力 |
| --- | --- | --- |
| NetaYume-Lumina | `comfy/workflows/netayume_lumina_lora.json` | チェックポイント、LoRA、prompt |
| Illustrious/SDXL | `comfy/workflows/illustrious_sdxl_ipadapter_openpose.json` | チェックポイント、LoRA、キャラ/絵柄画像、OpenPose画像、prompt |
| Qwen Image Edit 2511 | `comfy/workflows/qwen_image_edit_2511_multi_reference.json` | キャラ画像、服/絵柄画像、ポーズ/シーン画像、instruction |
| MiniMax H3 Turbo I2V | runtime `user/default/workflows/h3_turbo_i2v.json` | first frame画像、prompt |

## 使い方

1. 対応するprofileでPodを起動する。
2. `ComfyUI/models`へ必要なローカルモデルを置く。profileが自動取得するモデルは追加配置不要。
3. ComfyUIのWorkflow画面から対応JSONを開く。
4. `LoadImage`とモデルLoaderのファイル名を自分の入力に合わせる。
5. 画像または動画を生成する。

NetaYume-Luminaは、まずLoRAを外した状態と付けた状態を同じpromptで比較するためのワークフローです。`LoraLoaderModelOnly`のstrengthは0.85を初期値にしています。

Illustrious/SDXLは、キャラ/絵柄参照を`IPAdapterAdvanced`、ポーズ参照を`AIO_Preprocessor(OpenPose)`と`ControlNetApplyAdvanced`へ分けています。IPAdapterのweightは0.65、OpenPoseのstrengthは0.75を初期値にしています。

Qwen Image Edit 2511は、3枚の参照を`TextEncodeQwenImageEditPlus`へまとめ、instructionで「image 1はキャラ、image 2は服・絵柄、image 3はポーズ・シーン」と役割を明示しています。

MiniMax H3 Turbo は Comfy-Org の公式 I2V template を固定commitから取得し、`fp8_scaled` base、FP16 Video VAE、LightX2V 8-step Turbo LoRA、Turbo strength 1.0へ自動調整して `h3_turbo_i2v.json` として配置します。詳細は [H3_TURBO_RUNPOD.md](H3_TURBO_RUNPOD.md) を参照してください。

個人LoRA、Illustriousチェックポイント、IPAdapter、CLIP Vision、OpenPose ControlNetはGitへ含めていません。NetaYume-Lumina v3は`netayume-lumina`プロファイルで自動取得します。その他のファイル名は各JSONのLoaderにある初期値です。
