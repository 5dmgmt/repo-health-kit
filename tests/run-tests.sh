#!/bin/bash

# 以下では、実行時に展開させる変数を単一引用符で偽コマンドへ書き出します。
# shellcheck disable=SC2016

set -uo pipefail

export RH_DATA_GITHUB=0 RH_SUPABASE_CATALOG=0 RH_SUPABASE_ANON_PROBE=0 RH_SITE_URLS=

TEST_DIR="$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(unset CDPATH; cd -- "$TEST_DIR/.." && pwd)"
HEALTH="$PROJECT_DIR/bin/repo-health.sh"
TEST_BASH="${RH_TEST_BASH:-/bin/bash}"
# 作業フォルダは短い場所に作ります。本体は表示する名前（パス）を 120 字で切るため、TMPDIR が長いと、
# 「パスの終わりまで見える」ことに頼るテストの期待が外れます。どの TMPDIR でも同じ結果にするため、
# TMPDIR が短ければそれを使い、長いときは /tmp の下に作ります（/tmp に作れなければ TMPDIR の下に作ります）。
test_base="${TMPDIR:-/tmp}"
test_base="${test_base%/}"
TEST_TMP=""
if [ "${#test_base}" -gt 30 ]; then
  TEST_TMP="$(mktemp -d /tmp/rhk.XXXXXX 2>/dev/null)" || TEST_TMP=""
fi
[ -n "$TEST_TMP" ] || TEST_TMP="$(mktemp -d "$test_base/rhk.XXXXXX")" || exit 1
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

total=0
failed=0
REPO_PATH=""

pass() { total=$((total + 1)); printf 'ok %s - %s\n' "$total" "$1"; }
fail() { total=$((total + 1)); failed=$((failed + 1)); printf 'not ok %s - %s\n' "$total" "$1"; }

assert_contains() {
  local description="$1" file="$2" pattern="$3"
  if LC_ALL=C grep -qE -- "$pattern" "$file"; then pass "$description"; else fail "$description"; sed -n '1,120p' "$file"; fi
}

assert_not_contains() {
  local description="$1" file="$2" pattern="$3"
  if LC_ALL=C grep -qE -- "$pattern" "$file"; then fail "$description"; sed -n '1,120p' "$file"; else pass "$description"; fi
}

assert_count() {
  local description="$1" file="$2" pattern="$3" expected="$4" actual
  actual="$(LC_ALL=C grep -cE -- "$pattern" "$file" || true)"
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
    "$TEST_BASH" "$HEALTH" > "$output" 2>&1 || true
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
    RH_SKIP_SOFTWARE=1 \
    RH_NODE_CANDIDATES= RH_JAVA_CANDIDATES= RH_DOCKER="$fake_bin/missing-docker" \
    RH_MACOS_VERSION=27.0.1 RH_CLAUDE_CANDIDATES= RH_APP_DIRS="$case_dir/no-apps" RH_BREW="$fake_bin/brew" \
    RH_PYTHON_SITE_DIRS= RH_UV_CANDIDATES= RH_BUN_CANDIDATES= \
    "$@" "$TEST_BASH" "$HEALTH" > "$output" 2>&1 || true
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
    "$@" "$TEST_BASH" "$HEALTH" > "$output" 2>&1 || true
}

make_fake_brew() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/brew" <<'SH'
#!/bin/bash
fix_kegs() {
  [ -n "${FAKE_BREW_FIX_ON-}" ] && [ "${FAKE_BREW_FIX_ON}" = "$1" ] || return 0
  shift
  for formula in "$@"; do
    rm -f "${FAKE_BREW_STATE_DIR:?}/$formula.broken"
  done
}
case "${1:-}" in
  update) exit "${FAKE_BREW_UPDATE_RC:-0}" ;;
  outdated)
    if [ -n "${FAKE_BREW_AFTER_JSON-}" ] && [ -s "${FAKE_BREW_LOG:-/dev/null}" ]; then
      printf '%s\n' "$FAKE_BREW_AFTER_JSON"
    else
      python3 - <<'PY'
import json
import os
from pathlib import Path
raw = os.environ.get("FAKE_BREW_JSON", '{"formulae":[],"casks":[]}')
try:
    data = json.loads(raw)
    updated = Path(os.environ.get("FAKE_BREW_LOG", "/nonexistent") + ".updated")
    names = set(updated.read_text().splitlines()) if updated.is_file() else set()
    data["formulae"] = [f for f in data.get("formulae", []) if f.get("name") not in names]
    print(json.dumps(data))
except (ValueError, TypeError):
    print(raw)
PY
    fi ;;
  info)
    if [ "${2:-}" = --cask ]; then
      if [ -n "${FAKE_BREW_CASK_INFO_JSON-}" ]; then printf '%s\n' "$FAKE_BREW_CASK_INFO_JSON";
      else printf '%s\n' '{"formulae":[],"casks":[]}'; fi
    else exit 1; fi ;;
  upgrade|reinstall)
    printf '%s\n' "$*" >> "${FAKE_BREW_LOG:?}"
    printf 'deps-check=%s\n' "${HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK:-}" >> "$FAKE_BREW_LOG"
    printf 'cleanup=%s\n' "${HOMEBREW_NO_INSTALL_CLEANUP:-}" >> "$FAKE_BREW_LOG"
    fix_kegs "$@"
    if [ "$1" = upgrade ]; then
      if [ "${FAKE_BREW_UPGRADE_RC:-0}" = 0 ]; then
        for formula in "${@:2}"; do
          case "$formula" in --*) continue;; esac
          printf '%s\n' "$formula" >> "$FAKE_BREW_LOG.updated"
        done
      fi
      if [ -n "${FAKE_BREW_BREAK_AFTER_UPGRADE-}" ] && [ "$*" = 'upgrade node@24' ]; then
        printf 'all\n' > "$FAKE_BREW_STATE_DIR/$FAKE_BREW_BREAK_AFTER_UPGRADE.broken"
      fi
      exit "${FAKE_BREW_UPGRADE_RC:-0}"
    fi
    exit "${FAKE_BREW_REINSTALL_RC:-0}" ;;
  list)
    [ -z "${FAKE_BREW_LIST_LOG-}" ] || printf '%s\n' "$*" >> "$FAKE_BREW_LIST_LOG"
    [ "${FAKE_BREW_LIST_RC:-0}" = 0 ] || exit "$FAKE_BREW_LIST_RC"
    if [ "${2:-}" = --pinned ]; then
      printf '%b' "${FAKE_BREW_PINNED-}"
    elif [ "${2:-}" = --formula ] && [ "${3:-}" = -1 ]; then
      printf '%s\n' "${FAKE_BREW_FORMULAE-}"
    else
      versions="${FAKE_BREW_VERSIONS-}"
      if [ -n "${FAKE_BREW_SNAPSHOT_AFTER-}" ] && [ -s "${FAKE_BREW_LOG:-/dev/null}" ]; then
        versions="$FAKE_BREW_SNAPSHOT_AFTER"
      elif [ -n "${FAKE_BREW_FIXED_VERSIONS-}" ] \
        && { { [ -n "${3:-}" ] && [ ! -f "${FAKE_BREW_STATE_DIR:?}/$3.broken" ]; } \
          || { [ -z "${3:-}" ] && ! compgen -G "${FAKE_BREW_STATE_DIR:?}/*.broken" >/dev/null; }; }; then
        versions="$FAKE_BREW_FIXED_VERSIONS"
      fi
      FAKE_VERSIONS="$versions" python3 - "${3:-}" <<'PY'
import json
import os
import sys
from pathlib import Path
versions = os.environ.get("FAKE_VERSIONS", "").replace("\\n", "\n")
try:
    data = json.loads(os.environ.get("FAKE_BREW_JSON", "{}"))
except ValueError:
    data = {}
if not versions:
    versions = "\n".join(str(f.get("name")) + " " + " ".join(f.get("installed_versions", [])) for f in data.get("formulae", []))
updated_path = Path(os.environ.get("FAKE_BREW_LOG", "/nonexistent") + ".updated")
updated = set(updated_path.read_text().splitlines()) if updated_path.is_file() else set()
latest = {f.get("name"): f.get("current_version") for f in data.get("formulae", [])}
for line in versions.splitlines():
    name = line.split(" ", 1)[0]
    if name in updated and latest.get(name) and not os.environ.get("FAKE_BREW_SNAPSHOT_AFTER") and not os.environ.get("FAKE_BREW_FIXED_VERSIONS"):
        line = name + " " + latest[name]
    if not sys.argv[1] or name == sys.argv[1]:
        print(line)
PY
    fi ;;
  uses) printf '%b\n' "${FAKE_BREW_USES-}" ;;
  deps) printf '%b\n' "${FAKE_BREW_DEPS-}" ;;
  linkage)
    printf '%s\n' "$*" >> "${FAKE_BREW_LINKAGE_LOG:-/dev/null}"
    [ -z "${FAKE_BREW_LINKAGE_SLEEP-}" ] || sleep "$FAKE_BREW_LINKAGE_SLEEP"
    [ ! -f "${FAKE_BREW_STATE_DIR:-/nonexistent}/${3:-}.broken" ] ;;
  --prefix)
    if [ -n "${2:-}" ]; then
      [ "${FAKE_BREW_PREFIX_RC:-0}" = 0 ] || exit "$FAKE_BREW_PREFIX_RC"
      printf '%s/opt/%s\n' "${FAKE_BREW_PREFIX:-/fake/homebrew}" "$2"
    else printf '%s\n' "${FAKE_BREW_PREFIX:-/fake/homebrew}"; fi ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fake_bin/brew"
}

make_fake_node_keg() {
  local case_dir="$1" formula="$2" broken="${3:-}" bin
  bin="$case_dir/homebrew/opt/$formula/bin"
  mkdir -p "$bin" "$case_dir/state"
  [ -z "$broken" ] || printf '%s\n' "$broken" > "$case_dir/state/$formula.broken"
  cat > "$bin/node" <<'SH'
#!/bin/bash
formula="${0%/bin/node}"
formula="${formula##*/}"
printf '%s %s\n' "$formula" "${1:-}" >> "${FAKE_NODE_KEG_LOG:?}"
if [ "${FAKE_NODE_TRANSIENT_FORMULA-}" = "$formula" ] && [ "${1:-}" = --version ] \
  && [ ! -f "$FAKE_BREW_STATE_DIR/$formula.transient-tried" ]; then
  : > "$FAKE_BREW_STATE_DIR/$formula.transient-tried"
  exit 134
fi
if [ -f "${FAKE_BREW_STATE_DIR:?}/$formula.broken" ]; then
  mode="$(cat "$FAKE_BREW_STATE_DIR/$formula.broken")"
  if [ "$mode" != "js" ] || [ "${1:-}" != "--version" ]; then exit 134; fi
fi
case "${1:-}" in
  --version) printf 'v24.22.3\n' ;;
  *.js)
    grep -Fqx '{"name":"rh-node-health","version":"0.0.0","type":"commonjs"}' "${1%/*}/package.json" || exit 1
    grep -Fqx 'console.log("rh-node-ok")' "$1" || exit 1
    printf '%s\n' "${FAKE_NODE_KEG_OUTPUT-rh-node-ok}"
    exit "${FAKE_NODE_KEG_JS_RC:-0}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$bin/node"
}

make_npm_metadata_wrapper() {
  local dir="$1"
  mv "$dir/npm" "$dir/npm-fixture"
  cat > "$dir/npm" <<'SH'
#!/bin/bash
if [ "${1:-}" = view ]; then
  package="${2%@*}"
  "$0-fixture" view "$package" time --json | python3 -c '
import json, sys
raw = json.load(sys.stdin)
if "time" in raw or isinstance(raw, list):
    print(json.dumps(raw)); raise SystemExit()
versions = sorted(raw, key=lambda v: tuple(map(int, v.split("."))))
print(json.dumps({"time":raw, "versions":versions, "dist-tags":{"latest":versions[-1]}}))'
else
  exec "$0-fixture" "$@"
fi
SH
  chmod +x "$dir/npm"
}

make_fake_software_npm() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'if [ "${1:-}" = "outdated" ] && [ "${2:-}" = "-g" ]; then if [ -n "${FAKE_NPM_OUTDATED_JSON-}" ]; then printf "%s\n" "$FAKE_NPM_OUTDATED_JSON"; else printf "%s\n" "{}"; fi; exit "${FAKE_NPM_OUTDATED_RC:-0}"; fi'
    printf '%s\n' 'if [ "${1:-}" = "root" ] && [ "${2:-}" = "-g" ]; then printf "%s\n" "${FAKE_NPM_ROOT:-/fake/npm-global/lib/node_modules}"; exit 0; fi'
    printf '%s\n' 'if [ "${1:-}" = "view" ] && [ "${3:-}" = "time" ]; then'
    printf '%s\n' '  case "${2:-}" in oldpkg) printf "%s\n" "${FAKE_NPM_OLD_TIME_JSON:?}";; youngpkg) printf "%s\n" "${FAKE_NPM_YOUNG_TIME_JSON:?}";; *) if [ -n "${FAKE_NPM_TIME_JSON-}" ]; then printf "%s\n" "$FAKE_NPM_TIME_JSON"; else printf "%s\n" '\''{"1.0.0":"2020-01-01T00:00:00Z"}'\''; fi;; esac'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [ "${1:-}" = "--version" ]; then printf "%s\n" "1.0.0"; exit 0; fi'
    printf '%s\n' 'exit 1'
  } > "$fake_bin/npm"
  chmod +x "$fake_bin/npm"
  make_npm_metadata_wrapper "$fake_bin"
}

make_fake_mas() {
  local path="$1"
  mkdir -p "${path%/*}"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' '[ "${1:-}" = "outdated" ] || exit 1'
    printf '%s\n' 'printf "%b" "${FAKE_MAS_OUTDATED-}"'
  } > "$path"
  chmod +x "$path"
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
    RH_NOMAIL=1 RH_NO_DESKTOP=1 "$TEST_BASH" "$HEALTH" > "$output" 2>&1 || true
}

# 件数は末尾で表示します。

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
assert_contains 'git 管理外のフォルダは WARN' "$case_dir/output.txt" 'WARN  「素材フォルダ」 — git 管理外のフォルダです'
assert_contains '空のフォルダは参考' "$case_dir/output.txt" '「empty-dir」 — 空のフォルダ'
assert_not_contains '隠しフォルダは対象外' "$case_dir/output.txt" '\.hidden'
RH_WARN_NONGIT=0 run_health "$case_dir" "$case_dir/root with space"
assert_not_contains 'RH_WARN_NONGIT=0 なら知らせない' "$case_dir/output.txt" 'git 管理外のフォルダ'

case_dir="$TEST_TMP/detached"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" detached
git -C "$REPO_PATH" checkout -q --detach
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'detached HEAD は FAIL' "$case_dir/output.txt" 'FAIL  「detached」 .* detached HEAD'

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
assert_contains '未追跡かつ gitignore 外の .env は FAIL' "$case_dir/output.txt" 'FAIL  「envrepo」 .*未追跡かつ gitignore 外: 「.env」'
assert_not_contains '.env.local は検出対象外' "$case_dir/output.txt" '\.env\.local'

case_dir="$TEST_TMP/stash"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" stashrepo
printf 'change\n' >> "$REPO_PATH/README.md"
git -C "$REPO_PATH" stash push -q
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'stash 残置は WARN' "$case_dir/output.txt" 'WARN  「stashrepo」 .*stash 1 件残置'

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
assert_contains 'origin 未設定は WARN' "$case_dir/output.txt" 'WARN  「no-origin」 .*origin 未設定'

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
assert_contains 'dirty 1日目は作業中' "$case_dir/output.txt" 'dirty 1件（作業中・1日目）'
assert_not_contains 'dirty 1日目は WARN にしない' "$case_dir/output.txt" 'WARN  「dirtyrepo」 .*dirty'
state_file="$(find "$case_dir/state" -name 'dirty-*.state' -print -quit)"
yesterday="$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d')"
printf '%s 2\n' "$yesterday" > "$state_file"
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'dirty 3日目は WARN' "$case_dir/output.txt" 'WARN  「dirtyrepo」 .*dirty 1件が同じ内容のまま3日（コミットまたは退避を確認してください）'

# 0.7.1: Claude Code の作業フォルダ（.claude/worktrees）だけが未追跡のリポは、dirty に数えない
case_dir="$TEST_TMP/dirty-worktrees"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" wtrepo
mkdir -p "$REPO_PATH/.claude/worktrees/x"
printf 'work\n' > "$REPO_PATH/.claude/worktrees/x/a.txt"
run_health "$case_dir" "$case_dir/root with space"
assert_contains '.claude/worktrees だけが未追跡のリポは dirty 0 件' "$case_dir/output.txt" '「wtrepo」 — fetch=SKIP .* dirty=0 '
assert_not_contains '.claude/worktrees だけが未追跡のリポは作業中にも出さない' "$case_dir/output.txt" '「wtrepo」 — dirty [0-9]+件'
printf 'real\n' > "$REPO_PATH/real.txt"
run_health "$case_dir" "$case_dir/root with space"
assert_contains '作業フォルダの外の未追跡ファイルは今までどおり dirty に数える' "$case_dir/output.txt" 'dirty 1件（作業中・1日目）'

case_dir="$TEST_TMP/denylist"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" denyrepo
printf '{"name":"fixture","version":"1.0.0"}\n' > "$REPO_PATH/package.json"
printf '%s\n' '{"name":"fixture","lockfileVersion":3,"packages":{"":{"name":"fixture","version":"1.0.0"},"node_modules/keyv":{"version":"6.0.0"}}}' > "$REPO_PATH/package-lock.json"
git -C "$REPO_PATH" add package.json package-lock.json
git -C "$REPO_PATH" commit -q -m 'test: add lockfile'
git -C "$REPO_PATH" push -q
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'denylist 完全一致は FAIL' "$case_dir/output.txt" 'FAIL  「denyrepo」 .*keyv@6.0.0'

case_dir="$TEST_TMP/unsafe-config"
mkdir -p "$case_dir/home/.config/repo-health-kit" "$case_dir/root"
printf 'RH_MAIL_METHOD="none"\n' > "$case_dir/home/.config/repo-health-kit/config.sh"
chmod 666 "$case_dir/home/.config/repo-health-kit/config.sh"
HOME="$case_dir/home" RH_ROOTS="$case_dir/root" RH_SKIP_CLI=1 RH_NO_DESKTOP=1 "$TEST_BASH" "$HEALTH" > "$case_dir/output.txt" 2>&1
unsafe_rc=$?
if [ "$unsafe_rc" -ne 0 ]; then pass '権限666の設定ファイルは停止する'; else fail '権限666の設定ファイルは停止する'; fi
assert_contains '危険な設定ファイルを読まない理由を表示' "$case_dir/output.txt" '権限が安全でないため読みません'

case_dir="$TEST_TMP/test-mail"
mkdir -p "$case_dir/home"
HOME="$case_dir/home" RH_MAIL_METHOD=none "$TEST_BASH" "$HEALTH" --test-mail > "$case_dir/output.txt" 2>&1
assert_contains '--test-mail と none は送信しない' "$case_dir/output.txt" 'none のため送信しない'

case_dir="$TEST_TMP/install"
mkdir -p "$case_dir/home"
HOME="$case_dir/home" RH_NO_LAUNCHCTL=1 RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_NO_DESKTOP=1 \
  RH_SKIP_SECURITY=1 \
  /bin/bash "$PROJECT_DIR/install.sh" > "$case_dir/install-output.txt" 2>&1
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
HOME="$case_dir/home" RH_NO_LAUNCHCTL=1 /bin/bash "$PROJECT_DIR/uninstall.sh" > "$case_dir/uninstall-output.txt" 2>&1
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

# 0.7.1: install.sh が置くファイルを uninstall.sh がすべて消す。置く一覧と消す一覧の食い違いも照らし合わせる。
install_root="$case_dir/home/Library/Application Support/repo-health-kit"
if [ ! -e "$install_root/bin" ] && [ ! -e "$install_root/config" ] \
  && [ -z "$(find "$install_root" -type f -not -path "$install_root/state/*" -print -quit 2>/dev/null)" ]; then
  pass 'uninstall は本体・data-guard.py・設定表を残さず、空になった bin と config も消す'
else
  fail 'uninstall は本体・data-guard.py・設定表を残さず、空になった bin と config も消す'
  find "$install_root" -print
fi
installed_list="$(sed -n 's#^install -m [0-9]* .* "\$INSTALL_DIR/\([^"]*\)".*#\1#p' "$PROJECT_DIR/install.sh" | LC_ALL=C sort)"
removed_list="$(grep '^rm -f ' "$PROJECT_DIR/uninstall.sh" | grep -o '"\$INSTALL_DIR/[^"]*"' | sed 's#^"\$INSTALL_DIR/##; s#"$##' | LC_ALL=C sort)"
if [ -n "$installed_list" ] && [ "$installed_list" = "$removed_list" ] && printf '%s\n' "$installed_list" | grep -qx 'bin/data-guard.py'; then
  pass 'install.sh が置くファイルの一覧と uninstall.sh が消す一覧が一致する'
else
  fail 'install.sh が置くファイルの一覧と uninstall.sh が消す一覧が一致する'
  diff <(printf '%s\n' "$installed_list") <(printf '%s\n' "$removed_list")
fi

# 点検の状態（state）を INSTALL_DIR の外へ出して回すと、uninstall のあと INSTALL_DIR の下にファイルが 1 つも残らない
case_dir="$TEST_TMP/install-clean"
mkdir -p "$case_dir/home"
HOME="$case_dir/home" RH_STATE_DIR="$case_dir/state" RH_NO_LAUNCHCTL=1 RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_NO_DESKTOP=1 \
  RH_SKIP_SECURITY=1 \
  /bin/bash "$PROJECT_DIR/install.sh" > "$case_dir/install-output.txt" 2>&1
install_rc=$?
HOME="$case_dir/home" RH_NO_LAUNCHCTL=1 /bin/bash "$PROJECT_DIR/uninstall.sh" > "$case_dir/uninstall-output.txt" 2>&1
uninstall_rc=$?
install_root="$case_dir/home/Library/Application Support/repo-health-kit"
if [ "$install_rc" -eq 0 ] && [ "$uninstall_rc" -eq 0 ] && [ -z "$(find "$install_root" -type f -print -quit 2>/dev/null)" ]; then
  pass 'uninstall のあと INSTALL_DIR の下にファイルが 1 つも残らない'
else
  fail 'uninstall のあと INSTALL_DIR の下にファイルが 1 つも残らない'
  find "$install_root" -print 2>/dev/null
  sed -n '1,60p' "$case_dir/install-output.txt"
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
assert_contains 'ca-certificates の更新を自動修復へ出す' "$case_dir/output.txt" 'Homebrew: ca-certificates 2026-09-25 → 2026-10-20'
assert_not_contains 'ca-certificates の自動更新成功時は更新 WARN を出さない' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新'

case_dir="$TEST_TMP/security-node-manual"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" \
  FAKE_BREW_LOG="$case_dir/brew.log" \
  FAKE_BREW_JSON='{"formulae":[{"name":"ca-certificates","installed_versions":["2026-09-25"],"current_version":"2026-10-20"},{"name":"node","installed_versions":["26.11.1"],"current_version":"26.12.0"}]}'
assert_contains 'ca-certificates と node のうち ca は自動更新する' "$case_dir/output.txt" 'Homebrew: ca-certificates '
assert_contains 'RH_AUTOFIX_SECURITY=0 では node を WARN にする' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新が出ています: .*node 26\.11\.1 → 26\.12\.0'

case_dir="$TEST_TMP/security-node-software-dedupe"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
mkdir -p "$case_dir"
printf '[]\n' > "$case_dir/catalog.json"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" \
  FAKE_BREW_LOG="$case_dir/brew.log" RH_AUTOFIX_CA_CERTS=0 RH_SKIP_SOFTWARE=0 RH_AUTOFIX_SOFTWARE=1 \
  RH_CASK_CATALOG="$case_dir/catalog.json" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_JSON='{"formulae":[{"name":"node","installed_versions":["26.11.1"],"current_version":"26.12.0"},{"name":"rclone","installed_versions":["1.74.3"],"current_version":"1.75.2"}],"casks":[]}'
assert_contains 'セキュリティ部品の WARN はそのまま出す' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新が出ています: .*node 26\.11\.1 → 26\.12\.0'
assert_not_contains 'WARN 済みのセキュリティ部品はソフト更新に重ねない' "$case_dir/output.txt" 'ソフト更新: Homebrew node'
assert_not_contains 'WARN 済みのセキュリティ部品はソフト側で自動更新しない' "$case_dir/brew.log" 'upgrade --formula .*node'
assert_contains 'セキュリティ部品以外の formula はソフト側で自動更新する' "$case_dir/brew.log" 'upgrade --formula rclone'

case_dir="$TEST_TMP/security-node-auto"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" \
  FAKE_BREW_LOG="$case_dir/brew.log" RH_AUTOFIX_SECURITY=1 \
  FAKE_BREW_JSON='{"formulae":[{"name":"ca-certificates","installed_versions":["2026-09-25"],"current_version":"2026-10-20"},{"name":"node","installed_versions":["26.11.1"],"current_version":"26.12.0"}]}'
assert_contains 'RH_AUTOFIX_SECURITY=1 では node も brew upgrade する' "$case_dir/brew.log" '^upgrade node$'
assert_contains 'node の更新を自動修復へ出す' "$case_dir/output.txt" 'Homebrew: node 26\.11\.1 → 26\.12\.0'
assert_not_contains 'node の自動更新成功時は更新 WARN を出さない' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新'

# node の健康な keg と壊れた keg を分け、修復設定ごとの動きを確かめる。
for scenario in upgrade reinstall none manual js security wrong-output nonzero; do
  case_dir="$TEST_TMP/node-keg-$scenario"
  fake_bin="$case_dir/fake-bin"
  make_fake_brew "$fake_bin"
  make_fake_node_keg "$case_dir" node
  broken=all
  [ "$scenario" != js ] || broken=js
  make_fake_node_keg "$case_dir" node@24 "$broken"
  : > "$case_dir/brew.log"
  : > "$case_dir/node.log"
  fix_on=upgrade; autofix_software=1; autofix_security=0
  node_output=rh-node-ok; node_rc=0
  fixed_versions=$'node 26.13.1\nnode@24 24.22.3_1\n'
  case "$scenario" in
    reinstall) fix_on=reinstall; fixed_versions=$'node 26.13.1\nnode@24 24.22.3\n' ;;
    none) fix_on=none ;;
    manual) autofix_software=0; fix_on=none ;;
    security) autofix_software=0; autofix_security=1 ;;
    wrong-output) node_output=unexpected ;;
    nonzero) node_rc=134 ;;
  esac
  run_security "$case_dir" "$fake_bin" \
    FAKE_BREW_LOG="$case_dir/brew.log" FAKE_NODE_KEG_LOG="$case_dir/node.log" \
    FAKE_BREW_PREFIX="$case_dir/homebrew" FAKE_BREW_STATE_DIR="$case_dir/state" \
    FAKE_BREW_FORMULAE=$'node\nnode@24\n' FAKE_BREW_FIX_ON="$fix_on" \
    FAKE_BREW_VERSIONS=$'node 26.13.1\nnode@24 24.22.3\n' FAKE_BREW_FIXED_VERSIONS="$fixed_versions" \
    FAKE_NODE_KEG_OUTPUT="$node_output" FAKE_NODE_KEG_JS_RC="$node_rc" \
    RH_AUTOFIX_SOFTWARE="$autofix_software" RH_AUTOFIX_SECURITY="$autofix_security"
  assert_contains "$scenario: node@24 の起動を確認する" "$case_dir/node.log" '^node@24 --version$'
  if [ "$scenario" = manual ]; then
    assert_not_contains '自動修復なしでは upgrade も reinstall もしない' "$case_dir/brew.log" '^(upgrade|reinstall)'
  else
    assert_contains "$scenario: node@24 を名指しして upgrade する" "$case_dir/brew.log" '^upgrade node@24$'
    assert_contains "$scenario: upgrade は依存部品の巻き込みを止める" "$case_dir/brew.log" '^deps-check=1$'
  fi
  case "$scenario" in
    reinstall|none|wrong-output|nonzero)
      assert_count "$scenario: reinstall は1回だけ行う" "$case_dir/brew.log" '^reinstall node@24$' 1
      if awk '/^(upgrade|reinstall) node@24$/ { print }' "$case_dir/brew.log" | \
        diff - <(printf 'upgrade node@24\nreinstall node@24\n') >/dev/null; then
        pass "$scenario: upgrade のあとに reinstall する"
      else
        fail "$scenario: upgrade のあとに reinstall する"
      fi ;;
    *) assert_not_contains "$scenario: reinstall は呼ばない" "$case_dir/brew.log" '^reinstall node@24$' ;;
  esac
  case "$scenario" in
    none|manual|wrong-output|nonzero)
      assert_contains "$scenario: 不健康な node@24 は WARN" "$case_dir/output.txt" 'WARN  Homebrew の node@24 が起動しません'
      assert_not_contains "$scenario: 修復成功とは報告しない" "$case_dir/output.txt" 'Homebrew: node@24 .*を入れ直し'
      ;;
    *)
      assert_contains "$scenario: node@24 の修復を AUTOFIXED に載せる" "$case_dir/output.txt" 'Homebrew: node@24 24\.22\.3'
      assert_not_contains "$scenario: 直った node@24 の起動 WARN は出さない" "$case_dir/output.txt" 'WARN  Homebrew の node@24 が起動しません'
      if [ "$scenario" = reinstall ]; then
        assert_contains '前後の版が同じなら入れ直しと報告する' "$case_dir/output.txt" 'Homebrew: node@24 24\.22\.3( を入れ直し| → 24\.22\.3_1)'
      else
        assert_contains "$scenario: brew の前後の版を報告する" "$case_dir/output.txt" 'Homebrew: node@24 24\.22\.3 → 24\.22\.3_1'
      fi ;;
  esac
  if [ "$scenario" != wrong-output ] && [ "$scenario" != nonzero ]; then
    assert_not_contains "$scenario: 健康な node は修復しない" "$case_dir/brew.log" '^(upgrade|reinstall) node$'
    assert_contains "$scenario: 健康な node でも JS を実行する" "$case_dir/node.log" '^node .*/node-health/check\.js$'
  fi
  if [ "$scenario" = js ]; then
    assert_contains '版表示が通っても JS の異常を検出して修復する' "$case_dir/node.log" '^node@24 .*/node-health/check\.js$'
  fi
done

# 元の文面を保って WARN の一部・全部を除き、巻き込み更新にも追従する。
for scenario in partial all repaired-still-listed invalid-json; do
  case_dir="$TEST_TMP/node-keg-warning-$scenario"
  fake_bin="$case_dir/fake-bin"
  make_fake_brew "$fake_bin"
  make_fake_node_keg "$case_dir" node
  broken=all
  make_fake_node_keg "$case_dir" node@24 "$broken"
  make_fake_software_npm "$fake_bin"
  printf '[]\n' > "$case_dir/catalog.json"
  printf 'formula:rclone\t2026-10-01\n' > "$case_dir/state/software-outdated.tsv"
  : > "$case_dir/brew.log"
  : > "$case_dir/node.log"
  # ca の失敗 WARN を前、rclone の遅延 WARN を後に置く。
  brew_json='{"formulae":[{"name":"ca-certificates","installed_versions":["2026-09-25"],"current_version":"2026-10-20"},{"name":"node","installed_versions":["26.11.1"],"current_version":"26.12.0"},{"name":"node@24","installed_versions":["24.22.3"],"current_version":"24.22.3_1"},{"name":"rclone","installed_versions":["1.74.3"],"current_version":"1.75.2"}],"casks":[]}'
  after_json='{"formulae":[{"name":"node","installed_versions":["26.11.1"],"current_version":"26.12.0"},{"name":"rclone","installed_versions":["1.74.3"],"current_version":"1.75.2"}],"casks":[]}'
  case "$scenario" in
    all) after_json='{"formulae":[{"name":"rclone","installed_versions":["1.74.3"],"current_version":"1.75.2"}],"casks":[]}' ;;
    repaired-still-listed) after_json="$brew_json" ;;
    invalid-json) after_json='{"formulae":null}' ;;
  esac
  if [ "$scenario" != invalid-json ]; then
    after_json="$(python3 - "$after_json" <<'PYJSON'
import json
import sys
data = json.loads(sys.argv[1])
if not any(f.get("name") == "ca-certificates" for f in data["formulae"]):
    data["formulae"].insert(0, {"name": "ca-certificates", "installed_versions": ["2026-09-25"], "current_version": "2026-10-20"})
print(json.dumps(data))
PYJSON
)"
  fi
  run_security "$case_dir" "$fake_bin" \
    FAKE_BREW_LOG="$case_dir/brew.log" FAKE_NODE_KEG_LOG="$case_dir/node.log" \
    FAKE_BREW_PREFIX="$case_dir/homebrew" FAKE_BREW_STATE_DIR="$case_dir/state" \
    FAKE_BREW_FORMULAE=$'node\nnode@24\n' FAKE_BREW_FIX_ON=upgrade \
    FAKE_BREW_VERSIONS=$'node 26.11.1\nnode@24 24.22.3\n' \
    FAKE_BREW_JSON="$brew_json" FAKE_BREW_AFTER_JSON="$after_json" FAKE_BREW_UPGRADE_RC=1 \
    RH_AUTOFIX_SOFTWARE=1 RH_AUTOFIX_SECURITY=0 RH_SKIP_SOFTWARE=0 RH_TODAY=2026-11-16 \
    RH_CASK_CATALOG="$case_dir/catalog.json" RH_MAS="$fake_bin/missing-mas"
  case "$scenario" in
    repaired-still-listed)
      assert_contains '起動修復後も outdated に残る部品の更新 WARN は保つ' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新.*node@24'
      ;;
    *) assert_not_contains "$scenario: 解消した node@24 の更新 WARN は除く" "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新.*node@24' ;;
  esac
  case "$scenario" in
    all)
      assert_not_contains "$scenario: 解消した node の WARN 項目を除く" "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新.*node'
      ;;
    invalid-json)
      assert_contains '更新待ちの再取得が不正な場合は未検査を残す' "$case_dir/output.txt" 'Homebrew.*未検査'
      ;;
    *)
      assert_contains "$scenario: 更新待ちの node の文面を残す" "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新が出ています: .*node 26\.11\.1 → 26\.12\.0'
      ;;
  esac
  if [ "$scenario" != invalid-json ]; then
    if python3 - "$case_dir/output.txt" "$scenario" <<'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
before = next(i for i, line in enumerate(lines) if "WARN  ca-certificates の自動更新に失敗" in line)
after = next(i for i, line in enumerate(lines) if "WARN  rclone の更新が" in line)
assert before < after
if sys.argv[2] != "all":
    middle = next(i for i, line in enumerate(lines) if "WARN  Mac のセキュリティ部品に更新" in line)
    assert before < middle < after
PY
    then pass "$scenario: ほかの WARN の順番を変えない"; else fail "$scenario: ほかの WARN の順番を変えない"; fi
  fi
done

case_dir="$TEST_TMP/node-keg-warning-only"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_node_keg "$case_dir" node@24 all
: > "$case_dir/brew.log"
: > "$case_dir/node.log"
run_security "$case_dir" "$fake_bin" \
  FAKE_BREW_LOG="$case_dir/brew.log" FAKE_NODE_KEG_LOG="$case_dir/node.log" \
  FAKE_BREW_PREFIX="$case_dir/homebrew" FAKE_BREW_STATE_DIR="$case_dir/state" \
  FAKE_BREW_FORMULAE=node@24 FAKE_BREW_FIX_ON=upgrade \
  FAKE_BREW_VERSIONS=$'node@24 24.22.3\n' RH_AUTOFIX_SOFTWARE=1 RH_SECURITY_ONLY=1 \
  FAKE_BREW_JSON='{"formulae":[{"name":"node@24","installed_versions":["24.22.3"],"current_version":"24.22.3_1"}]}'
assert_contains '最後の WARN が消えても Bash 3.2 でレポートを作れる' "$case_dir/output.txt" '要対応: FAIL 0件 / WARN 0件'
assert_contains '最後の WARN を消した場合も修復結果を残す' "$case_dir/output.txt" 'Homebrew: node@24 24\.22\.3( を入れ直し| → 24\.22\.3_1)'

case_dir="$TEST_TMP/node-keg-no-formula"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
# 名前の似た別 formula は起動確認しない。
make_fake_node_keg "$case_dir" node-extra all
: > "$case_dir/brew.log"
: > "$case_dir/node.log"
run_security "$case_dir" "$fake_bin" \
  FAKE_BREW_LOG="$case_dir/brew.log" FAKE_NODE_KEG_LOG="$case_dir/node.log" \
  FAKE_BREW_PREFIX="$case_dir/homebrew" FAKE_BREW_STATE_DIR="$case_dir/state" \
  FAKE_BREW_FORMULAE=$'python\nnode-extra\nnode@foo\n' RH_AUTOFIX_SOFTWARE=1 RH_SECURITY_ONLY=1
assert_not_contains 'node formula がなければ起動確認をしない' "$case_dir/node.log" '.'
assert_not_contains 'node formula がなければ修復をしない' "$case_dir/brew.log" '^(upgrade|reinstall)'
assert_contains 'node formula がなければ要対応0件のまま' "$case_dir/output.txt" '要対応: FAIL 0件 / WARN 0件'

case_dir="$TEST_TMP/node-keg-no-executable"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" \
  FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_PREFIX="$case_dir/homebrew" \
  FAKE_BREW_FORMULAE=node@24 RH_AUTOFIX_SOFTWARE=1
assert_not_contains '実行できる node がない formula は修復しない' "$case_dir/brew.log" '^(upgrade|reinstall)'
assert_not_contains '実行できる node がない formula は起動 WARN を出さない' "$case_dir/output.txt" 'WARN  Homebrew の node@24 が起動しません'

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
assert_count '同じ venv の古い pip と certifi は WARN 1件にまとめる' "$case_dir/output.txt" 'WARN  Python（「fixture」/「.venv」）' 1
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
assert_not_contains '修正版の venv は Python の WARN を出さない' "$case_dir/output.txt" '^WARN  Python（「fixture」/「.venv」）'
assert_contains '修正版の pip は最低版以上の detail を出す' "$case_dir/output.txt" 'Python（「fixture」/「.venv」）の pip 26\.2\.2 — 最低版 26\.2\.2 以上'

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
kit_version_re="$(sed -n '1p' "$PROJECT_DIR/VERSION" | sed 's/\./\\./g')"
assert_contains 'kit の新しい版は WARN' "$case_dir/output.txt" "WARN  repo-health-kit の新しい版 ${kit_version_re} → 0\.9\.0 があります"

case_dir="$TEST_TMP/composer"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" composerrepo
printf '%s\n' '{"packages":[]}' > "$REPO_PATH/composer.lock"
composer_fake="$case_dir/composer"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'printf "%s\n" "$*" >> "${FAKE_COMPOSER_ARGS:-/dev/null}"'
  printf '%s\n' 'printf "%s\n" '\''{"advisories":{"vendor/package":[{"severity":"high"}]}}'\'''
  printf '%s\n' 'exit 1'
} > "$composer_fake"
chmod +x "$composer_fake"
FAKE_COMPOSER_ARGS="$case_dir/args.log" run_composer "$case_dir/high" "$case_dir/root with space" "$composer_fake"
assert_contains 'composer のプラグインを読み込まない' "$case_dir/args.log" '--no-plugins'
assert_contains 'composer のスクリプトを動かさない' "$case_dir/args.log" '--no-scripts'
assert_contains 'composer の high 1件は FAIL' "$case_dir/high/output.txt" 'FAIL  「composerrepo」 — 本番依存に critical/high 脆弱性（composer'
run_composer "$case_dir/absent" "$case_dir/root with space" ''
assert_contains 'composer 不在は WARN' "$case_dir/absent/output.txt" 'WARN  「composerrepo」 — composer audit 実行不能（composer 不在）'

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
assert_contains 'macOS 14.7 は修正版が出ていない系列の WARN' "$TEST_TMP/macos-14-eol/output.txt" 'WARN  macOS 14\.7 — 古い系列（表の最低系列 15 より前）'

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
assert_contains 'Claude Code 2.1.259 は修正版 2.1.260 より古い WARN' "$case_dir/output.txt" 'WARN  Claude Code 2\.1\.259（.*fake-bin/claude」）は修正版 2\.1\.260 より古い版です（GHSA-gfvf-j8jh-jxxw'
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
assert_contains '版を返さない Claude Code は未検査の NOTES' "$case_dir/output.txt" 'Claude Code（.*fake-bin/claude」）— 版を判定できず未検査'

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
    printf '%s\n' 'if [ "${1:-}" = "view" ] && [ "${3:-}" = "time" ]; then'
    printf '%s\n' '  if [ "${2:-}" = "@anthropic-ai/claude-code" ]; then latest="${FAKE_CLAUDE_LATEST:?}"; [ -z "${FAKE_CLAUDE_TIME_JSON-}" ] || { printf "%s\n" "$FAKE_CLAUDE_TIME_JSON"; exit 0; }; else latest="1.0.0"; fi'
    printf '%s\n' '  printf "{\"%s\":\"2020-01-01T00:00:00.000Z\"}\n" "$latest"'
    printf '%s\n' 'else printf "%s\n" "1.0.0"; fi'
  } > "$dir/npm"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'exit 0'
  } > "$dir/curl"
  chmod +x "$dir/npm" "$dir/curl"
  make_npm_metadata_wrapper "$dir"
}

case_dir="$TEST_TMP/claude-cli-dup"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_cli_set "$fake_bin"
make_fake_claude "$fake_bin/claude"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_CLI=0 \
  RH_CLAUDE_CANDIDATES="$fake_bin/claude" FAKE_CLAUDE_OUTPUT='2.1.250 (Claude Code)' FAKE_CLAUDE_LATEST=3.0.0
assert_contains 'CLI の更新確認はメジャー版遅れを WARN にする' "$case_dir/output.txt" 'WARN  claude 2\.1\.250 → 3\.0\.0'
assert_not_contains '同じ claude の最低版の話は 2 度目の WARN にしない' "$case_dir/output.txt" 'WARN  Claude Code 2\.1\.250'
assert_contains '2 度目に出さなかった最低版の話は detail に残す' "$case_dir/output.txt" 'Claude Code 2\.1\.250（.*）は修正版 2\.1\.260 より古い版です.*WARN は 1 件にまとめています'

make_fake_app() {
  local dir="$1" name="$2" bundle="$3" version="$4" build="${5:-}"
  mkdir -p "$dir/$name.app/Contents"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">' '<dict>'
    printf '<key>CFBundleIdentifier</key>\n<string>%s</string>\n' "$bundle"
    printf '<key>CFBundleShortVersionString</key>\n<string>%s</string>\n' "$version"
    [ -z "$build" ] || printf '<key>CFBundleVersion</key>\n<string>%s</string>\n' "$build"
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
make_fake_app "$apps" 'Google Chrome' com.google.Chrome 156.0.8078.78
make_fake_app "$apps/入れ子" 'Claude' com.anthropic.claudefordesktop 1.15961.9
make_fake_app "$apps" 'Firefox' org.mozilla.firefox 140.4.0
mkdir -p "$apps/Firefox.app/Contents/Resources/defaults/pref"
printf '%s\n' 'pref("app.update.channel", "esr");' > "$apps/Firefox.app/Contents/Resources/defaults/pref/channel-prefs.js"
make_fake_app "$apps" 'Other' com.example.other 0.0.1
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps"
assert_contains 'Chrome 156.0.8078.78 は修正版 156.0.8078.79 より古い WARN' "$case_dir/output.txt" 'WARN  Chrome 156\.0\.8078\.78（.*Google Chrome\.app」）は修正版 156\.0\.8078\.79 より古い版です'
assert_contains 'Chrome の WARN に直し方を含める' "$case_dir/output.txt" 'Chrome を再起動すると更新されます（設定 → Chrome について）'
assert_contains '1 段下のフォルダにある Claude Desktop 1.15961.9 も WARN' "$case_dir/output.txt" 'WARN  Claude Desktop 1\.15961\.9（.*入れ子/Claude\.app」）は修正版 1\.15962\.0 より古い版です'
assert_contains 'Firefox ESR は比べず NOTES にする' "$case_dir/output.txt" 'Firefox ESR（.*Firefox\.app」）— ESR の系列は未検査'
assert_not_contains 'Firefox ESR は WARN にしない' "$case_dir/output.txt" '(WARN|FAIL)  Firefox '
assert_not_contains '表に無いアプリは何も出さない' "$case_dir/output.txt" 'com\.example\.other|Other\.app'

case_dir="$TEST_TMP/apps-fixed"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_app "$apps" 'Google Chrome' com.google.Chrome 156.0.8078.79
make_fake_app "$apps" 'Claude' com.anthropic.claudefordesktop 1.15962.0
make_fake_app "$apps" 'Firefox' org.mozilla.firefox 158.0.1
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps"
assert_not_contains '修正版ちょうどのアプリは要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  (Chrome|Claude Desktop|Firefox) '
assert_contains '修正版以上のアプリは detail に残す' "$case_dir/output.txt" 'com\.google\.Chrome 156\.0\.8078\.79（.*）— 最低版 156\.0\.8078\.79 以上'

case_dir="$TEST_TMP/apps-firefox-old"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_app "$apps" 'Firefox' org.mozilla.firefox 158.0
mkdir -p "$apps/Firefox.app/Contents/Resources/defaults/pref"
printf '%s\n' 'pref("app.update.channel", "release");' > "$apps/Firefox.app/Contents/Resources/defaults/pref/channel-prefs.js"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps"
assert_contains '通常版の Firefox 158.0 は 158.0.1 より古い WARN' "$case_dir/output.txt" 'WARN  Firefox 158\.0（.*Firefox\.app」）は修正版 158\.0\.1 より古い版です（MFSA-2026-106'
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
assert_contains '名前ごとの案内が無いアプリは汎用の直し方を出す' "$case_dir/output.txt" 'WARN  com\.example\.sample 1\.0\.0（.*Sample\.app」）は修正版 2\.0\.0 より古い版です（テスト用）。アプリを最新版へ更新してください'

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

case_dir="$TEST_TMP/brew-brotli"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='brotli 1.2.0\n'
assert_contains 'Homebrew の brotli 1.2.0 は修正版 1.2.1 より古い WARN' "$case_dir/output.txt" 'WARN  Homebrew の brotli 1\.2\.0 は修正版 1\.2\.1 より古い版です（CVE-2026-111497.*）。brew upgrade brotli'
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='brotli 1.2.1\n'
assert_not_contains 'Homebrew の brotli 1.2.1 は要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  Homebrew の brotli'

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
assert_contains '表の最低系列より古い openssl@3 3.3.9 は WARN にする' "$case_dir/e/output.txt" '(WARN|FAIL)  Homebrew の openssl@3'
assert_contains '古い系列の WARN に表の最低系列を残す' "$case_dir/e/output.txt" 'Homebrew の openssl@3 3\.3\.9 — 古い系列（表の最低系列 3.4 より前）'

case_dir="$TEST_TMP/brew-no-double"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='curl 8.22.0\n' \
  FAKE_BREW_JSON='{"formulae":[{"name":"curl","installed_versions":["8.22.0"],"current_version":"8.23.0"}]}'
if [ "$(LC_ALL=C grep -cE '^- WARN .*curl' "$case_dir/output.txt")" = "1" ]; then pass 'セキュリティ部品の更新待ちと最低版の WARN を 1件にまとめる'; else fail 'セキュリティ部品の更新待ちと最低版の WARN を 1件にまとめる'; sed -n '1,40p' "$case_dir/output.txt"; fi
assert_contains 'まとめた WARN に更新待ちの版と最低版の理由を残す' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新が出ています: curl 8\.22\.0 → 8\.23\.0（修正版 8\.23\.0 未満: CVE-2026-92392'

# openssl@4 も一覧の openssl@* で拾う（0.8.2・2026-11-24 に両機で openssl@4 4.1.0 が入っていたのに一覧は @3・@1.1 だけだった）。
case_dir="$TEST_TMP/brew-openssl4"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_VERSIONS='openssl@4 4.1.0\n' \
  FAKE_BREW_JSON='{"formulae":[{"name":"openssl@4","installed_versions":["4.1.0"],"current_version":"4.1.1"}]}'
assert_contains 'openssl@4 の更新待ちもセキュリティ部品として WARN' "$case_dir/output.txt" 'WARN  Mac のセキュリティ部品に更新が出ています: openssl@4 4\.1\.0 → 4\.1\.1'

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
assert_contains '同梱リスト: PhantomSub の名前は任意の版で FAIL' "$case_dir/output.txt" 'FAIL  「shipped」 .*ourin-baileys@9\.9\.9（.*名前だけの一致（全版が対象）・「package-lock\.json」）'
assert_contains '同梱リスト: @apexacc/audit は全版 FAIL' "$case_dir/output.txt" 'FAIL  「shipped」 .*@apexacc/audit@0\.0\.1（.*名前だけの一致（全版が対象）'
assert_contains '同梱リスト: LiteLLM 1.107.0 は requirements.txt で FAIL' "$case_dir/output.txt" 'FAIL  「shipped」 .*pypi:litellm@1\.107\.0（.*版の一致・「requirements\.txt」）'
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
assert_contains 'npm の * 行は任意の版に当たる' "$case_dir/output.txt" 'FAIL  「custom」 .*somepkg@3\.1\.4（名前だけの行・名前だけの一致（全版が対象）・「package-lock\.json」）'
assert_not_contains 'npm の版つきの行は版違いに当たらない' "$case_dir/output.txt" 'verpkg@2\.0\.0'
assert_not_contains 'npm の名前は正規化しない（大文字小文字違いは当たらない）' "$case_dir/output.txt" 'SomePkg@1\.0\.0'
assert_contains 'pypi: 行は requirements.txt の litellm==1.107.0 に当たる（名前の正規化）' "$case_dir/output.txt" 'FAIL  「custom」 .*pypi:litellm@1\.107\.0（LiteLLM テスト・版の一致・「requirements\.txt」）'
assert_contains 'pypi: 行は uv.lock に当たる' "$case_dir/output.txt" 'pypi:litellm@1\.107\.0（LiteLLM テスト・版の一致・「uv\.lock」）'
assert_contains 'pypi: 行は poetry.lock に当たる（名前が LiteLLM でも）' "$case_dir/output.txt" 'pypi:LiteLLM@1\.107\.0（LiteLLM テスト・版の一致・「poetry\.lock」）'
assert_contains 'pypi: 行は Pipfile.lock に当たる' "$case_dir/output.txt" 'pypi:litellm@1\.107\.0（LiteLLM テスト・版の一致・「Pipfile\.lock」）'
assert_contains 'pypi: の * 行は PEP 503 の正規化で当たる（Some.Pkg_Name と some_pkg.name）' "$case_dir/output.txt" 'pypi:some_pkg\.name@2\.0（正規化テスト・名前だけの一致（全版が対象）・「requirements\.txt」）'
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
assert_contains 'ルートの package-lock.json は今までどおり追跡外でも見る' "$case_dir/output.txt" 'FAIL  「untracked」 .*keyv@6\.0\.0'

case_dir="$TEST_TMP/actions-bad"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" actionsrepo
mkdir -p "$REPO_PATH/.github/workflows"
printf 'name: ci\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions-cool/issues-helper@v3\n      # - uses: actions-cool/maintain-one-comment@v1\n' > "$REPO_PATH/.github/workflows/ci.yml"
printf 'name: deploy\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - name: x\n        uses: "Actions-Cool/Issues-Helper/sub@0123abcd"\n' > "$REPO_PATH/.github/workflows/deploy.yaml"
commit_all
printf 'jobs:\n  c:\n    steps:\n      - uses: actions-cool/maintain-one-comment@v1\n' > "$REPO_PATH/.github/workflows/untracked.yml"
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'uses: actions-cool/issues-helper@v3 は FAIL' "$case_dir/output.txt" 'FAIL  「actionsrepo」 — 侵害された GitHub Action（actions-cool/issues-helper）を使っています。workflow から外し、そのリポの secret を入れ替えてください（.*ci\.yml」）'
assert_contains '大文字小文字違い・下のパスつきの Actions-Cool/Issues-Helper/sub@sha も FAIL' "$case_dir/output.txt" 'FAIL  「actionsrepo」 — 侵害された GitHub Action（actions-cool/issues-helper）を使っています。.*deploy\.yaml'
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
assert_contains 'RH_ACTIONS_DENYLIST で表を差し替えられる' "$case_dir/output.txt" 'FAIL  「customactions」 — 侵害された GitHub Action（acme/evil）を使っています。.*テスト用の理由'
RH_ACTIONS_DENYLIST="$case_dir/missing.tsv" run_health "$case_dir" "$case_dir/root with space"
assert_contains '表が無いときは照合が動いていない FAIL' "$case_dir/output.txt" 'FAIL  「customactions」 — GitHub Actions 照合が動いていません（同梱リスト不足）'

# ---- 0.4.3: Mac のセキュリティ点検だけを動かす設定 ----

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
assert_not_contains 'security-only は dirty・behind の WARN を出さない' "$case_dir/output.txt" 'WARN  「securedirty」 .*dirty|WARN  「securedirty」 .*behind'
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
assert_contains 'security-only でも侵害パッケージを FAIL にする' "$case_dir/output.txt" 'FAIL  「securitydeny」 .*keyv@6\.0\.0'

case_dir="$TEST_TMP/security-only-actions"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" securityactions
mkdir -p "$REPO_PATH/.github/workflows"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions-cool/issues-helper@v3\n' > "$REPO_PATH/.github/workflows/ci.yml"
commit_all
run_security_only "$case_dir" "$case_dir/root with space"
assert_contains 'security-only でも侵害 Actions を FAIL にする' "$case_dir/output.txt" 'FAIL  「securityactions」 — 侵害された GitHub Action（actions-cool/issues-helper）'

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
assert_contains 'security-only でもリポの venv の古い pip を WARN にする' "$case_dir/output.txt" 'WARN  Python（「fixture」/「.venv」）.*pip 26\.2\.1'

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
  "$TEST_BASH" "$HEALTH" > "$case_dir/output.txt" 2>&1
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
  "$TEST_BASH" "$HEALTH" > "$case_dir/output.txt" 2>&1 || true
assert_contains '環境変数 RH_SECURITY_ONLY=0 が config.sh の 1 より優先される' "$case_dir/output.txt" 'FAIL  対象リポが0件です'
assert_contains '環境変数で通常点検に戻ると通常見出しを出す' "$case_dir/output.txt" '^# リポジトリ・ヘルスチェック$'

# ---- 0.4.4: HTTP2Shell（Brotli）の残り — Python の brotli・formula 専用の環境・Bun・Electron のアプリ ----

make_dist_info() {
  local site="$1" name="$2" version="$3"
  mkdir -p "$site/${name}-${version}.dist-info"
  printf 'Metadata-Version: 2.4\nName: %s\nVersion: %s\n' "$name" "$version" > "$site/${name}-${version}.dist-info/METADATA"
}

make_fake_bun() {
  local path="$1"
  mkdir -p "${path%/*}"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'printf "%s\n" "${FAKE_BUN_OUTPUT-}"'
  } > "$path"
  chmod +x "$path"
}

# Electron 製のアプリを作る。引数: 置き場 名前 バンドルID 版 更新日(touch -t の形式) electron(1/0)
make_fake_electron_app() {
  local dir="$1" name="$2" bundle="$3" version="$4" stamp="$5" electron="$6"
  make_fake_app "$dir" "$name" "$bundle" "$version"
  if [ "$electron" = "1" ]; then
    mkdir -p "$dir/$name.app/Contents/Frameworks/Electron Framework.framework"
  fi
  touch -t "$stamp" "$dir/$name.app/Contents/Info.plist"
}

# --- Python の brotli / brotlicffi ---

case_dir="$TEST_TMP/brotli-old"
fake_bin="$case_dir/fake-bin"
site="$case_dir/lib/python3.14/site-packages"
python="$case_dir/bin/python"
make_fake_brew "$fake_bin"
make_dist_info "$site" brotli 1.2.0
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'venv\t%s\t%s' "$site" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_contains '古い brotli 1.2.0 は 1.2.1 より古い WARN' "$case_dir/output.txt" 'WARN  Python（.*）の brotli 1\.2\.0 は修正版 1\.2\.1 より古い版です（CVE-2026-111497'
assert_contains 'brotli の WARN に pip install --upgrade brotli を案内する' "$case_dir/output.txt" '直し方: ".*bin/python" -m pip install --upgrade brotli'

case_dir="$TEST_TMP/brotli-fixed"
fake_bin="$case_dir/fake-bin"
site="$case_dir/lib/python3.14/site-packages"
python="$case_dir/bin/python"
make_fake_brew "$fake_bin"
make_dist_info "$site" brotli 1.2.1
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'venv\t%s\t%s' "$site" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_not_contains '修正版の brotli 1.2.1 は WARN を出さない' "$case_dir/output.txt" 'WARN  Python（.*）の brotli '
assert_contains '修正版の brotli は最低版以上の detail を出す' "$case_dir/output.txt" 'Python（.*）の brotli 1\.2\.1 — 最低版 1\.2\.1 以上'

case_dir="$TEST_TMP/brotli-newest-wins"
fake_bin="$case_dir/fake-bin"
site="$case_dir/lib/python3.14/site-packages"
python="$case_dir/bin/python"
make_fake_brew "$fake_bin"
make_dist_info "$site" brotli 1.2.0
make_dist_info "$site" brotli 1.2.1
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'venv\t%s\t%s' "$site" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_not_contains '同じ場所に複数の brotli があれば一番新しい版で判定する' "$case_dir/output.txt" 'WARN  Python（.*）の brotli '

case_dir="$TEST_TMP/brotlicffi-old"
fake_bin="$case_dir/fake-bin"
site="$case_dir/lib/python3.14/site-packages"
python="$case_dir/bin/python"
make_fake_brew "$fake_bin"
make_dist_info "$site" brotlicffi 1.2.0.0
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'venv\t%s\t%s' "$site" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_contains '古い brotlicffi 1.2.0.0 は 1.2.1.0 より古い WARN' "$case_dir/output.txt" 'WARN  Python（.*）の brotlicffi 1\.2\.0\.0 は修正版 1\.2\.1\.0 より古い版です'
assert_contains 'brotlicffi の WARN に pip install --upgrade brotlicffi を案内する' "$case_dir/output.txt" ' -m pip install --upgrade brotlicffi'
assert_not_contains 'brotlicffi の dist-info を brotli と取り違えない' "$case_dir/output.txt" 'の brotli 1\.'

case_dir="$TEST_TMP/brotlicffi-fixed"
fake_bin="$case_dir/fake-bin"
site="$case_dir/lib/python3.14/site-packages"
python="$case_dir/bin/python"
make_fake_brew "$fake_bin"
make_dist_info "$site" brotlicffi 1.2.1.0
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'venv\t%s\t%s' "$site" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_not_contains '修正版の brotlicffi 1.2.1.0 は WARN を出さない' "$case_dir/output.txt" 'WARN  Python（.*）の brotlicffi '

case_dir="$TEST_TMP/brotli-user-flag"
fake_bin="$case_dir/fake-bin"
site="$case_dir/home/Library/Python/3.14/lib/python/site-packages"
python="$case_dir/python3.14"
make_fake_brew "$fake_bin"
make_dist_info "$site" brotli 1.2.0
make_exit_command "$python" 0
: > "$case_dir/brew.log"
python_sites="$(printf 'user\t%s\t%s' "$site" "$python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_contains 'user site の古い brotli は --user 付きの直し方を案内する' "$case_dir/output.txt" ' -m pip install --user --upgrade brotli'

case_dir="$TEST_TMP/brotli-apple"
fake_bin="$case_dir/fake-bin"
site="$case_dir/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/lib/python3.9/site-packages"
make_fake_brew "$fake_bin"
make_python_site "$site" 26.2.2 2026.10.19
make_dist_info "$site" brotli 1.0.9
: > "$case_dir/brew.log"
python_sites="$(printf 'apple\t%s\t/usr/bin/python3' "$site")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_not_contains 'Apple 管理の Python の brotli は WARN にしない' "$case_dir/output.txt" '^WARN  (Python|Apple)'
assert_count 'Apple 管理の Python の brotli は NOTES 1件' "$case_dir/output.txt" 'Apple の python3（.*）の brotli 1\.0\.9 は古い版です（Apple の更新待ち）' 1

# --- Homebrew の formula 専用の環境（brew-formula） ---

case_dir="$TEST_TMP/brew-formula-brotli-old"
fake_bin="$case_dir/fake-bin"
site="$case_dir/homebrew/Cellar/yt-dlp/2026.10.21/libexec/lib/python3.15/site-packages"
make_fake_brew "$fake_bin"
make_dist_info "$site" brotli 1.2.0
: > "$case_dir/brew.log"
python_sites="$(printf 'brew-formula\t%s\t%s' "$site" "$case_dir/homebrew/Cellar/yt-dlp/2026.10.21/libexec/bin/python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_contains 'formula 専用の環境の古い brotli は WARN（場所の名前は Homebrew の formula）' "$case_dir/output.txt" 'WARN  Python（Homebrew の yt-dlp）の brotli 1\.2\.0 は修正版 1\.2\.1 より古い版です'
assert_contains 'formula 専用の環境の直し方は brew upgrade <formula>' "$case_dir/output.txt" '直し方: brew upgrade yt-dlp'
assert_contains 'Homebrew がまだ直していないときは、直るまでの注意を添える' "$case_dir/output.txt" 'brew upgrade yt-dlp（Homebrew が直すまでは、その道具で知らないサイトを開かない）'

case_dir="$TEST_TMP/brew-formula-brotli-outdated"
fake_bin="$case_dir/fake-bin"
site="$case_dir/homebrew/Cellar/yt-dlp/2026.10.21/libexec/lib/python3.15/site-packages"
make_fake_brew "$fake_bin"
make_dist_info "$site" brotli 1.2.0
: > "$case_dir/brew.log"
python_sites="$(printf 'brew-formula\t%s\t%s' "$site" "$case_dir/homebrew/Cellar/yt-dlp/2026.10.21/libexec/bin/python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites" \
  FAKE_BREW_JSON='{"formulae":[{"name":"yt-dlp","installed_versions":["2026.10.21"],"current_version":"2026.10.25"}],"casks":[]}'
assert_contains 'Homebrew が直した（brew outdated にある）formula は brew upgrade を案内する' "$case_dir/output.txt" 'WARN  Python（Homebrew の yt-dlp）の brotli 1\.2\.0.*直し方: brew upgrade yt-dlp$'
assert_not_contains 'brew outdated にある formula には直るまでの注意を添えない' "$case_dir/output.txt" 'Homebrew が直すまでは'

case_dir="$TEST_TMP/brew-formula-brotli-fixed"
fake_bin="$case_dir/fake-bin"
site="$case_dir/homebrew/Cellar/yt-dlp/2026.10.21/libexec/lib/python3.15/site-packages"
make_fake_brew "$fake_bin"
make_dist_info "$site" brotli 1.2.1
: > "$case_dir/brew.log"
python_sites="$(printf 'brew-formula\t%s\t%s' "$site" "$case_dir/homebrew/Cellar/yt-dlp/2026.10.21/libexec/bin/python")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_not_contains '修正版の brotli を抱える formula は WARN を出さない' "$case_dir/output.txt" 'WARN  Python（Homebrew の yt-dlp）'
assert_contains '修正版の formula 専用の環境は detail に残す' "$case_dir/output.txt" 'Python（Homebrew の yt-dlp）の brotli 1\.2\.1 — 最低版 1\.2\.1 以上'

case_dir="$TEST_TMP/brew-formula-linked-only"
fake_bin="$case_dir/fake-bin"
old_site="$case_dir/homebrew/Cellar/yt-dlp/2026.9.1/libexec/lib/python3.15/site-packages"
new_site="$case_dir/homebrew/Cellar/yt-dlp/2026.10.21/libexec/lib/python3.15/site-packages"
make_fake_brew "$fake_bin"
make_dist_info "$old_site" brotli 1.2.0
make_dist_info "$new_site" brotli 1.2.1
mkdir -p "$case_dir/homebrew/opt"
ln -s "$case_dir/homebrew/Cellar/yt-dlp/2026.10.21" "$case_dir/homebrew/opt/yt-dlp"
: > "$case_dir/brew.log"
python_sites="$(printf 'brew-formula\t%s\t/x/python\nbrew-formula\t%s\t/x/python' "$old_site" "$new_site")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_not_contains 'リンクされていない古い版の formula は見ない' "$case_dir/output.txt" 'WARN  Python（Homebrew の yt-dlp）'
assert_contains 'リンクされている版の formula は見る' "$case_dir/output.txt" 'Python（Homebrew の yt-dlp）の brotli 1\.2\.1 — 最低版 1\.2\.1 以上'

case_dir="$TEST_TMP/brew-formula-linked-old"
fake_bin="$case_dir/fake-bin"
old_site="$case_dir/homebrew/Cellar/yt-dlp/2026.9.1/libexec/lib/python3.15/site-packages"
new_site="$case_dir/homebrew/Cellar/yt-dlp/2026.10.21/libexec/lib/python3.15/site-packages"
make_fake_brew "$fake_bin"
make_dist_info "$old_site" brotli 1.2.1
make_dist_info "$new_site" brotli 1.2.0
mkdir -p "$case_dir/homebrew/opt"
ln -s "$case_dir/homebrew/Cellar/yt-dlp/2026.10.21" "$case_dir/homebrew/opt/yt-dlp"
: > "$case_dir/brew.log"
python_sites="$(printf 'brew-formula\t%s\t/x/python\nbrew-formula\t%s\t/x/python' "$old_site" "$new_site")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_count 'リンクされている版だけが古いときは WARN 1件' "$case_dir/output.txt" 'WARN  Python（Homebrew の yt-dlp）の brotli 1\.2\.0' 1

case_dir="$TEST_TMP/brew-formula-pip-old"
fake_bin="$case_dir/fake-bin"
site="$case_dir/homebrew/Cellar/sample-tool/1.0.0/libexec/lib/python3.15/site-packages"
make_fake_brew "$fake_bin"
make_python_site "$site" 26.2.1 2026.10.19
: > "$case_dir/brew.log"
python_sites="$(printf 'brew-formula\t%s\t/x/python' "$site")"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_PYTHON_SITE_DIRS="$python_sites"
assert_contains 'formula 専用の環境の古い pip も今の決まりで見る（直し方は brew upgrade <formula>）' "$case_dir/output.txt" 'WARN  Python（Homebrew の sample-tool）の pip 26\.2\.1 は修正版 26\.2\.2 より古い版です.*直し方: brew upgrade sample-tool'

# RH_PYTHON_SITE_DIRS を unset にして、候補の場所を実際に探させる（Homebrew の prefix は偽の brew が返す）
run_security_discover() {
  local case_dir="$1" fake_bin="$2" output
  shift 2
  output="$case_dir/output.txt"
  mkdir -p "$case_dir/home" "$case_dir/root"
  env -u RH_PYTHON_SITE_DIRS PATH="$fake_bin:$PATH" HOME="$case_dir/home" \
    RH_CONFIG_FILE="$case_dir/no-config.sh" RH_ROOTS="$case_dir/root" \
    RH_LOG_DIR="$case_dir/log" RH_STATE_DIR="$case_dir/state" \
    RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_SKIP_SECURITY=0 \
    RH_AUTOFIX_PULL=0 RH_MAIL_METHOD=none RH_NOMAIL=1 RH_NO_DESKTOP=1 \
    RH_TLS_PROBE=0 RH_SKIP_SOFTWAREUPDATE=1 RH_KIT_UPDATE_CHECK=0 \
    RH_NODE_CANDIDATES= RH_JAVA_CANDIDATES= RH_DOCKER="$fake_bin/missing-docker" \
    RH_MACOS_VERSION=27.0.1 RH_CLAUDE_CANDIDATES= RH_APP_DIRS="$case_dir/no-apps" RH_BREW="$fake_bin/brew" \
    RH_UV_CANDIDATES= RH_BUN_CANDIDATES= RH_SKIP_SOFTWARE=1 \
    "$@" "$TEST_BASH" "$HEALTH" > "$output" 2>&1 || true
}

case_dir="$TEST_TMP/brew-formula-discover-old"
fake_bin="$case_dir/fake-bin"
prefix="$case_dir/homebrew"
make_fake_brew "$fake_bin"
make_dist_info "$prefix/Cellar/yt-dlp/2026.10.21/libexec/lib/python3.15/site-packages" brotli 1.2.0
mkdir -p "$prefix/opt"
ln -s "$prefix/Cellar/yt-dlp/2026.10.21" "$prefix/opt/yt-dlp"
: > "$case_dir/brew.log"
run_security_discover "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_PREFIX="$prefix"
assert_contains 'Cellar の formula 専用の環境を実際に探して古い brotli を WARN にする' "$case_dir/output.txt" 'WARN  Python（Homebrew の yt-dlp）の brotli 1\.2\.0 は修正版 1\.2\.1 より古い版です.*brew upgrade yt-dlp'

case_dir="$TEST_TMP/brew-formula-discover-unlinked"
fake_bin="$case_dir/fake-bin"
prefix="$case_dir/homebrew"
make_fake_brew "$fake_bin"
make_dist_info "$prefix/Cellar/yt-dlp/2026.9.1/libexec/lib/python3.15/site-packages" brotli 1.2.0
make_dist_info "$prefix/Cellar/yt-dlp/2026.10.21/libexec/lib/python3.15/site-packages" brotli 1.2.1
mkdir -p "$prefix/opt"
ln -s "$prefix/Cellar/yt-dlp/2026.10.21" "$prefix/opt/yt-dlp"
: > "$case_dir/brew.log"
run_security_discover "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_PREFIX="$prefix"
assert_not_contains 'Cellar を探すときもリンクされていない古い版は見ない' "$case_dir/output.txt" 'WARN  Python（Homebrew の yt-dlp）'
assert_contains 'Cellar を探すときリンクされている版は見る' "$case_dir/output.txt" 'Python（Homebrew の yt-dlp）の brotli 1\.2\.1 — 最低版 1\.2\.1 以上'

# --- Bun ---

case_dir="$TEST_TMP/bun-old"
fake_bin="$case_dir/fake-bin"
bun_path="$case_dir/home/.bun/bin/bun"
make_fake_brew "$fake_bin"
make_fake_bun "$bun_path"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_BUN_CANDIDATES="$bun_path" FAKE_BUN_OUTPUT='1.3.11'
assert_contains 'Bun 1.3.11 は修正版 1.4.4 より古い WARN' "$case_dir/output.txt" 'WARN  Bun 1\.3\.11（.*\.bun/bin/bun」）は修正版 1\.4\.4 より古い版です（CVE-2026-111497'
assert_contains '.bun/bin/bun の WARN は bun upgrade を案内する' "$case_dir/output.txt" 'bun upgrade で更新してください'

case_dir="$TEST_TMP/bun-fixed"
fake_bin="$case_dir/fake-bin"
bun_path="$case_dir/home/.bun/bin/bun"
make_fake_brew "$fake_bin"
make_fake_bun "$bun_path"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_BUN_CANDIDATES="$bun_path" FAKE_BUN_OUTPUT='1.4.4'
assert_not_contains 'Bun 1.4.4 は要対応に出さない' "$case_dir/output.txt" '(WARN|FAIL)  Bun '
assert_contains '修正版の Bun は最低版以上の detail を出す' "$case_dir/output.txt" 'Bun 1\.4\.4（.*）— 最低版 1\.4\.4 以上'

case_dir="$TEST_TMP/bun-unknown"
fake_bin="$case_dir/fake-bin"
bun_path="$case_dir/bin/bun"
make_fake_brew "$fake_bin"
make_fake_bun "$bun_path"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_BUN_CANDIDATES="$bun_path" FAKE_BUN_OUTPUT=''
assert_contains '版を返さない Bun は未検査の NOTES' "$case_dir/output.txt" 'Bun（.*bin/bun」）— 版を判定できず未検査'
assert_not_contains '版を返さない Bun は WARN にしない' "$case_dir/output.txt" '(WARN|FAIL)  Bun '

case_dir="$TEST_TMP/bun-cellar"
fake_bin="$case_dir/fake-bin"
bun_path="$case_dir/Cellar/bun/1.3.11/bin/bun"
make_fake_brew "$fake_bin"
make_fake_bun "$bun_path"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_BUN_CANDIDATES="$bun_path" FAKE_BUN_OUTPUT='1.3.11'
assert_contains 'Homebrew の古い Bun は brew upgrade bun を案内する' "$case_dir/output.txt" 'WARN  Bun 1\.3\.11（.*）は修正版 1\.4\.4 より古い版です.*brew upgrade bun'

case_dir="$TEST_TMP/bun-other"
fake_bin="$case_dir/fake-bin"
bun_path="$case_dir/tools/bun"
make_fake_brew "$fake_bin"
make_fake_bun "$bun_path"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_BUN_CANDIDATES="$bun_path" FAKE_BUN_OUTPUT='1.3.11'
assert_contains '入れた方法が分からない Bun は入れた方法での更新を案内する' "$case_dir/output.txt" 'WARN  Bun 1\.3\.11（.*）は修正版 1\.4\.4 より古い版です.*入れた方法で更新してください'

case_dir="$TEST_TMP/bun-symlink"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_bun "$case_dir/real/bun"
mkdir -p "$fake_bin"
ln -s "$case_dir/real/bun" "$fake_bin/bun"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BUN_OUTPUT='1.3.11' \
  RH_BUN_CANDIDATES="$fake_bin/bun
$case_dir/real/bun"
assert_count '同じ実体の Bun は 1 度だけ見る' "$case_dir/output.txt" 'WARN  Bun 1\.3\.11' 1

case_dir="$TEST_TMP/bun-minimums-missing"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SECURITY_MINIMUMS="$case_dir/missing-minimums.tsv"
assert_contains '最低版表が無いときは Bun 点検不足の NOTES' "$case_dir/output.txt" 'Bun の最低版は同梱リスト不足のため未検査'
assert_contains '最低版表が無いときは Electron 点検不足の NOTES' "$case_dir/output.txt" 'Electron 製アプリの更新確認は同梱リスト不足のため未検査'

# --- Electron 製のアプリ（参考だけ） ---

case_dir="$TEST_TMP/electron-old"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_electron_app "$apps" 'Slack' com.tinyspeck.slackmacgap 4.50.0 202610011200 1
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps"
assert_count '基準日より前の Electron 製アプリは NOTES 1件' "$case_dir/output.txt" 'Slack 4\.50\.0（2026-10-01 更新）は、Brotli の修正（2026-10-21）より前の版のままかもしれません' 1
assert_contains 'Electron の NOTES に更新の案内を含める' "$case_dir/output.txt" 'アプリの「更新を確認」で最新にしてください'
assert_not_contains 'Electron 製アプリは WARN にしない' "$case_dir/output.txt" '(WARN|FAIL)  .*Slack'

case_dir="$TEST_TMP/electron-new"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_electron_app "$apps" 'Slack' com.tinyspeck.slackmacgap 4.51.0 202610231200 1
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps"
assert_not_contains '基準日より後に更新された Electron 製アプリは NOTES に出さない' "$case_dir/output.txt" 'Slack .*より前の版のままかもしれません'

case_dir="$TEST_TMP/electron-not-electron"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_electron_app "$apps" 'Plain' com.example.plain 1.0.0 202610011200 0
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps"
assert_not_contains 'Electron でないアプリは NOTES に出さない' "$case_dir/output.txt" 'Plain .*より前の版のままかもしれません'

case_dir="$TEST_TMP/electron-several"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_electron_app "$apps" 'Discord' com.hnc.Discord 0.0.350 202610051200 1
make_fake_electron_app "$apps" 'Obsidian' md.obsidian 1.9.0 202610301200 1
make_fake_electron_app "$apps/入れ子" '1Password' com.1password.1password 8.11.0 202609151200 1
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps"
assert_count '古い Electron 製アプリだけを 1 件ずつ NOTES に出す' "$case_dir/output.txt" 'より前の版のままかもしれません' 2
assert_contains '入れ子のフォルダの Electron 製アプリも見る' "$case_dir/output.txt" '1Password 8\.11\.0（2026-09-15 更新）は、Brotli の修正'

case_dir="$TEST_TMP/electron-table-date"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
minimums="$case_dir/minimums.tsv"
make_fake_brew "$fake_bin"
make_fake_electron_app "$apps" 'Slack' com.tinyspeck.slackmacgap 4.51.0 202610231200 1
printf 'electron-after\t*\t2026-10-30\tテスト用\n' > "$minimums"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps" RH_SECURITY_MINIMUMS="$minimums"
assert_contains '基準日は判定表の electron-after から読む' "$case_dir/output.txt" 'Slack 4\.51\.0（2026-10-23 更新）は、Brotli の修正（2026-10-30）より前の版のままかもしれません'

case_dir="$TEST_TMP/electron-no-date-row"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
minimums="$case_dir/minimums.tsv"
make_fake_brew "$fake_bin"
make_fake_electron_app "$apps" 'Slack' com.tinyspeck.slackmacgap 4.50.0 202610011200 1
printf 'app:com.example.sample\t*\t2.0.0\tテスト用\n' > "$minimums"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_APP_DIRS="$apps" RH_SECURITY_MINIMUMS="$minimums"
assert_contains '判定表に基準日が無いときは未検査の NOTES' "$case_dir/output.txt" 'Electron 製アプリの更新確認は判定表に基準日（electron-after）が無いため未検査'
assert_not_contains '基準日が無いときは Slack の NOTES を出さない' "$case_dir/output.txt" 'Slack .*より前の版のままかもしれません'

# --- 0.5.0: 入っているソフトの更新点検 ---

case_dir="$TEST_TMP/software-brew"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
catalog="$case_dir/catalog.json"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
make_fake_app "$apps" 'Old App' com.example.old 1.0.0
make_fake_app "$apps" 'Self App' com.example.self 2.0.0
printf '[]\n' > "$catalog"
: > "$case_dir/brew.log"
brew_json='{"formulae":[{"name":"rclone","installed_versions":["1.74.3"],"current_version":"1.75.2"},{"name":"pinned-tool","installed_versions":["1.0.0"],"current_version":"2.0.0","pinned":true}],"casks":[{"name":"old-app","installed_versions":["1.0.0"],"current_version":"2.0.0"},{"name":"self-app","installed_versions":["1.0.0"],"current_version":"2.0.0"},{"name":"ghost-app","installed_versions":["1.0.0"],"current_version":"2.0.0"},{"name":"latest-app","installed_versions":["latest"],"current_version":"latest"}]}'
cask_info='{"formulae":[],"casks":[{"token":"old-app","auto_updates":true,"artifacts":[{"app":["Old App.app"]}]},{"token":"self-app","auto_updates":true,"artifacts":[{"app":["Self App.app"]}]},{"token":"ghost-app","auto_updates":false,"artifacts":[{"app":["Ghost App.app"]}]}]}'
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 \
  RH_APP_DIRS="$apps" RH_CASK_CATALOG="$catalog" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_JSON="$brew_json" FAKE_BREW_CASK_INFO_JSON="$cask_info"
assert_contains 'Homebrew の更新は formula と古い GUI cask の2件' "$case_dir/output.txt" 'ソフト更新あり: 2件'
assert_contains 'formula の更新を参考欄に出す' "$case_dir/output.txt" 'ソフト更新: Homebrew rclone 1\.74\.3 → 1\.75\.2（brew upgrade rclone）'
assert_contains '古い GUI cask の更新を参考欄に出す' "$case_dir/output.txt" 'ソフト更新: Homebrew のアプリ old-app 1\.0\.0 → 2\.0\.0'
assert_contains 'アプリが無い cask は記録だけの NOTES' "$case_dir/output.txt" 'ghost-app は Homebrew の記録だけ残っています（アプリは見当たりません）'
assert_not_contains '自己更新済み cask はソフト更新に数えない' "$case_dir/output.txt" 'ソフト更新: .*self-app'
assert_not_contains 'latest と pinned はソフト更新に数えない' "$case_dir/output.txt" 'ソフト更新: .*(latest-app|pinned-tool)'

case_dir="$TEST_TMP/software-catalog"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
catalog="$case_dir/catalog.json"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
make_fake_app "$apps" 'Named App' com.example.named '7.1.9 (88375)'
make_fake_app "$apps" 'Bundle App' com.example.bundle 1.0.0
make_fake_app "$apps" 'Store App' com.example.store 1.0.0
mkdir -p "$apps/Store App.app/Contents/_MASReceipt"
make_fake_app "$apps" 'Apple App' com.apple.sample 1.0.0
make_fake_app "$apps" 'Unknown App' com.example.unknown 1.0.0
make_fake_app "$apps" 'Deleted App' com.example.deleted 1.0.0
make_fake_app "$apps" 'Office App' com.example.office 16.114.1 16.114.26102031
make_fake_app "$apps" 'Chrome App' com.example.chrome 156.0.8078.48 8078.48
printf '%s\n' '[{"token":"office-token","version":"16.114.26102031","artifacts":[{"app":["Office App.app"]}]},{"token":"chrome-token","version":"156.0.8078.49","artifacts":[{"app":["Chrome App.app"]}]},{"token":"named-token","version":"7.2.2.88465","artifacts":[{"app":["Named App.app"]}]},{"token":"bundle-token","version":"2.0.0","artifacts":[{"uninstall":[{"quit":"com.example.bundle"}]}]},{"token":"store-token","version":"2.0.0","artifacts":[{"app":["Store App.app"]}]},{"token":"apple-token","version":"2.0.0","artifacts":[{"app":["Apple App.app"]}]},{"token":"deleted-token","version":"2.0.0","artifacts":[{"pkg":["Deleted.pkg"]},{"uninstall":[{"signal":["KILL","com.example.deleted"],"delete":["/Applications/Deleted App.app","/Library/Deleted"]}]}]}]' > "$catalog"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 \
  RH_APP_DIRS="$apps" RH_CASK_CATALOG="$catalog" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_JSON='{"formulae":[],"casks":[]}'
assert_contains 'cask 目録はアプリ名で照合する' "$case_dir/output.txt" 'ソフト更新: アプリ Named App 7\.1\.9 \(88375\) → 7\.2\.2\.88465'
assert_contains 'cask 目録は bundle ID でも照合する' "$case_dir/output.txt" 'ソフト更新: アプリ Bundle App 1\.0\.0 → 2\.0\.0'
assert_not_contains 'App Store と Apple 純正アプリは目録比較から外す' "$case_dir/output.txt" 'ソフト更新: アプリ (Store App|Apple App)'
assert_not_contains '目録に当たらないアプリは更新扱いしない' "$case_dir/output.txt" 'ソフト更新: アプリ Unknown App'
assert_contains 'cask 目録は削除対象のアプリ名でも照合する（zoom 型）' "$case_dir/output.txt" 'ソフト更新: アプリ Deleted App 1\.0\.0 → 2\.0\.0'
assert_not_contains '表示版とビルドの書式が違うアプリはビルドで比べる（Office 型）' "$case_dir/output.txt" 'ソフト更新: アプリ Office App'
assert_contains '表示版と頭の揃わないビルドは比較に使わない（Chrome 型）' "$case_dir/output.txt" 'ソフト更新: アプリ Chrome App 156\.0\.8078\.48 → 156\.0\.8078\.49'

case_dir="$TEST_TMP/software-pkg-cask"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
catalog="$case_dir/catalog.json"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
make_fake_app "$apps" 'Pkg App' com.example.pkg 1.0.0
printf '[]\n' > "$catalog"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_AUTOFIX_SOFTWARE=1 \
  RH_APP_DIRS="$apps" RH_CASK_CATALOG="$catalog" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_JSON='{"formulae":[],"casks":[{"name":"pkg-app","installed_versions":["1.0.0"],"current_version":"2.0.0"},{"name":"pkg-only","installed_versions":["1.0.0"],"current_version":"2.0.0"}]}' \
  FAKE_BREW_CASK_INFO_JSON='{"formulae":[],"casks":[{"token":"pkg-app","auto_updates":false,"artifacts":[{"pkg":["Pkg.pkg"]},{"uninstall":[{"delete":["/Applications/Pkg App.app"]}]}]},{"token":"pkg-only","auto_updates":false,"artifacts":[{"installer":[{"script":"install.sh"}]}]}]}'
assert_contains 'pkg 形式の cask はアプリとして出す' "$case_dir/output.txt" 'ソフト更新: Homebrew のアプリ pkg-app 1\.0\.0 → 2\.0\.0'
assert_contains 'アプリ名の無い pkg 形式も記録だけと言い切らない' "$case_dir/output.txt" 'ソフト更新: Homebrew のアプリ pkg-only 1\.0\.0 → 2\.0\.0'
assert_not_contains 'pkg 形式の cask は自動更新しない' "$case_dir/brew.log" 'upgrade'

case_dir="$TEST_TMP/software-catalog-missing"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
make_fake_app "$apps" 'Plain App' com.example.plain 1.0.0
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 \
  RH_APP_DIRS="$apps" RH_CASK_CATALOG="$case_dir/missing-catalog.json" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_JSON='{"formulae":[],"casks":[]}'
assert_contains 'cask 目録が無ければアプリ更新確認を未検査にする' "$case_dir/output.txt" 'Homebrew で入れていないアプリの更新確認は未検査（目録を取得できません）'

case_dir="$TEST_TMP/software-mas"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
make_fake_mas "$fake_bin/mas"
make_fake_app "$apps" 'Store App' com.example.store 2.3.0
mkdir -p "$apps/Store App.app/Contents/_MASReceipt"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 \
  RH_APP_DIRS="$apps" RH_MAS="$fake_bin/mas" FAKE_MAS_OUTDATED='123  Store App  (2.3.0 -> 2.3.2)\n' \
  FAKE_BREW_JSON='{"formulae":[],"casks":[]}'
assert_contains 'mas outdated を App Store の更新として出す' "$case_dir/output.txt" 'ソフト更新: App Store Store App 2\.3\.0 → 2\.3\.2'
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 \
  RH_APP_DIRS="$apps" RH_MAS="$fake_bin/missing-mas" FAKE_BREW_JSON='{"formulae":[],"casks":[]}'
assert_contains 'mas が無ければ App Store アプリ件数を未検査にする' "$case_dir/output.txt" 'App Store のアプリ 1 件は未検査'

case_dir="$TEST_TMP/software-npm"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
: > "$case_dir/brew.log"
npm_outdated='{"oldpkg":{"current":"1.0.0","latest":"3.0.0"},"youngpkg":{"current":"1.0.0","latest":"2.0.0"}}'
old_times='{"1.0.0":"2020-01-01T00:00:00Z","2.0.0":"2020-01-02T00:00:00Z","3.0.0":"2999-01-01T00:00:00Z"}'
young_times='{"1.0.0":"2020-01-01T00:00:00Z","2.0.0":"2999-01-01T00:00:00Z"}'
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_JSON='{"formulae":[],"casks":[]}' FAKE_NPM_OUTDATED_JSON="$npm_outdated" \
  FAKE_NPM_OLD_TIME_JSON="$old_times" FAKE_NPM_YOUNG_TIME_JSON="$young_times"
assert_contains 'npm は公開3日以上の一つ前の版を上げ先にする' "$case_dir/output.txt" 'ソフト更新: npm oldpkg 1\.0\.0 → 2\.0\.0（npm i -g oldpkg@2\.0\.0'
assert_contains 'npm の最新が3日未満なら待つ旨を添える' "$case_dir/output.txt" '最新 3\.0\.0 は .*公開・3 日待ち'
assert_not_contains '3日未満の版しかない npm は更新に数えない' "$case_dir/output.txt" 'ソフト更新: npm youngpkg'
assert_contains '3日未満の版しかない npm は detail に残す' "$case_dir/output.txt" 'youngpkg の最新 2\.0\.0 は公開から 3 日たっていないので待ちます'

# Homebrew の node に付いてくる npm は、npm i -g で上げても node の更新で戻るので、更新待ちに数えない
for bundled in 1 0; do
  case_dir="$TEST_TMP/software-npm-homebrew-bundled-$bundled"
  fake_bin="$case_dir/fake-bin"
  hb="$case_dir/homebrew"
  make_fake_brew "$fake_bin"
  make_fake_software_npm "$fake_bin"
  mkdir -p "$hb/lib/node_modules/npm" "$case_dir/state"
  if [ "$bundled" = 1 ]; then
    mkdir -p "$hb/opt/node/libexec/lib/node_modules/npm"
    printf '%s\n' '{"name":"npm","version":"11.20.0"}' > "$hb/opt/node/libexec/lib/node_modules/npm/package.json"
  fi
  printf 'npm:npm\t2026-10-10\n' > "$case_dir/state/software-outdated.tsv"
  : > "$case_dir/brew.log"
  run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_TODAY=2026-10-25 \
    RH_MAS="$fake_bin/missing-mas" FAKE_BREW_JSON='{"formulae":[],"casks":[]}' FAKE_BREW_PREFIX="$hb" \
    FAKE_NPM_ROOT="$hb/lib/node_modules" FAKE_NPM_OUTDATED_JSON='{"npm":{"current":"11.20.0","latest":"12.2.3"}}' \
    FAKE_NPM_TIME_JSON='{"11.20.0":"2020-01-01T00:00:00Z","12.2.3":"2020-02-01T00:00:00Z"}'
  if [ "$bundled" = 1 ]; then
    assert_not_contains 'Homebrew の node に付いてくる npm は日数の WARN にしない' "$case_dir/output.txt" 'npm の更新が .* 日止まっています'
    assert_not_contains 'Homebrew の node に付いてくる npm はソフト更新に数えない' "$case_dir/output.txt" 'ソフト更新: npm npm'
    assert_contains 'Homebrew の node に付いてくる npm は detail に理由を残す' "$case_dir/output.txt" 'npm 11\.20\.0 は Homebrew の node に付いてくる版です.*最新 12\.2\.3'
    assert_not_contains 'Homebrew の node に付いてくる npm は状態ファイルから外す' "$case_dir/state/software-outdated.tsv" '^npm:npm'
  else
    assert_contains 'node が npm を同梱していなければ今までどおり日数の WARN にする' "$case_dir/output.txt" 'WARN  npm の更新が 15 日止まっています 11\.20\.0 → 12\.2\.3'
  fi
done

# CLI の確認でも、Homebrew の node に付いてくる npm はメジャー版遅れの WARN・自動更新にしない
for bundled in 1 0; do
  case_dir="$TEST_TMP/cli-npm-homebrew-bundled-$bundled"
  fake_bin="$case_dir/fake-bin"
  hb="$case_dir/homebrew"
  make_fake_brew "$fake_bin"
  make_fake_cli_set "$fake_bin"
  make_fake_claude "$fake_bin/claude"
  mkdir -p "$hb/lib/node_modules/npm/bin"
  if [ "$bundled" = 1 ]; then
    mkdir -p "$hb/opt/node/libexec/lib/node_modules/npm"
    printf '%s\n' '{"name":"npm","version":"11.20.0"}' > "$hb/opt/node/libexec/lib/node_modules/npm/package.json"
  fi
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'if [ "${1:-}" = "view" ]; then printf "%s\n" '\''{"time":{"11.20.0":"2020-01-01T00:00:00.000Z","12.2.3":"2020-02-01T00:00:00.000Z"},"versions":["11.20.0","12.2.3"],"dist-tags":{"latest":"12.2.3"}}'\''; exit 0; fi'
    printf '%s\n' 'if [ "${1:-}" = "install" ]; then printf "%s\n" "$*" >> "${FAKE_NPM_INSTALL_LOG:?}"; exit 0; fi'
    printf '%s\n' 'printf "%s\n" "11.20.0"'
  } > "$hb/lib/node_modules/npm/bin/npm-cli.js"
  chmod +x "$hb/lib/node_modules/npm/bin/npm-cli.js"
  rm -f "$fake_bin/npm" "$fake_bin/npm-fixture"
  ln -s "$hb/lib/node_modules/npm/bin/npm-cli.js" "$fake_bin/npm"
  : > "$case_dir/brew.log"
  : > "$case_dir/install.log"
  run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_CLI=0 RH_AUTOFIX_CLI=1 \
    FAKE_BREW_PREFIX="$hb" FAKE_NPM_INSTALL_LOG="$case_dir/install.log" \
    RH_CLAUDE_CANDIDATES="$fake_bin/claude" FAKE_CLAUDE_OUTPUT='2.1.250 (Claude Code)' FAKE_CLAUDE_LATEST=2.1.250
  if [ "$bundled" = 1 ]; then
    assert_contains 'CLI: Homebrew の node に付いてくる npm は更新ありの一覧に理由つきで出す' "$case_dir/output.txt" 'npm — 11\.20\.0 → 12\.2\.3（Homebrew の node に付いてくる版です'
    assert_not_contains 'CLI: Homebrew の node に付いてくる npm はメジャー版遅れの WARN にしない' "$case_dir/output.txt" 'npm — メジャー版が遅れています'
    assert_not_contains 'CLI: Homebrew の node に付いてくる npm は自動更新しない' "$case_dir/install.log" 'npm@'
  else
    assert_contains 'CLI: node が npm を同梱していなければ今までどおり自動更新する' "$case_dir/install.log" 'install -g npm@12\.2\.3'
  fi
done

case_dir="$TEST_TMP/software-stale-15"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
mkdir -p "$case_dir/state"
printf 'formula:rclone\t2026-10-10\n' > "$case_dir/state/software-outdated.tsv"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_TODAY=2026-10-25 \
  RH_MAS="$fake_bin/missing-mas" FAKE_BREW_JSON='{"formulae":[{"name":"rclone","installed_versions":["1.74.3"],"current_version":"1.75.2"}],"casks":[]}'
assert_contains '15日止まったソフト更新は WARN' "$case_dir/output.txt" 'WARN  rclone の更新が 15 日止まっています 1\.74\.3 → 1\.75\.2'

case_dir="$TEST_TMP/software-stale-13"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
mkdir -p "$case_dir/state"
printf 'formula:rclone\t2026-10-12\n' > "$case_dir/state/software-outdated.tsv"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_TODAY=2026-10-25 \
  RH_MAS="$fake_bin/missing-mas" FAKE_BREW_JSON='{"formulae":[{"name":"rclone","installed_versions":["1.74.3"],"current_version":"1.75.2"}],"casks":[]}'
assert_not_contains '13日のソフト更新は WARN にしない' "$case_dir/output.txt" 'WARN  rclone の更新が'
assert_contains '13日のソフト更新は参考欄に残す' "$case_dir/output.txt" 'ソフト更新: Homebrew rclone 1\.74\.3 → 1\.75\.2'
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_TODAY=2026-10-26 \
  RH_MAS="$fake_bin/missing-mas" FAKE_BREW_JSON='{"formulae":[],"casks":[]}'
assert_not_contains '遅れが消えた項目は状態ファイルから消す' "$case_dir/state/software-outdated.tsv" 'formula:rclone'

# 自分で上がるアプリ（Chrome 型）は Homebrew の記録が古いまま残る。表示と日数はアプリの実物の版で見る
case_dir="$TEST_TMP/software-stale-self-updating-cask"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
catalog="$case_dir/catalog.json"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
make_fake_app "$apps" 'Google Chrome' com.google.Chrome 158.0.8127.88
printf '[]\n' > "$catalog"
mkdir -p "$case_dir/state"
printf 'cask:google-chrome\t2026-11-11\n' > "$case_dir/state/software-outdated.tsv"
: > "$case_dir/brew.log"
brew_json='{"formulae":[],"casks":[{"name":"google-chrome","installed_versions":["156.0.8078.48"],"current_version":"158.0.8127.89"}]}'
cask_info='{"formulae":[],"casks":[{"token":"google-chrome","auto_updates":true,"artifacts":[{"app":["Google Chrome.app"]}]}]}'
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_TODAY=2026-11-25 \
  RH_APP_DIRS="$apps" RH_CASK_CATALOG="$catalog" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_JSON="$brew_json" FAKE_BREW_CASK_INFO_JSON="$cask_info"
assert_not_contains 'アプリが上がっていれば記録の古さの日数で WARN にしない' "$case_dir/output.txt" 'WARN  google-chrome の更新が'
assert_contains '自分で上がるアプリはアプリの実物の版を出す' "$case_dir/output.txt" 'ソフト更新: Homebrew のアプリ google-chrome 158\.0\.8127\.88 → 158\.0\.8127\.89'
assert_contains '日数はアプリの実物の版ごとに数える' "$case_dir/state/software-outdated.tsv" '^cask:google-chrome@158\.0\.8127\.88	2026-11-25$'
printf 'cask:google-chrome@158.0.8127.88\t2026-11-10\n' > "$case_dir/state/software-outdated.tsv"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_TODAY=2026-11-25 \
  RH_APP_DIRS="$apps" RH_CASK_CATALOG="$catalog" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_JSON="$brew_json" FAKE_BREW_CASK_INFO_JSON="$cask_info"
assert_contains 'アプリの実物の版が 15 日止まっていれば WARN' "$case_dir/output.txt" 'WARN  google-chrome の更新が 15 日止まっています 158\.0\.8127\.88 → 158\.0\.8127\.89'

case_dir="$TEST_TMP/software-autofix"
fake_bin="$case_dir/fake-bin"
apps="$case_dir/apps"
catalog="$case_dir/catalog.json"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
make_fake_app "$apps" 'Old App' com.example.old 1.0.0
printf '[]\n' > "$catalog"
: > "$case_dir/brew.log"
brew_json='{"formulae":[{"name":"rclone","installed_versions":["1.74.3"],"current_version":"1.75.2"}],"casks":[{"name":"old-app","installed_versions":["1.0.0"],"current_version":"2.0.0"}]}'
cask_info='{"formulae":[],"casks":[{"token":"old-app","auto_updates":false,"artifacts":[{"app":["Old App.app"]}]}]}'
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_AUTOFIX_SOFTWARE=1 \
  RH_APP_DIRS="$apps" RH_CASK_CATALOG="$catalog" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_JSON="$brew_json" FAKE_BREW_AFTER_JSON='{"formulae":[],"casks":[]}' FAKE_BREW_CASK_INFO_JSON="$cask_info"
assert_contains '自動更新は formula を名指しする' "$case_dir/brew.log" '^upgrade --formula rclone$'
assert_contains '自動更新は Homebrew cleanup を止める' "$case_dir/brew.log" '^cleanup=1$'
assert_not_contains 'GUI の cask は自動更新しない' "$case_dir/brew.log" '^upgrade --cask old-app$'
assert_contains '上がった formula は自動修復へ出す' "$case_dir/output.txt" 'Homebrew: rclone 1\.74\.3 → 1\.75\.2'
assert_not_contains '上がった formula はソフト更新一覧から消す' "$case_dir/output.txt" 'ソフト更新: Homebrew rclone'

case_dir="$TEST_TMP/software-skip"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 \
  RH_MAS="$fake_bin/missing-mas" RH_SOFTWARE_SKIP_TOOLS='gh' RH_SOFTWARE_IGNORE='foo' \
  FAKE_BREW_JSON='{"formulae":[{"name":"gh","installed_versions":["1.0.0"],"current_version":"2.0.0"},{"name":"foo","installed_versions":["1.0.0"],"current_version":"2.0.0"}],"casks":[]}'
assert_not_contains 'RH_SOFTWARE_SKIP_TOOLS の formula は出さない' "$case_dir/output.txt" 'ソフト更新: Homebrew gh '
assert_not_contains 'RH_SOFTWARE_IGNORE の formula は出さない' "$case_dir/output.txt" 'ソフト更新: Homebrew foo '
assert_contains 'skip と ignore 後は更新0件' "$case_dir/output.txt" 'ソフト更新あり: 0件'

case_dir="$TEST_TMP/software-auto-cli-skip"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_cli_set "$fake_bin"
make_fake_claude "$fake_bin/claude"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_SKIP_CLI=0 \
  RH_MAS="$fake_bin/missing-mas" FAKE_CLAUDE_OUTPUT='1.0.0' FAKE_CLAUDE_LATEST=1.0.0 \
  FAKE_BREW_JSON='{"formulae":[{"name":"gh","installed_versions":["1.0.0"],"current_version":"2.0.0"}],"casks":[]}'
assert_not_contains '通常モードでは CLI 点検対象をソフト更新から自動で外す' "$case_dir/output.txt" 'ソフト更新: Homebrew gh '

case_dir="$TEST_TMP/software-security-only"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_SECURITY_ONLY=1 \
  RH_MAS="$fake_bin/missing-mas" FAKE_BREW_JSON='{"formulae":[{"name":"rclone","installed_versions":["1.74.3"],"current_version":"1.75.2"}],"casks":[]}'
assert_contains 'security-only の参考見出しにソフト更新を含める' "$case_dir/output.txt" '## ③ 参考（Mac のセキュリティ・ソフト更新）'
assert_contains 'security-only にソフト更新件数を出す' "$case_dir/output.txt" 'ソフト更新あり: 1件'
assert_contains 'security-only にソフト更新行を出す' "$case_dir/output.txt" 'ソフト更新: Homebrew rclone'

case_dir="$TEST_TMP/cli-three-day-target"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_cli_set "$fake_bin"
make_fake_claude "$fake_bin/claude"
: > "$case_dir/brew.log"
claude_times='{"2.1.250":"2020-01-01T00:00:00Z","2.1.300":"2020-01-02T00:00:00Z","2.1.310":"2999-01-01T00:00:00Z"}'
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_CLI=0 \
  RH_CLAUDE_CANDIDATES="$fake_bin/claude" FAKE_CLAUDE_OUTPUT='2.1.250' FAKE_CLAUDE_LATEST=2.1.310 \
  FAKE_CLAUDE_TIME_JSON="$claude_times"
assert_contains 'CLI の上げ先は公開3日以上の版にする' "$case_dir/output.txt" 'claude 2\.1\.250 → 2\.1\.300.*（最新 2\.1\.310 は .*公開・3 日待ち）'

# ---- 0.6.0: 見逃し・更新の巻き込み・点検の継続 ----

run_k1_case() {
  local case_dir="$1" root="$2" fake_bin="$3"
  shift 3
  mkdir -p "$case_dir/home" "$case_dir/state"
  env PATH="$fake_bin:$PATH" HOME="$case_dir/home" \
    RH_CONFIG_FILE="$case_dir/no-config.sh" RH_ROOTS="$root" \
    RH_LOG_DIR="$case_dir/log" RH_STATE_DIR="$case_dir/state" \
    RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_SKIP_SECURITY=1 \
    RH_SKIP_SOFTWARE=1 RH_AUTOFIX_PULL=0 RH_MAIL_METHOD=none RH_NOMAIL=1 RH_NO_DESKTOP=1 \
    "$@" "$TEST_BASH" "$HEALTH" > "$case_dir/output.txt" 2>&1
  RUN_RC=$?
}

# JWT はこの場で作った署名なしの試験用データだけを使います。
case_dir="$TEST_TMP/k1-secrets"
make_remote_repo "$case_dir" secrets
python3 - "$REPO_PATH" <<'PY'
import base64
import json
import sys
from pathlib import Path
repo = Path(sys.argv[1])
def jwt(role):
    payload = base64.urlsafe_b64encode(json.dumps({"role": role}).encode()).decode().rstrip("=")
    return "eyJhbGciOiJIUzI1NiJ9." + payload + ".fixture"
for name in (".env.local", ".env.production"):
    (repo / name).write_text("SUPABASE_SERVICE_ROLE_KEY=" + jwt("service_role") + "\n")
(repo / "anon.ts").write_text("const publicToken = '" + jwt("anon") + "';\n")
(repo / ".env.example").write_text("EMPTY=\nREF=op://fixture/item/field\nSAMPLE=<value>\nKEY=your-key\n")
(repo / ".env.sample").write_text("KEY=" + "sb_secret_" + "Fk3jQ9zLm2Pq8RtW5vXy7BnC" + "\n")
(repo / "types.ts").write_text("\n".join([
    "sb_secret_" + "Fk3jQ9zLm2Pq8RtW5vXy7BnC",
    "re_" + "Ab3dE6gH" + "_" + "Jk9mN2pQ5sT8vW1yZ4bC7eF0",
    "AKIA" + "Q3ZK7RWM2XPL9TBV",
    "github_pat_" + "11AbCdEfGh2IjKlMnOp3Qr" + "_" + "St4UvWxYz5AbCdEfGh6IjKlMnOp7QrStUvWx8YzAbCdEf9GhIjKlMnOpQ0rStUv",
    "GOCSPX-" + "Fk3jQ9zLm2Pq8RtW5vXy7Bn",
    "postgresql://fixture:" + "Zq8vK2mN7pR4tW" + "@db.fixture.invalid/db",
]))
(repo / "samples.md").write_text("\n".join([
    "store_credentials_for_everyone_in_the_list = 1",
    "RESEND_API_KEY=re_xxxxxxxx_xxxxxxxxxxxxxxxxxxxxxxxx",
    "postgresql://postgres:[YOUR-PASSWORD]@db.abcdefghijklmnopqrst.supabase.co:5432/postgres",
    "postgres://user:password@localhost:5432/app",
    "github_pat_ で始まるトークンは細かい権限のトークンです",
]))
PY
commit_all
run_k1_case "$case_dir" "$case_dir/root with space" "$case_dir/missing-bin"
assert_contains '追跡中の .env.local の service_role は FAIL' "$case_dir/output.txt" 'FAIL  「secrets」 .*\.env\.local'
assert_contains '追跡中の .env.production の service_role は FAIL' "$case_dir/output.txt" 'FAIL  「secrets」 .*\.env\.production'
assert_contains '見本ファイルでも実値の秘密は FAIL' "$case_dir/output.txt" 'FAIL  「secrets」 .*\.env\.sample'
assert_not_contains '空・1Password・見本値だけのテンプレートは除外する' "$case_dir/output.txt" 'FAIL .*\.env\.example'
assert_not_contains 'anon JWT は秘密の検出対象にしない' "$case_dir/output.txt" 'FAIL .*anon\.ts'
assert_contains '追加した秘密の型をソースでも検出する' "$case_dir/output.txt" 'FAIL .*types\.ts」:[0-9]+'
assert_not_contains '単語の途中・見本の値・localhost の接続 URL は鍵として数えない' "$case_dir/output.txt" 'FAIL .*samples\.md'
if python3 - "$case_dir/output.txt" "$REPO_PATH" <<'PY'
import re
import sys
from pathlib import Path
output = Path(sys.argv[1]).read_text()
for path in Path(sys.argv[2]).iterdir():
    if path.name not in ("types.ts", ".env.local", ".env.production", ".env.sample"):
        continue
    for line in path.read_text().splitlines():
        value = line.partition("=")[2] if "=" in line else line
        if value and value in output:
            raise SystemExit(1)
PY
then pass '秘密の値をレポートに載せない'; else fail '秘密の値をレポートに載せない'; fi

case_dir="$TEST_TMP/k1-anon-env"
make_remote_repo "$case_dir" anonenv
python3 - "$REPO_PATH/.env.local" <<'PY'
import base64
import sys
from pathlib import Path
payload = base64.urlsafe_b64encode(b'{"role":"anon"}').decode().rstrip("=")
Path(sys.argv[1]).write_text("PUBLIC_KEY=eyJhbGciOiJIUzI1NiJ9." + payload + ".fixture\n")
PY
commit_all
run_k1_case "$case_dir" "$case_dir/root with space" "$case_dir/missing-bin"
assert_not_contains 'anon JWT だけの追跡中 .env.local は秘密の FAIL にしない' "$case_dir/output.txt" 'FAIL .*平文シークレット'

# 異常終了とタイムアウトを、当たりなしと区別します。
for scenario in exit1 timeout array; do
  case_dir="$TEST_TMP/k1-deny-$scenario"
  make_remote_repo "$case_dir" scanerror
  fake_bin="$case_dir/fake-bin"
  mkdir -p "$fake_bin"
  scanner="$PROJECT_DIR/bin/pkg-denylist-scan.py"
  case "$scenario" in
    exit1)
      scanner="$case_dir/scanner.py"
      printf 'raise SystemExit(1)\n' > "$scanner" ;;
    timeout)
      scanner="$case_dir/scanner.py"
      printf 'import time\ntime.sleep(5)\n' > "$scanner"
      real_perl="$(command -v perl)"
      cat > "$fake_bin/perl" <<'SH'
#!/bin/bash
if [ "${3:-}" = 60 ]; then set -- "$1" "$2" 1 "${@:4}"; fi
exec "$FAKE_REAL_PERL" "$@"
SH
      chmod +x "$fake_bin/perl" ;;
    array)
      printf '[]\n' > "$REPO_PATH/package-lock.json"
      commit_all ;;
  esac
  run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_DENY_SCANNER="$scanner" FAKE_REAL_PERL="${real_perl:-/usr/bin/perl}"
  assert_contains "$scenario: 照合不能を FAIL で知らせる" "$case_dir/output.txt" 'FAIL  「scanerror」 .*侵害パッケージ照合.*(異常終了|動いていません)'
done

# 対応する各 lock の書式を実際の照合へ渡します。
for format in pnpm-old pnpm-new yarn-v1 yarn-berry bun shrinkwrap; do
  case_dir="$TEST_TMP/k1-lock-$format"
  make_remote_repo "$case_dir" lockrepo
  printf '{"name":"fixture"}\n' > "$REPO_PATH/package.json"
  case "$format" in
    pnpm-old) printf 'lockfileVersion: 6.0\npackages:\n  /keyv@6.0.0:\n    resolution: {}\n' > "$REPO_PATH/pnpm-lock.yaml" ;;
    pnpm-new) printf "lockfileVersion: '9.0'\npackages:\n  keyv@6.0.0:\n    resolution: {}\n" > "$REPO_PATH/pnpm-lock.yaml" ;;
    yarn-v1) printf '# yarn lockfile v1\n\nkeyv@^6.0.0:\n  version "6.0.0"\n' > "$REPO_PATH/yarn.lock" ;;
    yarn-berry) printf '__metadata:\n  version: 8\n\n"keyv@npm:^6.0.0":\n  version: 6.0.0\n  resolution: "keyv@npm:6.0.0"\n' > "$REPO_PATH/yarn.lock" ;;
    bun) printf '{\n  "lockfileVersion": 1,\n  "packages": {\n    "keyv": ["keyv@6.0.0", "", {}, "fixture"],\n  },\n}\n' > "$REPO_PATH/bun.lock" ;;
    shrinkwrap) printf '{"lockfileVersion":3,"packages":{"node_modules/keyv":{"version":"6.0.0"}}}\n' > "$REPO_PATH/npm-shrinkwrap.json" ;;
  esac
  commit_all
  run_k1_case "$case_dir" "$case_dir/root with space" "$case_dir/missing-bin"
  assert_contains "$format: 侵害版を照合して FAIL にする" "$case_dir/output.txt" 'FAIL  「lockrepo」 .*keyv@6\.0\.0'
done

case_dir="$TEST_TMP/k1-bun-binary"
make_remote_repo "$case_dir" binary
printf 'fixture\000binary' > "$REPO_PATH/bun.lockb"
commit_all
run_k1_case "$case_dir" "$case_dir/root with space" "$case_dir/missing-bin"
assert_contains 'バイナリの bun.lockb は未照合の WARN' "$case_dir/output.txt" 'WARN .*bun\.lockb.*未照合|WARN .*未照合.*bun\.lockb'

# 据え置きはパッケージまたは GHSA ごとに適用します。
case_dir="$TEST_TMP/k1-vuln-allow"
make_remote_repo "$case_dir" auditrepo
fake_bin="$case_dir/fake-bin"
mkdir -p "$fake_bin"
printf '{"name":"fixture"}\n' > "$REPO_PATH/package.json"
printf '{"lockfileVersion":3,"packages":{}}\n' > "$REPO_PATH/package-lock.json"
commit_all
cat > "$fake_bin/npm" <<'SH'
#!/bin/bash
[ "${1:-}" = audit ] || exit 1
printf '%s\n' '{"metadata":{"vulnerabilities":{"critical":0,"high":2}},"vulnerabilities":{"allowed-pkg":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-aaaa-bbbb-cccc"}]},"other-pkg":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-dddd-eeee-ffff"}]}}}'
exit 1
SH
chmod +x "$fake_bin/npm"
printf 'auditrepo\tallowed-pkg\t2999-12-31\tfixture\n' > "$case_dir/allow.tsv"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_SKIP_AUDIT=0 RH_VULN_ALLOW_FILE="$case_dir/allow.tsv"
assert_contains '据え置き外の high が残ると FAIL にする' "$case_dir/output.txt" 'FAIL  「auditrepo」 .*据え置き 1 件・据え置き外 1 件'
printf 'auditrepo\tGHSA-aaaa-bbbb-cccc,other-pkg\t2999-12-31\tfixture\n' > "$case_dir/allow.tsv"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_SKIP_AUDIT=0 RH_VULN_ALLOW_FILE="$case_dir/allow.tsv"
assert_not_contains '複数の GHSA・パッケージに一致すれば FAIL を出さない' "$case_dir/output.txt" 'FAIL .*critical/high'
assert_contains '据え置きの件数を参考に出す' "$case_dir/output.txt" '据え置き 2 件・据え置き外 0 件'
printf 'auditrepo\t従来の説明文\t2999-12-31\tfixture\n' > "$case_dir/allow.tsv"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_SKIP_AUDIT=0 RH_VULN_ALLOW_FILE="$case_dir/allow.tsv"
assert_contains '説明文形式の据え置きは移行の手がかりを出す' "$case_dir/output.txt" '据え置きの形式が古い'
assert_not_contains '説明文形式は移行までは従来どおり効く' "$case_dir/output.txt" 'FAIL .*critical/high'

# ff-only pull の安全条件と、リポ内の自動実行設定の抑止を確認します。
for scenario in clean dirty stash ahead detached; do
  case_dir="$TEST_TMP/k1-pull-$scenario"
  make_remote_repo "$case_dir" pullrepo
  root="$case_dir/root with space"
  git clone -q "$case_dir/origin.git" "$case_dir/writer"
  git -C "$case_dir/writer" config user.name tester
  git -C "$case_dir/writer" config user.email tester@example.invalid
  printf 'remote\n' > "$case_dir/writer/remote.txt"
  git -C "$case_dir/writer" add remote.txt
  git -C "$case_dir/writer" commit -q -m 'test: remote change'
  git -C "$case_dir/writer" push -q
  case "$scenario" in
    dirty) printf 'local\n' >> "$REPO_PATH/README.md" ;;
    stash) printf 'local\n' >> "$REPO_PATH/README.md"; git -C "$REPO_PATH" stash push -q ;;
    ahead) printf 'local\n' > "$REPO_PATH/local.txt"; git -C "$REPO_PATH" add local.txt; git -C "$REPO_PATH" commit -q -m 'test: local change' ;;
    detached) git -C "$REPO_PATH" checkout -q --detach ;;
  esac
  before_head="$(git -C "$REPO_PATH" rev-parse HEAD)"
  if [ "$scenario" = clean ]; then
    cat > "$case_dir/fsmonitor" <<'SH'
#!/bin/bash
: > "$FAKE_FSMONITOR_MARK"
SH
    cat > "$REPO_PATH/.git/hooks/post-merge" <<'SH'
#!/bin/bash
: > "$FAKE_POSTMERGE_MARK"
SH
    chmod +x "$case_dir/fsmonitor" "$REPO_PATH/.git/hooks/post-merge"
    git -C "$REPO_PATH" config core.fsmonitor "$case_dir/fsmonitor"
  fi
  run_k1_case "$case_dir" "$root" "$case_dir/missing-bin" RH_SKIP_FETCH=0 RH_AUTOFIX_PULL=1 \
    FAKE_FSMONITOR_MARK="$case_dir/fsmonitor.mark" FAKE_POSTMERGE_MARK="$case_dir/postmerge.mark"
  after_head="$(git -c core.fsmonitor=false -C "$REPO_PATH" rev-parse HEAD)"
  if [ "$scenario" = clean ]; then
    if [ "$before_head" != "$after_head" ] && [ -f "$REPO_PATH/remote.txt" ]; then pass 'clean かつ behind のリポは ff-pull する'; else fail 'clean かつ behind のリポは ff-pull する'; fi
    if [ ! -e "$case_dir/fsmonitor.mark" ] && [ ! -e "$case_dir/postmerge.mark" ]; then pass 'fsmonitor と post-merge は点検中に実行しない'; else fail 'fsmonitor と post-merge は点検中に実行しない'; fi
  else
    if [ "$before_head" = "$after_head" ]; then pass "$scenario: 自動 pull しない"; else fail "$scenario: 自動 pull しない"; fi
  fi
done

# 同じ種類の未検査が続いた日数と、再開までの空白を知らせます。
case_dir="$TEST_TMP/k1-unchecked-streak"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
for day in 01 02 03; do
  run_security "$case_dir" "$fake_bin" RH_TODAY="2026-10-$day" FAKE_BREW_UPDATE_RC=1 FAKE_BREW_LOG="$case_dir/brew.log"
  if [ "$day" != 03 ]; then assert_not_contains "$day: 未検査の初日・2日目は継続 WARN を出さない" "$case_dir/output.txt" 'WARN .*未検査.*日目'; fi
done
assert_contains '未検査が3日続くと日数つき WARN にする' "$case_dir/output.txt" 'WARN .*未検査.*3[ ]*日目|WARN .*3[ ]*日目.*未検査'
printf '%s\n' "$(( $(date '+%s') - 40 * 3600 ))" > "$case_dir/state/last-completed"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log"
assert_contains '前回の完了から36時間を超えたら知らせる' "$case_dir/output.txt" '前回の点検が 40 時間前で止まっていました'

case_dir="$TEST_TMP/k1-lock"
mkdir -p "$case_dir/home" "$case_dir/root" "$case_dir/state/run.lock"
printf '%s %s\n' "$(date '+%s')" "$$" > "$case_dir/state/run.lock/started"
lock_started=$SECONDS
run_k1_case "$case_dir" "$case_dir/root" "$case_dir/missing-bin"
if [ "$RUN_RC" -eq 0 ] && [ $((SECONDS-lock_started)) -lt 3 ] && [ ! -f "$case_dir/log/repo-health-latest.md" ]; then pass '実行 lock があると2本目はすぐ終了する'; else fail '実行 lock があると2本目はすぐ終了する'; fi

# TERM または全体の時間切れで、不完全な結果を完成済みとして残しません。
for scenario in term runtime; do
  case_dir="$TEST_TMP/k1-stop-$scenario"
  fake_bin="$case_dir/fake-bin"
  mkdir -p "$fake_bin" "$case_dir/home" "$case_dir/root" "$case_dir/log"
  printf 'previous report\n' > "$case_dir/log/repo-health-latest.md"
  printf 'previous history\n' > "$case_dir/log/repo-health.log"
  cat > "$fake_bin/brew" <<'SH'
#!/bin/bash
if [ "${1:-}" = update ]; then : > "$FAKE_UPDATE_STARTED"; sleep 3; fi
exit 1
SH
  chmod +x "$fake_bin/brew"
  max_runtime=30
  [ "$scenario" != runtime ] || max_runtime=1
  env PATH="$fake_bin:$PATH" HOME="$case_dir/home" RH_CONFIG_FILE="$case_dir/missing-config" \
    RH_ROOTS="$case_dir/root" RH_LOG_DIR="$case_dir/log" RH_STATE_DIR="$case_dir/state" \
    RH_SECURITY_ONLY=1 RH_SKIP_SECURITY=0 RH_SKIP_SOFTWARE=1 RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 \
    RH_NO_DESKTOP=1 RH_NOMAIL=1 RH_KIT_UPDATE_CHECK=0 RH_SKIP_SOFTWAREUPDATE=1 RH_TLS_PROBE=0 \
    RH_NODE_CANDIDATES= RH_JAVA_CANDIDATES= RH_CLAUDE_CANDIDATES= RH_APP_DIRS="$case_dir/no-apps" \
    RH_PYTHON_SITE_DIRS= RH_UV_CANDIDATES= RH_BUN_CANDIDATES= RH_DOCKER="$fake_bin/missing-docker" RH_MACOS_VERSION=27.0.1 \
    RH_MAX_RUNTIME="$max_runtime" RH_BREW="$fake_bin/brew" FAKE_UPDATE_STARTED="$case_dir/started" \
    "$TEST_BASH" "$HEALTH" > "$case_dir/output.txt" 2>&1 &
  health_pid=$!
  for _attempt in 1 2 3 4 5 6 7 8 9 10; do [ ! -f "$case_dir/started" ] || break; sleep 0.1; done
  [ "$scenario" != term ] || kill -TERM "$health_pid"
  wait "$health_pid"
  stopped_rc=$?
  if [ "$stopped_rc" -eq 143 ]; then pass "$scenario: 終了コードは143"; else fail "$scenario: 終了コードは143"; fi
  assert_contains "$scenario: 前回のレポートを上書きしない" "$case_dir/log/repo-health-latest.md" '^previous report$'
  assert_contains "$scenario: 履歴へ不完全な結果を追記しない" "$case_dir/log/repo-health.log" '^previous history$'
  assert_count "$scenario: 履歴の行を増やさない" "$case_dir/log/repo-health.log" '.' 1
done

# メールの失敗を次に届ける本文の先頭に載せます。送信先も鍵も試験用です。
case_dir="$TEST_TMP/k1-mail"
make_remote_repo "$case_dir" mailrepo
mkdir -p "$case_dir/root with space/materials" "$case_dir/fake-bin"
printf 'fixture\n' > "$case_dir/root with space/materials/memo.txt"
fake_bin="$case_dir/fake-bin"
cat > "$fake_bin/security" <<'SH'
#!/bin/bash
printf 'fixture-mail-key\n'
SH
cat > "$fake_bin/curl" <<'SH'
#!/bin/bash
cat >/dev/null
while [ "$#" -gt 0 ]; do
  if [ "$1" = --data-binary ]; then shift; cp "${1#@}" "$FAKE_MAIL_PAYLOAD"; fi
  shift
done
exit "${FAKE_CURL_RC:-0}"
SH
cat > "$fake_bin/osascript" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_NOTIFY_LOG"
SH
chmod +x "$fake_bin/security" "$fake_bin/curl" "$fake_bin/osascript"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_MAIL_METHOD=resend RH_NOMAIL=0 RH_NO_DESKTOP=0 \
  RH_MAIL_TO=fixture@example.invalid FAKE_CURL_RC=1 FAKE_MAIL_PAYLOAD="$case_dir/payload.json" FAKE_NOTIFY_LOG="$case_dir/notify.log"
assert_contains '送信失敗の回数を状態に残す' "$case_dir/state/mail-failures" '^1$'
assert_contains '送信失敗をデスクトップへ通知する' "$case_dir/notify.log" '送.*(失敗|ません|でき)'
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_MAIL_METHOD=resend RH_NOMAIL=0 RH_NO_DESKTOP=0 \
  RH_MAIL_TO=fixture@example.invalid FAKE_CURL_RC=0 FAKE_MAIL_PAYLOAD="$case_dir/payload.json" FAKE_NOTIFY_LOG="$case_dir/notify.log"
if python3 - "$case_dir/payload.json" <<'PY'
import json
import sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text())
assert payload["text"].startswith("前回まで 1 回送れませんでした")
PY
then pass '次に届くメールの先頭で前回の送信失敗を知らせる'; else fail '次に届くメールの先頭で前回の送信失敗を知らせる'; fi
if [ ! -f "$case_dir/state/mail-failures" ] || [ "$(cat "$case_dir/state/mail-failures")" = 0 ]; then pass '送信成功後は失敗の目印を解消する'; else fail '送信成功後は失敗の目印を解消する'; fi
assert_not_contains '試験用の鍵もレポート・履歴へ出さない' "$case_dir/log/repo-health.log" 'fixture-mail-key'
: > "$case_dir/notify.log"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_MAIL_METHOD=none RH_NO_DESKTOP=0 FAKE_NOTIFY_LOG="$case_dir/notify.log"
assert_contains 'メールなしでも WARN をデスクトップへ通知する' "$case_dir/notify.log" 'display notification'
assert_not_contains 'WARN だけの通知は音を付けない' "$case_dir/notify.log" 'sound name'
: > "$case_dir/notify.log"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_MAIL_METHOD=resend RH_NOMAIL=0 RH_NO_DESKTOP=1 \
  RH_MAIL_TO=fixture@example.invalid FAKE_CURL_RC=1 FAKE_MAIL_PAYLOAD="$case_dir/payload.json" FAKE_NOTIFY_LOG="$case_dir/notify.log"
assert_not_contains 'RH_NO_DESKTOP=1 はメール失敗通知も出さない' "$case_dir/notify.log" '.'

# 更新の前後を記録し、更新しない部品との依存関係も守ります。
case_dir="$TEST_TMP/k1-incidental"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
: > "$case_dir/brew.log"
printf '[]\n' > "$case_dir/catalog.json"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_AUTOFIX_SOFTWARE=1 \
  RH_CASK_CATALOG="$case_dir/catalog.json" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_VERSIONS=$'rclone 1.0.0\notherlib 1.0.0\n' \
  FAKE_BREW_SNAPSHOT_AFTER=$'rclone 2.0.0\notherlib 1.1.0\n' \
  FAKE_BREW_JSON='{"formulae":[{"name":"rclone","installed_versions":["1.0.0"],"current_version":"2.0.0"}],"casks":[]}' \
  FAKE_BREW_AFTER_JSON='{"formulae":[],"casks":[]}'
assert_contains '名指し以外に上がった formula も AUTOFIXED に載せる' "$case_dir/output.txt" 'Homebrew: otherlib 1\.0\.0 → 1\.1\.0（巻き込みで更新）'

for protection in security ignore pin; do
  case_dir="$TEST_TMP/k1-protected-$protection"
  fake_bin="$case_dir/fake-bin"
  make_fake_brew "$fake_bin"
  make_fake_software_npm "$fake_bin"
  : > "$case_dir/brew.log"
  printf '[]\n' > "$case_dir/catalog.json"
  protected=node
  ignore=""; pinned=""
  case "$protection" in
    ignore) protected=keepme; ignore=keepme ;;
    pin) protected=keepme; pinned=$'keepme\n' ;;
  esac
  # 保護対象の依存先に新しい版が出ているときだけ、巻き込みになるので止めます。
  run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_AUTOFIX_SOFTWARE=1 \
    RH_CASK_CATALOG="$case_dir/catalog.json" RH_MAS="$fake_bin/missing-mas" \
    RH_SOFTWARE_IGNORE="$ignore" FAKE_BREW_PINNED="$pinned" FAKE_BREW_DEPS="$protected" \
    FAKE_BREW_JSON='{"formulae":[{"name":"rclone","installed_versions":["1.0.0"],"current_version":"2.0.0"},{"name":"'"$protected"'","installed_versions":["1.0.0"],"current_version":"3.0.0"}],"casks":[]}'
  assert_not_contains "$protection: 保護対象を依存先に含む formula は上げない" "$case_dir/brew.log" '^upgrade --formula rclone$'
  assert_contains "$protection: 自動更新を見送った理由を WARN に出す" "$case_dir/output.txt" "WARN .*rclone は $protected を一緒に上げるため自動更新しませんでした"
done

# 依存先の ca-certificates が最新なのに「一緒に上げるため」と止め、node の作り直し版も入らなかった回帰（0.8.1）。
case_dir="$TEST_TMP/k1-protected-current"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
: > "$case_dir/brew.log"
printf '[]\n' > "$case_dir/catalog.json"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_AUTOFIX_SOFTWARE=1 \
  RH_CASK_CATALOG="$case_dir/catalog.json" RH_MAS="$fake_bin/missing-mas" FAKE_BREW_DEPS=ca-certificates \
  FAKE_BREW_JSON='{"formulae":[{"name":"rclone","installed_versions":["1.0.0"],"current_version":"2.0.0"}],"casks":[]}'
assert_contains '保護対象の依存先が最新なら formula を上げる' "$case_dir/brew.log" '^upgrade --formula rclone$'
assert_not_contains '最新の依存先を理由に止めた WARN を出さない' "$case_dir/output.txt" 'ca-certificates を一緒に上げるため'

case_dir="$TEST_TMP/k1-revision-current-dependency"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_AUTOFIX_SOFTWARE=1 FAKE_BREW_DEPS=ca-certificates \
  FAKE_BREW_JSON='{"formulae":[{"name":"node","installed_versions":["26.13.1_2"],"current_version":"26.13.1_3"}],"casks":[]}'
assert_contains '最新の ca-certificates に依存する node も作り直し版へ上げる' "$case_dir/brew.log" '^upgrade node$'
assert_not_contains 'node を ca-certificates の巻き込みで止めない' "$case_dir/output.txt" 'node は ca-certificates を一緒に上げるため'

case_dir="$TEST_TMP/k1-protected-dependent"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
: > "$case_dir/brew.log"
printf '[]\n' > "$case_dir/catalog.json"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_AUTOFIX_SOFTWARE=1 \
  RH_CASK_CATALOG="$case_dir/catalog.json" RH_MAS="$fake_bin/missing-mas" FAKE_BREW_USES=node \
  FAKE_BREW_JSON='{"formulae":[{"name":"rclone","installed_versions":["1.0.0"],"current_version":"2.0.0"}],"casks":[]}'
assert_contains '保護対象が依存元のときは巻き込みを止めて候補を更新する' "$case_dir/brew.log" '^upgrade --formula rclone$'
assert_contains '依存元の自動更新を止めるフラグを付ける' "$case_dir/brew.log" '^deps-check=1$'

case_dir="$TEST_TMP/k1-revision"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_AUTOFIX_SOFTWARE=1 \
  FAKE_BREW_JSON='{"formulae":[{"name":"node","installed_versions":["26.13.1_1"],"current_version":"26.13.1_2"}],"casks":[]}'
assert_contains '同じ版の改訂だけならセキュリティ自動更新OFFでも上げる' "$case_dir/brew.log" '^upgrade node$'
assert_contains '改訂だけの更新は作り直しとして記録する' "$case_dir/output.txt" 'node .*26\.13\.1_1 → 26\.13\.1_2.*同じ版の作り直し'
assert_not_contains '更新済みの改訂は更新待ち WARN から外す' "$case_dir/output.txt" 'WARN .*セキュリティ部品に更新.*node '

case_dir="$TEST_TMP/k1-pinned-security"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_AUTOFIX_SECURITY=1 \
  FAKE_BREW_JSON='{"formulae":[{"name":"node","installed_versions":["26.13.1"],"current_version":"26.14.0","pinned":true}],"casks":[]}'
assert_not_contains 'pin 中のセキュリティ部品を更新しない' "$case_dir/brew.log" '^upgrade node$'
assert_not_contains 'pin 中の部品を更新待ち WARN にしない' "$case_dir/output.txt" 'WARN .*セキュリティ部品に更新.*node '
assert_contains 'pin 中であることを参考に出す' "$case_dir/output.txt" 'node.*pin 中|pin 中.*node'

case_dir="$TEST_TMP/k1-partial-security"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_AUTOFIX_SECURITY=1 FAKE_BREW_UPGRADE_RC=1 \
  FAKE_BREW_VERSIONS=$'node 26.13.1\npython@3.14 3.14.1\n' \
  FAKE_BREW_SNAPSHOT_AFTER=$'node 26.14.0\npython@3.14 3.14.1\n' \
  FAKE_BREW_JSON='{"formulae":[{"name":"node","installed_versions":["26.13.1"],"current_version":"26.14.0"},{"name":"python@3.14","installed_versions":["3.14.1"],"current_version":"3.14.2"}],"casks":[]}' \
  FAKE_BREW_AFTER_JSON='{"formulae":[{"name":"python@3.14","installed_versions":["3.14.1"],"current_version":"3.14.2"}],"casks":[]}'
assert_contains '終了コードが非0でも上がったセキュリティ部品は記録する' "$case_dir/output.txt" 'Homebrew: node 26\.13\.1 → 26\.14\.0'
assert_contains '上がらなかった部品は WARN に残す' "$case_dir/output.txt" 'WARN .*python@3\.14.*(失敗|更新)'

case_dir="$TEST_TMP/k1-node-revisit"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_node_keg "$case_dir" node@22
make_fake_node_keg "$case_dir" node@24 all
: > "$case_dir/brew.log"
: > "$case_dir/node.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_NODE_KEG_LOG="$case_dir/node.log" \
  FAKE_BREW_PREFIX="$case_dir/homebrew" FAKE_BREW_STATE_DIR="$case_dir/state" \
  FAKE_BREW_FORMULAE=$'node@22\nnode@24\n' FAKE_BREW_FIX_ON=upgrade \
  FAKE_BREW_BREAK_AFTER_UPGRADE=node@22 RH_AUTOFIX_SOFTWARE=1 \
  FAKE_BREW_VERSIONS=$'node@22 22.0.0\nnode@24 24.22.3\n'
if LC_ALL=C grep -qE '^upgrade node@22$' "$case_dir/brew.log" || LC_ALL=C grep -qE 'WARN .*node@22.*起動しません' "$case_dir/output.txt"; then
  pass '別の node の修復で壊れた node@22 も同じ回に拾う'
else fail '別の node の修復で壊れた node@22 も同じ回に拾う'; fi

case_dir="$TEST_TMP/k1-linkage"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
mkdir -p "$case_dir/state"
printf 'broken\n' > "$case_dir/state/python@3.14.broken"
: > "$case_dir/brew.log"
: > "$case_dir/linkage.log"
printf '[]\n' > "$case_dir/catalog.json"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_AUTOFIX_SOFTWARE=1 \
  RH_CASK_CATALOG="$case_dir/catalog.json" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_USES=python@3.14 FAKE_BREW_LINKAGE_LOG="$case_dir/linkage.log" \
  FAKE_BREW_STATE_DIR="$case_dir/state" FAKE_BREW_FIX_ON=upgrade \
  FAKE_BREW_VERSIONS=$'rclone 1.0.0\npython@3.14 3.14.1\n' \
  FAKE_BREW_SNAPSHOT_AFTER=$'rclone 2.0.0\npython@3.14 3.14.1\n' \
  FAKE_BREW_JSON='{"formulae":[{"name":"rclone","installed_versions":["1.0.0"],"current_version":"2.0.0"}],"casks":[]}'
assert_contains '更新した formula の node 以外の依存元も linkage を調べる' "$case_dir/linkage.log" '^linkage --test python@3\.14$'
assert_contains 'linkage が壊れた依存元を名指しして修復する' "$case_dir/brew.log" '^upgrade python@3\.14$'

case_dir="$TEST_TMP/k1-node-list-failure"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_LIST_RC=1
assert_contains 'node の導入一覧取得が失敗したら未検査を残す' "$case_dir/output.txt" 'Homebrew.*未検査'

# npm 以外の audit も、各道具の JSON を判定します。
for tool in pnpm yarn bun; do
  for severity in clean high; do
    case_dir="$TEST_TMP/k1-audit-$tool-$severity"
    make_remote_repo "$case_dir" audittool
    fake_bin="$case_dir/fake-bin"
    mkdir -p "$fake_bin"
    printf '{"name":"fixture"}\n' > "$REPO_PATH/package.json"
    case "$tool" in
      pnpm) printf "lockfileVersion: '9.0'\npackages:\n  safe-pkg@1.0.0:\n    resolution: {}\n" > "$REPO_PATH/pnpm-lock.yaml" ;;
      yarn) printf '__metadata:\n  version: 8\n\n"safe-pkg@npm:1.0.0":\n  version: 1.0.0\n  resolution: "safe-pkg@npm:1.0.0"\n' > "$REPO_PATH/yarn.lock" ;;
      bun) printf '{"lockfileVersion":1,"packages":{"safe-pkg":["safe-pkg@1.0.0","",{}]}}\n' > "$REPO_PATH/bun.lock" ;;
    esac
    commit_all
    cat > "$fake_bin/$tool" <<'SH'
#!/bin/bash
if [ "${1:-}" = --version ]; then printf '4.5.0\n'; exit 0; fi
printf '%s\n' "$*" >> "$FAKE_AUDIT_ARGS"
cat "$FAKE_AUDIT_RESULT"
SH
    chmod +x "$fake_bin/$tool"
    if [ "$tool" = yarn ]; then
      if [ "$severity" = clean ]; then : > "$case_dir/result.json";
      else
        printf '%s\n' '{"value":"safe-pkg","children":{"Severity":"high","URL":"https://github.com/advisories/GHSA-aaaa-bbbb-cccc"}}' '{"value":"safe-pkg","children":{"Severity":"moderate","URL":"https://github.com/advisories/GHSA-dddd-eeee-ffff"}}' > "$case_dir/result.json"
      fi
    elif [ "$tool" = pnpm ]; then
      if [ "$severity" = clean ]; then printf '{"advisories":{},"metadata":{"vulnerabilities":{"high":0}}}\n' > "$case_dir/result.json";
      else printf '{"advisories":{"123":{"module_name":"safe-pkg","severity":"high","url":"https://github.com/advisories/GHSA-aaaa-bbbb-cccc"}}}\n' > "$case_dir/result.json"; fi
    else
      if [ "$severity" = clean ]; then printf '{}\n' > "$case_dir/result.json";
      else printf '{"safe-pkg":[{"severity":"high","url":"https://github.com/advisories/GHSA-aaaa-bbbb-cccc"}]}\n' > "$case_dir/result.json"; fi
    fi
    run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_SKIP_AUDIT=0 \
      FAKE_AUDIT_ARGS="$case_dir/args.log" FAKE_AUDIT_RESULT="$case_dir/result.json"
    if [ "$severity" = high ]; then
      assert_contains "$tool: audit の high は FAIL にする" "$case_dir/output.txt" 'FAIL  「audittool」 .*critical/high'
    else
      assert_not_contains "$tool: audit の指摘なしは WARN・FAIL を出さない" "$case_dir/output.txt" '(FAIL|WARN).*audit.*(実行不能|critical/high)'
    fi
    case "$tool" in
      pnpm) assert_contains 'pnpm audit は本番依存を指定する' "$case_dir/args.log" '^audit --prod --json$' ;;
      yarn) assert_contains 'yarn berry は npm audit サブコマンドを使う' "$case_dir/args.log" '^npm audit --all --recursive --environment production --json$' ;;
      bun) assert_contains 'bun audit は JSON を指定する' "$case_dir/args.log" '^audit --json$' ;;
    esac
  done
done

case_dir="$TEST_TMP/k1-same-package-ghsa"
make_remote_repo "$case_dir" advisories
fake_bin="$case_dir/fake-bin"
mkdir -p "$fake_bin"
printf '{"name":"fixture"}\n' > "$REPO_PATH/package.json"
printf '{"lockfileVersion":3,"packages":{}}\n' > "$REPO_PATH/package-lock.json"
commit_all
cat > "$fake_bin/npm" <<'SH'
#!/bin/bash
printf '%s\n' '{"metadata":{"vulnerabilities":{"high":1}},"vulnerabilities":{"safe-pkg":{"severity":"high","via":[{"severity":"high","url":"https://github.com/advisories/GHSA-aaaa-bbbb-cccc"},{"severity":"high","url":"https://github.com/advisories/GHSA-dddd-eeee-ffff"}]}}}'
SH
chmod +x "$fake_bin/npm"
printf 'advisories\tGHSA-aaaa-bbbb-cccc\t2999-12-31\tfixture\n' > "$case_dir/allow.tsv"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_SKIP_AUDIT=0 RH_VULN_ALLOW_FILE="$case_dir/allow.tsv"
assert_contains '同じパッケージの別 GHSA まで据え置きにしない' "$case_dir/output.txt" 'FAIL  「advisories」 .*据え置き 1 件・据え置き外 1 件'

case_dir="$TEST_TMP/k1-node-transient"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_node_keg "$case_dir" node@24
: > "$case_dir/brew.log"
: > "$case_dir/node.log"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" FAKE_NODE_KEG_LOG="$case_dir/node.log" \
  FAKE_BREW_PREFIX="$case_dir/homebrew" FAKE_BREW_STATE_DIR="$case_dir/state" \
  FAKE_BREW_FORMULAE=node@24 FAKE_NODE_TRANSIENT_FORMULA=node@24 RH_AUTOFIX_SOFTWARE=1
assert_not_contains '1回だけの起動失敗では node を更新・入れ直ししない' "$case_dir/brew.log" '^(upgrade|reinstall) node@24$'
assert_not_contains '2回目に起動した node は起動 WARN にしない' "$case_dir/output.txt" 'WARN .*node@24.*起動しません'

case_dir="$TEST_TMP/k1-linkage-timeout"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_software_npm "$fake_bin"
real_perl="$(command -v perl)"
cat > "$fake_bin/perl" <<'SH'
#!/bin/bash
if [ "${3:-}" = 60 ]; then set -- "$1" "$2" 1 "${@:4}"; fi
exec "$FAKE_REAL_PERL" "$@"
SH
chmod +x "$fake_bin/perl"
: > "$case_dir/brew.log"
printf '[]\n' > "$case_dir/catalog.json"
run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_SKIP_SOFTWARE=0 RH_AUTOFIX_SOFTWARE=1 \
  RH_CASK_CATALOG="$case_dir/catalog.json" RH_MAS="$fake_bin/missing-mas" \
  FAKE_BREW_USES=python@3.14 FAKE_BREW_LINKAGE_SLEEP=3 FAKE_REAL_PERL="$real_perl" \
  FAKE_BREW_JSON='{"formulae":[{"name":"rclone","installed_versions":["1.0.0"],"current_version":"2.0.0"}],"casks":[]}'
assert_contains 'linkage の時間切れは未検査を残す' "$case_dir/output.txt" 'linkage.*制限時間.*未検査'

# 追跡中の env は、値のないものや参照だけのものも追跡自体を知らせます。
case_dir="$TEST_TMP/k1-tracked-env-policy"
make_remote_repo "$case_dir" envpolicy
printf '.env*\n' > "$REPO_PATH/.gitignore"
: > "$REPO_PATH/.env.local"
printf 'KEY=op://fixture/item/field\n' > "$REPO_PATH/.env.production"
git -C "$REPO_PATH" add .gitignore
git -C "$REPO_PATH" add -f .env.local .env.production
git -C "$REPO_PATH" commit -q -m 'test: tracked env fixtures'
run_k1_case "$case_dir" "$case_dir/root with space" "$case_dir/missing-bin"
assert_contains '空でも追跡中の .env.local は FAIL' "$case_dir/output.txt" 'FAIL  「envpolicy」 .*\.env\.local'
assert_contains '見本名以外の追跡中 env は参照値だけでも FAIL' "$case_dir/output.txt" 'FAIL  「envpolicy」 .*\.env\.production'

# 未検査の連続は日が空いたら数え直します。
case_dir="$TEST_TMP/k1-unchecked-gap"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
for day in 01 03 04; do
  run_security "$case_dir" "$fake_bin" RH_TODAY="2026-10-$day" FAKE_BREW_UPDATE_RC=1 FAKE_BREW_LOG="$case_dir/brew.log"
done
assert_not_contains '点検日が空いた未検査を連続3日とは数えない' "$case_dir/output.txt" 'WARN .*未検査.*日目'
run_security "$case_dir" "$fake_bin" RH_TODAY=2026-10-05 FAKE_BREW_UPDATE_RC=1 FAKE_BREW_LOG="$case_dir/brew.log"
assert_contains '数え直した未検査も3日目に WARN' "$case_dir/output.txt" 'WARN .*未検査.*3日目'

# 0.7.1: 利用者が自分で止めた点検は「止めています（設定 RH_…）」と書き、未検査の連続日数の WARN に上げない。
case_dir="$TEST_TMP/k1-stopped-checks"
make_remote_repo "$case_dir" stoppedrepo
printf '{"name":"fixture","version":"1.0.0"}\n' > "$REPO_PATH/package.json"
printf '%s\n' '{"name":"fixture","lockfileVersion":3,"packages":{"":{"name":"fixture","version":"1.0.0"}}}' > "$REPO_PATH/package-lock.json"
git -C "$REPO_PATH" add package.json package-lock.json
git -C "$REPO_PATH" commit -q -m 'test: lock'
git -C "$REPO_PATH" push -q
for day in 01 02 03; do
  run_k1_case "$case_dir" "$case_dir/root with space" "$case_dir/missing-bin" \
    RH_DATA_GUARD=0 RH_SKIP_AUDIT=1 RH_SKIP_FETCH=1 RH_TODAY="2026-10-$day"
done
assert_contains 'RH_DATA_GUARD=0 は「止めています」と書く' "$case_dir/output.txt" 'データの守りの点検は止めています（設定 RH_DATA_GUARD=0）'
assert_contains 'RH_SKIP_AUDIT=1 は「止めています」と書く' "$case_dir/output.txt" 'npm audit は止めています（設定 RH_SKIP_AUDIT=1）'
assert_contains 'RH_SKIP_FETCH=1 は「止めています」と書く' "$case_dir/output.txt" 'fetch は止めています（設定 RH_SKIP_FETCH=1）'
assert_contains 'RH_SKIP_SECURITY=1 は「止めています」と書く' "$case_dir/output.txt" 'Mac のセキュリティ点検は止めています（設定 RH_SKIP_SECURITY=1）'
assert_not_contains '止めたデータの守り・audit・fetch・Mac のセキュリティ点検は3日続いても未検査の WARN に上げない' "$case_dir/output.txt" 'WARN .*(RH_DATA_GUARD=0|RH_SKIP_AUDIT=1|RH_SKIP_FETCH=1|RH_SKIP_SECURITY=1).*未検査が続いて'

case_dir="$TEST_TMP/security-stopped-checks"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
: > "$case_dir/brew.log"
for day in 01 02 03; do
  run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_TODAY="2026-10-$day" \
    RH_SKIP_CLI=1 RH_TLS_PROBE=0 RH_SKIP_SOFTWAREUPDATE=1 RH_SKIP_SOFTWARE=1 RH_KIT_UPDATE_CHECK=0
done
assert_contains 'RH_SKIP_CLI=1 は「止めています」と書く' "$case_dir/output.txt" 'CLI 更新確認は止めています（設定 RH_SKIP_CLI=1）'
assert_contains 'RH_TLS_PROBE=0 は「止めています」と書く' "$case_dir/output.txt" '証明書の点検は止めています（設定 RH_TLS_PROBE=0）'
assert_contains 'RH_SKIP_SOFTWAREUPDATE=1 は「止めています」と書く' "$case_dir/output.txt" 'macOS のアップデート確認は止めています（設定 RH_SKIP_SOFTWAREUPDATE=1）'
assert_contains 'RH_SKIP_SOFTWARE=1 は「止めています」と書く' "$case_dir/output.txt" '入っているソフトの更新確認は止めています（設定 RH_SKIP_SOFTWARE=1）'
assert_contains 'RH_KIT_UPDATE_CHECK=0 は「止めています」と書く' "$case_dir/output.txt" 'repo-health-kit の更新確認は止めています（設定 RH_KIT_UPDATE_CHECK=0）'
assert_not_contains '止めた CLI・証明書・macOS アップデート・ソフト更新・kit の更新確認は3日続いても未検査の WARN に上げない' "$case_dir/output.txt" 'WARN .*(RH_SKIP_CLI=1|RH_TLS_PROBE=0|RH_SKIP_SOFTWAREUPDATE=1|RH_SKIP_SOFTWARE=1|RH_KIT_UPDATE_CHECK=0).*未検査が続いて'
assert_not_contains '止めた点検だけなら、3日目でも未検査の継続 WARN は 1 件も出ない' "$case_dir/output.txt" '未検査が続いて'

# 止めていないのに見られなかった点検は、今までどおり「未検査」を数えて3日目に WARN にする。
case_dir="$TEST_TMP/security-unchecked-not-stopped"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_exit_command "$fake_bin/apple-curl" 6
make_exit_command "$fake_bin/softwareupdate" 1
: > "$case_dir/brew.log"
for day in 01 02 03; do
  run_security "$case_dir" "$fake_bin" FAKE_BREW_LOG="$case_dir/brew.log" RH_TODAY="2026-10-$day" \
    RH_TLS_PROBE=1 RH_SKIP_SOFTWAREUPDATE=0 \
    RH_PROBE_APPLE_CURL="$fake_bin/apple-curl" RH_PROBE_APPLE_PYTHON="$fake_bin/missing-apple-python" \
    RH_PROBE_BREW_CURL="$fake_bin/missing-brew-curl" RH_PROBE_NODE="$fake_bin/missing-node" RH_PROBE_PYTHON="$fake_bin/missing-python"
  if [ "$day" != 03 ]; then assert_not_contains "$day: 止めていない未検査も初日・2日目は継続 WARN を出さない" "$case_dir/output.txt" '未検査が続いて'; fi
done
assert_contains 'RH_TLS_PROBE=1 で接続できなければ3日目に WARN' "$case_dir/output.txt" 'WARN  .*証明書の点検は接続できず未検査（未検査が続いて3日目'
assert_contains 'RH_SKIP_SOFTWAREUPDATE=0 で確認できなければ3日目に WARN' "$case_dir/output.txt" 'WARN  macOS のアップデート確認は未検査（未検査が続いて3日目'

case_dir="$TEST_TMP/k1-stale-lock"
mkdir -p "$case_dir/home" "$case_dir/root" "$case_dir/state/run.lock"
python3 - "$case_dir/state/run.lock" <<'PY'
import os
import sys
import time
past = time.time() - 10801
os.utime(sys.argv[1], (past, past))
PY
run_k1_case "$case_dir" "$case_dir/root" "$case_dir/missing-bin"
if [ -f "$case_dir/log/repo-health-latest.md" ] && [ ! -d "$case_dir/state/run.lock" ]; then pass '3時間を過ぎた lock は回復して点検を完了する'; else fail '3時間を過ぎた lock は回復して点検を完了する'; fi

# 送信中に中断しても、その回のレポートと履歴を公開しません。
case_dir="$TEST_TMP/k1-mail-term"
make_remote_repo "$case_dir" interruptedmail
mkdir -p "$case_dir/fake-bin" "$case_dir/log" "$case_dir/root with space/materials"
printf 'fixture\n' > "$case_dir/root with space/materials/memo.txt"
printf 'previous report\n' > "$case_dir/log/repo-health-latest.md"
printf 'previous history\n' > "$case_dir/log/repo-health.log"
cat > "$case_dir/fake-bin/security" <<'SH'
#!/bin/bash
printf 'fixture-mail-key\n'
SH
cat > "$case_dir/fake-bin/curl" <<'SH'
#!/bin/bash
cat >/dev/null
: > "$FAKE_MAIL_STARTED"
sleep 3
exit 0
SH
chmod +x "$case_dir/fake-bin/security" "$case_dir/fake-bin/curl"
env PATH="$case_dir/fake-bin:$PATH" HOME="$case_dir/home" RH_CONFIG_FILE="$case_dir/no-config" \
  RH_ROOTS="$case_dir/root with space" RH_LOG_DIR="$case_dir/log" RH_STATE_DIR="$case_dir/state" \
  RH_SKIP_SECURITY=1 RH_SKIP_SOFTWARE=1 RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_AUTOFIX_PULL=0 \
  RH_NO_DESKTOP=1 RH_NOMAIL=0 RH_MAIL_METHOD=resend RH_MAIL_TO=fixture@example.invalid \
  FAKE_MAIL_STARTED="$case_dir/started" "$TEST_BASH" "$HEALTH" > "$case_dir/output.txt" 2>&1 &
health_pid=$!
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ ! -f "$case_dir/started" ] || break; sleep 0.1; done
kill -TERM "$health_pid"
wait "$health_pid"
mail_stop_rc=$?
if [ "$mail_stop_rc" = 143 ]; then pass '送信中の TERM も143で終了する'; else fail '送信中の TERM も143で終了する'; fi
assert_contains '送信中断では前回のレポートを保つ' "$case_dir/log/repo-health-latest.md" '^previous report$'
assert_count '送信中断では履歴の行を増やさない' "$case_dir/log/repo-health.log" '.' 1

# audit が返す空 object と、詳細の欠けた重大な集計を区別します。
case_dir="$TEST_TMP/k1-audit-invalid-counts"
make_remote_repo "$case_dir" incompleteaudit
mkdir -p "$case_dir/fake-bin"
printf '{"name":"fixture"}\n' > "$REPO_PATH/package.json"
printf '{"lockfileVersion":3,"packages":{}}\n' > "$REPO_PATH/package-lock.json"
commit_all
cat > "$case_dir/fake-bin/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$FAKE_AUDIT_JSON"
SH
chmod +x "$case_dir/fake-bin/npm"
run_k1_case "$case_dir" "$case_dir/root with space" "$case_dir/fake-bin" RH_SKIP_AUDIT=0 FAKE_AUDIT_JSON='{}'
assert_contains 'npm audit の空 object を指摘なしと見なさない' "$case_dir/output.txt" 'WARN .*npm audit 実行不能'
run_k1_case "$case_dir" "$case_dir/root with space" "$case_dir/fake-bin" RH_SKIP_AUDIT=0 \
  FAKE_AUDIT_JSON='{"vulnerabilities":{},"metadata":{"vulnerabilities":{"high":1}}}'
assert_contains '詳細の欠けた high も据え置き外に残す' "$case_dir/output.txt" 'FAIL .*据え置き外 1 件'

# ---- 0.6.0: ノイズ・導入環境・公開レポート ----
# 本体の関数だけを取り出し、実機の点検を起動せず境界条件を確かめます。
unit_library="$TEST_TMP/k1b-functions.sh"
python3 - "$HEALTH" "$unit_library" <<'PY_UNIT'
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
names = ('clean_text', 'quote_name', 'is_uint', 'add_node_paths', 'file_owner', 'file_mode', 'check_config_safety', 'fatal', 'add_failure', 'add_protected_failure', 'add_warning', 'add_detail', 'apply_allowances', 'run_timeout', 'streak_key', 'streak_file', 'streak_bump', 'streak_reset', 'repo_state_key', 'rotate_log', 'version_less_than', 'npm_release_info', 'npm_package_for_cli', 'real_path_of', 'cli_is_npm', 'cli_remedy', 'update_cli', 'lookup_minimum_row', 'warn_old_series', 'current_version', 'latest_version', 'check_cli_tools')
parts = []
for name in names:
    match = re.search(r'^' + name + r'\(\) \{[^\n]*', text, re.M)
    if not match:
        raise SystemExit('missing function: ' + name)
    end = match.end() if match.group().endswith('}') else re.search(r'^\}', text[match.end():], re.M).end() + match.end()
    parts.append(text[match.start():end])
Path(sys.argv[2]).write_text('\n'.join(parts) + '\n')
PY_UNIT

case_dir="$TEST_TMP/k1b-allow"
mkdir -p "$case_dir/tmp" "$case_dir/state"
cat > "$case_dir/unit.sh" <<'SH'
set -uo pipefail
# shellcheck source=/dev/null
source "$UNIT_LIBRARY"
TMP_DIR="$CASE_DIR/tmp"; STATE_DIR="$CASE_DIR/state"
ALLOW_FILE="$CASE_DIR/allow.tsv"; RH_TODAY=2026-11-16
FAILURES=(); WARNINGS=(); NOTES=()
printf 'origin 未設定\t2026-11-23\t手元用\nサポート終了\t2026-11-15\t旧環境\n説明用\t2026-12-01\t教材\n侵害パッケージ\t2026-12-01\t試験\ncommit 済み\t2026-12-01\t試験\n長すぎる期限\t2027-11-16\t試験\n理由なし\t2026-12-01\t\n期限なし\t\t試験\n' > "$ALLOW_FILE"
add_warning '「local」 — origin 未設定'
add_warning 'サポート終了'
add_warning '長すぎる期限'
add_warning '理由なし'
add_warning '期限なし'
add_failure '説明用の FAIL'
add_protected_failure '侵害パッケージの FAIL'
add_protected_failure '鍵が commit 済み'
apply_allowances
printf 'COUNTS %s %s\n' "${#FAILURES[@]}" "${#WARNINGS[@]}"
printf 'FAIL %s\n' "${FAILURES[@]}"
printf 'WARN %s\n' "${WARNINGS[@]}"
printf 'NOTE %s\n' "${NOTES[@]}"
SH
UNIT_LIBRARY="$unit_library" CASE_DIR="$case_dir" "$TEST_BASH" "$case_dir/unit.sh" > "$case_dir/output.txt" 2>&1
assert_contains '据え置いた WARN と通常 FAIL を件数から外す' "$case_dir/output.txt" '^COUNTS 2 4$'
assert_contains '据え置いた指摘は期限付き参考に残す' "$case_dir/output.txt" '参考（据え置き中・期限 2026-11-23）WARN'
assert_contains '期限7日前から予告する' "$case_dir/output.txt" '据え置きの期限が近い: 2026-11-23'
assert_contains '期限切れは WARN に戻す' "$case_dir/output.txt" '^WARN サポート終了$'
assert_contains '侵害パッケージは据え置けない' "$case_dir/output.txt" '^FAIL 侵害パッケージの FAIL$'
assert_contains '追跡中の鍵は据え置けない' "$case_dir/output.txt" '^FAIL 鍵が commit 済み$'
assert_count '据え置き不可の注記も出す' "$case_dir/output.txt" 'NOTE 据え置き不可' 2
assert_contains '180日を超える期限は無効' "$case_dir/output.txt" '^WARN 長すぎる期限$'
assert_count '期限や理由の欠けた行も無効にする' "$case_dir/output.txt" '行目は無効' 3

case_dir="$TEST_TMP/k1b-npm"
mkdir -p "$case_dir/fake-bin" "$case_dir/tmp"
cat > "$case_dir/fake-bin/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE_DIR/npm.log"
cat "$CASE_DIR/metadata.json"
SH
chmod +x "$case_dir/fake-bin/npm"
cat > "$case_dir/unit.sh" <<'SH'
set -uo pipefail
# shellcheck source=/dev/null
source "$UNIT_LIBRARY"
TMP_DIR="$CASE_DIR/tmp"
if npm_release_info fixture 1.0.0; then printf 'TARGET %s\n' "$NPM_TARGET"; else printf 'UNCHECKED\n'; fi
SH
for scenario in missing-tag missing-version deprecated per-version-deprecated; do
  case "$scenario" in
    missing-tag) metadata='{"time":{"2.0.0":"2020-01-01T00:00:00Z"},"versions":["2.0.0"],"dist-tags":{}}';;
    missing-version) metadata='{"time":{"1.5.0":"2020-01-01T00:00:00Z","2.0.0":"2020-01-01T00:00:00Z","3.0.0":"2999-01-01T00:00:00Z"},"versions":["1.5.0","3.0.0"],"dist-tags":{"latest":"3.0.0"}}';;
    deprecated) metadata='{"time":{"1.5.0":"2020-01-01T00:00:00Z","2.0.0":"2020-01-01T00:00:00Z","3.0.0":"2999-01-01T00:00:00Z"},"versions":["1.5.0","2.0.0","3.0.0"],"dist-tags":{"latest":"3.0.0"},"deprecated":{"2.0.0":"withdrawn"}}';;
    per-version-deprecated) metadata='[{"version":"1.5.0","time":{"1.5.0":"2020-01-01T00:00:00Z","2.0.0":"2020-01-01T00:00:00Z","3.0.0":"2999-01-01T00:00:00Z"},"versions":["1.5.0","2.0.0","3.0.0"],"dist-tags":{"latest":"3.0.0"}},{"version":"2.0.0","deprecated":"withdrawn"},{"version":"3.0.0","time":{"1.5.0":"2020-01-01T00:00:00Z","2.0.0":"2020-01-01T00:00:00Z","3.0.0":"2999-01-01T00:00:00Z"},"versions":["1.5.0","2.0.0","3.0.0"],"dist-tags":{"latest":"3.0.0"}}]';;
  esac
  printf '%s\n' "$metadata" > "$case_dir/metadata.json"
  : > "$case_dir/npm.log"
  PATH="$case_dir/fake-bin:$PATH" UNIT_LIBRARY="$unit_library" CASE_DIR="$case_dir" "$TEST_BASH" "$case_dir/unit.sh" > "$case_dir/output.txt" 2>&1
  if [ "$scenario" = missing-tag ]; then
    assert_contains 'dist-tags.latest 取得失敗は上げ先なし' "$case_dir/output.txt" '^UNCHECKED$'
  else
    assert_contains "$scenario: 配布中かつ非推奨でない古い版だけを選ぶ" "$case_dir/output.txt" '^TARGET 1\.5\.0$'
  fi
  assert_count "$scenario: npm の問い合わせは一度だけ" "$case_dir/npm.log" '^view fixture@\* time dist-tags versions deprecated version --json$' 1
 done

case_dir="$TEST_TMP/k1b-path"
mkdir -p "$case_dir/home/.nvm/alias" "$case_dir/home/.nvm/versions/node/v24.1.0/bin" "$case_dir/home/.nvm/versions/node/v24.2.0/bin" "$case_dir/home/.nvm/versions/node/v2.9.0/bin" "$case_dir/npm-location"
printf '24\n' > "$case_dir/home/.nvm/alias/default"
cat > "$case_dir/home/.nvm/versions/node/v24.2.0/bin/npm" <<'SH'
#!/bin/bash
printf 'fake-nvm-npm\n'
SH
chmod +x "$case_dir/home/.nvm/versions/node/v24.2.0/bin/npm"
cat > "$case_dir/unit.sh" <<'SH'
set -uo pipefail
# shellcheck source=/dev/null
source "$UNIT_LIBRARY"
RH_NPM_DIR="$CASE_DIR/npm-location"
add_node_paths
case ":$PATH:" in *":$HOME/.nvm/versions/node/v24.2.0/bin:"*) printf 'NVM OK\n';; esac
case ":$PATH:" in *":$RH_NPM_DIR:"*) printf 'NPM-DIR OK\n';; esac
npm
# 小さい系列番号が24に前方一致しないことも確かめます。
printf '2\n' > "$HOME/.nvm/alias/default"
PATH=/usr/bin:/bin
add_node_paths
case ":$PATH:" in *":$HOME/.nvm/versions/node/v2.9.0/bin:"*) printf 'NVM-SERIES OK\n';; esac
case ":$PATH:" in *":$HOME/.nvm/versions/node/v24.2.0/bin:"*) exit 1;; esac
SH
HOME="$case_dir/home" PATH=/usr/bin:/bin UNIT_LIBRARY="$unit_library" CASE_DIR="$case_dir" "$TEST_BASH" "$case_dir/unit.sh" > "$case_dir/output.txt" 2>&1
assert_contains '偽 HOME の nvm default から最新の同系列を探す' "$case_dir/output.txt" '^NVM OK$'
assert_contains 'install 時に記録した npm の場所も PATH に加える' "$case_dir/output.txt" '^NPM-DIR OK$'
assert_contains 'nvm の偽 npm を実行できる' "$case_dir/output.txt" '^fake-nvm-npm$'
assert_contains 'nvm の系列番号を取り違えない' "$case_dir/output.txt" '^NVM-SERIES OK$'

case_dir="$TEST_TMP/k1b-names-log-state"
mkdir -p "$case_dir/tmp" "$case_dir/state" "$case_dir/a/same" "$case_dir/b/same"
cat > "$case_dir/unit.sh" <<'SH'
set -uo pipefail
# shellcheck source=/dev/null
source "$UNIT_LIBRARY"
STATE_DIR="$CASE_DIR/state"
printf '%s\n' "$(quote_name $'report\nFAIL injected\r\tfile')"
long="$(python3 -c 'print("名" * 140, end="")')"
printf '%s\n' "$(quote_name "$long")" | python3 -c 'import sys; s=sys.stdin.read().strip(); print("NAME-LENGTH", len(s)-2)'
printf '2026-11-15 4\n' > "$(streak_file dirty-same)"
repo_state_key "$CASE_DIR/a/same"; first="$REPO_STATE_KEY"
printf 'MIGRATED %s\n' "$(cat "$(streak_file "dirty-$first")")"
repo_state_key "$CASE_DIR/b/same"; second="$REPO_STATE_KEY"
[ "$first" = "$second" ] || printf 'SEPARATE\n'
printf '2026-11-16 9\n' > "$(streak_file "dirty-$first")"
printf 'OTHER %s\n' "$(cat "$(streak_file "dirty-$second")")"
streak_reset "dirty-$first"
repo_state_key "$CASE_DIR/a/same"
[ -f "$(streak_file "dirty-$first")" ] || printf 'MIGRATION ONCE\n'
python3 - "$CASE_DIR" <<'PY'
from pathlib import Path
import sys
for name in ('history', 'launch'):
    (Path(sys.argv[1]) / name).write_bytes(b'a' * 5242880)
PY
rotate_log "$CASE_DIR/history"
[ -f "$CASE_DIR/history.1" ] || printf 'AT-LIMIT KEPT\n'
printf 'b' >> "$CASE_DIR/history"
rotate_log "$CASE_DIR/history"
[ ! -e "$CASE_DIR/history" ] && [ -f "$CASE_DIR/history.1" ] && printf 'HISTORY ROTATED\n'
exec 9>> "$CASE_DIR/launch"
printf 'b' >&9
rotate_log "$CASE_DIR/launch" truncate
printf 'next\n' >&9
[ "$(cat "$CASE_DIR/launch")" = next ] && printf 'LAUNCH DESCRIPTOR OK\n'
[ -f "$CASE_DIR/launch.1" ] && printf 'LAUNCH ROTATED\n'
SH
UNIT_LIBRARY="$unit_library" CASE_DIR="$case_dir" "$TEST_BASH" "$case_dir/unit.sh" > "$case_dir/output.txt" 2>&1
assert_contains '改行・CR・タブのある名前も1行の引用に収める' "$case_dir/output.txt" '^「report FAIL injected  file」$'
assert_not_contains 'ファイル名から偽の FAIL 行を作れない' "$case_dir/output.txt" '^FAIL injected'
assert_contains '名前は120字で切る' "$case_dir/output.txt" '^NAME-LENGTH 120$'
assert_contains '既存の日数状態を引き継ぐ' "$case_dir/output.txt" '^MIGRATED 2026-11-15 4$'
assert_contains '同名リポは状態キーを分ける' "$case_dir/output.txt" '^SEPARATE$'
assert_contains '解除した日数を旧状態から復活させない' "$case_dir/output.txt" '^MIGRATION ONCE$'
assert_contains '別ルートの日数は連動しない' "$case_dir/output.txt" '^OTHER 2026-11-15 4$'
assert_contains 'ちょうど5MBでは回転しない' "$case_dir/output.txt" '^AT-LIMIT KEPT$'
assert_contains '5MBを超えた履歴を回転する' "$case_dir/output.txt" '^HISTORY ROTATED$'
assert_contains 'launchd の開いている出力先でも回転後の記録が残る' "$case_dir/output.txt" '^LAUNCH DESCRIPTOR OK$'
assert_contains 'launchd の旧ログを一世代残す' "$case_dir/output.txt" '^LAUNCH ROTATED$'

case_dir="$TEST_TMP/k1b-env-names"
make_remote_repo "$case_dir" names
printf '.env.*\n' > "$REPO_PATH/.gitignore"
printf 'PORT=3000\n' > "$REPO_PATH/.env.production"
printf '%s%s\n' '-----BEGIN PRIVATE' ' KEY-----' > "$REPO_PATH/"$'first\nWARN injected.txt'
run_health "$case_dir" "$case_dir/root with space"
assert_contains 'gitignore 済みの標準 env は参考に出す' "$case_dir/output.txt" 'gitignore 済みの env ファイル 「.env.production」'
assert_not_contains 'gitignore 済みの標準 env は WARN にしない' "$case_dir/output.txt" 'WARN .*git に入るおそれのある env ファイル'
assert_contains '改行入りファイルの FAIL は引用した1行に収める' "$case_dir/output.txt" 'FAIL .*「first WARN injected.txt」:1'
assert_not_contains '改行入りファイルから独立した WARN を作らない' "$case_dir/output.txt" '^WARN injected'

case_dir="$TEST_TMP/k1b-claude-old"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_claude "$fake_bin/claude"
run_security "$case_dir" "$fake_bin" RH_SECURITY_ONLY=1 RH_CLAUDE_CANDIDATES="$fake_bin/claude" FAKE_CLAUDE_OUTPUT=1.0.128 FAKE_BREW_LOG="$case_dir/brew.log" FAKE_BREW_LIST_LOG="$case_dir/list.log"
assert_count '最低版の点検は brew list --versions を引数なしで一度だけ取得する' "$case_dir/list.log" '^list --versions$' 1
assert_contains 'security-only でも claude 1.x を古い系列として WARN にする' "$case_dir/output.txt" 'WARN  Claude Code 1\.0\.128 — 古い系列（表の最低系列 2 より前）'
run_security "$case_dir" "$fake_bin" FAKE_BREW_LIST_RC=1 FAKE_BREW_LOG="$case_dir/brew.log"
assert_contains '導入済み brew の版を取れなければ最低版は未検査' "$case_dir/output.txt" 'Homebrew の最低版は導入済み版を取得できず未検査'

case_dir="$TEST_TMP/k1b-plist-fallback"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_app "$case_dir/apps" 'Test Browser' com.google.Chrome 156.0.8078.78
printf '#!/bin/bash\nexit 1\n' > "$fake_bin/plutil"
chmod +x "$fake_bin/plutil"
run_security "$case_dir" "$fake_bin" RH_APP_DIRS="$case_dir/apps" FAKE_BREW_LOG="$case_dir/brew.log"
assert_contains 'plutil raw 失敗時も PlistBuddy で最低版を読める' "$case_dir/output.txt" 'WARN  Chrome 156\.0\.8078\.78'
printf 'invalid plist\n' > "$case_dir/apps/Test Browser.app/Contents/Info.plist"
run_security "$case_dir" "$fake_bin" RH_APP_DIRS="$case_dir/apps" FAKE_BREW_LOG="$case_dir/brew.log"
assert_contains 'アプリがあって一件も読めなければ未検査' "$case_dir/output.txt" 'アプリの最低版は Info.plist を一件も読めず未検査'

case_dir="$TEST_TMP/k1b-native-cli"
fake_bin="$case_dir/fake-bin"
make_fake_brew "$fake_bin"
make_fake_cli_set "$fake_bin"
make_fake_claude "$case_dir/home/.local/bin/claude"
run_security "$case_dir" "$fake_bin" RH_SKIP_CLI=0 RH_AUTOFIX_CLI=1 \
  PATH="$case_dir/home/.local/bin:$fake_bin:/usr/bin:/bin" \
  RH_CLAUDE_CANDIDATES="$case_dir/home/.local/bin/claude" FAKE_CLAUDE_OUTPUT=2.1.250 \
  FAKE_CLAUDE_LATEST=3.0.0 FAKE_BREW_LOG="$case_dir/brew.log"
assert_contains 'native claude は現在版・上げ先・直し方を WARN にする' "$case_dir/output.txt" 'WARN  claude 2\.1\.250 → 3\.0\.0（claude update'
assert_not_contains 'native claude は自動更新しない' "$case_dir/output.txt" 'claude .*を自動更新'

case_dir="$TEST_TMP/k1b-node-lts"
mkdir -p "$case_dir/tmp"
cat > "$case_dir/unit.sh" <<'SH'
set -uo pipefail
# shellcheck source=/dev/null
source "$UNIT_LIBRARY"
TMP_DIR="$CASE_DIR/tmp"; SECURITY_MINIMUMS="$MINIMUMS"
RH_SKIP_CLI=0; RH_AUTOFIX_CLI=1
CLI_UPDATES=(); WARNINGS=(); NOTES=(); AUTOFIXED=()
# 外部コマンドの探索もこのシェルの中だけで置き換えます。
command() { if [ "${1:-}" = -v ] && [ "${2:-}" = node ]; then printf '/fixture/node\n'; else return 1; fi; }
current_version() { printf '24.22.1\n'; }
latest_version() { printf '26.12.1\n'; }
check_cli_tools
printf 'WARN-COUNT %s\n' "${#WARNINGS[@]}"
printf 'NOTE %s\n' "${CLI_UPDATES[@]}"
SH
UNIT_LIBRARY="$unit_library" CASE_DIR="$case_dir" MINIMUMS="$PROJECT_DIR/config/security-minimums.tsv" "$TEST_BASH" "$case_dir/unit.sh" > "$case_dir/output.txt" 2>&1
assert_contains 'サポート中の LTS は次系列の更新を WARN にしない' "$case_dir/output.txt" '^WARN-COUNT 0$'
assert_contains 'サポート中の LTS の更新案内は参考に出す' "$case_dir/output.txt" 'サポート中の LTS 系列 24\.22\.1 → 26\.12\.1'

case_dir="$TEST_TMP/k1b-install-retry"
fake_bin="$case_dir/fake-bin"
mkdir -p "$case_dir/home" "$fake_bin" "$case_dir/home/.nvm/alias" "$case_dir/home/.nvm/versions/node/v24.2.0/bin"
printf 'v24.2.0\n' > "$case_dir/home/.nvm/alias/default"
cat > "$fake_bin/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE_DIR/launchctl.log"
case "$1" in
  bootout) exit 0;;
  bootstrap) if [ ! -f "$CASE_DIR/tried" ]; then : > "$CASE_DIR/tried"; exit 5; fi; : > "$CASE_DIR/registered";;
  print) [ -f "$CASE_DIR/registered" ];;
esac
SH
chmod +x "$fake_bin/launchctl"
cat > "$fake_bin/gh" <<'SH'
#!/bin/bash
printf 'called\n' >> "$CASE_DIR/data-gh.log"
exit 1
SH
chmod +x "$fake_bin/gh"
HOME="$case_dir/home" PATH="$fake_bin:$PATH" CASE_DIR="$case_dir" \
  RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_NO_DESKTOP=1 RH_SKIP_SECURITY=1 \
  "$TEST_BASH" "$PROJECT_DIR/install.sh" > "$case_dir/output.txt" 2>&1
retry_rc=$?
if [ "$retry_rc" -eq 0 ]; then pass '一度失敗した bootstrap を再試行して install を完了する'; else fail '一度失敗した bootstrap を再試行して install を完了する'; fi
assert_count 'bootstrap は成功まで二度呼ぶ' "$case_dir/launchctl.log" '^bootstrap ' 2
assert_contains '定期実行の登録を print で確認する' "$case_dir/launchctl.log" '^print gui/[0-9]+/com.repo-health-kit$'
python3 - "$case_dir/home/Library/LaunchAgents/com.repo-health-kit.plist" "$case_dir/home" > "$case_dir/plist-path.txt" <<'PY_PATH'
import plistlib
import sys
from pathlib import Path
with open(sys.argv[1], 'rb') as handle:
    paths = plistlib.load(handle)['EnvironmentVariables']['PATH'].split(':')
if str(Path(sys.argv[2]) / '.nvm/versions/node/v24.2.0/bin') in paths:
    print('PLIST NVM OK')
PY_PATH
assert_contains 'plist にも nvm の既定 bin を足す' "$case_dir/plist-path.txt" '^PLIST NVM OK$'
assert_contains 'npm の場所を設定に残す'  "$case_dir/home/.config/repo-health-kit/config.sh" '^RH_NPM_DIR='
assert_contains '手元の clone の場所を設定に残す' "$case_dir/home/.config/repo-health-kit/config.sh" '^RH_CLONE_DIR='
if [ -f "$case_dir/home/.config/repo-health-kit/allow.tsv" ]; then pass 'install で空の据え置き表を作る'; else fail 'install で空の据え置き表を作る'; fi

# install の配布先にも新しい照合スクリプトが必要です。
if [ -f "$case_dir/home/Library/Application Support/repo-health-kit/bin/data-guard.py" ]; then pass 'install でデータ点検スクリプトを配置する'; else fail 'install でデータ点検スクリプトを配置する'; fi
if [ ! -f "$case_dir/data-gh.log" ]; then pass '環境で止めた GitHub 点検を設定ファイルで再有効化しない'; else fail '環境で止めた GitHub 点検を設定ファイルで再有効化しない'; fi

# ---- 0.7.0: データの守り（偽コマンド・偽リポのみ） ----
case_dir="$TEST_TMP/k2-integration"
make_remote_repo "$case_dir" app-a
fake_bin="$case_dir/fake-bin"
mkdir -p "$fake_bin"
cat > "$case_dir/scanner.py" <<'PY_DG_FAKE'
import os
from pathlib import Path
import sys
import time
with open(os.environ['K2_CALL_LOG'], 'a') as h:
    h.write('call\n')
mode = os.environ.get('K2_MODE', 'ok')
if mode == 'timeout':
    time.sleep(3)
print('DG\tWARN\tfixture_warn\tapp-a\tpublic.app_a_profiles\t確認が必要です')
print('DG\tINFO\tfixture_info\tapp-a\t-\t参考の点検結果です')
if mode != 'missing':
    paths = Path(sys.argv[-1]).read_bytes().split(b'\0')
    count = sum(bool(p) and (Path(os.fsdecode(p)) / '.git').exists() for p in paths)
    print(f'DG_DONE\t{count}\t1')
raise SystemExit(1 if mode == 'nonzero' else 0)
PY_DG_FAKE
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_SECURITY_ONLY=1 \
  RH_DATA_GUARD_SCANNER="$case_dir/scanner.py" K2_CALL_LOG="$case_dir/calls"
assert_count 'データの守りは全リポをまとめて一度呼ぶ' "$case_dir/calls" '^call$' 1
assert_contains 'security-only にデータの守りの節を出す' "$case_dir/output.txt" '## データの守り（Supabase ほか）'
assert_contains 'データの WARN は要対応に出す' "$case_dir/output.txt" 'WARN .*fixture_warn: 確認が必要です'
assert_contains 'データの INFO は専用節に出す' "$case_dir/output.txt" 'INFO .*fixture_info: 参考の点検結果です'
for dg_mode in missing nonzero timeout; do
  run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_SECURITY_ONLY=1 \
    RH_DATA_GUARD_SCANNER="$case_dir/scanner.py" K2_CALL_LOG="$case_dir/calls" \
    RH_DATA_GUARD_TIMEOUT=1 K2_MODE="$dg_mode"
  assert_contains "$dg_mode: データ点検の途中終了を未検査の WARN にする" "$case_dir/output.txt" 'WARN .*データの守りの点検が最後まで動きませんでした（未検査）'
done
: > "$case_dir/calls"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_SECURITY_ONLY=1 \
  RH_DATA_GUARD_SCANNER="$case_dir/scanner.py" K2_CALL_LOG="$case_dir/calls" RH_DATA_GUARD=0
assert_count 'RH_DATA_GUARD=0 ならデータの守りを呼ばない' "$case_dir/calls" '^call$' 0
assert_contains 'RH_DATA_GUARD=0 は「止めています」として注記する（0.7.1 で「未検査」から変更）' "$case_dir/output.txt" 'データの守りの点検は止めています（設定 RH_DATA_GUARD=0）'
assert_not_contains 'RH_DATA_GUARD=0 は未検査と書かない' "$case_dir/output.txt" 'RH_DATA_GUARD=0.*未検査'
cp "$TEST_TMP/k1-mail/fake-bin/security" "$TEST_TMP/k1-mail/fake-bin/curl" "$fake_bin/"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_MAIL_METHOD=resend RH_NOMAIL=0 \
  RH_MAIL_TO=fixture@example.invalid FAKE_MAIL_PAYLOAD="$case_dir/mail.json" \
  RH_DATA_GUARD_SCANNER="$case_dir/scanner.py" K2_CALL_LOG="$case_dir/calls"
if python3 - "$case_dir/mail.json" <<'PY_DG_MAIL'
import json
from pathlib import Path
import sys
body = json.loads(Path(sys.argv[1]).read_text())['text']
assert '■ データの守り（Supabase ほか）' in body
assert 'fixture_info: 参考の点検結果です' in body
assert 'WARN ' in body and 'fixture_warn' in body
PY_DG_MAIL
then pass 'データの要対応と参考をメール本文にも載せる'; else fail 'データの要対応と参考をメール本文にも載せる'; fi

# 一般の文面一致の据え置きでは、専用のデータ据え置き条件を迂回できません。
printf 'fixture_warn\t2026-12-01\tfixture\n' > "$case_dir/general-allow.tsv"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_TODAY=2026-11-16 \
  RH_ALLOW_FILE="$case_dir/general-allow.tsv" \
  RH_DATA_GUARD_SCANNER="$case_dir/scanner.py" K2_CALL_LOG="$case_dir/calls"
assert_contains '一般の allow.tsv ではデータの指摘を据え置けない' "$case_dir/output.txt" 'WARN .*fixture_warn: 確認が必要です'
mkdir -p "$REPO_PATH/supabase/migrations"
printf 'create table app_a_profiles(id uuid);\n' > "$REPO_PATH/supabase/migrations/001.sql"
run_k1_case "$case_dir" "$case_dir/root with space" "$fake_bin" RH_SECURITY_ONLY=1
assert_contains '実際のスキャナによる静的点検を本体の要対応へ載せる' "$case_dir/output.txt" 'WARN .*rls_off: migration の記述上は RLS'
assert_not_contains '実際のスキャナが最後まで動く' "$case_dir/output.txt" 'データの守りの点検が最後まで動きませんでした'

# ---- 0.8.0: dirty の指紋・fetch の理由・未マージ名・CLI 自動更新・止めた点検の書き方・既定のフォルダ・CI ----

file_mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

# §1 dirty の指紋: 同じ内容のまま続く dirty だけを WARN にする
case_dir="$TEST_TMP/dirty-fingerprint-same"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" fprepo
printf 'x\n' > "$REPO_PATH/private-file-name-9d2c.txt"
RH_TODAY=2026-11-01 run_health "$case_dir" "$case_dir/root with space"
assert_contains '同じ dirty の1日目は作業中' "$case_dir/output.txt" '「fprepo」 — dirty 1件（作業中・1日目）'
RH_TODAY=2026-11-02 run_health "$case_dir" "$case_dir/root with space"
assert_contains '同じ dirty の2日目は作業中' "$case_dir/output.txt" '「fprepo」 — dirty 1件（作業中・2日目）'
assert_not_contains '同じ dirty の2日目は WARN にしない' "$case_dir/output.txt" 'WARN  「fprepo」 .*dirty'
RH_TODAY=2026-11-03 run_health "$case_dir" "$case_dir/root with space"
assert_contains '同じ内容の dirty が3日続けば WARN' "$case_dir/output.txt" 'WARN  「fprepo」 — dirty 1件が同じ内容のまま3日（コミットまたは退避を確認してください）'
dirty_hash_path="$(find "$case_dir/state" -name 'dirty-*.hash' -print -quit)"
if [ -n "$dirty_hash_path" ] && LC_ALL=C grep -qxE '[0-9a-f]{40}' "$dirty_hash_path" && [ "$(file_mode_of "$dirty_hash_path")" = 600 ]; then
  pass 'dirty の指紋は 40 桁の値だけを権限 600 で保存する'
else
  fail 'dirty の指紋は 40 桁の値だけを権限 600 で保存する'
fi
if [ -n "$dirty_hash_path" ] && ! LC_ALL=C grep -rqF 'private-file-name-9d2c' "$case_dir/state" "$case_dir/log" "$case_dir/output.txt"; then
  pass 'dirty の指紋・状態・ログ・出力にファイル名を残さない'
else
  fail 'dirty の指紋・状態・ログ・出力にファイル名を残さない'
fi

case_dir="$TEST_TMP/dirty-fingerprint-changing"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" moverepo
printf 'a\n' > "$REPO_PATH/a.txt"
RH_TODAY=2026-11-01 run_health "$case_dir" "$case_dir/root with space"
printf 'b\n' > "$REPO_PATH/b.txt"
RH_TODAY=2026-11-02 run_health "$case_dir" "$case_dir/root with space"
assert_contains '内容が変わった dirty は日数を数え直す' "$case_dir/output.txt" '「moverepo」 — dirty 2件（作業中・1日目）'
printf 'c\n' > "$REPO_PATH/c.txt"
RH_TODAY=2026-11-03 run_health "$case_dir" "$case_dir/root with space"
assert_contains '毎日ファイルが変わる dirty は3日目も作業中' "$case_dir/output.txt" '「moverepo」 — dirty 3件（作業中・1日目）'
assert_not_contains '毎日ファイルが変わる dirty は WARN にしない' "$case_dir/output.txt" 'WARN  「moverepo」 .*dirty'
RH_TODAY=2026-11-04 run_health "$case_dir" "$case_dir/root with space"
assert_contains '変化が止まれば同じ内容として数え直した日数が進む' "$case_dir/output.txt" '「moverepo」 — dirty 3件（作業中・2日目）'
rm -f "$REPO_PATH/a.txt" "$REPO_PATH/b.txt" "$REPO_PATH/c.txt"
RH_TODAY=2026-11-05 run_health "$case_dir" "$case_dir/root with space"
assert_contains '消えて clean に戻れば dirty 0 件' "$case_dir/output.txt" '「moverepo」 — fetch=SKIP .* dirty=0 '
if [ -z "$(find "$case_dir/state" -name 'dirty-*' -print -quit)" ]; then pass 'clean に戻ったら dirty の日数と指紋を消す'; else fail 'clean に戻ったら dirty の日数と指紋を消す'; fi

case_dir="$TEST_TMP/dirty-rename-count"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" renrepo
git -C "$REPO_PATH" mv README.md RENAMED.md
run_health "$case_dir" "$case_dir/root with space"
assert_contains '名前の変更は 1 件として数える' "$case_dir/output.txt" '「renrepo」 — fetch=SKIP .* dirty=1 stash=0'

# §2 fetch の失敗の理由: stderr は分類だけに使い、中身（URL）を出さない
make_fake_fetch_git() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/git" <<'SH'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = fetch ]; then
    printf 'fetch\n' >> "${FAKE_GIT_LOG:?}"
    if [ -n "${FAKE_GIT_PASS_AFTER-}" ] && [ "$(wc -l < "$FAKE_GIT_LOG")" -gt "$FAKE_GIT_PASS_AFTER" ]; then exec "${REAL_GIT:?}" "$@"; fi
    printf '%s\n' "${FAKE_GIT_STDERR-}" >&2
    exit "${FAKE_GIT_RC:-128}"
  fi
done
exec "${REAL_GIT:?}" "$@"
SH
  printf '%s\n' '#!/bin/bash' 'exit 0' > "$fake_bin/sleep"
  chmod +x "$fake_bin/git" "$fake_bin/sleep"
}

run_fetch_health() {
  local case_dir="$1" root="$2" fake_bin="$3" output
  shift 3
  output="$case_dir/output.txt"
  mkdir -p "$case_dir/home"
  env PATH="$fake_bin:$PATH" REAL_GIT="$(command -v git)" FAKE_GIT_LOG="$case_dir/fetch.log" \
    HOME="$case_dir/home" RH_CONFIG_FILE="$case_dir/no-config.sh" RH_ROOTS="$root" \
    RH_LOG_DIR="$case_dir/log" RH_STATE_DIR="$case_dir/state" \
    RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=0 RH_SKIP_SECURITY=1 \
    RH_AUTOFIX_PULL=0 RH_MAIL_METHOD=none RH_NOMAIL=1 RH_NO_DESKTOP=1 \
    "$@" "$TEST_BASH" "$HEALTH" > "$output" 2>&1 || true
}

fake_url='https://FAKE-URL-SECRET-7f3a@git.example.invalid/org/repo.git'
for fetch_case in auth host timeout exitcode other; do
  case_dir="$TEST_TMP/fetch-reason-$fetch_case"
  mkdir -p "$case_dir"
  make_remote_repo "$case_dir" fetchrepo
  fake_bin="$case_dir/fake-bin"
  make_fake_fetch_git "$fake_bin"
  case "$fetch_case" in
    auth) fetch_err="fatal: could not read Username for '$fake_url': terminal prompts disabled"; fetch_rc=128; reason='認証'; hint='gh auth status か鍵を確認してください';;
    host) fetch_err="fatal: unable to access '$fake_url/': Could not resolve host: git.example.invalid"; fetch_rc=128; reason='ホスト不明'; hint='ネットと remote の URL を確認してください';;
    timeout) fetch_err="fatal: unable to access '$fake_url/': Operation timed out after 60001 milliseconds"; fetch_rc=128; reason='タイムアウト'; hint='回線を確認してください';;
    exitcode) fetch_err=''; fetch_rc=142; reason='タイムアウト'; hint='回線を確認してください';;
    other) fetch_err="fatal: repository '$fake_url/' not found"; fetch_rc=128; reason='その他'; hint='remote と認証を確認してください';;
  esac
  RH_TODAY=2026-11-01 run_fetch_health "$case_dir" "$case_dir/root with space" "$fake_bin" FAKE_GIT_STDERR="$fetch_err" FAKE_GIT_RC="$fetch_rc"
  assert_contains "$fetch_case: fetch 失敗の1日目は理由と次の一手を WARN に出す" "$case_dir/output.txt" "WARN  「fetchrepo」 — fetch 失敗（理由: ${reason}・1日目。継続すると FAIL。${hint}）"
  assert_count "$fetch_case: fetch は 1 度だけやり直す" "$case_dir/fetch.log" '^fetch$' 2
  RH_TODAY=2026-11-02 run_fetch_health "$case_dir" "$case_dir/root with space" "$fake_bin" FAKE_GIT_STDERR="$fetch_err" FAKE_GIT_RC="$fetch_rc"
  assert_contains "$fetch_case: 2日連続は理由と次の一手を FAIL に出す" "$case_dir/output.txt" "FAIL  「fetchrepo」 — fetch 失敗が2日連続（理由: ${reason}。${hint}）"
  assert_not_contains "$fetch_case: stderr の中身（URL）を出さない" "$case_dir/output.txt" 'FAKE-URL-SECRET-7f3a|git\.example\.invalid'
  if ! LC_ALL=C grep -rqF 'FAKE-URL-SECRET-7f3a' "$case_dir/log" "$case_dir/state"; then pass "$fetch_case: stderr の中身をログ・状態に残さない"; else fail "$fetch_case: stderr の中身をログ・状態に残さない"; fi
done

case_dir="$TEST_TMP/fetch-retry-ok"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" retryrepo
fake_bin="$case_dir/fake-bin"
make_fake_fetch_git "$fake_bin"
run_fetch_health "$case_dir" "$case_dir/root with space" "$fake_bin" FAKE_GIT_STDERR='fatal: Could not resolve host: x' FAKE_GIT_PASS_AFTER=1
assert_contains '1 回目の失敗は 2 回目で成功すれば fetch=OK' "$case_dir/output.txt" '「retryrepo」 — fetch=OK '
assert_not_contains '1 回目の失敗は 2 回目で成功すれば知らせない' "$case_dir/output.txt" 'fetch 失敗'
assert_count '失敗のあとの再試行は 1 度だけ' "$case_dir/fetch.log" '^fetch$' 2
case_dir="$TEST_TMP/fetch-plain-ok"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" plainrepo
run_fetch_health "$case_dir" "$case_dir/root with space" "$case_dir/no-fake-bin"
assert_contains '偽コマンドなしの fetch は成功する' "$case_dir/output.txt" '「plainrepo」 — fetch=OK '

# §3 未マージ remote ブランチは名前だけ（先頭 5 本・名前の `|` は除く）
push_remote_branches() {
  local case_dir="$1" name
  shift
  git clone -q "$case_dir/origin.git" "$case_dir/writer" 2>/dev/null
  git -C "$case_dir/writer" config user.name tester
  git -C "$case_dir/writer" config user.email tester@example.invalid
  for name in "$@"; do
    git -C "$case_dir/writer" checkout -q -b "$name"
    printf '%s\n' "$name" > "$case_dir/writer/branch-file.txt"
    git -C "$case_dir/writer" add branch-file.txt
    git -C "$case_dir/writer" commit -q -m "test: $name"
    git -C "$case_dir/writer" push -q origin "$name"
    git -C "$case_dir/writer" checkout -q -
  done
  git -C "$REPO_PATH" fetch -q origin
}
case_dir="$TEST_TMP/unmerged-two"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" mergetwo
push_remote_branches "$case_dir" feature/a fix/b
run_health "$case_dir" "$case_dir/root with space"
assert_contains '未マージ remote ブランチは名前を出す（2 本）' "$case_dir/output.txt" 'WARN  「mergetwo」 — 未マージ remote ブランチ 2 本（feature/a・fix/b）'
case_dir="$TEST_TMP/unmerged-seven"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" mergeseven
push_remote_branches "$case_dir" wip/c1 wip/c2 wip/c3 wip/c4 wip/c5 wip/c6 wip/c7
run_health "$case_dir" "$case_dir/root with space"
assert_contains '未マージ remote ブランチは先頭 5 本と「ほか N 本」（7 本）' "$case_dir/output.txt" 'WARN  「mergeseven」 — 未マージ remote ブランチ 7 本（wip/c1・wip/c2・wip/c3・wip/c4・wip/c5・ほか 2 本）'
assert_not_contains '6 本目以降の名前は出さない' "$case_dir/output.txt" 'wip/c6'
case_dir="$TEST_TMP/unmerged-pipe"
mkdir -p "$case_dir"
make_remote_repo "$case_dir" mergepipe
push_remote_branches "$case_dir" 'wip|pipe'
run_health "$case_dir" "$case_dir/root with space"
assert_contains '名前の `|` は除いて出す' "$case_dir/output.txt" 'WARN  「mergepipe」 — 未マージ remote ブランチ 1 本（wippipe）'
assert_not_contains '名前の `|` を表示に残さない' "$case_dir/output.txt" 'wip\|pipe'

# §4 RH_AUTOFIX_CLI=1 のときだけ、npm で入れた CLI のマイナー・パッチ遅れも自動更新する
make_npm_installed_claude() {
  local case_dir="$1" fake_bin="$2"
  make_fake_brew "$fake_bin"
  make_fake_cli_set "$fake_bin"
  make_fake_claude "$case_dir/lib/node_modules/@anthropic-ai/claude-code/bin/claude"
  ln -s "$case_dir/lib/node_modules/@anthropic-ai/claude-code/bin/claude" "$fake_bin/claude"
  mv "$fake_bin/npm-fixture" "$fake_bin/npm-fixture-orig"
  cat > "$fake_bin/npm-fixture" <<'SH'
#!/bin/bash
if [ "${1:-}" = install ]; then printf '%s\n' "$*" >> "${FAKE_NPM_INSTALL_LOG:?}"; exit "${FAKE_NPM_INSTALL_RC:-0}"; fi
exec "$0-orig" "$@"
SH
  chmod +x "$fake_bin/npm-fixture"
}
case_dir="$TEST_TMP/cli-minor-autofix"
fake_bin="$case_dir/fake-bin"
make_npm_installed_claude "$case_dir" "$fake_bin"
: > "$case_dir/install.log"
run_security "$case_dir" "$fake_bin" RH_SKIP_CLI=0 RH_AUTOFIX_CLI=1 FAKE_BREW_LOG="$case_dir/brew.log" \
  FAKE_CLAUDE_OUTPUT=2.1.250 FAKE_CLAUDE_LATEST=2.1.300 FAKE_NPM_INSTALL_LOG="$case_dir/install.log"
assert_contains 'RH_AUTOFIX_CLI=1 は npm 導入の CLI のマイナー遅れを自動更新する' "$case_dir/output.txt" 'claude — 2\.1\.250 → 2\.1\.300 を自動更新'
assert_contains '自動更新は公開から 3 日以上の上げ先を npm install -g する' "$case_dir/install.log" '^install -g @anthropic-ai/claude-code@2\.1\.300$'
assert_not_contains '自動更新できた CLI は更新あり一覧・WARN に出さない' "$case_dir/output.txt" 'WARN  claude — 2\.1\.250|CLI 更新あり: [1-9]|^- claude — 2\.1\.250 → 2\.1\.300$'
: > "$case_dir/install.log"
run_security "$case_dir" "$fake_bin" RH_SKIP_CLI=0 RH_AUTOFIX_CLI=0 FAKE_BREW_LOG="$case_dir/brew.log" \
  FAKE_CLAUDE_OUTPUT=2.1.250 FAKE_CLAUDE_LATEST=2.1.300 FAKE_NPM_INSTALL_LOG="$case_dir/install.log"
assert_contains 'RH_AUTOFIX_CLI=0 のマイナー遅れは並べるだけ' "$case_dir/output.txt" '^- claude — 2\.1\.250 → 2\.1\.300$'
assert_not_contains 'RH_AUTOFIX_CLI=0 は自動更新しない' "$case_dir/output.txt" 'claude .*を自動更新'
assert_count 'RH_AUTOFIX_CLI=0 は npm install を呼ばない' "$case_dir/install.log" 'install' 0
run_security "$case_dir" "$fake_bin" RH_SKIP_CLI=0 RH_AUTOFIX_CLI=1 FAKE_BREW_LOG="$case_dir/brew.log" \
  FAKE_CLAUDE_OUTPUT=2.1.250 FAKE_CLAUDE_LATEST=2.1.300 FAKE_NPM_INSTALL_LOG="$case_dir/install.log" FAKE_NPM_INSTALL_RC=1
assert_contains '自動更新に失敗したら WARN にコマンドを出す' "$case_dir/output.txt" 'WARN  claude — 2\.1\.250 → 2\.1\.300 の自動更新に失敗しました（npm install -g @anthropic-ai/claude-code@2\.1\.300）'
assert_not_contains '自動更新に失敗した CLI を「自動更新」と書かない' "$case_dir/output.txt" 'claude — 2\.1\.250 → 2\.1\.300 を自動更新'

# §5 止めた GitHub の点検は「止めています」、gh 不在・未ログインは「未検査」のまま（3 日目の WARN は後者だけ）
case_dir="$TEST_TMP/github-stopped-vs-missing"
mkdir -p "$case_dir/fake-bin" "$case_dir/home"
make_remote_repo "$case_dir" ghrepo
cat > "$case_dir/scanner-no-gh.py" <<'PY_NOGH'
import os
import runpy
# gh を探せない環境の PATH にして、本物のスキャナを動かします。
os.environ['PATH'] = os.environ['K5_SCANNER_PATH']
runpy.run_path(os.environ['K5_REAL_SCANNER'], run_name='__main__')
PY_NOGH
for day in 2026-11-01 2026-11-02 2026-11-03; do
  run_k1_case "$case_dir" "$case_dir/root with space" "$case_dir/fake-bin" RH_SECURITY_ONLY=1 RH_TODAY="$day" RH_DATA_GITHUB=0 \
    RH_DATA_GUARD_SCANNER="$case_dir/scanner-no-gh.py" K5_REAL_SCANNER="$PROJECT_DIR/bin/data-guard.py" K5_SCANNER_PATH=/usr/bin:/bin
done
assert_contains 'RH_DATA_GITHUB=0 は「止めています」と書く' "$case_dir/output.txt" 'GitHub の点検は止めています（設定 RH_DATA_GITHUB=0）'
assert_not_contains 'RH_DATA_GITHUB=0 は 3 日続いても未検査の WARN に上げない' "$case_dir/output.txt" 'WARN .*GitHub.*未検査'
assert_not_contains 'RH_DATA_GITHUB=0 の注記に「未検査」を入れない' "$case_dir/output.txt" 'RH_DATA_GITHUB=0.*未検査'
rm -rf "$case_dir/state"
for day in 2026-11-01 2026-11-02 2026-11-03; do
  run_k1_case "$case_dir" "$case_dir/root with space" "$case_dir/fake-bin" RH_SECURITY_ONLY=1 RH_TODAY="$day" RH_DATA_GITHUB=1 \
    RH_DATA_GUARD_SCANNER="$case_dir/scanner-no-gh.py" K5_REAL_SCANNER="$PROJECT_DIR/bin/data-guard.py" K5_SCANNER_PATH=/usr/bin:/bin
done
assert_contains 'gh が無いときは「未検査」と書く' "$case_dir/output.txt" 'gh が入っていないため GitHub の公開設定・Dependabot は未検査'
assert_contains 'gh が無い状態が 3 日続けば WARN に上げる' "$case_dir/output.txt" 'WARN .*gh が入っていないため GitHub の公開設定・Dependabot は未検査（未検査が続いて3日目'

# §7 既定の点検フォルダ: 設定に RH_ROOTS が無いときは ~/Plugins と ~/projects のうち存在するもの
run_default_roots() {
  local case_dir="$1"
  shift
  mkdir -p "$case_dir/home"
  env -u RH_ROOTS HOME="$case_dir/home" RH_CONFIG_FILE="$case_dir/config.sh" \
    RH_LOG_DIR="$case_dir/log" RH_STATE_DIR="$case_dir/state" \
    RH_SKIP_AUDIT=1 RH_SKIP_CLI=1 RH_SKIP_FETCH=1 RH_SKIP_SECURITY=1 \
    RH_AUTOFIX_PULL=0 RH_MAIL_METHOD=none RH_NOMAIL=1 RH_NO_DESKTOP=1 \
    "$@" "$TEST_BASH" "$HEALTH" > "$case_dir/output.txt" 2>&1 || true
}
case_dir="$TEST_TMP/roots-projects-only"
mkdir -p "$case_dir/home/projects"
make_remote_repo "$case_dir" seed
git clone -q "$case_dir/origin.git" "$case_dir/home/projects/projrepo" 2>/dev/null
run_default_roots "$case_dir"
assert_contains 'ホームの projects だけがあれば、そこを点検する' "$case_dir/output.txt" '「projrepo」 — fetch=SKIP'
assert_not_contains 'ホームの projects だけがあれば 0 件の FAIL を出さない' "$case_dir/output.txt" '対象リポが0件'
case_dir="$TEST_TMP/roots-both"
mkdir -p "$case_dir/home/projects" "$case_dir/home/Plugins"
make_remote_repo "$case_dir" seed
git clone -q "$case_dir/origin.git" "$case_dir/home/projects/projrepo" 2>/dev/null
git clone -q "$case_dir/origin.git" "$case_dir/home/Plugins/plugrepo" 2>/dev/null
run_default_roots "$case_dir"
assert_contains '両方あればホームの Plugins を点検する' "$case_dir/output.txt" '「plugrepo」 — fetch=SKIP'
assert_contains '両方あればホームの projects も点検する' "$case_dir/output.txt" '「projrepo」 — fetch=SKIP'
case_dir="$TEST_TMP/roots-plugins-only"
mkdir -p "$case_dir/home/Plugins"
make_remote_repo "$case_dir" seed
git clone -q "$case_dir/origin.git" "$case_dir/home/Plugins/plugrepo" 2>/dev/null
run_default_roots "$case_dir"
assert_contains 'ホームの Plugins だけでも今までどおり点検する' "$case_dir/output.txt" '「plugrepo」 — fetch=SKIP'
assert_not_contains 'ホームの projects が無ければ「対象ルートがありません」を出さない' "$case_dir/output.txt" '対象ルートがありません'
case_dir="$TEST_TMP/roots-neither"
mkdir -p "$case_dir/home"
run_default_roots "$case_dir"
assert_contains 'どちらも無ければ 0 件の案内を出す' "$case_dir/output.txt" 'FAIL  対象リポが0件です（RH_ROOTS の設定を確認してください）'
case_dir="$TEST_TMP/roots-config-wins"
mkdir -p "$case_dir/home/projects" "$case_dir/home/Plugins"
make_remote_repo "$case_dir" seed
git clone -q "$case_dir/origin.git" "$case_dir/home/projects/projrepo" 2>/dev/null
git clone -q "$case_dir/origin.git" "$case_dir/home/Plugins/plugrepo" 2>/dev/null
printf 'RH_ROOTS=("$HOME/Plugins")\n' > "$case_dir/config.sh"
chmod 600 "$case_dir/config.sh"
run_default_roots "$case_dir"
assert_contains '設定に RH_ROOTS があればそのとおりに点検する' "$case_dir/output.txt" '「plugrepo」 — fetch=SKIP'
assert_not_contains '設定に RH_ROOTS があればホームの projects を足さない' "$case_dir/output.txt" '「projrepo」'
assert_not_contains '設定例は RH_ROOTS を直書きしない（既定を上書きしない）' "$PROJECT_DIR/config/config.example.sh" '^RH_ROOTS='

# §8 CI（GitHub Actions）: アクションはコミットの SHA で固定・秘密を使わない・権限は読み取りだけ
workflow="$PROJECT_DIR/.github/workflows/tests.yml"
if [ -f "$workflow" ]; then pass 'CI のワークフローがある'; else fail 'CI のワークフローがある'; fi
uses_total="$(LC_ALL=C grep -cE '^[[:space:]]*(-[[:space:]]+)?uses:' "$workflow" || true)"
uses_pinned="$(LC_ALL=C grep -cE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9][0-9.]*$' "$workflow" || true)"
if [ "${uses_total:-0}" -ge 1 ] && [ "$uses_total" = "$uses_pinned" ]; then pass 'CI のアクションはすべてコミットの SHA で固定し、行末にタグを書く'; else fail 'CI のアクションはすべてコミットの SHA で固定し、行末にタグを書く'; fi
assert_contains 'CI の権限は contents: read だけ' "$workflow" '^permissions:$'
assert_contains 'CI は contents を読み取りだけにする' "$workflow" '^  contents: read$'
assert_not_contains 'CI は write 権限を持たない' "$workflow" ':[[:space:]]*write'
assert_not_contains 'CI は秘密を使わない' "$workflow" 'secrets\.'
assert_contains 'CI は macOS で動かす' "$workflow" 'runs-on: macos-latest'
assert_contains 'CI は push（main）と pull_request で動く' "$workflow" '^  pull_request:$'
assert_contains 'CI は回帰テストを動かす' "$workflow" 'tests/run-tests\.sh'
ci_denied=0
while IFS=$'\t' read -r denied_action _denied_reason; do
  case "$denied_action" in ''|\#*) continue;; esac
  if LC_ALL=C grep -qiF "$denied_action" "$workflow"; then ci_denied=1; fi
done < "$PROJECT_DIR/config/actions-denylist.tsv"
if [ "$ci_denied" = 0 ]; then pass 'CI のアクションは侵害リストに当たらない'; else fail 'CI のアクションは侵害リストに当たらない'; fi

python3 -I "$PROJECT_DIR/tests/data_guard_test.py" > "$TEST_TMP/data-guard-tests.log" 2>&1
dg_test_rc=$?
cat "$TEST_TMP/data-guard-tests.log"
read -r _dg_tag dg_total dg_failed < <(tail -1 "$TEST_TMP/data-guard-tests.log")
if [ "${_dg_tag:-}" = DG_TEST_COUNTS ] && [ "${dg_total:-0}" -gt 0 ]; then
  total=$((total + dg_total)); failed=$((failed + dg_failed))
  if [ "$dg_test_rc" -ne 0 ] && [ "$dg_failed" -eq 0 ]; then fail 'データ点検テストの実行が完了する'; fi
else
  fail 'データ点検テストの件数を確認する'
fi

if [ "$failed" -gt 0 ]; then
  printf '# %s/%s tests failed\n' "$failed" "$total"
  exit 1
fi
printf '# all %s tests passed\n' "$total"
