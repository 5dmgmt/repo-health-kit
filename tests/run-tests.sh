#!/bin/bash

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
  RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 \
  RH_AUTOFIX_PULL=0 RH_MAIL_METHOD=none RH_NOMAIL=1 RH_NO_DESKTOP=1 \
    bash "$HEALTH" > "$output" 2>&1 || true
}

printf '1..15\n'

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
  bash "$PROJECT_DIR/install.sh" > "$case_dir/install-output.txt" 2>&1
install_rc=$?
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
if [ -f "$case_dir/home/.config/repo-health-kit/config.sh" ] \
  && [ -f "$case_dir/home/Library/Logs/repo-health-kit/repo-health-latest.md" ]; then
  pass 'uninstall 後も設定とログを残す'
else
  fail 'uninstall 後も設定とログを残す'
fi

if [ "$failed" -gt 0 ]; then
  printf '# %s/%s tests failed\n' "$failed" "$total"
  exit 1
fi
printf '# all %s tests passed\n' "$total"
