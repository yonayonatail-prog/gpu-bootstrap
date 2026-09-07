# RunPod で TRELLIS2 を使う手順

このリポジトリの `trellis2` プロファイルは、ComfyUI と
`ComfyUI-TRELLIS2` を導入し、1 枚の画像から PBR テクスチャ付き GLB を
作るためのものです。

## 事前条件

- **Linux の NVIDIA Pod** を使います。Windows 用 Pod や CPU Pod では動きません。
- GPU メモリは **24 GB 以上**（RTX 4090 / A5000 / A6000 以上を目安）にします。
  TRELLIS.2 の公式要件は最低 24 GB で、A100/H100 で検証されています。
- `/workspace` のディスクは **少なくとも 60 GB、できれば 80 GB 以上**にします。
- RunPod の Pod 設定で TCP ではなく **HTTP ポート 8188** を公開します。
- 初回構築中は Pod を Stop/Terminate しません。Stop は処理を中断します。

このリポジトリは公開リポジトリです。GitHub トークン、`GH_TOKEN`、
Hugging Face トークンをこの手順のために設定したり、コマンドに書いたりする
必要はありません。過去にターミナル、チャット、スクリーンショット等へ
トークンを貼り付けた場合は、そのトークンを GitHub 側で失効させてください。

## 1. Pod を作る

RunPod で CUDA 対応の Ubuntu 系テンプレートを選び、上の条件を満たす GPU、
ディスク、HTTP 8188 を指定して Pod を起動します。Pod の **Connect → Terminal**
から Bash ターミナルを開きます。

## 2. 構築を開始する

次の 1 行をそのまま実行します。

```bash
curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/bootstrap.sh -o bootstrap.sh
bash bootstrap.sh trellis2
```

`[STARTED]` はバックグラウンドで構築を受け付けた、という意味です。完了では
ありません。ターミナルを閉じても構築は継続します。

セキュリティ上、ダウンロードしたスクリプトを実行する前に確認したい場合は、
次のように保存して中身を確認してから実行します。

```bash
curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/bootstrap.sh -o /tmp/gpu-bootstrap.sh
less /tmp/gpu-bootstrap.sh
bash /tmp/gpu-bootstrap.sh trellis2
```

## 3. 完了を確認する

別ターミナル、または同じターミナルで次を実行します。

```bash
tail -f /workspace/runtime/logs/bootstrap.log
```

次が出れば ComfyUI と必要なノードの起動確認まで完了です。

```text
[READY]
Profile: trellis2
```

`[FAILED]` が出た場合は、推測で再インストールせず、まず次を保存してください。

```bash
tail -n 200 /workspace/runtime/logs/bootstrap.log
tail -n 200 /workspace/runtime/logs/comfyui.log
```

同じ構築コマンドを再実行しても、完了済みの環境・ダウンロードは検証後に再利用されます。

## 4. ComfyUI を開く

`[READY]` の後、RunPod の Pod 画面にある **HTTP services** の
**Port 8188 → HTTP Service** を開きます。開くべきアドレスは、通常
`https://<Pod ID>-8188.proxy.runpod.net/` のような **`https://` で始まり
`proxy.runpod.net` を含む URL** です。

起動ログに出る次の表示は、コンテナ*内*の待受先を示すだけです。PC のブラウザや
Codex のブラウザへコピーして開いてはいけません。

```text
To see the GUI go to: http://0.0.0.0:8188
```

アドレスバーが `http://0.0.0.0:8188/` のままで「このサイトにアクセスできません」
となる場合は、ComfyUI の起動失敗ではありません。RunPod の HTTP Service リンクでは
なく、コンテナ内アドレスを開いています。Pod 画面へ戻り、Port 8188 の **HTTP Service**
リンクを開き直します。HTTP services が `Ready` になるまで待ちます。

RunPod 側のリンクを開いても画面が出ない場合だけ、Pod のターミナルで次を実行します。

```bash
curl --fail --silent http://127.0.0.1:8188/system_stats
```

JSON が返れば ComfyUI は Pod 内で起動済みなので、確認対象は RunPod の HTTP Service
（Port 8188 の公開状態・リンク先）です。接続エラーになる場合は、次を採取して
トラブルシュートします。

```bash
tail -n 200 /workspace/runtime/logs/comfyui.log
tail -n 200 /workspace/runtime/logs/bootstrap.log
```

初回起動ログの `MISSING -- run install.py`、`No module named 'CGAL'`、または
`pytorch with cu130 or higher` の警告だけでは、構築失敗とは判断しません。このプロファイル
では必要な TRELLIS2 ノードが登録されて `READY` になることを確認します。`install.py` や
PyTorch の更新を独断で実行すると、固定済みの依存関係を崩す可能性があるため、実行時に
必要なノードが失敗した場合に限ってログを確認して対処します。

### `LoadTrellis2Models` が初回ダウンロードで失敗する場合

`hf_hub_download() got an unexpected keyword argument 'tqdm_class'` は、TRELLIS2
ノードと Hugging Face Hub クライアントの進捗表示APIの互換性不整合です。GPUメモリ、
Hugging Face の認証、モデルの容量不足が原因ではありません。現行の起動スクリプトは
この引数を対応していないクライアントでは自動的に無視する互換処理を導入します。

すでに構築済みのPodでは、次を1回だけ実行してからComfyUIを再起動します。

```bash
sed -i 's/, tqdm_class=_comfy_tqdm()//g' \
  /workspace/runtime/ComfyUI/custom_nodes/ComfyUI-TRELLIS2/nodes/stages.py
kill "$(python3 -c 'import json; print(json.load(open("/workspace/runtime/service.json"))["pid"])')"
bash bootstrap.sh trellis2
```

最後のコマンドが `[STARTED]` を表示したら、`tail -f
/workspace/runtime/logs/bootstrap.log` で再度 `[READY]` になることを確認します。その後、
ブラウザを再読み込みして同じワークフローをキュー実行します。`install.py` はこのエラーの
修正ではないため実行しません。

ワークフロー一覧から `trellis2_geometry_texture.json` を開きます。見当たらない場合は
Pod のターミナルで次を確認します。

```bash
ls -l /workspace/runtime/ComfyUI/user/default/workflows/trellis2_geometry_texture.json
```

## 5. 画像から GLB を作る

1. `LoadImage` ノードで、対象物が中央にあり背景が単純な画像をアップロードします。
2. `LoadTrellis2Models` はまず `512`、precision と attention backend は `auto` のままにします。
3. キュー実行します。初回の実行時には TRELLIS2 の重みが Hugging Face から取得されるため、
   通常の生成より時間がかかります。この間は Pod を止めません。
4. 完了した GLB は `/workspace/runtime/ComfyUI/output/` に保存されます。ComfyUI の出力欄から
   ダウンロードするか、Pod を削除する前に必ず手元または永続ストレージへコピーします。

背景除去済みで、被写体全体が写り、強い反射・透明・細すぎる部位の少ない画像ほど結果が
安定します。単一画像のため、写っていない背面は推定生成されます。

## 6. Pod の扱い

- 一時的に使わないだけなら **Stop** します。永続ディスクを保持している限り、再開後は
  同じ Pod と環境を使えます。
- **Terminate** は Pod と一時ディスクを失う操作です。必要な GLB と画像を退避してから行います。
- 新しい Pod を作った場合だけ、手順 2 をもう一度実行します。

## よくある停止箇所

| 表示 | 最初に確認すること |
| --- | --- |
| `CUDA unavailable` | NVIDIA GPU Pod か、GPU ドライバを含むテンプレートか |
| `disk_preflight` | `/workspace` を 80 GB 以上に増やす |
| `service_health` | `comfyui.log` と HTTP 8188 の公開設定 |
| `http://0.0.0.0:8188` が開けない | 正常な挙動。RunPod の Port 8188 → HTTP Service が開く `https://…proxy.runpod.net` を使う |
| HTTP Service が `Ready`、`curl 127.0.0.1:8188/system_stats` も成功 | ComfyUI は起動済み。RunPod の公開リンクまたはブラウザ側を確認する |
| 初回キューが進まない | ComfyUI の画面・`comfyui.log` を確認。初回の重み取得中は待つ |
| メモリ不足 | 512 のまま試し、他の GPU プロセスを止める。24 GB 未満の GPU は使わない |

## 参考

TRELLIS.2 は Linux と NVIDIA GPU を対象とし、少なくとも 24 GB の GPU メモリを必要とします。
公式実装の詳細は [Microsoft TRELLIS.2](https://github.com/microsoft/TRELLIS.2) を参照してください。
ComfyUI 用ノードの導入方式と更新情報は
[ComfyUI-TRELLIS2](https://github.com/PozzettiAndrea/ComfyUI-TRELLIS2) を参照してください。
