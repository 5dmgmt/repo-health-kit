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
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
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
if [ -z "$RH_ENV_ROOTS_SET" ]; then
  RH_ROOTS=("$HOME/Plugins")
fi
: "${RH_MAIL_METHOD:=none}"
: "${RH_MAIL_FROM:=onboarding@resend.dev}"
: "${RH_MAIL_TO:=}"
: "${RH_RESEND_KEY_OP:=}"
: "${RH_AUTOFIX_PULL:=1}"
: "${RH_AUTOFIX_CLI:=0}"
: "${RH_FETCH_FAIL_DAYS:=2}"
: "${RH_DIRTY_DAYS_WARN:=3}"
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

case "$RH_MAIL_METHOD" in resend|none) ;; *) fatal "RH_MAIL_METHOD は resend または none を指定してください";; esac
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

APP_DIR="${RH_APP_DIR:-$HOME/Library/Application Support/repo-health-kit}"
LOG_DIR="${RH_LOG_DIR:-$HOME/Library/Logs/repo-health-kit}"
STATE_DIR="${RH_STATE_DIR:-$APP_DIR/state}"
LOG_FILE="$LOG_DIR/repo-health.log"
REPORT="$LOG_DIR/repo-health-latest.md"
DENYLIST="${RH_DENYLIST:-$KIT_DIR/config/pkg-denylist.tsv}"
DENY_SCANNER="${RH_DENY_SCANNER:-$SCRIPT_DIR/pkg-denylist-scan.py}"
VULN_ALLOW_FILE="${RH_VULN_ALLOW_FILE:-$HOME/.config/repo-health-kit/vuln-allow.tsv}"
SECURITY_PACKAGES="${RH_SECURITY_PACKAGES:-$KIT_DIR/config/security-packages.txt}"
SECURITY_MINIMUMS="${RH_SECURITY_MINIMUMS:-$KIT_DIR/config/security-minimums.tsv}"
TLS_PROBES="${RH_TLS_PROBES:-$KIT_DIR/config/tls-probes.tsv}"

mkdir -p "$LOG_DIR" "$STATE_DIR" || fatal "ログまたは状態の保存先を作成できません"
chmod 700 "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repo-health.XXXXXX")" || fatal "一時ディレクトリを作成できません"
# shellcheck disable=SC2329  # trap から呼び出します。
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

declare -a FAILURES WARNINGS AUTOFIXED WORKING SYNC_WAIT CLI_UPDATES NOTES DETAILS
FAILURES=(); WARNINGS=(); AUTOFIXED=(); WORKING=(); SYNC_WAIT=(); CLI_UPDATES=(); NOTES=(); DETAILS=()

add_failure() { FAILURES[${#FAILURES[@]}]="$(clean_text "$*")"; }
add_warning() { WARNINGS[${#WARNINGS[@]}]="$(clean_text "$*")"; }
add_detail() { DETAILS[${#DETAILS[@]}]="$(clean_text "$*")"; }

run_timeout() {
  local seconds="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}

streak_key() {
  local base checksum
  base="$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  checksum="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  printf '%s-%s' "$base" "$checksum"
}

streak_file() {
  printf '%s/%s.state' "$STATE_DIR" "$(streak_key "$1")"
}

streak_bump() {
  local file today saved_date count
  file="$(streak_file "$1")"
  today="$(TZ=Asia/Tokyo date '+%Y-%m-%d')"
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

git_internal_path() {
  local repo="$1" value
  value="$(git -C "$repo" rev-parse --git-path "$2" 2>/dev/null)" || return 1
  case "$value" in
    /*) printf '%s' "$value" ;;
    *) printf '%s/%s' "$repo" "$value" ;;
  esac
}

vulnerability_allowed() {
  local repo="$1" today row_repo advisory expiry reason
  [ -f "$VULN_ALLOW_FILE" ] || return 1
  today="$(TZ=Asia/Tokyo date '+%Y-%m-%d')"
  while IFS=$'\t' read -r row_repo advisory expiry reason; do
    case "$row_repo" in ''|\#*) continue;; esac
    [ "$row_repo" = "$repo" ] || continue
    case "$expiry" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) continue;; esac
    [ "$expiry" \< "$today" ] && continue
    printf '%s\t%s\t%s' "$advisory" "$expiry" "$reason"
    return 0
  done < "$VULN_ALLOW_FILE"
  return 1
}

is_exempt_env_name() {
  case "$(basename -- "$1")" in
    .env.local|.env.tpl|.env.example|.env.sample) return 0 ;;
    *) return 1 ;;
  esac
}

looks_like_plain_secret() {
  local file="$1" base
  base="$(basename -- "$file")"
  if [ "$base" = ".env" ] && LC_ALL=C grep -qE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=.+' "$file" 2>/dev/null; then
    return 0
  fi
  LC_ALL=C grep -qE 'AIza[0-9A-Za-z_-]{35}|sk-ant-[A-Za-z0-9_-]{40,}|sk-proj-[A-Za-z0-9_-]{40,}|sk_(live|test)_[A-Za-z0-9]{20,}|whsec_[A-Za-z0-9]{25,}|gh[pous]_[A-Za-z0-9]{30,}|sbp_[a-f0-9]{40}|xox[baprs]-[A-Za-z0-9-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----' "$file" 2>/dev/null
}

scan_secret_file() {
  local repo="$1" repo_name="$2" kind="$3" rel="$4" file
  is_exempt_env_name "$rel" && return 0
  case "$rel" in *node_modules/*) return 0;; esac
  file="$repo/$rel"
  [ -f "$file" ] || return 0
  if looks_like_plain_secret "$file"; then
    if [ "$kind" = "tracked" ]; then
      add_failure "$repo_name — 平文シークレットが commit 済み: $rel"
    else
      add_failure "$repo_name — 平文シークレットが未追跡かつ gitignore 外: $rel"
    fi
  fi
}

scan_secrets() {
  local repo="$1" repo_name="$2" rel
  while IFS= read -r -d '' rel; do
    scan_secret_file "$repo" "$repo_name" tracked "$rel"
  done < <(git -C "$repo" -c core.quotepath=false ls-files -z 2>/dev/null)
  while IFS= read -r -d '' rel; do
    scan_secret_file "$repo" "$repo_name" untracked "$rel"
  done < <(git -C "$repo" -c core.quotepath=false ls-files --others --exclude-standard -z 2>/dev/null)
}

scan_nonstandard_env() {
  local repo="$1" repo_name="$2" file keys modified now days
  for file in "$repo"/.env.*; do
    [ -f "$file" ] || continue
    is_exempt_env_name "$file" && continue
    keys="$(LC_ALL=C grep -cE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=.+' "$file" 2>/dev/null || true)"
    is_uint "$keys" || keys=0
    [ "$keys" -gt 0 ] || continue
    modified="$(stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null || printf '0')"
    now="$(date '+%s')"
    is_uint "$modified" || modified=0
    days=$(( (now - modified) / 86400 ))
    add_warning "$repo_name — 運用フロー外の env ファイル $(basename -- "$file")（${keys}キー・${days}日前）"
  done
}

audit_manifest() {
  local repo="$1" repo_name="$2" manifest="$3" manifest_dir lock rel label output counts critical high allow_row
  manifest_dir="$(dirname -- "$manifest")"
  lock="$manifest_dir/package-lock.json"
  rel="${manifest_dir#"$repo"/}"
  if [ "$manifest_dir" = "$repo" ]; then label="$repo_name"; else label="$repo_name/$rel"; fi
  if [ ! -f "$lock" ]; then
    # 入れ子で lock が無いものは、同梱の部品や教材のひな形（稼働物ではない）として扱う。複数機版と同じ判定
    if [ "$manifest_dir" = "$repo" ]; then
      add_warning "$label — package.json ありに lockfile なし（監査不能）"
    else
      add_detail "$label — lockfile なしの入れ子（同梱物として未監査）"
    fi
    return
  fi
  if [ "$RH_SKIP_AUDIT" = "1" ]; then
    add_detail "$label — npm audit は RH_SKIP_AUDIT=1 のため未検査"
    return
  fi
  if ! command -v npm >/dev/null 2>&1; then
    add_warning "$label — npm audit 実行不能（npm 不在）"
    return
  fi
  output="$TMP_DIR/audit-$(streak_key "$manifest").json"
  (cd "$manifest_dir" && run_timeout 120 npm audit --omit=dev --package-lock-only --json --fetch-timeout=60000 --fetch-retries=0 > "$output" 2>/dev/null) || true
  counts="$(python3 - "$output" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
    vuln = data.get("metadata", {}).get("vulnerabilities")
    if not isinstance(vuln, dict):
        raise ValueError
    print(f"{int(vuln.get('critical', 0))}|{int(vuln.get('high', 0))}|{int(vuln.get('moderate', 0))}|{int(vuln.get('low', 0))}")
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    pass
PY
)"
  if [ -z "$counts" ]; then
    add_warning "$label — npm audit 実行不能（timeout・ネットワーク・応答不正のいずれか）"
    return
  fi
  IFS='|' read -r critical high _moderate _low <<EOF
$counts
EOF
  if [ $((critical + high)) -gt 0 ]; then
    if allow_row="$(vulnerability_allowed "$repo_name")"; then
      NOTES[${#NOTES[@]}]="$label — 本番 critical/high は期限付き据え置き（${allow_row}）"
    else
      add_failure "$label — 本番依存に critical/high 脆弱性（${critical} critical / ${high} high）"
    fi
  fi
  add_detail "$label — npm audit(prod): ${critical} critical / ${high} high / ${_moderate} moderate / ${_low} low"
}

audit_composer_lock() {
  local repo="$1" repo_name="$2" lock="$3" manifest_dir rel label output counts
  local critical high medium low unknown allow_row composer_path
  manifest_dir="$(dirname -- "$lock")"
  rel="${manifest_dir#"$repo"/}"
  if [ "$manifest_dir" = "$repo" ]; then label="$repo_name"; else label="$repo_name/$rel"; fi
  if [ "$RH_SKIP_AUDIT" = "1" ]; then
    add_detail "$label — composer audit は RH_SKIP_AUDIT=1 のため未検査"
    return
  fi
  composer_path="${RH_COMPOSER_PATH-$(command -v composer 2>/dev/null || true)}"
  if [ -z "$composer_path" ]; then
    add_warning "$label — composer audit 実行不能（composer 不在）"
    return
  fi
  output="$TMP_DIR/composer-audit-$(streak_key "$lock").json"
  (cd "$manifest_dir" && run_timeout 120 "$composer_path" audit --locked --no-dev --format=json --no-interaction > "$output" 2>/dev/null) || true
  counts="$(python3 - "$output" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
    advisories = data.get("advisories")
    if not isinstance(advisories, (dict, list)):
        raise ValueError
    entries = []
    values = advisories.values() if isinstance(advisories, dict) else advisories
    for value in values:
        if isinstance(value, list):
            entries.extend(item for item in value if isinstance(item, dict))
        elif isinstance(value, dict):
            entries.append(value)
    counts = {key: 0 for key in ("critical", "high", "medium", "low", "unknown")}
    for advisory in entries:
        severity = str(advisory.get("severity", "")).lower()
        counts[severity if severity in counts else "unknown"] += 1
    print("|".join(str(counts[key]) for key in ("critical", "high", "medium", "low", "unknown")))
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    pass
PY
)"
  if [ -z "$counts" ]; then
    add_warning "$label — composer audit 実行不能（timeout・ネットワーク・応答不正のいずれか）"
    return
  fi
  IFS='|' read -r critical high medium low unknown <<EOF
$counts
EOF
  if [ $((critical + high)) -gt 0 ]; then
    if allow_row="$(vulnerability_allowed "$repo_name")"; then
      NOTES[${#NOTES[@]}]="$label — 本番 critical/high は期限付き据え置き（${allow_row}）"
    else
      add_failure "$label — 本番依存に critical/high 脆弱性（composer）"
    fi
  elif [ "$unknown" -gt 0 ]; then
    add_warning "$label — composer audit に重さ不明の指摘 ${unknown}件"
  fi
  add_detail "$label — composer audit(prod): ${critical} critical / ${high} high / ${medium} medium / ${low} low / ${unknown} unknown"
}

scan_manifests() {
  local repo="$1" repo_name="$2" manifest list composer_list
  list="$TMP_DIR/manifests-$(streak_key "$repo").list"
  : > "$list"
  [ -f "$repo/package.json" ] && printf '%s\0' "$repo/package.json" >> "$list"
  while IFS= read -r -d '' manifest; do
    printf '%s\0' "$repo/$manifest" >> "$list"
  done < <(git -C "$repo" -c core.quotepath=false ls-files -z -- '*/package.json' 2>/dev/null)
  while IFS= read -r -d '' manifest; do
    audit_manifest "$repo" "$repo_name" "$manifest"
  done < "$list"

  composer_list="$TMP_DIR/composer-locks-$(streak_key "$repo").list"
  : > "$composer_list"
  [ -f "$repo/composer.lock" ] && printf '%s\0' "$repo/composer.lock" >> "$composer_list"
  while IFS= read -r -d '' manifest; do
    printf '%s\0' "$repo/$manifest" >> "$composer_list"
  done < <(git -C "$repo" -c core.quotepath=false ls-files -z -- '*/composer.lock' 2>/dev/null)
  while IFS= read -r -d '' manifest; do
    audit_composer_lock "$repo" "$repo_name" "$manifest"
  done < "$composer_list"
}

scan_denylist() {
  local repo="$1" repo_name="$2" output rc line prefix hit_repo lock package reason
  output="$TMP_DIR/deny-$(streak_key "$repo").txt"
  if [ ! -f "$DENY_SCANNER" ] || [ ! -f "$DENYLIST" ]; then
    add_failure "$repo_name — 侵害パッケージ照合が動いていません（同梱ファイル不足）"
    return
  fi
  run_timeout 60 python3 "$DENY_SCANNER" --repo "$repo" --name "$repo_name" --denylist "$DENYLIST" > "$output" 2>/dev/null
  rc=$?
  while IFS= read -r line; do
    IFS='|' read -r prefix hit_repo lock package reason <<EOF
$line
EOF
    case "$prefix" in
      DENY) add_failure "$hit_repo — 侵害パッケージが入っています: ${package}（${reason}・${lock}）" ;;
      DENYSKIP) add_failure "$repo_name — 侵害パッケージ照合が動いていません: $lock" ;;
    esac
  done < "$output"
  if [ "$rc" -eq 2 ] && [ ! -s "$output" ]; then
    add_failure "$repo_name — 侵害パッケージ照合が異常終了しました"
  fi
}

check_git_size() {
  local repo="$1" repo_name="$2" git_dir kb mb size_file previous growth
  git_dir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || return
  kb="$(du -sk "$git_dir" 2>/dev/null | awk '{print $1}')"
  is_uint "$kb" || kb=0
  mb=$((kb / 1024))
  if [ "$mb" -gt "$RH_GIT_MB_WARN" ]; then
    add_warning "$repo_name — .git ${mb}MB（閾値 ${RH_GIT_MB_WARN}MB 超）"
  fi
  size_file="$STATE_DIR/$(streak_key "size-$repo_name").size"
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

check_repo() {
  local repo="$1" repo_name fetch branch state rebase_merge rebase_apply merge_head
  local ahead behind dirty stash fetch_days dirty_days stale_days upstream base unmerged
  local ff_ok git_status_count
  repo_name="$(clean_text "$(basename -- "$repo")")"

  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    add_failure "$repo_name — git repo 破損（rev-parse 不能）"
    return
  fi

  fetch="OK"
  if ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    fetch="NOREMOTE"
    add_warning "$repo_name — origin 未設定"
  elif [ "$RH_SKIP_FETCH" = "1" ]; then
    fetch="SKIP"
    add_detail "$repo_name — fetch は RH_SKIP_FETCH=1 のため未検査"
  elif run_timeout 90 git -C "$repo" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 fetch --prune --quiet origin >/dev/null 2>&1 \
    || { sleep 3; run_timeout 90 git -C "$repo" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 fetch --prune --quiet origin >/dev/null 2>&1; }; then
    streak_reset "fetch-$repo_name"
  else
    fetch="NG"
    fetch_days="$(streak_bump "fetch-$repo_name")"
    if [ "$fetch_days" -ge "$RH_FETCH_FAIL_DAYS" ]; then
      add_failure "$repo_name — fetch 失敗が${fetch_days}日連続（認証または remote を確認してください）"
    else
      add_warning "$repo_name — fetch 失敗（${fetch_days}日目。継続すると FAIL）"
    fi
  fi

  branch="$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null || printf 'DETACHED')"
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
    if upstream="$(git -C "$repo" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"; then
      ahead="$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || printf '?')"
      behind="$(git -C "$repo" rev-list --count 'HEAD..@{u}' 2>/dev/null || printf '?')"
    else
      upstream=""
      ahead="NOUP"; behind="NOUP"
      add_warning "$repo_name — upstream 未設定（${branch}）"
    fi
  fi
  if is_uint "$ahead" && [ "$ahead" -gt 0 ]; then add_warning "$repo_name — 未push $ahead 件"; fi

  git_status_count="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  is_uint "$git_status_count" || git_status_count=0
  dirty="$git_status_count"
  stash="$(git -C "$repo" stash list 2>/dev/null | wc -l | tr -d ' ')"
  is_uint "$stash" || stash=0

  if [ "$RH_AUTOFIX_PULL" = "1" ] && [ "$dirty" -eq 0 ] && [ "$stash" -eq 0 ] \
    && is_uint "$ahead" && [ "$ahead" -eq 0 ] && is_uint "$behind" && [ "$behind" -gt 0 ]; then
    if run_timeout 90 git -C "$repo" pull --ff-only --quiet >/dev/null 2>&1; then
      AUTOFIXED[${#AUTOFIXED[@]}]="$repo_name — behind ${behind}件を ff で解消"
      behind="$(git -C "$repo" rev-list --count 'HEAD..@{u}' 2>/dev/null || printf '0')"
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

  if [ "$dirty" -gt 0 ]; then
    dirty_days="$(streak_bump "dirty-$repo_name")"
    if [ "$dirty_days" -ge "$RH_DIRTY_DAYS_WARN" ]; then
      add_warning "$repo_name — dirty ${dirty}件が${dirty_days}日連続（コミットまたは退避を確認してください）"
    else
      WORKING[${#WORKING[@]}]="$repo_name — dirty ${dirty}件（${dirty_days}日目・作業中）"
    fi
  else
    streak_reset "dirty-$repo_name"
  fi
  [ "$stash" -gt 0 ] && add_warning "$repo_name — stash $stash 件残置"

  base=""
  for upstream in origin/HEAD origin/main origin/master; do
    if git -C "$repo" rev-parse -q --verify "$upstream" >/dev/null 2>&1; then base="$upstream"; break; fi
  done
  if [ "$fetch" != "NOREMOTE" ] && [ -n "$base" ]; then
    unmerged="$(git -C "$repo" for-each-ref --format='%(refname)' --no-merged "$base" refs/remotes/origin 2>/dev/null | LC_ALL=C grep -cv '^refs/remotes/origin/HEAD$' || true)"
    is_uint "$unmerged" || unmerged=0
    [ "$unmerged" -gt 0 ] && add_warning "$repo_name — 未マージ remote ブランチ $unmerged 本"
  fi

  if is_uint "$behind" && [ "$behind" -ge "$RH_STALE_BEHIND_THRESHOLD" ] && [ "$dirty" -gt 0 ]; then
    stale_days="$(streak_bump "stale-$repo_name")"
    if [ "$stale_days" -ge "$RH_STALE_DAYS_FAIL" ]; then
      add_failure "$repo_name — ${stale_days}日連続で behind>=${RH_STALE_BEHIND_THRESHOLD} かつ dirty"
    fi
  else
    streak_reset "stale-$repo_name"
  fi

  check_git_size "$repo" "$repo_name"
  scan_secrets "$repo" "$repo_name"
  scan_nonstandard_env "$repo" "$repo_name"
  scan_manifests "$repo" "$repo_name"
  scan_denylist "$repo" "$repo_name"
  add_detail "$repo_name — fetch=$fetch branch=$branch ahead=$ahead behind=$behind dirty=$dirty stash=$stash state=$state"
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
  local left="$1" right="$2" l1 l2 l3 r1 r2 r3
  IFS=. read -r l1 l2 l3 <<EOF
$left
EOF
  IFS=. read -r r1 r2 r3 <<EOF
$right
EOF
  l1=${l1:-0}; l2=${l2:-0}; l3=${l3:-0}
  r1=${r1:-0}; r2=${r2:-0}; r3=${r3:-0}
  is_uint "$l1" && is_uint "$l2" && is_uint "$l3" && is_uint "$r1" && is_uint "$r2" && is_uint "$r3" || return 1
  [ "$l1" -lt "$r1" ] && return 0
  [ "$l1" -gt "$r1" ] && return 1
  [ "$l2" -lt "$r2" ] && return 0
  [ "$l2" -gt "$r2" ] && return 1
  [ "$l3" -lt "$r3" ]
}

update_cli() {
  local tool="$1" path="$2" real package formula
  real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || printf '%s' "$path")"
  case "$tool" in
    claude) package='@anthropic-ai/claude-code'; formula='claude-code' ;;
    codex) package='@openai/codex'; formula='codex' ;;
    npm) package='npm'; formula='' ;;
    vercel|supabase) package="$tool"; formula="$tool" ;;
    node) package=''; formula='node' ;;
    gh) package=''; formula='gh' ;;
    op) package=''; formula='1password-cli' ;;
    *) return 1 ;;
  esac
  case "$real$path" in
    */node_modules/*)
      [ -n "$package" ] || return 1
      run_timeout 600 npm install -g "${package}@latest" >/dev/null 2>&1
      ;;
    */.local/bin/claude)
      run_timeout 600 "$path" update >/dev/null 2>&1
      ;;
    /opt/homebrew/bin/*|/usr/local/bin/*)
      [ -n "$formula" ] && command -v brew >/dev/null 2>&1 || return 1
      run_timeout 600 brew upgrade "$formula" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

check_cli_tools() {
  local tool path current latest duplicate duplicate_version current_major latest_major
  if [ "$RH_SKIP_CLI" = "1" ]; then
    NOTES[${#NOTES[@]}]="CLI 更新確認は RH_SKIP_CLI=1 のため未検査"
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
    latest="$(latest_version "$tool" || true)"
    if [ -z "$latest" ]; then
      NOTES[${#NOTES[@]}]="$tool — 最新版を取得できず未検査"
      continue
    fi
    if version_less_than "$current" "$latest"; then
      current_major="${current%%.*}"; latest_major="${latest%%.*}"
      if [ "$latest_major" -gt "$current_major" ]; then
        if [ "$RH_AUTOFIX_CLI" = "1" ] && update_cli "$tool" "$path"; then
          AUTOFIXED[${#AUTOFIXED[@]}]="$tool — メジャー版遅れ $current → $latest を自動更新"
        else
          add_warning "$tool — メジャー版が遅れています $current → $latest"
        fi
      else
        CLI_UPDATES[${#CLI_UPDATES[@]}]="$tool — $current → $latest"
      fi
    elif [ "$current" != "$latest" ]; then
      NOTES[${#NOTES[@]}]="$tool — 公開最新版より先行（現在 $current / 公開 ${latest}）"
    fi
  done
}

security_detail() {
  add_detail "Mac のセキュリティ — $*"
}

check_brew_security() {
  local outdated_json rows remaining name installed latest description failed_description
  local upgrade_description brew_prefix
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
  if ! python3 - "$outdated_json" "$SECURITY_PACKAGES" > "$rows" 2>/dev/null <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
patterns = []
with open(sys.argv[2], encoding="utf-8") as handle:
    for raw in handle:
        value = raw.strip()
        if value and not value.startswith("#"):
            patterns.append(value)
formulae = data.get("formulae")
if not isinstance(formulae, list):
    raise SystemExit(1)
for formula in formulae:
    if not isinstance(formula, dict):
        continue
    name = str(formula.get("name", ""))
    if not any(name.startswith(item[:-1]) if item.endswith("*") else name == item for item in patterns):
        continue
    installed = formula.get("installed_versions", [])
    old = ",".join(str(item) for item in installed) if isinstance(installed, list) else str(installed)
    new = formula.get("current_version") or formula.get("stable") or "不明"
    print(f"{name}\t{old or '不明'}\t{new}")
PY
  then
    NOTES[${#NOTES[@]}]="Homebrew のセキュリティ部品は応答不正のため未検査"
    return
  fi
  if [ ! -s "$rows" ]; then
    security_detail "Homebrew のセキュリティ部品は更新待ちなし"
    return
  fi

  remaining="$TMP_DIR/brew-security-remaining.tsv"
  : > "$remaining"
  failed_description=""
  while IFS=$'\t' read -r name installed latest; do
    if [ "$name" = "ca-certificates" ] && [ "$RH_AUTOFIX_CA_CERTS" = "1" ]; then
      # 名指しした部品だけを上げる（Homebrew は既定で、依存する別の部品の更新も一緒に行うため）
      if HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 run_timeout 600 brew upgrade ca-certificates >/dev/null 2>&1; then
        AUTOFIXED[${#AUTOFIXED[@]}]="ca-certificates — 証明書リスト ${installed} → ${latest} を自動更新"
      else
        failed_description="ca-certificates の自動更新に失敗しました（brew upgrade を手で実行してください）"
      fi
    else
      printf '%s\t%s\t%s\n' "$name" "$installed" "$latest" >> "$remaining"
    fi
  done < "$rows"
  [ -z "$failed_description" ] || add_warning "$failed_description"
  [ -s "$remaining" ] || return

  if [ "$RH_AUTOFIX_SECURITY" = "1" ]; then
    set --
    while IFS=$'\t' read -r name _installed _latest; do
      set -- "$@" "$name"
    done < "$remaining"
    if HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 run_timeout 900 brew upgrade "$@" >/dev/null 2>&1; then
      while IFS=$'\t' read -r name installed latest; do
        AUTOFIXED[${#AUTOFIXED[@]}]="$name — セキュリティ部品 $installed → $latest を自動更新"
      done < "$remaining"
      return
    fi
    upgrade_description=""
    while IFS=$'\t' read -r name _installed _latest; do
      if [ -z "$upgrade_description" ]; then upgrade_description="$name"; else upgrade_description="${upgrade_description}、$name"; fi
    done < "$remaining"
    add_warning "$upgrade_description の自動更新に失敗しました（brew upgrade を手で実行してください）"
    return
  fi

  description=""
  while IFS=$'\t' read -r name installed latest; do
    if [ -z "$description" ]; then
      description="$name $installed → $latest"
    else
      description="${description}、$name $installed → $latest"
    fi
  done < "$remaining"
  add_warning "Mac のセキュリティ部品に更新が出ています: ${description}（brew upgrade で更新できます）"
  brew_prefix="$(brew --prefix 2>/dev/null || true)"
  [ -z "$brew_prefix" ] || security_detail "Homebrew: $brew_prefix"
}

check_php_security() {
  local candidates seen bin real version series minimum reason eol_threshold eol_reason
  local listening lsof_output suffix kind matched httpd_pid keg kegs
  if [ ! -f "$SECURITY_MINIMUMS" ]; then
    NOTES[${#NOTES[@]}]="PHP の最低版は同梱リスト不足のため未検査"
    return
  fi
  candidates="$TMP_DIR/php-candidates.list"
  seen="$TMP_DIR/php-seen.list"
  kegs="$TMP_DIR/php-kegs.list"
  : > "$candidates"
  : > "$seen"
  : > "$kegs"
  type -aP php 2>/dev/null >> "$candidates" || true
  type -aP php-fpm 2>/dev/null >> "$candidates" || true
  [ -x /opt/homebrew/sbin/php-fpm ] && printf '%s\n' /opt/homebrew/sbin/php-fpm >> "$candidates"
  [ -x /usr/local/sbin/php-fpm ] && printf '%s\n' /usr/local/sbin/php-fpm >> "$candidates"

  listening="no"
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
    if [ -z "$version" ]; then
      NOTES[${#NOTES[@]}]="${kind}（${bin}）— 版を判定できず未検査"
      continue
    fi
    series="${version%.*}"
    minimum=""; reason=""; eol_threshold=""; eol_reason=""
    while IFS=$'\t' read -r component row_series row_minimum row_reason; do
      case "$component" in ''|\#*) continue;; esac
      [ "$component" = "php" ] || continue
      if [ "$row_series" = "$series" ]; then
        minimum="$row_minimum"; reason="$row_reason"
      elif [ "$row_series" = "EOL" ]; then
        eol_threshold="$row_minimum"; eol_reason="$row_reason"
      fi
    done < "$SECURITY_MINIMUMS"
    matched="no"
    if [ -n "$minimum" ] && version_less_than "$version" "$minimum"; then
      matched="minimum"
    elif [ -n "$eol_threshold" ] && version_less_than "$version" "$eol_threshold"; then
      matched="eol"
      reason="$eol_reason"
    fi
    if [ "$matched" = "no" ]; then
      security_detail "$kind ${version}（${bin}）— 最低版を満たしています"
      continue
    fi
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
  done < "$candidates"
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
    NOTES[${#NOTES[@]}]="証明書の点検は RH_TLS_PROBE=0 のため未検査"
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
    NOTES[${#NOTES[@]}]="macOS のアップデート確認は RH_SKIP_SOFTWAREUPDATE=1 のため未検査"
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
    NOTES[${#NOTES[@]}]="repo-health-kit の更新確認は RH_KIT_UPDATE_CHECK=0 のため未検査"
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

check_mac_security() {
  if [ "$RH_SKIP_SECURITY" = "1" ]; then
    NOTES[${#NOTES[@]}]="Mac のセキュリティ点検は RH_SKIP_SECURITY=1 のため未検査"
    return
  fi
  check_brew_security
  check_php_security
  check_tls_security
  check_software_updates
  check_kit_update
}

send_resend() {
  local subject="$1" body="$2" api_key payload
  [ -n "$RH_MAIL_TO" ] || { printf 'mail: RH_MAIL_TO が未設定です\n' >&2; return 1; }
  if [ -n "$RH_RESEND_KEY_OP" ]; then
    command -v op >/dev/null 2>&1 || { printf 'mail: op CLI が見つかりません\n' >&2; return 1; }
    api_key="$(run_timeout 30 op read "$RH_RESEND_KEY_OP" 2>/dev/null)" || return 1
  else
    command -v security >/dev/null 2>&1 || { printf 'mail: macOS Keychain を利用できません\n' >&2; return 1; }
    api_key="$(security find-generic-password -s repo-health-kit -a resend -w 2>/dev/null)" || return 1
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
  if [ "$RH_NOMAIL" = "1" ]; then
    printf 'mail: RH_NOMAIL=1 のため送信しない\n'
    return 0
  fi
  if [ "$RH_MAIL_METHOD" = "none" ]; then
    printf 'mail: none のため送信しない\n'
    return 0
  fi
  if send_resend '[repo-health] テスト送信' 'repo-health-kit のテスト送信です。'; then
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

while IFS= read -r -d '' repo; do
  [ -e "$repo/.git" ] || continue
  repo_count=$((repo_count + 1))
  check_repo "$repo"
done < "$REPO_LIST"

if [ "$repo_count" -eq 0 ]; then
  add_failure "対象リポが0件です（RH_ROOTS の設定を確認してください）"
fi

check_cli_tools
check_mac_security

fail_count=${#FAILURES[@]}
warn_count=${#WARNINGS[@]}
generated="$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M JST')"

{
  printf '# リポジトリ・ヘルスチェック\n\n'
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
  if [ "${#AUTOFIXED[@]}" -eq 0 ]; then printf 'なし\n'; else for item in "${AUTOFIXED[@]+"${AUTOFIXED[@]}"}"; do printf -- '- %s\n' "$item"; done; fi
  printf '\n## ③ 参考（作業中・同期待ち・CLI 更新あり・Mac のセキュリティ）\n\n'
  printf -- '- 作業中: %s件\n- 同期待ち: %s件\n- CLI 更新あり: %s件\n' "${#WORKING[@]}" "${#SYNC_WAIT[@]}" "${#CLI_UPDATES[@]}"
  for item in "${WORKING[@]+"${WORKING[@]}"}"; do printf -- '- %s\n' "$item"; done
  for item in "${SYNC_WAIT[@]+"${SYNC_WAIT[@]}"}"; do printf -- '- %s\n' "$item"; done
  for item in "${CLI_UPDATES[@]+"${CLI_UPDATES[@]}"}"; do printf -- '- %s\n' "$item"; done
  for item in "${NOTES[@]+"${NOTES[@]}"}"; do printf -- '- %s\n' "$item"; done
  printf "\n## ④ 全文の場所\n\n- 最新: \`%s\`\n- 履歴: \`%s\`\n" "$REPORT" "$LOG_FILE"
  printf '\n---\n\n## 点検詳細\n\n'
  for item in "${DETAILS[@]+"${DETAILS[@]}"}"; do printf -- '- %s\n' "$item"; done
} > "$REPORT" || fatal "レポートを書き込めません: $REPORT"
chmod 600 "$REPORT" 2>/dev/null || true

{
  printf '\n===== %s repo-health =====\n' "$generated"
  sed -n '1,$p' "$REPORT"
} >> "$LOG_FILE" || fatal "履歴ログへ追記できません: $LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true

sed -n '1,$p' "$REPORT"

if [ $((fail_count + warn_count)) -gt 0 ]; then
  if [ "$RH_NOMAIL" = "1" ]; then
    printf 'mail: RH_NOMAIL=1 のため送信しない\n' >> "$LOG_FILE"
  elif [ "$RH_MAIL_METHOD" = "none" ]; then
    printf 'mail: none のため送信しない\n' >> "$LOG_FILE"
  else
    hostname_short="$(hostname -s 2>/dev/null || printf 'Mac')"
    hostname_short="$(clean_text "$hostname_short")"
    subject="[repo-health] FAIL ${fail_count}件 / WARN ${warn_count}件 — ${hostname_short}"
    mail_body="$TMP_DIR/mail-body.txt"
    {
      printf '■ 要対応\n'
      for item in "${FAILURES[@]+"${FAILURES[@]}"}"; do printf '  - FAIL  %s\n' "$item"; done
      for item in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do printf '  - WARN  %s\n' "$item"; done
      printf '\n■ 自動で直したもの\n'
      if [ "${#AUTOFIXED[@]}" -eq 0 ]; then printf '  なし\n'; else for item in "${AUTOFIXED[@]+"${AUTOFIXED[@]}"}"; do printf '  - %s\n' "$item"; done; fi
      printf '\n■ 参考\n  作業中 %s件 / 同期待ち %s件 / CLI 更新あり %s件\n' "${#WORKING[@]}" "${#SYNC_WAIT[@]}" "${#CLI_UPDATES[@]}"
      printf '\n■ 全文の場所\n  %s\n' "$REPORT"
    } > "$mail_body"
    if send_resend "$subject" "$(sed -n '1,$p' "$mail_body")"; then
      printf 'mail: sent\n' >> "$LOG_FILE"
    else
      printf 'mail: FAILED（キー・宛先・ネットワークを確認してください）\n' >> "$LOG_FILE"
    fi
  fi
fi

if [ "$fail_count" -gt 0 ] && [ "$RH_NO_DESKTOP" != "1" ]; then
  osascript -e 'display notification "repo-health で FAIL。ローカルのレポートを確認してください" with title "repo-health" sound name "Basso"' 2>/dev/null || true
fi
[ "$fail_count" -eq 0 ] || exit 1
exit 0
