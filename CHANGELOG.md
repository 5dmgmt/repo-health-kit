# Changelog

## Unreleased

- clone 先の例に `~/projects/` を併記しました（AIFCC Workshop 向け）。

## 0.5.1 - 2026-10-31

- Chrome の最低版を 156.0.8078.79 に上げました（2026-10-27 と 2026-10-29 の安全修正）。
- Homebrew の Ruby（`ruby`・`ruby@3.4`・`ruby@3.3`）の最低版 4.0.9 / 3.4.12 / 3.3.13 を点検します（CVE-2026-97229 ほか）。

## 0.5.0 - 2026-10-25

- Homebrew、Homebrew 管理外のアプリ、Mac App Store、npm のグローバルパッケージについて、入っているソフトの更新待ちを点検するようにしました。
- 同じ更新が14日以上残った場合の WARN、自動更新できる Homebrew 項目の安全な更新、npm と CLI の公開後3日待ちに対応しました。
- セキュリティ専用出力とメールの参考欄に、ソフト更新の件数と内容を追加しました。
- npm の上げ先は、公開から3日以上たった版のうち npm の正式版（`latest`）までにしました。正式版にならずに見送られた版は選びません。
- pkg 形式の cask（zoom・Google Drive など）は、管理者のパスワードが要るため自動更新しません。アプリ名が目録の削除欄にしか載っていない cask（zoom）と、表示版とビルド番号の書式が違うアプリ（Microsoft Office）も正しく比べます。
- Homebrew のセキュリティ部品として WARN に出したものは、ソフト更新に重ねて出しません。

## 0.4.3 - 2026-10-23

- 点検ルート直下の git 管理外のフォルダを WARN で知らせます（`RH_WARN_NONGIT`、初期値 1）。空のフォルダ・隠しフォルダ・`RH_NONGIT_IGNORE` に書いた名前は参考扱いです。これまでは黙って飛ばしていました。

## 0.4.2 - 2026-10-23

- `RH_SECURITY_ONLY=1` で、Mac のセキュリティ点検と、侵害パッケージ・侵害 GitHub Actions の照合だけを動かせるようにしました。fetch・同期・audit・CLI の更新確認はしません。リポが0件でも FAIL にしません。件名は `[mac-security]` です。

## 0.4.1 - 2026-10-23

- Python の pip 26.2.2・certifi 2026.10.19・uv 0.13.4 の最低版を点検します（eMudhra の件の Python 版）。site-packages のファイルを読むだけで、Python は動かしません。
- 直し方として、sha256 付きの URL の表 `config/python-pins.tsv` を配ります。
- Homebrew の bind（CVE-2026-94300）の最低版 9.20.30 / 9.21.27 を点検します。

## 0.4.0 - 2026-10-22

- Java の系列ごとの最低版と、サポート終了系列を点検します。
- Docker 上の GitLab CE/EE と、自社運用の可能性がある GitLab の置き場を点検します。
- 最低版の判定表に、未掲載の系列へ適用する `*` 行を追加しました。
- 版の比較を4桁まで行うようにしました。
- macOS（CVE-2026-86950・CISA KEV）の系列ごとの最低版と、修正版が出ていない系列を点検します。
- Claude Code の CLI（2.1.260 未満）を点検します。CLI の更新確認と同じ話は WARN を 1 件にまとめます。
- /Applications などのアプリを Info.plist だけで点検します（Chrome・Firefox・Claude Desktop・Plex Media Server。アプリは起動しません）。Firefox ESR は対象外、動いている古い Plex Media Server は FAIL にします。
- Homebrew の curl と openssl@3 を系列ごとの最低版で点検します。セキュリティ部品の更新待ちの WARN と同じ formula は 1 件にまとめます。
- 最低版の判定表に、部品名 `macos`・`claude`・`app:<バンドル ID>`・`brew:<formula>` を追加しました。
- 侵害パッケージの照合リストで、版の列 `*`（その名前なら全版）と `pypi:`（Python。追跡中の requirements*.txt・poetry.lock・uv.lock・Pipfile.lock）を使えるようにしました。LiteLLM・Tensorlake・MemTensor・MALFEX・Apex Accelerator・PhantomSub（101 件）を追加しました。
- 追跡中の GitHub Actions の workflow から、侵害された Action（`config/actions-denylist.tsv`）の利用を FAIL で知らせます。
- GitLab のサポート終了の文が、表の EOL 行の系列の最低版を使うように直しました。

## 0.3.0 - 2026-10-22

- Node.js の系列ごとの最低版を点検し、古い修正版とサポート終了系列を知らせます。
- 最低版の判定表に、系列全体のサポート終了を表す `EOL` を追加しました。

## 0.2.0 - 2026-10-22

- Homebrew のセキュリティ部品と PHP の最低版を点検し、証明書リストを安全な範囲で自動更新します。
- CLI が失効済み証明書を信頼していないか、macOS と kit 自身に更新がないかを点検します。
- PHP リポジトリの `composer.lock` を対象に、本番依存の脆弱性を点検します。
- セキュリティ点検用の設定、判定表、偽コマンドだけで完結する回帰テストを追加しました。

## 0.1.0 - 2026-10-19

- Mac 1台向けの日次リポジトリ点検を追加しました。
- git、依存脆弱性、平文シークレット、侵害パッケージ、主要 CLI を点検します。
- Resend、macOS 通知、launchd による通知と定期実行に対応しました。
