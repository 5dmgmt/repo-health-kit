# repo-health-kit

Mac にある git リポジトリと、Mac のセキュリティ（Homebrew の部品・PHP・Node.js・Java・macOS とアプリの版・証明書・macOS のアップデート）を毎朝点検し、対応が必要なことをデスクトップ通知とメールで知らせる道具です。自動で直すのは、作業中の変更がなく fast-forward できる同期と、証明書リスト（ca-certificates）の更新など、安全を確認できる操作だけです。dirty、stash、依存パッケージの脆弱性は自動で変更しません。Node や Python などの部品の更新は、設定で有効にしたときだけ行います。

五次元経営株式会社が社内で使っている点検の仕組みから、クライアントが Mac 1台で使える部分を切り出しました。利用状況を外部へ送るテレメトリーはありません。点検のために接続する先は「[Mac のセキュリティ点検](#mac-のセキュリティ点検020)」にまとめています。

## 入れ方

Claude Code に任せる場合は、[PROMPT.md](PROMPT.md) の文面をそのまま貼り付けてください。入れる・設定する・初回の点検までを一緒に進めます。

自分で入れる場合は、macOS のターミナルで次を実行します。所要時間は5分ほどが目安です。Homebrew を使っている場合は、最後の初回点検で Homebrew の更新情報を取得するため、時間が延びることがあります。

```bash
git clone https://github.com/5dmgmt/repo-health-kit.git
cd repo-health-kit
./install.sh
```

本体は `~/Library/Application Support/repo-health-kit/`、設定は `~/.config/repo-health-kit/config.sh` に入ります。設定がすでにある場合は引き継ぎ、npm と clone の場所だけを記録し直します。点検対象の初期値は `~/Plugins` の直下です。

必要なコマンドは `bash`、`git`、`python3`、`curl`、`perl` です。`node` または `npm` がない場合、依存脆弱性は「異常なし」ではなく「未検査」として報告されます。Homebrew と composer は、使っている場合に点検の対象になります。Windows には対応していません。

## メールを設定する

Resend を使う方法を推奨します。設定しない場合も、ローカルのレポートと FAIL・WARN のデスクトップ通知は使えます。

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
   /bin/bash "$HOME/Library/Application Support/repo-health-kit/bin/repo-health.sh" --test-mail
   ```

1Password を使う場合は、API キーの代わりに `RH_RESEND_KEY_OP="op://…"` を設定できます。実行時に `op read` で取得し、キーをログや標準出力へ出しません。

## 鍵と JavaScript の依存の点検

鍵の検査は、追跡中のファイルと、未追跡かつ gitignore 外のファイルを見ます。未追跡で gitignore 済みのファイルは対象外です。追跡中の `.env.local`・`.env.production` など `.env*` は、追跡自体を FAIL にします（anon JWT だけのものは除きます）。`.env.example`・`.env.sample`・`.env.tpl` は、値が空・`op://`・`<...>`・`your-` で始まる見本だけなら除外します。検出結果にはファイル名・行番号・型だけを出し、値は出しません。見つかった鍵は入れ替え、Git の追跡から外してください。

Supabase の service_role JWT（anon は対象外）、`sb_secret_`、Resend、AWS、GitHub、Google OAuth、パスワード入り PostgreSQL URL も見ます。侵害パッケージの照合は `package-lock.json` に加え、`npm-shrinkwrap.json`・`pnpm-lock.yaml`・`yarn.lock`（v1・berry）・`bun.lock` に対応します。読み取れない lock や照合の異常終了は FAIL、バイナリの `bun.lockb` は「未照合」の WARN です。

依存の脆弱性は lock に合わせて npm・pnpm・yarn berry・bun の audit を使います。その道具がない場合は、入れる道具を参考に案内します。pnpm などの lock を npm audit で調べたことにはしません。

## Mac のセキュリティ点検（0.2.0〜）

0.2.0 で、リポジトリに加えて Mac そのものの点検を足しました。きっかけは、2026年10月に続けて公表された次の3件です（Node.js は 0.3.0 で追加）。

- **PHP 本体の脆弱性**（CVE-2026-109618 / CVE-2026-109619、通称 PHP2Shell。2026-10-21 公表）。修正版は 8.5.12 / 8.4.27 / 8.3.36 / 8.2.35 です。
- **Node.js の安全修正**（2026-10-21 公表）。修正版は 26.12.1 / 24.22.1 / 22.23.4 です。重要度 High の4件には、証明書の相手確認（ホスト名の確認）をすり抜けられる問題と、圧縮データ（Brotli）の処理で外から命令を実行されうる問題が含まれます。
- **eMudhra の中間 CA 8件の秘密鍵の漏洩**（2026-10-20 公表）。ブラウザ（Chrome・Safari など）と macOS 本体は対策済みです。一方で、curl・Node・Python などのコマンドラインの道具は、証明書リストを更新するまで、漏洩した証明書を信頼したままになります。

0.4.0 では、2026年9月下旬〜10月22日に公表されたものから、Mac で確かめられるものを足しました。修正版はどれも、配布元や CISA・NVD などの一次資料で確かめた値です。

- **GitLab**（CVE-2026-110264、CVSS 10.0。2026-10-21 公表）。修正版は 19.5.1 / 19.4.3 / 19.3.6 / 19.2.9 / 19.1.9 / 19.0.10 / 18.11.13 です。
- **Java**（Oracle の 2026年10月の定例更新。Java SE に 55件）。修正版は 8u511（OpenJDK 系は 8u512）/ 11.0.33 / 17.0.21 / 21.0.13 / 25.0.5 / 27.0.1 です。
- **macOS**（CVE-2026-86950。実際に悪用されたと Apple が公表）。修正版は Sequoia 15.8.1 / Tahoe 26.7.1 です。
- **Plex Media Server**（通称 Plex2Shell。4件とも悪用が確認済み）。修正版は 1.43.3.10861 です。
- **Claude Desktop・Claude Code・Chrome・Firefox・Homebrew の curl と OpenSSL** の安全修正。
- **侵害されたパッケージと GitHub Actions**（LiteLLM・Tensorlake・MALFEX・PhantomSub など、配布物そのものに悪意のあるコードが入っていたもの）。

0.4.1 では、次の2件を足しました。

- **Python の pip・certifi・uv**（eMudhra の件の続き。Python 公式の告知は 2026-10-20）。修正版は pip 26.2.2 / certifi 2026.10.19 / uv 0.13.4 です。pip は自分の中に証明書リストを持っていて、それを外す方法がありません。このため、macOS や certifi を更新しても、pip が古いままだと漏洩した証明書を信頼し続けます。Python ごと、作業用の環境（venv）ごとに更新が必要です。
- **Homebrew の BIND**（CVE-2026-94300。DNS サーバーの `named` の穴。2026-10-21 公表）。修正版は 9.20.30 / 9.21.27 です。

0.4.3 では、**Homebrew の brotli**（CVE-2026-111497。通信の圧縮形式 Brotli を展開する部品の穴で、Node.js・Python・curl などに広がりました。2026-10-21 公表）の最低版 1.2.1 / 1.1.1 / 1.0.10 を足しました。Python で `brotli`・`brotlicffi` を使っている場合は、1.2.1 以上へ上げてください。

0.4.4 では、同じ Brotli の穴（通称 HTTP2Shell）の残りを足しました。

- **Python の `brotli`・`brotlicffi`**（1.2.1 / 1.2.1.0 より古いもの）。Homebrew が道具ごとに持っている専用の Python 環境（たとえば `yt-dlp` の中）も見ます。Homebrew がまだ直していないときは、その旨を添えて知らせます。
- **Bun**（1.4.4 より古いもの）。同梱の Brotli と、証明書リスト（eMudhra）の両方が直った版です。
- **Electron 製のアプリ**（Slack・Discord・1Password・ChatGPT・Obsidian など）。アプリごとの修正版は公表されていないため、Brotli の修正（2026-10-21）より前に更新されたままのアプリを「参考」に並べます。アプリの「更新を確認」で最新にしてください。

0.5.0 では、脆弱性の有無にかかわらず、**入っているソフトが最新かどうか**を見るようにしました。Homebrew で入れたもの、Homebrew を使わずに入れたアプリ、App Store のアプリ、npm で入れた道具（`npm i -g`）が対象です。更新が出ているものは「参考」に並べ、同じ更新が14日以上残ったときだけ WARN にします。あわせて、CLI と npm の道具の上げ先を「公開から3日以上たった版」に変えました。出たばかりの版は、不具合や乗っ取りが見つかって取り下げられることがあるためです。

0.5.1 では、次の2件を足しました。

- **Chrome**（2026-10-27 に 52 件、2026-10-29 に 21 件の安全修正。どちらも Critical を含みます）。修正版は 156.0.8078.79 です。Chrome を再起動すると更新されます。
- **Homebrew の Ruby**（CVE-2026-97229 ほか。正規表現の部品の穴で、GitLab での悪用を CISA が確認しています。2026-10-23 公表）。修正版は 4.0.9 / 3.4.12 / 3.3.13 です。影響があるのは、外から受け取った文字列を正規表現にするプログラムを動かしている場合です。

### 何を見るか

1. **Homebrew のセキュリティ部品の更新待ち** — 証明書リスト（ca-certificates）、openssl、curl、git、openssh、node、python、php など、セキュリティに関わる部品に更新が出ていないかを見ます。対象の一覧は同梱の `config/security-packages.txt` です。Homebrew を使っていない Mac では、この点検は行いません。
2. **部品とアプリの最低版** — 表は同梱の `config/security-minimums.tsv` です。
   - **PHP**: Mac にある `php` と `php-fpm` の版が、上の修正版より古くないか、サポートが終わった系列（8.1 以前）でないかを見ます。PHP がサーバーとして動いている（接続を待ち受けている）ときは FAIL、そうでなければ WARN です。Apache は PHP を読み込んでいるときだけ数えます。管理者権限で動いているサーバーは見えないことがあるため、その場合は WARN になります。
   - **Node.js**: Mac にある `node` の版が、上の修正版より古くないか、サポートが終わった系列（21 以前・23・25）でないかを見ます。Homebrew の `node@24` のように普段の呼び出し先に入っていないものや、nvm で入れたものも見ます。Node.js は WARN です。直し方は入れ方に合わせて出します（例: `brew upgrade node@24`）。
   - **Java**: Mac にある JDK（`/Library/Java/JavaVirtualMachines`、Homebrew の `openjdk`、SDKMAN）の版を、JDK に同梱の `release` ファイルから読みます。`java` コマンドは動かしません。修正版より古いもの、サポートが終わった系列（26 や 22〜24 などの非 LTS）は WARN です。
   - **GitLab**: この Mac の Docker で `gitlab/gitlab-ce`・`gitlab/gitlab-ee` を動かしている場合に、イメージの版を見ます。修正版より古いものが動いていれば FAIL、止まっているだけなら WARN です。リポジトリの置き場が自社の GitLab らしいときは、サーバーの更新を確かめるよう「参考」に1回だけ出します。
   - **macOS**: 修正版より古い版、修正版が出ていない系列（Sonoma 14 以前）は WARN です。
   - **アプリ**: `/Applications` などにある Claude・Chrome・Firefox・Plex Media Server の版を、アプリの中の `Info.plist` から読みます。アプリは起動しません。修正版より古ければ WARN、Plex Media Server だけは動いていれば FAIL です。Firefox ESR は対象外です。
   - **Claude Code と Homebrew の curl・OpenSSL・BIND・brotli**: 修正版より古ければ WARN です。Homebrew の「更新待ち」の WARN と同じものは、1件にまとめます。
   - **Python の pip・certifi・uv**: Homebrew・python.org・pyenv・pipx・conda などで入れた Python と、リポジトリの中の作業用の環境（`.venv` など）を見ます。版は、それぞれの中のファイルから読みます。Python は動かしません。修正版より古ければ WARN です。直し方には、Python 公式の告知と同じ「ファイルの指紋（sha256）つき」の入れ方を添えます。古い pip で更新しても、途中ですり替えられないためです。指紋つきの URL は同梱の `config/python-pins.tsv` にあります。Python 3.9 以前では修正版の pip が入らないため、pip は「参考」に出します。そこにある certifi は WARN です。Mac に最初から入っている python3（Apple の管理物）は、「参考」だけに出します。uv の CLI（Homebrew・`~/.local/bin` など）も見ます。Docker のイメージの中は見ません。イメージを使っている場合は、キャッシュを使わずに作り直してください。
3. **composer の依存** — `composer.lock` があるリポジトリで `composer audit` を実行し、本番依存の脆弱性を見ます。npm の依存と同じく、critical/high は FAIL です。
4. **失効済みの証明書を信頼していないか** — Node、curl、python3 が、漏洩した証明書を使った確認用のテスト先へつながってしまうかを試します。つながった道具は、その証明書をまだ信頼しているということです。
5. **macOS のアップデート待ち** — macOS やセキュリティ関連のアップデートが出ていないかを見ます。
6. **kit 自身の新しい版** — 公開リポジトリの版番号と比べ、新しい版が出ていれば知らせます。版が新しくなると、点検の中身（テスト先や最低版の表）も新しくなるためです。
7. **侵害されたパッケージと GitHub Actions**（リポジトリごと） — 同梱の `config/pkg-denylist.tsv` と照らし合わせ、侵害が確認された npm・PyPI のパッケージが lock ファイルに入っていれば FAIL です。版を問わず名前だけで当たるもの（`*`）と、Python の lock（`requirements*.txt`・`poetry.lock`・`uv.lock`・`Pipfile.lock`）にも対応しました。`.github/workflows` で侵害された GitHub Actions（`config/actions-denylist.tsv`）を使っていれば、これも FAIL です。
8. **入っているソフトの更新待ち**（0.5.0〜） — 次の4つを見て、更新が出ているものを「参考」に並べます。同じ更新が14日以上残ったときは WARN にします。
   - **Homebrew**: `brew outdated --greedy` で、自分で更新するアプリも含めて見ます。版を固定したもの（`brew pin`）は外します。アプリが自分で更新済みで、Homebrew の記録だけ古いものは数えません。アプリを消したのに Homebrew の記録だけ残っているものは、記録の消し方（`brew uninstall --cask`）を「参考」に添えます。
   - **Homebrew を使わずに入れたアプリ**: `/Applications` などにあるアプリの版を `Info.plist` から読み、Homebrew の公開目録（cask の一覧）に載っている版と比べます。目録の版は参考値なので、直し方は「アプリの『更新を確認』から」です。アプリは起動しません。Apple 純正のアプリと App Store のアプリは、ここでは比べません。
   - **App Store のアプリ**: `mas` が入っていれば `mas outdated` で見ます。入っていなければ「未検査」と残します（`brew install mas` で点検に入ります）。
   - **npm で入れた道具**: `npm outdated -g` で見ます。上げ先は、公開から3日以上たった版のうち、npm の正式版（`latest`）までです。3日たっていない版しかないときは、待つ旨を点検詳細に残します。

   CLI の更新確認も行うとき（`RH_SECURITY_ONLY=0` で `RH_SKIP_CLI=0`）は、Claude Code・Codex・Node.js・npm・gh・Vercel・Supabase・1Password CLI を、同じものを2度出さないよう、ここでは数えません。Homebrew のセキュリティ部品として WARN に出したものも、重ねて出しません。

### 何を自動で直すか

- **証明書リスト（ca-certificates）** は、Homebrew に更新が出ていれば、初期設定で自動更新します。データだけの部品なので、既定で自動にしています。止める場合は `RH_AUTOFIX_CA_CERTS=0` にします。
- **それ以外のセキュリティ部品**（node、python、openssl、curl、php など）は、`RH_AUTOFIX_SECURITY=1` のとき `brew upgrade` します。Node や Python の版が上がると、開発中のアプリの動きが変わることがあるため、初期値は 0（自動更新しない）です。0 のままなら、更新待ちの部品は WARN 1件にまとめて届きます。
- 最低版の点検（PHP・Node.js・Java・GitLab・macOS・アプリなど）、composer の依存、macOS のアップデートでは、自動では直しません（Homebrew の php と node は、`RH_AUTOFIX_SECURITY=1` のとき上の更新に含まれます）。WARN や FAIL の文に、直し方の手がかりを添えます。
- 自動更新の前に依存関係を確認します。自動更新を止めているセキュリティ部品、`RH_SOFTWARE_IGNORE` に書いたもの、pin 中の部品を依存先として一緒に上げる候補は、更新せず WARN で知らせます。依存元の自動更新も抑えます。Homebrew がほかの部品を更新した場合は、前後の導入済み版を比べて「（巻き込みで更新）」と記録します。
- **入っているソフト**は、`RH_AUTOFIX_SOFTWARE=1` のときだけ、Homebrew の formula と、画面のあるアプリを持たない cask（フォントなど）を `brew upgrade` します。初期値は 0（自動更新しない）です。画面のあるアプリ、管理者のパスワードが要る pkg 形式のもの（zoom・Google Drive など）、App Store、npm の道具は、自動では更新しません。更新のあとに Homebrew の node（`node`・`node@24` など）が起動しなくなったときは、その formula を `brew upgrade`、だめなら `brew reinstall` で1回だけ直し、それでも起動しなければ WARN でお知らせします。
- **同じ版の作り直し**（例: `26.13.1_1` → `26.13.1_2`）は、`RH_AUTOFIX_SOFTWARE=1` ならセキュリティ部品にも当て、「（同じ版の作り直し）」と記録します。`RH_AUTOFIX_SECURITY` の初期値は 0 のままです。pin 中の部品は更新待ちの WARN から外し、「pin 中」と参考に残します。
- 更新した formula と、それを使う導入済みの formula は、部品の参照が壊れていないかも確認します。起動確認で2回続けて失敗した Node.js や、参照が壊れた formula は、自動更新が有効なら upgrade → reinstall を1回試します。修復後はすべての Homebrew の Node.js をもう一度確認します。点検には1部品60秒・合計600秒の上限があり、確認できなかったものは「未検査」に残します。
- 自動で更新したものは、レポートの「自動で直したもの」に載ります。自動更新に失敗したときは WARN でお知らせします。

### 外部へ接続するところ

- **証明書の点検**: 点検のたびに、確認用に公開されているテスト先（`dv-g3b-emudhra.we-have-a-problem.com` など2件。出典は [emudhra.we-have-a-problem.com](https://emudhra.we-have-a-problem.com/)）へ、手元の道具ごとに1回ずつ接続します。初期設定では、多くて10回（道具5つ × テスト先2件）です。応答があったかどうかだけを見て、ページの中身は読みません。止める場合は `RH_TLS_PROBE=0` にします。
- **新しい版の確認**: `raw.githubusercontent.com` から、版番号だけを書いたファイル `VERSION` を読みます。止める場合は `RH_KIT_UPDATE_CHECK=0` にします。
- **入っているソフトの更新確認**: Homebrew の公開目録 `https://formulae.brew.sh/api/cask.json` を読みます。目録は手元に保存し、20時間たつまでは読み直しません。読めないときは、7日以内に保存したものを使います。npm の道具は、版ごとの公開日時を npm の公開サーバーから読みます。App Store は `mas` が Apple へ問い合わせます。
- **そのほか**: Homebrew の更新情報（`brew update`）、macOS のアップデート確認（`softwareupdate -l`）、`composer audit` は、それぞれの配布元へ接続します。
- 点検結果を送る先は、設定したメールの宛先（Resend 経由）だけです。

Mac のセキュリティ点検を丸ごと止める場合は `RH_SKIP_SECURITY=1` にします。このときは、レポートの「参考」に「止めています（設定 RH_SKIP_SECURITY=1）」と残ります。

## 防御の記録（脆弱性への対応のまとめ）

五次元経営が実際に行った脆弱性への対応を、一週間ごとに `docs/defense/` へまとめています。社長が読む「まとめ」と「見分け方」に加えて、Claude Code がそのまま点検に使える手順とコマンドを載せています。新しい脆弱性の話を見かけたときは、`PROMPT.md` の「新しい脆弱性の話を聞いたとき」の枠を Claude Code に貼り付けてください。

- [2026年10月第4週・前半](docs/defense/2026-10-week4-part1.md)（eMudhra の証明書・Python の pip・Node.js・Java・PHP2Shell・GitLab・BIND・LiteLLM・Next.js・問い合わせフォーム）

## 届いたメールの読み方

メールは、FAIL か WARN があるときに届きます。送れなかった回は目印を保存し、画面にも通知します。次に送れるメールの先頭には「前回まで N 回送れませんでした」と出ます。宛先・鍵の取得方法・ネットワークを確認してください。

同じ種類の未検査が3日続くと、何日目かを添えて WARN に上げます。設定で自分から止めた点検（`RH_DATA_GUARD=0`・`RH_SKIP_AUDIT=1`・`RH_SKIP_FETCH=1`・`RH_SKIP_CLI=1`・`RH_TLS_PROBE=0`・`RH_SKIP_SOFTWAREUPDATE=1`・`RH_SKIP_SOFTWARE=1`・`RH_SKIP_SECURITY=1`・`RH_KIT_UPDATE_CHECK=0`）は、レポートに「止めています（設定 RH_…）」と書き、この WARN には上げません。応答がない・権限がないなどで本当に見られなかった点検だけを「未検査」と数えます。前回の完了から36時間より長く空いた場合も、今回の先頭で知らせます。点検全体は `RH_MAX_RUNTIME`（初期値2400秒）で打ち切り、同時起動は先に始まった1本だけが進みます。残った実行中の目印は3時間で無効になります。止まっていた間の通知は、次に点検が動いたときに届きます。

`RH_MAIL_METHOD=none` では WARN も音なしの画面通知に出ます。`RH_NO_DESKTOP=1` なら画面通知を止められます。

- `FAIL（赤）` は今日中に確認する目安です。例: detached HEAD、作業途中の merge、平文シークレット、本番依存の critical/high（npm・composer）、侵害パッケージ、侵害された GitHub Actions、サーバーとして動いている古い PHP・GitLab・Plex Media Server です。
- `WARN（黄）` は今週中に確認する目安です。例: 未push、stash、3日以上続く dirty、監査不能、CLI のメジャー版遅れ、Mac のセキュリティ部品の更新待ち、古い PHP（サーバーとして動いていないもの）、古い Node.js・Java・macOS・アプリ・Claude Code、失効済みの証明書を信頼している道具、macOS のアップデート待ち、kit の新しい版です。
- 「作業中」「同期待ち」は赤黄の対象外です。単発の dirty を異常とは決めつけません。
- 「未検査」は異常なしを意味しません。npm、Homebrew、ネットワークの状態を確認して再実行してください。
- 「参考」は、ローカルのレポート（`repo-health-latest.md`）に載り、メールの要対応には数えません。「データの守り」の参考はメールにも載ります。Apple 標準の curl と python3 についての知らせは、ここに出ます（[よくある質問](#apple-の-curl-と-python3-が失効済みの証明書をまだ信頼していると参考に出続けます)）。入っているソフトの更新も、ここに `ソフト更新: …` の形で並びます。同じ更新が14日以上残ると、WARN に上がります。

Mac のセキュリティ点検の文面は、たとえば次のようになります。版やパスは Mac ごとに変わります。

```text
FAIL  PHP 8.5.11（/opt/homebrew/bin/php）がサーバーとして動いています。CVE-2026-109618 / CVE-2026-109619（PHP2Shell・2026-10-21 公表）の修正版 8.5.12 以上へ更新してください
WARN  PHP 8.5.11（/opt/homebrew/bin/php）は修正版 8.5.12 より古い版です（CVE-2026-109618 / CVE-2026-109619）。使っていなければ brew uninstall php、使うなら修正版が出しだい brew upgrade php
WARN  Node 24.22.0（/opt/homebrew/opt/node@24/bin/node）は修正版 24.22.1 より古い版です（CVE-2026-105482 ほか（Node.js 10月の安全修正・2026-10-21 公表））。brew upgrade node@24（Homebrew に修正版が出しだい）
WARN  Mac のセキュリティ部品に更新が出ています: node 26.11.1 → 26.12.0（brew upgrade で更新できます）
WARN  Node が失効済みの証明書を信頼しています（eMudhra 中間CAの鍵漏洩）。brew upgrade node（Homebrew 以外で入れた場合はその方法で最新版）へ更新してください
WARN  macOS のアップデートが出ています: <アップデートの名前>（システム設定 → 一般 → ソフトウェアアップデート）
WARN  repo-health-kit の新しい版 <今の版> → <新しい版> があります。clone したフォルダで git pull し、./install.sh を実行してください
```

Claude Code に相談するときは、値やシークレットを貼らず、たとえば次のように頼めます。

> repo-health-latest.md の FAIL と WARN を読み、原因を調べてください。作業中の変更は消さず、修正前に影響範囲を説明してください。brew upgrade や brew uninstall で Mac の部品を変えるときも、先に何を変えるかを説明してください。

## 期限を決めて据え置く

確認済みの WARN / FAIL を一時的に参考へ移すときは、`~/.config/repo-health-kit/allow.tsv` に、タブで区切った3列を書きます。install 時に空の表を作ります。

```tsv
# 一致させる文（本文の一部）	期限 YYYY-MM-DD	理由
「local-tools」 — origin 未設定	2026-12-01	手元だけで使うため
```

例の期限は、利用時に当日から180日以内の日付へ置き換えてください。本文の一部を文字どおり照合するため、リポ名や指摘の種類まで含めると対象を絞れます。文・期限・理由はすべて必須です。期限当日まで参考（据え置き中・期限 …）に移り、要対応の件数と通知から外れます。7日前から参考に「据え置きの期限が近い」と出し、期限切れで要対応に戻します。侵害パッケージと追跡中の鍵の FAIL は据え置けず、表に一致しても FAIL と注記が残ります。利用者の設定にある `vuln-allow.tsv` による脆弱性ごとの据え置きとは別です。

`.env.production` などは、未追跡で gitignore 済みなら参考に出します。追跡中か gitignore されていない場合は「git に入るおそれのある env ファイル」として知らせ、追跡中の鍵は別途 FAIL にします。秘密の値は表示しません。

履歴ログと launchd のログは5MBを超えたら `.1` に回し、1世代だけ残します。同名のリポが複数の点検ルートにあっても、状態はフルパスの短いハッシュで区別します。既存の状態は初回に引き継ぎます。

## 設定を変える

`~/.config/repo-health-kit/config.sh` を編集します。複数の親ディレクトリや、1日複数回の時刻も指定できます。

```bash
RH_ROOTS=("$HOME/Plugins" "$HOME/仕事のリポジトリ")
RH_SCHEDULE="09:20 17:30"
RH_WARN_NONGIT=1
RH_NONGIT_IGNORE=("素材置き場")
RH_AUTOFIX_PULL=1
RH_AUTOFIX_CLI=0
```

CLI の自動更新は初期状態で無効です。有効にしたときも、npm で入れた CLI だけを、公開から3日以上たった版へ更新します。正式な latest 以下で、現在も配布され、非推奨になっていない版を選びます。取得できなければ未検査とします。npm 以外で入れた CLI は自動更新せず、現在版・上げ先・入れた方法に応じた直し方を WARN で案内します。Claude Code の公開日は npm の情報で確認します。サポート中の Node.js LTS 系列から次の LTS への案内は参考に出します。

Homebrew の formula と cask の自動更新には 3 日待ちがありません。

install は、そのときの npm の場所を `RH_NPM_DIR`、手元の clone の場所を `RH_CLONE_DIR` として設定に記録します。無人実行では、存在する fnm の default（`~/.local/share/fnm/aliases/default/bin`、無ければ `~/Library/Application Support/fnm/aliases/default/bin`）、nvm の `~/.nvm/alias/default` が指す版の bin、`RH_NPM_DIR` を PATH に加えます。シェルの初期化ファイルは実行しません。npm が見つからず飛ばした点検は未検査に残します。設定変更後に時刻を launchd へ反映するには、もう一度 `./install.sh` を実行します。

他人から受け取ったフォルダは点検ルートに置かないでください。点検時の git はファイル監視・hook・リポ固有の SSH コマンドを無効にし、composer もプラグインとスクリプトを動かさずに使います。

点検ルート直下にある git 管理外のフォルダは、点検できないので WARN で知らせます（`RH_WARN_NONGIT=1`、初期値）。空のフォルダは参考扱いで、`.` で始まるフォルダは対象外（数えない）です。
素材置き場など git 管理外でよいフォルダは `RH_NONGIT_IGNORE` に名前を書くと、WARN ではなく参考に出ます。

Mac のセキュリティ点検の設定は次の7つです。値は初期値です。設定ファイルに書いていない項目は、この初期値で動きます。変えたい項目だけを書き足してください。

```bash
RH_SECURITY_ONLY=0        # 1 で Mac のセキュリティと、侵害パッケージ・GitHub Actions の照合だけを行います（0.4.2〜）
RH_SKIP_SECURITY=0        # 1 で Mac のセキュリティ点検を丸ごと止めます
RH_AUTOFIX_CA_CERTS=1     # 証明書リスト ca-certificates を Homebrew で自動更新します。0 で止めます
RH_AUTOFIX_SECURITY=0     # 1 で node・python・openssl・php などのセキュリティ部品も自動更新します
RH_TLS_PROBE=1            # 0 で証明書の点検（テスト先への接続）を止めます
RH_SKIP_SOFTWAREUPDATE=0  # 1 で macOS のアップデート確認を止めます
RH_KIT_UPDATE_CHECK=1     # 0 で kit の新しい版の確認を止めます
```

入っているソフトの更新確認（0.5.0〜）の設定は次の4つです。値は初期値です。

```bash
RH_SKIP_SOFTWARE=0        # 1 で入っているソフトの更新確認を止めます
RH_AUTOFIX_SOFTWARE=0     # 1 で Homebrew の formula と、画面のあるアプリを持たない cask を自動更新します
RH_SOFTWARE_STALE_DAYS=14 # 同じ更新がこの日数以上残ったら WARN にします
RH_SOFTWARE_IGNORE=()     # 更新確認から外すもの。例: ("rclone" "Microsoft Word" "some-npm-package")
```

`RH_SOFTWARE_IGNORE` には、Homebrew の formula 名・cask 名、npm のパッケージ名、アプリ名（`.app` を除いた名前）を書きます。仕事で版を固定しているものや、止めている道具を書いておくと、参考にも WARN にも出なくなります。

`RH_SECURITY_ONLY=1` は、リポジトリの同期や依存の監査を別の仕組みで見ている場合に使います。このとき、リポジトリの fetch・未コミット・同期待ち・npm/composer audit・CLI の更新確認は行いません。レポートの見出しは「Mac のセキュリティ点検」、メールの件名は `[mac-security]` になります。

本番依存の critical/high を調査のうえ期限付きで据え置く場合は、`~/.config/repo-health-kit/vuln-allow.tsv` に次の形式で追記します。npm と composer の両方に効きます。初期状態は空です。2列目には GHSA の ID またはパッケージ名を書き、複数なら `,` で区切ります。一致した指摘だけを据え置き、ほかの critical/high は FAIL のまま知らせます。文面には「据え置き N 件・据え置き外 M 件」と出ます。2列目が説明文の古い行は従来どおり効きますが、移行の注記が出るため、ID・パッケージ名に書き換えてください。

```text
repo名<TAB>advisoryまたはpackage<TAB>YYYY-MM-DD<TAB>理由
```

## 新しい版に更新する

clone したフォルダで、次を実行します（PROMPT.md で入れた場合は `~/Tools/repo-health-kit`、AIFCC Workshop の受講者は `~/projects/repo-health-kit` です）。

```bash
git pull
./install.sh
```

- `install.sh` は、本体と同梱の表（テスト先・最低版など）を新しい版に入れ替え、最後にメールを送らずに一度点検します。
- 利用者の設定と据え置き表（`allow.tsv`・`vuln-allow.tsv`）は引き継ぎます。`config.sh` の npm と clone の場所だけを記録し直します。
- 新しい版で増えた設定は、書かなくても初期値で動きます。変えたい項目だけを「[設定を変える](#設定を変える)」を見て書き足してください。
- 新しい版が出ると、毎朝の点検で WARN としてお知らせします。お知らせが届いたら、この手順で更新してください。

Claude Code に任せる場合は、[PROMPT.md の「新しい版のお知らせが届いたとき」](PROMPT.md#新しい版のお知らせが届いたとき)の文面を貼り付けてください。

## 手で実行する・止める・外す

メールを送らず手で点検するには、次を実行します。

```bash
RH_NOMAIL=1 /bin/bash "$HOME/Library/Application Support/repo-health-kit/bin/repo-health.sh"
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

### Apple の python3 の pip が「古い版です」と参考に出続けます

Command Line Tools に入っている Python は 3.9 です。修正版の pip 26.2.2 は Python 3.10 以上が必要なので、この pip は上げられません。Apple の更新を待つあいだは、`/usr/bin/python3 -m pip` でネットからパッケージを入れないでください。入れる場合は、Homebrew の python3 を使ってください。

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


## データの守り（Supabase ほか）

0.7.0 では、各リポの SQL とアプリの入口をまとめて点検します。要対応は FAIL / WARN に入り、INFO / NOTE は「データの守り（Supabase ほか）」の節に載ります。この節はメールにも入り、`RH_SECURITY_ONLY=1` でも点検します。

既定でオンになるものは次のとおりです。

- migration などの SQL の RLS・方針・VIEW・DEFINER・Storage・GRANT と ORM の RLS 記述
- Supabase の共有プロジェクト、重複する表名、複数リポの migration、SQL がない利用側の確認
- ブラウザ側の秘密の変数名・client component と1段の import・`.next/static` の service_role JWT と `sb_secret_`
- git 履歴の鍵ファイル名（初回は全履歴、以後は追加分、1リポ20秒上限）
- cron / captcha の未設定時の素通り、Map の連射制限、新しく増えた認証不明の API 入口
- テナント列と方針の using の照合
- gh がありログイン済みの場合の GitHub 公開設定・Dependabot（24時間使い回し。`RH_DATA_GITHUB=0` で通信を停止）

本番への読み取りは既定でオフです。`RH_SUPABASE_CATALOG=1` と専用接続の設定で目録、`RH_SUPABASE_ANON_PROBE=1` で公開鍵の GET、`RH_SITE_URLS` で本番サイトの外形を点検できます。[詳しい手順](docs/data-guard.md)と[監査役割の作り方](docs/supabase-audit-role.md)を確認してから設定してください。

据え置きは `~/.config/repo-health-kit/data-allow.tsv`（`RH_DATA_ALLOW` で変更可）です。種類・対象・定義の md5 先頭12字（空欄可）・期限 YYYY-MM-DD・理由・所有アプリ（省略可）のタブ区切りです。[見本](config/data-allow.example.tsv)があります。期限は必須・最長180日、ハッシュを入れた行は定義が変わると効きません。SQL 内の `-- rh-allow: 理由 until YYYY-MM-DD` も使えます。RLS 無効とブラウザ側の service_role・秘密鍵は据え置けません。`RH_SUPABASE_APPS` の[所有アプリ台帳](config/supabase-apps.example.tsv)も任意で設定できます。

「migration の記述上は〜（本番は未確認）」は、ファイルから読めた事実です。本番の適用状況は確認していません。動的 SQL や別リポからの修正、ORM、教材の名前、共通の認証ヘルパーなどでは誤検知・見逃しがあります。意図した公開表は期限付きで据え置けます。RLS 有効で方針0本の全拒否は指摘しません。共有プロジェクトの「ログインした人全員」は別アプリの利用者も含むため FAIL になります。

`RH_DATA_GUARD=0` でデータの守りを丸ごと止められます（初期値は1）。止めたときは「止めています（設定 RH_DATA_GUARD=0）」と書き、未検査の WARN には上げません。`.claude`（Claude Code の作業フォルダ）と、直下に `.git` を持つ入れ子の checkout、`.vercel`・`.turbo` は、本流ではないので読みません。`dist`・`build`・`out`・`coverage` も、親のフォルダに `package.json` があるとき（リポの根・monorepo の各パッケージの根）だけ、ビルドの出力として読みません。`app/api/build/` のようなソースのフォルダは読みます。

`RH_DATA_GUARD_TIMEOUT` は初期値300秒です。終了の番兵がない・非0終了・時間切れは「未検査」の WARN にし、空出力を正常とは読みません。出力は名前・行番号・分類・定義ハッシュに限り、プロジェクト ref は先頭4字だけにします。
