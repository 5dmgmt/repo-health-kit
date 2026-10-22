#!/bin/bash
# 本体と launchd 登録を外します。設定・ログ・状態は残します。

set -uo pipefail

INSTALL_DIR="$HOME/Library/Application Support/repo-health-kit"
PLIST_FILE="$HOME/Library/LaunchAgents/com.repo-health-kit.plist"

if [ "${RH_NO_LAUNCHCTL:-0}" != "1" ] && command -v launchctl >/dev/null 2>&1; then
  launchctl bootout "gui/$UID/com.repo-health-kit" >/dev/null 2>&1 || true
fi

rm -f "$PLIST_FILE"
rm -f "$INSTALL_DIR/bin/repo-health.sh" "$INSTALL_DIR/bin/pkg-denylist-scan.py"
rm -f "$INSTALL_DIR/VERSION"
rm -f "$INSTALL_DIR/config/pkg-denylist.tsv" "$INSTALL_DIR/config/security-packages.txt"
rm -f "$INSTALL_DIR/config/security-minimums.tsv" "$INSTALL_DIR/config/tls-probes.tsv"
rm -f "$INSTALL_DIR/config/actions-denylist.tsv"
rmdir "$INSTALL_DIR/bin" "$INSTALL_DIR/config" 2>/dev/null || true
rmdir "$INSTALL_DIR" 2>/dev/null || true

printf 'repo-health-kit の本体と定期起動を外しました。\n'
printf '設定・ログ・状態は残しています。削除場所は README を確認してください。\n'
