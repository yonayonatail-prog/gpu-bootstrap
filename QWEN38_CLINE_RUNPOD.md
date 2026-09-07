# Qwen3.8-27B を Runpod で起動し、VS Code の Cline から使う手順

この手順では、Runpod の GPU Pod 上で Qwen3.8-27B の Q4 GGUF 量子化モデルを vLLM の OpenAI 互換 API として起動し、
手元の Windows PC の VS Code / Cline から SSH トンネル経由で利用します。

通信経路は次のとおりです。API ポートを Runpod の HTTP 公開ポートに追加する必要はありません。

```text
VS Code + Cline → http://127.0.0.1:8000/v1 → SSH tunnel → Pod 内 127.0.0.1:8000 → vLLM / Qwen3.8-27B
```

## 0. 事前に用意するもの

- Runpod アカウント
- Windows PC 上の VS Code
- VS Code の Cline 拡張機能
- Windows の OpenSSH クライアント（通常は標準搭載）
- まずは **VRAM 48 GB 級**の GPU Pod。Q4 は 24 GB 級でも試せますが、長いコンテキストや Cline のエージェント利用では余裕が少なくなります
- Pod の `/workspace` に少なくとも **50 GB 程度の空き容量**。Q4 モデル、Hugging Face キャッシュ、vLLM、Python 環境のための目安です

このリポジトリの既定モデルは `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M` です。Q4 の
GGUF 量子化なので、BF16 の重みをそのまま使う構成より GPU メモリとディスク消費を大きく抑えます。
GGUF は公式 Qwen 配布物ではなく Unsloth による量子化配布物です。tokenizer は互換性のため
公式の `Qwen/Qwen3.8-27B` を使用します。

## 1. Runpod で Pod を作成する

1. Runpod にログインします。
2. Pods の作成画面を開きます。
3. NVIDIA GPU を選びます。まずは VRAM 48 GB 級を選びます。24 GB 級で試す場合は、後述の `AGENT_VLLM_ARGS` でコンテキスト長を短くします。
4. Ubuntu 系のテンプレートを選びます。Python 3.10〜3.13、NVIDIA ドライバ、root またはパスワード不要の `sudo` が使えるものが前提です。
5. `/workspace` の容量を 50 GB 以上に設定します。
6. LLM API 用に HTTP ポートを公開する必要はありません。SSH 接続を利用できる状態にします。
7. Pod を作成して起動を待ちます。
8. Runpod の Pod 画面で **Connect → SSH** を開き、表示されるホスト名と SSH ポートを控えます。以後、これを `<runpod-host>` と `<runpod-port>` と表記します。

## 2. API キーを用意する

API キーは Cline が Pod 上の API へ接続するための共有秘密です。Git、ソースコード、スクリーンショット、
チャットに保存・送信しません。

Runpod の Bash ターミナルを開き、まずランダムな値を生成します。

```bash
openssl rand -hex 32
```

表示された 64 文字をパスワードマネージャーなど安全な場所へ保存します。この値を以下では
`<your-agent-api-key>` と表記します。

Pod を停止・起動しても設定を残したい場合は、Runpod の Pod 設定で Secret を作成し、
名前を `AGENT_API_KEY`、値を生成したキーにします。Secret を使わない場合は、次の起動コマンドを
実行する Bash セッションで毎回 `export` します。

## 3. Runpod 側で vLLM / Qwen を起動する

Runpod の **Bash ターミナル** で、Secret を使わない場合は次を実行します。

```bash
export AGENT_API_KEY='<your-agent-api-key>'
export AGENT_MODEL='unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M'
export AGENT_TOKENIZER='Qwen/Qwen3.8-27B'
```

Secret を `AGENT_API_KEY` として設定済みなら、同名の `export` は不要です。`AGENT_MODEL` と
`AGENT_TOKENIZER` は未設定でも上記の Q4 値が既定で使われます。続けて、このリポジトリの最新版 bootstrap を保存して実行します。

```bash
curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 180 \
  https://raw.githubusercontent.com/yonayonatail-prog/gpu-bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
bash bootstrap.sh agent
```

`[STARTED]` はバックグラウンド起動の受付であり、モデルのダウンロード・ロード完了ではありません。
ターミナルを閉じても処理は続きます。ログを確認します。

```bash
tail -f /workspace/runtime/logs/llm.log
```

モデルの初回取得と vLLM のインストールには時間が掛かります。エラーなく API が待受状態になるまで待ちます。
ログの追跡を終了するだけなら `Ctrl+C` を押します。これは vLLM 本体を停止しません。

別の Bash ターミナルで、Pod 内から API を確認します。

```bash
curl --fail --silent \
  -H "Authorization: Bearer $AGENT_API_KEY" \
  http://127.0.0.1:8000/v1/models
```

レスポンス内に `agent` があれば、Pod 側の API は利用可能です。起動状態の記録は次でも確認できます。

```bash
cat /workspace/runtime/llm-service.json
```

## 4. Windows で SSH トンネルを開く

Windows で **PowerShell** を開きます。Runpod の Connect → SSH に表示された値で、次を実行します。

```powershell
ssh -N -L 8000:127.0.0.1:8000 <runpod-host> -p <runpod-port>
```

最初の接続時はホスト鍵の確認が表示されるため、Runpod に表示される接続先と一致することを確認して
`yes` と入力します。パスワードまたは Runpod が案内する認証情報を入力します。

この PowerShell はトンネル専用です。何も表示されず待機する状態が正常です。VS Code を使っている間は
閉じないでください。終了するときはこの PowerShell で `Ctrl+C` を押します。

別の PowerShell を開き、Windows 側からトンネル越しの API を確認します。

```powershell
$headers = @{ Authorization = 'Bearer <your-agent-api-key>' }
Invoke-RestMethod -Headers $headers -Uri http://127.0.0.1:8000/v1/models
```

`agent` が返れば、Cline を設定できます。接続できない場合は、先に Runpod 側の `llm.log` と、
SSH コマンドのホスト名・ポートを確認してください。

## 5. VS Code に Cline を入れる

1. VS Code を開きます。
2. 左側の Extensions を開きます。
3. `Cline` を検索します。
4. 発行元と拡張機能名を確認して **Install** を押します。
5. インストール完了後、左側のアクティビティバーから Cline を開きます。
6. 対象の開発フォルダーを VS Code で開きます。Cline にファイル編集を許可する前に、対象フォルダーが正しいことを確認します。

## 6. Cline を Runpod の API に接続する

1. Cline パネルの歯車アイコン、または入力欄付近の API Provider 設定を開きます。
2. **API Provider** に **OpenAI Compatible** を選びます。
3. **Base URL** に次を設定します。

   ```text
   http://127.0.0.1:8000/v1
   ```

4. **API Key** に `<your-agent-api-key>` を貼り付けます。
5. **Model ID**（または Model）に次を入力します。

   ```text
   agent
   ```

6. 表示される場合は **Verify** または **Save** を押します。
7. 新しいチャットで、まず `こんにちは。接続確認として「OK」とだけ返答してください。` と送ります。

`agent` は Qwen の Hugging Face モデル ID ではなく、この起動構成が vLLM に公開する API 上のモデル名です。
ここへ `Qwen/Qwen3.8-27B` を入力しないでください。

Cline は OpenAI 互換プロバイダーに Base URL、API Key、Model ID を設定して接続できます。設定項目の名称や
配置は拡張機能の更新で変わる可能性があります。[Cline の OpenAI Compatible 設定](https://docs.cline.bot/provider-config/openai-compatible)も参照してください。

## 7. Cline で開発を始める

接続確認後、Cline には目的・範囲・確認方法を一度に伝えます。例えば次のように依頼します。

```text
このリポジトリを確認して、README の誤字を修正してください。
変更前に対象ファイルと修正案を短く示し、変更後にテストまたは検証コマンドを実行してください。
対象外のファイルは変更しないでください。
```

Cline がファイル編集、ターミナル実行、外部アクセスを提案したら、内容と対象パス・コマンドを確認してから
承認します。特に削除、依存関係の大量更新、認証情報の読み取り、外部サービスへの送信は慎重に扱ってください。

## 8. よくある問題

| 症状 | 確認・対処 |
| --- | --- |
| `Connection refused` | SSH トンネル用 PowerShell が動いているか、Pod の `llm.log` で vLLM が起動済みか確認します。 |
| `401` / Invalid API key | Runpod で起動した `AGENT_API_KEY` と Cline の API Key が完全一致するか確認します。キーをログや Git に書き込まないでください。 |
| Model not found | Cline の Model ID は `agent` です。`Qwen/Qwen3.8-27B` ではありません。 |
| Pod 側がメモリ不足で停止する | Q4 でもコンテキスト長の KV キャッシュが必要です。まず `export AGENT_VLLM_ARGS='--max-model-len 16384 --gpu-memory-utilization 0.90'` を設定してから起動し、それでも不足する場合は VRAM の大きい GPU を使います。 |
| Pod を再起動したら接続できない | vLLM 起動状態を確認し、必要なら `AGENT_API_KEY` を設定して `bash bootstrap.sh agent` を再実行します。Windows 側の SSH トンネルも開き直します。 |
| ポート 8000 が使用中 | Pod では `llm-service.json` の PID を確認します。Windows 側では別のトンネルやローカルサービスが 8000 を使っていないか確認します。必要なら `AGENT_PORT` と SSH の左右のポートを同じ値へ変更します。 |

## 9. モデルまたは API キーを変更して再起動する場合

すでに agent サービスが動いていると、スクリプトは既存サービスを再利用します。モデル名や API キーを変える場合は、
Runpod の Bash ターミナルで先に既存プロセスを停止します。

```bash
pid=$(python3 -c 'import json; print(json.load(open("/workspace/runtime/llm-service.json"))["pid"])')
kill "$pid"
rm /workspace/runtime/llm-service.json
```

新しい値を設定してから、再度起動します。

```bash
export AGENT_API_KEY='<new-agent-api-key>'
export AGENT_MODEL='unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M'
export AGENT_TOKENIZER='Qwen/Qwen3.8-27B'
bash bootstrap.sh agent
```

最後に、Windows の SSH トンネルと Cline の API Key を新しい値に合わせます。

## 10. 作業終了時

1. Cline のタスクが完了したこと、変更内容と Git 差分を確認します。
2. SSH トンネルの PowerShell で `Ctrl+C` を押してトンネルを閉じます。
3. 継続利用しない場合は、Runpod で Pod を停止します。課金を止めたい場合は Runpod 側の状態を確認してから停止または削除します。
4. Pod を削除する前に必要な成果物・ログ・ソース変更を Git などへ退避します。Pod 内のデータは削除後に復元できません。
