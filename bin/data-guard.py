#!/usr/bin/env python3
"""データの公開範囲を点検します。標準ライブラリのみ。値は出力・保存しません。"""
from __future__ import annotations

import argparse
import base64
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urljoin, urlsplit, quote

JST = timezone(timedelta(hours=9))
SKIP = {'.git', 'node_modules', 'vendor', '.next', '.venv', 'venv', '__pycache__', '.tmp-dg'}
IDENT = r'(?:"(?:[^"]|"")+"|[a-zA-Z_][\w$]*)'
NAME = rf'{IDENT}(?:\s*\.\s*{IDENT})?'
REF_URL = re.compile(r'https://([a-z0-9]{20})\.supabase\.co\b')
SECRET_WORDS = r'SECRET|SERVICE_ROLE|PASSWORD|PRIVATE_KEY|ACCESS_TOKEN|REFRESH_TOKEN'
SECRET_NAME = re.compile(r'NEXT_PUBLIC_(?:[A-Z0-9]+_)*(?:' + SECRET_WORDS + r')(?:_[A-Z0-9]+)*')
JS_TOKEN = re.compile(r'''//[^\n]*|/\*[\s\S]*?\*/|'(?:\\[\s\S]|[^'\\])*'|"(?:\\[\s\S]|[^"\\])*"''')
# アプリ独自の名前の確認（getSessionUserId・getSAUser・verifySessionToken・verifyCronSecret・requireAdmin など）も認める
AUTH = re.compile(r'\b(?:getUser|getSession|auth|authenticate|authorize|verifyToken|requireUser|requireAuth|(?:get|require|verify|check|assert|ensure|with)[A-Za-z0-9]*(?:User|Session|Auth|Admin|Token|Secret|Login)[A-Za-z0-9]*)\s*[.(]', re.I)
TENANT = re.compile(r'\b(?:org_id|tenant_id|team_id|company_id|workspace_id)\b', re.I)


def digest(value: str) -> str:
    return hashlib.md5(value.encode()).hexdigest()[:12]


def safe(value: object) -> str:
    text = ''.join(c if ord(c) >= 32 and ord(c) != 127 else ' ' for c in str(value))
    text = re.sub(r'[a-z0-9]{20}(?=\.supabase\.co)|\b[a-z0-9]{20}\b', lambda m: m[0][:4] + '…', text)
    text = re.sub(r'(?:sb_secret_[\w-]+|eyJ[\w-]+\.[\w-]+\.[\w-]+|postgres(?:ql)?://\S+)', '[非表示]', text)
    return text.replace('|', '_')[:350]


def name(value: str) -> str:
    parts = re.findall(IDENT, value)
    return '.'.join(p[1:-1].replace('""', '"') if p.startswith('"') else p.lower() for p in parts)


def table_name(value: str) -> str:
    parts = re.findall(IDENT, value)
    normalized = name(value)
    return normalized if len(parts) > 1 else 'public.' + normalized


def read(path: Path) -> str:
    return path.read_text(encoding='utf-8', errors='replace')


def files(repo: Path):
    def failed(_error):
        raise OSError('walk')
    for root, dirs, names in os.walk(repo, followlinks=False, onerror=failed):
        dirs[:] = sorted(d for d in dirs if d not in SKIP and not (Path(root) / d).is_symlink())
        for filename in sorted(names):
            path = Path(root) / filename
            if not path.is_symlink():
                yield path


def run(args: list[str], *, cwd=None, data=None, env=None, timeout=20) -> str:
    result = subprocess.run(args, cwd=cwd, input=data, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout, check=False)
    if result.returncode:
        raise ValueError('command failed')
    return result.stdout


def git(repo: Path, *args: str, timeout=20) -> str:
    return run(['git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
                '-c', 'core.sshCommand=ssh', '-c', 'core.quotepath=false', '-C', str(repo), *args], timeout=timeout)


def has_secret(text: str) -> bool:
    if re.search(r'\bsb_secret_[A-Za-z0-9_-]+', text):
        return True
    for token in re.findall(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', text):
        try:
            payload = token.split('.')[1]
            obj = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
            if isinstance(obj, dict) and obj.get('role') == 'service_role':
                return True
        except (ValueError, UnicodeError):
            pass
    return False


def js_mask(text: str, *, strings=True) -> str:
    """照合位置と行番号を保ったままコメント・文字列を隠します。"""
    result = list(text)

    def hide(start, end):
        result[start:end] = ['\n' if c == '\n' else ' ' for c in text[start:end]]

    def code(pos, interpolation=False):
        depth = 0
        while pos < len(text):
            m = JS_TOKEN.match(text, pos)
            if m:
                if strings or m[0].startswith(('//', '/*')):
                    hide(pos, m.end())
                pos = m.end()
                continue
            if text[pos] == '`':
                start = pos
                pos += 1
                while pos < len(text):
                    if text[pos] == '\\':
                        pos += 2
                    elif text[pos] == '`':
                        pos += 1
                        break
                    elif text.startswith('${', pos):
                        if strings:
                            hide(start, pos + 2)
                        pos = code(pos + 2, True)
                        start = pos
                    else:
                        pos += 1
                if strings:
                    hide(start, min(pos, len(text)))
                continue
            if interpolation:
                if text[pos] == '{':
                    depth += 1
                elif text[pos] == '}':
                    if depth == 0:
                        return pos + 1
                    depth -= 1
            pos += 1
        return pos

    code(0)
    return ''.join(result)


def client_source(text: str) -> bool:
    m = re.match(r'''\s*(['"])use client\1([^\S\n]*)(;|\n|$)''', js_mask(text, strings=False))
    if not m:
        return False
    # 改行の後に式が続く場合は、指示文ではありません。
    tail = js_mask(text, strings=False)[m.end():].lstrip()
    return m[3] != '\n' or not tail.startswith(tuple('([`.+-*/%<>=!&|^?,:'))


def secret_reference(text: str) -> bool:
    return any(re.search(SECRET_WORDS, m[1]) for m in re.finditer(
        r'\bprocess\s*\.\s*env\s*\.\s*([A-Za-z_$][\w$]*)', js_mask(text)))


def imports(text: str):
    code = js_mask(text)
    for m in re.finditer(r'''\b(?:import|export)\s+(?:[^;]*?\bfrom\s*)?['"]([^'"\n]+)['"]''', js_mask(text, strings=False)):
        if code[m.start():m.start() + 6] in ('import', 'export'):
            yield m[1]


def server_only(text: str) -> bool:
    code = js_mask(text)
    return any(code[m.start():m.start() + 6] == 'import' for m in re.finditer(
        r'''\bimport\s*['"]server-only['"]''', js_mask(text, strings=False)))


def browser_path(path: Path, repo: Repo) -> bool:
    parts = path.relative_to(repo.path).parts
    return parts[0] in {'app', 'components', 'lib', 'src', 'hooks'} and not any(
        'scripts' in part.lower() for part in parts[:-1])


def select_clones(paths: list[Path], guard: Guard) -> list[Path]:
    groups = defaultdict(list)
    selected = []
    for path in sorted(set(paths)):
        if not (path / '.git').exists():
            continue
        try:
            origin = git(path, 'remote', 'get-url', 'origin').strip()
        except (OSError, ValueError, subprocess.SubprocessError):
            origin = ''
        if origin:
            groups[origin].append(path)
        else:
            selected.append(path)
    for group in groups.values():
        if len(group) == 1:
            selected.extend(group)
            continue
        branches, defaults, dates = {}, [], {}
        for path in group:
            branches[path] = 'detached HEAD'
            try:
                branches[path] = git(path, 'symbolic-ref', '--quiet', '--short', 'HEAD').strip() or 'detached HEAD'
                default = git(path, 'symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD').strip()
                if default == 'refs/remotes/origin/' + branches[path]:
                    defaults.append(path)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
            try:
                dates[path] = int(git(path, 'log', '-1', '--format=%ct').strip())
            except (OSError, ValueError, subprocess.SubprocessError):
                dates[path] = 0
        keep = defaults or [max(group, key=lambda p: dates[p])]
        selected.extend(keep)
        for path in group:
            if path not in keep:
                guard.emit('NOTE', 'clone_skipped', path.name, '-', f'同じリモートの別の clone（{branches[path]}）は省略')
    return sorted(selected)


@dataclass
class Repo:
    path: Path
    refs: set[str] = field(default_factory=set)
    paths: list[Path] = field(default_factory=list)
    public: bool = False
    sql: list = field(default_factory=list)

    @property
    def label(self):
        return self.path.name


@dataclass
class Source:
    repo: Repo
    path: str
    line: int
    definition: str
    allowance: tuple[str, str] | None = None

    @property
    def location(self):
        return f'{self.path}:{self.line}'


class Guard:
    def __init__(self):
        self.today = date.fromisoformat(os.environ.get('RH_TODAY', datetime.now(JST).date().isoformat()))
        self.state = Path(os.environ.get('RH_STATE_DIR', str(Path.home() / 'Library/Logs/repo-health-kit/state')))
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.allow = []
        self.expired_allows = []
        # 本番カタログを見るときは、静的な「RLS 有効化が見つからない」を本番の結果と突き合わせてから出す
        self.defer_rls = os.environ.get('RH_SUPABASE_CATALOG', '0') == '1'
        self.deferred_rls = []
        self.live_functions = None
        self.live_views = None
        self.owners = []
        self.statements = 0
        self.load_allow()
        registry = os.environ.get('RH_SUPABASE_APPS')
        if registry:
            try:
                for row in read(Path(registry)).splitlines():
                    if row.strip() and not row.startswith('#'):
                        parts = row.split('\t')
                        if len(parts) >= 2 and all(parts[:2]):
                            self.owners.append(parts[:2])
                        else:
                            raise ValueError('registry')
            except (OSError, ValueError):
                self.emit('WARN', 'owner_unchecked', '-', '-', '所有アプリ台帳を読めません（未検査）')

    def load(self, key):
        path = self.state / ('dg-' + digest(key) + '.json')
        try:
            value = json.loads(read(path))
            if not isinstance(value, dict):
                raise ValueError('state')
            return value
        except FileNotFoundError:
            return {}
        except (OSError, ValueError):
            self.emit('WARN', 'state_unchecked', '-', '-', '前回のデータ点検の状態を読めません（未検査）')
            return {}

    def save(self, key, value):
        fd, tmp = tempfile.mkstemp(prefix='dg-', dir=self.state)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as handle:
                json.dump(value, handle, ensure_ascii=True)
            os.replace(tmp, self.state / ('dg-' + digest(key) + '.json'))
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def emit(self, level, kind, repo, target, message):
        print('\t'.join(map(safe, ('DG', level, kind, repo, target, message))), flush=True)

    def load_allow(self):
        path = Path(os.environ.get('RH_DATA_ALLOW', str(Path.home() / '.config/repo-health-kit/data-allow.tsv')))
        try:
            rows = read(path).splitlines()
        except FileNotFoundError:
            return
        except OSError:
            self.emit('WARN', 'allow_invalid', '-', '-', 'データの据え置き表を読めません')
            return
        for number, row in enumerate(rows, 1):
            if not row.strip() or row.startswith('#'):
                continue
            parts = row.split('\t')
            try:
                if len(parts) not in (5, 6) or not parts[0] or not parts[1] or not parts[4].strip():
                    raise ValueError('columns')
                expires = date.fromisoformat(parts[3])
                if expires.isoformat() != parts[3] or (expires - self.today).days > 180:
                    raise ValueError('expiry')
                if parts[2] and not re.fullmatch(r'[a-f0-9]{12}', parts[2]):
                    raise ValueError('hash')
            except ValueError:
                self.emit('WARN', 'allow_invalid', '-', f'行{number}', '据え置きには種類・対象・期限（最長180日）・理由が必要です')
                continue
            if expires < self.today:
                self.expired_allows.append((parts[0], parts[1], parts[2]))
                self.emit('NOTE', 'allow_expired', '-', f'行{number}', '据え置きの期限が切れています')
                continue
            self.allow.append((parts[0], parts[1], parts[2], expires))

    def allowance_expired(self, kind, target, definition_hash=''):
        return any(k == kind and t == target and (not h or h == definition_hash)
                   for k, t, h in self.expired_allows)

    def finding(self, level, kind, repo, target, message, *, source=None, definition_hash='', protected=False):
        label = repo.label if isinstance(repo, Repo) else repo
        if isinstance(repo, Repo) and repo.public and kind in STATIC_KINDS and level in ('WARN', 'FAIL'):
            level = 'FAIL'
        h = definition_hash or (digest(source.definition) if source else '')
        protected = protected or kind in {'rls_off', 'browser_service_key', 'site_service_key'}
        allowed = None
        if not protected:
            for ak, at, ah, expires in self.allow:
                if ak == kind and at in (target, f'{label}:{source.path}' if source else '') and (not ah or ah == h):
                    allowed = expires
                    break
            if not allowed and source and source.allowance:
                reason, expiry = source.allowance
                try:
                    expires = date.fromisoformat(expiry)
                    if reason.strip() and 0 <= (expires - self.today).days <= 180:
                        allowed = expires
                except ValueError:
                    pass
        if allowed:
            level = 'NOTE'
            message = f'据え置き中（期限 {allowed}・定義 md5 {h or "なし"}）'
            if (allowed - self.today).days <= 7:
                self.emit('NOTE', 'allow_expiring', label, target, '据え置きの期限まで7日以内です')
        if source:
            message += f' [{source.location}・md5 {h}]'
        self.emit(level, kind, label, target, message)

    def owner(self, repo, target, **kw):
        if os.environ.get('RH_SUPABASE_APPS') and not any(
            target == prefix or target.split('.')[-1] == prefix or
            (target.split('.')[-1].startswith(prefix.rstrip('*')) if prefix.endswith(('_', '*')) else False)
            for prefix, _app in self.owners
        ):
            self.finding('WARN', 'owner_unknown', repo, target, '所有アプリが分からない表', **kw)


STATIC_KINDS = {'rls_off', 'policy_open', 'policy_authenticated', 'policy_service_name', 'view_owner',
                'materialized_view', 'definer_path', 'definer_execute', 'storage_policy', 'user_metadata', 'orm_rls'}


def sql_statements(text: str):
    """SQL のコメント・引用符・dollar quote 内のセミコロンを保って分割します。"""
    token = re.compile(r"--[^\n]*|/\*[\s\S]*?\*/|\$[A-Za-z_0-9]*\$|'(?:''|[^'])*'|\"(?:\"\"|[^\"])*\"|;", re.M)
    buf, start, pos, allowance = [], None, 0, None
    matches = iter(token.finditer(text))
    for m in matches:
        if m.start() < pos:
            continue
        gap = text[pos:m.start()]
        if gap.strip() and start is None:
            start = pos + len(gap) - len(gap.lstrip())
        buf.append(gap)
        value = m[0]
        if value.startswith(('--', '/*')):
            mark = re.search(r'rh-allow:\s*(.*?)\s+until\s+(\d{4}-\d{2}-\d{2})', value)
            if mark:
                allowance = mark.group(1, 2)
            buf.append('\n' * value.count('\n') + ' ')
        elif value.startswith('$'):
            end = text.find(value, m.end())
            if end == -1:
                raise ValueError('dollar quote')
            if start is None:
                start = m.start()
            buf.append(text[m.start():end + len(value)])
            pos = end + len(value)
            continue
        elif value == ';':
            statement = ''.join(buf).strip()
            if statement:
                yield statement, text.count('\n', 0, start or 0) + 1, allowance
            buf, start, allowance = [], None, None
        else:
            if start is None:
                start = m.start()
            buf.append(value)
        pos = m.end()
    buf.append(text[pos:])
    if ''.join(buf).strip():
        yield ''.join(buf).strip(), text.count('\n', 0, start or pos) + 1, allowance


def expression(sql: str, keyword: str):
    m = re.search(r'\b' + keyword + r'\s*\(', sql, re.I)
    if not m:
        return None
    depth, i, quoted = 1, m.end(), False
    start = i
    while i < len(sql):
        c = sql[i]
        if c == "'":
            if quoted and i + 1 < len(sql) and sql[i + 1] == "'":
                i += 2
                continue
            quoted = not quoted
        if not quoted:
            depth += (c == '(') - (c == ')')
            if depth == 0:
                return sql[start:i]
        i += 1
    return None


def broad(expr):
    if expr is None:
        return 'true'
    compact = re.sub(r'[\s()]', '', expr.lower())
    if compact in ('true', 'true::boolean'):
        return 'true'
    if compact in ("auth.uidisnotnull", "auth.role='authenticated'", "'authenticated'=auth.role"):
        return 'authenticated'
    return ''


def policy_risks(policy, shared):
    sql = policy['sql']
    roles = policy['roles']
    cmd = policy['cmd']
    using, check = policy['using'], policy['check']
    if 'service_role' in policy['name'].lower() and 'service_role' not in roles:
        yield 'FAIL', 'policy_service_name', '方針名に service_role がありますが、宛先が service_role に限定されていません'
    if policy.get('restrictive'):
        return
    if roles and set(roles) <= {'service_role'}:
        return
    expr = check if cmd == 'INSERT' else using
    # ALL の NULL with_check は qual を継承します。読み取りと書込みの開きを両方扱います。
    open_kind = broad(expr)
    if cmd == 'ALL' and check is not None and broad(check):
        open_kind = open_kind or broad(check)
    audience = bool(set(roles) & {'anon', 'public', 'authenticated'})
    if open_kind and audience:
        if cmd == 'INSERT':
            yield 'INFO', 'policy_insert', '無条件の INSERT 方針です（公開フォームか確認してください）'
        elif 'authenticated' in roles or open_kind == 'authenticated':
            yield ('FAIL' if shared else 'WARN'), 'policy_authenticated', ('別のアプリで登録した人も読めます' if shared else 'ログインした人全員に開く方針です')
        else:
            yield 'WARN', 'policy_open', '未ログインを含む無条件の方針です'
    if 'user_metadata' in sql.lower():
        yield 'WARN', 'user_metadata', '本人が書き換えられる user_metadata を方針が参照しています'
    if policy['table'] == 'storage.objects' and (broad(using) or (using and re.fullmatch(r"[\s()]*bucket_id\s*=\s*'[^']+'(?:::text)?[\s()]*", using, re.I))):
        yield 'WARN', 'storage_policy', 'Storage の方針が無条件またはバケットだけを条件にしています'


def discover(repo: Repo, guard: Guard):
    repo.paths = list(files(repo.path))
    ref_file = repo.path / 'supabase/.temp/project-ref'
    if ref_file.is_file():
        candidate = read(ref_file).strip()
        if re.fullmatch(r'[a-z0-9]{20}', candidate):
            repo.refs.add(candidate)
    if not repo.refs:
        candidates = sorted(repo.paths, key=lambda p: (not p.name.startswith('.env'), not p.name.startswith('next.config'), str(p)))
        for path in candidates:
            if path.name.startswith('.env'):
                # 値を展開せず、公開URLの ref だけ取り出します。
                with path.open(encoding='utf-8', errors='replace') as handle:
                    for line in handle:
                        if 'supabase.co' in line:
                            repo.refs.update(REF_URL.findall(line))
            elif path.suffix in {'.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.json'}:
                repo.refs.update(REF_URL.findall(read(path)))
    for path in repo.paths:
        if path.suffix != '.sql':
            continue
        text = read(path)
        rel = path.relative_to(repo.path).as_posix()
        if not (rel.startswith(('supabase/migrations/', 'supabase/schemas/')) or re.search(r'\b(?:create|alter|drop)\s+(?:table|policy|view|function)\b', text, re.I)):
            continue
        for statement, line, allowance in sql_statements(text):
            guard.statements += 1
            repo.sql.append(Source(repo, rel, line, statement, allowance))


def function_identity(base: str, arguments: str):
    # overload を混ぜず、引数の既定値は照合キーにも表示にも使いません。
    arguments = re.sub(r"'(?:''|[^'])*'", "?", arguments)
    types = []
    builtin = {'integer', 'int', 'int2', 'int4', 'int8', 'bigint', 'smallint', 'text', 'uuid',
               'boolean', 'bool', 'json', 'jsonb', 'varchar', 'character', 'numeric', 'decimal',
               'double', 'real', 'timestamp', 'timestamptz', 'date', 'time', 'timetz', 'bytea',
               'record', 'void', 'anyelement', 'anyarray', 'bit', 'interval', 'vector'}
    for argument in arguments.split(','):
        argument = re.split(r'\bdefault\b|=', argument, maxsplit=1, flags=re.I)[0].strip()
        argument = re.sub(r'^(?:inout|in|out|variadic)\s+', '', argument, flags=re.I)
        words = argument.lower().split()
        if len(words) > 1 and words[0].strip('"').split('[')[0] not in builtin and '.' not in words[0]:
            words = words[1:]
        types.append(' '.join(words))
    return base, digest(','.join(types))


def table_body_hash(sql: str, start: int) -> str:
    # 引用された値や識別子は保ち、空白・コメント・非引用語の大文字小文字だけを正規化します。
    tokens = re.finditer(r'''\s+|'(?:''|[^'])*'|"(?:""|[^"])*"|\$([A-Za-z_0-9]*)\$[\s\S]*?\$\1\$|[\w$]+|[^\s]''', sql[start:])
    body, depth = [], 0
    for m in tokens:
        token = m[0]
        if token.isspace():
            continue
        if token == '(':
            depth += 1
            if depth == 1:
                continue
        elif token == ')':
            depth -= 1
            if depth == 0:
                return hashlib.md5(json.dumps(body).encode()).hexdigest()
        if depth:
            body.append(token if token.startswith(('"', "'", '$')) else token.lower())
    # CREATE TABLE AS / LIKE など列本文が無い形も、同一と決めつけず比較します。
    return hashlib.md5(re.sub(r'\s+', ' ', sql[start:].strip()).encode()).hexdigest()


def static_group(repos: list[Repo], guard: Guard, shared: bool):
    tables, policies, views, functions = {}, {}, {}, {}
    created = defaultdict(lambda: defaultdict(set))
    dynamic_blocks, dynamic_exec = [], []
    sources = sorted((src for repo in repos for src in repo.sql), key=lambda s: (Path(s.path).name, s.path, str(s.repo.path), s.line))
    for src in sources:
        sql = src.definition
        low = sql.lower()
        if re.match(r'\s*do\b', low) and re.search(r'\bexecute\b', low):
            dynamic_exec.append(low)
            if re.search(r'enable\s+row\s+level\s+security', low):
                dynamic_blocks.append(low)
        m = re.match(rf'create\s+(?:unlogged\s+)?table\s+(?:if\s+not\s+exists\s+)?({NAME})', sql, re.I)
        if m:
            target = table_name(m[1])
            created[target][str(src.repo.path)].add(table_body_hash(sql, m.end()))
            if target not in tables or not re.search(r'if\s+not\s+exists', sql, re.I):
                tables[target] = {'source': src, 'rls': False, 'columns': set(TENANT.findall(sql)), 'grant': False}
        m = re.match(rf'alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?({NAME})\s+(.*)', sql, re.I | re.S)
        if m:
            target, action = table_name(m[1]), m[2]
            if target not in tables:
                tables[target] = {'source': src, 'rls': False, 'columns': set(), 'grant': False}
            t = tables[target]
            if re.search(r'\benable\s+row\s+level\s+security', action, re.I):
                t['rls'] = True
            if re.search(r'\bdisable\s+row\s+level\s+security', action, re.I):
                t['rls'] = False
                t['source'] = src
            t['columns'].update(TENANT.findall(action))
            rename = re.match(rf'rename\s+to\s+({IDENT})', action, re.I)
            if rename:
                new = target.split('.')[0] + '.' + name(rename[1])
                tables[new] = tables.pop(target)
                for key in list(policies):
                    if key[0] == target:
                        p = policies.pop(key)
                        p['table'] = new
                        policies[new, key[1]] = p
        m = re.match(rf'drop\s+table\s+(?:if\s+exists\s+)?({NAME})', sql, re.I)
        if m:
            target = table_name(m[1])
            tables.pop(target, None)
            policies = {k: v for k, v in policies.items() if k[0] != target}
        m = re.match(rf'(create|alter|drop)\s+policy\s+(?:if\s+exists\s+)?({IDENT})\s+on\s+({NAME})(.*)', sql, re.I | re.S)
        if m:
            verb, pn, target, rest = m[1].lower(), name(m[2]), table_name(m[3]), m[4]
            key = target, pn
            if verb == 'drop':
                policies.pop(key, None)
                continue
            p = policies.get(key, {'name': pn, 'table': target, 'roles': ['public'], 'cmd': 'ALL', 'using': None, 'check': None, 'restrictive': False})
            role_match = re.search(r'\bto\s+(.+?)(?=\busing\b|\bwith\s+check\b|$)', rest, re.I | re.S)
            if role_match:
                p['roles'] = [name(x.strip()) for x in role_match[1].split(',')]
            cmd_match = re.search(r'\bfor\s+(select|insert|update|delete|all)\b', rest, re.I)
            if cmd_match:
                p['cmd'] = cmd_match[1].upper()
            for key_name, keyword in (('using', 'using'), ('check', r'with\s+check')):
                expr = expression(rest, keyword)
                if expr is not None:
                    p[key_name] = expr
            p['restrictive'] = p['restrictive'] or bool(re.search(r'\bas\s+restrictive\b', rest, re.I))
            rename = re.search(rf'\brename\s+to\s+({IDENT})', rest, re.I)
            if rename:
                policies.pop(key, None)
                pn = name(rename[1])
                p['name'] = pn
            p.update(source=src, sql=json.dumps({k: p[k] for k in ('roles', 'cmd', 'using', 'check')}, sort_keys=True))
            policies[target, pn] = p
        m = re.match(rf'create\s+(?:or\s+replace\s+)?(materialized\s+)?view\s+(?:if\s+not\s+exists\s+)?({NAME})', sql, re.I)
        if m:
            views[table_name(m[2])] = (src, bool(m[1]), bool(re.search(r'security_invoker\s*=\s*(?:true|on)', sql, re.I)))
        m = re.match(rf'alter\s+view\s+({NAME})[\s\S]*security_invoker\s*=\s*(?:true|on)', sql, re.I)
        if m and table_name(m[1]) in views:
            old = views[table_name(m[1])]
            views[table_name(m[1])] = (old[0], old[1], True)
        m = re.match(rf'drop\s+(?:materialized\s+)?view\s+(?:if\s+exists\s+)?({NAME})', sql, re.I)
        if m:
            views.pop(table_name(m[1]), None)
        m = re.match(rf'create\s+(?:or\s+replace\s+)?function\s+({NAME})\s*\(([^)]*)\)', sql, re.I)
        if m:
            target = table_name(m[1])
            functions[function_identity(target, m[2])] = {'name': target, 'source': src, 'definer': bool(re.search(r'\bsecurity\s+definer\b', sql, re.I)), 'path': bool(re.search(r'\bset\s+search_path\b', sql, re.I)), 'revoked': set()}
        m = re.match(rf'alter\s+function\s+({NAME})\s*\((.*?)\)\s+(security\s+invoker|set\s+search_path)\b', sql, re.I | re.S)
        if m:
            f = functions.get(function_identity(table_name(m[1]), m[2]))
            if f:
                if 'invoker' in m[3].lower():
                    f['definer'] = False
                else:
                    f['path'] = True
        m = re.match(rf'(revoke|grant)\s+(?:all|execute)[\s\S]*?on\s+function\s+({NAME})\s*\((.*?)\)\s+(?:from|to)\s+(.+)', sql, re.I)
        if m:
            f = functions.get(function_identity(table_name(m[2]), m[3]))
            if f:
                roles = set(re.findall(r'\b(?:public|anon|authenticated)\b', m[4].lower()))
                if m[1].lower() == 'revoke':
                    f['revoked'].update(roles)
                else:
                    f['revoked'].difference_update(roles)
        m = re.match(rf'drop\s+function\s+(?:if\s+exists\s+)?({NAME})\s*\((.*?)\)', sql, re.I)
        if m:
            functions.pop(function_identity(table_name(m[1]), m[2]), None)
        if re.match(r'grant\s', low) and re.search(r'\b(?:anon|authenticated)\b', low):
            for target in tables:
                if re.search(r'\b' + re.escape(target.split('.')[-1]) + r'\b', low) or 'all tables in schema' in low:
                    tables[target]['grant'] = True
        if 'storage.buckets' in low and (re.search(r'public\s*=\s*true', low) or (re.match(r'insert\b', low) and re.search(r'\btrue\b', low))):
            guard.finding('INFO', 'bucket_public', src.repo, 'storage.buckets', 'migration の記述上は公開バケットがあります（本番は未確認）', source=src)
    for target, t in tables.items():
        src = t['source']
        if target.startswith('public.') and not t['rls']:
            # 動的 SQL で有効化している「可能性」は、その表の名前を含むか、表の一覧を回す形のときだけ認める
            bare = re.escape(target.split('.')[-1])
            dynamic = any(re.search(r'\b' + bare + r'\b', block) or (re.search(r'\bfor\b[\s\S]*?\bin\b[\s\S]*?\bfrom\s+(?:pg_catalog\.)?(?:pg_tables|pg_class)\b|\bfor\b[\s\S]*?\bin\b[\s\S]*?information_schema\.tables', block) and re.search(r'format\s*\(|%i|quote_ident|\|\|', block)) for block in dynamic_blocks)
            args = ('NOTE' if dynamic else 'WARN', 'rls_off', src.repo, target,
                    'migration の記述上は RLS 有効化が見つかりません（本番は未確認）' + ('・動的 SQL で有効化している可能性' if dynamic else '') + ('・公開ロールへの GRANT もあります' if t['grant'] else ''))
            if guard.defer_rls:
                guard.deferred_rls.append((args, {'source': src}))
            else:
                guard.finding(*args, source=src)
        guard.owner(src.repo, target, source=src)
    for (target, pn), p in policies.items():
        src = p['source']
        bare_table = re.escape(target.split('.')[-1])
        redone = any(re.search(r'\b' + bare_table + r'\b', block) and re.search(r'(?:drop|alter|create)\s+policy', block) for block in dynamic_exec)
        for level, kind, message in policy_risks(p, shared):
            if redone:
                level, message = 'NOTE', message + '・後の動的 SQL で方針を作り直している可能性'
            guard.finding(level, kind, src.repo, f'{target}:{pn}', 'migration の記述上は' + message + '（本番は未確認）', source=src, definition_hash=digest(p['sql']))
        t = tables.get(target)
        using = p['using'] or ''
        # サーバー専用（to service_role だけ）の方針と、本人だけに絞る方針は、会社をまたぐ穴にならないので見ない
        server_only = set(r.lower() for r in p['roles']) <= {'service_role'}
        # 本人（uid・email）だけ、または管理者・会員かを関数で確かめる方針も、会社をまたぐ穴にはならない
        self_only = bool(re.search(r"auth\.uid\s*\(\s*\)|auth\.jwt\s*\(|auth\.email\s*\(|current_setting\s*\(\s*'(?:app|request)\.[a-z_.]*(?:user|email|sub)|\b[a-z0-9_]*(?:request_email|request_uid|current_user_id|is_superadmin|is_admin|is_member|is_owner|request_is_[a-z_]+)\s*\(", using, re.I))
        if redone:
            server_only = True
        if t and t['columns'] and p['cmd'] != 'INSERT' and not server_only and not self_only and not any(c.lower() in using.lower() for c in t['columns']) and not re.search(r'\bselect\b', using, re.I):
            guard.finding('WARN', 'tenant_boundary', src.repo, f'{target}:{pn}', 'migration の記述上は using にテナント列・所属の副問い合わせが見つかりません（本番は未確認）', source=src)
    for target, (src, material, invoker) in views.items():
        if target.startswith('public.') and (material or not invoker):
            args = ('WARN', 'materialized_view' if material else 'view_owner', src.repo, target, 'migration の記述上は RLS が効かない VIEW の可能性があります（本番は未確認）')
            if guard.defer_rls:
                guard.deferred_rls.append((args, {'source': src}))
            else:
                guard.finding(*args, source=src)
    for f in functions.values():
        target = f['name']
        src = f['source']
        if f['definer']:
            if not f['path']:
                guard.finding('WARN', 'definer_path', src.repo, target, 'migration の記述上は DEFINER の search_path が未固定です（本番は未確認）', source=src)
            if not {'public', 'anon'} <= f['revoked']:
                args = ('WARN', 'definer_execute', src.repo, target, 'migration の記述上は DEFINER の public・anon の EXECUTE 撤回が見つかりません（本番は未確認）')
                if guard.defer_rls:
                    guard.deferred_rls.append((args, {'source': src}))
                else:
                    guard.finding(*args, source=src)
    for target, definitions in created.items():
        if len(definitions) > 1:
            different = len({frozenset(hashes) for hashes in definitions.values()}) > 1
            guard.finding('WARN' if different else 'INFO', 'table_collision',
                          ', '.join(Path(p).name for p in sorted(definitions)), target,
                          '同じプロジェクトで複数リポの列定義が異なります' if different else '同じ定義を複数リポが持っています')
    return tables


def github(repo: Repo, guard: Guard, logged_in: bool):
    if os.environ.get('RH_DATA_GITHUB', '1') == '0' or not logged_in:
        guard.emit('NOTE', 'github_unchecked', repo.label, '-', 'GitHub は無効・gh 不在・未ログインのため未検査')
        return
    try:
        origin = git(repo.path, 'remote', 'get-url', 'origin').strip()
        match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?', origin)
        if not match:
            guard.emit('NOTE', 'github_unchecked', repo.label, '-', 'GitHub の origin を特定できず未検査')
            return
        remote = match[1]
        key = 'github:' + remote
        cached = guard.load(key)
        previous_public = cached.get('public')
        if time.time() - cached.get('time', 0) >= 86400:
            obj = json.loads(run(['gh', 'api', f'repos/{remote}']))
            if not isinstance(obj.get('private'), bool):
                raise ValueError('visibility')
            cached = {'public': not obj['private'], 'time': time.time(), 'alerts': None}
            try:
                alerts = json.loads(run(['gh', 'api', '--paginate', '--slurp', f'repos/{remote}/dependabot/alerts?state=open&per_page=100']))
                if not isinstance(alerts, list):
                    raise ValueError('alerts')
                # --slurp はページの配列です。偽CLI・単一ページの応答も扱います。
                if alerts and isinstance(alerts[0], list):
                    alerts = [item for page in alerts for item in page]
                cached['alerts'] = dict(Counter(a['security_advisory']['severity'] for a in alerts))
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                pass
            guard.save(key, cached)
        repo.public = cached['public']
        guard.emit('INFO', 'repo_visibility', repo.label, '-', '公開リポです' if repo.public else '非公開リポです')
        if repo.public and previous_public is False:
            # 24時間の間も、前回からの変更通知を保持します。
            cached['became_public'] = guard.today.isoformat()
            guard.save(key, cached)
        if cached.get('became_public') == guard.today.isoformat():
            guard.finding('WARN', 'repo_public', repo, f'{repo.label}:-', '前回から公開に変わりました')
        if cached.get('alerts') is None:
            guard.emit('NOTE', 'dependabot_unchecked', repo.label, '-', 'Dependabot は権限・応答を確認できず未検査')
        else:
            counts = cached['alerts']
            critical, high = counts.get('critical', 0), counts.get('high', 0)
            guard.emit('WARN' if critical + high else 'INFO', 'dependabot', repo.label, '-', f'Dependabot 未対応 critical {critical}件・high {high}件')
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        guard.emit('NOTE', 'github_unchecked', repo.label, '-', 'GitHub の公開設定を取得できず未検査')


def history(repo: Repo, guard: Guard):
    key = 'history:' + str(repo.path)
    old = guard.load(key)
    start = time.monotonic()
    try:
        tips = git(repo.path, 'for-each-ref', '--format=%(objectname)', timeout=max(0.1, 20 - (time.monotonic() - start))).split()
        tips += git(repo.path, 'rev-parse', '--verify', 'HEAD', timeout=max(0.1, 20 - (time.monotonic() - start))).split()
        tips = sorted(set(tips))
        previous = old.get('tips', [])
        args = ['log', '--all', 'HEAD', '--diff-filter=A', '--name-only', '--format=', '-z']
        if previous:
            args += ['--not', *previous]
        output = git(repo.path, *args, timeout=max(0.1, 20 - (time.monotonic() - start)))
        hits = set(old.get('files', []))
        for raw in output.split('\0'):
            rel = raw.strip('\n')
            filename = Path(rel).name.lower()
            if filename in {'.env.example', '.env.sample', '.env.tpl'}:
                continue
            if filename.startswith('.env') or filename.endswith('.pem') or re.search(r'(?:service[-_]?account|credentials|firebase-adminsdk)[^/]*\.json$', filename):
                hits.add(rel)
        guard.save(key, {'tips': tips, 'files': sorted(hits)})
        for rel in sorted(hits):
            guard.finding('FAIL' if repo.public else 'WARN', 'history_key_file', repo, f'{repo.label}:{rel}', '鍵ファイル名が履歴にあります。削除後も履歴に残るため、鍵の入れ替えを確認してください')
    except (OSError, ValueError, subprocess.SubprocessError):
        guard.emit('WARN', 'history_unchecked', repo.label, '-', 'git 履歴を制限時間内に読めず未検査（1リポ20秒）')


def source_scan(repo: Repo, guard: Guard):
    source_paths = [p for p in repo.paths if p.suffix in {'.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'} and 'docs' not in p.relative_to(repo.path).parts and '/data/phases/' not in '/' + p.relative_to(repo.path).as_posix()]
    texts = {p: read(p) for p in source_paths}
    for path in repo.paths:
        rel = path.relative_to(repo.path).as_posix()
        if 'docs' in path.relative_to(repo.path).parts:
            continue
        if path.name.startswith('.env'):
            # キー名だけを抽出します。値は走査に渡しません。
            with path.open(encoding='utf-8', errors='replace') as handle:
                for lineno, line in enumerate(handle, 1):
                    m = re.match(r'\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=', line)
                    if m and SECRET_NAME.fullmatch(m[1]):
                        guard.finding('FAIL', 'browser_env', repo, f'{repo.label}:{rel}', f'公開用の変数名に秘密を示す語があります [{rel}:{lineno}]', protected=bool(re.search(r'SERVICE|SECRET|ROLE', m[1])))
    for path, text in texts.items():
        rel = path.relative_to(repo.path).as_posix()
        for m in re.finditer(r'\bprocess\s*\.\s*env\s*\.\s*([A-Z][A-Z0-9_]*)\b', js_mask(text)):
            if SECRET_NAME.fullmatch(m[1]):
                guard.finding('FAIL', 'browser_env', repo, f'{repo.label}:{rel}', f'公開用の変数名に秘密を示す語があります [{rel}:{text.count(chr(10), 0, m.start()) + 1}]', protected=bool(re.search(r'SERVICE|SECRET|ROLE', m[1])))
        if path.name.startswith('next.config'):
            block = re.search(r'\benv\s*:\s*\{([\s\S]*?)\}', text)
            if block and any(re.search(r'(?:^|_)(?:' + SECRET_WORDS + r')(?:_|$)', key)
                             for key in re.findall(r'\b([A-Z][A-Z0-9_]*)\s*:', block[1])):
                guard.finding('FAIL', 'browser_env', repo, f'{repo.label}:{rel}', 'next.config の env に秘密を示す変数名があります', protected=bool(re.search(r'SERVICE|SECRET|ROLE', block[1])))
        if not browser_path(path, repo) or not client_source(text):
            continue
        danger = secret_reference(text) or has_secret(js_mask(text, strings=False))
        for imported in imports(text):
            if imported.startswith('.'):
                base = path.parent / imported
            elif imported.startswith('@/'):
                base = repo.path / imported[2:]
                if not any(p.exists() for p in (base, Path(str(base) + '.ts'), Path(str(base) + '.tsx'), base / 'index.ts', base / 'index.tsx')):
                    base = repo.path / 'src' / imported[2:]
            else:
                continue
            candidates = [base]
            for suffix in ('.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'):
                candidates.extend((Path(str(base) + suffix), base.with_suffix(suffix), base / ('index' + suffix)))
            for candidate in candidates:
                # リポ外の import と symlink は読みません。
                if candidate.is_symlink() or not candidate.resolve().is_relative_to(repo.path):
                    continue
                resolved = candidate.resolve()
                if resolved in texts and browser_path(resolved, repo):
                    imported_text = texts[resolved]
                    if not server_only(imported_text) and secret_reference(imported_text):
                        danger = True
        if danger:
            guard.finding('FAIL', 'browser_service_key', repo, f'{repo.label}:{rel}', 'ブラウザ側から service_role・秘密の参照があります', protected=True)
    bundle_dir = repo.path / '.next/static'
    if bundle_dir.is_dir():
        for path in files(bundle_dir):
            if path.suffix in {'.js', '.map', '.json'} and has_secret(read(path)):
                rel = path.relative_to(repo.path).as_posix()
                guard.finding('FAIL', 'browser_service_key', repo, f'{repo.label}:{rel}', 'ブラウザ配信物に service_role の JWT・秘密鍵の型があります', protected=True)
    package = repo.path / 'package.json'
    if package.is_file() and '@supabase/' in read(package):
        orm = any('prisma/migrations/' in p.relative_to(repo.path).as_posix() for p in repo.paths) or any('pgTable(' in t for t in texts.values())
        if orm and not any(re.search(r'row\s+level\s+security', s.definition, re.I) for s in repo.sql):
            guard.finding('WARN', 'orm_rls', repo, f'{repo.label}:package.json', 'migration の記述上は ORM の表に RLS の記述がありません（本番は未確認）')
    route_scan(repo, guard, texts)


def route_scan(repo: Repo, guard: Guard, texts):
    crons = []
    config = repo.path / 'vercel.json'
    if config.is_file():
        try:
            crons = [c['path'] for c in json.loads(read(config)).get('crons', [])]
        except (ValueError, TypeError, KeyError, AttributeError):
            guard.emit('WARN', 'api_unchecked', repo.label, 'vercel.json', 'cron の設定を読めず未検査')
    middleware = '\n'.join(t for p, t in texts.items() if p.name in ('proxy.ts', 'middleware.ts'))
    # 認証を含む middleware の実際の接頭辞検査か matcher に限ります。
    prefixes = []
    if AUTH.search(middleware):
        prefixes += re.findall(r'''startsWith\(\s*["'](/api/[^"']*)["']''', middleware)
        matchers = re.search(r'\bmatcher\s*:\s*(\[[\s\S]*?\]|["\'][^"\']*["\'])', middleware)
        if matchers:
            prefixes += [p.replace('/:path*', '').rstrip('/') for p in re.findall(r'''["'](/api/[^"']*)["']''', matchers[1]) if not re.search(r'[()?!|]', p)]
    routes = {}
    for path, text in texts.items():
        rel = path.relative_to(repo.path).as_posix()
        if not re.search(r'(?:^|/)app/api/(?:.*/)?route\.ts$', rel):
            continue
        api_path = '/' + rel.split('app/', 1)[1].rsplit('/route.ts', 1)[0]
        routes[api_path] = (path, text)
    unauth = []
    key = 'routes:' + str(repo.path)
    previous = guard.load(key)
    for api_path, (path, text) in routes.items():
        rel = path.relative_to(repo.path).as_posix()
        protected = any(api_path == p or api_path.startswith(p.rstrip('/') + '/') for p in prefixes)
        auth = bool(AUTH.search(text)) or protected
        if api_path in crons and not protected:
            secret_names = ['CRON_SECRET'] + re.findall(r'(?:const|let)\s+(\w+)\s*=\s*process\.env\.CRON_SECRET', text)
            bypass = any(re.search(r'if\s*\(\s*' + re.escape(n) + r'\s*&&', text) for n in secret_names) or bool(re.search(r'if\s*\(\s*(?:process\.env\.)?\w*secret\w*\s*&&', text, re.I))
            if 'CRON_SECRET' not in text or bypass:
                guard.finding('FAIL', 'cron_auth', repo, f'{repo.label}:{rel}', 'cron の秘密の確認がないか、未設定時に素通りする形です')
        if re.search(r'if\s*\(\s*!\s*\w*[sS]ecret\w*\s*\)\s*\{?\s*return\s+true\b', text):
            guard.finding('FAIL', 'captcha_bypass', repo, f'{repo.label}:{rel}', 'captcha の秘密が未設定のときに許可する形です')
        # 連射制限の Map は「名前が limit・rate・attempt・hits などで、時刻か回数を入れる」形だけを数える（問題の一覧などの引き表は数えない）
        limiter_maps = re.findall(r'^(?:export\s+)?(?:const|let|var)\s+(\w*(?:limit|rate|attempt|hit|throttl|bucket|request|ip)\w*)\s*=\s*new\s+Map\s*[(<]', text, re.M | re.I)
        if limiter_maps and re.search(r'Date\.now\s*\(|reset|window|count|attempts', text, re.I):
            guard.finding('WARN', 'memory_rate_limit', repo, f'{repo.label}:{rel}', 'モジュール直下の Map による連射制限はサーバーレスで共有されません')
        if not auth:
            unauth.append(rel)
            guard.finding('WARN' if 'files' in previous and rel not in previous['files'] else 'INFO', 'api_auth_unknown', repo, f'{repo.label}:{rel}', '認証の見当たらない API 入口です（語の静的照合・公開用途か確認してください）')
            if re.search(r'SERVICE_ROLE|SUPABASE_SECRET_KEY', text):
                guard.finding('WARN', 'api_service_auth', repo, f'{repo.label}:{rel}', 'service_role を使う入口に認証の記述が見当たりません')
    for api_path in crons:
        if api_path not in routes:
            guard.finding('FAIL', 'cron_auth', repo, f'{repo.label}:vercel.json', 'cron に対応する route.ts を確認できません')
    # captcha は共通ヘルパー内でも使われます。
    for path, text in texts.items():
        if path in [r[0] for r in routes.values()]:
            continue
        if re.search(r'captcha', text, re.I) and re.search(r'if\s*\(\s*!\s*\w*[sS]ecret\w*\s*\)\s*\{?\s*return\s+true\b', text):
            rel = path.relative_to(repo.path).as_posix()
            guard.finding('FAIL', 'captcha_bypass', repo, f'{repo.label}:{rel}', 'captcha の秘密が未設定のときに許可する形です')
    guard.save(key, {'files': unauth})


# カタログから式・関数本体を返さず、分類用の真偽と md5 だけを返します。
CATALOG_SQL = r"""
with config as (
  select coalesce(nullif(current_setting('pgrst.db_schemas', true), ''),
    (select split_part(s, '=', 2) from pg_db_role_setting d, unnest(d.setconfig) s
      where s like 'pgrst.db_schemas=%'
      order by (d.setrole = (select oid from pg_roles where rolname='authenticator')) desc limit 1), 'public') value
), exposed as (select trim(unnest(string_to_array(value, ','))) n from config),
tabs as (
 select n.nspname||'.'||c.relname target, c.oid, c.relrowsecurity rls,
 has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE') anon,
 has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE') authenticated
 from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where c.relkind in ('r','p') and n.nspname in (select n from exposed)
), pol as (
 select schemaname||'.'||tablename target, policyname name, cmd, roles,
 permissive='RESTRICTIVE' restrictive,
 regexp_replace(coalesce(case when cmd='INSERT' then with_check else qual end,'true'),'[[:space:]()]','','g') expr,
 regexp_replace(coalesce(with_check,qual,'true'),'[[:space:]()]','','g') check_expr,
 coalesce(qual,'') ~* '^[[:space:]()]*bucket_id[[:space:]]*=[[:space:]]*''[^'']+''(::text)?[[:space:]()]*$' bucket_only,
 coalesce(qual,'') ~* 'auth\.|owner|select' member_check,
 (coalesce(qual,'')||coalesce(with_check,'')) like '%user_metadata%' user_metadata,
 md5(coalesce(qual,'')||'|'||coalesce(with_check,'')||'|'||roles::text||'|'||cmd||'|'||permissive) hash
 from pg_policies where schemaname in (select n from exposed) or (schemaname='storage' and tablename='objects')
)
select jsonb_build_object(
 'tables_total',(select count(*) from tabs),
 'tables',coalesce((select jsonb_agg(jsonb_build_object('target',target,'rls',rls,'anon',anon,'authenticated',authenticated)) from tabs),'[]'::jsonb),
 'policies',coalesce((select jsonb_agg(jsonb_build_object('target',target,'name',name,'cmd',cmd,'roles',roles,
 'restrictive',restrictive,'open',expr in ('true','true::boolean'),
 'auth_only',expr in ('auth.uidisnotnull','auth.role=''authenticated''','''authenticated''=auth.role'),
 'check_open',check_expr in ('true','true::boolean'), 'bucket_only',bucket_only and not member_check,
 'user_metadata',user_metadata,'hash',left(hash,12))) from pol),'[]'::jsonb),
 'views',coalesce((select jsonb_agg(jsonb_build_object('target',n.nspname||'.'||c.relname,
 'materialized',c.relkind='m','invoker',coalesce(c.reloptions @> array['security_invoker=true'],false),
 'readable',has_table_privilege('anon',c.oid,'SELECT') or has_table_privilege('authenticated',c.oid,'SELECT'),
 'hash',left(md5(pg_get_viewdef(c.oid)),12)))
 from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('v','m') and n.nspname in (select n from exposed)),'[]'::jsonb),
 'functions',coalesce((select jsonb_agg(jsonb_build_object('target',n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',
 'search_path',exists(select 1 from unnest(p.proconfig) x where x like 'search_path=%'),
 'executable',has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE'),
 'anon',has_function_privilege('anon',p.oid,'EXECUTE'),
 'hash',left(md5(pg_get_functiondef(p.oid)),12))) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where p.prosecdef and p.prokind='f' and p.prorettype <> 'trigger'::regtype and n.nspname in (select n from exposed)),'[]'::jsonb),
 'buckets',coalesce((select jsonb_agg(jsonb_build_object('target',name,'public',public)) from storage.buckets),'[]'::jsonb),
 'realtime',coalesce((select jsonb_agg(jsonb_build_object('target',schemaname||'.'||tablename)) from pg_publication_tables where pubname='supabase_realtime'),'[]'::jsonb),
 'schemas',coalesce((select jsonb_agg(n) from exposed),'[]'::jsonb)
);
"""


def catalog_findings(data, shared):
    out = []
    def add(level, kind, target, message, h=''):
        out.append({'level': level, 'kind': kind, 'target': target, 'message': message, 'hash': h})
    for t in data['tables']:
        if not t['rls']:
            add('FAIL', 'rls_off', t['target'], '本番で RLS が無効です' + ('・公開ロールへの権限もあります' if t['anon'] or t['authenticated'] else ''))
    for p in data['policies']:
        target = p['target'] + ':' + p['name']
        h, roles = p['hash'], p['roles']
        if 'service_role' in p['name'].lower() and 'service_role' not in roles:
            add('FAIL', 'policy_service_name', target, '方針名に service_role がありますが宛先が限定されていません', h)
        if p['restrictive'] or not set(roles) & {'anon', 'public', 'authenticated'}:
            continue
        if p['open'] or p['auth_only'] or (p['cmd'] == 'ALL' and p['check_open']):
            if p['cmd'] == 'INSERT':
                add('INFO', 'policy_insert', target, '無条件の INSERT 方針です（公開フォームか確認してください）', h)
            elif 'authenticated' in roles or p['auth_only']:
                add('FAIL' if shared else 'WARN', 'policy_authenticated', target, '別のアプリで登録した人も読めます' if shared else 'ログインした人全員に開く方針です', h)
            else:
                add('WARN', 'policy_open', target, '未ログインを含む無条件の方針です', h)
        if p['target'] == 'storage.objects' and (p['open'] or p['bucket_only']):
            add('WARN', 'storage_policy', target, 'Storage の方針が無条件またはバケットだけを条件にしています', h)
        if p['user_metadata']:
            add('WARN', 'user_metadata', target, '本人が書き換えられる user_metadata を方針が参照しています', h)
    for v in data['views']:
        if v['readable'] and (v['materialized'] or not v['invoker']):
            add('WARN', 'view_owner', v['target'], '公開ロールが RLS を引き継がない VIEW を読めます', v['hash'])
    for f in data['functions']:
        if f['executable']:
            if f.get('anon', True):
                add('WARN', 'definer_execute', f['target'], '未ログイン（anon）でも SECURITY DEFINER 関数を実行できます。中で本人か管理者かを確かめているか見てください', f['hash'])
            else:
                add('INFO', 'definer_authenticated', f['target'], 'ログインした人が SECURITY DEFINER 関数を実行できます（共有プロジェクトでは別のアプリの人も含みます。中で本人・所属を確かめているか、人が確かめてください）', f['hash'])
            if not f['search_path']:
                add('WARN', 'definer_path', f['target'], '実行可能な DEFINER の search_path が未固定です', f['hash'])
    for b in data['buckets']:
        if b['public']:
            add('WARN', 'bucket_public', b['target'], '公開 Storage バケットです')
    for t in data['realtime']:
        add('INFO', 'realtime', t['target'], 'Realtime の公開対象です')
    for schema in data['schemas']:
        add('INFO', 'exposed_schema', schema, 'PostgREST の公開スキーマです')
    return out


def day_baseline(guard: Guard, key: str):
    old = guard.load(key)
    day = guard.today.isoformat()
    if old.get('date') == day:
        return old.get('baseline'), old
    return old.get('current'), {'date': day, 'baseline': old.get('current')}


def catalog(ref: str, repos: list[Repo], tables, guard: Guard):
    label = ', '.join(r.label for r in repos) or '監査対象'
    masked = ref[:4] + '…'
    try:
        if not shutil.which('psql') or not shutil.which('security'):
            raise ValueError('missing')
        connection = run(['security', 'find-generic-password', '-s', os.environ.get('RH_SUPABASE_CATALOG_KEYCHAIN', 'repo-health-kit-supabase-audit'), '-a', ref, '-w']).strip()
        url = urlsplit(connection)
        if url.scheme not in ('postgres', 'postgresql') or not url.hostname or not url.username or not url.password or not url.path.strip('/'):
            raise ValueError('connection')
        # 接続URL・その query のオプションをコマンドラインへ渡しません。
        pg_env = {k: v for k, v in os.environ.items() if not k.startswith(('PG', 'PSQL'))}
        pg_env.update(PGHOST=url.hostname, PGPORT=str(url.port or 5432), PGUSER=unquote(url.username), PGPASSWORD=unquote(url.password), PGDATABASE=unquote(url.path[1:]), PGSSLMODE='require', PGCONNECT_TIMEOUT='10', PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=20000')
        raw = run(['psql', '-X', '-q', '-t', '-A', '-w', '-v', 'ON_ERROR_STOP=1'], data=CATALOG_SQL, env=pg_env, timeout=30)
        data = json.loads(raw)
        required = {'tables_total', 'tables', 'policies', 'views', 'functions', 'buckets', 'realtime', 'schemas'}
        if not isinstance(data, dict) or not required <= data.keys() or not isinstance(data['tables_total'], int) or data['tables_total'] <= 0 or len(data['tables']) != data['tables_total'] or not all(isinstance(data[k], list) for k in required - {'tables_total'}):
            guard.emit('FAIL', 'catalog_unreadable', label, masked, 'カタログを読めていません（番兵・表の件数を確認できません）')
            return {}
        findings = catalog_findings(data, len(repos) > 1)
        # raw JSON は保存しません。許可したメタデータと分類済みの結果だけを保存します。
        baseline, snapshot = day_baseline(guard, 'catalog:' + ref)
        prior_ids = set(baseline or [])
        current = []
        unchanged = Counter()
        for item in findings:
            fid = digest('|'.join((item['kind'], item['target'], item['hash'])))
            current.append(fid)
            if baseline is not None and fid in prior_ids and not guard.allowance_expired(item['kind'], item['target'], item['hash']):
                unchanged[item['kind']] += 1
            else:
                guard.finding(item['level'], item['kind'], label, item['target'], '本番カタログ: ' + item['message'], definition_hash=item['hash'])
        for kind, count in sorted(unchanged.items()):
            guard.emit('INFO', 'catalog_unchanged', label, masked, f'前日から変わらない {kind} {count}件')
        live_tables = {}
        guard.live_functions = (guard.live_functions or set()) | {f['target'].split('(')[0] for f in data['functions']}
        guard.live_views = (guard.live_views or set()) | {v['target'] for v in data.get('views', [])}
        for t in data['tables']:
            target = t['target']
            live_tables[target] = bool(t['rls'])
            guard.owner(label, target)
            if target in tables and 'rls' in tables[target] and tables[target]['rls'] != bool(t['rls']):
                if tables[target]['rls'] and not t['rls']:
                    guard.emit('FAIL', 'catalog_drift', label, target, 'migration では RLS が有効なのに、本番では無効です')
                else:
                    guard.emit('NOTE', 'catalog_drift', label, target, '本番は RLS 有効・migration に有効化の記述がありません（SQL Editor か動的 SQL で当てた可能性）')
        snapshot['current'] = current
        snapshot['tables'] = live_tables
        guard.save('catalog:' + ref, snapshot)
        guard.emit('INFO', 'catalog_count', label, masked, f'本番カタログの表 {data["tables_total"]}件を確認しました')
        guard.save('catalog-failure:' + ref, {})
        return live_tables
    except (json.JSONDecodeError, KeyError, TypeError, AttributeError):
        guard.emit('FAIL', 'catalog_unreadable', label, masked, 'カタログを読めていません（応答の形式を確認できません）')
    except (OSError, ValueError, subprocess.SubprocessError):
        key = 'catalog-failure:' + ref
        old = guard.load(key)
        previous_date = old.get('date')
        if previous_date not in (guard.today.isoformat(), (guard.today - timedelta(days=1)).isoformat()):
            old = {}
        days = old.get('days', 0) + (old.get('date') != guard.today.isoformat())
        guard.save(key, {'date': guard.today.isoformat(), 'days': days})
        guard.emit('FAIL' if days >= 3 else 'WARN', 'catalog_unchecked', label, masked, '本番カタログは接続・専用鍵・psql を確認できず未検査' + (f'（未検査が続いて{days}日目）' if days >= 3 else ''))
    return {}


def curl_get(url: str, headers=None):
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError('url')
    def config_string(s):
        if any(ord(c) < 32 or ord(c) == 127 for c in s):
            raise ValueError('config')
        return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    lines = ['url = ' + config_string(url), 'request = "GET"', 'silent', 'show-error', 'max-time = 10', 'connect-timeout = 10', 'proto = "=https"']
    for k, v in (headers or {}).items():
        lines.append('header = ' + config_string(k + ': ' + v))
    # 本文とヘッダーはメモリだけで扱います。redirect を追わず鍵の別ホスト送信を防ぎます。
    output = run(['curl', '-q', '-K', '-', '-i', '-w', '\nRH_HTTP_STATUS:%{http_code}'], data='\n'.join(lines) + '\n', timeout=12)
    body_headers, marker, status = output.rpartition('\nRH_HTTP_STATUS:')
    if not marker or not re.fullmatch(r'\d{3}\s*', status):
        raise ValueError('http status')
    code = int(status.strip())
    header, separator, body = body_headers.replace('\r\n', '\n').partition('\n\n')
    if not separator:
        raise ValueError('http response')
    return code, header, body


def anon_probe(repo: Repo, tables_by_ref, guard: Guard):
    if not repo.refs:
        guard.emit('WARN', 'probe_unchecked', repo.label, '-', '公開鍵による実測は ref または表の一覧がなく未検査')
        return set()
    public_key, url = '', ''
    for path in sorted(p for p in repo.paths if p.name.startswith('.env')):
        with path.open(encoding='utf-8', errors='replace') as handle:
            for line in handle:
                m = re.match(r'\s*(?:export\s+)?(NEXT_PUBLIC_SUPABASE_(?:URL|ANON_KEY|PUBLISHABLE_KEY))\s*=\s*(.*?)\s*$', line)
                if not m:
                    continue
                value = m[2].strip('"\'')
                if m[1].endswith('_URL') and REF_URL.fullmatch(value):
                    url = value
                elif m[1].endswith(('_ANON_KEY', '_PUBLISHABLE_KEY')):
                    public_key = value
    match = REF_URL.fullmatch(url)
    if not match or match[1] not in repo.refs or not public_key or has_secret(public_key):
        guard.emit('WARN', 'probe_unchecked', repo.label, '-', '公開鍵・URL を確認できず実測は未検査')
        return set()
    tables = tables_by_ref.get(match[1], {})
    if not tables:
        guard.emit('WARN', 'probe_unchecked', repo.label, '-', '公開鍵による実測は表の一覧がなく未検査')
        return set()
    key = 'probe:' + match[1]
    old = guard.load(key)
    if old.get('date') == guard.today.isoformat():
        for target in old.get('unchecked', []):
            guard.emit('WARN', 'probe_unchecked', repo.label, target, '公開鍵の実測で応答を確認できず未検査（本日の結果）')
        for target in old.get('opened', []):
            guard.finding('WARN' if old.get('baseline') is None or target in old.get('expired', []) else 'FAIL', 'anon_readable', repo, target, '公開鍵で1件読める表です（本日の結果）')
        return {match[1]}
    baseline = old.get('readable')
    readable, unchecked, complete, requested = [], [], True, False
    for target in sorted(tables):
        schema, sep, table = target.partition('.')
        if not sep:
            continue
        if requested:
            time.sleep(1)
        requested = True
        try:
            status, _headers, body = curl_get(url + '/rest/v1/' + quote(table, safe='') + '?select=*&limit=1', {'apikey': public_key, 'Authorization': 'Bearer ' + public_key, 'Accept-Profile': schema})
            obj = json.loads(body)
            if status == 200 and isinstance(obj, list):
                count = len(obj)
                del obj, body
                if count:
                    readable.append(target)
                else:
                    guard.emit('INFO', 'anon_empty', repo.label, target, '公開鍵の取得件数0件（拒否と空の表を区別できません）')
            elif status in (401, 403):
                guard.emit('INFO', 'anon_denied', repo.label, target, '公開鍵の読み取りが拒否されました')
            else:
                raise ValueError('probe response')
        except (OSError, ValueError, subprocess.SubprocessError):
            complete = False
            unchecked.append(target)
            guard.emit('WARN', 'probe_unchecked', repo.label, target, '公開鍵の実測で応答を確認できず未検査')
    expired = [t for t in readable if guard.allowance_expired('anon_readable', t)]
    opened = [t for t in readable if baseline is None or t not in baseline or t in expired]
    for target in opened:
        level = 'WARN' if baseline is None or (target in expired and target in baseline) else 'FAIL'
        message = '据え置きの期限が切れた、公開鍵で1件読める表です' if target in expired else '公開鍵で1件読める表です（初回）' if baseline is None else '新しく公開鍵で1件読めるようになった表です'
        guard.finding(level, 'anon_readable', repo, target, message)
    guard.save(key, {'date': guard.today.isoformat(), 'baseline': baseline, 'readable': readable if complete else baseline, 'opened': opened, 'unchecked': unchecked, 'expired': expired})
    guard.emit('INFO', 'probe_count', repo.label, '-', f'公開鍵で読めた表 {len(readable)}件（行の本文は破棄しました）')
    return {match[1]}


def site_scan(site: str, index: int, guard: Guard):
    label = f'サイト{index}'
    parsed = urlsplit(site)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        guard.emit('WARN', 'site_unchecked', label, '-', 'URL の形式を確認できず未検査（https の URL を指定してください）')
        return
    key = 'site:' + site
    old = guard.load(key)
    if old.get('date') == guard.today.isoformat():
        for item in old.get('findings', []):
            guard.finding(item[0], item[1], label, item[2], item[3])
        return
    findings, complete = [], True
    requested = False
    def get(url):
        nonlocal requested
        if requested:
            time.sleep(1)
        requested = True
        return curl_get(url)
    def add(level, kind, target, msg):
        findings.append([level, kind, target, msg])
    try:
        origin = f'https://{parsed.netloc}'
        for path in ('/.env', '/.git/config'):
            status, _headers, _body = get(origin + path)
            if status != 404:
                add('FAIL', 'site_sensitive_path', path, '秘密ファイルのパスが404以外を返します（内容は保存しません）')
        status, headers, html = get(site)
        if status != 200:
            raise ValueError('top')
        names = ['strict-transport-security', 'content-security-policy', 'x-content-type-options', 'x-frame-options']
        present = [n for n in names if re.search(r'^' + n + ':', headers, re.I | re.M)]
        add('INFO', 'site_headers', '/', '確認できたヘッダー: ' + (', '.join(present) or '対象なし'))
        # ユーザー入力由来の URL は出力しません。許可された同一originだけを取得します。
        scripts = set(re.findall(r'''<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["']''', html, re.I))
        if has_secret(html):
            add('FAIL', 'site_service_key', '/', '配信 HTML に service_role の JWT・秘密鍵の型があります')
        for i, script in enumerate(sorted(scripts), 1):
            url = urljoin(site, script)
            jsurl = urlsplit(url)
            target = f'JS{i}'
            if (jsurl.scheme, jsurl.netloc) != (parsed.scheme, parsed.netloc):
                add('NOTE', 'site_external_js', target, '別ホストの JS は未検査です')
                continue
            code, _headers, js = get(url)
            if code != 200:
                complete = False
                add('WARN', 'site_unchecked', target, 'JS を取得できず未検査です')
                continue
            if has_secret(js):
                add('FAIL', 'site_service_key', target, '配信 JS に service_role の JWT・秘密鍵の型があります')
            maps = re.findall(r'[#@]\s*sourceMappingURL=([^\s*]+)', js)
            if not maps:
                maps = [jsurl.path + '.map']
            for source_map in maps:
                if source_map.startswith('data:'):
                    add('WARN', 'site_sourcemap', target, 'ソースマップが配信されています')
                    continue
                map_url = urljoin(url, source_map)
                mapped = urlsplit(map_url)
                if (mapped.scheme, mapped.netloc) != (parsed.scheme, parsed.netloc):
                    continue
                code, _headers, body = get(map_url)
                if code == 200:
                    try:
                        obj = json.loads(body)
                        if isinstance(obj, dict) and obj.get('version') == 3:
                            add('WARN', 'site_sourcemap', target, 'ソースマップが公開されています')
                    except ValueError:
                        pass
        add('NOTE', 'site_scope', '/', 'トップから取得できる範囲の点検です。ログイン後の配信物は未確認です')
    except (OSError, ValueError, subprocess.SubprocessError):
        complete = False
        add('WARN', 'site_unchecked', '-', '本番サイトの応答を確認できず未検査です')
    for item in findings:
        guard.finding(item[0], item[1], label, item[2], item[3])
    guard.save(key, {'date': guard.today.isoformat(), 'findings': findings, 'complete': complete})


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', action='append', default=[], help='個別のリポ（繰り返し可）')
    parser.add_argument('--root', action='append', default=[], help='リポが並ぶルート（繰り返し可）')
    parser.add_argument('--repos-file', help='本体から渡す NUL 区切りのリポ一覧')
    parser.add_argument('roots', nargs='*', help='点検ルート')
    args = parser.parse_args()
    guard = Guard()
    paths = [Path(p).expanduser().resolve() for p in args.repo]
    if args.repos_file:
        paths += [Path(os.fsdecode(p)).resolve() for p in Path(args.repos_file).read_bytes().split(b'\0') if p]
    for raw in args.root + args.roots:
        root = Path(raw).expanduser().resolve()
        if not root.is_dir():
            guard.emit('WARN', 'root_unchecked', '-', '-', '点検ルートがなく未検査です')
            continue
        if (root / '.git').exists():
            paths.append(root)
        else:
            paths += [p.resolve() for p in root.iterdir() if p.is_dir() and not p.is_symlink() and not p.name.startswith('.') and (p / '.git').exists()]
    logged_in = False
    if os.environ.get('RH_DATA_GITHUB', '1') != '0' and shutil.which('gh'):
        try:
            run(['gh', 'auth', 'status'])
            logged_in = True
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    repos = []
    for path in select_clones(paths, guard):
        repo = Repo(path)
        repos.append(repo)
        try:
            discover(repo, guard)
            github(repo, guard, logged_in)
            history(repo, guard)
            source_scan(repo, guard)
        except (OSError, ValueError, subprocess.SubprocessError):
            guard.emit('WARN', 'repo_unchecked', repo.label, '-', 'リポのファイルを読み切れず未検査です')
    ref_groups = defaultdict(list)
    for repo in repos:
        for ref in repo.refs:
            ref_groups[ref].append(repo)
    # 複数refを使うリポも、それぞれの共有相手へ静的SQLを関連付けます。
    group_tables = {}
    for ref, group in sorted(ref_groups.items()):
        shared = len(group) > 1
        if shared:
            label = ', '.join(r.label for r in group)
            guard.emit('INFO', 'shared_project', label, ref[:4] + '…', f'{len(group)}リポが同じプロジェクトを使っています。方針の当たりはこの全リポへ影響します。スキーマ・所属条件・プロジェクトの分離を検討してください')
            if sum(bool(r.sql) for r in group) > 1:
                guard.emit('WARN', 'migration_collision', label, ref[:4] + '…', '複数リポに SQL があり migration 履歴がぶつかる可能性があります')
        for repo in group:
            if not repo.sql:
                guard.emit('NOTE', 'migration_missing', repo.label, ref[:4] + '…', 'SQL の表定義がなく静的には未検査です。公開鍵の実測か本番カタログで確認してください')
        group_tables[ref] = static_group(group, guard, shared)
    for repo in repos:
        if not repo.refs:
            static_group([repo], guard, False)
    live_rls = {}
    if os.environ.get('RH_SUPABASE_CATALOG', '0') == '1':
        refs = os.environ.get('RH_SUPABASE_CATALOG_REFS', '').split()
        if not refs:
            guard.emit('WARN', 'catalog_unchecked', '-', '-', '本番カタログの対象 ref がなく未検査です')
        for ref in sorted(set(refs)):
            if not re.fullmatch(r'[a-z0-9]{20}', ref):
                guard.emit('WARN', 'catalog_unchecked', '-', '-', '本番カタログの ref の形式が不正です（未検査）')
                continue
            live = catalog(ref, ref_groups[ref], group_tables.get(ref, {}), guard)
            live_rls.update({k: v for k, v in (live or {}).items()})
            for target in live:
                group_tables.setdefault(ref, {}).setdefault(target, {})
    else:
        guard.emit('NOTE', 'catalog_disabled', '-', '-', '本番カタログは既定オフです（本番は未確認）')
    for args, kwargs in guard.deferred_rls:
        kind, target = args[1], args[3]
        if live_rls and kind == 'rls_off':
            # 本番で RLS 有効と確かめられた表は出さない（食い違いの NOTE が代わりに出る）。本番に無い表は注記だけ
            if live_rls.get(target) is True:
                continue
            if target not in live_rls:
                guard.finding('NOTE', 'rls_off', args[2], target, 'migration にだけある表です（本番には表がありません）', **kwargs)
                continue
        if guard.live_functions is not None and kind == 'definer_execute':
            # 本番の権限が正本。本番にある関数は本番の結果（WARN か参考）に任せ、無い関数は注記だけ
            if target in guard.live_functions:
                continue
            guard.finding('NOTE', 'definer_execute', args[2], target, 'migration にだけある関数です（本番には関数がありません）', **kwargs)
            continue
        if guard.live_views is not None and kind in ('view_owner', 'materialized_view'):
            # 本番の VIEW の権限が正本。本番にある VIEW は本番の結果に任せ、無いものは注記だけ
            if target in guard.live_views:
                continue
            guard.finding('NOTE', kind, args[2], target, 'migration にだけある VIEW です（本番には VIEW がありません）', **kwargs)
            continue
        guard.finding(*args, **kwargs)
    guard.deferred_rls = []
    if os.environ.get('RH_SUPABASE_ANON_PROBE', '0') == '1':
        probed = set()
        for repo in repos:
            if repo.refs - probed:
                probed.update(anon_probe(repo, group_tables, guard))
    else:
        guard.emit('NOTE', 'probe_disabled', '-', '-', '公開鍵での実測は既定オフです（本番は未確認）')
    sites = os.environ.get('RH_SITE_URLS', '').split()
    for index, site in enumerate(dict.fromkeys(sites), 1):
        site_scan(site, index, guard)
    if not sites:
        guard.emit('NOTE', 'site_disabled', '-', '-', '本番サイトは URL 未設定のため未検査です')
    print(f'DG_DONE\t{len(repos)}\t{guard.statements}', flush=True)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except Exception:
        # 例外に秘密の値やソース断片が含まれることがあるため表示しません。
        print('DG\tWARN\tscanner_unchecked\t-\t-\tデータの守りの点検が最後まで動きませんでした（未検査）', flush=True)
        raise SystemExit(1) from None
