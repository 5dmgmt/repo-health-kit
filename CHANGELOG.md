# Changelog

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
