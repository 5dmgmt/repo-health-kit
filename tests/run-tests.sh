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

assert_count() {
  local description="$1" file="$2" pattern="$3" expected="$4" actual
  actual="$(LC_ALL=C grep -cE "$pattern" "$file" || true)"
  if [ "$actual" = "$expected" ]; then pass "$description"; else fail "$description"; sed -n '1,160p' "$file"; fi
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
    RH_MACOS_VERSION=27.0.1 RH_CLAUDE_CANDIDATES= RH_APP_DIRS= RH_BREW="$fake_bin/brew" \
    RH_PYTHON_SITE_DIRS= RH_UV_CANDIDATES= \
    "$@" bash "$HEALTH" > "$output" 2>&1 || true
}

run_security_only() {
  local case_dir="$1" root="$2" output
  shift 2
  output="$case_dir/output.txt"
  mkdir -p "$case_dir/home" "$root"
  env HOME="$case_dir/home" \
    RH_CONFIG_FILE="$case_dir/no-config.sh" RH_ROOTS="$root" \
    RH_LOG_DIR="$case_dir/log" RH_STATE_DIR="$case_dir/state" \
    RH_SECURITY_ONLY=1 RH_SKIP_SECURITY=1 RH_SKIP_CLI=0 RH_SKIP_FETCH=0 \
    RH_AUTOFIX_PULL=1 RH_MAIL_METHOD=none RH_NOMAIL=1 RH_NO_DESKTOP=1 \
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
    printf '%s\n' '  list) printf "%b" "${FAKE_BREW_VERSIONS-}" | while IFS= read -r line; do case "$line" in "$3 "*) printf "%s\n" "$line";; esac; done ;;'
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

make_python_site() {
  local site="$1" pip_version="$2" certifi_version="$3"
  mkdir -p "$site/pip" "$site/certifi"
  printf '__version__ = "%s"\n' "$pip_version" > "$site/pip/__init__.py"
  printf '__version__ = "%s"\n' "$certifi_version" > "$site/certifi/__init__.py"
}

make_fake_uv() {
  local path="$1" version="$2"
  mkdir -p "${path%/*}"
  {
    printf '%s\n' '#!/bin/bash'
    printf 'printf "uv %s\\n"\n' "$version"
  } > "$path"
  chmod +x "$path"
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
  mkdir -p "${path%/*}"
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

printf '1..192\n'

case_dir="$TEST_TMP/clean"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" '見本 リポ'
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'clean なリポは要対応0件' "$case_dir/output.txt" '要対応: FAIL 0件 / WARN 0件'

case_dir="$TEST_TMP/non-git"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" gitrepo
mkdir -p "$case_dir/root with space/素材フォルダ" "$case_dir/root with space/empty-dir" "$case_dir/root with space/.hidden"
printf 'memo\n' > "$case_dir/root with space/素材フォルダ/memo.txt"
printf 'x\n' > "$case_dir/root with space/.hidden/x"
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'git 管理外のフォルダは WARN' "$case_dir/output.txt" 'WARN  素材フォルダ — git 管理外のフォルダです'
assert_contains '空のフォルダは参考' "$case_dir/output.txt" 'empty-dir — 空のフォルダ'
assert_not_contains '隠しフォルダは対象外' "$case_dir/output.txt" '\.hidden'
RH_WARN_NONGIT=0 run_health "$case_dir" "$case_dir/root with space"
assert_not_contains 'RH_WARN_NONGIT=0 なら知らせない' "$case_dir/output.txt" 'git 管理外のフォルダ'

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
  && [ -f "$case_dir/home/Library/Application Support/repo-health-kit/config/python-pins.tsv" ] \
  && [ -f "$case_dir/home/Library/Application Support/repo-health-kit/config/tls-probes.tsv" ] \
  && [ -f "$case_dir/home/Library/Application Support/repo-health-kit/config/actions-denylist.tsv" ]; then
  installed_assets=1
fi
HOME="$case_dir/home" RH_NO_LAUNCHCTL=1 bash "$PROJECT_DIR/uninstall.sh" > "$case_dir/uninstall-output.txt" 2>&1
uninstall_rc=$?
if [ "$install_rc" -eq 0 ] && [ "$uninstall_rc" -eq 0 ] \
  && [ ! -e "$case_dir/home/Library/LaunchAgents/com.repo-health-kit.plist" ] \
  && [ ! -e "$case_dir/home/Library/Application Support/repo-health-kit/config/python-pins.tsv" ]; then
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

case_dir="$TEST_TMP/python-venv-old"
fake_bin="$case_dir/fake-bin"
repo="$case_dir/root/fixture"
venv="$repo/.venv"
site="$venv/lib/python3.14/site-packages"
marker="$case_dir/python-executed"
make_fake_brew "$fake_bin"
mkdir -p "$repo/.git" "$venv/bin"
printf 'home = /fixture\n' > "$venv/pyvenv.cfg"
make_python_site "$site" 26.2.1 2026.7.22
{
  printf '%s\n' '#!/bin/bash'
  printf 'printf executed > "%s"\n' "$marker"
} > "$venv/bin/python"
chmod +x "$venv/bin/python"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log"
assert_count '同じ venv の古い pip と certifi は WARN 1件にまとめる' "$case_dir/output.txt" 'WARN  Python（fixture/\.venv）' 1
assert_contains 'venv の WARN はその venv の python を案内する' "$case_dir/output.txt" "$venv/bin/python"
assert_contains 'venv の WARN は sha256 付き pip URL を案内する' "$case_dir/output.txt" 'pip-26\.2\.2-py3-none-any\.whl#sha256=fd7f4dfa8190e014013b9f08f3e973f4e4c26ffd179a204895533a7254813a70'
assert_contains 'venv の WARN は sha256 付き certifi URL を案内する' "$case_dir/output.txt" 'certifi-2026\.10\.19-py3-none-any\.whl#sha256=42d35340cc5b9ba78e818ddbff0c5b1c2b779de448a340fd1b989f5fa8670e1b'
if [ ! -e "$marker" ]; then pass '点検対象の venv の python は実行しない'; else fail '点検対象の venv の python は実行しない'; fi

case_dir="$TEST_TMP/python-venv-fixed"
fake_bin="$case_dir/fake-bin"
repo="$case_dir/root/fixture"
venv="$repo/.venv"
site="$venv/lib/python3.14/site-packages"
make_fake_brew "$fake_bin"
mkdir -p "$repo/.git" "$venv/bin"
printf 'home = /fixture\n' > "$venv/pyvenv.cfg"
make_python_site "$site" 26.2.2 2026.10.19
make_exit_command "$venv/bin/python" 0
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log"
assert_not_contains '修正版の venv は Python の WARN を出さない' "$case_dir/output.txt" '^WARN  Python（fixture/\.venv）'
assert_contains '修正版の pip は最低版以上の detail を出す' "$case_dir/output.txt" 'Python（fixture/\.venv）の pip 26\.2\.2 — 最低版 26\.2\.2 以上'

case_dir="$TEST_TMP/python-dist-info-remnant"
fake_bin="$case_dir/fake-bin"
site="$case_dir/Library/Python/3.14/lib/python/site-packages"
python="$case_dir/python3.14"
make_fake_brew "$fake_bin"
make_python_site "$site" 26.2.2 2026.10.19
mkdir -p "$site/certifi-2026.2.25.dist-info"
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'user\t%s\t%s' "$site" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" \
  RH_PYTHON_SITE_DIRS="$python_sites"
assert_not_contains '古い certifi dist-info の残骸では WARN にしない' "$case_dir/output.txt" '^WARN  Python（.*python-dist-info-remnant'

case_dir="$TEST_TMP/python-user-39"
fake_bin="$case_dir/fake-bin"
site="$case_dir/home/Library/Python/3.9/lib/python/site-packages"
python="$case_dir/python3"
make_fake_brew "$fake_bin"
make_python_site "$site" 21.2.4 2026.1.4
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'user\t%s\t%s' "$site" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_contains 'Python 3.9 の古い pip は更新不能の NOTES' "$case_dir/output.txt" 'Python 3\.9（.*）の pip 21\.2\.4 は修正版 26\.2\.2 を入れられません（Python 3\.10 以上が必要）'
assert_contains 'user site の古い certifi は --user 付きの WARN' "$case_dir/output.txt" 'WARN  Python（.*）の certifi 2026\.1\.4.*-m pip install --user "certifi @'

case_dir="$TEST_TMP/python-apple"
fake_bin="$case_dir/fake-bin"
site="$case_dir/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/lib/python3.9/site-packages"
make_fake_brew "$fake_bin"
make_python_site "$site" 21.2.4 2026.1.4
: > "$case_dir/brew.log"
python_sites="$(printf 'apple\t%s\t/usr/bin/python3' "$site")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_not_contains 'Apple 管理の Python は WARN にしない' "$case_dir/output.txt" '^WARN  (Python|Apple)'
assert_count 'Apple 管理の Python は場所ごとに NOTES 1件' "$case_dir/output.txt" 'Apple の python3（.*）の pip 21\.2\.4 は古い版です' 1

case_dir="$TEST_TMP/python-certifi-formula"
fake_bin="$case_dir/fake-bin"
keg_site="$case_dir/Cellar/certifi/2026.2.25/lib/python3.14/site-packages"
site13="$case_dir/homebrew/lib/python3.13/site-packages"
site14="$case_dir/homebrew/lib/python3.14/site-packages"
python="$case_dir/homebrew/bin/python3.14"
make_fake_brew "$fake_bin"
mkdir -p "$keg_site/certifi" "$site13" "$site14/certifi" "${python%/*}"
printf '__version__ = "2026.2.25"\n' > "$keg_site/certifi/__init__.py"
# 3.13 はフォルダーごと、3.14 は実機の Homebrew と同じく中のファイルごとに symlink
ln -s "$keg_site/certifi" "$site13/certifi"
ln -s "$keg_site/certifi/__init__.py" "$site14/certifi/__init__.py"
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'brew\t%s\t%s\nbrew\t%s\t%s' "$site13" "$python" "$site14" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_count 'Homebrew certifi formula は keg ごとに WARN 1件' "$case_dir/output.txt" 'WARN  Python（.*）の certifi 2026\.2\.25' 1
assert_contains 'Homebrew certifi formula は brew upgrade certifi を案内する' "$case_dir/output.txt" '直し方: brew upgrade certifi'

case_dir="$TEST_TMP/python-pins-missing"
fake_bin="$case_dir/fake-bin"
site="$case_dir/lib/python3.14/site-packages"
python="$case_dir/bin/python"
make_fake_brew "$fake_bin"
make_python_site "$site" 26.2.1 2026.7.22
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'venv\t%s\t%s' "$site" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" \
  RH_PYTHON_SITE_DIRS="$python_sites" RH_PYTHON_PINS="$case_dir/missing-python-pins.tsv"
assert_contains 'pins 表が無いときは通常更新と sha256 の注意を案内する' "$case_dir/output.txt" 'pip install --upgrade pip certifi（Python 公式の告知にある sha256 付きの入れ方が安全です）'

case_dir="$TEST_TMP/python-site-uv"
fake_bin="$case_dir/fake-bin"
site="$case_dir/lib/python3.14/site-packages"
python="$case_dir/bin/python"
make_fake_brew "$fake_bin"
mkdir -p "$site/uv-0.13.3.dist-info"
printf 'Metadata-Version: 2.4\nVersion: 0.13.3\n' > "$site/uv-0.13.3.dist-info/METADATA"
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'venv\t%s\t%s' "$site" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_contains 'site-packages の古い uv は pip を先に直す WARN' "$case_dir/output.txt" 'WARN  Python（.*）の uv 0\.13\.3 は修正版 0\.13\.4 より古い版です.*pip を先に直してから'

case_dir="$TEST_TMP/uv-local-old"
fake_bin="$case_dir/fake-bin"
uv_path="$case_dir/home/.local/bin/uv"
make_fake_brew "$fake_bin"
make_fake_uv "$uv_path" 0.13.3
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_UV_CANDIDATES="$uv_path"
assert_contains '古い user uv は uv self update を案内する' "$case_dir/output.txt" 'WARN  uv 0\.13\.3（.*\.local/bin/uv）は修正版 0\.13\.4 より古い版です.*uv self update'

case_dir="$TEST_TMP/uv-local-fixed"
fake_bin="$case_dir/fake-bin"
uv_path="$case_dir/home/.local/bin/uv"
make_fake_brew "$fake_bin"
make_fake_uv "$uv_path" 0.13.5
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_UV_CANDIDATES="$uv_path"
assert_not_contains '修正版以上の uv CLI は WARN を出さない' "$case_dir/output.txt" '^WARN  uv '

case_dir="$TEST_TMP/uv-cellar-old"
fake_bin="$case_dir/fake-bin"
uv_path="$case_dir/Cellar/uv/0.13.3/bin/uv"
make_fake_brew "$fake_bin"
make_fake_uv "$uv_path" 0.13.3
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_UV_CANDIDATES="$uv_path"
assert_contains 'Homebrew の古い uv は brew upgrade uv を案内する' "$case_dir/output.txt" 'WARN  uv 0\.13\.3（.*）は修正版 0\.13\.4 より古い版です.*brew upgrade uv'

case_dir="$TEST_TMP/uv-venv-old"
fake_bin="$case_dir/fake-bin"
uv_path="$case_dir/tool-venv/bin/uv"
make_fake_brew "$fake_bin"
make_fake_uv "$uv_path" 0.13.3
printf 'home = /fixture\n' > "$case_dir/tool-venv/pyvenv.cfg"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_UV_CANDIDATES="$uv_path"
assert_not_contains 'venv の uv CLI は二重 WARN を出さない' "$case_dir/output.txt" '^WARN  uv '

case_dir="$TEST_TMP/uv-unknown"
fake_bin="$case_dir/fake-bin"
uv_path="$case_dir/bin/uv"
make_fake_brew "$fake_bin"
make_fake_uv "$uv_path" unknown
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_UV_CANDIDATES="$uv_path"
assert_contains '版を返さない uv は未検査の NOTES' "$case_dir/output.txt" 'uv（.*bin/uv）— 版を判定できず未検査'

case_dir="$TEST_TMP/python-minimums-missing"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SECURITY_MINIMUMS="$case_dir/missing-minimums.tsv"
assert_contains '最低版表が無いときは Python 点検不足の NOTES' "$case_dir/output.txt" 'Python の pip・certifi の最低版は同梱リスト不足のため未検査'

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
assert_contains 'kit の新しい版は WARN' "$case_dir/output.txt" 'WARN  repo-health-kit の新しい版 0\.4\.3 → 0\.9\.0 があります'

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

# ---- 0.4.0 後半: macOS・Claude Code・アプリ・Homebrew の formula ----

run_macos_case() {
  local name="$1" version="$2" case_dir fake_bin
  case_dir="$TEST_TMP/$name"
  fake_bin="$case_dir/fake-bin"
  make_fake_brew "$fake_bin"
  : > "$case_dir/brew.log"
  run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_MACOS_VERSION="$version"
}

run_macos_case macos-15-old 15.8.0
assert_contains 'macOS 15.8.0 は修正版 15.8.1 より古い WARN' "$TEST_TMP/macos-15-old/output.txt" 'WARN  macOS 15\.8\.0 は修正版 15\.8\.1 より古い版です（CVE-2026-86950'
assert_contains 'macOS の WARN にソフトウェアアップデートの案内を含める' "$TEST_TMP/macos-15-old/output.txt" 'macOS 15\.8\.0 .*ソフトウェアアップデートで更新してください'

run_macos_case macos-15-fixed 15.8.1
assert_not_contains 'macOS 15.8.1 は要対応に出さない' "$TEST_TMP/macos-15-fixed/output.txt" '(WARN|FAIL)  macOS '

run_macos_case macos-26-old 26.7.0
assert_contains 'macOS 26.7.0 は修正版 26.7.1 より古い WARN' "$TEST_TMP/macos-26-old/output.txt" 'WARN  macOS 26\.7\.0 は修正版 26\.7\.1 より古い版です'

run_macos_case macos-14-eol 14.7
assert_contains 'macOS 14.7 は修正版が出ていない系列の WARN' "$TEST_TMP/macos-14-eol/output.txt" 'WARN  macOS 14\.7 はサポート終了の系列です.*この系列には修正版が出ていません。新しい macOS へ更新してください'

run_macos_case macos-27 27.0.1
assert_not_contains 'macOS 27.0.1 は表に無い系列で要対応に出さない' "$TEST_TMP/macos-27/output.txt" '(WARN|FAIL)  macOS '
assert_contains 'macOS 27.0.1 は detail に残す' "$TEST_TMP/macos-27/output.txt" 'macOS 27\.0\.1 — この系列は最低版リストに未掲載'

run_macos_case macos-unknown ''
assert_contains '版を返さない macOS は未検査の NOTES' "$TEST_TMP/macos-unknown/output.txt" 'macOS — 版を判定できず未検査'

make_fake_claude() {
  local path="$1"
  mkdir -p "$(dirname -- "$path")"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'printf "%s\n" "${FAKE_CLAUDE_OUTPUT-}"'
  } > "$path"
  chmod +x "$path"
}

case_dir="$TEST_TMP/claude-old"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_claude "$fake_bin/claude"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_CLAUDE_CANDIDATES="$fake_bin/claude" FAKE_CLAUDE_OUTPUT='2.1.259 (Claude Code)'
assert_contains 'Claude Code 2.1.259 は修正版 2.1.260 より古い WARN' "$case_dir/output.txt" 'WARN  Claude Code 2\.1\.259（.*fake-bin/claude）は修正版 2\.1\.260 より古い版です（GHSA-gfvf-j8jh-jxxw'
assert_contains 'Claude Code の WARN に claude update の案内を含める' "$case_dir/output.txt" 'claude update で更新してください'

case_dir="$TEST_TMP/claude-fixed"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_claude "$fake_bin/claude"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_CLAUDE_CANDIDATES="$fake_bin/claude" FAKE_CLAUDE_OUTPUT='2.1.260 (Claude Code)'
assert_not_contains 'Claude Code 2.1.260 は要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  Claude Code '

case_dir="$TEST_TMP/claude-unknown"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_claude "$fake_bin/claude"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_CLAUDE_CANDIDATES="$fake_bin/claude" FAKE_CLAUDE_OUTPUT=''
assert_contains '版を返さない Claude Code は未検査の NOTES' "$case_dir/output.txt" 'Claude Code（.*fake-bin/claude）— 版を判定できず未検査'

case_dir="$TEST_TMP/claude-symlink"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_claude "$case_dir/real/claude"
ln -s "$case_dir/real/claude" "$fake_bin/claude"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" \
  RH_CLAUDE_CANDIDATES="$fake_bin/claude
$case_dir/real/claude" FAKE_CLAUDE_OUTPUT='2.1.250 (Claude Code)'
if [ "$(LC_ALL=C grep -c 'WARN  Claude Code 2\.1\.250' "$case_dir/output.txt")" = "1" ]; then pass '同じ実体の Claude Code は WARN 1件にまとめる'; else fail '同じ実体の Claude Code は WARN 1件にまとめる'; sed -n '1,40p' "$case_dir/output.txt"; fi

# CLI の更新確認（メジャー版遅れ）が同じ claude を WARN にしたときは、最低版の点検を detail に落とす
make_fake_cli_set() {
  local dir="$1" tool
  mkdir -p "$dir"
  for tool in codex node gh vercel supabase op; do
    {
      printf '%s\n' '#!/bin/bash'
      printf '%s\n' 'printf "%s\n" "1.0.0"'
    } > "$dir/$tool"
    chmod +x "$dir/$tool"
  done
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'if [ "${1:-}" = "view" ] && [ "${2:-}" = "@anthropic-ai/claude-code" ]; then printf "%s\n" "${FAKE_CLAUDE_LATEST:?}"; else printf "%s\n" "1.0.0"; fi'
  } > "$dir/npm"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'exit 0'
  } > "$dir/curl"
  chmod +x "$dir/npm" "$dir/curl"
}

case_dir="$TEST_TMP/claude-cli-dup"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_cli_set "$fake_bin"
make_fake_claude "$fake_bin/claude"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_CLI=0 \
  RH_CLAUDE_CANDIDATES="$fake_bin/claude" FAKE_CLAUDE_OUTPUT='2.1.250 (Claude Code)' FAKE_CLAUDE_LATEST=3.0.0
assert_contains 'CLI の更新確認はメジャー版遅れを WARN にする' "$case_dir/output.txt" 'WARN  claude — メジャー版が遅れています 2\.1\.250 → 3\.0\.0'
assert_not_contains '同じ claude の最低版の話は 2 度目の WARN にしない' "$case_dir/output.txt" 'WARN  Claude Code 2\.1\.250'
assert_contains '2 度目に出さなかった最低版の話は detail に残す' "$case_dir/output.txt" 'Claude Code 2\.1\.250（.*）は修正版 2\.1\.260 より古い版です.*WARN は 1 件にまとめています'

make_fake_app() {
  local dir="$1" name="$2" bundle="$3" version="$4"
  mkdir -p "$dir/$name.app/Contents"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">' '<dict>'
    printf '<key>CFBundleIdentifier</key>\n<string>%s</string>\n' "$bundle"
    printf '<key>CFBundleShortVersionString</key>\n<string>%s</string>\n' "$version"
    printf '%s\n' '</dict>' '</plist>'
  } > "$dir/$name.app/Contents/Info.plist"
}

make_fake_pgrep() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' '[ "${1:-}" = "-x" ] && [ "${2:-}" = "Plex Media Server" ] && [ "${FAKE_PLEX_RUNNING:-0}" = "1" ]'
  } > "$fake_bin/pgrep"
  chmod +x "$fake_bin/pgrep"
}

case_dir="$TEST_TMP/apps-old"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_app "$apps" 'Google Chrome' com.google.Chrome 156.0.8078.46
make_fake_app "$apps/入れ子" 'Claude' com.anthropic.claudefordesktop 1.15961.9
make_fake_app "$apps" 'Firefox' org.mozilla.firefox 140.4.0
mkdir -p "$apps/Firefox.app/Contents/Resources/defaults/pref"
printf '%s\n' 'pref("app.update.channel", "esr");' > "$apps/Firefox.app/Contents/Resources/defaults/pref/channel-prefs.js"
make_fake_app "$apps" 'Other' com.example.other 0.0.1
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps"
assert_contains 'Chrome 156.0.8078.46 は修正版 156.0.8078.47 より古い WARN' "$case_dir/output.txt" 'WARN  Chrome 156\.0\.8078\.46（.*Google Chrome\.app）は修正版 156\.0\.8078\.47 より古い版です'
assert_contains 'Chrome の WARN に直し方を含める' "$case_dir/output.txt" 'Chrome を再起動すると更新されます（設定 → Chrome について）'
assert_contains '1 段下のフォルダにある Claude Desktop 1.15961.9 も WARN' "$case_dir/output.txt" 'WARN  Claude Desktop 1\.15961\.9（.*入れ子/Claude\.app）は修正版 1\.15962\.0 より古い版です'
assert_contains 'Firefox ESR は比べず NOTES にする' "$case_dir/output.txt" 'Firefox ESR（.*Firefox\.app）— ESR の系列は未検査'
assert_not_contains 'Firefox ESR は WARN にしない' "$case_dir/output.txt" '(WARN|FAIL)  Firefox '
assert_not_contains '表に無いアプリは何も出さない' "$case_dir/output.txt" 'com\.example\.other|Other\.app'

case_dir="$TEST_TMP/apps-fixed"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_app "$apps" 'Google Chrome' com.google.Chrome 156.0.8078.47
make_fake_app "$apps" 'Claude' com.anthropic.claudefordesktop 1.15962.0
make_fake_app "$apps" 'Firefox' org.mozilla.firefox 158.0.1
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps"
assert_not_contains '修正版ちょうどのアプリは要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  (Chrome|Claude Desktop|Firefox) '
assert_contains '修正版以上のアプリは detail に残す' "$case_dir/output.txt" 'com\.google\.Chrome 156\.0\.8078\.47（.*）— 最低版 156\.0\.8078\.47 以上'

case_dir="$TEST_TMP/apps-firefox-old"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_app "$apps" 'Firefox' org.mozilla.firefox 158.0
mkdir -p "$apps/Firefox.app/Contents/Resources/defaults/pref"
printf '%s\n' 'pref("app.update.channel", "release");' > "$apps/Firefox.app/Contents/Resources/defaults/pref/channel-prefs.js"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps"
assert_contains '通常版の Firefox 158.0 は 158.0.1 より古い WARN' "$case_dir/output.txt" 'WARN  Firefox 158\.0（.*Firefox\.app）は修正版 158\.0\.1 より古い版です（MFSA-2026-106'
assert_contains 'Firefox の WARN に直し方を含める' "$case_dir/output.txt" 'メニュー → Firefox について で更新'

case_dir="$TEST_TMP/apps-unknown-remedy"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
minimums="$case_dir/minimums.tsv"
make_fake_brew "$fake_bin"
make_fake_app "$apps" 'Sample' com.example.sample 1.0.0
printf 'app:com.example.sample\t*\t2.0.0\tテスト用\n' > "$minimums"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps" RH_SECURITY_MINIMUMS="$minimums"
assert_contains '名前ごとの案内が無いアプリは汎用の直し方を出す' "$case_dir/output.txt" 'WARN  com\.example\.sample 1\.0\.0（.*Sample\.app）は修正版 2\.0\.0 より古い版です（テスト用）。アプリを最新版へ更新してください'

case_dir="$TEST_TMP/plex-stopped"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_pgrep "$fake_bin"
make_fake_app "$apps" 'Plex Media Server' com.plexapp.plexmediaserver 1.43.2.0
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps" FAKE_PLEX_RUNNING=0
assert_contains '動いていない Plex 1.43.2.0 は WARN' "$case_dir/output.txt" 'WARN  Plex Media Server 1\.43\.2\.0（.*）は修正版 1\.43\.3\.10861 より古い版です（Plex2Shell'
assert_contains 'Plex の WARN に侵害の確認を含める' "$case_dir/output.txt" '侵害されていないかの確認も必要です（Plex の告知）'
assert_not_contains '動いていない Plex は FAIL にしない' "$case_dir/output.txt" 'FAIL  Plex Media Server'

case_dir="$TEST_TMP/plex-running"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_pgrep "$fake_bin"
make_fake_app "$apps" 'Plex Media Server' com.plexapp.plexmediaserver 1.43.2.0
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps" FAKE_PLEX_RUNNING=1
assert_contains '動いている Plex 1.43.2.0 は FAIL' "$case_dir/output.txt" 'FAIL  Plex Media Server 1\.43\.2\.0（.*）が動いています。修正版 1\.43\.3\.10861 より古い版です'

case_dir="$TEST_TMP/plex-fixed"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_pgrep "$fake_bin"
make_fake_app "$apps" 'Plex Media Server' com.plexapp.plexmediaserver 1.43.3.10861
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps" FAKE_PLEX_RUNNING=1
assert_not_contains '修正版の Plex は動いていても要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  Plex Media Server'

case_dir="$TEST_TMP/brew-curl-old"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='curl 8.22.0\nopenssl@3 3.6.5\n'
assert_contains 'Homebrew の curl 8.22.0 は修正版 8.23.0 より古い WARN' "$case_dir/output.txt" 'WARN  Homebrew の curl 8\.22\.0 は修正版 8\.23\.0 より古い版です（CVE-2026-92392.*）。brew upgrade curl'
assert_not_contains '修正版の openssl@3 3.6.5 は要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  Homebrew の openssl@3'

case_dir="$TEST_TMP/brew-bind"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='bind 9.20.29\n'
assert_contains 'Homebrew の bind 9.20.29 は修正版 9.20.30 より古い WARN' "$case_dir/output.txt" 'WARN  Homebrew の bind 9\.20\.29 は修正版 9\.20\.30 より古い版です（CVE-2026-94300.*）。brew upgrade bind'
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='bind 9.20.30\n'
assert_not_contains 'Homebrew の bind 9.20.30 は要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  Homebrew の bind'

case_dir="$TEST_TMP/brew-curl-fixed"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='curl 8.23.0\n'
assert_not_contains 'Homebrew の curl 8.23.0 は要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  Homebrew の curl'
assert_contains '修正版以上の Homebrew の curl は detail に最低版を残す' "$case_dir/output.txt" 'Homebrew の curl 8\.23\.0 — 最低版 8\.23\.0 以上'

case_dir="$TEST_TMP/brew-curl-revision"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='curl 8.22.0_1\n'
assert_contains '修正番号つきの版（8.22.0_1）も比べて WARN にする' "$case_dir/output.txt" 'WARN  Homebrew の curl 8\.22\.0_1 は修正版 8\.23\.0 より古い版です'

case_dir="$TEST_TMP/brew-openssl"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir/a" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='openssl@3 3.6.4\n'
assert_contains 'Homebrew の openssl@3 3.6.4 は修正版 3.6.5 より古い WARN' "$case_dir/a/output.txt" 'WARN  Homebrew の openssl@3 3\.6\.4 は修正版 3\.6\.5 より古い版です（CVE-2026-84782'
run_security "$case_dir/b" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='openssl@3 3.5.8\n'
assert_contains 'Homebrew の openssl@3 3.5.8 は系列ごとの修正版 3.5.9 で比べる' "$case_dir/b/output.txt" 'WARN  Homebrew の openssl@3 3\.5\.8 は修正版 3\.5\.9 より古い版です'
run_security "$case_dir/c" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='openssl@3 3.4.7\n'
assert_contains 'Homebrew の openssl@3 3.4.7 は系列ごとの修正版 3.4.8 で比べる' "$case_dir/c/output.txt" 'WARN  Homebrew の openssl@3 3\.4\.7 は修正版 3\.4\.8 より古い版です'
run_security "$case_dir/d" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='openssl@3 3.5.9\n'
assert_not_contains 'Homebrew の openssl@3 3.5.9 は要対応に出さない' "$case_dir/d/output.txt" '(WARN|FAIL)  Homebrew の openssl@3'
run_security "$case_dir/e" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='openssl@3 3.3.9\n'
assert_not_contains '最低版リストに無い系列（openssl@3 3.3.9）は要対応に出さない' "$case_dir/e/output.txt" '(WARN|FAIL)  Homebrew の openssl@3'
assert_contains '最低版リストに無い系列は detail に未掲載と残す' "$case_dir/e/output.txt" 'Homebrew の openssl@3 3\.3\.9 — この系列は最低版リストに未掲載'

case_dir="$TEST_TMP/brew-no-double"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='curl 8.22.0\n' \
  FAKE_BREW_JSON='{"formulae":[{"name":"curl","installed_versions":["8.22.0"],"current_version":"8.23.0"}]}'
if [ "$(LC_ALL=C grep -cE '^- WARN .*curl' "$case_dir/output.txt")" = "1" ]; then pass 'セキュリティ部品の更新待ちと最低版の WARN を 1件にまとめる'; else fail 'セキュリティ部品の更新待ちと最低版の WARN を 1件にまとめる'; sed -n '1,40p' "$case_dir/output.txt"; fi
assert_contains 'まとめた WARN に更新待ちの版と最低版の理由を残す' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新が出ています: curl 8\.22\.0 → 8\.23\.0（修正版 8\.23\.0 未満: CVE-2026-92392'

case_dir="$TEST_TMP/brew-absent-for-minimums"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='curl 8.22.0\n' RH_BREW="$fake_bin/missing-brew"
assert_not_contains 'brew が無いときは Homebrew の formula の出力をしない' "$case_dir/output.txt" 'Homebrew の curl'

# ---- 0.4.0 後半: GitLab の EOL の文は、表の EOL 行の系列の最低版を使う ----

case_dir="$TEST_TMP/gitlab-eol-from-table"
fake_bin="$case_dir/fake-bin"
docker_fake="$fake_bin/docker"
minimums="$case_dir/minimums.tsv"
make_fake_brew "$fake_bin"
make_fake_docker "$docker_fake"
printf 'gitlab\t19.1\t19.1.9\tテスト\ngitlab\t19.0\t19.0.10\tテスト\ngitlab\tEOL\t19.0\tテスト用の古い系列\n' > "$minimums"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_DOCKER="$docker_fake" RH_SECURITY_MINIMUMS="$minimums" \
  FAKE_DOCKER_PS='gitlab/gitlab-ce:18.10.8-ce.0\trunning\teol\n' FAKE_DOCKER_IMAGES='gitlab/gitlab-ce:18.10.8-ce.0\n'
assert_contains 'GitLab の EOL の文は表の EOL 行の系列（19.0）の最低版を使う' "$case_dir/output.txt" 'FAIL  GitLab 18\.10\.8（.*）が動いています。サポート終了の系列です.*で 19\.0\.10 以上へ'

case_dir="$TEST_TMP/gitlab-eol-no-row"
fake_bin="$case_dir/fake-bin"
docker_fake="$fake_bin/docker"
minimums="$case_dir/minimums.tsv"
make_fake_brew "$fake_bin"
make_fake_docker "$docker_fake"
printf 'gitlab\t19.1\t19.1.9\tテスト\ngitlab\tEOL\t19.0\tテスト用の古い系列\n' > "$minimums"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_DOCKER="$docker_fake" RH_SECURITY_MINIMUMS="$minimums" \
  FAKE_DOCKER_PS='gitlab/gitlab-ce:18.10.8-ce.0\trunning\teol\n' FAKE_DOCKER_IMAGES='gitlab/gitlab-ce:18.10.8-ce.0\n'
assert_contains 'EOL 行の系列に行が無くても文が空にならない（サポート中の系列へ）' "$case_dir/output.txt" 'FAIL  GitLab 18\.10\.8（.*）が動いています。サポート終了の系列です.*でサポート中の系列へ'
assert_not_contains 'EOL 行の系列に行が無いとき、空の最低版で「以上へ」と言わない' "$case_dir/output.txt" '）で 以上へ'

# ---- 0.4.0 後半: 侵害パッケージ（全版指定・Python）と GitHub Actions ----

commit_all() {
  git -C "$REPO_PATH" add -A
  git -C "$REPO_PATH" commit -q -m 'test: fixture'
  git -C "$REPO_PATH" push -q
}

case_dir="$TEST_TMP/denylist-shipped"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" shipped
printf '{"name":"fixture","version":"1.0.0"}\n' > "$REPO_PATH/package.json"
printf '%s\n' '{"name":"fixture","lockfileVersion":3,"packages":{"":{"name":"fixture"},"node_modules/ourin-baileys":{"version":"9.9.9"},"node_modules/@apexacc/audit":{"version":"0.0.1"}}}' > "$REPO_PATH/package-lock.json"
printf 'requests==2.0.0\nlitellm==1.107.0\n' > "$REPO_PATH/requirements.txt"
printf 'litellm==1.106.2\n' > "$REPO_PATH/requirements-dev.txt"
commit_all
run_health "$case_dir" "$case_dir/root with space"
assert_contains '同梱リスト: PhantomSub の名前は任意の版で FAIL' "$case_dir/output.txt" 'FAIL  shipped .*ourin-baileys@9\.9\.9（.*名前だけの一致（全版が対象）・package-lock\.json）'
assert_contains '同梱リスト: @apexacc/audit は全版 FAIL' "$case_dir/output.txt" 'FAIL  shipped .*@apexacc/audit@0\.0\.1（.*名前だけの一致（全版が対象）'
assert_contains '同梱リスト: LiteLLM 1.107.0 は requirements.txt で FAIL' "$case_dir/output.txt" 'FAIL  shipped .*pypi:litellm@1\.107\.0（.*版の一致・requirements\.txt）'
assert_not_contains '同梱リスト: LiteLLM 1.106.2 は当たらない' "$case_dir/output.txt" 'litellm@1\.106\.2'

case_dir="$TEST_TMP/denylist-custom"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" custom
custom_deny="$case_dir/deny.tsv"
printf 'somepkg\t*\t名前だけの行\nverpkg\t1.0.0\t版つきの行\npypi:LiteLLM\t1.107.0\tLiteLLM テスト\npypi:Some.Pkg_Name\t*\t正規化テスト\n' > "$custom_deny"
printf '{"name":"fixture","version":"1.0.0"}\n' > "$REPO_PATH/package.json"
printf '%s\n' '{"name":"fixture","lockfileVersion":3,"packages":{"":{"name":"fixture"},"node_modules/somepkg":{"version":"3.1.4"},"node_modules/verpkg":{"version":"2.0.0"},"node_modules/SomePkg":{"version":"1.0.0"},"node_modules/litellm":{"version":"1.107.0"}}}' > "$REPO_PATH/package-lock.json"
printf 'requests==2.0.0\nlitellm==1.107.0\nsome_pkg.name==2.0 ; python_version > "3"\n' > "$REPO_PATH/requirements.txt"
printf 'litellm==1.106.2\n' > "$REPO_PATH/requirements-old.txt"
printf '[[package]]\nname = "litellm"\nversion = "1.107.0"\n\n[[package]]\nversion = "1.0"\n\n[package.dependencies]\nname = "some-pkg-name"\n' > "$REPO_PATH/uv.lock"
printf '[[package]]\nname = "LiteLLM"\nversion = "1.107.0"\ndescription = "x"\n\n[[package]]\nname = "other"\nversion = "1.107.0"\n' > "$REPO_PATH/poetry.lock"
printf '%s\n' '{"default":{"litellm":{"version":"==1.107.0"}},"develop":{"verpkg":{"version":"==1.0.0"}}}' > "$REPO_PATH/Pipfile.lock"
commit_all
RH_DENYLIST="$custom_deny" run_health "$case_dir" "$case_dir/root with space"
assert_contains 'npm の * 行は任意の版に当たる' "$case_dir/output.txt" 'FAIL  custom .*somepkg@3\.1\.4（名前だけの行・名前だけの一致（全版が対象）・package-lock\.json）'
assert_not_contains 'npm の版つきの行は版違いに当たらない' "$case_dir/output.txt" 'verpkg@2\.0\.0'
assert_not_contains 'npm の名前は正規化しない（大文字小文字違いは当たらない）' "$case_dir/output.txt" 'SomePkg@1\.0\.0'
assert_contains 'pypi: 行は requirements.txt の litellm==1.107.0 に当たる（名前の正規化）' "$case_dir/output.txt" 'FAIL  custom .*pypi:litellm@1\.107\.0（LiteLLM テスト・版の一致・requirements\.txt）'
assert_contains 'pypi: 行は uv.lock に当たる' "$case_dir/output.txt" 'pypi:litellm@1\.107\.0（LiteLLM テスト・版の一致・uv\.lock）'
assert_contains 'pypi: 行は poetry.lock に当たる（名前が LiteLLM でも）' "$case_dir/output.txt" 'pypi:LiteLLM@1\.107\.0（LiteLLM テスト・版の一致・poetry\.lock）'
assert_contains 'pypi: 行は Pipfile.lock に当たる' "$case_dir/output.txt" 'pypi:litellm@1\.107\.0（LiteLLM テスト・版の一致・Pipfile\.lock）'
assert_contains 'pypi: の * 行は PEP 503 の正規化で当たる（Some.Pkg_Name と some_pkg.name）' "$case_dir/output.txt" 'pypi:some_pkg\.name@2\.0（正規化テスト・名前だけの一致（全版が対象）・requirements\.txt）'
assert_not_contains 'litellm==1.106.2 は当たらない' "$case_dir/output.txt" 'litellm@1\.106\.2|requirements-old\.txt'
assert_not_contains 'toml ロックの下位の表（[package.dependencies]）の name は読まない' "$case_dir/output.txt" 'pypi:some-pkg-name@'
assert_not_contains 'pypi: 行は npm の package-lock.json（npm の litellm）に当たらない' "$case_dir/output.txt" 'litellm@1\.107\.0（[^）]*）[^）]*package-lock\.json'

case_dir="$TEST_TMP/denylist-untracked"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" untracked
printf 'litellm==1.107.0\n' > "$REPO_PATH/requirements.txt"
printf '[[package]]\nname = "litellm"\nversion = "1.107.0"\n' > "$REPO_PATH/uv.lock"
printf '%s\n' '{"name":"fixture","lockfileVersion":3,"packages":{"":{"name":"fixture"},"node_modules/keyv":{"version":"6.0.0"}}}' > "$REPO_PATH/package-lock.json"
run_health "$case_dir" "$case_dir/root with space"
assert_not_contains '追跡外の Python のファイルは見ない' "$case_dir/output.txt" 'litellm'
assert_contains 'ルートの package-lock.json は今までどおり追跡外でも見る' "$case_dir/output.txt" 'FAIL  untracked .*keyv@6\.0\.0'

case_dir="$TEST_TMP/actions-bad"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" actionsrepo
mkdir -p "$REPO_PATH/.github/workflows"
printf 'name: ci\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions-cool/issues-helper@v3\n      # - uses: actions-cool/maintain-one-comment@v1\n' > "$REPO_PATH/.github/workflows/ci.yml"
printf 'name: deploy\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - name: x\n        uses: "Actions-Cool/Issues-Helper/sub@0123abcd"\n' > "$REPO_PATH/.github/workflows/deploy.yaml"
commit_all
printf 'jobs:\n  c:\n    steps:\n      - uses: actions-cool/maintain-one-comment@v1\n' > "$REPO_PATH/.github/workflows/untracked.yml"
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'uses: actions-cool/issues-helper@v3 は FAIL' "$case_dir/output.txt" 'FAIL  actionsrepo — 侵害された GitHub Action（actions-cool/issues-helper）を使っています。workflow から外し、そのリポの secret を入れ替えてください（.*ci\.yml）'
assert_contains '大文字小文字違い・下のパスつきの Actions-Cool/Issues-Helper/sub@sha も FAIL' "$case_dir/output.txt" 'FAIL  actionsrepo — 侵害された GitHub Action（actions-cool/issues-helper）を使っています。.*deploy\.yaml'
assert_not_contains 'コメントアウトした行と追跡外の workflow は見ない' "$case_dir/output.txt" 'maintain-one-comment'
assert_not_contains 'ほかの action（actions/checkout）は FAIL にしない' "$case_dir/output.txt" 'GitHub Action（actions/checkout）'

case_dir="$TEST_TMP/actions-clean"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" cleanactions
mkdir -p "$REPO_PATH/.github/workflows"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n      - uses: ./local-action\n      - uses: docker://alpine:3\n' > "$REPO_PATH/.github/workflows/ci.yml"
commit_all
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'ほかの action だけのリポは要対応0件' "$case_dir/output.txt" '要対応: FAIL 0件 / WARN 0件'

case_dir="$TEST_TMP/actions-custom-table"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" customactions
mkdir -p "$REPO_PATH/.github/workflows"
printf 'jobs:\n  a:\n    steps:\n      - uses: acme/evil@v1\n' > "$REPO_PATH/.github/workflows/ci.yml"
commit_all
printf '# 見出し\nacme/evil\tテスト用の理由\n' > "$case_dir/actions.tsv"
RH_ACTIONS_DENYLIST="$case_dir/actions.tsv" run_health "$case_dir" "$case_dir/root with space"
assert_contains 'RH_ACTIONS_DENYLIST で表を差し替えられる' "$case_dir/output.txt" 'FAIL  customactions — 侵害された GitHub Action（acme/evil）を使っています。.*テスト用の理由'
RH_ACTIONS_DENYLIST="$case_dir/missing.tsv" run_health "$case_dir" "$case_dir/root with space"
assert_contains '表が無いときは照合が動いていない FAIL' "$case_dir/output.txt" 'FAIL  customactions — GitHub Actions 照合が動いていません（同梱リスト不足）'

# ---- 0.4.2: Mac のセキュリティ点検だけを動かす設定 ----

case_dir="$TEST_TMP/security-only-state"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" securedirty
git clone -q "$case_dir/origin.git" "$case_dir/updater" 2>/dev/null
git -C "$case_dir/updater" config user.name tester
git -C "$case_dir/updater" config user.email tester@example.invalid
printf 'remote change\n' >> "$case_dir/updater/README.md"
git -C "$case_dir/updater" add README.md
git -C "$case_dir/updater" commit -q -m 'test: remote change'
git -C "$case_dir/updater" push -q
git -C "$REPO_PATH" fetch -q origin
printf 'local change\n' >> "$REPO_PATH/README.md"
: > "$case_dir/git.trace"
run_security_only "$case_dir" "$case_dir/root with space" GIT_TRACE="$case_dir/git.trace"
assert_not_contains 'security-only は dirty・behind の WARN を出さない' "$case_dir/output.txt" 'WARN  securedirty .*dirty|WARN  securedirty .*behind'
assert_contains 'security-only の見出しは Mac のセキュリティ点検' "$case_dir/output.txt" '^# Mac のセキュリティ点検$'
assert_not_contains 'security-only は git fetch を呼ばない' "$case_dir/git.trace" 'git fetch| fetch '
assert_not_contains 'security-only の参考にリポ・CLI の件数行を出さない' "$case_dir/output.txt" '^- (作業中|同期待ち|CLI 更新あり):'

case_dir="$TEST_TMP/security-only-denylist"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" securitydeny
printf '{"name":"fixture","version":"1.0.0"}\n' > "$REPO_PATH/package.json"
printf '%s\n' '{"name":"fixture","lockfileVersion":3,"packages":{"":{"name":"fixture"},"node_modules/keyv":{"version":"6.0.0"}}}' > "$REPO_PATH/package-lock.json"
commit_all
run_security_only "$case_dir" "$case_dir/root with space"
assert_contains 'security-only でも侵害パッケージを FAIL にする' "$case_dir/output.txt" 'FAIL  securitydeny .*keyv@6\.0\.0'

case_dir="$TEST_TMP/security-only-actions"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" securityactions
mkdir -p "$REPO_PATH/.github/workflows"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions-cool/issues-helper@v3\n' > "$REPO_PATH/.github/workflows/ci.yml"
commit_all
run_security_only "$case_dir" "$case_dir/root with space"
assert_contains 'security-only でも侵害 Actions を FAIL にする' "$case_dir/output.txt" 'FAIL  securityactions — 侵害された GitHub Action（actions-cool/issues-helper）'

case_dir="$TEST_TMP/security-only-venv"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
repo="$case_dir/root/fixture"
venv="$repo/.venv"
site="$venv/lib/python3.14/site-packages"
mkdir -p "$repo/.git" "$venv/bin"
printf 'home = /fixture\n' > "$venv/pyvenv.cfg"
make_python_site "$site" 26.2.1 2026.10.18
make_exit_command "$venv/bin/python" 0
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SECURITY_ONLY=1
assert_contains 'security-only でもリポの venv の古い pip を WARN にする' "$case_dir/output.txt" 'WARN  Python（fixture/\.venv）.*pip 26\.2\.1'

case_dir="$TEST_TMP/security-only-empty"
mkdir -p "$case_dir/empty"
run_security_only "$case_dir" "$case_dir/empty"
assert_not_contains 'security-only は対象リポ0件を FAIL にしない' "$case_dir/output.txt" 'FAIL  対象リポが0件'
assert_contains 'security-only はリポ0件で侵害パッケージ未検査を NOTES に出す' "$case_dir/output.txt" 'リポが0件のため、侵害パッケージの照合は未検査'
assert_not_contains 'security-only は CLI 更新確認の未検査 NOTES を出さない' "$case_dir/output.txt" 'CLI 更新確認は .*未検査'
assert_contains 'security-only は空のルートでも専用見出しを出す' "$case_dir/output.txt" '^# Mac のセキュリティ点検$'

case_dir="$TEST_TMP/security-only-invalid"
mkdir -p "$case_dir/home"
HOME="$case_dir/home" RH_CONFIG_FILE="$case_dir/no-config.sh" RH_SECURITY_ONLY=2 \
  bash "$HEALTH" > "$case_dir/output.txt" 2>&1
invalid_rc=$?
if [ "$invalid_rc" -ne 0 ]; then pass 'RH_SECURITY_ONLY=2 は停止する'; else fail 'RH_SECURITY_ONLY=2 は停止する'; fi
assert_contains 'RH_SECURITY_ONLY=2 の fatal 理由を表示する' "$case_dir/output.txt" 'FATAL: RH_SECURITY_ONLY は 0 または 1 を指定してください'

case_dir="$TEST_TMP/security-only-env-wins"
mkdir -p "$case_dir/home" "$case_dir/empty"
printf 'RH_SECURITY_ONLY=1\n' > "$case_dir/config.sh"
HOME="$case_dir/home" RH_CONFIG_FILE="$case_dir/config.sh" RH_SECURITY_ONLY=0 RH_ROOTS="$case_dir/empty" \
  RH_LOG_DIR="$case_dir/log" RH_STATE_DIR="$case_dir/state" \
  RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_SKIP_SECURITY=1 \
  RH_AUTOFIX_PULL=0 RH_MAIL_METHOD=none RH_NOMAIL=1 RH_NO_DESKTOP=1 \
  bash "$HEALTH" > "$case_dir/output.txt" 2>&1 || true
assert_contains '環境変数 RH_SECURITY_ONLY=0 が config.sh の 1 より優先される' "$case_dir/output.txt" 'FAIL  対象リポが0件です'
assert_contains '環境変数で通常点検に戻ると通常見出しを出す' "$case_dir/output.txt" '^# リポジトリ・ヘルスチェック$'

if [ "$failed" -gt 0 ]; then
  printf '# %s/%s tests failed\n' "$failed" "$total"
  exit 1
fi
printf '# all %s tests passed\n' "$total"
