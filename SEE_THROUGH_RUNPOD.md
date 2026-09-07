# SeeThrough を Runpod / ComfyUI で使う手順

この手順は、このリポジトリの `seethrough` プロファイルで導入される
`ComfyUI-See-through` を使い、1 枚のアニメ調キャラクター画像を Live2D 向けの
透過レイヤーと深度情報へ分解するためのものです。

> **大切:** `video_default.json` は Wan 2.1 によるテキスト→動画ワークフローです。
> Wan と SeeThrough は別プロファイルです。SeeThrough では、専用ワークフロー
> `seethrough_basic.json` が自動配置されます。

## 1. Pod を用意する

Runpod で NVIDIA GPU の Pod を作成し、HTTP ポート **8188** を公開します。目安は
標準構成なら VRAM 16 GB 以上です。8–12 GB でも後述の節約設定で試せますが、遅くなります。

`/workspace` には 60 GB 以上の空き容量を確保してください。モデル本体は初回実行時に
Hugging Face から追加で取得されます。

ComfyUI は認証を追加せずに 8188 番で待ち受けます。Runpod の HTTP URL は第三者に共有せず、
必要なら SSH トンネルでアクセスを制限してください。

## 2. SeeThrough を含む ComfyUI を構築する

Runpod の **Bash ターミナル** で次を実行します。

```bash
curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 \
  https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
bash bootstrap.sh seethrough
```

進捗を確認します。

```bash
tail -f /workspace/runtime/logs/bootstrap.log
```

`[READY]` と表示されたら、Runpod の **Connect → HTTP Service :8188** を開きます。
`[STARTED]` は構築を受け付けただけで、利用可能になったことを意味しません。

この `seethrough` プロファイルは次を導入します。

- ComfyUI
- `ComfyUI-See-through`（固定 revision: `98d754bf04f668647919ab750eccb0e0640faa81`）

Wan 2.1 の動画モデルは取得しません。動画が必要なときだけ、別途 `bash bootstrap.sh video` を実行します。

## 3. SeeThrough の専用ワークフローを ComfyUI に追加する

ComfyUI をブラウザで再読み込みし、Workflow の一覧から `seethrough_basic.json` を開きます。

| ワークフロー | 使いどころ |
| --- | --- |
| `seethrough_basic.json` | PSD と Depth PSD を書き出す標準構成です。 |

一覧に出ない場合は、上記 JSON をブラウザへドラッグ＆ドロップして読み込みます。

## 4. 入力画像を準備する

`Load Image` ノードで、正面に近く、人物が一人だけ写ったアニメ調の PNG または WebP を
アップロードします。背景が単純で、髪・顔・衣服の輪郭が見えている画像ほど安定します。

次のような画像は分解の品質が落ちやすいため、避けるか別画像を試してください。

- 人物が複数いる、または人物が画面端で大きく欠けている
- 強いモーションブラー、極端な遠近、非常に暗い画像
- 髪・手・衣服が密に重なり、境界がほとんど見えない画像
- 写実写真（SeeThrough はアニメイラスト向けです）

## 5. ノードを接続・設定する

`seethrough_basic.json` には、以下が接続済みです。接続を作り直す場合も、この順序にします。

```text
Load Image
  └─ image ───────────────→ SeeThrough Generate Layers
SeeThrough Load LayerDiff Model ─→ SeeThrough Generate Layers
SeeThrough Generate Layers ──────→ SeeThrough Generate Depth
SeeThrough Load Depth Model ─────→ SeeThrough Generate Depth
SeeThrough Generate Depth ───────→ SeeThrough Post Process
SeeThrough Post Process
  ├─ parts ───────────────→ SeeThrough Save PSD
  └─ preview ─────────────→ Preview Image
```

最初は次の値を使います。

| ノード / 項目 | 推奨値 | 意味 |
| --- | --- | --- |
| Load LayerDiff Model / `auto_download` | `true` | 初回にレイヤー生成モデルを取得します。 |
| Load Depth Model / `auto_download` | `true` | 初回に深度モデルを取得します。 |
| Generate Layers / `seed` | 固定値 | 同じ入力・設定で結果を再現するため、試行中は固定します。 |
| Generate Layers / `resolution` | `1024` | まずはこの値で実行します。上げるほど高精細・低速になります。 |
| Generate Layers / `num_inference_steps` | `30` | 標準品質。増やすほど遅くなります。 |
| Generate Depth / `resolution_depth` | `-1` | レイヤーと同じ解像度で深度を推定します。 |
| Post Process / 左右分割 | `true` | 目・耳・手袋などを左右別レイヤーにします。 |
| Load LayerDiff Model / tag embedding cache | `true` | 品質を変えずにおよそ 2 GB の VRAM を節約します。 |
| Load LayerDiff Model / group offload | `false` | 通常はオフ。低 VRAM 時だけオンにします。 |

`Save PSD` ノードの `parts` には必ず `Post Process` の `parts` 出力を、画面確認用の
`Preview Image` には `preview` 出力を接続します。

## 6. 実行と PSD の取得

1. 画面上部の **Queue Prompt** を押します。
2. 初回だけは LayerDiff と Marigold のモデル取得があるため、通常より待ちます。完了まで画面を更新せず待ちます。
3. `Preview Image` で合成プレビューを確認します。
4. `SeeThrough Save PSD` ノードの **Download PSD** を押して PSD をブラウザへ保存します。

PSD は前髪・後髪・顔・目・衣服・アクセサリーなど、最大 24 の透過レイヤーと深度順を含みます。
Live2D 編集では、この PSD を元に不要な重なりの修正や、隠れていた領域の描き足しを行います。

ComfyUI 側の生成データは `/workspace/runtime/ComfyUI/output/` に残ります。Pod を削除する前に、
PSD と必要な出力を手元へダウンロードしてください。

## 7. VRAM が足りないとき

メモリ不足時は、次の順で一つずつ設定を変えて再実行します。

1. LayerDiff Loader の tag embedding cache を有効にする（既定値）。
2. Generate Depth の `resolution_depth=720` にする。
3. Generate Layers の `resolution` を下げる。
4. LayerDiff Loader の group offload を有効にする。CPU と GPU の転送が増えるため、処理時間は約 2〜3 倍になります。

group offload を有効にしても失敗する場合は、より大きな VRAM の Pod を使うのが確実です。

## 8. つまずきやすい点

| 症状 | 確認・対処 |
| --- | --- |
| SeeThrough ノードがない | `bootstrap.log` が `[READY]` か確認し、ブラウザを強制再読み込みします。`/workspace/runtime/logs/comfyui.log` に import エラーがないか確認します。 |
| 初回実行が長い | モデル自動ダウンロード中です。通信と空き容量を確認し、完了を待ちます。事前にモデルを置いた場合は `auto_download=false` にできます。 |
| VRAM / CUDA out of memory | 「7. VRAM が足りないとき」の順に解像度・深度解像度・offload を調整します。 |
| PSD のダウンロードボタンが出ない | `Post Process` の `parts` が `SeeThrough Save PSD` へ接続されているか確認します。ブラウザのダウンロード許可も確認します。 |
| レイヤーに欠け・混ざりがある | 単純な背景・正面寄り・人物一人の画像に替え、seed を変えて再実行します。結果は自動分解の下絵として扱い、Live2D で補正します。 |
| Pod を消したら成果物がない | この構成は外部ストレージへ自動転送しません。削除前に PSD と出力をダウンロードします。 |

## 9. ローカルモデル運用（任意）

毎回の自動取得を避けるには、LayerDiff と Marigold の Diffusers 形式モデル
（`model_index.json` を含むディレクトリ）を次の配下へ置きます。

```text
/workspace/runtime/ComfyUI/models/SeeThrough/
```

この場所では、直下、`<リポジトリ名>/`、または `<組織名>/<リポジトリ名>/` のいずれの配置も
認識されます。ローカル配置を確認した後に両方の Loader の `auto_download` を `false` にすると、
意図しないネットワーク取得を防げます。
