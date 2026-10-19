# repo-health-kit

Mac にある git リポジトリを毎朝点検し、対応が必要な問題をデスクトップ通知とメールで知らせる道具です。自動で直すのは、作業中の変更がなく fast-forward できる同期など、安全を確認できる操作だけです。dirty、stash、脆弱性は自動で変更しません。

五次元経営株式会社が社内で使っている点検の仕組みから、クライアントが Mac 1台で使える部分を切り出しました。利用状況を外部へ送るテレメトリーはありません。

## 入れ方

Claude Code に任せる場合は、[PROMPT.md](PROMPT.md) の文面をそのまま貼り付けてください。入れる・設定する・初回の点検までを一緒に進めます。

自分で入れる場合は、macOS のターミナルで次を実行します。所要時間は5分ほどが目安です。

```bash
git clone <このリポジトリのURL>
cd repo-health-kit
./install.sh
```

本体は `~/Library/Application Support/repo-health-kit/`、設定は `~/.config/repo-health-kit/config.sh` に入ります。設定がすでにある場合、installer は上書きしません。点検対象の初期値は `~/Plugins` の直下です。

必要なコマンドは `bash`、`git`、`python3`、`curl` です。`node` または `npm` がない場合、依存脆弱性は「異常なし」ではなく「未検査」として報告されます。Windows には対応していません。

## メールを設定する

Resend を使う方法を推奨します。設定しない場合も、ローカルのレポートと FAIL のデスクトップ通知は使えます。

1. [Resend](https://resend.com/) でアカウントを作ります。
2. Resend の画面で API キーを作ります。キーは設定ファイルへ書かないでください。
3. 次のコマンドを実行し、表示される入力欄へ API キーを貼り付けます。キーをコマンドの引数や履歴へ残さず、macOS Keychain に保存します。

   ```bash
   security add-generic-password -U -s repo-health-kit -a resend -w
   ```

4. `~/.config/repo-health-kit/config.sh` を開き、次の3項目を設定します。

   ```bash
   RH_MAIL_METHOD="resend"
   RH_MAIL_FROM="onboarding@resend.dev"
   RH_MAIL_TO="あなたのメールアドレス"
   ```

5. 試用の差出人 `onboarding@resend.dev` は、Resend に登録したアドレス宛の送信に限られます。別の宛先へ送る場合は、Resend で所有ドメインを認証し、そのドメインの差出人へ変更します。
6. テスト送信します。

   ```bash
   bash "$HOME/Library/Application Support/repo-health-kit/bin/repo-health.sh" --test-mail
   ```

1Password を使う場合は、API キーの代わりに `RH_RESEND_KEY_OP="op://…"` を設定できます。実行時に `op read` で取得し、キーをログや標準出力へ出しません。

## 届いたメールの読み方

- `FAIL（赤）` は今日中に確認する目安です。例: detached HEAD、作業途中の merge、平文シークレット、本番依存の critical/high、侵害パッケージです。
- `WARN（黄）` は今週中に確認する目安です。例: 未push、stash、3日以上続く dirty、監査不能、CLI のメジャー版遅れです。
- 「作業中」「同期待ち」は赤黄の対象外です。単発の dirty を異常とは決めつけません。
- 「未検査」は異常なしを意味しません。npm やネットワークの状態を確認して再実行してください。

Claude Code に相談するときは、値やシークレットを貼らず、たとえば次のように頼めます。

> repo-health-latest.md の FAIL と WARN を読み、原因を調べてください。作業中の変更は消さず、修正前に影響範囲を説明してください。

## 設定を変える

`~/.config/repo-health-kit/config.sh` を編集します。複数の親ディレクトリや、1日複数回の時刻も指定できます。

```bash
RH_ROOTS=("$HOME/Plugins" "$HOME/仕事のリポジトリ")
RH_SCHEDULE="09:20 17:30"
RH_AUTOFIX_PULL=1
RH_AUTOFIX_CLI=0
```

CLI の自動更新は初期状態で無効です。設定変更後に時刻を launchd へ反映するには、もう一度 `./install.sh` を実行します。

本番依存の critical/high を調査のうえ期限付きで据え置く場合は、`~/.config/repo-health-kit/vuln-allow.tsv` に次の形式で追記します。初期状態は空です。

```text
repo名<TAB>advisoryまたはpackage<TAB>YYYY-MM-DD<TAB>理由
```

## 手で実行する・止める・外す

メールを送らず手で点検するには、次を実行します。

```bash
RH_NOMAIL=1 bash "$HOME/Library/Application Support/repo-health-kit/bin/repo-health.sh"
```

定期実行だけ止めるには、次を実行します。

```bash
launchctl bootout "gui/$UID/com.repo-health-kit"
```

本体と定期実行を外すには、clone したディレクトリで `./uninstall.sh` を実行します。設定、ログ、連続日数の状態は、再導入や調査に備えて残します。不要になった場合は、内容を確認してから次の3か所を Finder で削除してください。

- `~/.config/repo-health-kit/`
- `~/Library/Logs/repo-health-kit/`
- `~/Library/Application Support/repo-health-kit/state/`

## よくある質問

### Mac が起動していない、またはスリープしていたら？

launchd は状況により、次に Mac が利用可能になったときに実行します。毎回の実行時刻を保証するものではありません。最新レポートの生成時刻も確認してください。

### リポジトリが多いと遅くなりますか？

各リポジトリで `git fetch` と `npm audit` を行うため、数やネットワーク状態に応じて時間がかかります。外部コマンドにはタイムアウトを設けています。

### どこまで自動で直しますか？

初期状態では、clean で ahead や stash がなく fast-forward できるリポジトリだけ `git pull --ff-only` で同期します。CLI 更新は初期状態では行いません。commit、push、stash の削除、依存修正は行いません。

### Windows でも使えますか？

使えません。macOS の Keychain、通知、launchd を使うためです。

## ログと安全性

- 最新レポート: `~/Library/Logs/repo-health-kit/repo-health-latest.md`
- 履歴ログ: `~/Library/Logs/repo-health-kit/repo-health.log`
- 状態: `~/Library/Application Support/repo-health-kit/state/`

設定ファイルが現在の利用者以外の所有物である場合や、group/other から書き込み可能な場合は読み込みません。シークレットの値はレポートへ出さず、検出したファイルのパスだけを示します。

## License

MIT License です。詳細は [LICENSE](LICENSE) をご覧ください。
