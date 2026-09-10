# 画像生成比較ワークフロー

3つの比較軸を、ComfyUIへ読み込めるAPI形式のJSONとして同梱しています。

| 比較 | JSON | 入力 |
| --- | --- | --- |
| NetaYume-Lumina | `comfy/workflows/netayume_lumina_lora.json` | チェックポイント、LoRA、prompt |
| Illustrious/SDXL | `comfy/workflows/illustrious_sdxl_ipadapter_openpose.json` | チェックポイント、LoRA、キャラ/絵柄画像、OpenPose画像、prompt |
| Qwen Image Edit 2511 | `comfy/workflows/qwen_image_edit_2511_multi_reference.json` | キャラ画像、服/絵柄画像、ポーズ/シーン画像、instruction |

## 使い方

1. 対応するprofileでPodを起動する。
2. `ComfyUI/models`へ必要なローカルモデルを置く。
3. ComfyUIのWorkflow画面へJSONをドラッグする。
4. `LoadImage`とモデルLoaderのファイル名を自分のファイル名に合わせる。
5. 画像を生成し、同じseed・解像度・stepsで3方式を比較する。

NetaYume-Luminaは、まずLoRAを外した状態と付けた状態を同じpromptで比較するためのワークフローです。`LoraLoaderModelOnly`のstrengthは0.85を初期値にしています。

Illustrious/SDXLは、キャラ/絵柄参照を`IPAdapterAdvanced`、ポーズ参照を`AIO_Preprocessor(OpenPose)`と`ControlNetApplyAdvanced`へ分けています。IPAdapterのweightは0.65、OpenPoseのstrengthは0.75を初期値にしています。

Qwen Image Edit 2511は、3枚の参照を`TextEncodeQwenImageEditPlus`へまとめ、instructionで「image 1はキャラ、image 2は服・絵柄、image 3はポーズ・シーン」と役割を明示しています。

個人LoRA、Illustriousチェックポイント、IPAdapter、CLIP Vision、OpenPose ControlNetはGitへ含めていません。NetaYume-Lumina v3は`netayume-lumina`プロファイルで自動取得します。その他のファイル名は各JSONのLoaderにある初期値です。
