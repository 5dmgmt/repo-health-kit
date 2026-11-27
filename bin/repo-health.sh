#!/bin/bash
# Mac 1台の git リポジトリを点検し、安全に直せる同期だけを自動修復します。

set -uo pipefail

export PATH="$PATH:$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_TERMINAL_PROMPT=0
export npm_config_update_notifier=false

SCRIPT_DIR="$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)"
KIT_DIR="$(unset CDPATH; cd -- "$SCRIPT_DIR/.." && pwd)"

fatal() {
  printf 'FATAL: %s\n' "$*" >&2
  exit 1
}

clean_text() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

# 外から来た名前は、本文の区切りと混ざらないよう引用して表示します。
quote_name() {
  local value
  value="$(clean_text "$1")"
  python3 -c 'import sys; print("「" + sys.argv[1][:120] + "」", end="")' "$value"
}

# シェルの初期化を実行せず、既定の Node 環境だけを探します。
add_node_paths() {
  local candidate alias version prefix nvm_root="$HOME/.nvm" depth=0
  candidate="$HOME/.local/share/fnm/aliases/default/bin"
  [ -d "$candidate" ] || candidate="$HOME/Library/Application Support/fnm/aliases/default/bin"
  [ ! -d "$candidate" ] || PATH="$PATH:$candidate"
  alias=default
  while [ -f "$nvm_root/alias/$alias" ] && [ "$depth" -lt 8 ]; do
    IFS= read -r alias < "$nvm_root/alias/$alias" || true
    depth=$((depth + 1))
  done
  case "$alias" in
    v[0-9]*|[0-9]*)
      prefix="${alias#v}"
      version="$(find "$nvm_root/versions/node" -mindepth 1 -maxdepth 1 -type d -name "v$prefix*" 2>/dev/null | python3 -c '
import re, sys
prefix = sys.argv[1]
items = [s.strip() for s in sys.stdin if re.search(r"/v[0-9]+(?:\.[0-9]+)*$", s.strip()) and (s.strip().rsplit("/v", 1)[1] == prefix or s.strip().rsplit("/v", 1)[1].startswith(prefix + "."))]
def key(s): return tuple(map(int, s.rsplit("/v", 1)[1].split(".")))
print(max(items, key=key) if items else "")' "$prefix")"
      [ ! -d "$version/bin" ] || PATH="$PATH:$version/bin"
      ;;
  esac
  [ ! -d "${RH_NPM_DIR:-/nonexistent}" ] || PATH="$PATH:$RH_NPM_DIR"
  export PATH
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

file_owner() {
  stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

check_config_safety() {
  local path="$1" owner mode
  owner="$(file_owner "$path")" || fatal "設定ファイルの所有者を確認できません: $path"
  mode="$(file_mode "$path")" || fatal "設定ファイルの権限を確認できません: $path"
  if [ "$owner" != "$(id -u)" ]; then
    fatal "設定ファイルの所有者が現在の利用者ではないため読みません: $path"
  fi
  case "$mode" in
    *[2367][0-9]|*[2367])
      fatal "設定ファイルの権限が安全でないため読みません（group/other 書き込み可）: $path"
      ;;
  esac
}

# 環境変数で明示したテスト用スイッチと対象ルートは、設定ファイルより優先します。
RH_ENV_ROOTS_SET="${RH_ROOTS+x}"; RH_ENV_ROOTS_VALUE="${RH_ROOTS-}"
RH_ENV_SKIP_AUDIT_SET="${RH_SKIP_AUDIT+x}"; RH_ENV_SKIP_AUDIT_VALUE="${RH_SKIP_AUDIT-}"
RH_ENV_SKIP_CLI_SET="${RH_SKIP_CLI+x}"; RH_ENV_SKIP_CLI_VALUE="${RH_SKIP_CLI-}"
RH_ENV_SKIP_SECURITY_SET="${RH_SKIP_SECURITY+x}"; RH_ENV_SKIP_SECURITY_VALUE="${RH_SKIP_SECURITY-}"
RH_ENV_SKIP_FETCH_SET="${RH_SKIP_FETCH+x}"; RH_ENV_SKIP_FETCH_VALUE="${RH_SKIP_FETCH-}"
RH_ENV_NO_DESKTOP_SET="${RH_NO_DESKTOP+x}"; RH_ENV_NO_DESKTOP_VALUE="${RH_NO_DESKTOP-}"
RH_ENV_SECURITY_ONLY_SET="${RH_SECURITY_ONLY+x}"; RH_ENV_SECURITY_ONLY_VALUE="${RH_SECURITY_ONLY-}"
RH_ENV_SKIP_SOFTWARE_SET="${RH_SKIP_SOFTWARE+x}"; RH_ENV_SKIP_SOFTWARE_VALUE="${RH_SKIP_SOFTWARE-}"
RH_ENV_AUTOFIX_SOFTWARE_SET="${RH_AUTOFIX_SOFTWARE+x}"; RH_ENV_AUTOFIX_SOFTWARE_VALUE="${RH_AUTOFIX_SOFTWARE-}"
RH_ENV_SOFTWARE_STALE_DAYS_SET="${RH_SOFTWARE_STALE_DAYS+x}"; RH_ENV_SOFTWARE_STALE_DAYS_VALUE="${RH_SOFTWARE_STALE_DAYS-}"
RH_ENV_SOFTWARE_IGNORE_SET="${RH_SOFTWARE_IGNORE+x}"; RH_ENV_SOFTWARE_IGNORE_VALUE="${RH_SOFTWARE_IGNORE-}"
RH_ENV_SOFTWARE_SKIP_TOOLS_SET="${RH_SOFTWARE_SKIP_TOOLS+x}"; RH_ENV_SOFTWARE_SKIP_TOOLS_VALUE="${RH_SOFTWARE_SKIP_TOOLS-}"
RH_ENV_DATA_GUARD_TIMEOUT_SET="${RH_DATA_GUARD_TIMEOUT+x}"; RH_ENV_DATA_GUARD_TIMEOUT_VALUE="${RH_DATA_GUARD_TIMEOUT-}"
RH_ENV_DATA_GUARD_SCANNER_SET="${RH_DATA_GUARD_SCANNER+x}"; RH_ENV_DATA_GUARD_SCANNER_VALUE="${RH_DATA_GUARD_SCANNER-}"
RH_ENV_DATA_ALLOW_SET="${RH_DATA_ALLOW+x}"; RH_ENV_DATA_ALLOW_VALUE="${RH_DATA_ALLOW-}"
RH_ENV_DATA_GITHUB_SET="${RH_DATA_GITHUB+x}"; RH_ENV_DATA_GITHUB_VALUE="${RH_DATA_GITHUB-}"
RH_ENV_DATA_GUARD_SET="${RH_DATA_GUARD+x}"; RH_ENV_DATA_GUARD_VALUE="${RH_DATA_GUARD-}"
RH_ENV_SUPABASE_APPS_SET="${RH_SUPABASE_APPS+x}"; RH_ENV_SUPABASE_APPS_VALUE="${RH_SUPABASE_APPS-}"
RH_ENV_SUPABASE_CATALOG_SET="${RH_SUPABASE_CATALOG+x}"; RH_ENV_SUPABASE_CATALOG_VALUE="${RH_SUPABASE_CATALOG-}"
RH_ENV_SUPABASE_CATALOG_REFS_SET="${RH_SUPABASE_CATALOG_REFS+x}"; RH_ENV_SUPABASE_CATALOG_REFS_VALUE="${RH_SUPABASE_CATALOG_REFS-}"
RH_ENV_SUPABASE_CATALOG_KEYCHAIN_SET="${RH_SUPABASE_CATALOG_KEYCHAIN+x}"; RH_ENV_SUPABASE_CATALOG_KEYCHAIN_VALUE="${RH_SUPABASE_CATALOG_KEYCHAIN-}"
RH_ENV_SUPABASE_ANON_PROBE_SET="${RH_SUPABASE_ANON_PROBE+x}"; RH_ENV_SUPABASE_ANON_PROBE_VALUE="${RH_SUPABASE_ANON_PROBE-}"
RH_ENV_SITE_URLS_SET="${RH_SITE_URLS+x}"; RH_ENV_SITE_URLS_VALUE="${RH_SITE_URLS-}"
if [ -z "$RH_ENV_ROOTS_SET" ]; then
  # 設定に RH_ROOTS が無いときの既定は、~/Plugins と ~/projects のうち存在するもの（両方あれば両方）です。
  # どちらも無ければ ~/Plugins のままにし、「対象リポが0件です」の案内を出します。
  RH_ROOTS=()
  for rh_default_root in "$HOME/Plugins" "$HOME/projects"; do
    [ ! -d "$rh_default_root" ] || RH_ROOTS[${#RH_ROOTS[@]}]="$rh_default_root"
  done
  [ "${#RH_ROOTS[@]}" -gt 0 ] || RH_ROOTS=("$HOME/Plugins")
fi
: "${RH_MAIL_METHOD:=none}"
: "${RH_MAIL_FROM:=onboarding@resend.dev}"
: "${RH_MAIL_TO:=}"
: "${RH_RESEND_KEY_OP:=}"
: "${RH_AUTOFIX_PULL:=1}"
: "${RH_AUTOFIX_CLI:=0}"
: "${RH_FETCH_FAIL_DAYS:=2}"
: "${RH_DIRTY_DAYS_WARN:=3}"
: "${RH_WARN_NONGIT:=1}"
: "${RH_GIT_MB_WARN:=1000}"
: "${RH_GIT_GROWTH_MB:=100}"
: "${RH_STALE_BEHIND_THRESHOLD:=20}"
: "${RH_STALE_DAYS_FAIL:=7}"
: "${RH_SKIP_AUDIT:=0}"
: "${RH_SKIP_CLI:=0}"
: "${RH_SKIP_SECURITY:=0}"
: "${RH_SKIP_FETCH:=0}"
: "${RH_AUTOFIX_CA_CERTS:=1}"
: "${RH_AUTOFIX_SECURITY:=0}"
: "${RH_TLS_PROBE:=1}"
: "${RH_SKIP_SOFTWAREUPDATE:=0}"
: "${RH_KIT_UPDATE_CHECK:=1}"
: "${RH_NOMAIL:=0}"
: "${RH_NO_DESKTOP:=0}"
: "${RH_SECURITY_ONLY:=0}"
: "${RH_SKIP_SOFTWARE:=0}"
: "${RH_AUTOFIX_SOFTWARE:=0}"
: "${RH_SOFTWARE_STALE_DAYS:=14}"
: "${RH_SOFTWARE_SKIP_TOOLS:=}"
: "${RH_MAX_RUNTIME:=2400}"

RH_CONFIG_FILE="${RH_CONFIG_FILE:-$HOME/.config/repo-health-kit/config.sh}"
if [ -f "$RH_CONFIG_FILE" ]; then
  check_config_safety "$RH_CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$RH_CONFIG_FILE"
fi
[ -z "$RH_ENV_ROOTS_SET" ] || RH_ROOTS=("$RH_ENV_ROOTS_VALUE")
[ -z "$RH_ENV_SKIP_AUDIT_SET" ] || RH_SKIP_AUDIT="$RH_ENV_SKIP_AUDIT_VALUE"
[ -z "$RH_ENV_SKIP_CLI_SET" ] || RH_SKIP_CLI="$RH_ENV_SKIP_CLI_VALUE"
[ -z "$RH_ENV_SKIP_SECURITY_SET" ] || RH_SKIP_SECURITY="$RH_ENV_SKIP_SECURITY_VALUE"
[ -z "$RH_ENV_SKIP_FETCH_SET" ] || RH_SKIP_FETCH="$RH_ENV_SKIP_FETCH_VALUE"
[ -z "$RH_ENV_NO_DESKTOP_SET" ] || RH_NO_DESKTOP="$RH_ENV_NO_DESKTOP_VALUE"
[ -z "$RH_ENV_SECURITY_ONLY_SET" ] || RH_SECURITY_ONLY="$RH_ENV_SECURITY_ONLY_VALUE"
[ -z "$RH_ENV_SKIP_SOFTWARE_SET" ] || RH_SKIP_SOFTWARE="$RH_ENV_SKIP_SOFTWARE_VALUE"
[ -z "$RH_ENV_AUTOFIX_SOFTWARE_SET" ] || RH_AUTOFIX_SOFTWARE="$RH_ENV_AUTOFIX_SOFTWARE_VALUE"
[ -z "$RH_ENV_SOFTWARE_STALE_DAYS_SET" ] || RH_SOFTWARE_STALE_DAYS="$RH_ENV_SOFTWARE_STALE_DAYS_VALUE"
if [ -n "$RH_ENV_SOFTWARE_IGNORE_SET" ]; then
  RH_SOFTWARE_IGNORE=()
  while IFS= read -r software_ignore_item; do
    [ -n "$software_ignore_item" ] && RH_SOFTWARE_IGNORE[${#RH_SOFTWARE_IGNORE[@]}]="$software_ignore_item"
  done < <(printf '%s\n' "$RH_ENV_SOFTWARE_IGNORE_VALUE" | tr ' ' '\n')
elif [ -z "${RH_SOFTWARE_IGNORE+x}" ]; then
  RH_SOFTWARE_IGNORE=()
fi
[ -z "$RH_ENV_SOFTWARE_SKIP_TOOLS_SET" ] || RH_SOFTWARE_SKIP_TOOLS="$RH_ENV_SOFTWARE_SKIP_TOOLS_VALUE"

[ -z "$RH_ENV_DATA_GUARD_TIMEOUT_SET" ] || RH_DATA_GUARD_TIMEOUT="$RH_ENV_DATA_GUARD_TIMEOUT_VALUE"
[ -z "$RH_ENV_DATA_GUARD_SCANNER_SET" ] || RH_DATA_GUARD_SCANNER="$RH_ENV_DATA_GUARD_SCANNER_VALUE"
[ -z "$RH_ENV_DATA_ALLOW_SET" ] || RH_DATA_ALLOW="$RH_ENV_DATA_ALLOW_VALUE"
[ -z "$RH_ENV_DATA_GITHUB_SET" ] || RH_DATA_GITHUB="$RH_ENV_DATA_GITHUB_VALUE"
[ -z "$RH_ENV_DATA_GUARD_SET" ] || RH_DATA_GUARD="$RH_ENV_DATA_GUARD_VALUE"
[ -z "$RH_ENV_SUPABASE_APPS_SET" ] || RH_SUPABASE_APPS="$RH_ENV_SUPABASE_APPS_VALUE"
[ -z "$RH_ENV_SUPABASE_CATALOG_SET" ] || RH_SUPABASE_CATALOG="$RH_ENV_SUPABASE_CATALOG_VALUE"
[ -z "$RH_ENV_SUPABASE_CATALOG_REFS_SET" ] || RH_SUPABASE_CATALOG_REFS="$RH_ENV_SUPABASE_CATALOG_REFS_VALUE"
[ -z "$RH_ENV_SUPABASE_CATALOG_KEYCHAIN_SET" ] || RH_SUPABASE_CATALOG_KEYCHAIN="$RH_ENV_SUPABASE_CATALOG_KEYCHAIN_VALUE"
[ -z "$RH_ENV_SUPABASE_ANON_PROBE_SET" ] || RH_SUPABASE_ANON_PROBE="$RH_ENV_SUPABASE_ANON_PROBE_VALUE"
[ -z "$RH_ENV_SITE_URLS_SET" ] || RH_SITE_URLS="$RH_ENV_SITE_URLS_VALUE"

add_node_paths

case "$RH_MAIL_METHOD" in resend|none) ;; *) fatal "RH_MAIL_METHOD は resend または none を指定してください";; esac
case "$RH_SECURITY_ONLY" in 0|1) ;; *) fatal "RH_SECURITY_ONLY は 0 または 1 を指定してください";; esac
is_uint "$RH_AUTOFIX_PULL" || fatal "RH_AUTOFIX_PULL は0以上の整数で指定してください"
is_uint "$RH_AUTOFIX_CLI" || fatal "RH_AUTOFIX_CLI は0以上の整数で指定してください"
is_uint "$RH_FETCH_FAIL_DAYS" || fatal "RH_FETCH_FAIL_DAYS は0以上の整数で指定してください"
is_uint "$RH_DIRTY_DAYS_WARN" || fatal "RH_DIRTY_DAYS_WARN は0以上の整数で指定してください"
is_uint "$RH_GIT_MB_WARN" || fatal "RH_GIT_MB_WARN は0以上の整数で指定してください"
is_uint "$RH_GIT_GROWTH_MB" || fatal "RH_GIT_GROWTH_MB は0以上の整数で指定してください"
is_uint "$RH_STALE_BEHIND_THRESHOLD" || fatal "RH_STALE_BEHIND_THRESHOLD は0以上の整数で指定してください"
is_uint "$RH_STALE_DAYS_FAIL" || fatal "RH_STALE_DAYS_FAIL は0以上の整数で指定してください"
is_uint "$RH_SKIP_AUDIT" || fatal "RH_SKIP_AUDIT は0以上の整数で指定してください"
is_uint "$RH_SKIP_CLI" || fatal "RH_SKIP_CLI は0以上の整数で指定してください"
is_uint "$RH_SKIP_SECURITY" || fatal "RH_SKIP_SECURITY は0以上の整数で指定してください"
is_uint "$RH_SKIP_FETCH" || fatal "RH_SKIP_FETCH は0以上の整数で指定してください"
is_uint "$RH_AUTOFIX_CA_CERTS" || fatal "RH_AUTOFIX_CA_CERTS は0以上の整数で指定してください"
is_uint "$RH_AUTOFIX_SECURITY" || fatal "RH_AUTOFIX_SECURITY は0以上の整数で指定してください"
is_uint "$RH_TLS_PROBE" || fatal "RH_TLS_PROBE は0以上の整数で指定してください"
is_uint "$RH_SKIP_SOFTWAREUPDATE" || fatal "RH_SKIP_SOFTWAREUPDATE は0以上の整数で指定してください"
is_uint "$RH_KIT_UPDATE_CHECK" || fatal "RH_KIT_UPDATE_CHECK は0以上の整数で指定してください"
is_uint "$RH_NOMAIL" || fatal "RH_NOMAIL は0以上の整数で指定してください"
is_uint "$RH_NO_DESKTOP" || fatal "RH_NO_DESKTOP は0以上の整数で指定してください"
is_uint "$RH_SKIP_SOFTWARE" || fatal "RH_SKIP_SOFTWARE は0以上の整数で指定してください"
is_uint "$RH_AUTOFIX_SOFTWARE" || fatal "RH_AUTOFIX_SOFTWARE は0以上の整数で指定してください"
is_uint "$RH_SOFTWARE_STALE_DAYS" || fatal "RH_SOFTWARE_STALE_DAYS は0以上の整数で指定してください"

is_uint "$RH_MAX_RUNTIME" && [ "$RH_MAX_RUNTIME" -gt 0 ] || fatal "RH_MAX_RUNTIME は正の秒数で指定してください"

APP_DIR="${RH_APP_DIR:-$HOME/Library/Application Support/repo-health-kit}"
LOG_DIR="${RH_LOG_DIR:-$HOME/Library/Logs/repo-health-kit}"
STATE_DIR="${RH_STATE_DIR:-$APP_DIR/state}"
LOG_FILE="$LOG_DIR/repo-health.log"
REPORT="$LOG_DIR/repo-health-latest.md"
DENYLIST="${RH_DENYLIST:-$KIT_DIR/config/pkg-denylist.tsv}"
DENY_SCANNER="${RH_DENY_SCANNER:-$SCRIPT_DIR/pkg-denylist-scan.py}"
ALLOW_FILE="${RH_ALLOW_FILE:-$HOME/.config/repo-health-kit/allow.tsv}"
VULN_ALLOW_FILE="${RH_VULN_ALLOW_FILE:-$HOME/.config/repo-health-kit/vuln-allow.tsv}"
SECURITY_PACKAGES="${RH_SECURITY_PACKAGES:-$KIT_DIR/config/security-packages.txt}"
SECURITY_MINIMUMS="${RH_SECURITY_MINIMUMS:-$KIT_DIR/config/security-minimums.tsv}"
PYTHON_PINS="${RH_PYTHON_PINS:-$KIT_DIR/config/python-pins.tsv}"
ACTIONS_DENYLIST="${RH_ACTIONS_DENYLIST:-$KIT_DIR/config/actions-denylist.tsv}"
TLS_PROBES="${RH_TLS_PROBES:-$KIT_DIR/config/tls-probes.tsv}"

mkdir -p "$LOG_DIR" "$STATE_DIR" || fatal "ログまたは状態の保存先を作成できません"
chmod 700 "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

# 点検を専用のプロセスグループで動かし、子コマンドも制限時間に含めます。
# ps によるプロセス一覧が利用できない環境でも同じように停止できます。
if [ "${RH_RUNTIME_CHILD:-0}" != 1 ]; then
  # bash の配列は環境へ export できないため、呼出元の scalar を復元して渡します。
  if [ -n "$RH_ENV_ROOTS_SET" ]; then
    unset RH_ROOTS
    # shellcheck disable=SC2178  # 再起動先へ渡すときだけ配列から scalar に戻します。
    export RH_ROOTS="$RH_ENV_ROOTS_VALUE"
  fi
  if [ -n "$RH_ENV_SOFTWARE_IGNORE_SET" ]; then
    unset RH_SOFTWARE_IGNORE
    # shellcheck disable=SC2178  # 再起動先へ渡すときだけ配列から scalar に戻します。
    export RH_SOFTWARE_IGNORE="$RH_ENV_SOFTWARE_IGNORE_VALUE"
  fi
  RH_RUNTIME_CHILD=1 exec perl - "$RH_MAX_RUNTIME" "$BASH" "$0" "$@" <<'PERL'
use strict;
use warnings;
use POSIX qw(setpgid);
my $seconds = shift @ARGV;
my $pid = fork();
defined $pid or die "runtime guard: fork failed\n";
if ($pid == 0) {
    setpgid(0, 0) == 0 or die "runtime guard: setpgid failed\n";
    exec @ARGV or die "runtime guard: exec failed\n";
}
# 親からも設定し、起動直後に届く停止信号との競合を避けます。
setpgid($pid, $pid);
my $stop_code = 0;
my $stop = sub {
    my ($code) = @_;
    if ($stop_code) {
        kill 'KILL', -$pid;
    } else {
        $stop_code = $code;
        kill 'TERM', -$pid;
        alarm 2;
    }
};
$SIG{ALRM} = sub { $stop->(143) };
$SIG{TERM} = sub { $stop->(143) };
$SIG{HUP} = sub { $stop->(143) };
$SIG{INT} = sub { $stop->(130) };
alarm $seconds;
my $result;
do { $result = waitpid($pid, 0) } while $result == -1 && $!{EINTR};
my $status = $?;
alarm 0;
exit $stop_code if $stop_code;
exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
PERL
fi

# mkdir が成功した回だけが点検と後始末を行います。
RUN_LOCK="$STATE_DIR/run.lock"
if ! mkdir "$RUN_LOCK" 2>/dev/null; then
  lock_started="$(stat -f '%m' "$RUN_LOCK" 2>/dev/null || stat -c '%Y' "$RUN_LOCK" 2>/dev/null || printf '0')"
  is_uint "$lock_started" || lock_started=0
  if [ $(( $(date '+%s') - lock_started )) -lt 10800 ]; then
    printf 'repo-health: 点検中のため終了します\n'
    exit 0
  fi
  mkdir "$STATE_DIR/run.lock.reclaim" 2>/dev/null || exit 0
  lock_started="$(stat -f '%m' "$RUN_LOCK" 2>/dev/null || stat -c '%Y' "$RUN_LOCK" 2>/dev/null || printf '0')"
  is_uint "$lock_started" || lock_started=0
  if [ $(( $(date '+%s') - lock_started )) -lt 10800 ]; then
    rmdir "$STATE_DIR/run.lock.reclaim"
    exit 0
  fi
  rm -rf "$RUN_LOCK"
  mkdir "$RUN_LOCK" 2>/dev/null || { rmdir "$STATE_DIR/run.lock.reclaim"; exit 0; }
  rmdir "$STATE_DIR/run.lock.reclaim"
fi
printf '%s %s\n' "$(date '+%s')" "$$" > "$RUN_LOCK/started"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repo-health.XXXXXX")" || fatal "一時ディレクトリを作成できません"
# shellcheck disable=SC2329  # EXIT trap から呼び出します。
cleanup() {
  rm -rf "$TMP_DIR" "$RUN_LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

rotate_log() {
  local path="$1" size mode="${2:-move}"
  [ -f "$path" ] || return 0
  size="$(wc -c < "$path" | tr -d ' ')"
  [ "$size" -gt 5242880 ] || return 0
  if [ "$mode" = truncate ]; then
    cp -p "$path" "$path.1" && : > "$path"
  else
    mv -f "$path" "$path.1"
  fi
}
rotate_log "$LOG_FILE"
rotate_log "$LOG_DIR/repo-health-launchd.log" truncate

declare -a FAILURES WARNINGS AUTOFIXED WORKING SYNC_WAIT CLI_UPDATES SOFTWARE_UPDATES NOTES DETAILS
FAILURES=(); WARNINGS=(); AUTOFIXED=(); WORKING=(); SYNC_WAIT=(); CLI_UPDATES=(); SOFTWARE_UPDATES=(); NOTES=(); DETAILS=(); DATA_GUARD_NOTES=()

add_failure() { FAILURES[${#FAILURES[@]}]="$(clean_text "$*")"; }
add_warning() { WARNINGS[${#WARNINGS[@]}]="$(clean_text "$*")"; }
add_protected_failure() {
  add_failure "$@"
  printf '%s\n' "$(clean_text "$*")" >> "$TMP_DIR/protected-failures"
}
add_detail() { DETAILS[${#DETAILS[@]}]="$(clean_text "$*")"; }

# 全ての検査が終わったあとに適用し、据え置き中は件数・通知から外します。
apply_allowances() {
  local status pattern expiry reason remaining item level matched protected
  local -a kept
  [ -f "$ALLOW_FILE" ] || return 0
  check_config_safety "$ALLOW_FILE"
  python3 - "$ALLOW_FILE" "${RH_TODAY:-$(TZ=Asia/Tokyo date '+%Y-%m-%d')}" > "$TMP_DIR/allow-valid.tsv" <<'PY_ALLOW'
from datetime import date
import sys
from pathlib import Path
today = date.fromisoformat(sys.argv[2])
for number, line in enumerate(Path(sys.argv[1]).read_text(encoding="utf-8").splitlines(), 1):
    if not line.strip() or line.startswith("#"):
        continue
    parts = line.split("\t")
    try:
        if len(parts) != 3 or not parts[0].strip() or not parts[2].strip():
            raise ValueError()
        expires = date.fromisoformat(parts[1])
        if expires.isoformat() != parts[1] or (expires - today).days > 180:
            raise ValueError()
    except ValueError:
        print(f"INVALID\t{number}\t-\t-\t-")
        continue
    print("\t".join(("VALID", *parts, str((expires - today).days))))
PY_ALLOW
  while IFS=$'\t' read -r status pattern expiry reason remaining; do
    [ "$status" != INVALID ] || { NOTES[${#NOTES[@]}]="据え置き表の ${pattern} 行目は無効です（文・期限 YYYY-MM-DD・理由が必要です。期限は最長 180 日）"; }
  done < "$TMP_DIR/allow-valid.tsv"
  for level in FAIL WARN; do
    kept=()
    if [ "$level" = FAIL ]; then
      printf '%s\0' "${FAILURES[@]+"${FAILURES[@]}"}" > "$TMP_DIR/allow-items"
    else
      printf '%s\0' "${WARNINGS[@]+"${WARNINGS[@]}"}" > "$TMP_DIR/allow-items"
    fi
    while IFS= read -r -d '' item; do
      [ -n "$item" ] || continue
      matched=0; protected=0
      # データの据え置きは種類・対象・ハッシュを照合する専用表だけで扱います。
      if [ -f "$TMP_DIR/data-guard-items" ] && grep -Fqx -- "$item" "$TMP_DIR/data-guard-items"; then
        kept[${#kept[@]}]="$item"
        continue
      fi
      if [ "$level" = FAIL ] && [ -f "$TMP_DIR/protected-failures" ] && grep -Fqx -- "$item" "$TMP_DIR/protected-failures"; then protected=1; fi
      while IFS=$'\t' read -r status pattern expiry reason remaining; do
        [ "$status" = VALID ] || continue
        case "$item" in *"$pattern"*) ;; *) continue;; esac
        if [ "$protected" = 1 ]; then
          NOTES[${#NOTES[@]}]="据え置き不可（侵害パッケージ・追跡中の鍵）: $item"
          break
        fi
        [ "$remaining" -ge 0 ] || continue
        NOTES[${#NOTES[@]}]="参考（据え置き中・期限 ${expiry}）${level} ${item}（理由: $(clean_text "$reason")）"
        if [ "$remaining" -le 7 ]; then NOTES[${#NOTES[@]}]="据え置きの期限が近い: ${expiry} — $item"; fi
        matched=1
        break
      done < "$TMP_DIR/allow-valid.tsv"
      [ "$matched" = 1 ] || kept[${#kept[@]}]="$item"
    done < "$TMP_DIR/allow-items"
    if [ "$level" = FAIL ]; then FAILURES=("${kept[@]+"${kept[@]}"}"); else WARNINGS=("${kept[@]+"${kept[@]}"}"); fi
  done
}

# shellcheck disable=SC2329  # process substitution と timeout 経由でも使います。
rh_git() {
  command git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.sshCommand=ssh "$@"
}

run_timeout() {
  local seconds="$1"
  shift
  if [ "${1-}" = "rh_git" ]; then
    shift
    set -- git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.sshCommand=ssh "$@"
  fi
  perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}

streak_key() {
  local base checksum
  base="$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  checksum="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  printf '%s-%s' "$base" "$checksum"
}

repo_state_key() {
  local repo="$1" base hash prefix old new marker
  base="$(basename -- "$repo")"
  hash="$(printf '%s' "$repo" | cksum | awk '{print $1}')"
  REPO_STATE_KEY="$(printf '%s' "$base" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c 1-100)-$hash"
  marker="$STATE_DIR/$(streak_key "migrated-$REPO_STATE_KEY").state"
  [ ! -f "$marker" ] || return 0
  for prefix in fetch dirty stale size; do
    if [ "$prefix" = size ]; then
      old="$STATE_DIR/$(streak_key "$prefix-$base").size"
      new="$STATE_DIR/$(streak_key "$prefix-$REPO_STATE_KEY").size"
    else
      old="$(streak_file "$prefix-$base")"
      new="$(streak_file "$prefix-$REPO_STATE_KEY")"
    fi
    [ ! -f "$old" ] || [ -f "$new" ] || cp -p "$old" "$new"
  done
  : > "$marker"
  chmod 600 "$marker"
}

streak_file() {
  printf '%s/%s.state' "$STATE_DIR" "$(streak_key "$1")"
}

streak_bump() {
  local file today saved_date count
  file="$(streak_file "$1")"
  today="${RH_TODAY:-$(TZ=Asia/Tokyo date '+%Y-%m-%d')}"
  saved_date=""; count=0
  if [ -f "$file" ]; then
    read -r saved_date count < "$file" 2>/dev/null || true
  fi
  is_uint "$count" || count=0
  if [ "$saved_date" != "$today" ]; then
    count=$((count + 1))
    printf '%s %s\n' "$today" "$count" > "$file"
    chmod 600 "$file" 2>/dev/null || true
  fi
  printf '%s' "$count"
}

streak_reset() {
  rm -f "$(streak_file "$1")"
}

# dirty の指紋の保存先です。中身は shasum の 40 桁だけで、ファイル名は残しません。
dirty_hash_file() {
  printf '%s/%s.hash' "$STATE_DIR" "$(streak_key "dirty-$1")"
}

# 取れなかった理由を、stderr の中身を見せずに分類します（URL に鍵が入ることがあるため）。
# 終了コード 124・142（alarm による停止）はタイムアウトです。結果は認証・ホスト不明・タイムアウト・その他。
classify_fetch_failure() {
  local rc="$1" err_file="$2" text
  case "$rc" in 124|142) printf 'タイムアウト'; return;; esac
  text="$(LC_ALL=C sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*##g' "$err_file" 2>/dev/null | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$text" in
    *auth*|*permission*|*credential*|*'could not read username'*) printf '認証';;
    # 'resolve host' は 'resolve hostname' も含みます。
    *'resolve host'*|*'name or service not known'*) printf 'ホスト不明';;
    *timeout*|*'timed out'*) printf 'タイムアウト';;
    *) printf 'その他';;
  esac
}

fetch_failure_hint() {
  case "$1" in
    '認証') printf 'gh auth status か鍵を確認してください';;
    'ホスト不明') printf 'ネットと remote の URL を確認してください';;
    'タイムアウト') printf '回線を確認してください';;
    *) printf 'remote と認証を確認してください';;
  esac
}

# origin を fetch します。stderr は呼び出し側の一時ファイル（600）へ取り、表示はしません。
fetch_origin() {
  local repo="$1" err_file="$2"
  : > "$err_file" && chmod 600 "$err_file" 2>/dev/null || true
  run_timeout 90 rh_git -C "$repo" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 fetch --prune --quiet origin >/dev/null 2>"$err_file"
}

# データ点検の時間切れでは、curl・psql などの子もまとめて停止します。
run_data_guard_timeout() {
  perl - "$@" <<'PERL_DG'
use strict;
use warnings;
use POSIX qw(setpgid);
my $seconds = shift @ARGV;
my $pid = fork();
defined $pid or die "data guard: fork failed\n";
if ($pid == 0) {
    setpgid(0, 0) == 0 or die "data guard: setpgid failed\n";
    exec @ARGV or die "data guard: exec failed\n";
}
setpgid($pid, $pid);
my $stopped = 0;
my $stop = sub {
    if ($stopped) { kill 'KILL', -$pid; }
    else { $stopped = 1; kill 'TERM', -$pid; alarm 2; }
};
$SIG{ALRM} = $stop;
$SIG{TERM} = $stop;
$SIG{HUP} = $stop;
$SIG{INT} = $stop;
alarm $seconds;
my $result;
do { $result = waitpid($pid, 0) } while $result == -1 && $!{EINTR};
my $status = $?;
alarm 0;
# 親が先に終わっても、制限時間を超えた子を残しません。
kill 'KILL', -$pid if $stopped;
exit 124 if $stopped;
exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
PERL_DG
}

check_data_guard() {
  local output="$TMP_DIR/data-guard.tsv" valid_rows="$TMP_DIR/data-guard-valid.tsv" rc=0 tag level kind repo target message item
  local limit="${RH_DATA_GUARD_TIMEOUT:-300}"
  if [ "${RH_DATA_GUARD:-1}" = "0" ]; then
    # 利用者が自分で止めた点検は「未検査」と書かない（未検査の連続日数で WARN に上げるため）
    NOTES[${#NOTES[@]}]="データの守りの点検は止めています（設定 RH_DATA_GUARD=0）"
    return
  fi
  if ! is_uint "$limit" || [ "$limit" -eq 0 ]; then
    add_warning "データの守りの点検が最後まで動きませんでした（未検査）"
    printf '%s\n' "データの守りの点検が最後まで動きませんでした（未検査）" >> "$TMP_DIR/data-guard-items"
    return
  fi
  run_data_guard_timeout "$limit" env RH_STATE_DIR="$STATE_DIR" \
    RH_DATA_ALLOW="${RH_DATA_ALLOW:-$HOME/.config/repo-health-kit/data-allow.tsv}" \
    RH_SUPABASE_APPS="${RH_SUPABASE_APPS:-}" RH_DATA_GITHUB="${RH_DATA_GITHUB:-1}" \
    RH_SUPABASE_CATALOG="${RH_SUPABASE_CATALOG:-0}" \
    RH_SUPABASE_CATALOG_REFS="${RH_SUPABASE_CATALOG_REFS:-}" \
    RH_SUPABASE_CATALOG_KEYCHAIN="${RH_SUPABASE_CATALOG_KEYCHAIN:-repo-health-kit-supabase-audit}" \
    RH_SUPABASE_ANON_PROBE="${RH_SUPABASE_ANON_PROBE:-0}" RH_SITE_URLS="${RH_SITE_URLS:-}" \
    RH_TODAY="${RH_TODAY:-$(TZ=Asia/Tokyo date '+%Y-%m-%d')}" \
    python3 -I "${RH_DATA_GUARD_SCANNER:-$SCRIPT_DIR/data-guard.py}" --repos-file "$REPO_LIST" > "$output" 2>/dev/null || rc=$?
  # 空出力・途中終了・壊れた行を正常と読みません。
  if ! python3 -I - "$output" "$repo_count" > "$valid_rows" <<'PY_DG'
import re
import sys
from pathlib import Path
rows = Path(sys.argv[1]).read_text().splitlines()
valid = bool(rows and re.fullmatch(r'DG_DONE\t' + re.escape(sys.argv[2]) + r'\t[0-9]+', rows[-1]))
for row in rows:
    if row.startswith('DG_DONE\t'):
        continue
    fields = row.split('\t')
    row_valid = len(fields) == 6 and fields[0] == 'DG' and fields[1] in ('FAIL', 'WARN', 'NOTE', 'INFO')
    valid = valid and row_valid
    if row_valid:
        print(row)
raise SystemExit(0 if valid else 1)
PY_DG
  then
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    add_warning "データの守りの点検が最後まで動きませんでした（未検査）"
    printf '%s\n' "データの守りの点検が最後まで動きませんでした（未検査）" >> "$TMP_DIR/data-guard-items"
  fi
  while IFS=$'\t' read -r tag level kind repo target message; do
    [ "$tag" = DG ] || continue
    item="データの守り: $(quote_name "$repo") / $(quote_name "$target") — $kind: $message"
    case "$level" in
      FAIL) add_failure "$item"; printf '%s\n' "$item" >> "$TMP_DIR/data-guard-items";;
      WARN) add_warning "$item"; printf '%s\n' "$item" >> "$TMP_DIR/data-guard-items";;
      INFO|NOTE) DATA_GUARD_NOTES[${#DATA_GUARD_NOTES[@]}]="$(clean_text "$level $item")";;
    esac
  done < "$valid_rows"
}

git_internal_path() {
  local repo="$1" value
  value="$(rh_git -C "$repo" rev-parse --git-path "$2" 2>/dev/null)" || return 1
  case "$value" in
    /*) printf '%s' "$value" ;;
    *) printf '%s/%s' "$repo" "$value" ;;
  esac
}

scan_secrets() {
  local repo="$1" repo_name="$2" pattern tracked untracked output rel line secret_type kind
  tracked="$TMP_DIR/secrets-tracked.list"
  untracked="$TMP_DIR/secrets-untracked.list"
  output="$TMP_DIR/secrets-hits.tsv"
  pattern='AIza[0-9A-Za-z_-]{35}|sk-ant-[A-Za-z0-9_-]{40,}|sk-proj-[A-Za-z0-9_-]{40,}|sk_(live|test)_[A-Za-z0-9]{20,}|whsec_[A-Za-z0-9]{25,}|gh[pous]_[A-Za-z0-9]{30,}|sbp_[a-f0-9]{40}|xox[baprs]-[A-Za-z0-9-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|sb_secret_[A-Za-z0-9_-]+|re_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]+|GOCSPX-[A-Za-z0-9_-]+|postgres(ql)?://[^[:space:]]+|^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*='
  # 候補の絞り込みはまとめて行い、ファイルごとの grep 起動を避けます。
  rh_git -C "$repo" grep -I -l -E -z "$pattern" -- . ':!node_modules' ':!**/node_modules/**' > "$tracked" 2>/dev/null || true
  rh_git -C "$repo" ls-files -z -- '.env*' '**/.env*' >> "$tracked" 2>/dev/null || true
  (cd "$repo" && rh_git ls-files -z --others --exclude-standard | xargs -0 grep -l -I -E --null -- "$pattern" /dev/null) > "$untracked" 2>/dev/null || true
  if ! python3 - "$repo" "$tracked" "$untracked" > "$output" 2>/dev/null <<'PY'
import base64
import json
import os
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
patterns = [
    ("Google API key", r"AIza[0-9A-Za-z_-]{35}"),
    ("Anthropic API key", r"sk-ant-[A-Za-z0-9_-]{40,}"),
    ("OpenAI API key", r"sk-proj-[A-Za-z0-9_-]{40,}"),
    ("Stripe key", r"sk_(?:live|test)_[A-Za-z0-9]{20,}|whsec_[A-Za-z0-9]{25,}"),
    ("GitHub token", r"gh[pous]_[A-Za-z0-9]{30,}|(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9]{20,}_[A-Za-z0-9]{40,}"),
    ("Supabase token", r"sbp_[a-f0-9]{40}|(?<![A-Za-z0-9_])sb_secret_[A-Za-z0-9_-]{20,}"),
    ("Slack token", r"xox[baprs]-[A-Za-z0-9-]{20,}"),
    ("private key", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("Resend API key", r"(?<![A-Za-z0-9_])re_[A-Za-z0-9]{6,12}_[A-Za-z0-9]{16,40}(?![A-Za-z0-9_])"),
    ("AWS access key", r"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}(?![A-Za-z0-9])"),
    ("Google OAuth secret", r"(?<![A-Za-z0-9_])GOCSPX-[A-Za-z0-9_-]{20,}"),
    ("PostgreSQL password URL", r"postgres(?:ql)?://[^\s:/@]+:[^\s@]+@[^\s]+"),
]
pg_url = re.compile(r"postgres(?:ql)?://[^\s:/@]+:([^\s@]+)@([^\s/:?]+)")
placeholder = re.compile(r"(?i)^(\[.*\]|<.*>|\$\{?[A-Za-z_]+\}?|\*+|x+|\.+|password|pass|passwd|postgres|secret|changeme|your[-_].*|.*example.*|.*placeholder.*|.*dummy.*|.*fake.*)$")
sample_token = re.compile(r"(?i)x{6,}|your|example|dummy|fake|sample|placeholder")

def real_hit(label, pattern, text):
    # 見本の値と、見本のパスワード・localhost の接続 URL は数えません。
    if label == "PostgreSQL password URL":
        for m in pg_url.finditer(text):
            pw, host = m.group(1), m.group(2).lower()
            if len(pw) >= 8 and not placeholder.match(pw) and host not in ("localhost", "127.0.0.1", "host", "hostname", "db", "postgres") and "example" not in host:
                return True
        return False
    return any(not sample_token.search(m.group(0)) for m in re.finditer(pattern, text))
assignment = re.compile(r"^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*(.*?)\s*$")
jwt = re.compile(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")

def role(token):
    try:
        payload = token.split('.')[1]
        data = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
        return data.get('role') if isinstance(data, dict) else None
    except (ValueError, TypeError, UnicodeError):
        return None

def value(raw):
    raw = re.sub(r'\s+#.*$', '', raw).strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        return raw[1:-1]
    return raw

def sample(raw):
    return not raw or raw.startswith(('op://', 'your-')) or bool(re.fullmatch(r'<[^>]*>', raw))

for kind, source in (("tracked", sys.argv[2]), ("untracked", sys.argv[3])):
    for rel in dict.fromkeys(os.fsdecode(part) for part in Path(source).read_bytes().split(b'\0') if part):
        path = Path(rel)
        if 'node_modules' in path.parts or rel == '/dev/null':
            continue
        lines = (repo / path).read_text(encoding='utf-8', errors='replace').splitlines()
        env = path.name.startswith('.env')
        template = path.name in ('.env.example', '.env.sample', '.env.tpl')
        assignments = [(n, value(m.group(1))) for n, text in enumerate(lines, 1) if (m := assignment.match(text))]
        if template and all(sample(raw) for _, raw in assignments):
            # 型が直接埋め込まれた行は、テンプレートのコメントでも点検します。
            template_safe = True
        else:
            template_safe = False
        hits = set()
        if env:
            anon_only = bool(assignments) and all(jwt.fullmatch(raw) and role(raw) == 'anon' for _, raw in assignments)
            if kind == 'tracked' and not template_safe and not anon_only:
                hits.add((assignments[0][0] if assignments else 1, 'tracked .env file'))
            for n, raw in assignments:
                if sample(raw) or (jwt.fullmatch(raw) and role(raw) == 'anon'):
                    continue
                hits.add((n, '.env assignment'))
        for n, text in enumerate(lines, 1):
            if template_safe and assignment.match(text):
                continue
            for label, pattern in patterns:
                if real_hit(label, pattern, text):
                    hits.add((n, label))
            if any(role(m.group()) == 'service_role' for m in jwt.finditer(text)):
                hits.add((n, 'Supabase service_role JWT'))
        for n, label in sorted(hits):
            sys.stdout.write(f'{kind}\0{rel}\0{n}\0{label}\0')
PY
  then
    add_failure "$repo_name — 平文シークレットの検査が異常終了しました"
    return
  fi
  while IFS= read -r -d '' kind && IFS= read -r -d '' rel && IFS= read -r -d '' line && IFS= read -r -d '' secret_type; do
    if [ "$secret_type" = 'tracked .env file' ]; then
      add_failure "$repo_name — .env ファイルが追跡中: $(quote_name "$rel"):${line}（${secret_type}）"
    elif [ "$kind" = tracked ]; then
      add_protected_failure "$repo_name — 平文シークレットが commit 済み: $(quote_name "$rel"):${line}（${secret_type}）"
    else
      add_failure "$repo_name — 平文シークレットが未追跡かつ gitignore 外: $(quote_name "$rel"):${line}（${secret_type}）"
    fi
  done < "$output"
}

scan_nonstandard_env() {
  local repo="$1" repo_name="$2" file keys modified now days ignored
  for file in "$repo"/.env.*; do
    [ -f "$file" ] || continue
    ignored=0
    if ! rh_git -C "$repo" ls-files --error-unmatch -- "${file#"$repo"/}" >/dev/null 2>&1 \
      && rh_git -C "$repo" check-ignore -q -- "$file"; then ignored=1; fi
    case "${file##*/}" in .env.local|.env.example|.env.sample|.env.tpl) continue;; esac
    keys="$(LC_ALL=C grep -cE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=.+' "$file" 2>/dev/null || true)"
    is_uint "$keys" || keys=0
    [ "$keys" -gt 0 ] || continue
    modified="$(stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null || printf '0')"
    now="$(date '+%s')"
    is_uint "$modified" || modified=0
    days=$(( (now - modified) / 86400 ))
    if [ "$ignored" = 1 ]; then
      NOTES[${#NOTES[@]}]="$repo_name — gitignore 済みの env ファイル $(quote_name "${file##*/}")"
    else
      add_warning "$repo_name — git に入るおそれのある env ファイル $(quote_name "${file##*/}")（${keys}キー・${days}日前）"
    fi
  done
}

# audit の結果と期限付き据え置きを、指摘単位で照合します。
audit_counts() {
  python3 - "$1" "$2" "$VULN_ALLOW_FILE" "$3" "${RH_TODAY:-$(TZ=Asia/Tokyo date '+%Y-%m-%d')}" "${4:-0}" <<'PY'
import json
import re
import sys
from pathlib import Path

source, mode, allow_path, repo, today, audit_rc = sys.argv[1:]
allowed_ids = set()
legacy = False
try:
    for line in Path(allow_path).read_text(encoding='utf-8').splitlines():
        cols = line.split('\t')
        if len(cols) < 3 or cols[0] != repo or not re.fullmatch(r'\d{4}-\d\d-\d\d', cols[2]) or cols[2] < today:
            continue
        ids = [x.strip() for x in cols[1].split(',')]
        if all(re.fullmatch(r'(?:GHSA-[A-Za-z0-9-]+|(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*)', x) for x in ids):
            allowed_ids.update(ids)
        else:
            legacy = True
except FileNotFoundError:
    pass

def identifiers(name, entry):
    values = {name}
    if isinstance(entry, dict):
        for key in ('name', 'packageName', 'module_name', 'advisoryId', 'id', 'url', 'link', 'github_advisory_id'):
            if isinstance(entry.get(key), str):
                values.add(entry[key])
        for via in entry.get('via', []) if isinstance(entry.get('via'), list) else []:
            if isinstance(via, dict):
                values.update(identifiers('', via))
    for raw in list(values):
        values.update(re.findall(r'GHSA-[A-Za-z0-9-]+', raw))
    return values

try:
    raw = Path(source).read_text(encoding='utf-8')
    if mode == 'yarn':
        # yarn berry は advisory ごとの NDJSON（value と children）です。
        entries_raw = [json.loads(line) for line in raw.splitlines() if line.strip()]
        normalized = {}
        for index, record in enumerate(entries_raw):
            if not isinstance(record, dict):
                raise ValueError
            if not record:
                continue
            child = record.get('children')
            if not isinstance(child, dict) or not isinstance(child.get('Severity'), str):
                raise ValueError
            normalized[str(index)] = {
                'module_name': str(record.get('value', '')),
                'severity': child['Severity'].lower(),
                'url': str(child.get('URL', '')),
            }
        data = {'advisories': normalized}
    else:
        data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError
    if mode == 'bun' and all(isinstance(group, list) for group in data.values()):
        if not data and audit_rc != '0':
            raise ValueError
        normalized = {}
        for package, group in data.items():
            for advisory in group:
                if not isinstance(advisory, dict) or not isinstance(advisory.get('severity'), str):
                    raise ValueError
                normalized[str(len(normalized))] = dict(advisory, module_name=package)
        data = {'advisories': normalized}
    counts = dict.fromkeys(('critical', 'high', 'moderate', 'low', 'unknown'), 0)
    entries = []
    if mode == 'composer':
        advisories = data.get('advisories')
        if not isinstance(advisories, (dict, list)):
            raise ValueError
        for name, group in (advisories.items() if isinstance(advisories, dict) else enumerate(advisories)):
            for entry in group if isinstance(group, list) else [group]:
                if isinstance(entry, dict):
                    sev = entry.get('severity', 'unknown').lower()
                    sev = 'moderate' if sev == 'medium' else sev
                    counts[sev if sev in counts else 'unknown'] += 1
                    if sev in ('critical', 'high'):
                        entries.append(identifiers(str(name), entry))
    else:
        metadata = data.get('metadata', {}).get('vulnerabilities')
        vulnerabilities = data.get('vulnerabilities')
        advisories = data.get('advisories')
        if isinstance(vulnerabilities, dict):
            for name, entry in vulnerabilities.items():
                if not isinstance(entry, dict):
                    raise ValueError
                sev = entry.get('severity', 'unknown')
                counts[sev if sev in counts else 'unknown'] += 1
                if sev in ('critical', 'high'):
                    # npm は同じ package の via に別 GHSA をまとめるため、それぞれ照合します。
                    vias = entry.get('via', [])
                    if not isinstance(vias, list):
                        raise ValueError
                    severe_via = [v for v in vias if not isinstance(v, dict) or v.get('severity') in (None, 'critical', 'high')]
                    if severe_via:
                        for via in severe_via:
                            entries.append(identifiers(name, via) if isinstance(via, dict) else {name})
                    else:
                        entries.append(identifiers(name, entry))
        elif isinstance(advisories, dict):
            for entry in advisories.values():
                if not isinstance(entry, dict):
                    raise ValueError
                sev = entry.get('severity', 'unknown')
                counts[sev if sev in counts else 'unknown'] += 1
                if sev in ('critical', 'high'):
                    entries.append(identifiers(entry.get('module_name', ''), entry))
        elif isinstance(metadata, dict) and any(key in metadata for key in ('critical', 'high')):
            for key in counts:
                counts[key] = int(metadata.get(key, 0))
            entries = [set() for _ in range(counts['critical'] + counts['high'])]
        else:
            raise ValueError
        # 一覧が欠けていても集計上の重大な指摘を黙らせません。
        if isinstance(metadata, dict):
            if not any(key in metadata for key in ('critical', 'high')):
                raise ValueError
            if any(type(value) is not int or value < 0 for key, value in metadata.items() if key in counts):
                raise ValueError
            expected = int(metadata.get('critical', 0)) + int(metadata.get('high', 0))
            entries.extend(set() for _ in range(max(0, expected - len(entries))))
            for key in counts:
                counts[key] = max(counts[key], int(metadata.get(key, 0)))
    accepted = sum(1 for ids in entries if legacy or ids & allowed_ids)
    print('|'.join(map(str, [counts['critical'], counts['high'], counts['moderate'], counts['low'], counts['unknown'], accepted, len(entries)-accepted, int(legacy)])))
except (OSError, ValueError, TypeError, AttributeError):
    pass
PY
}

report_audit_counts() {
  local label="$1" tool="$2" counts="$3" critical high moderate low unknown accepted unmatched legacy
  IFS='|' read -r critical high moderate low unknown accepted unmatched legacy <<EOF_COUNTS
$counts
EOF_COUNTS
  if [ "$legacy" = 1 ]; then
    NOTES[${#NOTES[@]}]="$label — 据え置きの形式が古い（GHSA かパッケージ名を書いてください）"
  fi
  if [ "$accepted" -gt 0 ]; then
    NOTES[${#NOTES[@]}]="$label — 本番 critical/high は期限付き据え置き（据え置き ${accepted} 件・据え置き外 ${unmatched} 件）"
  fi
  if [ "$unmatched" -gt 0 ]; then
    add_failure "$label — 本番依存に critical/high 脆弱性（${tool}: ${critical} critical / ${high} high・据え置き ${accepted} 件・据え置き外 ${unmatched} 件）"
  elif [ "$unknown" -gt 0 ]; then
    add_warning "$label — $tool に重さ不明の指摘 ${unknown}件"
  fi
  add_detail "$label — $tool(prod): ${critical} critical / ${high} high / ${moderate} moderate / ${low} low / ${unknown} unknown"
}

audit_manifest() {
  local repo="$1" repo_name="$2" manifest="$3" manifest_dir rel label output counts tool=npm version audit_rc
  local -a audit_args
  manifest_dir="$(dirname -- "$manifest")"
  rel="${manifest_dir#"$repo"/}"
  if [ "$manifest_dir" = "$repo" ]; then label="$repo_name"; else label="$repo_name/$(quote_name "$rel")"; fi
  if [ -f "$manifest_dir/package-lock.json" ] || [ -f "$manifest_dir/npm-shrinkwrap.json" ]; then
    audit_args=(audit --omit=dev --package-lock-only --json --fetch-timeout=60000 --fetch-retries=0)
  elif [ -f "$manifest_dir/pnpm-lock.yaml" ]; then
    tool=pnpm; audit_args=(audit --prod --json)
  elif [ -f "$manifest_dir/yarn.lock" ]; then
    tool=yarn; audit_args=(npm audit --all --recursive --environment production --json)
  elif [ -f "$manifest_dir/bun.lock" ] || [ -f "$manifest_dir/bun.lockb" ]; then
    tool=bun; audit_args=(audit --json)
  else
    if [ "$manifest_dir" = "$repo" ]; then
      add_warning "$label — package.json ありに lockfile なし（監査不能）"
    else
      add_detail "$label — lockfile なしの入れ子（同梱物として未監査）"
    fi
    return
  fi
  if [ "$RH_SKIP_AUDIT" = 1 ]; then
    add_detail "$label — $tool audit は止めています（設定 RH_SKIP_AUDIT=1）"
    return
  fi
  if ! command -v "$tool" >/dev/null 2>&1; then
    if [ "$tool" = npm ]; then
      add_warning "$label — npm audit 実行不能（npm 不在）"
      NOTES[${#NOTES[@]}]="$label — npm 不在のため依存脆弱性は未検査"
    else
      NOTES[${#NOTES[@]}]="$label — この lock は npm audit では見られません（${tool} を入れると見られます）"
    fi
    return
  fi
  if [ "$tool" = yarn ]; then
    version="$(run_timeout 20 yarn --version 2>/dev/null || true)"
    case "$version" in 0.*|1.*|'')
      NOTES[${#NOTES[@]}]="$label — この lock は npm audit では見られません（yarn berry を入れると見られます）"
      return;;
    esac
  fi
  output="$TMP_DIR/audit-$(streak_key "$manifest").json"
  (cd "$manifest_dir" && run_timeout 120 "$tool" "${audit_args[@]}" > "$output" 2>/dev/null)
  audit_rc=$?
  if [ "$audit_rc" -ne 0 ] && [ "$audit_rc" -ne 1 ]; then
    add_warning "$label — $tool audit 実行不能（異常終了）"
    return
  fi
  if [ "$tool" = yarn ] && [ "$audit_rc" -ne 0 ] && [ ! -s "$output" ]; then
    add_warning "$label — $tool audit 実行不能（応答なし）"
    return
  fi
  counts="$(audit_counts "$output" "$tool" "$(basename -- "$repo")" "$audit_rc")"
  if [ -z "$counts" ]; then
    add_warning "$label — $tool audit 実行不能（timeout・ネットワーク・応答不正のいずれか）"
    return
  fi
  report_audit_counts "$label" "$tool audit" "$counts"
}

audit_composer_lock() {
  local repo="$1" repo_name="$2" lock="$3" manifest_dir rel label output counts composer_path
  manifest_dir="$(dirname -- "$lock")"
  rel="${manifest_dir#"$repo"/}"
  if [ "$manifest_dir" = "$repo" ]; then label="$repo_name"; else label="$repo_name/$(quote_name "$rel")"; fi
  if [ "$RH_SKIP_AUDIT" = 1 ]; then
    add_detail "$label — composer audit は止めています（設定 RH_SKIP_AUDIT=1）"
    return
  fi
  composer_path="${RH_COMPOSER_PATH-$(command -v composer 2>/dev/null || true)}"
  if [ -z "$composer_path" ]; then
    add_warning "$label — composer audit 実行不能（composer 不在）"
    return
  fi
  output="$TMP_DIR/composer-audit-$(streak_key "$lock").json"
  (cd "$manifest_dir" && run_timeout 120 "$composer_path" --no-plugins --no-scripts audit --locked --no-dev --format=json --no-interaction > "$output" 2>/dev/null) || true
  counts="$(audit_counts "$output" composer "$(basename -- "$repo")")"
  if [ -z "$counts" ]; then
    add_warning "$label — composer audit 実行不能（timeout・ネットワーク・応答不正のいずれか）"
    return
  fi
  report_audit_counts "$label" 'composer audit' "$counts"
}

scan_manifests() {
  local repo="$1" repo_name="$2" manifest list composer_list
  list="$TMP_DIR/manifests-$(streak_key "$repo").list"
  : > "$list"
  [ -f "$repo/package.json" ] && printf '%s\0' "$repo/package.json" >> "$list"
  while IFS= read -r -d '' manifest; do
    printf '%s\0' "$repo/$manifest" >> "$list"
  done < <(rh_git -C "$repo" -c core.quotepath=false ls-files -z -- '*/package.json' 2>/dev/null)
  while IFS= read -r -d '' manifest; do
    audit_manifest "$repo" "$repo_name" "$manifest"
  done < "$list"

  composer_list="$TMP_DIR/composer-locks-$(streak_key "$repo").list"
  : > "$composer_list"
  [ -f "$repo/composer.lock" ] && printf '%s\0' "$repo/composer.lock" >> "$composer_list"
  while IFS= read -r -d '' manifest; do
    printf '%s\0' "$repo/$manifest" >> "$composer_list"
  done < <(rh_git -C "$repo" -c core.quotepath=false ls-files -z -- '*/composer.lock' 2>/dev/null)
  while IFS= read -r -d '' manifest; do
    audit_composer_lock "$repo" "$repo_name" "$manifest"
  done < "$composer_list"
}

scan_denylist() {
  local repo="$1" repo_name="$2" output rc line prefix _hit_repo lock package reason
  output="$TMP_DIR/deny-$(streak_key "$repo").txt"
  if [ ! -f "$DENY_SCANNER" ] || [ ! -f "$DENYLIST" ]; then
    add_failure "$repo_name — 侵害パッケージ照合が動いていません（同梱ファイル不足）"
    return
  fi
  run_timeout 60 python3 "$DENY_SCANNER" --repo "$repo" --name "$repo_name" --denylist "$DENYLIST" > "$output" 2>/dev/null
  rc=$?
  while IFS= read -r line; do
    IFS='|' read -r prefix _hit_repo lock package reason <<EOF
$line
EOF
    case "$prefix" in
      DENY) add_protected_failure "$repo_name — 侵害パッケージが入っています: ${package}（${reason}・$(quote_name "$lock")）" ;;
      DENYWARN) add_warning "$repo_name — $(quote_name "$lock") は未照合（${package}）" ;;
      DENYSKIP) add_failure "$repo_name — 侵害パッケージ照合が動いていません: $lock" ;;
    esac
  done < "$output"
  if { [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; } || { [ "$rc" -eq 1 ] && [ ! -s "$output" ]; }; then
    add_failure "$repo_name — 侵害パッケージ照合が異常終了しました"
  fi
}

scan_actions_denylist() {
  local repo="$1" repo_name="$2" output rc prefix workflow action reason
  if [ ! -f "$ACTIONS_DENYLIST" ]; then
    add_failure "$repo_name — GitHub Actions 照合が動いていません（同梱リスト不足）"
    return
  fi
  output="$TMP_DIR/actions-$(streak_key "$repo").txt"
  # 追跡中の .github/workflows/*.yml|*.yaml の uses: を読み、owner/repo（下のパス・@ 以降は無視・大小文字は区別しない）を表と比べる
  python3 - "$repo" "$ACTIONS_DENYLIST" > "$output" 2>/dev/null <<'PY'
import re
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
deny = {}
for raw in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split("\t")
    deny[parts[0].strip().lower()] = parts[1].strip() if len(parts) > 1 else "理由未記入"
if not deny:
    sys.stdout.write("ACTIONSKIP\0-\0-\0照合リストが空です\0")
    raise SystemExit(2)

result = subprocess.run(
    ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.sshCommand=ssh", "-c", "core.quotepath=false", "ls-files", "-z"],
    cwd=repo,
    capture_output=True,
    timeout=30,
    check=False,
)
uses_line = re.compile(r"""^\s*(?:-\s*)?uses\s*:\s*['"]?([^'"#\s]+)""")
seen = set()
for raw in result.stdout.split(b"\0"):
    if not raw:
        continue
    try:
        rel = raw.decode("utf-8")
    except UnicodeDecodeError:
        continue
    lower_rel = rel.lower()
    if not lower_rel.startswith(".github/workflows/") or not lower_rel.endswith((".yml", ".yaml")):
        continue
    try:
        text = (repo / rel).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    for line in text.splitlines():
        match = uses_line.match(line)
        if not match:
            continue
        value = match.group(1)
        if value.startswith(("./", "docker://")):
            continue
        parts = value.split("@", 1)[0].split("/")
        if len(parts) < 2:
            continue
        action = "/".join(parts[:2]).lower()
        reason = deny.get(action)
        if reason is None or (rel, action) in seen:
            continue
        seen.add((rel, action))
        sys.stdout.write("\0".join(("ACTION", rel, action, reason)) + "\0")
PY
  rc=$?
  while IFS= read -r -d '' prefix && IFS= read -r -d '' workflow && IFS= read -r -d '' action && IFS= read -r -d '' reason; do
    case "$prefix" in
      ACTION) add_failure "$repo_name — 侵害された GitHub Action（${action}）を使っています。workflow から外し、そのリポの secret を入れ替えてください（${reason}・$(quote_name "$workflow")）" ;;
      ACTIONSKIP) add_failure "$repo_name — GitHub Actions 照合が動いていません: ${reason}" ;;
    esac
  done < "$output"
  if [ "$rc" -ne 0 ] && [ ! -s "$output" ]; then
    add_failure "$repo_name — GitHub Actions 照合が異常終了しました"
  fi
}

check_git_size() {
  local repo="$1" repo_name="$2" git_dir kb mb size_file previous growth
  git_dir="$(rh_git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || return
  kb="$(du -sk "$git_dir" 2>/dev/null | awk '{print $1}')"
  is_uint "$kb" || kb=0
  mb=$((kb / 1024))
  if [ "$mb" -gt "$RH_GIT_MB_WARN" ]; then
    add_warning "$repo_name — .git ${mb}MB（閾値 ${RH_GIT_MB_WARN}MB 超）"
  fi
  size_file="$STATE_DIR/$(streak_key "size-$REPO_STATE_KEY").size"
  if [ -f "$size_file" ]; then
    previous="$(sed -n '1p' "$size_file" 2>/dev/null)"
    if is_uint "$previous" && [ "$mb" -gt "$previous" ]; then
      growth=$((mb - previous))
      if [ "$growth" -ge "$RH_GIT_GROWTH_MB" ]; then
        add_warning "$repo_name — .git が急増 ${previous}MB→${mb}MB（+${growth}MB）"
      fi
    fi
  fi
  printf '%s\n' "$mb" > "$size_file"
  chmod 600 "$size_file" 2>/dev/null || true
  add_detail "$repo_name — .git ${mb}MB"
}

remote_host() {
  local url="$1" host
  case "$url" in
    *://*) host="$(printf '%s' "$url" | sed -n 's#^[A-Za-z][A-Za-z0-9+.-]*://\([^/@]*@\)\{0,1\}\([^/:]*\).*#\2#p')" ;;
    *@*:*) host="${url#*@}"; host="${host%%:*}" ;;
    *) host="" ;;
  esac
  printf '%s' "$host" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9._-'
}

note_self_managed_gitlab_origin() {
  local origin_url="$1" host seen_file
  host="$(remote_host "$origin_url")"
  case "$host" in
    ''|gitlab.com) return ;;
    *gitlab*) ;;
    *) return ;;
  esac
  seen_file="$TMP_DIR/gitlab-origin-hosts.seen"
  if [ -f "$seen_file" ] && LC_ALL=C grep -Fqx "$host" "$seen_file" 2>/dev/null; then
    return
  fi
  printf '%s\n' "$host" >> "$seen_file"
  NOTES[${#NOTES[@]}]="${host} は自社で動かしている GitLab の可能性があります。サーバーの管理者に CVE-2026-110264 の修正版（19.5.1 など）を当てたか確かめてください"
}

# 未マージ remote ブランチの名前を「a・b・c」に整えます（名前だけ・先頭 5 本まで・残りは「ほか N 本」）。
# 名前の `|`・改行・制御文字は除き、1 本 120 字で切ります。
unmerged_branch_list() {
  printf '%s\n' "$1" | python3 -I -c '
import re
import sys
names = sys.stdin.buffer.read().decode("utf-8", "replace").split("\n")
if names and names[-1] == "":
    names.pop()
shown = []
for raw in names[:5]:
    name = raw[len("refs/remotes/origin/"):] if raw.startswith("refs/remotes/origin/") else raw
    name = re.sub(r"[|\x00-\x1f\x7f]", "", name)[:120]
    shown.append(name or "-")
text = "・".join(shown)
if len(names) > 5:
    text += "・ほか " + str(len(names) - 5) + " 本"
sys.stdout.buffer.write(text.encode("utf-8"))
'
}

check_repo() {
  local repo="$1" repo_name fetch branch state rebase_merge rebase_apply merge_head
  local ahead behind dirty stash fetch_days dirty_days stale_days upstream base unmerged
  local ff_ok git_status_count origin_url fetch_err fetch_rc fetch_reason fetch_hint
  local status_file dirty_hash hash_file old_hash unmerged_names
  repo_name="$(quote_name "$(basename -- "$repo")")"
  repo_state_key "$repo"

  if ! rh_git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    add_failure "$repo_name — git repo 破損（rev-parse 不能）"
    return
  fi

  fetch="OK"
  origin_url="$(rh_git -C "$repo" remote get-url origin 2>/dev/null || true)"
  if [ -z "$origin_url" ]; then
    fetch="NOREMOTE"
    add_warning "$repo_name — origin 未設定"
  else
    note_self_managed_gitlab_origin "$origin_url"
    if [ "$RH_SKIP_FETCH" = "1" ]; then
      fetch="SKIP"
      add_detail "$repo_name — fetch は止めています（設定 RH_SKIP_FETCH=1）"
    else
      # 1 回目が失敗したら少し待って 1 度だけやり直し、最後の失敗の stderr だけを分類に使います。
      fetch_err="$TMP_DIR/fetch-stderr.txt"
      fetch_rc=0
      fetch_origin "$repo" "$fetch_err" || { sleep 3; fetch_origin "$repo" "$fetch_err"; } || fetch_rc=$?
      if [ "$fetch_rc" -eq 0 ]; then
        streak_reset "fetch-$REPO_STATE_KEY"
      else
        fetch="NG"
        fetch_reason="$(classify_fetch_failure "$fetch_rc" "$fetch_err")"
        fetch_hint="$(fetch_failure_hint "$fetch_reason")"
        fetch_days="$(streak_bump "fetch-$REPO_STATE_KEY")"
        if [ "$fetch_days" -ge "$RH_FETCH_FAIL_DAYS" ]; then
          add_failure "$repo_name — fetch 失敗が${fetch_days}日連続（理由: ${fetch_reason}。${fetch_hint}）"
        else
          add_warning "$repo_name — fetch 失敗（理由: ${fetch_reason}・${fetch_days}日目。継続すると FAIL。${fetch_hint}）"
        fi
      fi
      rm -f "$fetch_err"
    fi
  fi

  branch="$(rh_git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null || printf 'DETACHED')"
  branch="$(clean_text "$branch")"
  if [ "$branch" = "DETACHED" ]; then add_failure "$repo_name — detached HEAD"; fi

  state="OK"
  rebase_merge="$(git_internal_path "$repo" rebase-merge 2>/dev/null || true)"
  rebase_apply="$(git_internal_path "$repo" rebase-apply 2>/dev/null || true)"
  merge_head="$(git_internal_path "$repo" MERGE_HEAD 2>/dev/null || true)"
  [ -n "$rebase_merge" ] && [ -d "$rebase_merge" ] && state="REBASE"
  [ -n "$rebase_apply" ] && [ -d "$rebase_apply" ] && state="REBASE"
  [ -n "$merge_head" ] && [ -f "$merge_head" ] && state="MERGE"
  [ "$state" = "OK" ] || add_failure "$repo_name — $state 途中残置"

  ahead="-"; behind="-"
  if [ "$branch" != "DETACHED" ]; then
    if upstream="$(rh_git -C "$repo" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"; then
      ahead="$(rh_git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || printf '?')"
      behind="$(rh_git -C "$repo" rev-list --count 'HEAD..@{u}' 2>/dev/null || printf '?')"
    else
      upstream=""
      ahead="NOUP"; behind="NOUP"
      add_warning "$repo_name — upstream 未設定（$(quote_name "$branch")）"
    fi
  fi
  if is_uint "$ahead" && [ "$ahead" -gt 0 ]; then add_warning "$repo_name — 未push $ahead 件"; fi

  # Claude Code の作業フォルダ（.claude/worktrees）の中身は、リポの dirty に数えない。
  # status の出力にはファイル名が入るため、一時ファイル（600）に取り、件数と指紋（shasum）だけを使って消します。
  status_file="$TMP_DIR/dirty-status.out"
  : > "$status_file" && chmod 600 "$status_file" 2>/dev/null || true
  git_status_count=0; dirty_hash=""
  if rh_git -C "$repo" status --porcelain=v1 -z -- . ':(exclude).claude/worktrees' > "$status_file" 2>/dev/null; then
    git_status_count="$(python3 -I - "$status_file" <<'PY_DIRTY_COUNT'
import sys
entries = iter(open(sys.argv[1], "rb").read().split(b"\0")[:-1])
count = 0
for entry in entries:
    count += 1
    # 名前の変更・複製は、元の名前がもう 1 つ続きます。
    if b"R" in entry[:2] or b"C" in entry[:2]:
        next(entries, None)
print(count)
PY_DIRTY_COUNT
)"
    dirty_hash="$(shasum "$status_file" 2>/dev/null | cut -c1-40)"
  fi
  rm -f "$status_file"
  is_uint "$git_status_count" || git_status_count=0
  dirty="$git_status_count"
  stash="$(rh_git -C "$repo" stash list 2>/dev/null | wc -l | tr -d ' ')"
  is_uint "$stash" || stash=0

  if [ "$RH_AUTOFIX_PULL" = "1" ] && [ "$dirty" -eq 0 ] && [ "$stash" -eq 0 ] \
    && is_uint "$ahead" && [ "$ahead" -eq 0 ] && is_uint "$behind" && [ "$behind" -gt 0 ]; then
    if run_timeout 90 rh_git -C "$repo" pull --ff-only --quiet >/dev/null 2>&1; then
      AUTOFIXED[${#AUTOFIXED[@]}]="$repo_name — behind ${behind}件を ff で解消"
      behind="$(rh_git -C "$repo" rev-list --count 'HEAD..@{u}' 2>/dev/null || printf '0')"
    else
      add_warning "$repo_name — behind ${behind}件の自動 ff pull に失敗"
    fi
  fi

  if is_uint "$behind" && [ "$behind" -gt 0 ]; then
    ff_ok=1
    is_uint "$ahead" || ff_ok=0
    [ "$ff_ok" -eq 0 ] || [ "$ahead" -eq 0 ] || ff_ok=0
    [ "$dirty" -eq 0 ] || ff_ok=0
    if [ "$ff_ok" -eq 1 ]; then
      SYNC_WAIT[${#SYNC_WAIT[@]}]="$repo_name — behind ${behind}（clean・ff 可能）"
    else
      add_warning "$repo_name — behind ${behind}（ahead/dirty を伴い ff 不可）"
    fi
  fi

  # dirty の連続日数は、指紋（status の出力の shasum）が前回と同じときだけ数えます。
  # 内容が変わっている dirty は作業が進んでいるので数え直し、同じ内容のまま続いたときだけ WARN にします。
  hash_file="$(dirty_hash_file "$REPO_STATE_KEY")"
  if [ "$dirty" -gt 0 ]; then
    old_hash=""
    [ ! -f "$hash_file" ] || read -r old_hash < "$hash_file" 2>/dev/null || true
    if [ -n "$dirty_hash" ] && [ "$old_hash" != "$dirty_hash" ]; then
      streak_reset "dirty-$REPO_STATE_KEY"
    fi
    if [ -n "$dirty_hash" ]; then
      printf '%s\n' "$dirty_hash" > "$hash_file"
      chmod 600 "$hash_file" 2>/dev/null || true
    fi
    dirty_days="$(streak_bump "dirty-$REPO_STATE_KEY")"
    if [ "$dirty_days" -ge "$RH_DIRTY_DAYS_WARN" ]; then
      add_warning "$repo_name — dirty ${dirty}件が同じ内容のまま${dirty_days}日（コミットまたは退避を確認してください）"
    else
      WORKING[${#WORKING[@]}]="$repo_name — dirty ${dirty}件（作業中・${dirty_days}日目）"
    fi
  else
    streak_reset "dirty-$REPO_STATE_KEY"
    rm -f "$hash_file"
  fi
  [ "$stash" -gt 0 ] && add_warning "$repo_name — stash $stash 件残置"

  base=""
  for upstream in origin/HEAD origin/main origin/master; do
    if rh_git -C "$repo" rev-parse -q --verify "$upstream" >/dev/null 2>&1; then base="$upstream"; break; fi
  done
  if [ "$fetch" != "NOREMOTE" ] && [ -n "$base" ]; then
    unmerged_names="$(rh_git -C "$repo" for-each-ref --format='%(refname)' --no-merged "$base" refs/remotes/origin 2>/dev/null | LC_ALL=C grep -v '^refs/remotes/origin/HEAD$' || true)"
    unmerged=0
    if [ -n "$unmerged_names" ]; then
      unmerged="$(printf '%s\n' "$unmerged_names" | LC_ALL=C grep -c . || true)"
      is_uint "$unmerged" || unmerged=0
    fi
    if [ "$unmerged" -gt 0 ]; then
      add_warning "$repo_name — 未マージ remote ブランチ $unmerged 本（$(unmerged_branch_list "$unmerged_names")）"
    fi
  fi

  if is_uint "$behind" && [ "$behind" -ge "$RH_STALE_BEHIND_THRESHOLD" ] && [ "$dirty" -gt 0 ]; then
    stale_days="$(streak_bump "stale-$REPO_STATE_KEY")"
    if [ "$stale_days" -ge "$RH_STALE_DAYS_FAIL" ]; then
      add_failure "$repo_name — ${stale_days}日連続で behind>=${RH_STALE_BEHIND_THRESHOLD} かつ dirty"
    fi
  else
    streak_reset "stale-$REPO_STATE_KEY"
  fi

  check_git_size "$repo" "$repo_name"
  scan_secrets "$repo" "$repo_name"
  scan_nonstandard_env "$repo" "$repo_name"
  scan_manifests "$repo" "$repo_name"
  scan_denylist "$repo" "$repo_name"
  scan_actions_denylist "$repo" "$repo_name"
  add_detail "$repo_name — fetch=$fetch branch=$(quote_name "$branch") ahead=$ahead behind=$behind dirty=$dirty stash=$stash state=$state"
}

check_repo_security_only() {
  local repo="$1" repo_name
  repo_name="$(quote_name "$(basename -- "$repo")")"
  repo_state_key "$repo"
  scan_denylist "$repo" "$repo_name"
  scan_actions_denylist "$repo" "$repo_name"
}

current_version() {
  run_timeout 20 "$1" --version 2>/dev/null | head -1 | LC_ALL=C grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

latest_version() {
  case "$1" in
    claude) run_timeout 40 npm view @anthropic-ai/claude-code version 2>/dev/null ;;
    codex) run_timeout 40 npm view @openai/codex version 2>/dev/null ;;
    npm|vercel|supabase) run_timeout 40 npm view "$1" version 2>/dev/null ;;
    node) run_timeout 40 curl -fsS https://nodejs.org/dist/index.json 2>/dev/null | python3 -c 'import json,sys; print(next(x["version"].lstrip("v") for x in json.load(sys.stdin) if x.get("lts")))' 2>/dev/null ;;
    gh) run_timeout 40 gh api repos/cli/cli/releases/latest -q .tag_name 2>/dev/null | sed 's/^v//' ;;
    op) run_timeout 40 curl -fsS https://api.github.com/repos/1Password/op/releases/latest 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null ;;
  esac
}

version_less_than() {
  local left="$1" right="$2" l1 l2 l3 l4 r1 r2 r3 r4
  IFS=. read -r l1 l2 l3 l4 <<EOF
$left
EOF
  IFS=. read -r r1 r2 r3 r4 <<EOF
$right
EOF
  l1=${l1:-0}; l2=${l2:-0}; l3=${l3:-0}; l4=${l4:-0}
  r1=${r1:-0}; r2=${r2:-0}; r3=${r3:-0}; r4=${r4:-0}
  is_uint "$l1" && is_uint "$l2" && is_uint "$l3" && is_uint "$l4" \
    && is_uint "$r1" && is_uint "$r2" && is_uint "$r3" && is_uint "$r4" || return 1
  [ "$l1" -lt "$r1" ] && return 0
  [ "$l1" -gt "$r1" ] && return 1
  [ "$l2" -lt "$r2" ] && return 0
  [ "$l2" -gt "$r2" ] && return 1
  [ "$l3" -lt "$r3" ] && return 0
  [ "$l3" -gt "$r3" ] && return 1
  [ "$l4" -lt "$r4" ]
}

npm_release_info() {
  local package="$1" current="$2" time_json key
  NPM_LATEST=""; NPM_TARGET=""; NPM_LATEST_DATE=""; NPM_LATEST_WAIT=0
  key="$(streak_key "npm-time-$package")"
  time_json="$TMP_DIR/${key}.json"
  if ! run_timeout 40 npm view "$package@*" time dist-tags versions deprecated version --json > "$time_json" 2>/dev/null; then
    return 1
  fi
  IFS=$'\t' read -r NPM_LATEST NPM_TARGET NPM_LATEST_DATE NPM_LATEST_WAIT < <(
    python3 -I - "$time_json" "$current" <<'PY'
import json
import re
import sys
from datetime import datetime, timedelta, timezone


def version_key(value):
    if not isinstance(value, str) or "-" in value:
        return None
    match = re.fullmatch(r"v?(\d+(?:\.\d+)*)", value)
    if not match:
        return None
    parts = tuple(int(part) for part in match.group(1).split("."))
    return parts + (0,) * (8 - len(parts))


def published_at(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
# @* の各版のメタデータを一度で取得し、古い版の非推奨指定も拾います。
if isinstance(data, list):
    rows = data
    if not rows or not all(isinstance(row, dict) for row in rows):
        raise SystemExit(1)
    data = dict(rows[-1])
    data["deprecated"] = {row.get("version"): row.get("deprecated") for row in rows if row.get("deprecated")}
if not isinstance(data, dict):
    raise SystemExit(1)
current_key = version_key(sys.argv[2])
if current_key is None:
    raise SystemExit(1)
releases = []
times = data.get("time")
versions = data.get("versions")
tags = data.get("dist-tags")
if not isinstance(times, dict) or not isinstance(versions, list) or not isinstance(tags, dict):
    raise SystemExit(1)
cap_key = version_key(tags.get("latest"))
if cap_key is None or tags.get("latest") not in versions:
    raise SystemExit(1)
# npm が package 全体の deprecated を返した場合は、候補全体を見送ります。
# 版ごとの非推奨情報がある場合も同じ問い合わせ結果から除きます。
deprecated = data.get("deprecated", {})
if isinstance(deprecated, str) and deprecated.strip():
    raise SystemExit(1)
for version, raw_time in times.items():
    if version not in versions or (isinstance(deprecated, dict) and deprecated.get(version)):
        continue
    key = version_key(version)
    moment = published_at(raw_time)
    if key is not None and moment is not None:
        releases.append((key, version.lstrip("v"), moment))
releases = [item for item in releases if item[0] <= cap_key]
if not releases:
    raise SystemExit(1)
latest_key, latest, latest_time = max(releases, key=lambda item: item[0])
cutoff = datetime.now(timezone.utc) - timedelta(hours=72)
eligible = [item for item in releases if current_key < item[0] and item[2] <= cutoff]
target = max(eligible, key=lambda item: item[0])[1] if eligible else "-"
jst = timezone(timedelta(hours=9))
latest_date = latest_time.astimezone(jst).strftime("%Y-%m-%d %H:%M JST")
waiting = "1" if current_key < latest_key and latest_time > cutoff else "0"
print(f"{latest}\t{target}\t{latest_date}\t{waiting}")
PY
  ) || return 1
  [ "$NPM_TARGET" != "-" ] || NPM_TARGET=""
  [ -n "$NPM_LATEST" ]
}

npm_package_for_cli() {
  case "$1" in
    claude) printf '%s' '@anthropic-ai/claude-code' ;;
    codex) printf '%s' '@openai/codex' ;;
    npm|vercel|supabase) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

cli_is_npm() {
  local real
  real="$(real_path_of "$2")"
  case "$real" in */node_modules/*) npm_package_for_cli "$1" >/dev/null;; *) return 1;; esac
}

# Homebrew の node は npm を同梱していて、node を入れ直すたびに <prefix>/lib/node_modules/npm を同梱の版で上書きします。
# ここにある npm を npm i -g で上げても次の node の更新で同梱の版に戻るので、npm は node の更新で上げるものとして扱います。
# 同梱の npm の置き場は 2 通りです。
#   node        … <prefix>/Cellar/node/<版>/libexec/lib/node_modules/npm（<prefix>/opt/node/libexec/lib/node_modules/npm）
#   node@NN     … <prefix>/Cellar/node@NN/<版>/lib/node_modules/npm（libexec ではありません）
# 引数は npm の置き場所（npm root -g の下の npm か、npm コマンドの実体）。次のどれかなら同梱とします。
#   1. 実体が <prefix>/lib/node_modules/npm の下にあり、opt/node の libexec に同梱の npm がある（opt/node@* の libexec も見ますが、node@NN の同梱は libexec にありません）。
#   2. 実体が上の Cellar の置き場（node または node@NN）の下にある（node@NN だけを link した機）。
#   3. 実体が <prefix>/lib/node_modules/npm の下にあり、その package.json の実体が 2 の置き場の下にある（ファイル単位の link）。
# keg-only の node@NN の opt/node@NN/lib/node_modules/npm があるだけでは同梱としません。
# その場合の <prefix>/lib/node_modules/npm は、利用者が npm i -g npm で入れたもので、node の更新では上書きされないためです。
npm_is_homebrew_bundled() {
  local where="$1" prefix real keg package_real
  [ -n "$where" ] || return 1
  command -v brew >/dev/null 2>&1 || return 1
  prefix="$(run_timeout 30 brew --prefix 2>/dev/null || true)"
  [ -n "$prefix" ] || return 1
  prefix="$(real_path_of "$prefix")"
  real="$(real_path_of "$where")"
  if npm_path_in_homebrew_keg "$prefix" "$real"; then return 0; fi
  case "$real" in "$prefix/lib/node_modules/npm"|"$prefix/lib/node_modules/npm/"*) ;; *) return 1 ;; esac
  for keg in "$prefix"/opt/node "$prefix"/opt/node@*; do
    [ -f "$keg/libexec/lib/node_modules/npm/package.json" ] && return 0
  done
  package_real="$(real_path_of "$prefix/lib/node_modules/npm/package.json")"
  npm_path_in_homebrew_keg "$prefix" "$package_real"
}

# 実体のパスが、Homebrew の node または node@NN の Cellar の中の npm の置き場の下なら成功します。
npm_path_in_homebrew_keg() {
  local prefix="$1" real="$2"
  case "$real" in
    "$prefix"/Cellar/node/*/libexec/lib/node_modules/npm|"$prefix"/Cellar/node/*/libexec/lib/node_modules/npm/*) return 0 ;;
    "$prefix"/Cellar/node@*/*/lib/node_modules/npm|"$prefix"/Cellar/node@*/*/lib/node_modules/npm/*) return 0 ;;
  esac
  return 1
}

cli_remedy() {
  local tool="$1" path="$2" target="$3" real formula flag
  real="$(real_path_of "$path")"
  if cli_is_npm "$tool" "$path"; then
    flag="$(npm_install_flag "$tool")"
    printf 'npm install -g %s@%s%s' "$(npm_package_for_cli "$tool")" "$target" "${flag:+ $flag}"
    return
  fi
  case "$tool:$path:$real" in
    claude:*:*/.local/*|claude:*/.local/bin/claude:*) printf 'claude update で更新（公開日を確認してください）';;
    *:/opt/homebrew/*:*|*:/usr/local/*:*|*:*:*/Cellar/*|*:*:*/Caskroom/*)
      formula="$tool"
      case "$tool" in claude) formula=claude-code;; op) formula=1password-cli;; esac
      printf 'brew upgrade %s（入る版と公開日を確認してください）' "$formula";;
    *) printf '入れた方法で %s へ更新してください' "$target";;
  esac
}

# Claude Code の npm パッケージは、postinstall で本体の実行ファイルを置きます。
# npm 12 以降は許可のない install スクリプトを実行せず、本体が置かれないまま起動しなくなるので、claude のときだけ許可のフラグを付けます。
# このフラグを知らない古い npm でも、注意が出るだけで install は進みます。付けないツールは何も出しません。
npm_install_flag() {
  case "$1" in
    claude) printf '%s' "--allow-scripts=$(npm_package_for_cli claude)" ;;
  esac
}

# npm で入れ直したあと、実際に動く版が上げ先と同じになったときだけ成功とします。
# npm の終了コードだけでは、入れた先と動いている先が違う場合（別の置き場に入った・スクリプトが止められた）を見分けられません。
update_cli() {
  local tool="$1" path="$2" target="$3" package flag now
  cli_is_npm "$tool" "$path" && [ -n "$target" ] || return 1
  package="$(npm_package_for_cli "$tool")"
  flag="$(npm_install_flag "$tool")"
  if [ -n "$flag" ]; then
    run_timeout 600 npm install -g "${package}@${target}" "$flag" >/dev/null 2>&1 || return 1
  else
    run_timeout 600 npm install -g "${package}@${target}" >/dev/null 2>&1 || return 1
  fi
  now="$(current_version "$path" || true)"
  [ "$now" = "$target" ]
}

check_cli_tools() {
  local tool path current latest target duplicate duplicate_version current_major latest_major
  local package wait_note remedy
  if [ "$RH_SKIP_CLI" = "1" ]; then
    NOTES[${#NOTES[@]}]="CLI 更新確認は止めています（設定 RH_SKIP_CLI=1）"
    return
  fi
  for tool in claude codex node npm gh vercel supabase op; do
    path="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$path" ] || continue
    current="$(current_version "$path" || true)"
    [ -n "$current" ] || { NOTES[${#NOTES[@]}]="$tool — 現在版を判定できません"; continue; }
    while IFS= read -r duplicate; do
      [ -n "$duplicate" ] && [ "$duplicate" != "$path" ] || continue
      duplicate_version="$(current_version "$duplicate" || true)"
      [ -n "$duplicate_version" ] || duplicate_version="起動不能"
      if [ "$duplicate_version" != "$current" ]; then
        add_warning "$tool — 重複インストール（採用=$path:$current / 他=$duplicate:${duplicate_version}）"
      fi
    done < <(type -aP "$tool" 2>/dev/null | LC_ALL=C sort -u)
    target=""; wait_note=""
    if npm_package_for_cli "$tool" >/dev/null && ! command -v npm >/dev/null 2>&1; then
      NOTES[${#NOTES[@]}]="$tool — npm 不在のため公開日・更新先は未検査"
      continue
    fi
    if package="$(npm_package_for_cli "$tool" 2>/dev/null)"; then
      if npm_release_info "$package" "$current"; then
        latest="$NPM_LATEST"
        target="$NPM_TARGET"
        if [ "$NPM_LATEST_WAIT" = "1" ]; then
          wait_note="（最新 ${latest} は ${NPM_LATEST_DATE} 公開・3 日待ち）"
        fi
      else
        latest=""
      fi
    else
      latest="$(latest_version "$tool" || true)"
      target="$latest"
    fi
    if [ -z "$latest" ]; then
      NOTES[${#NOTES[@]}]="$tool — 最新版を取得できず未検査"
      continue
    fi
    if version_less_than "$current" "$latest"; then
      if [ -z "$target" ] || ! version_less_than "$current" "$target"; then
        if [ -n "$wait_note" ]; then
          CLI_UPDATES[${#CLI_UPDATES[@]}]="$tool — 現在 $current ${wait_note}"
        else
          NOTES[${#NOTES[@]}]="$tool — 3 日以上前に公開された上げ先を取得できず未検査"
        fi
        continue
      fi
      current_major="${current%%.*}"; latest_major="${target%%.*}"
      if [ "$tool" = npm ] && npm_is_homebrew_bundled "$path"; then
        CLI_UPDATES[${#CLI_UPDATES[@]}]="npm — $current → ${target}（Homebrew の node に付いてくる版です。npm i -g で上げても node の更新で戻るため、node の更新で上がるのを待ちます）"
        continue
      fi
      if [ "$tool" = node ] && [ -f "$SECURITY_MINIMUMS" ]; then
        lookup_minimum_row node "$current"
        if [ -n "$MIN_ROW_MINIMUM" ] && [ "$MIN_ROW_MINIMUM" != EOL ]; then
          CLI_UPDATES[${#CLI_UPDATES[@]}]="node — サポート中の LTS 系列 $current → $target"
          continue
        fi
      fi
      remedy="$(cli_remedy "$tool" "$path" "$target")"
      if ! cli_is_npm "$tool" "$path"; then
        add_warning "$tool $current → ${target}（${remedy}）${wait_note}"
        if [ "$tool" = claude ] && [ "$latest_major" -gt "$current_major" ]; then real_path_of "$path" >> "$TMP_DIR/cli-major-warned.claude"; fi
        continue
      fi
      if [ "$latest_major" -gt "$current_major" ]; then
        if [ "$tool" = npm ]; then
          # npm 本体のメジャー版は、依存の install スクリプトの扱いなど install の挙動が変わるため、RH_AUTOFIX_CLI=1 でも自動では上げません。
          add_warning "npm — メジャー版が遅れています $current → ${target}（${remedy}）${wait_note}。npm のメジャー版は install の挙動が変わるため自動では上げません。上げる前に動作を確かめてください"
        elif [ "$RH_AUTOFIX_CLI" = "1" ] && update_cli "$tool" "$path" "$target"; then
          AUTOFIXED[${#AUTOFIXED[@]}]="$tool — メジャー版遅れ $current → $target を自動更新"
        else
          add_warning "$tool — メジャー版が遅れています $current → ${target}（${remedy}）${wait_note}"
          [ "$tool" != "claude" ] || real_path_of "$path" >> "$TMP_DIR/cli-major-warned.claude"
        fi
      elif [ "$RH_AUTOFIX_CLI" = "1" ]; then
        # RH_AUTOFIX_CLI=1 のときだけ、npm で入れた CLI のマイナー・パッチ遅れも、公開から 3 日以上の上げ先へ更新します。
        if update_cli "$tool" "$path" "$target"; then
          AUTOFIXED[${#AUTOFIXED[@]}]="$tool — $current → $target を自動更新"
        else
          add_warning "$tool — $current → ${target} の自動更新に失敗しました（${remedy}）${wait_note}"
        fi
      else
        CLI_UPDATES[${#CLI_UPDATES[@]}]="$tool — $current → $target${wait_note}"
      fi
    elif [ "$current" != "$latest" ]; then
      NOTES[${#NOTES[@]}]="$tool — 公開最新版より先行（現在 $current / 公開 ${latest}）"
    fi
  done
}

security_detail() {
  add_detail "Mac のセキュリティ — $*"
}

# 判定表（security-minimums.tsv）から、部品と版に当たる行を探します。結果は MIN_ROW_* に入ります。
# 系列は x.y → x → * の順に探し、いちばん細かく当たった行を採ります。
# 系列の列が EOL の行は、最低版の列の値（これより古い版は修正版が出ない）を MIN_ROW_EOL_THRESHOLD に入れます。
lookup_minimum_row() {
  local component="$1" version="$2" major rest minor series level
  local row_component row_series row_minimum row_reason
  MIN_ROW_OLDEST=""; MIN_ROW_MINIMUM=""; MIN_ROW_REASON=""; MIN_ROW_EOL_THRESHOLD=""; MIN_ROW_EOL_REASON=""
  major="${version%%.*}"
  series="$major"
  case "$version" in
    *.*) rest="${version#*.}"; minor="${rest%%.*}"; series="${major}.${minor}" ;;
  esac
  level=0
  while IFS=$'\t' read -r row_component row_series row_minimum row_reason; do
    case "$row_component" in ''|\#*) continue;; esac
    [ "$row_component" = "$component" ] || continue
    case "$row_series" in
      [0-9]*)
        if [ -z "$MIN_ROW_OLDEST" ] || version_less_than "$row_series" "$MIN_ROW_OLDEST"; then MIN_ROW_OLDEST="$row_series"; fi;;
    esac
    if [ "$row_series" = "EOL" ]; then
      MIN_ROW_EOL_THRESHOLD="$row_minimum"; MIN_ROW_EOL_REASON="$row_reason"
    elif [ "$row_series" = "$series" ]; then
      MIN_ROW_MINIMUM="$row_minimum"; MIN_ROW_REASON="$row_reason"; level=3
    elif [ "$row_series" = "$major" ] && [ "$level" -lt 3 ]; then
      MIN_ROW_MINIMUM="$row_minimum"; MIN_ROW_REASON="$row_reason"; level=2
    elif [ "$row_series" = "*" ] && [ "$level" -lt 2 ]; then
      MIN_ROW_MINIMUM="$row_minimum"; MIN_ROW_REASON="$row_reason"; level=1
    fi
  done < "$SECURITY_MINIMUMS"
}

warn_old_series() {
  if [ -z "$MIN_ROW_MINIMUM" ] && [ -n "$MIN_ROW_OLDEST" ] && version_less_than "$2" "$MIN_ROW_OLDEST"; then
    add_warning "$1 $2 — 古い系列（表の最低系列 ${MIN_ROW_OLDEST} より前）。サポート中の系列へ更新してください"
    return 0
  fi
  return 1
}

# 文字列の先頭にある数字の版（1〜4 桁）だけを取り出します。取れなければ何も出しません。
leading_version() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eo '^[0-9]+(\.[0-9]+){0,3}' | head -1
}

real_path_of() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || printf '%s\n' "$1"
}

check_macos_minimum() {
  local version major
  if [ ! -f "$SECURITY_MINIMUMS" ]; then
    NOTES[${#NOTES[@]}]="macOS の最低版は同梱リスト不足のため未検査"
    return
  fi
  if [ -n "${RH_MACOS_VERSION+x}" ]; then
    version="$RH_MACOS_VERSION"
  else
    version="$(sw_vers -productVersion 2>/dev/null || true)"
  fi
  version="$(leading_version "$version")"
  major="${version%%.*}"
  if [ -z "$version" ] || ! is_uint "$major"; then
    NOTES[${#NOTES[@]}]="macOS — 版を判定できず未検査"
    return
  fi
  lookup_minimum_row macos "$version"
  warn_old_series macOS "$version" && return
  if [ -n "$MIN_ROW_MINIMUM" ] && [ "$MIN_ROW_MINIMUM" != "EOL" ]; then
    if version_less_than "$version" "$MIN_ROW_MINIMUM"; then
      add_warning "macOS ${version} は修正版 ${MIN_ROW_MINIMUM} より古い版です（${MIN_ROW_REASON}）。ソフトウェアアップデートで更新してください"
    else
      security_detail "macOS ${version} — 最低版 ${MIN_ROW_MINIMUM} 以上"
    fi
  elif [ "$MIN_ROW_MINIMUM" = "EOL" ]; then
    add_warning "macOS ${version} はサポート終了の系列です（${MIN_ROW_REASON}）。この系列には修正版が出ていません。新しい macOS へ更新してください"
  elif [ -n "$MIN_ROW_EOL_THRESHOLD" ] && version_less_than "$version" "$MIN_ROW_EOL_THRESHOLD"; then
    add_warning "macOS ${version} はサポート終了の系列です（${MIN_ROW_EOL_REASON}）。この系列には修正版が出ていません。新しい macOS へ更新してください"
  else
    security_detail "macOS ${version} — この系列は最低版リストに未掲載"
  fi
}

check_claude_minimum() {
  local candidates ordered seen_real raw real version cli_marker
  if [ ! -f "$SECURITY_MINIMUMS" ]; then
    NOTES[${#NOTES[@]}]="Claude Code の最低版は同梱リスト不足のため未検査"
    return
  fi
  candidates="$TMP_DIR/claude-candidates.list"
  ordered="$TMP_DIR/claude-ordered.list"
  seen_real="$TMP_DIR/claude-seen.list"
  cli_marker="$TMP_DIR/cli-major-warned.claude"
  : > "$candidates"; : > "$seen_real"
  if [ -n "${RH_CLAUDE_CANDIDATES+x}" ]; then
    printf '%s\n' "$RH_CLAUDE_CANDIDATES" >> "$candidates"
  else
    type -aP claude 2>/dev/null >> "$candidates" || true
    [ -x "$HOME/.claude/local/claude" ] && printf '%s\n' "$HOME/.claude/local/claude" >> "$candidates"
    [ -x "$HOME/.local/bin/claude" ] && printf '%s\n' "$HOME/.local/bin/claude" >> "$candidates"
  fi
  # 見つけた順を保ったまま、同じパスの重複を除く
  awk 'NF && !seen[$0]++' "$candidates" > "$ordered"
  while IFS= read -r raw; do
    [ -f "$raw" ] && [ -x "$raw" ] || continue
    real="$(real_path_of "$raw")"
    if LC_ALL=C grep -Fqx "$real" "$seen_real" 2>/dev/null; then continue; fi
    printf '%s\n' "$real" >> "$seen_real"
    version="$(run_timeout 20 "$raw" --version 2>/dev/null | head -1 | LC_ALL=C grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -z "$version" ]; then
      NOTES[${#NOTES[@]}]="Claude Code（$(quote_name "$raw")）— 版を判定できず未検査"
      continue
    fi
    lookup_minimum_row claude "$version"
    warn_old_series "Claude Code" "$version" && continue
    if [ -z "$MIN_ROW_MINIMUM" ] || [ "$MIN_ROW_MINIMUM" = "EOL" ]; then
      security_detail "Claude Code ${version}（$(quote_name "$raw")）— この系列は最低版リストに未掲載"
    elif ! version_less_than "$version" "$MIN_ROW_MINIMUM"; then
      security_detail "Claude Code ${version}（$(quote_name "$raw")）— 最低版 ${MIN_ROW_MINIMUM} 以上"
    elif [ -f "$cli_marker" ] && LC_ALL=C grep -Fqx "$real" "$cli_marker" 2>/dev/null; then
      # CLI の更新確認がすでに「メジャー版が遅れています」の WARN にしている。同じ版の話を 2 度 WARN にしない
      security_detail "Claude Code ${version}（$(quote_name "$raw")）は修正版 ${MIN_ROW_MINIMUM} より古い版です（${MIN_ROW_REASON}）— CLI の更新確認の WARN と同じ話のため、WARN は 1 件にまとめています"
    else
      add_warning "Claude Code ${version}（$(quote_name "$raw")）は修正版 ${MIN_ROW_MINIMUM} より古い版です（${MIN_ROW_REASON}）。claude update で更新してください（npm で入れた場合は npm install -g @anthropic-ai/claude-code@latest）"
    fi
  done < "$ordered"
}

# Bun の CLI の版を、判定表（bun）の最低版と比べます。Bun は起動せず --version だけを呼びます。
# 候補は type -aP bun と ~/.bun/bin/bun（RH_BUN_CANDIDATES があればそれだけ。テスト用）で、実体が同じものは 1 度だけ見ます。
check_bun_minimum() {
  local candidates ordered seen_real raw real version remedy
  if [ ! -f "$SECURITY_MINIMUMS" ]; then
    NOTES[${#NOTES[@]}]="Bun の最低版は同梱リスト不足のため未検査"
    return
  fi
  candidates="$TMP_DIR/bun-candidates.list"
  ordered="$TMP_DIR/bun-ordered.list"
  seen_real="$TMP_DIR/bun-seen.list"
  : > "$candidates"; : > "$seen_real"
  if [ -n "${RH_BUN_CANDIDATES+x}" ]; then
    printf '%s\n' "$RH_BUN_CANDIDATES" >> "$candidates"
  else
    type -aP bun 2>/dev/null >> "$candidates" || true
    [ -x "$HOME/.bun/bin/bun" ] && printf '%s\n' "$HOME/.bun/bin/bun" >> "$candidates"
  fi
  # 見つけた順を保ったまま、同じパスの重複を除く
  awk 'NF && !seen[$0]++' "$candidates" > "$ordered"
  while IFS= read -r raw; do
    [ -f "$raw" ] && [ -x "$raw" ] || continue
    real="$(real_path_of "$raw")"
    if LC_ALL=C grep -Fqx "$real" "$seen_real" 2>/dev/null; then continue; fi
    printf '%s\n' "$real" >> "$seen_real"
    version="$(run_timeout 20 "$raw" --version 2>/dev/null | head -1 | LC_ALL=C grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -z "$version" ]; then
      NOTES[${#NOTES[@]}]="Bun（$(quote_name "$raw")）— 版を判定できず未検査"
      continue
    fi
    lookup_minimum_row bun "$version"
    warn_old_series "Bun" "$version" && continue
    if [ -z "$MIN_ROW_MINIMUM" ] || [ "$MIN_ROW_MINIMUM" = "EOL" ]; then
      security_detail "Bun ${version}（$(quote_name "$raw")）— この系列は最低版リストに未掲載"
      continue
    fi
    if ! version_less_than "$version" "$MIN_ROW_MINIMUM"; then
      security_detail "Bun ${version}（$(quote_name "$raw")）— 最低版 ${MIN_ROW_MINIMUM} 以上"
      continue
    fi
    remedy="入れた方法で更新してください"
    case "$raw:$real" in
      "$HOME/.bun/bin/bun":*|*:"$HOME/.bun/bin/bun") remedy="bun upgrade で更新してください" ;;
      *:*/Cellar/bun/*|*/Cellar/bun/*:*) remedy="brew upgrade bun で更新してください" ;;
    esac
    add_warning "Bun ${version}（$(quote_name "$raw")）は修正版 ${MIN_ROW_MINIMUM} より古い版です（${MIN_ROW_REASON}）。${remedy}"
  done < "$ordered"
}

# .app のフォルダを 1 行ずつ出します。/Applications は 1 段下（/Applications/*/*.app）まで、~/Applications は直下だけ。
# RH_APP_DIRS（改行区切りのフォルダ一覧）があれば、それだけを 1 段下まで探します（テスト用）。
list_app_bundles() {
  local root
  if [ -n "${RH_APP_DIRS+x}" ]; then
    while IFS= read -r root; do
      [ -n "$root" ] && [ -d "$root" ] || continue
      find "$root" -mindepth 1 -maxdepth 2 -type d -name '*.app' -prune -print 2>/dev/null
    done <<EOF
$RH_APP_DIRS
EOF
    return
  fi
  [ -d /Applications ] && find /Applications -mindepth 1 -maxdepth 2 -type d -name '*.app' -prune -print 2>/dev/null
  [ -d "$HOME/Applications" ] && find "$HOME/Applications" -mindepth 1 -maxdepth 1 -type d -name '*.app' -prune -print 2>/dev/null
  return 0
}

plist_value() {
  local value
  if value="$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)" && [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  value="$(/usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null)" || return 1
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

check_app_minimums() {
  local apps app plist bundle component raw_version version label remedy running read_count=0
  if [ ! -f "$SECURITY_MINIMUMS" ]; then
    NOTES[${#NOTES[@]}]="アプリの最低版は同梱リスト不足のため未検査"
    return
  fi
  apps="$TMP_DIR/app-bundles.list"
  list_app_bundles | awk 'NF && !seen[$0]++' > "$apps"
  while IFS= read -r app; do
    plist="$app/Contents/Info.plist"
    [ -f "$plist" ] || continue
    # アプリは起動せず、Info.plist だけを読む
    bundle="$(plist_value "$plist" CFBundleIdentifier 2>/dev/null || true)"
    [ -n "$bundle" ] || continue
    read_count=$((read_count + 1))
    component="app:${bundle}"
    awk -F '\t' -v component="$component" '$1 == component { found=1 } END { exit !found }' "$SECURITY_MINIMUMS" || continue
    raw_version="$(plist_value "$plist" CFBundleShortVersionString 2>/dev/null || true)"
    version="$(leading_version "$raw_version")"
    if [ -z "$version" ]; then
      raw_version="$(plist_value "$plist" CFBundleVersion 2>/dev/null || true)"
      version="$(leading_version "$raw_version")"
    fi
    if [ -z "$version" ]; then
      NOTES[${#NOTES[@]}]="${bundle}（$(quote_name "$app")）— 版を判定できず未検査"
      continue
    fi
    if [ "$bundle" = "org.mozilla.firefox" ] \
      && LC_ALL=C grep -qi 'esr' "$app/Contents/Resources/defaults/pref/channel-prefs.js" 2>/dev/null; then
      NOTES[${#NOTES[@]}]="Firefox ESR（$(quote_name "$app")）— ESR の系列は未検査"
      continue
    fi
    lookup_minimum_row "$component" "$version"
    warn_old_series "$component" "$version" && continue
    if [ -z "$MIN_ROW_MINIMUM" ] || [ "$MIN_ROW_MINIMUM" = "EOL" ]; then
      security_detail "${bundle} ${version}（$(quote_name "$app")）— この系列は最低版リストに未掲載"
      continue
    fi
    if ! version_less_than "$version" "$MIN_ROW_MINIMUM"; then
      security_detail "${bundle} ${version}（$(quote_name "$app")）— 最低版 ${MIN_ROW_MINIMUM} 以上"
      continue
    fi
    label="$bundle"; remedy="アプリを最新版へ更新してください"
    case "$bundle" in
      com.google.Chrome) label="Chrome"; remedy="Chrome を再起動すると更新されます（設定 → Chrome について）" ;;
      org.mozilla.firefox) label="Firefox"; remedy="メニュー → Firefox について で更新" ;;
      com.anthropic.claudefordesktop) label="Claude Desktop"; remedy="Claude を開いて更新（メニュー → 更新を確認）" ;;
      com.plexapp.plexmediaserver)
        label="Plex Media Server"
        remedy="Plex Media Server を ${MIN_ROW_MINIMUM} 以上へ。動いていた場合は、侵害されていないかの確認も必要です（Plex の告知）"
        ;;
    esac
    running="no"
    if [ "$bundle" = "com.plexapp.plexmediaserver" ] && command -v pgrep >/dev/null 2>&1 \
      && pgrep -x "Plex Media Server" >/dev/null 2>&1; then
      running="yes"
    fi
    if [ "$running" = "yes" ]; then
      # サーバーとして外から攻撃される（実際に悪用されている）ので FAIL にする
      add_failure "${label} ${version}（$(quote_name "$app")）が動いています。修正版 ${MIN_ROW_MINIMUM} より古い版です（${MIN_ROW_REASON}）。${remedy}"
    else
      add_warning "${label} ${version}（$(quote_name "$app")）は修正版 ${MIN_ROW_MINIMUM} より古い版です（${MIN_ROW_REASON}）。${remedy}"
    fi
  done < "$apps"
  if [ -s "$apps" ] && [ "$read_count" -eq 0 ]; then
    NOTES[${#NOTES[@]}]="アプリの最低版は Info.plist を一件も読めず未検査"
  fi
}

# Electron 製のアプリ（Contents/Frameworks/Electron Framework.framework を持つ .app）の参考表示です。
# Chromium と Node を抱えるため版では判断できません。Info.plist の更新日が、判定表（electron-after）の日付より前なら
# 「その日より前の版のままかもしれない」と NOTES に 1 件ずつ出します。版は比べず、WARN にもしません。
# アプリは起動せず、Info.plist の中身と更新日だけを見ます。
check_electron_apps() {
  local apps app plist after name version raw_version plist_date
  if [ ! -f "$SECURITY_MINIMUMS" ]; then
    NOTES[${#NOTES[@]}]="Electron 製アプリの更新確認は同梱リスト不足のため未検査"
    return
  fi
  lookup_minimum_row electron-after 0
  after="$MIN_ROW_MINIMUM"
  if ! printf '%s\n' "$after" | LC_ALL=C grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    NOTES[${#NOTES[@]}]="Electron 製アプリの更新確認は判定表に基準日（electron-after）が無いため未検査"
    return
  fi
  apps="$TMP_DIR/electron-app-bundles.list"
  list_app_bundles | awk 'NF && !seen[$0]++' > "$apps"
  while IFS= read -r app; do
    [ -d "$app/Contents/Frameworks/Electron Framework.framework" ] || continue
    plist="$app/Contents/Info.plist"
    [ -f "$plist" ] || continue
    plist_date="$(TZ=Asia/Tokyo /usr/bin/stat -f '%Sm' -t '%Y-%m-%d' "$plist" 2>/dev/null || true)"
    if ! printf '%s\n' "$plist_date" | LC_ALL=C grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
      NOTES[${#NOTES[@]}]="${app} — Electron 製ですが更新日を取得できず未検査"
      continue
    fi
    if [ "${plist_date//-/}" -ge "${after//-/}" ]; then
      security_detail "Electron 製アプリ ${app}（${plist_date} 更新）— 基準日 ${after} 以降"
      continue
    fi
    name="${app##*/}"
    name="${name%.app}"
    version=""
    if [ -f "$plist" ]; then
      raw_version="$(plist_value "$plist" CFBundleShortVersionString 2>/dev/null || true)"
      version="$(leading_version "$raw_version")"
      if [ -z "$version" ]; then
        raw_version="$(plist_value "$plist" CFBundleVersion 2>/dev/null || true)"
        version="$(leading_version "$raw_version")"
      fi
    fi
    [ -z "$version" ] || name="${name} ${version}"
    NOTES[${#NOTES[@]}]="${name}（${plist_date} 更新）は、Brotli の修正（${after}）より前の版のままかもしれません。アプリの「更新を確認」で最新にしてください"
  done < "$apps"
}

# Homebrew の formula の版が、判定表（brew:<formula>）の最低版より古いかを調べます。
# 古ければ 0 を返し、BREW_MIN_MINIMUM と BREW_MIN_REASON に最低版と理由を入れます。
# Homebrew の版は 8.22.0_1 のように _ で修正番号が付くため、_ より前だけで比べます。
brew_below_minimum() {
  local formula="$1" version="${2%%_*}"
  BREW_MIN_MINIMUM=""; BREW_MIN_REASON=""
  [ -f "$SECURITY_MINIMUMS" ] || return 1
  lookup_minimum_row "brew:${formula}" "$version"
  [ -n "$MIN_ROW_MINIMUM" ] && [ "$MIN_ROW_MINIMUM" != "EOL" ] || return 1
  version_less_than "$version" "$MIN_ROW_MINIMUM" || return 1
  BREW_MIN_MINIMUM="$MIN_ROW_MINIMUM"; BREW_MIN_REASON="$MIN_ROW_REASON"
  return 0
}

# Homebrew の formula（curl・openssl@3 など）の版を点検します。Apple 標準の curl・LibreSSL は
# Apple の更新でしか直らないため比べません（TLS の点検の注記と同じ扱い）。
check_brew_formula_minimums() {
  local brew_cmd formulas formula output version words warned_file
  local row_component _row_series _row_minimum _row_reason
  [ -f "$SECURITY_MINIMUMS" ] || return
  if [ -n "${RH_BREW+x}" ]; then brew_cmd="$RH_BREW"; else brew_cmd="$(command -v brew 2>/dev/null || true)"; fi
  [ -n "$brew_cmd" ] && [ -x "$brew_cmd" ] || return
  formulas="$TMP_DIR/brew-minimum-formulas.list"
  warned_file="$TMP_DIR/brew-security-warned.list"
  : > "$formulas"
  while IFS=$'\t' read -r row_component _row_series _row_minimum _row_reason; do
    case "$row_component" in brew:*) printf '%s\n' "${row_component#brew:}" >> "$formulas";; esac
  done < "$SECURITY_MINIMUMS"
  LC_ALL=C sort -u "$formulas" > "$formulas.sorted"
  if ! run_timeout 30 "$brew_cmd" list --versions > "$TMP_DIR/brew-minimum-installed" 2>/dev/null; then
    NOTES[${#NOTES[@]}]="Homebrew の最低版は導入済み版を取得できず未検査"
    return
  fi
  while IFS= read -r formula; do
    [ -n "$formula" ] || continue
    output="$(awk -v name="$formula" '$1 == name { print }' "$TMP_DIR/brew-minimum-installed")"
    [ -n "$output" ] || continue
    read -r -a words <<EOF
$output
EOF
    [ "${#words[@]}" -gt 1 ] || continue
    # 1 つ目は formula 名。2 つ目からが入っている版（複数あればそれぞれ比べる）
    for version in "${words[@]:1}"; do
      if brew_below_minimum "$formula" "$version"; then
        if [ -f "$warned_file" ] && LC_ALL=C grep -Fqx "$formula" "$warned_file" 2>/dev/null; then
          # check_brew_security の「更新が出ています」の WARN が、すでにこの formula を理由つきで知らせている
          security_detail "Homebrew の ${formula} ${version} は修正版 ${BREW_MIN_MINIMUM} より古い版です（${BREW_MIN_REASON}）— 更新待ちの WARN と同じ話のため、WARN は 1 件にまとめています"
        else
          add_warning "Homebrew の ${formula} ${version} は修正版 ${BREW_MIN_MINIMUM} より古い版です（${BREW_MIN_REASON}）。brew upgrade ${formula} で更新してください"
        fi
      elif warn_old_series "Homebrew の $formula" "${version%%_*}"; then
        :
      elif [ -n "$MIN_ROW_MINIMUM" ] && [ "$MIN_ROW_MINIMUM" != "EOL" ]; then
        security_detail "Homebrew の ${formula} ${version} — 最低版 ${MIN_ROW_MINIMUM} 以上"
      else
        security_detail "Homebrew の ${formula} ${version} — この系列は最低版リストに未掲載"
      fi
    done
  done < "$formulas.sorted"
}

brew_formula_is_security() {
  local formula="$1" pattern
  [ -f "$SECURITY_PACKAGES" ] || return 1
  while IFS= read -r pattern; do
    case "$pattern" in ''|\#*) continue;; esac
    # shellcheck disable=SC2254  # 設定表の node@* などを glob として照合します。
    case "$formula" in $pattern) return 0;; esac
  done < "$SECURITY_PACKAGES"
  return 1
}

brew_revision_only() {
  local old="$1" latest="$2" version revision old_revision
  local -a versions
  IFS=',' read -r -a versions <<EOF
$old
EOF
  [ "${#versions[@]}" -gt 0 ] || return 1
  case "$latest" in
    *_*) revision="${latest##*_}"; is_uint "$revision" || return 1;;
    *) return 1;;
  esac
  for version in "${versions[@]}"; do
    [ "${version%_*}" = "${latest%_*}" ] || return 1
    old_revision=0
    case "$version" in *_*) old_revision="${version##*_}"; is_uint "$old_revision" || return 1;; esac
    [ "$revision" -gt "$old_revision" ] || return 1
  done
  return 0
}

brew_snapshot() {
  if run_timeout 30 brew list --versions > "$1" 2>/dev/null; then return 0; fi
  NOTES[${#NOTES[@]}]="Homebrew の導入済み版を取得できず未検査"
  return 1
}

# 名指し以外の更新も記録し、後の linkage 点検へ渡します。
brew_record_changes() {
  local before="$1" after="$2" requested="$3" suffix="${4-}" name old new detail
  local changes="$TMP_DIR/brew-version-changes.tsv"
  # 上げたあとは「新しい版の出ている formula」の一覧を取り直します。
  rm -f "$TMP_DIR/brew-outdated-formulae.list"
  python3 -I - "$before" "$after" > "$changes" 2>/dev/null <<'PY'
import sys
def read(path):
    result = {}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            parts = raw.split()
            if len(parts) >= 2:
                result[parts[0]] = ",".join(parts[1:])
    return result
before, after = (read(path) for path in sys.argv[1:])
for name, new in after.items():
    old = before.get(name, "未導入")
    if new != old:
        print(f"{name}\t{old}\t{new}")
PY
  while IFS=$'\t' read -r name old new; do
    detail="$suffix"
    if ! grep -Fqx "$name" "$requested"; then detail="（巻き込みで更新）"; fi
    AUTOFIXED[${#AUTOFIXED[@]}]="Homebrew: $name $old → $new${detail}"
    printf '%s\n' "$name" >> "$TMP_DIR/brew-updated.list"
  done < "$changes"
}

brew_prepare_pins() {
  local output="$TMP_DIR/brew-pinned.list"
  [ -f "$output" ] && return
  if ! run_timeout 30 brew list --pinned > "$output" 2>/dev/null; then
    rm -f "$output"
    NOTES[${#NOTES[@]}]="Homebrew の pin 一覧を取得できず未検査"
    return 1
  fi
}

# 新しい版の出ている formula の名前の一覧を作ります。取れなければ 1。
brew_prepare_outdated() {
  local output="$TMP_DIR/brew-outdated-formulae.list" json="$TMP_DIR/brew-outdated-formulae.json"
  [ -f "$output" ] && return 0
  if run_timeout 300 brew outdated --formula --json=v2 > "$json" 2>/dev/null \
    && python3 -I - "$json" > "$output.tmp" 2>/dev/null <<'PYOUTDATED'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
formulae = data.get("formulae")
if not isinstance(formulae, list):
    raise SystemExit(1)
for formula in formulae:
    if not isinstance(formula, dict) or not isinstance(formula.get("name"), str):
        raise SystemExit(1)
    print(formula["name"])
    if isinstance(formula.get("full_name"), str) and formula["full_name"] != formula["name"]:
        print(formula["full_name"])
PYOUTDATED
  then
    mv "$output.tmp" "$output"
    return 0
  fi
  rm -f "$output.tmp"
  return 1
}

brew_formula_is_protected() {
  local name="$1"
  software_is_ignored "$name" && return 0
  if [ -f "$TMP_DIR/brew-pinned.list" ] && grep -Fqx "$name" "$TMP_DIR/brew-pinned.list"; then return 0; fi
  if [ "$RH_AUTOFIX_SECURITY" != "1" ] && brew_formula_is_security "$name"; then
    # 今回、安全に当てた同じ版の改訂は依存先にも使えます。
    if [ -f "$TMP_DIR/brew-revision-fixed.list" ] && grep -Fqx "$name" "$TMP_DIR/brew-revision-fixed.list"; then return 1; fi
    return 0
  fi
  return 1
}

brew_formula_safe_to_upgrade() {
  local name="$1" dependency outdated_known
  local deps="$TMP_DIR/brew-deps.list" uses="$TMP_DIR/brew-uses.list"
  brew_prepare_pins || return 1
  if ! run_timeout 30 brew uses --installed --recursive "$name" > "$uses" 2>/dev/null \
    || ! run_timeout 30 brew deps --installed "$name" > "$deps" 2>/dev/null; then
    NOTES[${#NOTES[@]}]="Homebrew の ${name} の依存関係を取得できず自動更新は未検査"
    return 1
  fi
  outdated_known=0
  brew_prepare_outdated && outdated_known=1
  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    # 新しい版の出ていない依存先は brew upgrade が触らないので、巻き込みは起きません。
    # 一覧が取れないときは、今までどおり依存先を全部見ます。
    if [ "$outdated_known" = "1" ] && ! grep -Fqx "$dependency" "$TMP_DIR/brew-outdated-formulae.list"; then continue; fi
    if brew_formula_is_protected "$dependency"; then
      add_warning "$name は $dependency を一緒に上げるため自動更新しませんでした"
      return 1
    fi
  done < "$deps"
  # 呼び出し側では依存元の保護を常に有効にします。uses は修復の対象一覧にも使います。
  return 0
}

check_brew_security() {
  local outdated_json rows remaining name installed latest description brew_prefix item installed_version pinned
  local before="$TMP_DIR/brew-security-before.list" after="$TMP_DIR/brew-security-after.list"
  local requested="$TMP_DIR/brew-security-requested.list" pending="$TMP_DIR/brew-security-pending.list"
  local revision suffix attempt
  local -a installed_versions
  command -v brew >/dev/null 2>&1 || return
  if ! run_timeout 300 brew update --quiet >/dev/null 2>&1; then
    NOTES[${#NOTES[@]}]="Homebrew の更新情報を取得できず未検査"
    return
  fi
  if [ ! -f "$SECURITY_PACKAGES" ]; then
    NOTES[${#NOTES[@]}]="Homebrew のセキュリティ部品は同梱リスト不足のため未検査"
    return
  fi
  outdated_json="$TMP_DIR/brew-outdated.json"
  if ! run_timeout 300 brew outdated --json=v2 > "$outdated_json" 2>/dev/null; then
    NOTES[${#NOTES[@]}]="Homebrew のセキュリティ部品は更新待ちを取得できず未検査"
    return
  fi
  rows="$TMP_DIR/brew-security.tsv"
  if ! python3 - "$outdated_json" "$SECURITY_PACKAGES" > "$rows" 2>/dev/null <<'PYSEC'
import fnmatch
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    patterns = [raw.strip() for raw in handle if raw.strip() and not raw.startswith("#")]
formulae = data.get("formulae")
if not isinstance(formulae, list):
    raise SystemExit(1)
for formula in formulae:
    if not isinstance(formula, dict):
        continue
    name = str(formula.get("name", ""))
    if not any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns):
        continue
    installed = formula.get("installed_versions", [])
    old = ",".join(str(item) for item in installed) if isinstance(installed, list) else str(installed)
    new = formula.get("current_version") or formula.get("stable") or "不明"
    print(f"{name}\t{old or '不明'}\t{new}\t{int(bool(formula.get('pinned')))}")
PYSEC
  then
    NOTES[${#NOTES[@]}]="Homebrew のセキュリティ部品は応答不正のため未検査"
    return
  fi
  remaining="$TMP_DIR/brew-security-remaining.tsv"
  : > "$remaining"
  brew_prepare_pins || return
  while IFS=$'\t' read -r name installed latest pinned; do
    if [ "$pinned" = "1" ] || grep -Fqx "$name" "$TMP_DIR/brew-pinned.list"; then
      NOTES[${#NOTES[@]}]="Homebrew の ${name} は pin 中（brew unpin ${name} で更新対象に戻せます）"
      continue
    fi
    revision=0; suffix=""; attempt=0
    if [ "$RH_AUTOFIX_SOFTWARE" = "1" ] && brew_revision_only "$installed" "$latest"; then
      revision=1; suffix="（同じ版の作り直し）"; attempt=1
    fi
    [ "$RH_AUTOFIX_SECURITY" != "1" ] || attempt=1
    if [ "$name" = "ca-certificates" ] && [ "$RH_AUTOFIX_CA_CERTS" = "1" ]; then attempt=1; fi
    if [ "$attempt" = "1" ] && ! software_is_ignored "$name" \
      && brew_formula_safe_to_upgrade "$name" && brew_snapshot "$before"; then
      printf '%s\n' "$name" > "$requested"
      HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
        run_timeout 900 brew upgrade "$name" >/dev/null 2>&1 || true
      if brew_snapshot "$after"; then brew_record_changes "$before" "$after" "$requested" "$suffix"; fi
      if run_timeout 300 brew outdated --json=v2 > "$outdated_json" 2>/dev/null \
        && python3 -I - "$outdated_json" > "$pending" 2>/dev/null <<'PYPENDING'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
if not isinstance(data.get("formulae"), list):
    raise SystemExit(1)
for formula in data["formulae"]:
    print(formula["name"])
PYPENDING
      then
        if ! grep -Fqx "$name" "$pending"; then
          if [ "$revision" = "1" ]; then printf '%s\n' "$name" >> "$TMP_DIR/brew-revision-fixed.list"; fi
          continue
        fi
      else
        NOTES[${#NOTES[@]}]="Homebrew の ${name} は更新後の確認ができず未検査"
      fi
      add_warning "$name の自動更新に失敗しました（brew upgrade を手で実行してください）"
    fi
    printf '%s\t%s\t%s\n' "$name" "$installed" "$latest" >> "$remaining"
  done < "$rows"
  if [ ! -s "$remaining" ]; then
    security_detail "Homebrew のセキュリティ部品は更新待ちなし"
    return
  fi
  description=""
  : > "$TMP_DIR/brew-security-warned.list"
  : > "$TMP_DIR/brew-security-warned-items.tsv"
  while IFS=$'\t' read -r name installed latest; do
    item="$name $installed → $latest"
    IFS=',' read -r -a installed_versions <<EOF
$installed
EOF
    for installed_version in "${installed_versions[@]}"; do
      if brew_below_minimum "$name" "$installed_version"; then
        item="${item}（修正版 ${BREW_MIN_MINIMUM} 未満: ${BREW_MIN_REASON}）"
        break
      fi
    done
    printf '%s\n' "$name" >> "$TMP_DIR/brew-security-warned.list"
    printf '%s\t%s\n' "$name" "$item" >> "$TMP_DIR/brew-security-warned-items.tsv"
    if [ -z "$description" ]; then description="$item"; else description="${description}、$item"; fi
  done < "$remaining"
  printf '%s\n' "${#WARNINGS[@]}" > "$TMP_DIR/brew-security-warning-index"
  add_warning "Mac のセキュリティ部品に更新が出ています: ${description}（brew upgrade で更新できます）"
  brew_prefix="$(run_timeout 30 brew --prefix 2>/dev/null || true)"
  [ -z "$brew_prefix" ] || security_detail "Homebrew: $brew_prefix"
}

check_minimum_versions() {
  local component="$1" row_component candidates seen bin real version series major minimum reason
  local eol_threshold eol_reason listening lsof_output suffix kind matched httpd_pid
  local keg kegs policy_level brew_prefix nvm_dir remedy formula
  if [ ! -f "$SECURITY_MINIMUMS" ]; then
    case "$component" in
      php) NOTES[${#NOTES[@]}]="PHP の最低版は同梱リスト不足のため未検査" ;;
      node) NOTES[${#NOTES[@]}]="node の最低版は同梱リスト不足のため未検査" ;;
    esac
    return
  fi
  candidates="$TMP_DIR/${component}-candidates.list"
  seen="$TMP_DIR/${component}-seen.list"
  kegs="$TMP_DIR/${component}-kegs.list"
  : > "$candidates"
  : > "$seen"
  : > "$kegs"

  listening="no"
  case "$component" in
    php)
      type -aP php 2>/dev/null >> "$candidates" || true
      type -aP php-fpm 2>/dev/null >> "$candidates" || true
      [ -x /opt/homebrew/sbin/php-fpm ] && printf '%s\n' /opt/homebrew/sbin/php-fpm >> "$candidates"
      [ -x /usr/local/sbin/php-fpm ] && printf '%s\n' /usr/local/sbin/php-fpm >> "$candidates"
      if command -v lsof >/dev/null 2>&1; then
        if lsof_output="$(run_timeout 20 lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null)"; then
          if printf '%s\n' "$lsof_output" | awk 'NR > 1 && $1 ~ /^php/ { found=1 } END { exit !found }'; then
            listening="yes"
          fi
          # httpd は PHP を読み込んでいる（mod_php）ときだけ数える。PHP を使わない Apache で FAIL にしない
          for httpd_pid in $(printf '%s\n' "$lsof_output" | awk 'NR > 1 && $1 ~ /^httpd/ { print $2 }' | LC_ALL=C sort -u); do
            if run_timeout 20 lsof -nP -p "$httpd_pid" 2>/dev/null | LC_ALL=C grep -qiE 'libphp|mod_php'; then
              listening="yes"
            fi
          done
        else
          listening="unknown"
        fi
      else
        listening="unknown"
      fi
      ;;
    node)
      if [ -n "${RH_NODE_CANDIDATES+x}" ]; then
        printf '%s\n' "$RH_NODE_CANDIDATES" >> "$candidates"
      else
        type -aP node 2>/dev/null >> "$candidates" || true
        if command -v brew >/dev/null 2>&1; then
          brew_prefix="$(brew --prefix 2>/dev/null || true)"
          if [ -n "$brew_prefix" ]; then
            [ -x "$brew_prefix/opt/node/bin/node" ] && printf '%s\n' "$brew_prefix/opt/node/bin/node" >> "$candidates"
            for bin in "$brew_prefix"/opt/node@*/bin/node; do
              [ -x "$bin" ] && printf '%s\n' "$bin" >> "$candidates"
            done
          fi
        fi
        nvm_dir="${NVM_DIR:-$HOME/.nvm}"
        for bin in "$nvm_dir"/versions/node/*/bin/node; do
          [ -x "$bin" ] && printf '%s\n' "$bin" >> "$candidates"
        done
      fi
      ;;
    *) return ;;
  esac

  while IFS= read -r bin; do
    [ -x "$bin" ] || continue
    real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$bin" 2>/dev/null || printf '%s' "$bin")"
    LC_ALL=C grep -Fqx "$real" "$seen" 2>/dev/null && continue
    printf '%s\n' "$real" >> "$seen"
    # Homebrew の同じ版（keg）の php と php-fpm は1件にまとめる
    keg="$(printf '%s\n' "$real" | sed -n 's#^\(.*/Cellar/[^/][^/]*/[^/][^/]*\)/.*#\1#p')"
    if [ -n "$keg" ]; then
      LC_ALL=C grep -Fqx "$keg" "$kegs" 2>/dev/null && continue
      printf '%s\n' "$keg" >> "$kegs"
    fi
    if [ "$component" = "php" ]; then
      case "$(basename -- "$bin")" in
        php-fpm*)
          kind="php-fpm"
          version="$(run_timeout 20 "$bin" -v 2>/dev/null | sed -n '1{s/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p;q;}')"
          ;;
        *)
          kind="php"
          version="$(run_timeout 20 "$bin" -r 'echo PHP_VERSION;' 2>/dev/null || true)"
          version="$(printf '%s' "$version" | LC_ALL=C grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
          ;;
      esac
    else
      kind="node"
      version="$(run_timeout 20 "$bin" -p 'process.versions.node' 2>/dev/null || true)"
      version="$(printf '%s' "$version" | LC_ALL=C grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    fi
    if [ -z "$version" ]; then
      NOTES[${#NOTES[@]}]="${kind}（${bin}）— 版を判定できず未検査"
      continue
    fi
    series="${version%.*}"
    major="${version%%.*}"
    minimum=""; reason=""; eol_threshold=""; eol_reason=""
    policy_level=0
    while IFS=$'\t' read -r row_component row_series row_minimum row_reason; do
      case "$row_component" in ''|\#*) continue;; esac
      [ "$row_component" = "$component" ] || continue
      if [ "$row_series" = "$series" ]; then
        minimum="$row_minimum"; reason="$row_reason"
        policy_level=2
      elif [ "$row_series" = "$major" ] && [ "$policy_level" -lt 2 ]; then
        minimum="$row_minimum"; reason="$row_reason"
        policy_level=1
      elif [ "$row_series" = "EOL" ]; then
        eol_threshold="$row_minimum"; eol_reason="$row_reason"
      fi
    done < "$SECURITY_MINIMUMS"
    matched="no"
    if [ "$minimum" = "EOL" ]; then
      matched="eol"
    elif [ -n "$minimum" ] && version_less_than "$version" "$minimum"; then
      matched="minimum"
    elif [ -n "$eol_threshold" ] && version_less_than "$version" "$eol_threshold"; then
      matched="eol"
      reason="$eol_reason"
    fi
    if [ "$matched" = "no" ] && [ "$component" = "php" ]; then
      security_detail "$kind ${version}（${bin}）— 最低版を満たしています"
      continue
    fi
    if [ "$component" = "php" ]; then
      suffix=""
      [ "$listening" != "unknown" ] || suffix="（待ち受けの有無は未検査）"
      if [ "$matched" = "eol" ]; then
        if [ "$listening" = "yes" ]; then
          add_failure "PHP ${version}（${bin}）がサーバーとして動いています。サポート終了の系列です（${reason}）。サポート中の版へ更新してください"
        else
          add_warning "PHP ${version}（${bin}）はサポート終了の系列です（${reason}）${suffix}。使っていなければ brew uninstall php、使うならサポート中の版へ更新してください"
        fi
      elif [ "$listening" = "yes" ]; then
        add_failure "PHP ${version}（${bin}）がサーバーとして動いています。${reason}の修正版 $minimum 以上へ更新してください"
      else
        add_warning "PHP ${version}（${bin}）は修正版 $minimum より古い版です（${reason}）${suffix}。使っていなければ brew uninstall php、使うなら修正版が出しだい brew upgrade php"
      fi
    elif [ "$matched" = "no" ]; then
      security_detail "node ${version}（${bin}）— 最低版を満たしています"
    elif [ "$matched" = "eol" ]; then
      add_warning "Node ${version}（${bin}）はサポート終了の系列です（${reason}）。サポート中の系列（22・24・26 など）へ移ってください"
    else
      remedy="入れた方法で最新版へ更新してください"
      if [ -n "$keg" ]; then
        formula="${keg%/*}"
        formula="${formula##*/}"
        remedy="brew upgrade ${formula}（Homebrew に修正版が出しだい）"
      else
        nvm_dir="${NVM_DIR:-$HOME/.nvm}"
        case "$real" in
          "$nvm_dir"/versions/node/*) remedy="nvm install ${major} で最新の ${major}.x へ" ;;
        esac
      fi
      add_warning "Node ${version}（${bin}）は修正版 $minimum より古い版です（${reason}）。${remedy}"
    fi
  done < "$candidates"
}

check_java_versions() {
  local candidates seen kegs home real release raw_version version display_version series
  local row_component row_series row_minimum row_reason minimum reason wildcard_minimum wildcard_reason
  local keg brew_prefix sdkman_dir remedy formula matched
  if [ ! -f "$SECURITY_MINIMUMS" ]; then
    NOTES[${#NOTES[@]}]="Java の最低版は同梱リスト不足のため未検査"
    return
  fi
  candidates="$TMP_DIR/java-candidates.list"
  seen="$TMP_DIR/java-seen.list"
  kegs="$TMP_DIR/java-kegs.list"
  : > "$candidates"
  : > "$seen"
  : > "$kegs"

  if [ -n "${RH_JAVA_CANDIDATES+x}" ]; then
    printf '%s\n' "$RH_JAVA_CANDIDATES" >> "$candidates"
  else
    for home in /Library/Java/JavaVirtualMachines/*/Contents/Home "$HOME"/Library/Java/JavaVirtualMachines/*/Contents/Home; do
      [ -d "$home" ] && printf '%s\n' "$home" >> "$candidates"
    done
    if command -v brew >/dev/null 2>&1; then
      brew_prefix="$(brew --prefix 2>/dev/null || true)"
      if [ -n "$brew_prefix" ]; then
        home="$brew_prefix/opt/openjdk/libexec/openjdk.jdk/Contents/Home"
        [ -d "$home" ] && printf '%s\n' "$home" >> "$candidates"
        for home in "$brew_prefix"/opt/openjdk@*/libexec/openjdk.jdk/Contents/Home; do
          [ -d "$home" ] && printf '%s\n' "$home" >> "$candidates"
        done
      fi
    fi
    sdkman_dir="$HOME/.sdkman/candidates/java"
    for home in "$sdkman_dir"/*; do
      [ -d "$home" ] || continue
      [ "$(basename -- "$home")" = "current" ] && continue
      printf '%s\n' "$home" >> "$candidates"
    done
  fi

  while IFS= read -r home; do
    [ -n "$home" ] && [ -d "$home" ] || continue
    real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$home" 2>/dev/null || printf '%s' "$home")"
    LC_ALL=C grep -Fqx "$real" "$seen" 2>/dev/null && continue
    printf '%s\n' "$real" >> "$seen"
    keg="$(printf '%s\n' "$real" | sed -n 's#^\(.*/Cellar/[^/][^/]*/[^/][^/]*\)/.*#\1#p')"
    if [ -n "$keg" ]; then
      LC_ALL=C grep -Fqx "$keg" "$kegs" 2>/dev/null && continue
      printf '%s\n' "$keg" >> "$kegs"
    fi

    release="$home/release"
    if [ ! -r "$release" ]; then
      NOTES[${#NOTES[@]}]="java（${home}）— 版を判定できず未検査"
      continue
    fi
    raw_version="$(sed -n 's/^JAVA_VERSION="\([^"]*\)".*/\1/p' "$release" 2>/dev/null | head -1)"
    case "$raw_version" in
      1.8.0_*) version="$(printf '%s' "$raw_version" | sed -n 's/^1\.8\.0_\([0-9][0-9]*\).*/8.0.\1/p')" ;;
      *) version="$(printf '%s' "$raw_version" | LC_ALL=C grep -Eo '^[0-9]+(\.[0-9]+){0,3}' | head -1)" ;;
    esac
    if [ -z "$version" ]; then
      NOTES[${#NOTES[@]}]="java（${home}）— 版を判定できず未検査"
      continue
    fi
    series="${version%%.*}"
    display_version="$version"
    [ "$series" != "8" ] || display_version="8u${version##*.}"

    minimum=""; reason=""; wildcard_minimum=""; wildcard_reason=""
    while IFS=$'\t' read -r row_component row_series row_minimum row_reason; do
      case "$row_component" in ''|\#*) continue;; esac
      [ "$row_component" = "java" ] || continue
      if [ "$row_series" = "$series" ]; then
        minimum="$row_minimum"; reason="$row_reason"
      elif [ "$row_series" = "*" ]; then
        wildcard_minimum="$row_minimum"; wildcard_reason="$row_reason"
      fi
    done < "$SECURITY_MINIMUMS"
    if [ -z "$minimum" ]; then
      minimum="$wildcard_minimum"; reason="$wildcard_reason"
    fi

    matched="no"
    if [ "$minimum" = "EOL" ]; then
      matched="eol"
    elif [ -n "$minimum" ] && version_less_than "$version" "$minimum"; then
      matched="minimum"
    fi
    if [ "$matched" = "no" ]; then
      security_detail "Java ${display_version}（${home}）— 最低版を満たしています"
      continue
    fi
    if [ "$matched" = "eol" ]; then
      add_warning "Java ${display_version}（${home}）はサポート終了の系列です（${reason}）。サポート中の系列（LTS の 17・21・25 など）へ移ってください。使っていなければ削除してください"
      continue
    fi

    remedy="入れた方法（配布元のインストーラーや brew upgrade --cask）で最新版へ"
    if [ -n "$keg" ]; then
      formula="${keg%/*}"
      formula="${formula##*/}"
      remedy="brew upgrade ${formula}（Homebrew に修正版が出しだい）"
    else
      sdkman_dir="$HOME/.sdkman/candidates/java"
      case "$home:$real" in
        "$sdkman_dir"/*:*|*:"$sdkman_dir"/*) remedy="sdk install java で同じ系列の最新版へ" ;;
        /Library/Java/JavaVirtualMachines/*:*|"$HOME"/Library/Java/JavaVirtualMachines/*:*)
          remedy="入れた方法（配布元のインストーラーや brew upgrade --cask）で最新版へ"
          ;;
      esac
    fi
    add_warning "Java ${display_version}（${home}）は修正版 ${minimum} より古い版です（${reason}）。${remedy}"
  done < "$candidates"
}

python_version_from_site() {
  local site="$1" version
  version="$(printf '%s\n' "$site" | sed -n 's#.*[/]lib/python\([0-9][0-9]*\.[0-9][0-9]*\)t*/site-packages.*#\1#p' | head -1)"
  if [ -z "$version" ]; then
    version="$(printf '%s\n' "$site" | sed -n 's#.*[/]Versions/\([0-9][0-9]*\.[0-9][0-9]*\).*#\1#p' | head -1)"
  fi
  if [ -z "$version" ]; then
    version="$(printf '%s\n' "$site" | sed -n 's#.*[/]Library/Python/\([0-9][0-9]*\.[0-9][0-9]*\)/.*#\1#p' | head -1)"
  fi
  printf '%s\n' "$version"
}

python_package_version() {
  local init_file="$1" raw
  [ -r "$init_file" ] || return
  raw="$(sed -n "s/^[[:space:]]*__version__[[:space:]]*=[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p" "$init_file" 2>/dev/null | head -1)"
  leading_version "$raw"
}

python_pin_url() {
  local wanted="$1" component _version url
  [ -f "$PYTHON_PINS" ] || return
  while IFS=$'\t' read -r component _version url; do
    case "$component" in ''|\#*) continue;; esac
    if [ "$component" = "$wanted" ]; then
      printf '%s\n' "$url"
      return
    fi
  done < "$PYTHON_PINS"
}

# site-packages の <名前>-*.dist-info/METADATA の Version: を読みます（同じ場所に複数あれば一番新しい版）。
# 名前は大文字小文字違いを引数で並べて渡します（例: brotli Brotli）。取れなければ何も出しません。
python_dist_info_version() {
  local site="$1" stem metadata metadata_version found=""
  shift
  for stem in "$@"; do
    for metadata in "$site/$stem"-*.dist-info/METADATA; do
      [ -r "$metadata" ] || continue
      metadata_version="$(sed -n 's/^Version:[[:space:]]*//p' "$metadata" 2>/dev/null | head -1)"
      metadata_version="$(leading_version "$metadata_version")"
      [ -n "$metadata_version" ] || continue
      if [ -z "$found" ] || version_less_than "$found" "$metadata_version"; then
        found="$metadata_version"
      fi
    done
  done
  [ -z "$found" ] || printf '%s\n' "$found"
}

# .../Cellar/<formula>/<版>/... のパスから formula 名を出します。
brew_formula_from_site() {
  printf '%s\n' "$1" | sed -n 's#.*/Cellar/\([^/][^/]*\)/[^/][^/]*/.*#\1#p' | head -1
}

# Cellar/<formula>/<版>/ の site-packages が、リンクされている版（<prefix>/opt/<formula> の実体）かを返します。
# 古い版のフォルダが残っているだけの場合は 1 を返します。opt が無いときは判断できないので 0（見る側）に倒します。
brew_formula_site_is_linked() {
  local site="$1" keg prefix formula opt
  keg="$(printf '%s\n' "$site" | sed -n 's#^\(.*/Cellar/[^/][^/]*/[^/][^/]*\)/.*#\1#p' | head -1)"
  [ -n "$keg" ] || return 0
  prefix="${keg%/Cellar/*}"
  formula="$(brew_formula_from_site "$site")"
  [ -n "$formula" ] || return 0
  opt="$prefix/opt/$formula"
  [ -e "$opt" ] || return 0
  [ "$(real_path_of "$opt")" = "$(real_path_of "$keg")" ]
}

# Homebrew の formula が brew outdated に載っている（brew upgrade で直る）かを返します。載っていれば 0。
# 一覧を取れなかったときは載っていない扱いにして、「Homebrew はまだ直していない」と案内する側に倒します。
# 一覧は一時ファイルに書いてから読みます（パイプの右で配列を変えない）。
brew_formula_is_outdated() {
  local formula="$1" brew_cmd="$2" json names
  json="$TMP_DIR/python-brew-outdated.json"
  names="$TMP_DIR/python-brew-outdated.names"
  if [ ! -f "$names" ]; then
    : > "$names"
    if [ -n "$brew_cmd" ] && [ -x "$brew_cmd" ] && run_timeout 120 "$brew_cmd" outdated --json=v2 > "$json" 2>/dev/null; then
      if ! python3 - "$json" > "$names" 2>/dev/null <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
for formula in data.get("formulae", []):
    if isinstance(formula, dict) and formula.get("name"):
        print(formula["name"])
PY
      then
        : > "$names"
      fi
    fi
  fi
  LC_ALL=C grep -Fqx "$formula" "$names" 2>/dev/null
}

add_python_site_candidate() {
  local candidates="$1" kind="$2" site="$3" python="$4" label="${5:-$3}"
  [ -d "$site" ] || return
  printf '%s\t%s\t%s\t%s\n' "$kind" "$site" "$python" "$label" >> "$candidates"
}

check_python_packages() {
  local candidates seen formula_kegs uv_candidates uv_seen brew_cmd brew_prefix site version_root
  local pyenv_root pipx_root conda_root repo cfg venv relative repo_name kind python label real py_version
  local pip_version certifi_version uv_version metadata metadata_version pip_min pip_reason cert_min cert_reason
  local uv_min uv_reason pip_old cert_old uv_old pip_pin cert_pin python_name fallback user_flag
  local pip_remedy cert_remedy cert_real cert_keg uv_raw uv_real uv_output uv_root
  local brotli_version brotlicffi_version brotli_min brotli_reason brotlicffi_min brotlicffi_reason
  local brotli_old brotlicffi_old brotli_remedy brotlicffi_remedy uv_remedy formula_name site_tail

  if [ ! -f "$SECURITY_MINIMUMS" ]; then
    NOTES[${#NOTES[@]}]="Python の pip・certifi の最低版は同梱リスト不足のため未検査"
    return
  fi

  candidates="$TMP_DIR/python-sites.tsv"
  seen="$TMP_DIR/python-sites-seen.list"
  formula_kegs="$TMP_DIR/python-certifi-kegs.list"
  : > "$candidates"
  : > "$seen"
  : > "$formula_kegs"

  if [ -n "${RH_BREW+x}" ]; then brew_cmd="$RH_BREW"; else brew_cmd="$(command -v brew 2>/dev/null || true)"; fi
  if [ -n "${RH_PYTHON_SITE_DIRS+x}" ]; then
    printf '%s\n' "$RH_PYTHON_SITE_DIRS" >> "$candidates"
  else
    if [ -n "$brew_cmd" ] && [ -x "$brew_cmd" ]; then
      brew_prefix="$("$brew_cmd" --prefix 2>/dev/null || true)"
      if [ -n "$brew_prefix" ]; then
        for site in "$brew_prefix"/lib/python3.*/site-packages; do
          [ -d "$site" ] || continue
          # lib/python3.15t のような free-threaded 版は、呼び出し名も python3.15t
          python_name="${site%/site-packages}"
          python_name="${python_name##*/}"
          add_python_site_candidate "$candidates" brew "$site" "$brew_prefix/bin/${python_name}" "$site"
        done
        # formula 専用の環境（yt-dlp など、自分の Python と部品を抱える道具）。リンクされている版かどうかは読む側で見る
        for site in "$brew_prefix"/Cellar/*/*/libexec/lib/python3.*/site-packages; do
          [ -d "$site" ] || continue
          version_root="${site%%/lib/python*}"
          add_python_site_candidate "$candidates" brew-formula "$site" "$version_root/bin/python" "$site"
        done
      fi
    fi
    for site in /Library/Frameworks/Python.framework/Versions/*/lib/python3.*/site-packages; do
      [ -d "$site" ] || continue
      version_root="${site%%/lib/python*}"
      py_version="$(python_version_from_site "$site")"
      add_python_site_candidate "$candidates" python.org "$site" "$version_root/bin/python${py_version}" "$site"
    done
    for site in /Library/Frameworks/PythonT.framework/Versions/*/lib/python3.*/site-packages; do
      [ -d "$site" ] || continue
      version_root="${site%%/lib/python*}"
      py_version="$(python_version_from_site "$site")"
      add_python_site_candidate "$candidates" python.org "$site" "$version_root/bin/python${py_version}t" "$site"
    done
    for site in "$HOME"/Library/Python/*/lib/python/site-packages; do
      [ -d "$site" ] || continue
      py_version="$(python_version_from_site "$site")"
      if [ "$py_version" = "3.9" ]; then
        python=/usr/bin/python3
      else
        python="$(command -v "python${py_version}" 2>/dev/null || printf 'python%s' "$py_version")"
      fi
      add_python_site_candidate "$candidates" user "$site" "$python" "$site"
    done
    pyenv_root="${PYENV_ROOT:-$HOME/.pyenv}"
    for site in "$pyenv_root"/versions/*/lib/python3.*/site-packages; do
      [ -d "$site" ] || continue
      version_root="${site%%/lib/python*}"
      add_python_site_candidate "$candidates" pyenv "$site" "$version_root/bin/python" "$site"
    done
    for site in "$HOME"/.local/share/uv/python/*/lib/python3.*/site-packages; do
      [ -d "$site" ] || continue
      version_root="${site%%/lib/python*}"
      add_python_site_candidate "$candidates" uv-python "$site" "$version_root/bin/python3" "$site"
    done
    for pipx_root in "$HOME/.local/pipx" "$HOME/.local/share/pipx"; do
      for site in "$pipx_root"/venvs/*/lib/python3.*/site-packages; do
        [ -d "$site" ] || continue
        version_root="${site%%/lib/python*}"
        add_python_site_candidate "$candidates" pipx "$site" "$version_root/bin/python" "$site"
      done
    done
    for conda_root in "$HOME/miniconda3" "$HOME/anaconda3" "$HOME/miniforge3"; do
      for site in "$conda_root"/lib/python3.*/site-packages "$conda_root"/envs/*/lib/python3.*/site-packages; do
        [ -d "$site" ] || continue
        version_root="${site%%/lib/python*}"
        add_python_site_candidate "$candidates" conda "$site" "$version_root/bin/python" "$site"
      done
    done
    for site in /Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/*/lib/python3.*/site-packages \
      /Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/*/lib/python3.*/site-packages; do
      [ -d "$site" ] || continue
      add_python_site_candidate "$candidates" apple "$site" /usr/bin/python3 "$site"
    done
  fi

  while IFS= read -r -d '' repo; do
    [ -e "$repo/.git" ] || continue
    while IFS= read -r -d '' cfg; do
      venv="${cfg%/pyvenv.cfg}"
      relative="${venv#"$repo"/}"
      repo_name="$(basename -- "$repo")"
      for site in "$venv"/lib/python3.*/site-packages; do
        [ -d "$site" ] || continue
        add_python_site_candidate "$candidates" venv "$site" "$venv/bin/python" "$(quote_name "$repo_name")/$(quote_name "$relative")"
      done
    done < <(find "$repo" -maxdepth 3 \( -name .git -o -name node_modules \) -prune -o -type f -name pyvenv.cfg -print0 2>/dev/null)
  done < "$REPO_LIST"

  while IFS=$'\t' read -r kind site python label; do
    [ -n "$kind" ] && [ -d "$site" ] || continue
    case "$kind" in brew|brew-formula|python.org|user|pyenv|uv-python|pipx|conda|venv|apple) ;; *) continue;; esac
    # formula の古い版のフォルダが残っているだけのものは、動いていないので見ない
    if [ "$kind" = "brew-formula" ] && ! brew_formula_site_is_linked "$site"; then continue; fi
    real="$(real_path_of "$site")"
    LC_ALL=C grep -Fqx "$real" "$seen" 2>/dev/null && continue
    printf '%s\n' "$real" >> "$seen"
    [ -n "$label" ] || label="$site"
    formula_name=""
    if [ "$kind" = "brew-formula" ]; then
      formula_name="$(brew_formula_from_site "$site")"
      [ -z "$formula_name" ] || label="Homebrew の ${formula_name}"
    fi
    py_version="$(python_version_from_site "$site")"
    pip_version="$(python_package_version "$site/pip/__init__.py" || true)"
    certifi_version="$(python_package_version "$site/certifi/__init__.py" || true)"
    uv_version=""
    for metadata in "$site"/uv-*.dist-info/METADATA; do
      [ -r "$metadata" ] || continue
      metadata_version="$(sed -n 's/^Version:[[:space:]]*//p' "$metadata" 2>/dev/null | head -1)"
      metadata_version="$(leading_version "$metadata_version")"
      [ -n "$metadata_version" ] || continue
      if [ -z "$uv_version" ] || version_less_than "$uv_version" "$metadata_version"; then
        uv_version="$metadata_version"
      fi
    done

    brotli_version="$(python_dist_info_version "$site" brotli Brotli)"
    brotlicffi_version="$(python_dist_info_version "$site" brotlicffi)"

    pip_min=""; pip_reason=""; cert_min=""; cert_reason=""; uv_min=""; uv_reason=""
    brotli_min=""; brotli_reason=""; brotlicffi_min=""; brotlicffi_reason=""
    if [ -n "$pip_version" ]; then
      lookup_minimum_row pip "$pip_version"; pip_min="$MIN_ROW_MINIMUM"; pip_reason="$MIN_ROW_REASON"
    fi
    if [ -n "$certifi_version" ]; then
      lookup_minimum_row certifi "$certifi_version"; cert_min="$MIN_ROW_MINIMUM"; cert_reason="$MIN_ROW_REASON"
    fi
    if [ -n "$uv_version" ]; then
      lookup_minimum_row uv "$uv_version"; uv_min="$MIN_ROW_MINIMUM"; uv_reason="$MIN_ROW_REASON"
    fi
    if [ -n "$brotli_version" ]; then
      lookup_minimum_row brotli-py "$brotli_version"; brotli_min="$MIN_ROW_MINIMUM"; brotli_reason="$MIN_ROW_REASON"
    fi
    if [ -n "$brotlicffi_version" ]; then
      lookup_minimum_row brotlicffi "$brotlicffi_version"; brotlicffi_min="$MIN_ROW_MINIMUM"; brotlicffi_reason="$MIN_ROW_REASON"
    fi
    pip_old=0; cert_old=0; uv_old=0; brotli_old=0; brotlicffi_old=0
    [ -z "$pip_min" ] || ! version_less_than "$pip_version" "$pip_min" || pip_old=1
    [ -z "$cert_min" ] || ! version_less_than "$certifi_version" "$cert_min" || cert_old=1
    [ -z "$uv_min" ] || ! version_less_than "$uv_version" "$uv_min" || uv_old=1
    [ -z "$brotli_min" ] || [ "$brotli_min" = "EOL" ] || ! version_less_than "$brotli_version" "$brotli_min" || brotli_old=1
    [ -z "$brotlicffi_min" ] || [ "$brotlicffi_min" = "EOL" ] || ! version_less_than "$brotlicffi_version" "$brotlicffi_min" || brotlicffi_old=1

    if [ "$kind" = "apple" ]; then
      if [ "$pip_old" -eq 1 ]; then
        NOTES[${#NOTES[@]}]="Apple の python3（${label}）の pip ${pip_version} は古い版です（Apple の更新待ち）。/usr/bin/python3 -m pip でネットからパッケージを入れないでください"
      elif [ "$cert_old" -eq 1 ]; then
        NOTES[${#NOTES[@]}]="Apple の python3（${label}）の certifi ${certifi_version} は古い版です（Apple の更新待ち）。/usr/bin/python3 -m pip でネットからパッケージを入れないでください"
      fi
      if [ "$brotli_old" -eq 1 ]; then
        NOTES[${#NOTES[@]}]="Apple の python3（${label}）の brotli ${brotli_version} は古い版です（Apple の更新待ち）。この python3 で知らないサイトを開かないでください"
      fi
      if [ "$brotlicffi_old" -eq 1 ]; then
        NOTES[${#NOTES[@]}]="Apple の python3（${label}）の brotlicffi ${brotlicffi_version} は古い版です（Apple の更新待ち）。この python3 で知らないサイトを開かないでください"
      fi
      continue
    fi

    if [ -n "$pip_version" ] && [ "$pip_old" -eq 0 ]; then
      security_detail "Python（${label}）の pip ${pip_version} — 最低版 ${pip_min} 以上"
    fi
    if [ -n "$certifi_version" ] && [ "$cert_old" -eq 0 ]; then
      security_detail "Python（${label}）の certifi ${certifi_version} — 最低版 ${cert_min} 以上"
    fi
    if [ -n "$uv_version" ] && [ "$uv_old" -eq 0 ]; then
      security_detail "Python（${label}）の uv ${uv_version} — 最低版 ${uv_min} 以上"
    fi
    if [ -n "$brotli_version" ] && [ "$brotli_old" -eq 0 ]; then
      security_detail "Python（${label}）の brotli ${brotli_version} — 最低版 ${brotli_min:-（未掲載）} 以上"
    fi
    if [ -n "$brotlicffi_version" ] && [ "$brotlicffi_old" -eq 0 ]; then
      security_detail "Python（${label}）の brotlicffi ${brotlicffi_version} — 最低版 ${brotlicffi_min:-（未掲載）} 以上"
    fi

    if [ "$pip_old" -eq 1 ] && [ -n "$py_version" ] && version_less_than "$py_version" 3.10; then
      NOTES[${#NOTES[@]}]="Python ${py_version}（${label}）の pip ${pip_version} は修正版 ${pip_min} を入れられません（Python 3.10 以上が必要）。この pip でネットからパッケージを入れないでください"
      pip_old=0
    fi

    python_name="$python"
    [ -x "$python" ] || python_name="この環境の python"
    pip_pin="$(python_pin_url pip || true)"
    cert_pin="$(python_pin_url certifi || true)"
    fallback="\"${python_name}\" -m pip install --upgrade pip certifi（Python 公式の告知にある sha256 付きの入れ方が安全です）"
    user_flag=""
    [ "$kind" != "user" ] || user_flag="--user "

    cert_keg=""
    # Homebrew は certifi のフォルダーごとではなく中のファイルごとに symlink を張ることがあるので、__init__.py の実体で見る
    if [ "$cert_old" -eq 1 ] && [ -e "$site/certifi/__init__.py" ]; then
      cert_real="$(real_path_of "$site/certifi/__init__.py")"
      cert_keg="$(printf '%s\n' "$cert_real" | sed -n 's#^\(.*/Cellar/certifi/[^/][^/]*\)/.*#\1#p')"
      if [ -n "$cert_keg" ] && LC_ALL=C grep -Fqx "$cert_keg" "$formula_kegs" 2>/dev/null; then
        cert_old=0
      fi
    fi

    # formula 専用の環境は Homebrew の持ち物なので、直し方は brew upgrade <formula>。
    # Homebrew がまだ直していない（brew outdated に載っていない）ときは、直るまでの注意を添える
    uv_remedy="\"${python_name}\" -m pip install --upgrade uv"
    site_tail=""
    if [ -n "$formula_name" ]; then
      uv_remedy="brew upgrade ${formula_name}"
      if [ "$pip_old" -eq 1 ] || [ "$cert_old" -eq 1 ] || [ "$uv_old" -eq 1 ] || [ "$brotli_old" -eq 1 ] || [ "$brotlicffi_old" -eq 1 ]; then
        brew_formula_is_outdated "$formula_name" "$brew_cmd" \
          || site_tail="（Homebrew が直すまでは、その道具で知らないサイトを開かない）"
      fi
    fi

    pip_remedy=""
    if [ "$pip_old" -eq 1 ]; then
      if [ -n "$formula_name" ]; then
        pip_remedy="brew upgrade ${formula_name}"
      elif [ -z "$pip_pin" ]; then
        pip_remedy="$fallback"
      else
        pip_remedy="\"${python_name}\" -m pip install \"pip @ ${pip_pin}\""
        if [ "$kind" = "brew" ] && [ -n "$py_version" ]; then
          pip_remedy="brew upgrade python@${py_version}。まだ古ければ ${pip_remedy}"
        fi
      fi
    fi
    cert_remedy=""
    if [ "$cert_old" -eq 1 ]; then
      if [ -n "$cert_keg" ]; then
        cert_remedy="brew upgrade certifi"
      elif [ -n "$formula_name" ]; then
        cert_remedy="brew upgrade ${formula_name}"
      elif [ -z "$cert_pin" ]; then
        cert_remedy="$fallback"
      else
        cert_remedy="\"${python_name}\" -m pip install ${user_flag}\"certifi @ ${cert_pin}\""
      fi
    fi

    if [ "$pip_old" -eq 1 ] && [ "$cert_old" -eq 1 ]; then
      if [ "$pip_remedy" = "$fallback" ] || [ "$cert_remedy" = "$fallback" ]; then
        add_warning "Python（${label}）の pip ${pip_version} は修正版 ${pip_min} より古い版です（${pip_reason}）、certifi ${certifi_version} は修正版 ${cert_min} より古い版です（${cert_reason}）。直し方: ${fallback}"
      elif [ "$pip_remedy" = "$cert_remedy" ]; then
        add_warning "Python（${label}）の pip ${pip_version} は修正版 ${pip_min} より古い版です（${pip_reason}）、certifi ${certifi_version} は修正版 ${cert_min} より古い版です（${cert_reason}）。直し方: ${pip_remedy}${site_tail}"
      else
        add_warning "Python（${label}）の pip ${pip_version} は修正版 ${pip_min} より古い版です（${pip_reason}）、certifi ${certifi_version} は修正版 ${cert_min} より古い版です（${cert_reason}）。直し方: ${pip_remedy} → ${cert_remedy}${site_tail}"
      fi
    elif [ "$pip_old" -eq 1 ]; then
      add_warning "Python（${label}）の pip ${pip_version} は修正版 ${pip_min} より古い版です（${pip_reason}）。直し方: ${pip_remedy}${site_tail}"
    elif [ "$cert_old" -eq 1 ]; then
      add_warning "Python（${label}）の certifi ${certifi_version} は修正版 ${cert_min} より古い版です（${cert_reason}）。直し方: ${cert_remedy}${site_tail}"
    fi
    if [ "$cert_old" -eq 1 ] && [ -n "$cert_keg" ]; then
      printf '%s\n' "$cert_keg" >> "$formula_kegs"
    fi
    if [ "$uv_old" -eq 1 ]; then
      if [ -n "$formula_name" ]; then
        add_warning "Python（${label}）の uv ${uv_version} は修正版 ${uv_min} より古い版です（${uv_reason}）。直し方: ${uv_remedy}${site_tail}"
      else
        add_warning "Python（${label}）の uv ${uv_version} は修正版 ${uv_min} より古い版です（${uv_reason}）。pip を先に直してから、直し方: ${uv_remedy}"
      fi
    fi
    if [ "$brotli_old" -eq 1 ]; then
      if [ -n "$formula_name" ]; then
        brotli_remedy="brew upgrade ${formula_name}"
      else
        brotli_remedy="\"${python_name}\" -m pip install ${user_flag}--upgrade brotli"
      fi
      add_warning "Python（${label}）の brotli ${brotli_version} は修正版 ${brotli_min} より古い版です（${brotli_reason}）。直し方: ${brotli_remedy}${site_tail}"
    fi
    if [ "$brotlicffi_old" -eq 1 ]; then
      if [ -n "$formula_name" ]; then
        brotlicffi_remedy="brew upgrade ${formula_name}"
      else
        brotlicffi_remedy="\"${python_name}\" -m pip install ${user_flag}--upgrade brotlicffi"
      fi
      add_warning "Python（${label}）の brotlicffi ${brotlicffi_version} は修正版 ${brotlicffi_min} より古い版です（${brotlicffi_reason}）。直し方: ${brotlicffi_remedy}${site_tail}"
    fi
  done < "$candidates"

  uv_candidates="$TMP_DIR/uv-candidates.list"
  uv_seen="$TMP_DIR/uv-seen.list"
  : > "$uv_candidates"
  : > "$uv_seen"
  if [ -n "${RH_UV_CANDIDATES+x}" ]; then
    printf '%s\n' "$RH_UV_CANDIDATES" >> "$uv_candidates"
  else
    type -aP uv 2>/dev/null >> "$uv_candidates" || true
    [ -x "$HOME/.local/bin/uv" ] && printf '%s\n' "$HOME/.local/bin/uv" >> "$uv_candidates"
    [ -x "$HOME/.cargo/bin/uv" ] && printf '%s\n' "$HOME/.cargo/bin/uv" >> "$uv_candidates"
  fi
  while IFS= read -r uv_raw; do
    [ -n "$uv_raw" ] && [ -x "$uv_raw" ] || continue
    uv_real="$(real_path_of "$uv_raw")"
    LC_ALL=C grep -Fqx "$uv_real" "$uv_seen" 2>/dev/null && continue
    printf '%s\n' "$uv_real" >> "$uv_seen"
    uv_output="$(run_timeout 20 "$uv_raw" --version 2>/dev/null | head -1 || true)"
    uv_version="$(printf '%s\n' "$uv_output" | LC_ALL=C grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -z "$uv_version" ]; then
      NOTES[${#NOTES[@]}]="uv（${uv_raw}）— 版を判定できず未検査"
      continue
    fi
    lookup_minimum_row uv "$uv_version"
    uv_min="$MIN_ROW_MINIMUM"; uv_reason="$MIN_ROW_REASON"
    if [ -z "$uv_min" ] || ! version_less_than "$uv_version" "$uv_min"; then
      security_detail "uv ${uv_version}（${uv_raw}）— 最低版 ${uv_min} 以上"
      continue
    fi
    uv_root="${uv_raw%/bin/uv}"
    if [ -f "$uv_root/pyvenv.cfg" ]; then
      security_detail "uv ${uv_version}（${uv_raw}）— venv の site-packages 側で判定"
      continue
    fi
    uv_root="${uv_real%/bin/uv}"
    if [ -f "$uv_root/pyvenv.cfg" ]; then
      security_detail "uv ${uv_version}（${uv_raw}）— venv の site-packages 側で判定"
    elif printf '%s\n' "$uv_real" | LC_ALL=C grep -q '/Cellar/uv/'; then
      add_warning "uv ${uv_version}（${uv_raw}）は修正版 ${uv_min} より古い版です（${uv_reason}）。直し方: brew upgrade uv"
    else
      case "$uv_raw" in
        "$HOME/.local/bin/uv"|"$HOME/.cargo/bin/uv")
          add_warning "uv ${uv_version}（${uv_raw}）は修正版 ${uv_min} より古い版です（${uv_reason}）。直し方: uv self update"
          ;;
        *) add_warning "uv ${uv_version}（${uv_raw}）は修正版 ${uv_min} より古い版です（${uv_reason}）。入れた方法で更新してください" ;;
      esac
    fi
  done < "$uv_candidates"
}

is_gitlab_image() {
  case "$1" in
    gitlab/gitlab-ce:*|gitlab/gitlab-ee:*|*/gitlab/gitlab-ce:*|*/gitlab/gitlab-ee:*|\
    gitlab/gitlab-ce@*|gitlab/gitlab-ee@*|*/gitlab/gitlab-ce@*|*/gitlab/gitlab-ee@*) return 0 ;;
    *) return 1 ;;
  esac
}

check_gitlab_docker() {
  local docker_cmd ps_output images_output records images image state _names running
  local tag version series row_component row_series row_minimum row_reason minimum reason
  local eol_threshold eol_reason eol_minimum matched remedy
  if [ ! -f "$SECURITY_MINIMUMS" ]; then
    NOTES[${#NOTES[@]}]="GitLab の最低版は同梱リスト不足のため未検査"
    return
  fi
  if [ -n "${RH_DOCKER+x}" ]; then
    docker_cmd="$RH_DOCKER"
  else
    docker_cmd="$(command -v docker 2>/dev/null || true)"
  fi
  [ -n "$docker_cmd" ] && [ -x "$docker_cmd" ] || return
  run_timeout 20 "$docker_cmd" info >/dev/null 2>&1 || return
  ps_output="$(run_timeout 20 "$docker_cmd" ps -a --format '{{.Image}}\t{{.State}}\t{{.Names}}' 2>/dev/null || true)"
  images_output="$(run_timeout 20 "$docker_cmd" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)"
  records="$TMP_DIR/gitlab-docker-records.tsv"
  images="$TMP_DIR/gitlab-docker-images.list"
  : > "$records"
  while IFS=$'\t' read -r image state _names; do
    is_gitlab_image "$image" || continue
    if [ "$state" = "running" ]; then
      printf '%s\trunning\n' "$image" >> "$records"
    else
      printf '%s\tstopped\n' "$image" >> "$records"
    fi
  done <<EOF
$ps_output
EOF
  while IFS= read -r image; do
    is_gitlab_image "$image" || continue
    printf '%s\timage\n' "$image" >> "$records"
  done <<EOF
$images_output
EOF
  [ -s "$records" ] || return
  cut -f1 "$records" | LC_ALL=C sort -u > "$images"

  while IFS= read -r image; do
    running="no"
    if awk -F '\t' -v image="$image" '$1 == image && $2 == "running" { found=1 } END { exit !found }' "$records"; then
      running="yes"
    fi
    tag="${image##*:}"
    version="$(printf '%s' "$tag" | LC_ALL=C grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -z "$version" ]; then
      if [ "$running" = "yes" ]; then
        add_warning "GitLab（${image}）は動いていますが版を判定できません。GitLab の管理画面（/help）で版を確かめ、19.5.1 などの修正版以上か確認してください"
      else
        NOTES[${#NOTES[@]}]="GitLab（${image}）— 版を判定できず未検査"
      fi
      continue
    fi

    series="${version%.*}"
    minimum=""; reason=""; eol_threshold=""; eol_reason=""; eol_minimum=""
    while IFS=$'\t' read -r row_component row_series row_minimum row_reason; do
      case "$row_component" in ''|\#*) continue;; esac
      [ "$row_component" = "gitlab" ] || continue
      if [ "$row_series" = "$series" ]; then
        minimum="$row_minimum"; reason="$row_reason"
      elif [ "$row_series" = "EOL" ]; then
        eol_threshold="$row_minimum"; eol_reason="$row_reason"
      fi
    done < "$SECURITY_MINIMUMS"
    if [ -n "$eol_threshold" ]; then
      while IFS=$'\t' read -r row_component row_series row_minimum _row_reason; do
        case "$row_component" in ''|\#*) continue;; esac
        if [ "$row_component" = "gitlab" ] && [ "$row_series" = "$eol_threshold" ]; then
          eol_minimum="$row_minimum"
          break
        fi
      done < "$SECURITY_MINIMUMS"
    fi
    matched="no"
    if [ -n "$minimum" ] && version_less_than "$version" "$minimum"; then
      matched="minimum"
    elif [ -n "$eol_threshold" ] && version_less_than "$version" "$eol_threshold"; then
      matched="eol"; reason="$eol_reason"; minimum="$eol_minimum"
    fi
    [ "$matched" != "no" ] || continue
    if [ -n "$minimum" ]; then
      remedy="GitLab の更新手順（https://docs.gitlab.com/update/ ）で ${minimum} 以上へ。単一サーバー構成では更新中に止まります"
    else
      remedy="GitLab の更新手順（https://docs.gitlab.com/update/ ）でサポート中の系列へ。単一サーバー構成では更新中に止まります"
    fi
    if [ "$matched" = "eol" ]; then
      if [ "$running" = "yes" ]; then
        add_failure "GitLab ${version}（${image}）が動いています。サポート終了の系列です（${reason}）。${remedy}"
      else
        add_warning "GitLab ${version}（${image}）はサポート終了の系列です（${reason}）。${remedy}"
      fi
    elif [ "$running" = "yes" ]; then
      add_failure "GitLab ${version}（${image}）が動いています。修正版 ${minimum} より古い版です（${reason}）。${remedy}"
    else
      add_warning "GitLab ${version}（${image}）は修正版 ${minimum} より古い版です（${reason}）。${remedy}"
    fi
  done < "$images"
}

tls_probe_once() {
  local kind="$1" path="$2" url="$3" rc
  case "$kind" in
    curl)
      run_timeout 15 "$path" -sS --max-time 14 -o /dev/null "$url" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      [ "$rc" -eq 60 ] && return 60
      return 1
      ;;
    node)
      run_timeout 15 "$path" -e '
const url = process.argv[1];
fetch(url, {redirect: "manual"}).then(() => process.exit(0)).catch((error) => {
  const code = String(error && error.cause && error.cause.code || "");
  process.exit(/^(CERT_|UNABLE_TO_|SELF_SIGNED|DEPTH_ZERO|ERR_TLS_CERT)/.test(code) ? 60 : 1);
});' "$url" >/dev/null 2>&1
      return $?
      ;;
    python)
      run_timeout 15 "$path" -I - "$url" >/dev/null 2>&1 <<'PY'
import ssl
import sys
import urllib.error
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

try:
    opener = urllib.request.build_opener(NoRedirect)
    with opener.open(sys.argv[1], timeout=14):
        pass
except urllib.error.HTTPError:
    raise SystemExit(0)
except urllib.error.URLError as error:
    reason = error.reason
    if isinstance(reason, ssl.SSLCertVerificationError) or (
        isinstance(reason, ssl.SSLError) and "CERTIFICATE_VERIFY_FAILED" in str(reason)
    ):
        raise SystemExit(60)
    raise SystemExit(1)
except ssl.SSLError as error:
    raise SystemExit(60 if "CERTIFICATE_VERIFY_FAILED" in str(error) else 1)
except Exception:
    raise SystemExit(1)
PY
      return $?
      ;;
  esac
  return 1
}

check_tls_security() {
  local tools apple_curl apple_python brew_curl node_path python_path brew_prefix
  local label kind path remedy url subject connected rejected unknown rc apple_connected
  local python_formula python_remedy connected_subject apple_subject
  if [ "$RH_TLS_PROBE" = "0" ]; then
    NOTES[${#NOTES[@]}]="証明書の点検は止めています（設定 RH_TLS_PROBE=0）"
    return
  fi
  if [ ! -f "$TLS_PROBES" ]; then
    NOTES[${#NOTES[@]}]="証明書の点検は同梱リスト不足のため未検査"
    return
  fi
  tools="$TMP_DIR/tls-tools.tsv"
  : > "$tools"
  apple_curl="${RH_PROBE_APPLE_CURL-/usr/bin/curl}"
  [ -x "$apple_curl" ] && printf 'Apple の curl\tcurl\t%s\tApple\n' "$apple_curl" >> "$tools"
  apple_python="${RH_PROBE_APPLE_PYTHON-/usr/bin/python3}"
  if [ -n "${RH_PROBE_APPLE_PYTHON+x}" ] || { command -v xcode-select >/dev/null 2>&1 && xcode-select -p >/dev/null 2>&1; }; then
    [ -x "$apple_python" ] && printf 'Apple の python3\tpython\t%s\tApple\n' "$apple_python" >> "$tools"
  fi
  if [ -n "${RH_PROBE_BREW_CURL+x}" ]; then
    brew_curl="$RH_PROBE_BREW_CURL"
  elif command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    brew_curl="$brew_prefix/opt/curl/bin/curl"
  else
    brew_curl=""
  fi
  [ -n "$brew_curl" ] && [ -x "$brew_curl" ] && printf 'Homebrew の curl\tcurl\t%s\tbrew upgrade curl ca-certificates\n' "$brew_curl" >> "$tools"
  node_path="${RH_PROBE_NODE-$(command -v node 2>/dev/null || true)}"
  [ -n "$node_path" ] && [ -x "$node_path" ] && printf 'Node\tnode\t%s\tbrew upgrade node（Homebrew 以外で入れた場合はその方法で最新版）\n' "$node_path" >> "$tools"
  if [ -n "${RH_PROBE_PYTHON+x}" ]; then
    python_path="$RH_PROBE_PYTHON"
  else
    python_path="$(command -v python3 2>/dev/null || true)"
    [ "$python_path" != "/usr/bin/python3" ] || python_path=""
  fi
  if [ -n "$python_path" ] && [ -x "$python_path" ]; then
    python_formula="$(python3 -c 'import os,re,sys; m=re.search(r"/Cellar/(python@[0-9.]+)/", os.path.realpath(sys.argv[1])); print(m.group(1) if m else "")' "$python_path" 2>/dev/null || true)"
    if [ -n "$python_formula" ]; then
      python_remedy="brew upgrade $python_formula ca-certificates"
    else
      python_remedy="python3 を入れた方法で最新版"
    fi
    printf 'Homebrew などの python3\tpython\t%s\t%s\n' "$python_path" "$python_remedy" >> "$tools"
  fi

  apple_connected=""; apple_subject=""
  while IFS=$'\t' read -r label kind path remedy; do
    connected=0; rejected=0; unknown=0; connected_subject=""
    while IFS=$'\t' read -r url subject; do
      case "$url" in ''|\#*) continue;; esac
      tls_probe_once "$kind" "$path" "$url"
      rc=$?
      case "$rc" in
        0) connected=$((connected + 1)); [ -n "$connected_subject" ] || connected_subject="${subject:-$url}" ;;
        60) rejected=$((rejected + 1)) ;;
        *) unknown=$((unknown + 1)) ;;
      esac
    done < "$TLS_PROBES"
    if [ "$connected" -gt 0 ]; then
      if [ "$remedy" = "Apple" ]; then
        label="${label#Apple の }"
        if [ -z "$apple_connected" ]; then apple_connected="$label"; else apple_connected="${apple_connected}・$label"; fi
        [ -n "$apple_subject" ] || apple_subject="$connected_subject"
      else
        add_warning "$label が失効済みの証明書を信頼しています（${connected_subject}）。$remedy へ更新してください"
      fi
    elif [ "$rejected" -gt 0 ]; then
      security_detail "$label — 失効済みの証明書を拒否（正常）"
    else
      NOTES[${#NOTES[@]}]="$label — 証明書の点検は接続できず未検査"
    fi
  done < "$tools"
  if [ -n "$apple_connected" ]; then
    NOTES[${#NOTES[@]}]="Apple の $apple_connected は失効済みの証明書をまだ信頼しています（${apple_subject}）。Apple の修正待ちです。ソフトウェアアップデートが出たら適用してください"
  fi
}

check_software_updates() {
  local output labels label security_labels other_labels
  if [ "$RH_SKIP_SOFTWAREUPDATE" = "1" ]; then
    NOTES[${#NOTES[@]}]="macOS のアップデート確認は止めています（設定 RH_SKIP_SOFTWAREUPDATE=1）"
    return
  fi
  if ! command -v softwareupdate >/dev/null 2>&1; then
    NOTES[${#NOTES[@]}]="macOS のアップデート確認は未検査"
    return
  fi
  output="$TMP_DIR/softwareupdate.txt"
  if ! run_timeout 180 softwareupdate -l > "$output" 2>/dev/null; then
    NOTES[${#NOTES[@]}]="macOS のアップデート確認は未検査"
    return
  fi
  labels="$(sed -n 's/^[[:space:]]*\*[[:space:]]*Label:[[:space:]]*//p' "$output")"
  security_labels=""; other_labels=""
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    case "$label" in
      *macOS*|*Security*)
        if [ -z "$security_labels" ]; then security_labels="$label"; else security_labels="${security_labels}、$label"; fi
        ;;
      *)
        if [ -z "$other_labels" ]; then other_labels="$label"; else other_labels="${other_labels}、$label"; fi
        ;;
    esac
  done <<EOF
$labels
EOF
  [ -z "$security_labels" ] || add_warning "macOS のアップデートが出ています: ${security_labels}（システム設定 → 一般 → ソフトウェアアップデート）"
  [ -z "$other_labels" ] || security_detail "その他のアップデート: $other_labels"
  if [ -z "$security_labels" ] && [ -z "$other_labels" ]; then
    security_detail "macOS のアップデート待ちはありません"
  fi
}

check_kit_update() {
  local current latest
  if [ "$RH_KIT_UPDATE_CHECK" = "0" ]; then
    NOTES[${#NOTES[@]}]="repo-health-kit の更新確認は止めています（設定 RH_KIT_UPDATE_CHECK=0）"
    return
  fi
  current="$(sed -n '1p' "$KIT_DIR/VERSION" 2>/dev/null || true)"
  latest="$(run_timeout 20 curl -fsS https://raw.githubusercontent.com/5dmgmt/repo-health-kit/main/VERSION 2>/dev/null || true)"
  latest="$(printf '%s' "$latest" | sed -n '1p')"
  if ! printf '%s\n' "$current" | LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    || ! printf '%s\n' "$latest" | LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
    NOTES[${#NOTES[@]}]="repo-health-kit の更新確認は未検査"
  elif version_less_than "$current" "$latest"; then
    add_warning "repo-health-kit の新しい版 $current → $latest があります。clone したフォルダで git pull し、./install.sh を実行してください"
  else
    security_detail "repo-health-kit $current — 更新待ちなし"
  fi
}

software_is_ignored() {
  local wanted="$1" ignored
  for ignored in "${RH_SOFTWARE_IGNORE[@]+"${RH_SOFTWARE_IGNORE[@]}"}"; do
    [ "$wanted" != "$ignored" ] || return 0
  done
  return 1
}

software_is_cli_managed() {
  local kind="$1" name="$2" tool
  for tool in $SOFTWARE_SKIP_TOOLS_EFFECTIVE; do
    case "$tool:$kind:$name" in
      claude:formula:claude-code|claude:cask:claude-code|claude:npm:@anthropic-ai/claude-code) return 0 ;;
      codex:formula:codex|codex:cask:codex|codex:npm:@openai/codex) return 0 ;;
      node:formula:node|node:formula:node@*) return 0 ;;
      npm:npm:npm) return 0 ;;
      gh:formula:gh) return 0 ;;
      vercel:formula:vercel|vercel:npm:vercel) return 0 ;;
      supabase:formula:supabase|supabase:formula:*/supabase|supabase:npm:supabase) return 0 ;;
      op:cask:1password-cli) return 0 ;;
    esac
  done
  return 1
}

software_make_app_inventory() {
  local output="$1" app plist folder display bundle version receipt read_count=0
  local apps
  : > "$output"
  apps="$TMP_DIR/software-app-bundles.list"
  list_app_bundles | awk 'NF && !seen[$0]++' > "$apps"
  while IFS= read -r app; do
    plist="$app/Contents/Info.plist"
    [ -f "$plist" ] || continue
    folder="${app##*/}"
    display="${folder%.app}"
    bundle="$(plist_value "$plist" CFBundleIdentifier 2>/dev/null || true)"
    version="$(plist_value "$plist" CFBundleShortVersionString 2>/dev/null || true)"
    if [ -z "$version" ]; then
      version="$(plist_value "$plist" CFBundleVersion 2>/dev/null || true)"
    fi
    [ -z "$bundle" ] || read_count=$((read_count + 1))
    receipt=0
    [ ! -e "$app/Contents/_MASReceipt" ] || receipt=1
    folder="$(printf '%s' "$folder" | tr '\t\n' '  ')"
    display="$(printf '%s' "$display" | tr '\t\n' '  ')"
    bundle="$(printf '%s' "$bundle" | tr '\t\n' '  ')"
    version="$(printf '%s' "$version" | tr '\t\n' '  ')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$app" "$folder" "$display" "${bundle:--}" "${version:--}" "$receipt" >> "$output"
  done < "$apps"
  if [ -s "$apps" ] && [ "$read_count" -eq 0 ]; then
    NOTES[${#NOTES[@]}]="アプリの目録は Info.plist を一件も読めず未検査"
  fi
}

software_prepare_catalog() {
  local cache="$STATE_DIR/cask-catalog.json" download="$TMP_DIR/cask-catalog.download"
  SOFTWARE_CATALOG=""
  if [ -n "${RH_CASK_CATALOG+x}" ]; then
    if [ -f "$RH_CASK_CATALOG" ] \
      && python3 -I - "$RH_CASK_CATALOG" >/dev/null 2>&1 <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
if not isinstance(data, list):
    raise SystemExit(1)
PY
    then
      SOFTWARE_CATALOG="$RH_CASK_CATALOG"
      return 0
    fi
    NOTES[${#NOTES[@]}]="Homebrew で入れていないアプリの更新確認は未検査（目録を取得できません）"
    return 1
  fi
  if [ -f "$cache" ] && find "$cache" -mmin -1200 -print 2>/dev/null | grep -q .; then
    SOFTWARE_CATALOG="$cache"
    return 0
  fi
  if run_timeout 120 curl -fsS https://formulae.brew.sh/api/cask.json > "$download" 2>/dev/null \
    && python3 -I - "$download" >/dev/null 2>&1 <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
if not isinstance(data, list):
    raise SystemExit(1)
PY
  then
    chmod 600 "$download" 2>/dev/null || true
    mv "$download" "$cache"
    SOFTWARE_CATALOG="$cache"
    return 0
  fi
  if [ -f "$cache" ] && find "$cache" -mtime -7 -print 2>/dev/null | grep -q .; then
    SOFTWARE_CATALOG="$cache"
    return 0
  fi
  NOTES[${#NOTES[@]}]="Homebrew で入れていないアプリの更新確認は未検査（目録を取得できません）"
  return 1
}

check_installed_software() {
  local app_inventory="$TMP_DIR/software-apps.tsv" raw_updates="$TMP_DIR/software-updates.tsv"
  local filtered_updates="$TMP_DIR/software-updates-filtered.tsv"
  local brew_json="$TMP_DIR/software-brew-outdated.json" brew_rows="$TMP_DIR/software-brew.tsv"
  local cask_info="$TMP_DIR/software-cask-info.json" cask_rows="$TMP_DIR/software-casks.tsv"
  local cask_managed="$TMP_DIR/software-cask-managed.tsv" auto_candidates="$TMP_DIR/software-auto.tsv"
  local fixed_keys="$TMP_DIR/software-fixed.keys" remaining_keys="$TMP_DIR/software-remaining.keys"
  local catalog_rows="$TMP_DIR/software-catalog.tsv" catalog_stats="$TMP_DIR/software-catalog-count"
  local mas_rows="$TMP_DIR/software-mas.tsv" npm_json="$TMP_DIR/software-npm.json"
  local npm_rows="$TMP_DIR/software-npm.tsv" state_file="$STATE_DIR/software-outdated.tsv"
  local state_new="$TMP_DIR/software-state.tsv" dated_rows="$TMP_DIR/software-dated.tsv"
  local kind name installed latest remedy key display auto_updates has_app present app_version
  local target wait_suffix package current days today item
  local failed_names="" eligible="$TMP_DIR/software-auto-eligible.tsv"
  local before="$TMP_DIR/software-before.list" after="$TMP_DIR/software-after.list"
  local requested="$TMP_DIR/software-requested.list" snapshot_ok=0
  local mas_cmd
  local homebrew_checked=0 app_checked=0 mas_checked=0 npm_checked=0 mas_installed=0
  local attempted_upgrade=0 formula_rc=0 cask_rc=0 app_candidates=0
  local cask_shown cask_key
  SOFTWARE_SKIP_TOOLS_EFFECTIVE="$RH_SOFTWARE_SKIP_TOOLS"
  if [ "$RH_SECURITY_ONLY" != "1" ] && [ "$RH_SKIP_CLI" != "1" ]; then
    SOFTWARE_SKIP_TOOLS_EFFECTIVE="$SOFTWARE_SKIP_TOOLS_EFFECTIVE claude codex node npm gh vercel supabase op"
  fi
  if [ "$RH_SKIP_SOFTWARE" = "1" ]; then
    NOTES[${#NOTES[@]}]="入っているソフトの更新確認は止めています（設定 RH_SKIP_SOFTWARE=1）"
    return
  fi

  : > "$raw_updates"
  : > "$auto_candidates"
  : > "$fixed_keys"
  : > "$cask_managed"
  software_make_app_inventory "$app_inventory"

  if command -v brew >/dev/null 2>&1; then
    if ! run_timeout 300 brew outdated --greedy --json=v2 > "$brew_json" 2>/dev/null; then
      NOTES[${#NOTES[@]}]="入っているソフトの Homebrew 更新確認は未検査"
    elif python3 -I - "$brew_json" > "$brew_rows" 2>/dev/null <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
for kind, source in (("formula", data.get("formulae", [])), ("cask", data.get("casks", []))):
    if not isinstance(source, list):
        raise SystemExit(1)
    for entry in source:
        if not isinstance(entry, dict) or entry.get("pinned"):
            continue
        name = str(entry.get("name") or entry.get("token") or "")
        versions = entry.get("installed_versions", [])
        if not isinstance(versions, list):
            versions = [versions]
        current = entry.get("current_version") or entry.get("version") or "不明"
        if str(current).lower() == "latest" or any(str(value).lower() == "latest" for value in versions):
            continue
        old = ",".join(str(value) for value in versions if value not in (None, "")) or "不明"
        if name:
            print(f"{kind}\t{name}\t{old}\t{current}")
PY
    then
      while IFS=$'\t' read -r kind name installed latest; do
        [ "$kind" = "formula" ] || continue
        software_is_ignored "$name" && continue
        software_is_cli_managed formula "$name" && continue
        if [ "$RH_AUTOFIX_SECURITY" != "1" ] && brew_formula_is_security "$name"; then continue; fi
        # セキュリティ部品として ① に WARN 済みのものは、③ に重ねて出さず自動更新もしない
        if [ -s "$TMP_DIR/brew-security-warned.list" ] && grep -Fqx "$name" "$TMP_DIR/brew-security-warned.list"; then
          continue
        fi
        homebrew_checked=$((homebrew_checked + 1))
        remedy="brew upgrade $name"
        printf 'formula:%s\tHomebrew\t%s\t%s\t%s\t%s\n' "$name" "$name" "$installed" "$latest" "$remedy" >> "$raw_updates"
        printf 'formula:%s\tformula\t%s\t%s\t%s\n' "$name" "$name" "$installed" "$latest" >> "$auto_candidates"
      done < "$brew_rows"

      set --
      while IFS=$'\t' read -r kind name _installed _latest; do
        [ "$kind" = "cask" ] || continue
        software_is_ignored "$name" && continue
        software_is_cli_managed cask "$name" && continue
        set -- "$@" "$name"
      done < "$brew_rows"
      if [ "$#" -gt 0 ]; then
        if run_timeout 300 brew info --cask --json=v2 "$@" > "$cask_info" 2>/dev/null \
          && python3 -I - "$cask_info" "$brew_rows" "$app_inventory" "$cask_managed" > "$cask_rows" 2>/dev/null <<'PY'
import json
import plistlib
import re
import sys
from pathlib import Path


def values(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from values(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from values(item)


def version_numbers(value):
    return tuple(int(part) for part in re.findall(r"\d+", str(value).split(",", 1)[0]))


def build_numbers(app_path, short):
    # Office は表示版 16.114.1・ビルド 16.114.26102031 で、目録はビルドの方を載せる。
    # 先頭2つが表示版と同じ3桁以上のビルドだけ使う（Chrome の 8078.48 等を誤って使わない）
    try:
        with open(Path(app_path) / "Contents" / "Info.plist", "rb") as handle:
            build = plistlib.load(handle).get("CFBundleVersion")
    except Exception:
        return ()
    parts = version_numbers(build or "")
    short_parts = version_numbers(short)
    if len(parts) >= 3 and len(short_parts) >= 2 and parts[:2] == short_parts[:2]:
        return parts
    return ()


def version_ge(left, right, app_path=None):
    left_parts = version_numbers(left)
    right_parts = version_numbers(right)
    if not left_parts or not right_parts:
        return False
    length = min(len(left_parts), len(right_parts))
    if left_parts[:length] >= right_parts[:length]:
        return True
    build = build_numbers(app_path, left) if app_path else ()
    length = min(len(build), len(right_parts))
    return bool(build) and build[:length] >= right_parts[:length]


with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
outdated = {}
with open(sys.argv[2], encoding="utf-8") as handle:
    for raw in handle:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) == 4 and parts[0] == "cask":
            outdated[parts[1]] = parts[2:]
apps = {}
bundles = {}
with open(sys.argv[3], encoding="utf-8") as handle:
    for raw in handle:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) != 6:
            continue
        apps[parts[1]] = parts
        if parts[3] != "-":
            bundles[parts[3]] = parts
casks = data.get("casks", []) if isinstance(data, dict) else []
if not isinstance(casks, list):
    raise SystemExit(1)
managed = []
for cask in casks:
    if not isinstance(cask, dict):
        continue
    token = str(cask.get("token") or cask.get("name") or "")
    if token not in outdated:
        continue
    app_names = []
    quit_ids = []
    deleted_apps = []
    installs_pkg = False
    for artifact in cask.get("artifacts", []):
        if not isinstance(artifact, dict):
            continue
        if "app" in artifact:
            app_names.extend(Path(value).name for value in values(artifact["app"]))
        # pkg 形式（zoom・Google Drive など）は更新に管理者パスワードが要るので自動更新しない
        if "pkg" in artifact or "installer" in artifact:
            installs_pkg = True
        uninstall = artifact.get("uninstall")
        for entry in uninstall if isinstance(uninstall, list) else [uninstall]:
            if not isinstance(entry, dict):
                continue
            if "quit" in entry:
                quit_ids.extend(values(entry["quit"]))
            if "delete" in entry:
                deleted_apps.extend(
                    Path(value).name for value in values(entry["delete"])
                    if value.startswith("/Applications/") and value.endswith(".app")
                )
    for app_name in app_names + deleted_apps:
        managed.append(("app", app_name))
    for bundle in quit_ids:
        managed.append(("bundle", bundle))
    installed, latest = outdated[token]
    found = next((apps[name] for name in app_names + deleted_apps if name in apps), None)
    if found is None:
        found = next((bundles[bundle] for bundle in quit_ids if bundle in bundles), None)
    actual = found[4] if found is not None else "-"
    # pkg 形式でアプリ名が目録に無いものは、見つからなくても「記録だけ」とは言い切らない
    present = "1" if found is not None or (installs_pkg and not app_names) else "0"
    has_app = "1" if app_names or installs_pkg else "0"
    auto_updates = "1" if cask.get("auto_updates") else "0"
    updated = "1" if found is not None and version_ge(actual, latest, found[0]) else "0"
    print(f"{token}\t{installed}\t{latest}\t{auto_updates}\t{has_app}\t{present}\t{actual}\t{updated}")
with open(sys.argv[4], "w", encoding="utf-8") as handle:
    for kind, value in managed:
        handle.write(f"{kind}\t{value}\n")
PY
        then
          while IFS=$'\t' read -r name installed latest auto_updates has_app present app_version item; do
            homebrew_checked=$((homebrew_checked + 1))
            if [ "$has_app" = "1" ] && [ "$present" = "0" ]; then
              NOTES[${#NOTES[@]}]="$name は Homebrew の記録だけ残っています（アプリは見当たりません）。記録を消すなら brew uninstall --cask $name"
              continue
            fi
            if [ "$has_app" = "1" ] && [ "$item" = "1" ]; then
              security_detail "$name は Homebrew の記録は古いがアプリは更新済み（${app_version}）"
              continue
            fi
            if [ "$has_app" = "1" ]; then
              if [ "$auto_updates" = "1" ]; then
                remedy="アプリの「更新を確認」から（brew upgrade --cask $name でも可。アプリが一度終了します）"
              else
                remedy="brew upgrade --cask $name"
              fi
              # 自分で上がるアプリ（Chrome など）は Homebrew の記録が古いまま残る。表示と「何日止まっているか」はアプリの実物の版で見る
              # （記録の版で数えると、アプリが上がり続けていても、最初に記録が古くなった日から数えてしまう）
              cask_shown="$installed"
              cask_key="cask:$name"
              if [ "$present" = "1" ] && [ -n "$app_version" ] && [ "$app_version" != "-" ]; then
                cask_shown="$app_version"
                cask_key="cask:$name@$app_version"
              fi
              printf '%s\tHomebrew のアプリ\t%s\t%s\t%s\t%s\n' "$cask_key" "$name" "$cask_shown" "$latest" "$remedy" >> "$raw_updates"
            else
              remedy="brew upgrade --cask $name"
              printf 'cask:%s\tHomebrew\t%s\t%s\t%s\t%s\n' "$name" "$name" "$installed" "$latest" "$remedy" >> "$raw_updates"
              printf 'cask:%s\tcask\t%s\t%s\t%s\n' "$name" "$name" "$installed" "$latest" >> "$auto_candidates"
            fi
          done < "$cask_rows"
        else
          NOTES[${#NOTES[@]}]="入っているソフトの Homebrew cask 更新確認は未検査"
        fi
      fi
    else
      NOTES[${#NOTES[@]}]="入っているソフトの Homebrew 更新確認は未検査（応答不正）"
    fi
  fi

  while IFS=$'\t' read -r _item _name _display _bundle _version item; do
    [ "$item" = "0" ] || continue
    case "$_bundle" in com.apple.*) continue ;; esac
    app_candidates=$((app_candidates + 1))
  done < "$app_inventory"
  if [ "$app_candidates" -gt 0 ] && software_prepare_catalog; then
    python3 -I - "$SOFTWARE_CATALOG" "$app_inventory" "$cask_managed" "$catalog_stats" > "$catalog_rows" 2>/dev/null <<'PY'
import json
import plistlib
import re
import sys
from pathlib import Path


def values(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from values(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from values(item)


def numbers(value):
    return tuple(int(part) for part in re.findall(r"\d+", str(value).split(",", 1)[0]))


def build_numbers(app_path, short):
    # 表示版とビルドで書式が違うアプリ（Office）向け。条件は Homebrew 側の同名関数と同じ
    try:
        with open(Path(app_path) / "Contents" / "Info.plist", "rb") as handle:
            build = plistlib.load(handle).get("CFBundleVersion")
    except Exception:
        return ()
    parts = numbers(build or "")
    short_parts = numbers(short)
    if len(parts) >= 3 and len(short_parts) >= 2 and parts[:2] == short_parts[:2]:
        return parts
    return ()


with open(sys.argv[1], encoding="utf-8") as handle:
    catalog = json.load(handle)
managed_names = set()
managed_bundles = set()
try:
    with open(sys.argv[3], encoding="utf-8") as handle:
        for raw in handle:
            kind, _, value = raw.rstrip("\n").partition("\t")
            (managed_names if kind == "app" else managed_bundles).add(value)
except FileNotFoundError:
    pass
by_name = {}
by_bundle = {}
by_deleted = {}
for cask in catalog:
    if not isinstance(cask, dict):
        continue
    token = str(cask.get("token") or "")
    version = str(cask.get("version") or "")
    for artifact in cask.get("artifacts", []):
        if not isinstance(artifact, dict):
            continue
        if "app" in artifact:
            for value in values(artifact["app"]):
                by_name.setdefault(Path(value).name, (token, version))
        uninstall = artifact.get("uninstall")
        entries = uninstall if isinstance(uninstall, list) else [uninstall]
        for entry in entries:
            if isinstance(entry, dict) and "quit" in entry:
                for value in values(entry["quit"]):
                    by_bundle.setdefault(value, (token, version))
            # zoom のように app も quit も無く、削除対象にだけアプリ名が載る cask がある
            if isinstance(entry, dict) and "delete" in entry:
                for value in values(entry["delete"]):
                    if value.startswith("/Applications/") and value.endswith(".app"):
                        by_deleted.setdefault(Path(value).name, (token, version))
checked = 0
with open(sys.argv[2], encoding="utf-8") as handle:
    for raw in handle:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) != 6:
            continue
        _path, folder, display, bundle, current, receipt = parts
        if receipt == "1" or bundle.startswith("com.apple."):
            continue
        if folder in managed_names or bundle in managed_bundles:
            continue
        match = by_name.get(folder)
        if match is None and bundle != "-":
            match = by_bundle.get(bundle)
        if match is None:
            match = by_deleted.get(folder)
        if match is None:
            continue
        token, latest = match
        left = numbers(current)
        right = numbers(latest)
        if not left or not right or latest.lower() == "latest":
            continue
        checked += 1
        length = min(len(left), len(right))
        if left[:length] < right[:length]:
            build = build_numbers(_path, current)
            if build and build[:min(len(build), len(right))] >= right[:min(len(build), len(right))]:
                continue
            print(f"app:{bundle if bundle != '-' else folder}\t{display}\t{current}\t{latest}\t{token}")
with open(sys.argv[4], "w", encoding="utf-8") as handle:
    handle.write(str(checked) + "\n")
PY
    if [ -f "$catalog_stats" ]; then read -r app_checked < "$catalog_stats" || app_checked=0; fi
    while IFS=$'\t' read -r key display current latest name; do
      software_is_ignored "$display" && continue
      remedy="アプリの「更新を確認」から（Homebrew の目録 $name の版と比べた参考値です）"
      printf '%s\tアプリ\t%s\t%s\t%s\t%s\n' "$key" "$display" "$current" "$latest" "$remedy" >> "$raw_updates"
    done < "$catalog_rows"
  fi

  mas_installed="$(awk -F '\t' '$6 == 1 {count++} END {print count+0}' "$app_inventory")"
  mas_cmd="${RH_MAS-}"
  if [ -z "${RH_MAS+x}" ]; then mas_cmd="$(command -v mas 2>/dev/null || true)"; fi
  if [ -n "$mas_cmd" ] && [ -x "$mas_cmd" ]; then
    run_timeout 120 "$mas_cmd" outdated > "$mas_rows" 2>/dev/null || true
    while IFS=$'\t' read -r key display current latest; do
      software_is_ignored "$display" && continue
      mas_checked=$((mas_checked + 1))
      printf 'mas:%s\tApp Store\t%s\t%s\t%s\tApp Store の「アップデート」から\n' "$key" "$display" "$current" "$latest" >> "$raw_updates"
    done < <(python3 -I - "$mas_rows" 2>/dev/null <<'PY'
import re
import sys
with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    for raw in handle:
        match = re.match(r"^\s*(\d+)\s+(.+?)\s+\(([^ ]+)\s+->\s+([^)]+)\)\s*$", raw)
        if match:
            print("\t".join(match.groups()))
PY
    )
    [ "$mas_checked" -ge "$mas_installed" ] || mas_checked="$mas_installed"
  elif [ "$mas_installed" -gt 0 ]; then
    mas_checked="$mas_installed"
    NOTES[${#NOTES[@]}]="App Store のアプリ ${mas_installed} 件は未検査（App Store の「アップデート」で確認できます。brew install mas で点検に入ります）"
  fi

  if command -v npm >/dev/null 2>&1; then
    run_timeout 120 npm outdated -g --json > "$npm_json" 2>/dev/null || true
    if python3 -I - "$npm_json" > "$npm_rows" 2>/dev/null <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
if not isinstance(data, dict):
    raise SystemExit(1)
for name, info in data.items():
    if not isinstance(info, dict):
        continue
    current = str(info.get("current") or "")
    latest = str(info.get("latest") or "")
    if current and latest and current != latest:
        print(f"{name}\t{current}\t{latest}")
PY
    then
      while IFS=$'\t' read -r package current latest; do
        software_is_ignored "$package" && continue
        software_is_cli_managed npm "$package" && continue
        npm_checked=$((npm_checked + 1))
        if [ "$package" = npm ] && npm_is_homebrew_bundled "$(run_timeout 30 npm root -g 2>/dev/null || true)/npm"; then
          security_detail "npm $current は Homebrew の node に付いてくる版です。npm i -g で上げても node の更新で戻るため、node の更新で上がるのを待ちます（最新 ${latest}）"
          continue
        fi
        if ! npm_release_info "$package" "$current"; then
          NOTES[${#NOTES[@]}]="npm $package の公開日を取得できず未検査"
          continue
        fi
        target="$NPM_TARGET"
        if [ -n "$target" ] && version_less_than "$current" "$target"; then
          wait_suffix=""
          if [ "$NPM_LATEST_WAIT" = "1" ] && [ "$NPM_LATEST" != "$target" ]; then
            wait_suffix="。最新 $NPM_LATEST は $NPM_LATEST_DATE 公開・3 日待ち"
          fi
          remedy="npm i -g ${package}@${target}${wait_suffix}"
          printf 'npm:%s\tnpm\t%s\t%s\t%s\t%s\n' "$package" "$package" "$current" "$target" "$remedy" >> "$raw_updates"
        elif [ "$NPM_LATEST_WAIT" = "1" ] && version_less_than "$current" "$NPM_LATEST"; then
          security_detail "$package の最新 $NPM_LATEST は公開から 3 日たっていないので待ちます"
        fi
      done < "$npm_rows"
    else
      NOTES[${#NOTES[@]}]="npm のグローバル更新確認は未検査"
    fi
  else
    NOTES[${#NOTES[@]}]="npm 不在のためグローバルソフトの更新確認は未検査"
  fi

  if [ "$RH_AUTOFIX_SOFTWARE" = "1" ] && [ -s "$auto_candidates" ]; then
    : > "$eligible"
    : > "$requested"
    while IFS=$'\t' read -r key kind name installed latest; do
      if [ "$kind" = "formula" ]; then
        brew_formula_safe_to_upgrade "$name" || continue
        printf '%s\n' "$name" >> "$requested"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$kind" "$name" "$installed" "$latest" >> "$eligible"
    done < "$auto_candidates"
    cp "$eligible" "$auto_candidates"
    set --
    while IFS=$'\t' read -r _key kind name _installed _latest; do
      [ "$kind" = "formula" ] || continue
      set -- "$@" "$name"
    done < "$auto_candidates"
    if [ "$#" -gt 0 ]; then
      if brew_snapshot "$before"; then
        snapshot_ok=1
        attempted_upgrade=1
        HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
          run_timeout 900 brew upgrade --formula "$@" >/dev/null 2>&1 || formula_rc=$?
        if brew_snapshot "$after"; then brew_record_changes "$before" "$after" "$requested"; fi
      fi
    fi
    set --
    while IFS=$'\t' read -r _key kind name _installed _latest; do
      [ "$kind" = "cask" ] || continue
      set -- "$@" "$name"
    done < "$auto_candidates"
    if [ "$#" -gt 0 ]; then
      attempted_upgrade=1
      HOMEBREW_NO_INSTALL_CLEANUP=1 run_timeout 900 brew upgrade --cask "$@" >/dev/null 2>&1 || cask_rc=$?
    fi
    if [ "$attempted_upgrade" = "1" ] && run_timeout 300 brew outdated --greedy --json=v2 > "$brew_json" 2>/dev/null \
      && python3 -I - "$brew_json" > "$remaining_keys" 2>/dev/null <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
for kind, source in (("formula", data.get("formulae", [])), ("cask", data.get("casks", []))):
    for entry in source if isinstance(source, list) else []:
        if isinstance(entry, dict):
            name = entry.get("name") or entry.get("token")
            if name:
                print(f"{kind}:{name}")
PY
    then
      failed_names=""
      while IFS=$'\t' read -r key kind name installed latest; do
        if grep -Fqx "$key" "$remaining_keys"; then
          if [ -z "$failed_names" ]; then failed_names="$name"; else failed_names="$failed_names $name"; fi
        else
          printf '%s\n' "$key" >> "$fixed_keys"
          if [ "$kind" = "cask" ]; then AUTOFIXED[${#AUTOFIXED[@]}]="Homebrew: $name $installed → $latest"; fi
        fi
      done < "$auto_candidates"
      [ -z "$failed_names" ] || add_warning "Homebrew の自動更新に失敗: $failed_names"
    else
      while IFS=$'\t' read -r _key _kind name _installed _latest; do
        if [ -z "$failed_names" ]; then failed_names="$name"; else failed_names="$failed_names $name"; fi
      done < "$auto_candidates"
      [ -z "$failed_names" ] || add_warning "Homebrew の自動更新に失敗: $failed_names"
    fi
  fi
  : "$formula_rc" "$cask_rc" "$snapshot_ok"

  : > "$filtered_updates"
  while IFS=$'\t' read -r key kind display installed latest remedy; do
    if [ -s "$fixed_keys" ] && grep -Fqx "$key" "$fixed_keys"; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$kind" "$display" "$installed" "$latest" "$remedy" >> "$filtered_updates"
  done < "$raw_updates"

  today="${RH_TODAY:-$(TZ=Asia/Tokyo date +%F)}"
  python3 -I - "$state_file" "$filtered_updates" "$today" "$state_new" > "$dated_rows" 2>/dev/null <<'PY'
import sys
from datetime import date

state_path, updates_path, today_raw, new_state = sys.argv[1:]
today = date.fromisoformat(today_raw)
first_seen = {}
try:
    with open(state_path, encoding="utf-8") as handle:
        for raw in handle:
            key, sep, value = raw.rstrip("\n").partition("\t")
            if not sep:
                continue
            try:
                date.fromisoformat(value)
            except ValueError:
                continue
            first_seen[key] = value
except FileNotFoundError:
    pass
rows = []
with open(updates_path, encoding="utf-8") as handle:
    for raw in handle:
        parts = raw.rstrip("\n").split("\t")
        if len(parts) != 6:
            continue
        first = first_seen.get(parts[0], today_raw)
        days = max(0, (today - date.fromisoformat(first)).days)
        rows.append((parts, first, days))
with open(new_state, "w", encoding="utf-8") as handle:
    for parts, first, _days in rows:
        handle.write(f"{parts[0]}\t{first}\n")
for parts, _first, days in rows:
    print("\t".join(parts + [str(days)]))
PY
  if [ -f "$state_new" ]; then
    chmod 600 "$state_new" 2>/dev/null || true
    mv "$state_new" "$state_file"
  fi
  while IFS=$'\t' read -r _key kind display installed latest remedy days; do
    if [ "$days" -ge "$RH_SOFTWARE_STALE_DAYS" ]; then
      add_warning "$display の更新が $days 日止まっています $installed → ${latest}（${remedy}）"
    else
      SOFTWARE_UPDATES[${#SOFTWARE_UPDATES[@]}]="$kind $display $installed → ${latest}（${remedy}）"
    fi
  done < "$dated_rows"

  security_detail "入っているソフト — Homebrew ${homebrew_checked}・アプリ ${app_checked}・App Store ${mas_checked}・npm ${npm_checked} 件を確認"
}

node_keg_is_healthy() {
  local output
  run_timeout 20 "$1" --version >/dev/null 2>&1 || return 1
  output="$(run_timeout 20 "$1" "$TMP_DIR/node-health/check.js" 2>/dev/null)" || return 1
  [ "$output" = "rh-node-ok" ]
}

brew_linkage_is_healthy() {
  local formula="$1" remaining limit start rc
  : "${BREW_LINKAGE_USED:=0}"
  remaining=$((600 - BREW_LINKAGE_USED))
  if [ "$remaining" -le 0 ]; then
    NOTES[${#NOTES[@]}]="Homebrew の ${formula} の linkage は合計制限時間を超えたため未検査"
    return 2
  fi
  limit=60
  [ "$remaining" -ge "$limit" ] || limit="$remaining"
  start=$SECONDS
  run_timeout "$limit" brew linkage --test "$formula" >/dev/null 2>&1
  rc=$?
  BREW_LINKAGE_USED=$((BREW_LINKAGE_USED + SECONDS - start))
  case "$rc" in
    0) return 0;;
    124|137|142)
      NOTES[${#NOTES[@]}]="Homebrew の ${formula} の linkage は制限時間を超えたため未検査"
      return 2;;
    *) return 1;;
  esac
}

brew_repair_health() {
  if [ "$1" = "node" ]; then node_keg_is_healthy "$2"; else brew_linkage_is_healthy "$2"; fi
}

brew_repair_formula() {
  local formula="$1" kind="$2" target="$3" old new rc
  local before="$TMP_DIR/brew-repair-before.list" after="$TMP_DIR/brew-repair-after.list"
  local requested="$TMP_DIR/brew-repair-requested.list" attempts="$TMP_DIR/brew-repair-attempted.list"
  brew_prepare_pins || return 1
  software_is_ignored "$formula" && return 1
  if grep -Fqx "$formula" "$TMP_DIR/brew-pinned.list"; then return 1; fi
  brew_formula_safe_to_upgrade "$formula" || return 1
  [ ! -f "$attempts" ] || ! grep -Fqx "$formula" "$attempts" || return 1
  printf '%s\n' "$formula" >> "$attempts"
  brew_snapshot "$before" || return 1
  old="$(run_timeout 30 brew list --versions "$formula" 2>/dev/null | cut -d ' ' -f 2-)"
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
    run_timeout 900 brew upgrade "$formula" >/dev/null 2>&1 || true
  brew_repair_health "$kind" "$target"; rc=$?
  if [ "$rc" -eq 1 ]; then
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
      run_timeout 900 brew reinstall "$formula" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$formula" > "$requested"
  if brew_snapshot "$after"; then brew_record_changes "$before" "$after" "$requested" "（部品の更新のあと動かなくなったため修復）"; fi
  if brew_repair_health "$kind" "$target"; then
    new="$(run_timeout 30 brew list --versions "$formula" 2>/dev/null | cut -d ' ' -f 2-)"
    if [ "$old" = "$new" ]; then
      AUTOFIXED[${#AUTOFIXED[@]}]="Homebrew: ${formula} ${new} を入れ直し（部品の更新のあと動かなくなったため作り直し版へ）"
    fi
    printf '%s\n' "$formula" >> "$TMP_DIR/brew-health-repaired.list"
    printf '%s\n' "$formula" >> "$TMP_DIR/node-health-fixed.list"
    printf '%s\n' "$formula" >> "$TMP_DIR/brew-updated.list"
    return 0
  fi
  return 1
}

check_updated_formula_linkage() {
  local name dependent rc found
  local updated="$TMP_DIR/brew-updated.list" candidates="$TMP_DIR/brew-linkage-candidates.list"
  local seen="$TMP_DIR/brew-linkage-seen.list" uses="$TMP_DIR/brew-linkage-uses.list"
  [ -s "$updated" ] || return
  : > "$seen"
  while :; do
    : > "$candidates"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      printf '%s\n' "$name" >> "$candidates"
      if run_timeout 30 brew uses --installed --recursive "$name" > "$uses" 2>/dev/null; then
        cat "$uses" >> "$candidates"
      else
        NOTES[${#NOTES[@]}]="Homebrew の ${name} の依存元を取得できず linkage は未検査"
      fi
    done < "$updated"
    LC_ALL=C sort -u "$candidates" > "$candidates.sorted"
    found=0
    while IFS= read -r dependent; do
      [ -n "$dependent" ] || continue
      grep -Fqx "$dependent" "$seen" && continue
      printf '%s\n' "$dependent" >> "$seen"
      found=1
      brew_linkage_is_healthy "$dependent"; rc=$?
      [ "$rc" -eq 1 ] || continue
      if { [ "$RH_AUTOFIX_SOFTWARE" != "1" ] && [ "$RH_AUTOFIX_SECURITY" != "1" ]; } \
        || ! brew_repair_formula "$dependent" linkage "$dependent"; then
        add_warning "Homebrew の ${dependent} の部品のつながりが壊れています（brew reinstall ${dependent} を試してください）"
      fi
    done < "$candidates.sorted"
    [ "$found" = "1" ] || break
    [ "${BREW_LINKAGE_USED:-0}" -lt 600 ] || break
  done
}

refresh_brew_security_warning() {
  local outdated="$TMP_DIR/node-health-outdated.json" pending="$TMP_DIR/node-health-outdated.list"
  local name item description="" index i
  local -a refreshed
  [ -s "$TMP_DIR/brew-security-warned-items.tsv" ] || return
  # 取得できなければ元の WARN を保ち、取得できたときだけ更新済みのものを除きます。
  : > "$pending"
  if run_timeout 300 brew outdated --json=v2 > "$outdated" 2>/dev/null \
    && python3 -I - "$outdated" > "$pending" 2>/dev/null <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
formulae = data.get("formulae")
if not isinstance(formulae, list):
    raise SystemExit(1)
for formula in formulae:
    if not isinstance(formula, dict) or not isinstance(formula.get("name"), str):
        raise SystemExit(1)
    print(formula["name"])
PY
  then
    :
  else
    cp "$TMP_DIR/brew-security-warned.list" "$pending"
  fi
  : > "$TMP_DIR/brew-security-warned.list"
  while IFS=$'\t' read -r name item; do
    if ! grep -Fqx "$name" "$pending"; then
      continue
    fi
    printf '%s\n' "$name" >> "$TMP_DIR/brew-security-warned.list"
    if [ -z "$description" ]; then description="$item"; else description="${description}、$item"; fi
  done < "$TMP_DIR/brew-security-warned-items.tsv"
  index="$(cat "$TMP_DIR/brew-security-warning-index")"
  refreshed=()
  for ((i=0; i<${#WARNINGS[@]}; i++)); do
    if [ "$i" = "$index" ]; then
      if [ -n "$description" ]; then
        refreshed[${#refreshed[@]}]="$(clean_text "Mac のセキュリティ部品に更新が出ています: ${description}（brew upgrade で更新できます）")"
      fi
    else
      refreshed[${#refreshed[@]}]="${WARNINGS[$i]}"
    fi
  done
  WARNINGS=("${refreshed[@]+"${refreshed[@]}"}")
}

check_node_kegs_health() {
  local formula prefix bin pass repair_count=0
  local formulas="$TMP_DIR/node-health-formulae.list" health_dir="$TMP_DIR/node-health"
  command -v brew >/dev/null 2>&1 || return
  if ! run_timeout 30 brew list --formula -1 > "$formulas" 2>/dev/null; then
    NOTES[${#NOTES[@]}]="Homebrew の node 一覧を取得できず起動確認は未検査"
    refresh_brew_security_warning
    return
  fi
  mkdir -p "$health_dir"
  printf '%s\n' '{"name":"rh-node-health","version":"0.0.0","type":"commonjs"}' > "$health_dir/package.json"
  printf '%s\n' 'console.log("rh-node-ok")' > "$health_dir/check.js"
  touch "$TMP_DIR/node-health-fixed.list"
  for pass in 1 2 3; do
    if [ "$pass" = "2" ] && [ "$repair_count" -eq 0 ] && [ ! -s "$TMP_DIR/brew-health-repaired.list" ]; then continue; fi
    while IFS= read -r formula; do
      [[ "$formula" =~ ^node(@[0-9]+)?$ ]] || continue
      if ! prefix="$(run_timeout 20 brew --prefix "$formula" 2>/dev/null)"; then
        [ "$pass" != "1" ] || NOTES[${#NOTES[@]}]="Homebrew の ${formula} の場所を取得できず起動確認は未検査"
        continue
      fi
      bin="$prefix/bin/node"
      if [ ! -x "$bin" ]; then
        [ "$pass" != "1" ] || NOTES[${#NOTES[@]}]="Homebrew の ${formula} の実行ファイルがなく起動確認は未検査"
        continue
      fi
      # 初回起動の遅さだけで修復しないよう、2 回続けて失敗したものだけを扱います。
      node_keg_is_healthy "$bin" && continue
      node_keg_is_healthy "$bin" && continue
      if [ "$pass" != "3" ] && { [ "$RH_AUTOFIX_SOFTWARE" = "1" ] || [ "$RH_AUTOFIX_SECURITY" = "1" ]; }; then
        if brew_repair_formula "$formula" node "$bin"; then repair_count=$((repair_count + 1)); fi
      fi
      if [ "$pass" = "3" ]; then
        add_warning "Homebrew の ${formula} が起動しません（brew reinstall ${formula} を試してください）"
      fi
    done < "$formulas"
    if [ "$pass" = "1" ]; then
      check_updated_formula_linkage
    fi
  done
  refresh_brew_security_warning
}

check_mac_security() {
  if [ "$RH_SKIP_SECURITY" = "1" ]; then
    NOTES[${#NOTES[@]}]="Mac のセキュリティ点検は止めています（設定 RH_SKIP_SECURITY=1）"
    return
  fi
  check_brew_security
  check_installed_software
  check_node_kegs_health
  check_minimum_versions php
  check_minimum_versions node
  check_java_versions
  check_python_packages
  check_gitlab_docker
  check_macos_minimum
  check_claude_minimum
  check_bun_minimum
  check_app_minimums
  check_electron_apps
  check_brew_formula_minimums
  check_tls_security
  check_software_updates
  check_kit_update
}

desktop_notice() {
  local message="$1" sound="${2-}"
  [ "$RH_NO_DESKTOP" = 1 ] && return
  if [ "$sound" = 1 ]; then
    osascript -e "display notification \"$message\" with title \"repo-health\" sound name \"Basso\"" 2>/dev/null || true
  else
    osascript -e "display notification \"$message\" with title \"repo-health\"" 2>/dev/null || true
  fi
}

check_unchecked_streaks() {
  local item key days old_key saved_date _saved_count state_file today yesterday
  local current="$TMP_DIR/unchecked-current" index="$STATE_DIR/unchecked-index"
  today="${RH_TODAY:-$(TZ=Asia/Tokyo date '+%Y-%m-%d')}"
  yesterday="$(python3 - "$today" <<'PY_DATE'
from datetime import date, timedelta
import sys
print((date.fromisoformat(sys.argv[1]) - timedelta(days=1)).isoformat())
PY_DATE
)"
  : > "$current"
  for item in "${NOTES[@]+"${NOTES[@]}"}" "${DETAILS[@]+"${DETAILS[@]}"}" "${DATA_GUARD_NOTES[@]+"${DATA_GUARD_NOTES[@]}"}"; do
    case "$item" in *未検査*) ;; *) continue;; esac
    key="unchecked-$(printf '%s' "$item" | cksum | awk '{print $1}')"
    grep -Fqx -- "$key" "$current" && continue
    printf '%s\n' "$key" >> "$current"
    state_file="$(streak_file "$key")"
    saved_date=""; _saved_count=0
    [ ! -f "$state_file" ] || read -r saved_date _saved_count < "$state_file"
    if [ "$saved_date" != "$today" ] && [ "$saved_date" != "$yesterday" ]; then streak_reset "$key"; fi
    days="$(streak_bump "$key")"
    if [ "$days" -ge 3 ]; then
      add_warning "${item}（未検査が続いて${days}日目。設定や接続を確認してください）"
    fi
  done
  if [ -f "$index" ]; then
    while IFS= read -r old_key; do
      grep -Fqx -- "$old_key" "$current" || streak_reset "$old_key"
    done < "$index"
  fi
  cp "$current" "$index"
  chmod 600 "$index" 2>/dev/null || true
}

send_resend() {
  local subject="$1" body="$2" api_key payload
  [ -n "$RH_MAIL_TO" ] || { printf 'mail: RH_MAIL_TO が未設定です\n' >&2; return 1; }
  if [ -n "$RH_RESEND_KEY_OP" ]; then
    command -v op >/dev/null 2>&1 || { printf 'mail: op CLI が見つかりません\n' >&2; return 1; }
    api_key="$(run_timeout 30 op read "$RH_RESEND_KEY_OP" 2>/dev/null)" || return 1
  else
    command -v security >/dev/null 2>&1 || { printf 'mail: macOS Keychain を利用できません\n' >&2; return 1; }
    api_key="$(run_timeout 30 security find-generic-password -s repo-health-kit -a resend -w 2>/dev/null)" || return 1
  fi
  [ -n "$api_key" ] || { printf 'mail: Resend API キーを取得できません\n' >&2; return 1; }
  payload="$TMP_DIR/resend-payload.json"
  RH_JSON_FROM="$RH_MAIL_FROM" RH_JSON_TO="$RH_MAIL_TO" RH_JSON_SUBJECT="$subject" RH_JSON_BODY="$body" \
    python3 - "$payload" <<'PY'
import json
import os
import sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({
        "from": os.environ["RH_JSON_FROM"],
        "to": [os.environ["RH_JSON_TO"]],
        "subject": os.environ["RH_JSON_SUBJECT"],
        "text": os.environ["RH_JSON_BODY"],
    }, handle, ensure_ascii=False)
PY
  chmod 600 "$payload"
  printf 'header = "Authorization: Bearer %s"\n' "$api_key" | \
    run_timeout 40 curl -fsS -X POST https://api.resend.com/emails \
      -H 'Content-Type: application/json' --data-binary "@$payload" -K - >/dev/null 2>&1
  mail_rc=$?
  unset api_key
  return "$mail_rc"
}

test_mail() {
  local test_subject
  if [ "$RH_NOMAIL" = "1" ]; then
    printf 'mail: RH_NOMAIL=1 のため送信しない\n'
    return 0
  fi
  if [ "$RH_MAIL_METHOD" = "none" ]; then
    printf 'mail: none のため送信しない\n'
    return 0
  fi
  if [ "$RH_SECURITY_ONLY" = "1" ]; then
    test_subject='[mac-security] テスト送信'
  else
    test_subject='[repo-health] テスト送信'
  fi
  if send_resend "$test_subject" 'repo-health-kit のテスト送信です。'; then
    printf 'mail: テスト送信に成功しました\n'
  else
    printf 'mail: テスト送信に失敗しました（キー・宛先・ネットワークを確認してください）\n' >&2
    return 1
  fi
}

if [ "${1:-}" = "--test-mail" ]; then
  test_mail
  exit $?
elif [ "$#" -gt 0 ]; then
  fatal "未対応の引数です: $1"
fi

REPO_LIST="$TMP_DIR/repos.list"
: > "$REPO_LIST"
repo_count=0
for root in "${RH_ROOTS[@]+"${RH_ROOTS[@]}"}"; do
  if [ ! -d "$root" ]; then
    NOTES[${#NOTES[@]}]="対象ルートがありません: $(clean_text "$root")"
    continue
  fi
  find "$root" -mindepth 1 -maxdepth 1 -type d -print0 >> "$REPO_LIST"
done

# git 管理外のフォルダは点検できないので、黙って飛ばさずに知らせる。
# 空のフォルダは参考扱い、隠しフォルダは対象外（数えない）、RH_NONGIT_IGNORE に書いた名前も参考扱いにする。
note_non_git_dir() {
  local dir="$1" name ignored
  name="$(basename "$dir")"
  case "$name" in .*) return 0;; esac
  [ "$RH_WARN_NONGIT" = "1" ] || return 0
  [ "$RH_SECURITY_ONLY" = "1" ] && return 0
  if [ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -not -name '.DS_Store' -print -quit 2>/dev/null)" ]; then
    NOTES[${#NOTES[@]}]="$(quote_name "$name") — 空のフォルダ（git 管理外）"
    return 0
  fi
  for ignored in "${RH_NONGIT_IGNORE[@]+"${RH_NONGIT_IGNORE[@]}"}"; do
    if [ "$ignored" = "$name" ]; then
      NOTES[${#NOTES[@]}]="$(quote_name "$name") — git 管理外のフォルダ（RH_NONGIT_IGNORE により参考扱い）"
      return 0
    fi
  done
  add_warning "$(quote_name "$name") — git 管理外のフォルダです。点検の対象になっていません（git init して remote を設定するか、別の場所へ移すか、RH_NONGIT_IGNORE に名前を加えてください）"
}

[ "$RH_SKIP_SECURITY" = "1" ] || check_node_kegs_health

while IFS= read -r -d '' repo; do
  if [ ! -e "$repo/.git" ]; then
    note_non_git_dir "$repo"
    continue
  fi
  repo_count=$((repo_count + 1))
  if [ "$RH_SECURITY_ONLY" = "1" ]; then
    check_repo_security_only "$repo"
  else
    check_repo "$repo"
  fi
done < "$REPO_LIST"

if [ "$repo_count" -eq 0 ]; then
  if [ "$RH_SECURITY_ONLY" = "1" ]; then
    NOTES[${#NOTES[@]}]="リポが0件のため、侵害パッケージの照合は未検査"
  else
    add_failure "対象リポが0件です（RH_ROOTS の設定を確認してください）"
  fi
fi

check_data_guard

[ "$RH_SECURITY_ONLY" = "1" ] || check_cli_tools
check_mac_security
check_unchecked_streaks

completion_notice=""
last_completed="$(cat "$STATE_DIR/last-completed" 2>/dev/null || true)"
if is_uint "$last_completed"; then
  elapsed=$(( $(date '+%s') - last_completed ))
  if [ "$elapsed" -gt 129600 ]; then
    completion_notice="前回の点検が $((elapsed / 3600)) 時間前で止まっていました"
    add_warning "$completion_notice"
  fi
fi
mail_failures="$(cat "$STATE_DIR/mail-failures" 2>/dev/null || true)"
is_uint "$mail_failures" || mail_failures=0

apply_allowances

fail_count=${#FAILURES[@]}
warn_count=${#WARNINGS[@]}
generated="$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M JST')"
report_draft="$TMP_DIR/report.md"
mail_log="$TMP_DIR/mail-log"
: > "$mail_log"

{
  if [ "$RH_SECURITY_ONLY" = "1" ]; then
    printf '# Mac のセキュリティ点検\n\n'
  else
    printf '# リポジトリ・ヘルスチェック\n\n'
  fi
  [ -z "$completion_notice" ] || printf '%s\n\n' "$completion_notice"
  printf '_生成: %s_\n\n' "$generated"
  printf '**要対応: FAIL %s件 / WARN %s件**\n\n' "$fail_count" "$warn_count"
  printf '## ① 要対応\n\n'
  if [ "$fail_count" -eq 0 ] && [ "$warn_count" -eq 0 ]; then
    printf 'ALL GREEN（FAIL/WARN なし）\n'
  else
    for item in "${FAILURES[@]+"${FAILURES[@]}"}"; do printf -- '- FAIL  %s\n' "$item"; done
    for item in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do printf -- '- WARN  %s\n' "$item"; done
  fi
  printf '\n## ② 自動で直したもの\n\n'
  if [ "${#AUTOFIXED[@]}" -eq 0 ]; then printf 'なし\n'; else for item in "${AUTOFIXED[@]+"${AUTOFIXED[@]}"}"; do printf -- '- %s\n' "$(clean_text "$item")"; done; fi
  if [ "$RH_SECURITY_ONLY" = "1" ]; then
    printf '\n## ③ 参考（Mac のセキュリティ・ソフト更新）\n\n'
  else
    printf '\n## ③ 参考（作業中・同期待ち・CLI 更新あり・Mac のセキュリティ・ソフト更新）\n\n'
    printf -- '- 作業中: %s件\n- 同期待ち: %s件\n- CLI 更新あり: %s件\n' "${#WORKING[@]}" "${#SYNC_WAIT[@]}" "${#CLI_UPDATES[@]}"
    for item in "${WORKING[@]+"${WORKING[@]}"}"; do printf -- '- %s\n' "$(clean_text "$item")"; done
    for item in "${SYNC_WAIT[@]+"${SYNC_WAIT[@]}"}"; do printf -- '- %s\n' "$(clean_text "$item")"; done
    for item in "${CLI_UPDATES[@]+"${CLI_UPDATES[@]}"}"; do printf -- '- %s\n' "$(clean_text "$item")"; done
  fi
  printf -- '- ソフト更新あり: %s件\n' "${#SOFTWARE_UPDATES[@]}"
  for item in "${SOFTWARE_UPDATES[@]+"${SOFTWARE_UPDATES[@]}"}"; do printf -- '- ソフト更新: %s\n' "$item"; done
  for item in "${NOTES[@]+"${NOTES[@]}"}"; do printf -- '- %s\n' "$(clean_text "$item")"; done
  printf '\n## データの守り（Supabase ほか）\n\n'
  for item in "${DATA_GUARD_NOTES[@]+"${DATA_GUARD_NOTES[@]}"}"; do printf -- '- %s\n' "$item"; done
  printf "\n## ④ 全文の場所\n\n- 最新: \`%s\`\n- 履歴: \`%s\`\n" "$REPORT" "$LOG_FILE"
  printf '\n---\n\n## 点検詳細\n\n'
  for item in "${DETAILS[@]+"${DETAILS[@]}"}"; do printf -- '- %s\n' "$(clean_text "$item")"; done
} > "$report_draft" || fatal "レポートを書き込めません: $REPORT"
chmod 600 "$report_draft" 2>/dev/null || true

sed -n '1,$p' "$report_draft"

if [ $((fail_count + warn_count + mail_failures)) -gt 0 ]; then
  if [ "$RH_NOMAIL" = "1" ]; then
    printf 'mail: RH_NOMAIL=1 のため送信しない\n' >> "$mail_log"
  elif [ "$RH_MAIL_METHOD" = "none" ]; then
    printf 'mail: none のため送信しない\n' >> "$mail_log"
  else
    hostname_short="$(hostname -s 2>/dev/null || printf 'Mac')"
    hostname_short="$(clean_text "$hostname_short")"
    if [ "$RH_SECURITY_ONLY" = "1" ]; then
      subject="[mac-security] FAIL ${fail_count}件 / WARN ${warn_count}件 — ${hostname_short}"
    else
      subject="[repo-health] FAIL ${fail_count}件 / WARN ${warn_count}件 — ${hostname_short}"
    fi
    mail_body="$TMP_DIR/mail-body.txt"
    {
      [ "$mail_failures" -eq 0 ] || printf '前回まで %s 回送れませんでした\n\n' "$mail_failures"
      [ -z "$completion_notice" ] || printf '%s\n\n' "$completion_notice"
      printf '■ 要対応\n'
      for item in "${FAILURES[@]+"${FAILURES[@]}"}"; do printf '  - FAIL  %s\n' "$item"; done
      for item in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do printf '  - WARN  %s\n' "$item"; done
      printf '\n■ 自動で直したもの\n'
      if [ "${#AUTOFIXED[@]}" -eq 0 ]; then printf '  なし\n'; else for item in "${AUTOFIXED[@]+"${AUTOFIXED[@]}"}"; do printf '  - %s\n' "$item"; done; fi
      if [ "$RH_SECURITY_ONLY" = "1" ]; then
        printf '\n■ 参考\n  ソフト更新あり %s件\n' "${#SOFTWARE_UPDATES[@]}"
      else
        printf '\n■ 参考\n  作業中 %s件 / 同期待ち %s件 / CLI 更新あり %s件 / ソフト更新あり %s件\n' "${#WORKING[@]}" "${#SYNC_WAIT[@]}" "${#CLI_UPDATES[@]}" "${#SOFTWARE_UPDATES[@]}"
      fi
      printf '\n■ データの守り（Supabase ほか）\n'
      for item in "${DATA_GUARD_NOTES[@]+"${DATA_GUARD_NOTES[@]}"}"; do printf '  - %s\n' "$item"; done
      printf '\n■ 全文の場所\n  %s\n'  "$REPORT"
    } > "$mail_body"
    if send_resend "$subject" "$(sed -n '1,$p' "$mail_body")"; then
      printf 'mail: sent\n' >> "$mail_log"
      rm -f "$STATE_DIR/mail-failures"
    else
      printf 'mail: FAILED（キー・宛先・ネットワークを確認してください）\n' >> "$mail_log"
      printf '%s\n' "$((mail_failures + 1))" > "$STATE_DIR/mail-failures"
      chmod 600 "$STATE_DIR/mail-failures" 2>/dev/null || true
      desktop_notice '点検結果のメールを送れませんでした。設定と接続を確認してください'
    fi
  fi
fi

if [ "$fail_count" -gt 0 ]; then
  desktop_notice 'repo-health で FAIL。ローカルのレポートを確認してください' 1
elif [ "$warn_count" -gt 0 ] && [ "$RH_MAIL_METHOD" = none ]; then
  desktop_notice 'repo-health で WARN。ローカルのレポートを確認してください'
fi
# 通知まで済んだ結果だけを最新レポートと履歴に反映します。
mv "$report_draft" "$REPORT" || fatal "レポートを書き込めません: $REPORT"
{
  printf '\n===== %s repo-health =====\n' "$generated"
  sed -n '1,$p' "$REPORT"
  cat "$mail_log"
} >> "$LOG_FILE" || fatal "履歴ログへ追記できません: $LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true
printf '%s\n' "$(date '+%s')" > "$STATE_DIR/last-completed"
chmod 600 "$STATE_DIR/last-completed" 2>/dev/null || true
[ "$fail_count" -eq 0 ] || exit 1
exit 0
