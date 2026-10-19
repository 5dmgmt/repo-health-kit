#!/bin/bash
# repo-health-kit の設定例です。このファイルにシークレットを書かないでください。
# 本体が source して読む設定なので、ここでは「未使用の変数」の指摘を止めます。
# shellcheck disable=SC2034

# 点検する親ディレクトリです。直下の git リポジトリを点検します。複数指定できます。
RH_ROOTS=("$HOME/Plugins")

# メール送信方法です。resend または none を指定します。
RH_MAIL_METHOD="none"

# Resend の差出人です。初期値は Resend の登録アドレス宛だけに送れる試用用です。
RH_MAIL_FROM="onboarding@resend.dev"

# 通知先メールアドレスです。RH_MAIL_METHOD=resend の場合は必須です。
RH_MAIL_TO=""

# 1Password を使う場合だけ op:// 参照を書きます。値そのものは書きません。
RH_RESEND_KEY_OP=""

# clean かつ behind のリポを git pull --ff-only で同期します。止める場合は 0 です。
RH_AUTOFIX_PULL=1

# CLI のメジャー版遅れを自動更新します。初期値は安全のため 0 です。
RH_AUTOFIX_CLI=0

# fetch 失敗を FAIL にする連続日数です。
RH_FETCH_FAIL_DAYS=2

# dirty を WARN にする連続日数です。単発の dirty は作業中として扱います。
RH_DIRTY_DAYS_WARN=3

# .git の容量と、前回からの増加量の WARN 閾値（MB）です。
RH_GIT_MB_WARN=1000
RH_GIT_GROWTH_MB=100

# behind と dirty が同時に続く状態を FAIL にする閾値です。
RH_STALE_BEHIND_THRESHOLD=20
RH_STALE_DAYS_FAIL=7

# launchd の起動時刻です。半角スペース区切りで複数指定できます。
RH_SCHEDULE="09:20"

# 通常は 0 のままです。手動検証で外部通信を止める場合だけ 1 にします。
RH_SKIP_AUDIT=0
RH_SKIP_CLI=0
RH_SKIP_FETCH=0

# 自動テストなどでデスクトップ通知も止める場合だけ 1 にします。
RH_NO_DESKTOP=0
