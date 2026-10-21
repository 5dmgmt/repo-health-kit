# repo-health-kit

Mac にある git リポジトリと、Mac のセキュリティ（Homebrew の部品・PHP・証明書・macOS のアップデート）を毎朝点検し、対応が必要なことをデスクトップ通知とメールで知らせる道具です。自動で直すのは、作業中の変更がなく fast-forward できる同期と、証明書リスト（ca-certificates）の更新など、安全を確認できる操作だけです。dirty、stash、依存パッケージの脆弱性は自動で変更しません。Node や Python などの部品の更新は、設定で有効にしたときだけ行います。

五次元経営株式会社が社内で使っている点検の仕組みから、クライアントが Mac 1台で使える部分を切り出しました。利用状況を外部へ送るテレメトリーはありません。点検のために接続する先は「[Mac のセキュリティ点検](#mac-のセキュリティ点検020)」にまとめています。

## 入れ方

Claude Code に任せる場合は、[PROMPT.md](PROMPT.md) の文面をそのまま貼り付けてください。入れる・設定する・初回の点検までを一緒に進めます。

自分で入れる場合は、macOS のターミナルで次を実行します。所要時間は5分ほどが目安です。Homebrew を使っている場合は、最後の初回点検で Homebrew の更新情報を取得するため、時間が延びることがあります。

```bash
git clone https://github.com/5dmgmt/repo-health-kit.git
cd repo-health-kit
./install.sh
```

本体は `~/Library/Application Support/repo-health-kit/`、設定は `~/.config/repo-health-kit/config.sh` に入ります。設定がすでにある場合、installer は上書きしません。点検対象の初期値は `~/Plugins` の直下です。

必要なコマンドは `bash`、`git`、`python3`、`curl`、`perl` です。`node` または `npm` がない場合、依存脆弱性は「異常なし」ではなく「未検査」として報告されます。Homebrew と composer は、使っている場合に点検の対象になります。Windows には対応していません。

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

## Mac のセキュリティ点検（0.2.0）

0.2.0 で、リポジトリに加えて Mac そのものの点検を足しました。きっかけは、2026年10月に続けて公表された次の2件です。

- **PHP 本体の脆弱性**（CVE-2026-109618 / CVE-2026-109619、通称 PHP2Shell。2026-10-21 公表）。修正版は 8.5.12 / 8.4.27 / 8.3.36 / 8.2.35 です。
- **eMudhra の中間 CA 8件の秘密鍵の漏洩**（2026-10-20 公表）。ブラウザ（Chrome・Safari など）と macOS 本体は対策済みです。一方で、curl・Node・Python などのコマンドラインの道具は、証明書リストを更新するまで、漏洩した証明書を信頼したままになります。

### 何を見るか

1. **Homebrew のセキュリティ部品の更新待ち** — 証明書リスト（ca-certificates）、openssl、curl、git、openssh、node、python、php など、セキュリティに関わる部品に更新が出ていないかを見ます。対象の一覧は同梱の `config/security-packages.txt` です。Homebrew を使っていない Mac では、この点検は行いません。
2. **PHP の最低版** — Mac にある `php` と `php-fpm` の版が、上の修正版より古くないか、サポートが終わった系列（8.1 以前）でないかを見ます。PHP がサーバーとして動いている（接続を待ち受けている）ときは FAIL、そうでなければ WARN です。Apache は PHP を読み込んでいるときだけ数えます。管理者権限で動いているサーバーは見えないことがあるため、その場合は WARN になります。
3. **composer の依存** — `composer.lock` があるリポジトリで `composer audit` を実行し、本番依存の脆弱性を見ます。npm の依存と同じく、critical/high は FAIL です。
4. **失効済みの証明書を信頼していないか** — Node、curl、python3 が、漏洩した証明書を使った確認用のテスト先へつながってしまうかを試します。つながった道具は、その証明書をまだ信頼しているということです。
5. **macOS のアップデート待ち** — macOS やセキュリティ関連のアップデートが出ていないかを見ます。
6. **kit 自身の新しい版** — 公開リポジトリの版番号と比べ、新しい版が出ていれば知らせます。版が新しくなると、点検の中身（テスト先や最低版の表）も新しくなるためです。

### 何を自動で直すか

- **証明書リスト（ca-certificates）** は、Homebrew に更新が出ていれば、初期設定で自動更新します。データだけの部品なので、既定で自動にしています。止める場合は `RH_AUTOFIX_CA_CERTS=0` にします。
- **それ以外のセキュリティ部品**（node、python、openssl、curl、php など）は、`RH_AUTOFIX_SECURITY=1` のときだけ、まとめて `brew upgrade` します。Node や Python の版が上がると、開発中のアプリの動きが変わることがあるため、初期値は 0（自動更新しない）です。0 のままなら、更新待ちの部品は WARN 1件にまとめて届きます。
- PHP の最低版の点検、composer の依存、macOS のアップデートでは、自動では直しません（Homebrew の php は、`RH_AUTOFIX_SECURITY=1` のとき上の更新に含まれます）。WARN や FAIL の文に、直し方の手がかりを添えます。
- 自動更新では、名指しした部品だけを更新します。その部品に依存する別の部品（たとえば Node や Python）を、Homebrew の既定の動きでまとめて更新することはしません。
- 自動で更新したものは、レポートの「自動で直したもの」に載ります。自動更新に失敗したときは WARN でお知らせします。

### 外部へ接続するところ

- **証明書の点検**: 点検のたびに、確認用に公開されているテスト先（`dv-g3b-emudhra.we-have-a-problem.com` など2件。出典は [emudhra.we-have-a-problem.com](https://emudhra.we-have-a-problem.com/)）へ、手元の道具ごとに1回ずつ接続します。初期設定では、多くて10回（道具5つ × テスト先2件）です。応答があったかどうかだけを見て、ページの中身は読みません。止める場合は `RH_TLS_PROBE=0` にします。
- **新しい版の確認**: `raw.githubusercontent.com` から、版番号だけを書いたファイル `VERSION` を読みます。止める場合は `RH_KIT_UPDATE_CHECK=0` にします。
- **そのほか**: Homebrew の更新情報（`brew update`）、macOS のアップデート確認（`softwareupdate -l`）、`composer audit` は、それぞれの配布元へ接続します。
- 点検結果を送る先は、設定したメールの宛先（Resend 経由）だけです。

Mac のセキュリティ点検を丸ごと止める場合は `RH_SKIP_SECURITY=1` にします。このときは、レポートの「参考」に「未検査」と残ります。

## 届いたメールの読み方

メールは、FAIL か WARN があるときに届きます。

- `FAIL（赤）` は今日中に確認する目安です。例: detached HEAD、作業途中の merge、平文シークレット、本番依存の critical/high（npm・composer）、侵害パッケージ、サーバーとして動いている古い PHP です。
- `WARN（黄）` は今週中に確認する目安です。例: 未push、stash、3日以上続く dirty、監査不能、CLI のメジャー版遅れ、Mac のセキュリティ部品の更新待ち、古い PHP（サーバーとして動いていないもの）、失効済みの証明書を信頼している道具、macOS のアップデート待ち、kit の新しい版です。
- 「作業中」「同期待ち」は赤黄の対象外です。単発の dirty を異常とは決めつけません。
- 「未検査」は異常なしを意味しません。npm、Homebrew、ネットワークの状態を確認して再実行してください。
- 「参考」は、ローカルのレポート（`repo-health-latest.md`）にだけ載り、メールの要対応には数えません。Apple 標準の curl と python3 についての知らせは、ここに出ます（[よくある質問](#apple-の-curl-と-python3-が失効済みの証明書をまだ信頼していると参考に出続けます)）。

Mac のセキュリティ点検の文面は、たとえば次のようになります。版やパスは Mac ごとに変わります。

```text
FAIL  PHP 8.5.11（/opt/homebrew/bin/php）がサーバーとして動いています。CVE-2026-109618 / CVE-2026-109619（PHP2Shell・2026-10-21 公表）の修正版 8.5.12 以上へ更新してください
WARN  PHP 8.5.11（/opt/homebrew/bin/php）は修正版 8.5.12 より古い版です（CVE-2026-109618 / CVE-2026-109619）。使っていなければ brew uninstall php、使うなら修正版が出しだい brew upgrade php
WARN  Mac のセキュリティ部品に更新が出ています: node 26.11.1 → 26.12.0（brew upgrade で更新できます）
WARN  Node が失効済みの証明書を信頼しています（eMudhra 中間CAの鍵漏洩）。brew upgrade node（Homebrew 以外で入れた場合はその方法で最新版）へ更新してください
WARN  macOS のアップデートが出ています: <アップデートの名前>（システム設定 → 一般 → ソフトウェアアップデート）
WARN  repo-health-kit の新しい版 <今の版> → <新しい版> があります。clone したフォルダで git pull し、./install.sh を実行してください
```

Claude Code に相談するときは、値やシークレットを貼らず、たとえば次のように頼めます。

> repo-health-latest.md の FAIL と WARN を読み、原因を調べてください。作業中の変更は消さず、修正前に影響範囲を説明してください。brew upgrade や brew uninstall で Mac の部品を変えるときも、先に何を変えるかを説明してください。

## 設定を変える

`~/.config/repo-health-kit/config.sh` を編集します。複数の親ディレクトリや、1日複数回の時刻も指定できます。

```bash
RH_ROOTS=("$HOME/Plugins" "$HOME/仕事のリポジトリ")
RH_SCHEDULE="09:20 17:30"
RH_AUTOFIX_PULL=1
RH_AUTOFIX_CLI=0
```

CLI の自動更新は初期状態で無効です。設定変更後に時刻を launchd へ反映するには、もう一度 `./install.sh` を実行します。

Mac のセキュリティ点検（0.2.0）の設定は次の6つです。値は初期値です。設定ファイルに書いていない項目は、この初期値で動きます。変えたい項目だけを書き足してください。

```bash
RH_SKIP_SECURITY=0        # 1 で Mac のセキュリティ点検を丸ごと止めます
RH_AUTOFIX_CA_CERTS=1     # 証明書リスト ca-certificates を Homebrew で自動更新します。0 で止めます
RH_AUTOFIX_SECURITY=0     # 1 で node・python・openssl・php などのセキュリティ部品も自動更新します
RH_TLS_PROBE=1            # 0 で証明書の点検（テスト先への接続）を止めます
RH_SKIP_SOFTWAREUPDATE=0  # 1 で macOS のアップデート確認を止めます
RH_KIT_UPDATE_CHECK=1     # 0 で kit の新しい版の確認を止めます
```

本番依存の critical/high を調査のうえ期限付きで据え置く場合は、`~/.config/repo-health-kit/vuln-allow.tsv` に次の形式で追記します。npm と composer の両方に効きます。初期状態は空です。

```text
repo名<TAB>advisoryまたはpackage<TAB>YYYY-MM-DD<TAB>理由
```

## 新しい版に更新する

clone したフォルダで、次を実行します（PROMPT.md で入れた場合は `~/Tools/repo-health-kit` です）。

```bash
git pull
./install.sh
```

- `install.sh` は、本体と同梱の表（テスト先・最低版など）を新しい版に入れ替え、最後にメールを送らずに一度点検します。
- 設定ファイル（`~/.config/repo-health-kit/config.sh`）と据え置きの設定（`vuln-allow.tsv`）は上書きしません。
- 新しい版で増えた設定は、書かなくても初期値で動きます。変えたい項目だけを「[設定を変える](#設定を変える)」を見て書き足してください。
- 0.2.0 からは、新しい版が出ると、毎朝の点検で WARN としてお知らせします。0.1.0 にはこの確認がないため、0.1.0 から 0.2.0 への更新は、この手順で一度行ってください。

Claude Code に任せる場合は、[PROMPT.md の「すでに入れている人が新しい版に更新するとき」](PROMPT.md#すでに入れている人が新しい版に更新するとき)の文面を貼り付けてください。

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

各リポジトリで `git fetch` と `npm audit` を行うため、数やネットワーク状態に応じて時間がかかります。Mac のセキュリティ点検でも、Homebrew の更新情報の取得や macOS のアップデート確認に時間がかかることがあります。外部コマンドにはタイムアウトを設けています。

### どこまで自動で直しますか？

初期状態では、clean で ahead や stash がなく fast-forward できるリポジトリだけ `git pull --ff-only` で同期します。Homebrew を使っている場合は、証明書リスト（ca-certificates）も更新します。CLI と、Node や Python などのセキュリティ部品の更新は、初期状態では行いません。commit、push、stash の削除、依存修正は行いません。

### Apple の curl と python3 が「失効済みの証明書をまだ信頼している」と参考に出続けます

macOS に最初から入っている `/usr/bin/curl` と `/usr/bin/python3` は、Apple が管理する証明書リスト（`/etc/ssl/cert.pem`）を使います。そのため、Apple の更新が届くまでこの状態が続き、利用者の側でできる作業はありません。Apple の修正がソフトウェアアップデートで出たら、適用してください。参考の扱いなので、メールの要対応には数えません。ブラウザ（Chrome・Safari など）と macOS 本体は対策済みです。Homebrew の curl・Node・python3 は、`brew upgrade` で更新すると拒否に変わることを、五次元経営の Mac で確かめています。

### Node や Python も自動で更新したほうがよいですか？

どちらも選べます。`RH_AUTOFIX_SECURITY=1` にすると、セキュリティの更新が早く入ります。一方で、Node や Python の版が上がり、開発中のアプリの動きが変わることがあります。初期値の 0 のまま WARN を受け取り、作業の区切りで `brew upgrade` する進め方もあります。

### Windows でも使えますか？

使えません。macOS の Keychain、通知、launchd を使うためです。

## ログと安全性

- 最新レポート: `~/Library/Logs/repo-health-kit/repo-health-latest.md`
- 履歴ログ: `~/Library/Logs/repo-health-kit/repo-health.log`
- 状態: `~/Library/Application Support/repo-health-kit/state/`

設定ファイルが現在の利用者以外の所有物である場合や、group/other から書き込み可能な場合は読み込みません。シークレットの値はレポートへ出さず、検出したファイルのパスだけを示します。

## License

MIT License です。詳細は [LICENSE](LICENSE) をご覧ください。
