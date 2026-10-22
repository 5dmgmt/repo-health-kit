#!/bin/bash

# 以下では、実行時に展開させる変数を単一引用符で偽コマンドへ書き出します。
# shellcheck disable=SC2016

set -uo pipefail

TEST_DIR="$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(unset CDPATH; cd -- "$TEST_DIR/.." && pwd)"
HEALTH="$PROJECT_DIR/bin/repo-health.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/repo-health-tests.XXXXXX")" || exit 1
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

total=0
failed=0
REPO_PATH=""

pass() { total=$((total + 1)); printf 'ok %s - %s\n' "$total" "$1"; }
fail() { total=$((total + 1)); failed=$((failed + 1)); printf 'not ok %s - %s\n' "$total" "$1"; }

assert_contains() {
  local description="$1" file="$2" pattern="$3"
  if LC_ALL=C grep -qE "$pattern" "$file"; then pass "$description"; else fail "$description"; sed -n '1,120p' "$file"; fi
}

assert_not_contains() {
  local description="$1" file="$2" pattern="$3"
  if LC_ALL=C grep -qE "$pattern" "$file"; then fail "$description"; sed -n '1,120p' "$file"; else pass "$description"; fi
}

make_remote_repo() {
  local case_dir="$1" name="$2" root bare
  root="$case_dir/root with space"
  bare="$case_dir/origin.git"
  mkdir -p "$root"
  git init -q --bare "$bare"
  git clone -q "$bare" "$root/$name" 2>/dev/null
  REPO_PATH="$root/$name"
  git -C "$REPO_PATH" config user.name tester
  git -C "$REPO_PATH" config user.email tester@example.invalid
  printf '# fixture\n' > "$REPO_PATH/README.md"
  git -C "$REPO_PATH" add README.md
  git -C "$REPO_PATH" commit -q -m 'test: initial'
  git -C "$REPO_PATH" push -q -u origin HEAD
}

run_health() {
  local case_dir="$1" root="$2" output
  output="$case_dir/output.txt"
  mkdir -p "$case_dir/home"
  HOME="$case_dir/home" \
  RH_ROOTS="$root" \
  RH_LOG_DIR="$case_dir/log" \
  RH_STATE_DIR="$case_dir/state" \
  RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_SKIP_SECURITY=1 \
  RH_AUTOFIX_PULL=0 RH_MAIL_METHOD=none RH_NOMAIL=1 RH_NO_DESKTOP=1 \
    bash "$HEALTH" > "$output" 2>&1 || true
}

run_security() {
  local case_dir="$1" fake_bin="$2" output
  shift 2
  output="$case_dir/output.txt"
  mkdir -p "$case_dir/home" "$case_dir/root"
  env PATH="$fake_bin:$PATH" HOME="$case_dir/home" \
    RH_CONFIG_FILE="$case_dir/no-config.sh" RH_ROOTS="$case_dir/root" \
    RH_LOG_DIR="$case_dir/log" RH_STATE_DIR="$case_dir/state" \
    RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_SKIP_SECURITY=0 \
    RH_AUTOFIX_PULL=0 RH_MAIL_METHOD=none RH_NOMAIL=1 RH_NO_DESKTOP=1 \
    RH_TLS_PROBE=0 RH_SKIP_SOFTWAREUPDATE=1 RH_KIT_UPDATE_CHECK=0 \
    RH_NODE_CANDIDATES= RH_JAVA_CANDIDATES= RH_DOCKER="$fake_bin/missing-docker" \
    "$@" bash "$HEALTH" > "$output" 2>&1 || true
}

make_fake_brew() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  update) exit "${FAKE_BREW_UPDATE_RC:-0}" ;;'
    printf '%s\n' '  outdated) if [ -n "${FAKE_BREW_JSON-}" ]; then printf "%s\n" "$FAKE_BREW_JSON"; else printf "%s\n" '\''{"formulae":[]}'\''; fi ;;'
    printf '%s\n' '  upgrade) printf "%s\n" "$*" >> "${FAKE_BREW_LOG:?}"; printf "deps-check=%s\n" "${HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK:-}" >> "${FAKE_BREW_LOG:?}"; exit "${FAKE_BREW_UPGRADE_RC:-0}" ;;'
    printf '%s\n' '  --prefix) printf "%s\n" "${FAKE_BREW_PREFIX:-/fake/homebrew}" ;;'
    printf '%s\n' '  *) exit 1 ;;'
    printf '%s\n' 'esac'
  } > "$fake_bin/brew"
  chmod +x "$fake_bin/brew"
}

make_fake_php() {
  local fake_bin="$1"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  -r) printf "%s" "${FAKE_PHP_VERSION:?}" ;;'
    printf '%s\n' '  -v) printf "PHP %s (fpm-fcgi)\n" "${FAKE_PHP_VERSION:?}" ;;'
    printf '%s\n' '  *) exit 1 ;;'
    printf '%s\n' 'esac'
  } > "$fake_bin/php"
  chmod +x "$fake_bin/php"
}

make_fake_node() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  -p) printf "%s" "${FAKE_NODE_VERSION-}" ;;'
    printf '%s\n' '  *) exit 1 ;;'
    printf '%s\n' 'esac'
  } > "$fake_bin/node"
  chmod +x "$fake_bin/node"
}

make_fake_java_home() {
  local home="$1" version="$2"
  mkdir -p "$home"
  printf 'JAVA_VERSION="%s"\n' "$version" > "$home/release"
}

make_fake_docker() {
  local path="$1"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  info) exit "${FAKE_DOCKER_INFO_RC:-0}" ;;'
    printf '%s\n' '  ps) printf "%b" "${FAKE_DOCKER_PS-}" ;;'
    printf '%s\n' '  images) printf "%b" "${FAKE_DOCKER_IMAGES-}" ;;'
    printf '%s\n' '  *) exit 1 ;;'
    printf '%s\n' 'esac'
  } > "$path"
  chmod +x "$path"
}

make_fake_lsof() {
  local fake_bin="$1"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'printf "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"'
    printf '%s\n' 'if [ "${2:-}" = "-p" ]; then [ "${FAKE_HTTPD_PHP:-0}" = "1" ] && printf "httpd 77 user txt REG 1,4 0 0 /opt/homebrew/opt/php/lib/httpd/modules/libphp.so\n"; exit 0; fi'
    printf '%s\n' 'if [ "${FAKE_PHP_LISTEN:-0}" = "1" ]; then printf "php-fpm 42 user 3u IPv4 0t0 TCP *:9000 (LISTEN)\n"; fi'
    printf '%s\n' 'if [ "${FAKE_HTTPD_LISTEN:-0}" = "1" ]; then printf "httpd 77 user 4u IPv6 0t0 TCP *:8080 (LISTEN)\n"; fi'
  } > "$fake_bin/lsof"
  chmod +x "$fake_bin/lsof"
}

make_exit_command() {
  local path="$1" rc="$2"
  {
    printf '%s\n' '#!/bin/bash'
    printf 'exit %s\n' "$rc"
  } > "$path"
  chmod +x "$path"
}

run_composer() {
  local case_dir="$1" root="$2" composer_path="$3" output
  output="$case_dir/output.txt"
  mkdir -p "$case_dir/home"
  HOME="$case_dir/home" RH_CONFIG_FILE="$case_dir/no-config.sh" RH_ROOTS="$root" \
    RH_LOG_DIR="$case_dir/log" RH_STATE_DIR="$case_dir/state" \
    RH_SKIP_AUDIT=0 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_SKIP_SECURITY=1 \
    RH_COMPOSER_PATH="$composer_path" RH_AUTOFIX_PULL=0 RH_MAIL_METHOD=none \
    RH_NOMAIL=1 RH_NO_DESKTOP=1 bash "$HEALTH" > "$output" 2>&1 || true
}

printf '1..76\n'

case_dir="$TEST_TMP/clean"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" '見本 リポ'
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'clean なリポは要対応0件' "$case_dir/output.txt" '要対応: FAIL 0件 / WARN 0件'

case_dir="$TEST_TMP/detached"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" detached
git -C "$REPO_PATH" checkout -q --detach
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'detached HEAD は FAIL' "$case_dir/output.txt" 'FAIL  detached .* detached HEAD'

case_dir="$TEST_TMP/env"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" envrepo
printf '.env.local\n' > "$REPO_PATH/.gitignore"
git -C "$REPO_PATH" add .gitignore
git -C "$REPO_PATH" commit -q -m 'test: ignore local env'
git -C "$REPO_PATH" push -q
printf 'API_KEY=plain-text\n' > "$REPO_PATH/.env"
printf 'API_KEY=ignored-local\n' > "$REPO_PATH/.env.local"
run_health "$case_dir" "$case_dir/root with space"
assert_contains '未追跡かつ gitignore 外の .env は FAIL' "$case_dir/output.txt" 'FAIL  envrepo .*未追跡かつ gitignore 外: .env'
assert_not_contains '.env.local は検出対象外' "$case_dir/output.txt" '\.env\.local'

case_dir="$TEST_TMP/stash"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" stashrepo
printf 'change\n' >> "$REPO_PATH/README.md"
git -C "$REPO_PATH" stash push -q
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'stash 残置は WARN' "$case_dir/output.txt" 'WARN  stashrepo .*stash 1 件残置'

case_dir="$TEST_TMP/no-origin"
root="$case_dir/root"
repo="$root/no-origin"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name tester
git -C "$repo" config user.email tester@example.invalid
printf 'fixture\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m 'test: initial'
run_health "$case_dir" "$root"
assert_contains 'origin 未設定は WARN' "$case_dir/output.txt" 'WARN  no-origin .*origin 未設定'

case_dir="$TEST_TMP/gitlab-origin"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" gitlab-one
git clone -q "$case_dir/origin.git" "$case_dir/root with space/gitlab-two" 2>/dev/null
git -C "$case_dir/root with space/gitlab-one" remote set-url origin 'https://gitlab.example.co.jp/team/one.git'
git -C "$case_dir/root with space/gitlab-two" remote set-url origin 'git@gitlab.example.co.jp:team/two.git'
run_health "$case_dir" "$case_dir/root with space"
if [ "$(LC_ALL=C grep -c 'gitlab.example.co.jp は自社で動かしている GitLab の可能性があります' "$case_dir/output.txt")" = "1" ]; then
  pass '同じ自社 GitLab ホストは NOTES 1件にまとめる'
else
  fail '同じ自社 GitLab ホストは NOTES 1件にまとめる'
  sed -n '1,120p' "$case_dir/output.txt"
fi

case_dir="$TEST_TMP/gitlab-com-origin"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" gitlab-com
git -C "$REPO_PATH" remote set-url origin 'https://gitlab.com/team/repo.git'
run_health "$case_dir" "$case_dir/root with space"
assert_not_contains 'gitlab.com は自社 GitLab の NOTES を出さない' "$case_dir/output.txt" '自社で動かしている GitLab'

case_dir="$TEST_TMP/dirty"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" dirtyrepo
printf 'working\n' >> "$REPO_PATH/README.md"
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'dirty 1日目は作業中' "$case_dir/output.txt" 'dirty 1件（1日目・作業中）'
assert_not_contains 'dirty 1日目は WARN にしない' "$case_dir/output.txt" 'WARN  dirtyrepo .*dirty'
state_file="$(find "$case_dir/state" -name 'dirty-*.state' -print -quit)"
yesterday="$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d')"
printf '%s 2\n' "$yesterday" > "$state_file"
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'dirty 3日目は WARN' "$case_dir/output.txt" 'WARN  dirtyrepo .*dirty 1件が3日連続'

case_dir="$TEST_TMP/denylist"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" denyrepo
printf '{"name":"fixture","version":"1.0.0"}\n' > "$REPO_PATH/package.json"
printf '%s\n' '{"name":"fixture","lockfileVersion":3,"packages":{"":{"name":"fixture","version":"1.0.0"},"node_modules/keyv":{"version":"6.0.0"}}}' > "$REPO_PATH/package-lock.json"
git -C "$REPO_PATH" add package.json package-lock.json
git -C "$REPO_PATH" commit -q -m 'test: add lockfile'
git -C "$REPO_PATH" push -q
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'denylist 完全一致は FAIL' "$case_dir/output.txt" 'FAIL  denyrepo .*keyv@6.0.0'

case_dir="$TEST_TMP/unsafe-config"
mkdir -p "$case_dir/home/.config/repo-health-kit" "$case_dir/root"
printf 'RH_MAIL_METHOD="none"\n' > "$case_dir/home/.config/repo-health-kit/config.sh"
chmod 666 "$case_dir/home/.config/repo-health-kit/config.sh"
HOME="$case_dir/home" RH_ROOTS="$case_dir/root" RH_SKIP_CLI=1 RH_NO_DESKTOP=1 bash "$HEALTH" > "$case_dir/output.txt" 2>&1
unsafe_rc=$?
if [ "$unsafe_rc" -ne 0 ]; then pass '権限666の設定ファイルは停止する'; else fail '権限666の設定ファイルは停止する'; fi
assert_contains '危険な設定ファイルを読まない理由を表示' "$case_dir/output.txt" '権限が安全でないため読みません'

case_dir="$TEST_TMP/test-mail"
mkdir -p "$case_dir/home"
HOME="$case_dir/home" RH_MAIL_METHOD=none bash "$HEALTH" --test-mail > "$case_dir/output.txt" 2>&1
assert_contains '--test-mail と none は送信しない' "$case_dir/output.txt" 'none のため送信しない'

case_dir="$TEST_TMP/install"
mkdir -p "$case_dir/home"
HOME="$case_dir/home" RH_NO_LAUNCHCTL=1 RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_NO_DESKTOP=1 \
  RH_SKIP_SECURITY=1 \
  bash "$PROJECT_DIR/install.sh" > "$case_dir/install-output.txt" 2>&1
install_rc=$?
installed_assets=0
if [ -f "$case_dir/home/Library/Application Support/repo-health-kit/VERSION" ] \
  && [ -f "$case_dir/home/Library/Application Support/repo-health-kit/config/security-packages.txt" ] \
  && [ -f "$case_dir/home/Library/Application Support/repo-health-kit/config/security-minimums.tsv" ] \
  && [ -f "$case_dir/home/Library/Application Support/repo-health-kit/config/tls-probes.tsv" ]; then
  installed_assets=1
fi
HOME="$case_dir/home" RH_NO_LAUNCHCTL=1 bash "$PROJECT_DIR/uninstall.sh" > "$case_dir/uninstall-output.txt" 2>&1
uninstall_rc=$?
if [ "$install_rc" -eq 0 ] && [ "$uninstall_rc" -eq 0 ] \
  && [ ! -e "$case_dir/home/Library/LaunchAgents/com.repo-health-kit.plist" ]; then
  pass '一時 HOME で install と uninstall が完了する'
else
  fail '一時 HOME で install と uninstall が完了する'
  sed -n '1,160p' "$case_dir/install-output.txt"
  sed -n '1,80p' "$case_dir/uninstall-output.txt"
fi
if [ "$installed_assets" -eq 1 ]; then
  pass 'install は版情報とセキュリティ判定表をコピーする'
else
  fail 'install は版情報とセキュリティ判定表をコピーする'
fi
if [ -f "$case_dir/home/.config/repo-health-kit/config.sh" ] \
  && [ -f "$case_dir/home/Library/Logs/repo-health-kit/repo-health-latest.md" ]; then
  pass 'uninstall 後も設定とログを残す'
else
  fail 'uninstall 後も設定とログを残す'
fi

case_dir="$TEST_TMP/security-ca"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" \
  FAKE_BREW_LOG="$case_dir/brew.log" \
  FAKE_BREW_JSON='{"formulae":[{"name":"ca-certificates","installed_versions":["2026-09-25"],"current_version":"2026-10-20"}]}'
assert_contains 'ca-certificates は既定で brew upgrade する' "$case_dir/brew.log" '^upgrade ca-certificates$'
assert_contains 'ca-certificates の更新は依存する別の部品を巻き込まない' "$case_dir/brew.log" '^deps-check=1$'
assert_contains 'ca-certificates の更新を自動修復へ出す' "$case_dir/output.txt" 'ca-certificates .*2026-09-25 → 2026-10-20 を自動更新'
assert_not_contains 'ca-certificates の自動更新成功時は更新 WARN を出さない' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新'

case_dir="$TEST_TMP/security-node-manual"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" \
  FAKE_BREW_LOG="$case_dir/brew.log" \
  FAKE_BREW_JSON='{"formulae":[{"name":"ca-certificates","installed_versions":["2026-09-25"],"current_version":"2026-10-20"},{"name":"node","installed_versions":["26.11.1"],"current_version":"26.12.0"}]}'
assert_contains 'ca-certificates と node のうち ca は自動更新する' "$case_dir/output.txt" 'ca-certificates .*を自動更新'
assert_contains 'RH_AUTOFIX_SECURITY=0 では node を WARN にする' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新が出ています: node 26\.11\.1 → 26\.12\.0'

case_dir="$TEST_TMP/security-node-auto"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" \
  FAKE_BREW_LOG="$case_dir/brew.log" RH_AUTOFIX_SECURITY=1 \
  FAKE_BREW_JSON='{"formulae":[{"name":"ca-certificates","installed_versions":["2026-09-25"],"current_version":"2026-10-20"},{"name":"node","installed_versions":["26.11.1"],"current_version":"26.12.0"}]}'
assert_contains 'RH_AUTOFIX_SECURITY=1 では node も brew upgrade する' "$case_dir/brew.log" '^upgrade node$'
assert_contains 'node の更新を自動修復へ出す' "$case_dir/output.txt" 'node .*26\.11\.1 → 26\.12\.0 を自動更新'
assert_not_contains 'node の自動更新成功時は更新 WARN を出さない' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新'

case_dir="$TEST_TMP/php-warn"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_php "$fake_bin"
make_fake_lsof "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_PHP_VERSION=8.5.11
assert_contains '待ち受けなしの PHP 8.5.11 は WARN' "$case_dir/output.txt" 'WARN  PHP 8\.5\.11（.*fake-bin/php）.*8\.5\.12'
assert_contains 'PHP の WARN に CVE を残す' "$case_dir/output.txt" 'CVE-2026-109618 / CVE-2026-109619'

case_dir="$TEST_TMP/php-fail"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_php "$fake_bin"
make_fake_lsof "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_PHP_VERSION=8.5.11 FAKE_PHP_LISTEN=1
assert_contains '待ち受け中の PHP 8.5.11 は FAIL' "$case_dir/output.txt" 'FAIL  PHP 8\.5\.11（.*fake-bin/php）がサーバーとして動いています'

case_dir="$TEST_TMP/php-httpd-nophp"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_php "$fake_bin"
make_fake_lsof "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_PHP_VERSION=8.5.11 FAKE_HTTPD_LISTEN=1
assert_contains 'PHP を読み込まない httpd の待ち受けでは WARN のまま' "$case_dir/output.txt" 'WARN  PHP 8\.5\.11（.*fake-bin/php）'
assert_not_contains 'PHP を読み込まない httpd の待ち受けでは FAIL にしない' "$case_dir/output.txt" 'FAIL  PHP 8\.5\.11'

case_dir="$TEST_TMP/php-httpd-modphp"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_php "$fake_bin"
make_fake_lsof "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_PHP_VERSION=8.5.11 FAKE_HTTPD_LISTEN=1 FAKE_HTTPD_PHP=1
assert_contains 'mod_php を読み込んだ httpd の待ち受けは FAIL' "$case_dir/output.txt" 'FAIL  PHP 8\.5\.11（.*fake-bin/php）がサーバーとして動いています'

case_dir="$TEST_TMP/php-same-keg"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_lsof "$fake_bin"
mkdir -p "$case_dir/Cellar/php/8.5.11_1/bin" "$case_dir/Cellar/php/8.5.11_1/sbin"
make_fake_php "$case_dir/Cellar/php/8.5.11_1/bin"
cp "$case_dir/Cellar/php/8.5.11_1/bin/php" "$case_dir/Cellar/php/8.5.11_1/sbin/php-fpm"
ln -s "$case_dir/Cellar/php/8.5.11_1/bin/php" "$fake_bin/php"
ln -s "$case_dir/Cellar/php/8.5.11_1/sbin/php-fpm" "$fake_bin/php-fpm"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_PHP_VERSION=8.5.11
if [ "$(LC_ALL=C grep -cE 'WARN  PHP 8\.5\.11（.*php-same-keg/' "$case_dir/output.txt")" = "1" ]; then pass '同じ keg の php と php-fpm は WARN 1件にまとめる'; else fail '同じ keg の php と php-fpm は WARN 1件にまとめる'; sed -n '1,40p' "$case_dir/output.txt"; fi

case_dir="$TEST_TMP/php-fixed"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_php "$fake_bin"
make_fake_lsof "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_PHP_VERSION=8.5.12
assert_not_contains 'PHP 8.5.12 は要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  PHP 8\.5\.12（.*fake-bin/php）'

case_dir="$TEST_TMP/php-eol"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_php "$fake_bin"
make_fake_lsof "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_PHP_VERSION=8.1.30
assert_contains 'PHP 8.1 はサポート終了の WARN' "$case_dir/output.txt" 'WARN  PHP 8\.1\.30（.*fake-bin/php）はサポート終了'

case_dir="$TEST_TMP/node-26-old"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_node "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" \
  RH_NODE_CANDIDATES="$fake_bin/node" FAKE_NODE_VERSION=26.12.0
assert_contains 'Node 26.12.0 は修正版 26.12.1 より古い WARN' "$case_dir/output.txt" 'WARN  Node 26\.12\.0（.*fake-bin/node）.*修正版 26\.12\.1'
assert_contains 'Node 26.12.0 の WARN に CVE を含める' "$case_dir/output.txt" 'Node 26\.12\.0.*CVE-2026-105482'

case_dir="$TEST_TMP/node-26-fixed"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_node "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" \
  RH_NODE_CANDIDATES="$fake_bin/node" FAKE_NODE_VERSION=26.12.1
assert_not_contains 'Node 26.12.1 は要対応に出さない' "$case_dir/output.txt" 'WARN  Node 26\.12\.1（.*fake-bin/node）'

case_dir="$TEST_TMP/node-24-old"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_node "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" \
  RH_NODE_CANDIDATES="$fake_bin/node" FAKE_NODE_VERSION=24.22.0
assert_contains 'Node 24.22.0 は修正版 24.22.1 より古い WARN' "$case_dir/output.txt" 'WARN  Node 24\.22\.0（.*fake-bin/node）.*修正版 24\.22\.1'

case_dir="$TEST_TMP/node-25-eol"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_node "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" \
  RH_NODE_CANDIDATES="$fake_bin/node" FAKE_NODE_VERSION=25.9.0
assert_contains 'Node 25 はサポート終了の WARN' "$case_dir/output.txt" 'WARN  Node 25\.9\.0（.*fake-bin/node）はサポート終了'

case_dir="$TEST_TMP/node-20-eol"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_node "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" \
  RH_NODE_CANDIDATES="$fake_bin/node" FAKE_NODE_VERSION=20.19.0
assert_contains 'Node 20 は EOL 閾値によるサポート終了の WARN' "$case_dir/output.txt" 'WARN  Node 20\.19\.0（.*fake-bin/node）はサポート終了'

case_dir="$TEST_TMP/node-cellar"
fake_bin="$case_dir/fake-bin"
cellar_bin="$case_dir/Cellar/node@24/24.22.0/bin"
make_fake_brew "$fake_bin"
make_fake_node "$cellar_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" \
  RH_NODE_CANDIDATES="$cellar_bin/node" FAKE_NODE_VERSION=24.22.0
assert_contains 'Homebrew の Node は formula 名つきの直し方を出す' "$case_dir/output.txt" 'brew upgrade node@24（Homebrew に修正版が出しだい）'

case_dir="$TEST_TMP/node-unknown"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_node "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" \
  RH_NODE_CANDIDATES="$fake_bin/node" FAKE_NODE_VERSION=
assert_contains '版を返さない Node は未検査の NOTES' "$case_dir/output.txt" 'node（.*fake-bin/node）— 版を判定できず未検査'

case_dir="$TEST_TMP/java-21-old"
fake_bin="$case_dir/fake-bin"
java_home="$case_dir/jdk-21-old/Contents/Home"
make_fake_brew "$fake_bin"
make_fake_java_home "$java_home" 21.0.12
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_JAVA_CANDIDATES="$java_home"
assert_contains 'Java 21.0.12 は修正版 21.0.13 より古い WARN' "$case_dir/output.txt" 'WARN  Java 21\.0\.12（.*jdk-21-old/Contents/Home）.*修正版 21\.0\.13'
assert_contains 'Java の WARN に Oracle 10月定例更新の理由を含める' "$case_dir/output.txt" 'Java 21\.0\.12.*Oracle 2026年10月の定例更新（Java SE 55件）'

case_dir="$TEST_TMP/java-21-fixed"
fake_bin="$case_dir/fake-bin"
java_home="$case_dir/jdk-21-fixed/Contents/Home"
make_fake_brew "$fake_bin"
make_fake_java_home "$java_home" 21.0.13
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_JAVA_CANDIDATES="$java_home"
assert_not_contains 'Java 21.0.13 は要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  Java 21\.0\.13（'

case_dir="$TEST_TMP/java-11-four-parts"
fake_bin="$case_dir/fake-bin"
java_home="$case_dir/jdk-11-old/Contents/Home"
make_fake_brew "$fake_bin"
make_fake_java_home "$java_home" 11.0.32.1
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_JAVA_CANDIDATES="$java_home"
assert_contains 'Java 11.0.32.1 は4桁で比較して WARN' "$case_dir/output.txt" 'WARN  Java 11\.0\.32\.1（.*）.*修正版 11\.0\.33'

case_dir="$TEST_TMP/java-8"
fake_bin="$case_dir/fake-bin"
java_old="$case_dir/jdk-8-old/Contents/Home"
java_fixed="$case_dir/jdk-8-fixed/Contents/Home"
make_fake_brew "$fake_bin"
make_fake_java_home "$java_old" 1.8.0_504
make_fake_java_home "$java_fixed" 1.8.0_511
: > "$case_dir/brew.log"
run_security "$case_dir/old" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_JAVA_CANDIDATES="$java_old"
assert_contains 'Java 1.8.0_504 は 8u504 と表示して WARN' "$case_dir/old/output.txt" 'WARN  Java 8u504（.*）.*修正版 8\.0\.511'
run_security "$case_dir/fixed" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_JAVA_CANDIDATES="$java_fixed"
assert_not_contains 'Java 8u511 は要対応に出さない' "$case_dir/fixed/output.txt" '(WARN|FAIL)  Java 8u511（'

case_dir="$TEST_TMP/java-eol"
fake_bin="$case_dir/fake-bin"
java_home="$case_dir/jdk-24/Contents/Home"
make_fake_brew "$fake_bin"
make_fake_java_home "$java_home" 24.0.2
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_JAVA_CANDIDATES="$java_home"
assert_contains 'Java 24 は * 行でサポート終了の WARN' "$case_dir/output.txt" 'WARN  Java 24\.0\.2（.*）はサポート終了の系列'

case_dir="$TEST_TMP/java-no-release"
fake_bin="$case_dir/fake-bin"
java_home="$case_dir/jdk-no-release/Contents/Home"
make_fake_brew "$fake_bin"
mkdir -p "$java_home"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_JAVA_CANDIDATES="$java_home"
assert_contains 'release の無い Java は未検査の NOTES' "$case_dir/output.txt" 'java（.*jdk-no-release/Contents/Home）— 版を判定できず未検査'

case_dir="$TEST_TMP/java-cellar"
fake_bin="$case_dir/fake-bin"
java_home="$case_dir/Cellar/openjdk@21/21.0.12/libexec/openjdk.jdk/Contents/Home"
make_fake_brew "$fake_bin"
make_fake_java_home "$java_home" 21.0.12
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_JAVA_CANDIDATES="$java_home"
assert_contains 'Homebrew の Java は formula 名つきの直し方を出す' "$case_dir/output.txt" 'brew upgrade openjdk@21（Homebrew に修正版が出しだい）'

case_dir="$TEST_TMP/version-four-parts"
fake_bin="$case_dir/fake-bin"
java_old="$case_dir/jdk-old/Contents/Home"
java_fixed="$case_dir/jdk-fixed/Contents/Home"
minimums="$case_dir/minimums.tsv"
make_fake_brew "$fake_bin"
make_fake_java_home "$java_old" 11.0.32
make_fake_java_home "$java_fixed" 11.0.32.1
printf 'java\t11\t11.0.32.1\t4桁比較\njava\t*\tEOL\t終了\n' > "$minimums"
: > "$case_dir/brew.log"
run_security "$case_dir/old" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SECURITY_MINIMUMS="$minimums" RH_JAVA_CANDIDATES="$java_old"
assert_contains '11.0.32 は 11.0.32.1 より古い' "$case_dir/old/output.txt" 'WARN  Java 11\.0\.32（.*）.*修正版 11\.0\.32\.1'
run_security "$case_dir/fixed" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SECURITY_MINIMUMS="$minimums" RH_JAVA_CANDIDATES="$java_fixed"
assert_not_contains '11.0.32.1 は同じ4桁の最低版を満たす' "$case_dir/fixed/output.txt" '(WARN|FAIL)  Java 11\.0\.32\.1（'

case_dir="$TEST_TMP/gitlab-docker"
fake_bin="$case_dir/fake-bin"
docker_fake="$fake_bin/docker"
make_fake_brew "$fake_bin"
make_fake_docker "$docker_fake"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_DOCKER="$docker_fake" \
  FAKE_DOCKER_PS='gitlab/gitlab-ce:19.5.0-ce.0\trunning\tlive\nregistry.example/gitlab/gitlab-ee:19.4.2-ee.0\texited\tstopped\ngitlab/gitlab-ce:latest\trunning\tunknown\ngitlab/gitlab-ee:19.5.1-ee.0\trunning\tfixed\ngitlab/gitlab-ce:18.10.8-ce.0\trunning\teol\n' \
  FAKE_DOCKER_IMAGES='gitlab/gitlab-ce:19.5.0-ce.0\nregistry.example/gitlab/gitlab-ee:19.4.2-ee.0\ngitlab/gitlab-ce:latest\ngitlab/gitlab-ee:19.5.1-ee.0\ngitlab/gitlab-ce:18.10.8-ce.0\n'
assert_contains '動いている古い GitLab は FAIL' "$case_dir/output.txt" 'FAIL  GitLab 19\.5\.0（gitlab/gitlab-ce:19\.5\.0-ce\.0）が動いています'
assert_contains '止まっている古い GitLab は WARN' "$case_dir/output.txt" 'WARN  GitLab 19\.4\.2（registry\.example/gitlab/gitlab-ee:19\.4\.2-ee\.0）は修正版 19\.4\.3 より古い'
assert_contains '動いている latest の GitLab は版不明の WARN' "$case_dir/output.txt" 'WARN  GitLab（gitlab/gitlab-ce:latest）は動いていますが版を判定できません'
assert_not_contains '修正版以上の GitLab は要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  GitLab 19\.5\.1（gitlab/gitlab-ee:19\.5\.1-ee\.0）'
assert_contains '動いている修正版なしの古い GitLab 系列は FAIL' "$case_dir/output.txt" 'FAIL  GitLab 18\.10\.8（gitlab/gitlab-ce:18\.10\.8-ce\.0）が動いています。サポート終了の系列'

case_dir="$TEST_TMP/gitlab-docker-info-fail"
fake_bin="$case_dir/fake-bin"
docker_fake="$fake_bin/docker"
make_fake_brew "$fake_bin"
make_fake_docker "$docker_fake"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_DOCKER="$docker_fake" FAKE_DOCKER_INFO_RC=1 \
  FAKE_DOCKER_PS='gitlab/gitlab-ce:19.5.0-ce.0\trunning\tlive\n'
assert_not_contains 'docker info 失敗時は GitLab の出力をしない' "$case_dir/output.txt" 'GitLab'

case_dir="$TEST_TMP/gitlab-docker-absent"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log"
assert_not_contains 'docker が無い時は GitLab の出力をしない' "$case_dir/output.txt" 'GitLab'

case_dir="$TEST_TMP/tls-node"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_exit_command "$fake_bin/apple-curl" 60
make_exit_command "$fake_bin/node" 0
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_TLS_PROBE=1 \
  RH_PROBE_APPLE_CURL="$fake_bin/apple-curl" RH_PROBE_APPLE_PYTHON="$fake_bin/missing-apple-python" \
  RH_PROBE_BREW_CURL="$fake_bin/missing-brew-curl" RH_PROBE_NODE="$fake_bin/node" RH_PROBE_PYTHON="$fake_bin/missing-python"
assert_contains '接続できる Node は TLS の WARN' "$case_dir/output.txt" 'WARN  Node が失効済みの証明書を信頼しています'
assert_contains 'TLS の WARN は tls-probes.tsv の件名を使う' "$case_dir/output.txt" '信頼しています（eMudhra 中間CAの鍵漏洩（2026-10-20 公表））'

case_dir="$TEST_TMP/tls-apple"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_exit_command "$fake_bin/apple-curl" 0
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_TLS_PROBE=1 \
  RH_PROBE_APPLE_CURL="$fake_bin/apple-curl" RH_PROBE_APPLE_PYTHON="$fake_bin/missing-apple-python" \
  RH_PROBE_BREW_CURL="$fake_bin/missing-brew-curl" RH_PROBE_NODE="$fake_bin/missing-node" RH_PROBE_PYTHON="$fake_bin/missing-python"
assert_contains '接続できる Apple curl は NOTES' "$case_dir/output.txt" 'Apple の curl は失効済みの証明書をまだ信頼しています'
assert_not_contains '接続できる Apple curl は WARN にしない' "$case_dir/output.txt" 'WARN  Apple の curl'

case_dir="$TEST_TMP/tls-reject"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_exit_command "$fake_bin/apple-curl" 60
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_TLS_PROBE=1 \
  RH_PROBE_APPLE_CURL="$fake_bin/apple-curl" RH_PROBE_APPLE_PYTHON="$fake_bin/missing-apple-python" \
  RH_PROBE_BREW_CURL="$fake_bin/missing-brew-curl" RH_PROBE_NODE="$fake_bin/missing-node" RH_PROBE_PYTHON="$fake_bin/missing-python"
assert_contains 'TLS 拒否は正常として detail に残す' "$case_dir/output.txt" 'Apple の curl — 失効済みの証明書を拒否（正常）'
assert_not_contains 'TLS 拒否時は信頼中と報告しない' "$case_dir/output.txt" 'Apple の curl は失効済みの証明書をまだ信頼'

case_dir="$TEST_TMP/tls-unknown"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_exit_command "$fake_bin/apple-curl" 6
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_TLS_PROBE=1 \
  RH_PROBE_APPLE_CURL="$fake_bin/apple-curl" RH_PROBE_APPLE_PYTHON="$fake_bin/missing-apple-python" \
  RH_PROBE_BREW_CURL="$fake_bin/missing-brew-curl" RH_PROBE_NODE="$fake_bin/missing-node" RH_PROBE_PYTHON="$fake_bin/missing-python"
assert_contains 'TLS の接続不能は未検査の NOTES' "$case_dir/output.txt" 'Apple の curl — 証明書の点検は接続できず未検査'

case_dir="$TEST_TMP/software-macos"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'printf "    * Label: %s\n" "${FAKE_UPDATE_LABEL:?}"'
} > "$fake_bin/softwareupdate"
chmod +x "$fake_bin/softwareupdate"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWAREUPDATE=0 FAKE_UPDATE_LABEL='macOS Tahoe 27.0.2'
assert_contains 'macOS の更新は WARN' "$case_dir/output.txt" 'WARN  macOS のアップデートが出ています: macOS Tahoe 27\.0\.2'

case_dir="$TEST_TMP/software-clt"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'printf "    * Label: %s\n" "${FAKE_UPDATE_LABEL:?}"'
} > "$fake_bin/softwareupdate"
chmod +x "$fake_bin/softwareupdate"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWAREUPDATE=0 FAKE_UPDATE_LABEL='Command Line Tools for Xcode 27.0'
assert_not_contains 'Command Line Tools だけなら macOS 更新 WARN は出さない' "$case_dir/output.txt" 'WARN  macOS のアップデートが出ています'
assert_contains 'Command Line Tools は detail に残す' "$case_dir/output.txt" 'その他のアップデート: Command Line Tools for Xcode 27\.0'

case_dir="$TEST_TMP/kit-disabled"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'printf "called\n" >> "${FAKE_CURL_LOG:?}"'
  printf '%s\n' 'printf "0.9.0\n"'
} > "$fake_bin/curl"
chmod +x "$fake_bin/curl"
: > "$case_dir/brew.log"
: > "$case_dir/curl.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_CURL_LOG="$case_dir/curl.log" RH_KIT_UPDATE_CHECK=0
if [ ! -s "$case_dir/curl.log" ]; then pass 'RH_KIT_UPDATE_CHECK=0 は curl を呼ばない'; else fail 'RH_KIT_UPDATE_CHECK=0 は curl を呼ばない'; fi

case_dir="$TEST_TMP/kit-newer"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'printf "called\n" >> "${FAKE_CURL_LOG:?}"'
  printf '%s\n' 'printf "0.9.0\n"'
} > "$fake_bin/curl"
chmod +x "$fake_bin/curl"
: > "$case_dir/brew.log"
: > "$case_dir/curl.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_CURL_LOG="$case_dir/curl.log" RH_KIT_UPDATE_CHECK=1
assert_contains 'kit の新しい版は WARN' "$case_dir/output.txt" 'WARN  repo-health-kit の新しい版 0\.4\.0 → 0\.9\.0 があります'

case_dir="$TEST_TMP/composer"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" composerrepo
printf '%s\n' '{"packages":[]}' > "$REPO_PATH/composer.lock"
composer_fake="$case_dir/composer"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'printf "%s\n" '\''{"advisories":{"vendor/package":[{"severity":"high"}]}}'\'''
  printf '%s\n' 'exit 1'
} > "$composer_fake"
chmod +x "$composer_fake"
run_composer "$case_dir/high" "$case_dir/root with space" "$composer_fake"
assert_contains 'composer の high 1件は FAIL' "$case_dir/high/output.txt" 'FAIL  composerrepo — 本番依存に critical/high 脆弱性（composer）'
run_composer "$case_dir/absent" "$case_dir/root with space" ''
assert_contains 'composer 不在は WARN' "$case_dir/absent/output.txt" 'WARN  composerrepo — composer audit 実行不能（composer 不在）'

if [ "$failed" -gt 0 ]; then
  printf '# %s/%s tests failed\n' "$failed" "$total"
  exit 1
fi
printf '# all %s tests passed\n' "$total"
