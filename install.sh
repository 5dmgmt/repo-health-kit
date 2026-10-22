#!/bin/bash
# repo-health-kit を利用者の Library 配下へインストールまたは更新します。

set -uo pipefail

SCRIPT_DIR="$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/repo-health-kit"
CONFIG_DIR="$HOME/.config/repo-health-kit"
CONFIG_FILE="$CONFIG_DIR/config.sh"
LOG_DIR="$HOME/Library/Logs/repo-health-kit"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_FILE="$PLIST_DIR/com.repo-health-kit.plist"
TEMPLATE="$SCRIPT_DIR/launchd/com.repo-health-kit.plist.template"

fail() {
  printf 'インストール中止: %s\n' "$*" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "macOS 専用です"
for command_name in bash git python3 curl perl; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name が見つかりません"
done
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  printf '案内: node/npm がないため、依存脆弱性の点検は「未検査」として報告されます。\n'
fi

mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/config" "$CONFIG_DIR" "$LOG_DIR" "$PLIST_DIR" || fail "保存先を作成できません"
chmod 700 "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" 2>/dev/null || true

install -m 755 "$SCRIPT_DIR/bin/repo-health.sh" "$INSTALL_DIR/bin/repo-health.sh" || fail "本体をコピーできません"
install -m 755 "$SCRIPT_DIR/bin/pkg-denylist-scan.py" "$INSTALL_DIR/bin/pkg-denylist-scan.py" || fail "照合スクリプトをコピーできません"
install -m 644 "$SCRIPT_DIR/VERSION" "$INSTALL_DIR/VERSION" || fail "版情報をコピーできません"
install -m 644 "$SCRIPT_DIR/config/pkg-denylist.tsv" "$INSTALL_DIR/config/pkg-denylist.tsv" || fail "照合リストをコピーできません"
install -m 644 "$SCRIPT_DIR/config/security-packages.txt" "$INSTALL_DIR/config/security-packages.txt" || fail "セキュリティ部品リストをコピーできません"
install -m 644 "$SCRIPT_DIR/config/security-minimums.tsv" "$INSTALL_DIR/config/security-minimums.tsv" || fail "最低版リストをコピーできません"
install -m 644 "$SCRIPT_DIR/config/tls-probes.tsv" "$INSTALL_DIR/config/tls-probes.tsv" || fail "証明書点検リストをコピーできません"
install -m 644 "$SCRIPT_DIR/config/actions-denylist.tsv" "$INSTALL_DIR/config/actions-denylist.tsv" || fail "侵害された GitHub Actions のリストをコピーできません"

if [ ! -f "$CONFIG_FILE" ]; then
  install -m 600 "$SCRIPT_DIR/config/config.example.sh" "$CONFIG_FILE" || fail "設定ファイルを作成できません"
  printf '設定を作成しました: %s\n' "$CONFIG_FILE"
else
  printf '既存の設定は上書きしません: %s\n' "$CONFIG_FILE"
fi
chmod 600 "$CONFIG_FILE"

VULN_ALLOW_FILE="$CONFIG_DIR/vuln-allow.tsv"
if [ ! -f "$VULN_ALLOW_FILE" ]; then
  install -m 600 "$SCRIPT_DIR/config/vuln-allow.example.tsv" "$VULN_ALLOW_FILE" || fail "据え置き設定を作成できません"
fi

owner="$(stat -f '%u' "$CONFIG_FILE" 2>/dev/null)" || fail "設定ファイルの所有者を確認できません"
mode="$(stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null)" || fail "設定ファイルの権限を確認できません"
[ "$owner" = "$(id -u)" ] || fail "設定ファイルの所有者が現在の利用者ではありません"
case "$mode" in *[2367][0-9]|*[2367]) fail "設定ファイルが group/other から書き込み可能です";; esac

RH_SCHEDULE="09:20"
RH_MAIL_METHOD="none"
ENV_SKIP_AUDIT_SET="${RH_SKIP_AUDIT+x}"; ENV_SKIP_AUDIT_VALUE="${RH_SKIP_AUDIT-}"
ENV_SKIP_CLI_SET="${RH_SKIP_CLI+x}"; ENV_SKIP_CLI_VALUE="${RH_SKIP_CLI-}"
ENV_SKIP_SECURITY_SET="${RH_SKIP_SECURITY+x}"; ENV_SKIP_SECURITY_VALUE="${RH_SKIP_SECURITY-}"
ENV_SKIP_FETCH_SET="${RH_SKIP_FETCH+x}"; ENV_SKIP_FETCH_VALUE="${RH_SKIP_FETCH-}"
ENV_NO_DESKTOP_SET="${RH_NO_DESKTOP+x}"; ENV_NO_DESKTOP_VALUE="${RH_NO_DESKTOP-}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
[ -z "$ENV_SKIP_AUDIT_SET" ] || RH_SKIP_AUDIT="$ENV_SKIP_AUDIT_VALUE"
[ -z "$ENV_SKIP_CLI_SET" ] || RH_SKIP_CLI="$ENV_SKIP_CLI_VALUE"
[ -z "$ENV_SKIP_SECURITY_SET" ] || RH_SKIP_SECURITY="$ENV_SKIP_SECURITY_VALUE"
[ -z "$ENV_SKIP_FETCH_SET" ] || RH_SKIP_FETCH="$ENV_SKIP_FETCH_VALUE"
[ -z "$ENV_NO_DESKTOP_SET" ] || RH_NO_DESKTOP="$ENV_NO_DESKTOP_VALUE"

python3 - "$TEMPLATE" "$PLIST_FILE" "$HOME" "$INSTALL_DIR/bin/repo-health.sh" "$LOG_DIR/repo-health-launchd.log" "$RH_SCHEDULE" <<'PY'
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

template_path, output_path, home, program, log_path, schedule = sys.argv[1:]
entries = []
for value in schedule.split():
    match = re.fullmatch(r"([01][0-9]|2[0-3]):([0-5][0-9])", value)
    if not match:
        raise SystemExit(f"RH_SCHEDULE の時刻が不正です: {value}")
    hour, minute = (int(part) for part in match.groups())
    entries.append(
        "    <dict><key>Hour</key><integer>"
        f"{hour}</integer><key>Minute</key><integer>{minute}</integer></dict>"
    )
if not entries:
    raise SystemExit("RH_SCHEDULE に時刻がありません")
text = Path(template_path).read_text(encoding="utf-8")
text = text.replace("__HOME__", escape(home))
text = text.replace("__PROGRAM_PATH__", escape(program))
text = text.replace("__LAUNCH_LOG_PATH__", escape(log_path))
text = text.replace("<!--__SCHEDULE_ENTRIES__-->", "\n".join(entries))
Path(output_path).write_text(text, encoding="utf-8")
PY
plist_rc=$?
[ "$plist_rc" -eq 0 ] || fail "launchd 設定を生成できません"
chmod 600 "$PLIST_FILE"

if [ "$RH_MAIL_METHOD" = "resend" ]; then
  printf '\nResend API キーを macOS Keychain へ登録してください。値は画面へ表示されません。\n'
  printf '  security add-generic-password -U -s repo-health-kit -a resend -w\n'
fi

if [ "${RH_NO_LAUNCHCTL:-0}" = "1" ]; then
  printf 'RH_NO_LAUNCHCTL=1 のため launchctl 登録を省略しました。\n'
else
  launchctl bootout "gui/$UID/com.repo-health-kit" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$PLIST_FILE" || fail "launchd へ登録できません"
  printf '定期点検を登録しました: %s\n' "$RH_SCHEDULE"
fi

printf '\nメールを送らずに初回点検を実行します。\n'
check_rc=0
RH_NOMAIL=1 bash "$INSTALL_DIR/bin/repo-health.sh" || check_rc=$?
if [ "$check_rc" -ne 0 ]; then
  printf '初回点検で FAIL が見つかりました。上のレポートを確認してください。\n'
fi
printf 'インストールが完了しました。設定: %s\n' "$CONFIG_FILE"
