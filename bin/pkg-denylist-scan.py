#!/usr/bin/env python3
"""package-lock.json を既知の侵害パッケージ一覧と完全一致で照合します。"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Iterator

DEFAULT_DENYLIST = Path(__file__).resolve().parent.parent / "config" / "pkg-denylist.tsv"
DEFAULT_ROOT = Path.home() / "Plugins"


def safe_field(value: str) -> str:
    """区切り文字と制御文字をレポートへ持ち込まないようにします。"""
    return "".join("_" if char == "|" else char for char in value if ord(char) >= 32 and ord(char) != 127)


def load_denylist(path: Path) -> dict[tuple[str, str], str]:
    entries: dict[tuple[str, str], str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        name, version = parts[0].strip(), parts[1].strip()
        reason = parts[2].strip() if len(parts) > 2 else "理由未記入"
        if name and version:
            entries[(name, version)] = reason
    return entries


def tracked_lockfiles(repo: Path) -> list[Path]:
    found: list[Path] = []
    root_lock = repo / "package-lock.json"
    if root_lock.is_file():
        found.append(root_lock)
    try:
        result = subprocess.run(
            ["git", "-c", "core.quotepath=false", "ls-files", "--", "*/package-lock.json"],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        for rel in result.stdout.splitlines():
            rel = rel.strip()
            if not rel or "node_modules" in rel:
                continue
            lockfile = repo / rel
            if lockfile.is_file() and lockfile not in found:
                found.append(lockfile)
    except (subprocess.SubprocessError, OSError):
        pass
    return found


def installed_packages(lockfile: Path) -> Iterator[tuple[str, str]]:
    try:
        data = json.loads(lockfile.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, UnicodeDecodeError):
        return

    packages = data.get("packages") or {}
    if isinstance(packages, dict):
        for package_path, info in packages.items():
            if not package_path or not isinstance(info, dict):
                continue
            name = info.get("name") or package_path.split("node_modules/")[-1]
            version = info.get("version")
            if isinstance(name, str) and isinstance(version, str):
                yield name, version

    def walk(dependencies: object) -> Iterator[tuple[str, str]]:
        if not isinstance(dependencies, dict):
            return
        for name, info in dependencies.items():
            if not isinstance(name, str) or not isinstance(info, dict):
                continue
            version = info.get("version")
            if isinstance(version, str):
                yield name, version
            yield from walk(info.get("dependencies"))

    yield from walk(data.get("dependencies"))


def scan_repo(repo: Path, name: str, denylist: dict[tuple[str, str], str]) -> list[str]:
    hits: list[str] = []
    seen: set[tuple[str, str, str]] = set()
    for lockfile in tracked_lockfiles(repo):
        try:
            relative = lockfile.relative_to(repo).as_posix()
        except ValueError:
            relative = lockfile.as_posix()
        for package, version in installed_packages(lockfile):
            reason = denylist.get((package, version))
            if reason is None:
                continue
            key = (relative, package, version)
            if key in seen:
                continue
            seen.add(key)
            hits.append(
                "|".join(
                    [
                        "DENY",
                        safe_field(name),
                        safe_field(relative),
                        safe_field(f"{package}@{version}"),
                        safe_field(reason),
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
    if not denylist:
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
        print(f"# 該当なし（{len(targets)}リポ / 照合 {len(denylist)}件）", file=sys.stderr)
    return 1 if hits else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
