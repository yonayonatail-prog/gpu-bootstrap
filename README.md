# gpu-bootstrap

Disposable GPU Environment Bootstrap / Orchestrator v0.1。Runpodの新品Podに1行貼り付けると、モデル取得、ComfyUI導入、検証、サービス起動までバックグラウンドで進めます。

Gitには設定・コード・ワークフローを保存します。モデルはPodごとに取得し、Network Volumeには依存しません。Podの作成・課金・削除は自動化しません。

自分用のモデル、ワークフロー、Runpod設定に合わせて、気軽にフォークして育ててください。公開版はMIT Licenseで提供しています。

## 最初の1回だけ設定するもの

1. Ubuntu 22.04 / 24.04、Python 3.10–3.13、NVIDIA GPU・動作するドライバ、rootまたはパスワード不要のsudoを使えるテンプレートを用意します。推奨検証対象はRTX 4090です。CUDA 12.8用PyTorchをインストールするので、対応する十分新しいNVIDIAドライバを使ってください。ドライバ自体はこの仕組みでは導入しません。
2. HTTPポート **8188** を公開します。ComfyUIは `0.0.0.0:8188` で待ち受けます。ComfyUI自体にはログイン認証を追加していないため、アクセスURLを公開せず、必要ならSSHトンネル等でアクセスを制限してください。
3. `/workspace` の作業ディスクは **60 GB以上** を初期目安にします。標準videoはモデル約9.2 GiBに加え、Python/CUDA依存・一時ファイル・生成出力分が必要です。起動時に必要空き容量を計算します。既定では導入予算20 GiB、残す空き容量5 GiBを確保します。

標準のvideo/imageモデルは公開配布です。通常 `HF_TOKEN` は不要です。後からgatedモデルを追加する場合は、Hugging Face側で利用条件に同意してからRunpod Secretに読み取りトークンを追加します。

参考: [Runpod Secrets](https://docs.runpod.io/pods/templates/secrets)、[HTTPポート](https://docs.runpod.io/pods/configuration/expose-ports)、[GitHubトークン作成](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)

## 毎回貼り付ける手順

Runpodの **Bashターミナル** で実行します。公開リポジトリなのでGitHubトークンは不要です。`bootstrap.sh` は自分自身を一時ファイルへコピーしてバックグラウンド実行するため、標準入力から `bash -s` へ直接渡さず、いったんファイルへ保存してから実行してください。

```bash
curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/bootstrap.sh -o bootstrap.sh
bash bootstrap.sh base
```

既定の `base` はモデルも Custom Node も取得しない最小の ComfyUI 構成です。SeeThrough を使う場合は最後を `seethrough` に、Wan 動画生成を使う場合は `video` に、画像生成は `image` に変更します。今回追加した比較用プロファイルは `netayume-lumina`、`illustrious-sdxl`、`qwen-image-edit-2511` です。TRELLIS2 の画像→3D環境は `trellis2` に変更します。SeeThrough の操作は [SEE_THROUGH_RUNPOD.md](SEE_THROUGH_RUNPOD.md)、TRELLIS2 固有の Pod 条件と操作は [TRELLIS2_RUNPOD.md](TRELLIS2_RUNPOD.md) を参照してください。フォークした場合は、URLの所有者・リポジトリ名をフォーク先へ差し替えてください。取得元を確認したい場合は、保存した `bootstrap.sh` の内容を確認してから実行してください。

RunpodをClineのLLMサーバーとして使う場合は、Runpod Secretまたは環境変数にAPIキーを設定してから `agent` を指定します。LLM APIはPod内の `127.0.0.1:8000` だけで待ち受けるため、RunpodのHTTPポートを追加公開する必要はありません。

```bash
export AGENT_API_KEY='replace-with-a-long-random-key'
export AGENT_MODEL='unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M'
export AGENT_TOKENIZER='Qwen/Qwen3.8-27B'
curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/bootstrap.sh -o bootstrap.sh && bash bootstrap.sh agent
```

既定は `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M` の Q4 GGUF 量子化です。vLLM の GGUF プラグインと、公式ベースモデルの tokenizer を自動導入・指定します。Q4 は BF16 より大幅に必要 VRAM を抑えますが、コンテキスト長と KV キャッシュにも VRAM が必要です。VRAM が不足する場合は `AGENT_VLLM_ARGS` に `--max-model-len` や `--gpu-memory-utilization` を指定して調整してください。

起動後、手元PCでRunpodのSSH接続情報を使ってトンネルを張ります。`<runpod-host>` と `<runpod-port>` はRunpodの **Connect → SSH** に表示される値です。

```bash
ssh -N -L 8000:127.0.0.1:8000 <runpod-host> -p <runpod-port>
```

ClineではプロバイダーをOpenAI互換、Base URLを `http://127.0.0.1:8000/v1`、モデル名を `agent`、APIキーをRunpodに設定した `AGENT_API_KEY` とします。音声入力はWindowsの音声入力（`Win+H`）をClineの入力欄で利用できます。

Runpod の Pod 作成、API キー、SSH トンネル、VS Code / Cline の設定、接続確認までを省略せずに進める場合は [QWEN38_CLINE_RUNPOD.md](QWEN38_CLINE_RUNPOD.md) を参照してください。

`[STARTED]` はバックグラウンド処理の受付です。構築完了を意味しません。以後ターミナルを閉じても構築は続きます。

```bash
tail -f /workspace/runtime/logs/bootstrap.log
```

起動直後は `[STAGE] system_dependencies` としてAPTの更新・パッケージ導入が実行されます。APT更新は180秒、パッケージ導入は900秒でタイムアウトし、完了すると `[DONE]` が表示されます。ここで長時間止まる場合は、モデル取得やComfyUI起動までまだ進んでいません。

`[READY]` が出たらRunpodの **Connect → HTTP Service :8188** から開きます。`0.0.0.0` は待ち受けアドレスであり、手元PCで開くURLではありません。処理時間は回線・配布元・GPU・依存導入に左右されます。数十分は目安であり保証ではありません。

ComfyUIのWorkflow一覧から、使うprofileに対応するJSONを開いてRunします。新しい3つは `netayume_lumina_lora.json`、`illustrious_sdxl_ipadapter_openpose.json`、`qwen_image_edit_2511_multi_reference.json` です。`base` には同梱ワークフローはありません。**起動時に勝手に生成ジョブを投入することはありません。** READYはCUDAデバイス、HTTP応答、ワークフローに必要なノードの存在までの確認です。実際の生成成功・画質までは保証しません。

## 標準プロファイル

| 実行コマンド | 内容 | 同梱ワークフロー |
| --- | --- | --- |
| `bash bootstrap.sh base` | モデル・Custom Node なしの最小 ComfyUI | なし |
| `bash bootstrap.sh seethrough` | SeeThrough によるアニメ調キャラクターのレイヤー・深度分解 | PSD / Depth PSD、合成プレビュー |
| `bash bootstrap.sh video` | Wan 2.1 T2V 1.3B FP16 / UMT5 FP8 scaled / Wan VAE | 832×480・33フレーム・16fps、animated WebP保存 |
| `bash bootstrap.sh image` | Stable Diffusion 1.5 FP16 | 512×512、PNG保存 |
| `bash bootstrap.sh trellis2` | TRELLIS.2 を使う ComfyUI の画像→3D環境 | PBR テクスチャ付き GLB、3Dプレビュー |
| `bash bootstrap.sh netayume-lumina` | NetaYume-Lumina + 自分のLoRAで素の生成を確認 | `netayume_lumina_lora.json` |
| `bash bootstrap.sh illustrious-sdxl` | Illustrious/SDXL + 自分LoRA + IPAdapter(CLIP Vision) + OpenPose | `illustrious_sdxl_ipadapter_openpose.json` |
| `bash bootstrap.sh qwen-image-edit-2511` | キャラ・服/絵柄・ポーズ/シーンの3画像を1指示へ統合 | `qwen_image_edit_2511_multi_reference.json` |
| `bash bootstrap.sh agent` | vLLM OpenAI互換API | Cline等からSSHトンネル経由で利用 |
| `bash bootstrap.sh llm` | 旧予約名 | 明示的エラーで停止 |

比較用プロファイルのContainer diskは、必要最低限の目安を次のとおりとします。

| プロファイル | 必要最低限のContainer disk |
| --- | ---: |
| `netayume-lumina`（NetaYume-Lumina） | 30 GB |
| `qwen-image-edit-2511`（Qwen Image Edit 2511） | 60 GB |

これはモデル配置と起動に必要な最低目安です。生成画像の保存、再ダウンロード用の余裕、依存パッケージの増加分は別途必要になります。

動画の初期出力はanimated WebPです。MP4が必要ならワークフローを追加してください。SeeThrough は `seethrough` プロファイルでのみ導入します。SeeThrough の取得・固定revision・requirements導入に加え、LayerDiffが内部参照するJuggernautのscheduler設定（小さな設定ファイルのみ）も構築時にHugging Faceキャッシュへ先取りします。さらに LayerDiff本体（約10.2 GB）とMarigold深度モデル（約3.3 GB）も、`seethrough` プロファイルの構築中に同じキャッシュへ事前取得します。自動取得が失敗するPodでは、[SeeThrough手順書の事前取得手順](SEE_THROUGH_RUNPOD.md#81-hugging-face-接続に失敗する場合モデルを事前取得する)を実行してください。

ComfyUIはv0.3.50のcommit、PyTorchは2.7.1/cu128、Transformersは4.55.4に固定しています。標準モデルも配布元のcommit・バイト数・SHA-256を固定しています。新モデルを利用するときは対応するComfyUI・依存条件も更新してください。ComfyUIの間接依存パッケージすべてを完全ロックした環境ではありません。

モデルの利用条件: [Wan配布元](https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged)、[SD1.5配布元](https://huggingface.co/Comfy-Org/stable-diffusion-v1-5-archive)。モデルのライセンスはコードの配布条件とは別です。

### 3系統の比較プロファイル

`illustrious-sdxl` は個人LoRAや非標準チェックポイントをGitへ保存しません。Pod起動後に次の場所へ自分のファイルを配置し、ワークフローのLoaderのファイル名だけ合わせてください。`netayume-lumina`のNetaYume-Lumina v3本体はプロファイル実行時に自動取得します。

```text
ComfyUI/models/checkpoints/illustriousXL_v01.safetensors
ComfyUI/models/loras/my_lora.safetensors
ComfyUI/models/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors
ComfyUI/models/clip_vision/clip_vision_h.safetensors
ComfyUI/models/controlnet/controlnet-openpose-sdxl-1.0.safetensors
```

`netayume-lumina` は `prompt → 自分のLoRA → generate`、`illustrious-sdxl` はキャラ/絵柄をIPAdapter、ポーズをOpenPose、キャラをLoRAで分離制御します。後者は `ComfyUI_IPAdapter_plus` と `comfyui_controlnet_aux` を自動導入します。`qwen-image-edit-2511` は公式ComfyUIモデルを自動取得し、3枚の参照画像と自然言語指示を `TextEncodeQwenImageEditPlus` へ渡します。QwenはFP8混合版を使用するため、VRAMが少ない場合は解像度を下げてください。

## 構築の流れと再実行

```text
一時bootstrap取得 → 切断に耐えるバックグラウンド起動
  → OS最低限の依存 → private Git取得 → controller専用venv
  → profile/registry検証 → ディスク空き容量検証
  → 固定版ComfyUI・専用venv・Custom Nodes
  → モデル並列取得 → サイズ/SHA-256検証 → 原子的に配置
  → ComfyUI起動 → CUDA/HTTP/ノード確認 → READY
```

同じコマンドを再実行できます。起動が重複するとlockで抑止し、完了モデルはSHA-256検証後にSKIPします。取得途中のファイルは残り、`hf download` / `aria2c --continue` の再開機能を利用します。配布先・revisionを変えたファイルには別の一時領域を使います。ネットワークや配布サーバーのRange対応次第では、一部の取得がやり直しになる場合があります。

容量判定は未完了モデルの全サイズを予約する保守的な計算です。部分取得の再利用を見込んで必要容量を小さく表示しません。導入予算は見積もりなので、任意のCustom Nodeの大きなビルドまで保証するものではありません。生成出力による後日のディスク不足は別途管理してください。

既存の同一ComfyUIプロセスはPID・プロセス開始時刻・コマンド・設定署名を確認して再利用します。プロファイル、ComfyUI revision、Custom Node構成が変わった場合は、このオーケストレーター自身が起動したComfyUIに限りSIGTERMで自動停止してから切り替えます。実行中の生成ジョブがある場合は中断されるため、テスト環境以外では完了を待ってください。他のプロセスが8188を使用していたら、誤停止を避けるためエラーで止めます。

## 保存場所と成果物の扱い

既定の `RUNTIME_ROOT=/workspace/runtime`。変更する場合はRunpodテンプレートの環境変数で指定します。

```text
/workspace/runtime/
  repository/                 このGitリポジトリの取得先
  controller-venv/            オーケストレーターとhf CLI
  comfy-venv/                 ComfyUIのPython環境
  llm-venv/                   agent用vLLM環境
  ComfyUI/models/             検証済みモデル
  ComfyUI/output/             生成した画像・動画
  ComfyUI/user/default/workflows/
  downloads/                 再開可能な一時取得データ
  logs/bootstrap.log         全体進捗と失敗段階
  logs/downloads.jsonl        モデル単位の結果
  logs/comfyui.log            サービス起動・生成時のログ
  logs/<model>.log            backend詳細、URL/tokenはマスク
  status.json                全体状態、READY/FAILEDを含む
  service.json               管理中のComfyUIプロセス情報
  llm-service.json            管理中のagent APIプロセス情報
```

**v0.1時点では外部ストレージへの自動転送は未接続です。成果物はPod内に保存されます。** Podを削除する前に必ずダウンロードしてください。[Runpodのディスク寿命](https://docs.runpod.io/pods/storage/types)

推奨する次段階は `ComfyUI/output → OneDriveの成果物専用フォルダ → 手元PC`。rcloneを用いて完成したファイルと生成設定を日付・実行IDごとのフォルダへコピーし、転送確認まで原本を残す構成です。接続先と認証を決めてから実装します。[rclone OneDrive](https://rclone.org/onedrive/)

## 設定を追加・変更する

GitHubへ変更をpushしてから同じ1行を実行すると、新しい設定が反映されます。Runtime側repositoryに直接変更を残した場合は、それを上書きせず停止します。固定した過去の環境を使うには `GPU_BOOTSTRAP_REF` にcommit SHAを指定し、上記取得URLの `ref=main` も同じSHAへ変更してください。

`profiles/*.yaml` は用途、`registry.yaml` は取得方法、`comfy/custom_nodes.yaml` は拡張ノードを担当します。モデルごとに `size_bytes` とSHA-256が必須です。HFでは `revision` は40桁commit SHA、`files` は次の形式です。

```yaml
models:
  my_model:
    source: huggingface
    repo: organization/repository
    revision: <full-40-character-commit>
    destination: diffusion_models
    files:
      - path: subdir/model.safetensors
        size_bytes: 123456789
        sha256: <64-character-sha256>
```

HFのサブディレクトリ構造は取得用一時領域に保持し、ComfyUIには `destination/ファイル名` として配置します。ファイル名の衝突は設定エラーになります。

Direct URLの場合は `source: url`, `url`, `filename`, `destination`, `size_bytes`, `sha256` を指定します。HTTPSのみです。秘密トークンや期限付き認証URLはGitへ保存しないでください。Direct URLの追加認証・CivitAI API専用backendは未実装です。

```yaml
nodes:
  my_node:
    repo: https://github.com/owner/trusted-node.git
    revision: <full-40-character-commit>
```

Custom Nodeは信頼できるリポジトリだけを追加します。`requirements.txt` はComfyUI専用venvへ制約付きで導入します。任意の `install.py` は実行しません。追加のOS依存や専用インストーラーを要するNodeは別途対応が必要です。

## トラブル時

| 表示・症状 | 対処 |
| --- | --- |
| 初期取得の401/403/404 | `GH_TOKEN`、対象repoへのContents読み取り権限、有効期限を確認 |
| `disk_preflight` | 作業ディスクを増やす。モデルDL前に停止済み |
| `dependencies` | `logs/dependencies.log` でPython・CUDA・パッケージのエラーを確認 |
| `model_download` | モデル別ログ、配布元、通信、必要ならHF_TOKENと利用条件を確認して再実行 |
| `service_health` | `comfyui.log`、GPU、起動時間、ワークフローのNodeを確認 |
| `[BUSY]` | 別の構築が実行中。`bootstrap.log` を確認 |
| READYだがブラウザで開けない | Runpod側でHTTP 8188を公開したか確認 |

ETAは直近のファイル増分の移動平均から計算する **ダウンロードの概算** です。依存導入や検証の残り時間を含みません。backendの書き込み方によって粗くなり、見積もれない場合は `calculating...` と表示します。JSONLの速度は新規に完成したファイル容量/処理時間で、厳密なネットワーク転送速度ではありません。

## 開発・検証

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python orchestrator.py video --plan
python -m unittest discover -s tests -v
bash -n bootstrap.sh scripts/install_comfy.sh scripts/install_llm.sh
```

`--plan` は設定を検証し、モデル一覧・容量・配置先を表示します。モデル取得、環境導入、GPU起動は行いません。Windowsでも実行できます。本体の構築実行はLinux専用です。

自動テストは設定解決、未知ID、ディスク不足、完了済みSKIP、失敗、再開、破損検知、パス逸脱、secretマスク、失敗時の起動抑止、workflow接続整合性を対象とします。GitHub ActionsではLinuxの排他制御も検証します。backendの単体テストはダウンローダーをモックしており、大容量モデルをCIで取得しません。

実機4090 Podで残る確認:

- 新品Podで1行実行し、SSH切断後も構築が進むこと。
- 標準video/imageでREADYとなり、ワークフローを1回実行して成果物が得られること。
- 同じコマンドの再実行で再DL・ComfyUI二重起動が起きないこと。
- 取得中断後のhf/aria2実通信での再開、失敗からの復帰、実際の所要時間・VRAM。
- 外部成果物転送を追加した後、転送完了を確認してからPodを削除できること。

MVPの対象外: `llm` プロファイルの旧方式、CivitAI専用backend、外部成果物転送、Pod自動作成・削除、モデル検索GUI、Docker image build、間接依存の完全ロック。`agent` は独立したvLLMランチャーで、モデル取得・推論性能・Pod自動作成までは管理しません。
