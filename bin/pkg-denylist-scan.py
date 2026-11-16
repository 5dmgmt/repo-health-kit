#!/usr/bin/env python3
"""JavaScript/Python の lock を既知の侵害パッケージ一覧と照合します。

照合リストの形式: 名前<TAB>版<TAB>出典・理由
- 版の列が `*` の行は「その名前なら全版が対象」です。
- 名前の先頭が `pypi:` の行は Python のパッケージです（PEP 503 で名前を正規化して比べます）。
  先頭に `pypi:` が無い行は npm で、名前は正規化しません。
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterator

DEFAULT_DENYLIST = Path(__file__).resolve().parent.parent / "config" / "pkg-denylist.tsv"
DEFAULT_ROOT = Path.home() / "Plugins"
PYTHON_LOCK_NAMES = {"poetry.lock", "uv.lock", "Pipfile.lock"}
NPM_LOCK_NAMES = {
    "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"
}
PYPI_PREFIX = "pypi:"
ANY_VERSION = "*"


def safe_field(value: str) -> str:
    """区切り文字と制御文字をレポートへ持ち込まないようにします。"""
    return "".join("_" if char == "|" else char for char in value if ord(char) >= 32 and ord(char) != 127)


def pep503_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def load_denylist(path: Path) -> dict[str, dict[tuple[str, str], str]]:
    entries: dict[str, dict[tuple[str, str], str]] = {"npm": {}, "pypi": {}}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        raw_name, version = parts[0].strip(), parts[1].strip()
        reason = parts[2].strip() if len(parts) > 2 else "理由未記入"
        ecosystem = "npm"
        name = raw_name
        if raw_name.startswith(PYPI_PREFIX):
            ecosystem = "pypi"
            name = pep503_name(raw_name[len(PYPI_PREFIX):])
        if name and version:
            entries[ecosystem][(name, version)] = reason
    return entries


def tracked_lockfiles(repo: Path) -> list[tuple[Path, str]]:
    """照合する lock の一覧です。

    npm: ルートの lock（追跡の有無によらず）と、追跡中の入れ子の lock。
    Python: 追跡中（git ls-files）の requirements*.txt・poetry.lock・uv.lock・Pipfile.lock だけ。
    """
    found: list[tuple[Path, str]] = []
    seen: set[Path] = set()

    def add(lockfile: Path, ecosystem: str) -> None:
        if lockfile not in seen and lockfile.is_file():
            seen.add(lockfile)
            found.append((lockfile, ecosystem))

    for lock_name in sorted(NPM_LOCK_NAMES):
        add(repo / lock_name, "npm")
    try:
        result = subprocess.run(
            ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
             "-c", "core.sshCommand=ssh", "-c", "core.quotepath=false", "ls-files", "-z"],
            cwd=repo,
            capture_output=True,
            timeout=30,
            check=False,
        )
        for raw in result.stdout.split(b"\0"):
            if not raw:
                continue
            try:
                rel = raw.decode("utf-8")
            except UnicodeDecodeError:
                continue
            path = Path(rel)
            if "node_modules" in path.parts:
                continue
            if path.name in NPM_LOCK_NAMES:
                add(repo / path, "npm")
            elif path.name in PYTHON_LOCK_NAMES or (
                path.name.startswith("requirements") and path.suffix == ".txt"
            ):
                add(repo / path, "pypi")
    except (subprocess.SubprocessError, OSError):
        pass
    return found


def npm_packages(lockfile: Path) -> Iterator[tuple[str, str]]:
    if lockfile.name == "pnpm-lock.yaml":
        yield from pnpm_packages(lockfile)
        return
    if lockfile.name == "yarn.lock":
        yield from yarn_packages(lockfile)
        return
    if lockfile.name == "bun.lock":
        yield from bun_packages(lockfile)
        return
    data = json.loads(lockfile.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("lock の最上位が object ではありません")

    packages = data.get("packages", {})
    if not isinstance(packages, dict):
        raise ValueError("packages が object ではありません")
    for package_path, info in packages.items():
        if not package_path or not isinstance(info, dict):
            continue
        name = info.get("name") or package_path.split("node_modules/")[-1]
        version = info.get("version")
        if isinstance(name, str) and isinstance(version, str):
            yield name, version

    def walk(dependencies: object) -> Iterator[tuple[str, str]]:
        if dependencies is None:
            return
        if not isinstance(dependencies, dict):
            raise ValueError("dependencies が object ではありません")
        for name, info in dependencies.items():
            if not isinstance(name, str) or not isinstance(info, dict):
                continue
            version = info.get("version")
            if isinstance(version, str):
                yield name, version
            yield from walk(info.get("dependencies"))

    yield from walk(data.get("dependencies"))


def resolved_package(value: str) -> tuple[str, str] | None:
    """name@version / @scope/name@version を、peer の付記を除いて読みます。"""
    match = re.fullmatch(r"(@[^/@\s]+/[^/@\s]+|[^/@\s]+)@(?:npm:)?([0-9][^()\s]*)[()\s]?.*", value)
    if not match:
        return None
    return match.group(1), match.group(2)


def pnpm_packages(lockfile: Path) -> Iterator[tuple[str, str]]:
    lines = lockfile.read_text(encoding="utf-8").splitlines()
    in_packages = False
    saw_packages = False
    key_indent = 0
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw.startswith((" ", "\t")):
            in_packages = bool(re.fullmatch(r"packages:\s*(?:\{\})?\s*(?:#.*)?", raw))
            saw_packages = saw_packages or in_packages
            key_indent = 0
            continue
        if not in_packages:
            continue
        indent = len(raw) - len(raw.lstrip())
        if not key_indent:
            key_indent = indent
        if indent != key_indent:
            continue
        match = re.match(r"\s*(?:'([^']+)'|\"([^\"]+)\"|([^\s]+?)):\s*(?:\{\})?\s*(?:#.*)?$", raw)
        if not match:
            raise ValueError("packages のキーを読めません")
        key = next(part for part in match.groups() if part is not None).lstrip("/")
        package = resolved_package(key)
        if package is None:
            # 古い pnpm の /name/version と /@scope/name/version も扱います。
            legacy = re.fullmatch(r"(.+)/([0-9][^()\s]*)(?:\(.*\))?", key)
            package = (legacy.group(1), legacy.group(2)) if legacy else None
        if package is None:
            raise ValueError("packages の名前と版を読めません")
        yield package
    if not saw_packages and not any(re.fullmatch(r"(?:importers|dependencies|devDependencies):\s*\{\}", line) for line in lines):
        raise ValueError("packages の一覧がありません")


def yarn_packages(lockfile: Path) -> Iterator[tuple[str, str]]:
    lines = lockfile.read_text(encoding="utf-8").splitlines()
    names: list[str] = []
    version = ""
    resolution = ""
    saw_entry = False

    def entry() -> Iterator[tuple[str, str]]:
        package = resolved_package(resolution) if resolution else None
        if package:
            yield package
        elif version:
            for name in names:
                yield name, version
        elif names:
            raise ValueError("yarn の版を読めません")

    for raw in [*lines, "__end__:"]:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw.startswith((" ", "\t")):
            yield from entry()
            names = []
            version = ""
            resolution = ""
            if not raw.rstrip().endswith(":"):
                raise ValueError("yarn の見出しを読めません")
            key = raw.rstrip()[:-1].strip().strip("\"'")
            if key in {"__metadata", "__end__"}:
                continue
            # v1 の複数 selector と berry の npm:/patch: などの selector。
            for selector in re.split(r"\s*,\s*", key):
                match = re.match(r"[\"']?(@[^/@\s]+/[^/@\s]+|[^/@\s]+)@", selector)
                if match:
                    names.append(match.group(1))
            if not names:
                raise ValueError("yarn の名前を読めません")
            saw_entry = True
            continue
        match = re.match(r"\s*(version|resolution)(?:\s+|:\s*)[\"']?([^\"'\s]+)", raw)
        if match:
            if match.group(1) == "version":
                version = match.group(2)
            else:
                resolution = match.group(2)
    if not saw_entry and not any("yarn lockfile v1" in line or line.startswith("__metadata:") for line in lines):
        raise ValueError("yarn の一覧がありません")


def bun_packages(lockfile: Path) -> Iterator[tuple[str, str]]:
    """bun のテキスト lock のコメント・末尾カンマを、文字列を保って除きます。"""
    raw = lockfile.read_text(encoding="utf-8")
    strings = r""""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"""
    comments = re.compile(strings + r"|//[^\n]*|/\*[\s\S]*?\*/")
    text = comments.sub(lambda match: match.group() if match.group().startswith(('"', "'")) else " ", raw)
    keys = re.compile(strings + r"|([A-Za-z_$][A-Za-z0-9_$]*)\s*:")

    def json_token(match: re.Match[str]) -> str:
        token = match.group()
        if token.startswith("'"):
            return json.dumps(ast.literal_eval(token))
        if token.startswith('"'):
            return token
        return json.dumps(match.group(1)) + ":"

    text = keys.sub(json_token, text)
    commas = re.compile(r'"(?:[^"\\]|\\.)*"|,\s*(?=[}\]])')
    text = commas.sub(lambda match: match.group() if match.group().startswith('"') else "", text)
    data = json.loads(text)
    if not isinstance(data, dict) or not isinstance(data.get("packages"), dict):
        raise ValueError("bun の packages がありません")
    for info in data["packages"].values():
        if not isinstance(info, list) or not info or not isinstance(info[0], str):
            raise ValueError("bun の名前と版を読めません")
        package = resolved_package(info[0])
        if package:
            yield package
        elif not any(marker in info[0] for marker in ("@workspace:", "@file:", "@link:", "@git", "@https:")):
            raise ValueError("bun の名前と版を読めません")


def requirements_packages(lockfile: Path) -> Iterator[tuple[str, str]]:
    pattern = re.compile(
        r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^]]+\])?\s*===?\s*([^\s;#\\]+)"
    )
    lines = lockfile.read_text(encoding="utf-8").splitlines()
    for line in lines:
        match = pattern.match(line)
        if match:
            yield match.group(1), match.group(2)


def toml_lock_packages(lockfile: Path) -> Iterator[tuple[str, str]]:
    """poetry.lock / uv.lock の [[package]] ごとの name と version を読みます。"""
    lines = lockfile.read_text(encoding="utf-8").splitlines()
    name = ""
    version = ""
    in_package = False
    for raw in [*lines, "[[package]]"]:
        line = raw.strip()
        if line.startswith("["):
            # 見出しに来たら、直前の [[package]] の name と version をここで確定する。
            # [package.dependencies] など下位の表の中身は読まない。
            if in_package and name and version:
                yield name, version
            name = ""
            version = ""
            in_package = line == "[[package]]"
            continue
        if not in_package:
            continue
        match = re.match(r'^name\s*=\s*["\']([^"\']+)["\']', line)
        if match and not name:
            name = match.group(1)
            continue
        match = re.match(r'^version\s*=\s*["\']([^"\']+)["\']', line)
        if match and not version:
            version = match.group(1)


def pipfile_packages(lockfile: Path) -> Iterator[tuple[str, str]]:
    data = json.loads(lockfile.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("lock の最上位が object ではありません")
    for section in ("default", "develop"):
        packages = data.get(section, {})
        if not isinstance(packages, dict):
            raise ValueError("Pipfile の一覧が object ではありません")
        for name, info in packages.items():
            if not isinstance(name, str) or not isinstance(info, dict):
                continue
            value = info.get("version")
            if isinstance(value, str) and value.startswith("==") and len(value) > 2:
                yield name, value[2:]


def python_packages(lockfile: Path) -> Iterator[tuple[str, str]]:
    if lockfile.name.startswith("requirements") and lockfile.suffix == ".txt":
        yield from requirements_packages(lockfile)
    elif lockfile.name in {"poetry.lock", "uv.lock"}:
        yield from toml_lock_packages(lockfile)
    elif lockfile.name == "Pipfile.lock":
        yield from pipfile_packages(lockfile)


def scan_repo(
    repo: Path, name: str, denylist: dict[str, dict[tuple[str, str], str]]
) -> list[str]:
    hits: list[str] = []
    seen: set[tuple[str, str, str, str]] = set()
    for lockfile, ecosystem in tracked_lockfiles(repo):
        try:
            relative = lockfile.relative_to(repo).as_posix()
        except ValueError:
            relative = lockfile.as_posix()
        if lockfile.name == "bun.lockb":
            hits.append(f"DENYWARN|{safe_field(name)}|{safe_field(relative)}|未照合（bun.lockb のバイナリ形式）")
            continue
        try:
            # generator の読取エラーも、この lock の中だけに閉じ込めます。
            packages = list(npm_packages(lockfile) if ecosystem == "npm" else python_packages(lockfile))
        except (OSError, UnicodeError, ValueError, SyntaxError, TypeError, AttributeError, RecursionError):
            hits.append(f"DENYSKIP|{safe_field(name)}|{safe_field(relative)}（lock を読めません・形式不正）")
            continue
        for raw_package, version in packages:
            package = pep503_name(raw_package) if ecosystem == "pypi" else raw_package
            reason = denylist[ecosystem].get((package, version))
            match_kind = "版の一致"
            if reason is None:
                reason = denylist[ecosystem].get((package, ANY_VERSION))
                match_kind = "名前だけの一致（全版が対象）"
            if reason is None:
                continue
            display = f"pypi:{raw_package}@{version}" if ecosystem == "pypi" else f"{raw_package}@{version}"
            key = (relative, ecosystem, package, version)
            if key in seen:
                continue
            seen.add(key)
            hits.append(
                "|".join(
                    [
                        "DENY",
                        safe_field(name),
                        safe_field(relative),
                        safe_field(display),
                        safe_field(f"{reason}・{match_kind}"),
                    ]
                )
            )
    return hits


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", help="対象リポのパス")
    parser.add_argument("--name", help="レポートに表示するリポ名")
    parser.add_argument("--all", action="store_true", help="~/Plugins 直下をまとめて照合")
    parser.add_argument("--denylist", default=str(DEFAULT_DENYLIST))
    args = parser.parse_args()

    denylist_path = Path(args.denylist).expanduser()
    report_name = args.name or (Path(args.repo).name if args.repo else "-")
    if not denylist_path.is_file():
        print(f"DENYSKIP|{safe_field(report_name)}|照合リストがありません")
        return 2
    try:
        denylist = load_denylist(denylist_path)
    except (OSError, UnicodeDecodeError):
        print(f"DENYSKIP|{safe_field(report_name)}|照合リストを読めません")
        return 2
    if not any(denylist.values()):
        print(f"DENYSKIP|{safe_field(report_name)}|照合リストが空です")
        return 2

    targets: list[tuple[Path, str]] = []
    if args.all:
        if not DEFAULT_ROOT.is_dir():
            print("DENYSKIP|-|対象ルートがありません")
            return 2
        targets.extend((path, path.name) for path in sorted(DEFAULT_ROOT.iterdir()) if path.is_dir())
    elif args.repo:
        repo = Path(args.repo).expanduser()
        if not repo.is_dir():
            print(f"DENYSKIP|{safe_field(report_name)}|対象パスがありません")
            return 2
        targets.append((repo, args.name or repo.name))
    else:
        parser.error("--repo または --all が必要です")

    hits: list[str] = []
    for repo, name in targets:
        hits.extend(scan_repo(repo, name, denylist))
    for hit in hits:
        print(hit)
    if args.all and not hits:
        count = sum(len(entries) for entries in denylist.values())
        print(f"# 該当なし（{len(targets)}リポ / 照合 {count}件）", file=sys.stderr)
    return 1 if hits else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
