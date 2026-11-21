#!/usr/bin/env python3
"""偽リポ・偽CLIだけでデータの守りの境界を検証します。"""
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parent.parent
SCANNER = PROJECT / 'bin/data-guard.py'
spec = importlib.util.spec_from_file_location('data_guard', SCANNER)
dg = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = dg
spec.loader.exec_module(dg)
REF = 'abcdefghijklmnopqrst'
FAKE_PASSWORD = 'fixture-password-never-print'
FAKE_KEY = 'fixture-publishable-never-print'
ROW_VALUE = 'fixture-row-never-print'

FAKE_CLI = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
from urllib.parse import urlsplit
root = pathlib.Path(os.environ['DG_FIXTURE'])
cmd = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'cli-log').open('a') as h:
    h.write(json.dumps([cmd, args, time.monotonic()]) + '\n')
if cmd == 'git':
    repo = pathlib.Path(args[args.index('-C')+1])
    if 'symbolic-ref' in args:
        p = repo / ('.fixture-default' if args[-1] == 'refs/remotes/origin/HEAD' else '.fixture-branch')
        if not p.exists(): sys.exit(1)
        print(p.read_text().strip())
    elif 'for-each-ref' in args or 'rev-parse' in args: print('a'*40)
    elif 'log' in args and '--format=%ct' in args:
        p = repo / '.fixture-date'
        print(p.read_text().strip() if p.exists() else '0')
    elif 'log' in args:
        p = repo / '.fixture-history'
        if p.exists(): sys.stdout.write(p.read_text())
    elif 'remote' in args:
        p = repo / '.fixture-origin'
        print(p.read_text().strip() if p.exists() else 'https://github.com/example/' + repo.name + '.git')
elif cmd == 'gh':
    if 'status' in args:
        sys.exit(int(os.environ.get('DG_GH_AUTH_RC', '0')))
    if any('vulnerability-alerts' in a for a in args):
        # gh api -i は、4xx でもヘッダの先頭行（HTTP/x.x NNN）を出して終了コードが 0 になりません。
        code = os.environ.get('DG_GH_VULN', '204')
        if code == 'none': sys.exit(1)
        print('HTTP/2.0 ' + code + ' Status\ncontent-type: application/json\n')
        if code != '204': print('{"message":"fixture-body-never-print"}')
        sys.exit(0 if code == '204' else 1)
    if any('dependabot/alerts' in a for a in args):
        if os.environ.get('DG_GH_ALERT_DENY'): sys.exit(1)
        print('[[{"security_advisory":{"severity":"high"}}]]')
    else:
        print(json.dumps({'private': os.environ.get('DG_PUBLIC', '0') != '1'}))
elif cmd == 'security':
    if os.environ.get('DG_NO_KEY'): sys.exit(1)
    print('postgresql://audit:fixture-password-never-print@db.example.invalid:6543/database')
elif cmd == 'psql':
    query = sys.stdin.read()
    (root / 'query.sql').write_text(query)
    (root / 'pg-flags.json').write_text(json.dumps({
      'password_ok': os.environ.get('PGPASSWORD') == 'fixture-password-never-print',
      'ssl_ok': os.environ.get('PGSSLMODE') == 'require',
      'readonly_ok': 'default_transaction_read_only=on' in os.environ.get('PGOPTIONS', '')}))
    if os.environ.get('DG_PSQL_FAIL'): sys.exit(1)
    print((root / 'catalog.json').read_text())
elif cmd == 'curl':
    config = sys.stdin.read()
    url = json.loads(next(s.split('=',1)[1].strip() for s in config.splitlines() if s.startswith('url =')))
    public = 'fixture-publishable-never-print' in config
    with (root / 'requests.jsonl').open('a') as h:
        h.write(json.dumps({'url': url, 'time': time.monotonic(), 'public_key_ok': public})+'\n')
    path = urlsplit(url).path
    mode = os.environ.get('DG_HTTP_MODE', 'probe')
    status, body, headers = 200, '', 'Content-Type: application/json'
    if mode == 'probe':
        body = '[{"private":"fixture-row-never-print"}]' if os.environ.get('DG_READABLE', '1') == '1' else '[]'
        if os.environ.get('DG_PROBE_FAIL'):
            status, body = 500, '{}'
    else:
        if path in ('/.env','/.git/config'):
            status = 200 if mode == 'site-bad' else 404
            body = 'fixture-row-never-print'
        elif path.endswith('.map'):
            status, body = 200, '{"version":3,"sources":[]}'
        elif path.endswith('.js'):
            body = 'const k="sb_secret_fixturebrowserkey";' if mode == 'site-bad' else 'const a=1;'
        else:
            body = '<script src="/app.js"></script>'
            headers = 'Content-Type: text/html\nX-Content-Type-Options: nosniff'
    print('HTTP/1.1 '+str(status)+' Status\n'+headers+'\n\n'+body+'\nRH_HTTP_STATUS:'+str(status), end='')
'''


def jwt(role):
    payload = base64.urlsafe_b64encode(json.dumps({'role': role}).encode()).decode().rstrip('=')
    return 'eyJhbGciOiJIUzI1NiJ9.' + payload + '.fixtureSignature'


def catalog_data():
    return {'tables_total': 1,
            'tables': [{'target': 'public.app_a_profiles', 'rls': False, 'anon': True, 'authenticated': True}],
            'policies': [], 'views': [], 'functions': [], 'buckets': [], 'realtime': [], 'schemas': ['public']}


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='data-guard-test-')
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'fake-bin'
        self.bin.mkdir()
        for cmd in ('git', 'gh', 'security', 'psql', 'curl'):
            path = self.bin / cmd
            path.write_text(FAKE_CLI)
            path.chmod(0o755)
        self.state = self.root / 'state'
        self.repo = self.new_repo('app-a')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        HOME=str(self.root / 'home'), DG_FIXTURE=str(self.root),
                        RH_STATE_DIR=str(self.state), RH_DATA_GITHUB='0',
                        RH_SUPABASE_CATALOG='0', RH_SUPABASE_ANON_PROBE='0', RH_SITE_URLS='',
                        RH_TODAY='2026-11-16', RH_DATA_ALLOW=str(self.root / 'allow.tsv'), RH_SUPABASE_APPS='')
        for key in list(self.env):
            if key.startswith('DG_') and key != 'DG_FIXTURE':
                del self.env[key]
        (self.root / 'catalog.json').write_text(json.dumps(catalog_data()))

    def tearDown(self):
        self.tmp.cleanup()

    def new_repo(self, label, ref=None):
        path = self.root / 'repos' / label
        (path / '.git').mkdir(parents=True)
        if ref:
            self.write('supabase/.temp/project-ref', ref, path)
        return path

    def write(self, rel, text, repo=None):
        path = (repo or self.repo) / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def sql(self, text, filename='001.sql', repo=None):
        return self.write('supabase/migrations/' + filename, text, repo)

    def scan(self, **env):
        proc = subprocess.run([sys.executable, '-I', str(SCANNER), '--root', str(self.root / 'repos')],
                              env=dict(self.env, **env), text=True, capture_output=True, timeout=35)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertRegex(proc.stdout, r'DG_DONE\t\d+\t\d+\n$')
        self.assertEqual(proc.stderr, '')
        self.assertNotIn(FAKE_PASSWORD, proc.stdout)
        self.assertNotIn(FAKE_KEY, proc.stdout)
        self.assertNotIn(ROW_VALUE, proc.stdout)
        return proc.stdout

    def assert_hit(self, output, level, kind):
        self.assertIn(f'DG\t{level}\t{kind}\t', output)

    def assert_no_hit(self, output, kind):
        self.assertNotRegex(output, r'DG\t(?:FAIL|WARN|NOTE|INFO)\t' + kind + r'\t')

    def open_sql(self, role='anon', command='SELECT', expr='true'):
        return f'create table app_a_profiles(id uuid, org_id uuid); alter table app_a_profiles enable row level security; create policy app_a_access on app_a_profiles for {command} to {role} ' + (f'with check ({expr});' if command == 'INSERT' else f'using ({expr});')

    def test_rls_off(self):
        self.sql('create table app_a_profiles(id uuid);')
        self.assert_hit(self.scan(), 'WARN', 'rls_off')

    def test_select_open(self):
        self.sql(self.open_sql())
        self.assert_hit(self.scan(), 'WARN', 'policy_open')

    def test_insert_reference(self):
        self.sql(self.open_sql(command='INSERT'))
        out = self.scan()
        self.assert_hit(out, 'INFO', 'policy_insert')
        self.assert_no_hit(out, 'policy_open')

    def test_all_with_check_inherits_using(self):
        self.sql(self.open_sql(command='ALL', expr='auth.uid() = id'))
        self.assert_no_hit(self.scan(), 'policy_open')

    def test_all_open_check(self):
        self.sql(self.open_sql(command='ALL', expr='auth.uid() = id')[:-1] + ' with check (true);')
        self.assert_hit(self.scan(), 'WARN', 'policy_open')

    def test_later_drop_policy(self):
        self.sql(self.open_sql())
        self.sql('drop policy app_a_access on app_a_profiles;', '002.sql')
        self.assert_no_hit(self.scan(), 'policy_open')

    def test_later_alter_policy(self):
        self.sql(self.open_sql())
        self.sql('alter policy app_a_access on app_a_profiles using (auth.uid() = id);', '002.sql')
        self.assert_no_hit(self.scan(), 'policy_open')

    def test_later_enable_rls(self):
        self.sql('create table app_a_profiles(id uuid);')
        self.sql('alter table app_a_profiles enable row level security;', '002.sql')
        self.assert_no_hit(self.scan(), 'rls_off')

    def test_disable_rls(self):
        self.sql(self.open_sql())
        self.sql('alter table app_a_profiles disable row level security;', '002.sql')
        self.assert_hit(self.scan(), 'WARN', 'rls_off')

    def test_drop_table(self):
        self.sql('create table app_a_profiles(id uuid); drop table app_a_profiles;')
        self.assert_no_hit(self.scan(), 'rls_off')

    def test_rename_table(self):
        self.sql('create table app_a_profiles(id uuid); alter table app_a_profiles rename to app_a_people; alter table app_a_people enable row level security;')
        self.assert_no_hit(self.scan(), 'rls_off')

    def test_dynamic_enable_note(self):
        self.sql("create table app_a_profiles(id uuid); do $$ begin execute 'alter table app_a_profiles enable row level security'; end $$;")
        out = self.scan()
        self.assert_hit(out, 'NOTE', 'rls_off')
        self.assertIn('動的 SQL', out)

    def test_quoted_table_case(self):
        self.sql('create table "App_A_Profiles"(id uuid); alter table "App_A_Profiles" enable row level security;')
        self.assert_no_hit(self.scan(), 'rls_off')

    def test_view(self):
        self.sql('create view app_a_view as select 1;')
        self.assert_hit(self.scan(), 'WARN', 'view_owner')

    def test_view_invoker(self):
        self.sql('create view app_a_view with(security_invoker=true) as select 1;')
        self.assert_no_hit(self.scan(), 'view_owner')

    def test_materialized(self):
        self.sql('create materialized view app_a_view as select 1;')
        self.assert_hit(self.scan(), 'WARN', 'materialized_view')

    def test_definer(self):
        self.sql('create function app_a_func() returns int language sql security definer as $$ select 1; $$;')
        out = self.scan()
        self.assert_hit(out, 'WARN', 'definer_path')
        self.assert_hit(out, 'WARN', 'definer_execute')

    def test_definer_hardened(self):
        self.sql('create function app_a_func() returns int language sql security definer set search_path=public as $$ select 1; $$; revoke execute on function app_a_func() from public, anon;')
        out = self.scan()
        self.assert_no_hit(out, 'definer_path')
        self.assert_no_hit(out, 'definer_execute')

    def test_service_role_misnamed(self):
        self.sql(self.open_sql().replace('app_a_access', 'service_role_all').replace(' to anon', ''))
        self.assert_hit(self.scan(), 'FAIL', 'policy_service_name')

    def test_service_role_only(self):
        self.sql(self.open_sql(role='service_role'))
        self.assert_no_hit(self.scan(), 'policy_open')

    def test_deny_all(self):
        self.sql('create table app_a_profiles(id uuid); alter table app_a_profiles enable row level security;')
        out = self.scan()
        self.assert_no_hit(out, 'rls_off')
        self.assert_no_hit(out, 'policy_open')

    def test_unusual_sql_location(self):
        self.write('database/bootstrap.sql', 'create table app_a_profiles(id uuid);')
        self.assert_hit(self.scan(), 'WARN', 'rls_off')

    def test_comments_and_dollars(self):
        self.sql("-- create table ignored(id int);\ncreate table app_a_profiles(id text default 'a;b');\n/* create policy x on app_a_profiles using(true); */\nalter table app_a_profiles enable row level security;")
        out = self.scan()
        self.assertIn('DG_DONE\t1\t2', out)
        self.assert_no_hit(out, 'rls_off')

    def test_shared_authenticated(self):
        self.write('supabase/.temp/project-ref', REF)
        self.new_repo('app-b', REF)
        self.sql(self.open_sql(role='authenticated'))
        out = self.scan()
        self.assert_hit(out, 'FAIL', 'policy_authenticated')
        self.assertIn('別のアプリで登録した人も読めます', out)
        self.assertNotIn(REF, out)

    def test_single_authenticated(self):
        self.sql(self.open_sql(role='authenticated'))
        self.assert_hit(self.scan(), 'WARN', 'policy_authenticated')

    def test_shared_uid_not_null(self):
        self.write('supabase/.temp/project-ref', REF)
        self.new_repo('app-b', REF)
        self.sql(self.open_sql(role='authenticated', expr='(auth.uid()) is not null'))
        self.assert_hit(self.scan(), 'FAIL', 'policy_authenticated')

    def test_shared_role(self):
        self.write('supabase/.temp/project-ref', REF)
        self.new_repo('app-b', REF)
        self.sql(self.open_sql(role='authenticated', expr="auth.role() = 'authenticated'"))
        self.assert_hit(self.scan(), 'FAIL', 'policy_authenticated')

    def test_shared_cross_repo_fix(self):
        self.write('supabase/.temp/project-ref', REF)
        other = self.new_repo('app-b', REF)
        self.sql(self.open_sql(role='authenticated'))
        self.sql('drop policy app_a_access on app_a_profiles;', '002.sql', other)
        self.assert_no_hit(self.scan(), 'policy_authenticated')

    def test_table_collision(self):
        self.write('supabase/.temp/project-ref', REF)
        other = self.new_repo('app-b', REF)
        self.sql('create table if not exists app_a_profiles(id uuid);')
        self.sql('create table if not exists app_a_profiles(id uuid, label text);', repo=other)
        self.assert_hit(self.scan(), 'WARN', 'table_collision')

    def test_default_off_notes_are_not_unchecked(self):
        out = self.scan()
        for kind in ('catalog_disabled', 'probe_disabled', 'site_disabled'):
            self.assert_hit(out, 'NOTE', kind)
            line = next(row for row in out.splitlines() if f'\t{kind}\t' in row)
            self.assertNotIn('未検査', line)

    def test_table_collision_dropped_later(self):
        self.write('supabase/.temp/project-ref', REF)
        other = self.new_repo('app-b', REF)
        self.sql('create table if not exists app_a_profiles(id uuid);')
        self.sql('create table if not exists app_a_profiles(id uuid, label text);', repo=other)
        self.sql('drop table if exists public.app_a_profiles, app_a_other cascade;', '002.sql', other)
        out = self.scan()
        self.assert_no_hit(out, 'table_collision')
        self.assert_no_hit(out, 'rls_off')

    def test_table_collision_recreated_after_drop(self):
        self.write('supabase/.temp/project-ref', REF)
        other = self.new_repo('app-b', REF)
        self.sql('create table app_a_profiles(id uuid);')
        self.sql('drop table app_a_profiles;', '002.sql')
        self.sql('create table app_a_profiles(id uuid, label text);', '003.sql', other)
        self.sql('create table app_a_profiles(id uuid, note text);', '004.sql')
        self.assert_hit(self.scan(), 'WARN', 'table_collision')

    def test_table_collision_same_definition(self):
        self.write('supabase/.temp/project-ref', REF)
        other = self.new_repo('app-b', REF)
        self.sql("create table app_a_profiles(id uuid, label text default 'A (demo)', amount numeric(8, 2));")
        self.sql("CREATE TABLE IF NOT EXISTS public.app_a_profiles ( ID UUID, /* copy */ LABEL TEXT DEFAULT 'A (demo)', AMOUNT NUMERIC (8,2) );", repo=other)
        out = self.scan()
        self.assert_hit(out, 'INFO', 'table_collision')
        self.assertNotIn('DG\tWARN\ttable_collision\t', out)
        self.assertIn('同じ定義を複数リポが持っています', out)

    def test_table_collision_preserves_quoted_values(self):
        self.write('supabase/.temp/project-ref', REF)
        other = self.new_repo('app-b', REF)
        self.sql("create table app_a_profiles(label text default 'A  B');")
        self.sql("create table app_a_profiles(label text default 'a b');", repo=other)
        self.assert_hit(self.scan(), 'WARN', 'table_collision')

    def test_table_collision_different_refs(self):
        self.write('supabase/.temp/project-ref', REF)
        other = self.new_repo('app-b', 'bbbbbbbbbbbbbbbbbbbb')
        self.sql('create table app_a_profiles(id uuid);')
        self.sql('create table app_a_profiles(id text);', repo=other)
        self.assert_no_hit(self.scan(), 'table_collision')

    def clone_fixture(self, branch_a='main', branch_b='topic', date_a=100, date_b=200):
        other = self.new_repo('app-b', REF)
        for repo, branch, stamp in ((self.repo, branch_a, date_a), (other, branch_b, date_b)):
            self.write('.fixture-origin', 'https://example.invalid/fixture/app.git', repo)
            self.write('.fixture-default', 'refs/remotes/origin/main', repo)
            self.write('.fixture-branch', branch, repo)
            self.write('.fixture-date', str(stamp), repo)
            self.write('supabase/.temp/project-ref', REF, repo)
        return other

    def test_done_counts_git_repos_from_repos_file(self):
        # 本体は点検ルートの全フォルダを渡し、git のリポの数と DG_DONE を照らし合わせる。git でないフォルダは数えない
        plain = self.root / 'repos' / 'not-a-repo'
        plain.mkdir(parents=True, exist_ok=True)
        listing = self.root / 'repos.list'
        listing.write_bytes(b'\0'.join(os.fsencode(str(x)) for x in (self.repo, plain)) + b'\0')
        proc = subprocess.run([sys.executable, '-I', str(SCANNER), '--repos-file', str(listing)], env=self.env, text=True, capture_output=True, timeout=35)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertRegex(proc.stdout, r'DG_DONE\t1\t\d+\n$')

    def test_clone_default_excludes_old_findings(self):
        other = self.clone_fixture()
        self.sql(self.open_sql(role='authenticated'))
        self.sql('create table app_b_legacy(id uuid);', repo=other)
        self.write('app/page.tsx', "'use client'; const key=process.env.APP_SECRET;", other)
        self.write('.fixture-history', '.env.local\0', other)
        out = self.scan(RH_DATA_GITHUB='1')
        self.assert_hit(out, 'NOTE', 'clone_skipped')
        self.assertIn('同じリモートの別の clone（topic）は省略', out)
        self.assert_hit(out, 'WARN', 'policy_authenticated')
        for kind in ('shared_project', 'rls_off', 'browser_service_key', 'history_key_file'):
            self.assert_no_hit(out, kind)
        # 本体は渡したリポの数と照らし合わせるので、省いた clone も数に入れる（2 本渡して 1 本を省いても 2）
        self.assertIn('DG_DONE\t2\t', out)
        logs = [json.loads(line) for line in (self.root / 'cli-log').read_text().splitlines()]
        self.assertFalse(any('repos/example/app-b' in arg for entry in logs if entry[0] == 'gh' for arg in entry[1]))

    def test_clone_default_keeps_findings(self):
        self.clone_fixture(branch_a='topic', branch_b='main')
        self.sql('create table app_a_legacy(id uuid);')
        self.sql('create table app_b_profiles(id uuid);', repo=self.root / 'repos/app-b')
        out = self.scan()
        self.assert_hit(out, 'WARN', 'rls_off')
        self.assertNotIn('public.app_a_legacy', out)
        self.assertIn('public.app_b_profiles', out)

    def test_clone_fallback_latest_commit(self):
        other = self.clone_fixture('topic-a', 'topic-b')
        self.sql('create table app_a_legacy(id uuid);')
        self.sql('create table app_b_profiles(id uuid);', repo=other)
        out = self.scan()
        self.assertIn('public.app_b_profiles', out)
        self.assertNotIn('public.app_a_legacy', out)
        self.assertIn('DG_DONE\t2\t', out)

    def test_clone_fallback_latest_can_be_first(self):
        self.clone_fixture('topic-a', 'topic-b', 300, 200)
        self.sql('create table app_a_profiles(id uuid);')
        self.assertIn('public.app_a_profiles', self.scan())

    def test_distinct_origins_are_both_scanned(self):
        self.new_repo('app-b')
        out = self.scan()
        self.assert_no_hit(out, 'clone_skipped')
        self.assertIn('DG_DONE\t2\t', out)

    def test_env_only_ref(self):
        self.write('.env.local', f'NEXT_PUBLIC_SUPABASE_URL=https://{REF}.supabase.co\nOTHER_SECRET={FAKE_PASSWORD}\n')
        self.new_repo('app-b', REF)
        out = self.scan()
        self.assert_hit(out, 'INFO', 'shared_project')
        self.assertNotIn('OTHER_SECRET', out)

    def test_project_ref_file_is_not_mixed_with_other_files(self):
        # supabase/.temp/project-ref が見つかったら、ほかのファイルの公開 URL は ref として読まない
        other = 'zyxwvutsrqponmlkjihg'
        repo_p = self.new_repo('app-p', REF)
        self.write('lib/url.ts', f'export const url = "https://{other}.supabase.co";', repo_p)
        self.new_repo('app-q', other)
        self.assert_no_hit(self.scan(), 'shared_project')

    def test_work_folders_and_nested_checkouts_are_not_read(self):
        leak = 'create table {}(id uuid);'
        self.sql(leak.format('app_a_profiles'))
        # Claude Code の作業フォルダ（worktree）・.git ファイルを持つ git worktree・.git フォルダを持つ入れ子の checkout
        self.write('.claude/worktrees/agent-x/supabase/migrations/001.sql', leak.format('leak_claude'))
        self.write('copy-a/supabase/migrations/001.sql', leak.format('leak_worktree'))
        (self.repo / 'copy-a/.git').write_text('gitdir: /nonexistent/worktrees/copy-a\n')
        self.write('packages/copy-b/supabase/migrations/001.sql', leak.format('leak_nested'))
        (self.repo / 'packages/copy-b/.git').mkdir()
        out = self.scan()
        self.assertIn('public.app_a_profiles', out)
        for name in ('leak_claude', 'leak_worktree', 'leak_nested'):
            self.assertNotIn(name, out)

    def test_build_output_folders_are_not_read(self):
        # dist・build・out・coverage は、親に package.json があるとき（リポの根・パッケージの根）だけ読まない。.vercel・.turbo はどの深さでも読まない
        url = f'export const u = "https://{REF}.supabase.co";'
        self.write('package.json', '{}')
        self.write('packages/p/package.json', '{}')
        self.sql('create table app_a_profiles(id uuid);')
        self.write('dist/x.js', url)
        self.write('packages/p/dist/x.js', url)
        for folder in ('dist', 'build', 'out', 'coverage'):
            self.write(f'{folder}/supabase/migrations/001.sql', 'create table leak_root_' + folder + '(id uuid);')
            self.write(f'packages/p/{folder}/supabase/migrations/001.sql', 'create table leak_pkg_' + folder + '(id uuid);')
        for folder in ('.vercel', '.turbo'):
            name = folder.strip('.')
            self.write(f'{folder}/supabase/migrations/001.sql', 'create table leak_root_' + name + '(id uuid);')
            self.write(f'apps/web/{folder}/supabase/migrations/001.sql', 'create table leak_web_' + name + '(id uuid);')
        self.new_repo('app-b', REF)
        out = self.scan()
        self.assertIn('public.app_a_profiles', out)
        self.assertNotIn('leak_', out)
        # dist/x.js を読めば app-a も REF を持ち、app-b と共有になる
        self.assert_no_hit(out, 'shared_project')

    def test_source_folders_named_like_build_output_are_read(self):
        # package.json のない親の下の build・out・dist などは、ソースとして読む
        self.write('package.json', '{}')
        self.write('app/page.tsx', "'use client';\nimport { db } from '../lib/out/db';")
        self.write('lib/out/db.ts', 'const db = process.env.SUPABASE_SERVICE_ROLE_KEY;')
        self.write('app/api/build/route.ts', 'export function POST() {}')
        self.write('sub/dist/x.js', f'export const u = "https://{REF}.supabase.co";')
        for folder in ('dist', 'build', 'out', 'coverage'):
            self.write(f'sub/{folder}/supabase/migrations/001.sql', 'create table leak_sub_' + folder + '(id uuid);')
        self.new_repo('app-b', REF)
        out = self.scan()
        # lib/out/db.ts を読めたので、それを import する app/page.tsx が FAIL になる
        self.assertRegex(out, r'FAIL\tbrowser_service_key\t[^\n]*app/page\.tsx')
        self.assertRegex(out, r'api_auth_unknown\t[^\n]*app/api/build/route\.ts')
        self.assert_hit(out, 'INFO', 'shared_project')
        for folder in ('dist', 'build', 'out', 'coverage'):
            self.assertIn('leak_sub_' + folder, out)

    def test_browser_env(self):
        self.write('.env.local', 'NEXT_PUBLIC_SERVICE_ROLE_KEY=' + FAKE_PASSWORD)
        self.assert_hit(self.scan(), 'FAIL', 'browser_env')

    def test_browser_import(self):
        self.write('app/page.tsx', "'use client';\nimport { db } from '../lib/db';")
        self.write('lib/db.ts', 'const db = process.env.SUPABASE_SERVICE_ROLE_KEY;')
        self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')

    def test_server_only_import(self):
        self.write('app/page.tsx', "'use client';\nimport { db } from '../lib/db';")
        self.write('lib/db.ts', "import 'server-only';\nconst db = process.env.SUPABASE_SERVICE_ROLE_KEY;")
        self.assert_no_hit(self.scan(), 'browser_service_key')

    def test_client_directive_leading_comments(self):
        for directive in ("'use client';", '"use client"\n'):
            with self.subTest(directive=directive):
                self.write('src/app/page.tsx', '\n// heading\n/* heading */\n' + directive + '\nconst key=process.env.APP_SECRET;')
                self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')

    def test_client_directive_must_be_first_statement(self):
        for prefix in ("const a=1; // 'use client'\n", '/* "use client" */\n',
                       "'use server';\n'use client';\n", "const hint = \"'use client'\";\n",
                       "'use client' + 'example';\n", "'use client'\n+ 'example';\n"):
            with self.subTest(prefix=prefix):
                self.write('lib/server.ts', prefix + 'const key=process.env.APP_SERVICE_ROLE_KEY;')
                self.assert_no_hit(self.scan(), 'browser_service_key')

    def test_browser_words_comments_and_strings_are_ignored(self):
        self.write('app/page.tsx', """'use client';
// process.env.APP_SECRET and service_role
/* process.env.APP_PRIVATE_KEY */
const quiz = 'SERVICE_ROLE_KEY service_role process.env.APP_PASSWORD';
const lesson = `process.env.APP_REFRESH_TOKEN`;
""")
        self.assert_no_hit(self.scan(), 'browser_service_key')

    def test_browser_private_env_references(self):
        for word in ('SERVICE_ROLE', 'SECRET', 'PRIVATE_KEY', 'PASSWORD', 'ACCESS_TOKEN', 'REFRESH_TOKEN'):
            with self.subTest(word=word):
                self.write('hooks/use-demo.ts', "'use client'; const key=process.env.APP_" + word + ';')
                self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')

    def test_browser_template_expression_is_code(self):
        self.write('app/page.tsx', "'use client'; const value=`Bearer ${process.env.APP_SECRET}`;")
        self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')

    def test_browser_nested_template_expression_is_code(self):
        self.write('app/page.tsx', "'use client'; const value=`${{key: `nested ${process.env.APP_PASSWORD}`}.key}`;")
        self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')

    def test_browser_import_javascript_index(self):
        self.write('app/page.tsx', "'use client'; import { key } from '../lib/keys';")
        self.write('lib/keys/index.js', 'export const key=process.env.APP_ACCESS_TOKEN;')
        self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')

    def test_browser_actual_key_shapes(self):
        for key in ('sb_secret_fixturekey', jwt('service_role')):
            with self.subTest(key_kind=key[:3]):
                self.write('components/demo.tsx', "'use client'; const key='" + key + "';")
                out = self.scan()
                self.assert_hit(out, 'FAIL', 'browser_service_key')
                self.assertNotIn(key, out)

    def test_browser_public_values_and_comments_are_ignored(self):
        self.write('app/page.tsx', "'use client';\n// sb_secret_fixturekey\nconst key='" + jwt('anon') + "'; const url=process.env.NEXT_PUBLIC_APP_URL;")
        self.assert_no_hit(self.scan(), 'browser_service_key')

    def test_browser_source_scope(self):
        for rel in ('scripts/lesson.ts', 'training/page.tsx', 'next.config.ts',
                    'app/scripts/page.tsx', 'src/demo-scripts/page.tsx', 'lib/scripts-demo/key.ts'):
            self.write(rel, "'use client'; const key=process.env.APP_SECRET; const sample='sb_secret_fixturekey';")
        self.assert_no_hit(self.scan(), 'browser_service_key')

    def test_browser_import_scope(self):
        self.write('app/page.tsx', "'use client'; import { key } from '../scripts/demo';")
        self.write('scripts/demo.ts', 'export const key=process.env.APP_SECRET;')
        self.assert_no_hit(self.scan(), 'browser_service_key')

    def test_browser_import_words_and_server_marker_comments(self):
        self.write('app/page.tsx', "'use client'; import { key } from '@/lib/key';")
        self.write('src/lib/key.ts', "// import 'server-only';\nexport const key=process.env.APP_PRIVATE_KEY;")
        self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')
        self.write('src/lib/key.ts', "// process.env.APP_PRIVATE_KEY\nexport const quiz='SERVICE_ROLE_KEY';")
        self.assert_no_hit(self.scan(), 'browser_service_key')

    def test_browser_import_only_one_hop(self):
        self.write('app/page.tsx', "'use client'; import { key } from '../lib/first';")
        self.write('lib/first.ts', "export { key } from './second';")
        self.write('lib/second.ts', 'export const key=process.env.APP_SECRET;')
        self.assert_no_hit(self.scan(), 'browser_service_key')

    def test_browser_env_token_boundaries(self):
        for key in ('NEXT_PUBLIC_FF_PUBLIC_PRIVATE_SPLIT', 'NEXT_PUBLIC_SERVICE_URL',
                    'NEXT_PUBLIC_ROLE', 'NEXT_PUBLIC_TOKEN', 'NEXT_PUBLIC_MYSECRET',
                    'NEXT_PUBLIC_PRIVATE_LABEL_KEY', 'NEXT_PUBLIC_ACCESS_TOKENIZED'):
            self.write('.env.local', key + '=fixture')
            self.write('lib/public.ts', 'const value=process.env.' + key + ';')
            self.write('next.config.ts', 'export default {env: {' + key + ': "fixture"}};')
            with self.subTest(key=key):
                self.assert_no_hit(self.scan(), 'browser_env')

    def test_browser_env_secret_tokens(self):
        for word in ('SECRET', 'SERVICE_ROLE', 'PASSWORD', 'PRIVATE_KEY', 'ACCESS_TOKEN', 'REFRESH_TOKEN'):
            key = 'NEXT_PUBLIC_APP_' + word + '_VALUE'
            with self.subTest(word=word):
                self.write('.env.local', key + '=fixture')
                self.write('lib/public.ts', 'const value=process.env.' + key + ';')
                self.write('next.config.ts', 'export default {env: {APP_' + word + ': "fixture"}};')
                self.assertEqual(self.scan().count('DG\tFAIL\tbrowser_env\t'), 3)

    def test_static_bundle_jwt(self):
        self.write('.next/static/app.js', 'const a="' + jwt('service_role') + '";')
        self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')

    def test_static_bundle_routes_named_like_build_output(self):
        # 配信物の route 名が build・out・dist でも読み落とさない（ソースの除外とは分ける）
        for route in ('build', 'out', 'dist'):
            self.write(f'.next/static/chunks/app/{route}/page.js', 'const a="' + jwt('service_role') + '";')
        self.assertEqual(self.scan().count('DG\tFAIL\tbrowser_service_key\t'), 3)

    def test_static_bundle_anon(self):
        self.write('.next/static/app.js', 'const a="' + jwt('anon') + '";')
        self.assert_no_hit(self.scan(), 'browser_service_key')

    def test_static_bundle_secret(self):
        self.write('.next/static/app.js', 'sb_secret_fixturebrowserkey')
        self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')

    def test_history_incremental(self):
        self.write('.fixture-history', '.env.local\0keys/private.pem\0service-account.json\0.env.example\0')
        out = self.scan()
        self.assert_hit(out, 'WARN', 'history_key_file')
        self.assertNotIn('.env.example', out)
        self.scan()
        self.assertIn('--not', (self.root / 'cli-log').read_text())

    def test_history_public(self):
        self.write('.fixture-history', '.env.local\0')
        self.assert_hit(self.scan(RH_DATA_GITHUB='1', DG_PUBLIC='1'), 'FAIL', 'history_key_file')

    def test_cron_no_secret(self):
        self.write('vercel.json', '{"crons":[{"path":"/api/cron"}]}')
        self.write('app/api/cron/route.ts', 'export async function GET() { return Response.json({}); }')
        self.assert_hit(self.scan(), 'FAIL', 'cron_auth')

    def test_cron_secret_bypass(self):
        self.write('vercel.json', '{"crons":[{"path":"/api/cron"}]}')
        self.write('app/api/cron/route.ts', 'const cronSecret = process.env.CRON_SECRET; if (cronSecret && header !== cronSecret) return denied;')
        self.assert_hit(self.scan(), 'FAIL', 'cron_auth')

    def test_cron_secret_guard(self):
        self.write('vercel.json', '{"crons":[{"path":"/api/cron"}]}')
        self.write('app/api/cron/route.ts', 'const cronSecret = process.env.CRON_SECRET; if (!cronSecret || header !== cronSecret) return denied;')
        self.assert_no_hit(self.scan(), 'cron_auth')

    def test_captcha(self):
        self.write('lib/captcha.ts', 'const captcha=true; function verify(secret) { if (!secret) return true; }')
        self.assert_hit(self.scan(), 'FAIL', 'captcha_bypass')

    def test_map_limiter(self):
        self.write('app/api/form/route.ts', 'const rateLimit = new Map();\nexport function POST() { const now = Date.now(); const v = rateLimit.get(1); if (!v || v.reset < now) rateLimit.set(1, { count: 1, reset: now + 60000 }); }')
        self.assert_hit(self.scan(), 'WARN', 'memory_rate_limit')

    def test_lookup_map_is_not_limiter(self):
        # 問題の一覧などの引き表は、連射制限として数えない
        self.write('app/api/exam/route.ts', 'const QUESTION_BY_ID = new Map(QUESTIONS.map((q) => [q.id, q]));\nexport function POST() { return QUESTION_BY_ID.get(1); }')
        self.assert_no_hit(self.scan(), 'memory_rate_limit')

    def test_new_unauth_route(self):
        self.write('app/api/form/route.ts', 'export function POST() {}')
        self.assert_hit(self.scan(), 'INFO', 'api_auth_unknown')
        self.write('app/api/new/route.ts', 'export function POST() {}')
        out = self.scan()
        self.assert_hit(out, 'WARN', 'api_auth_unknown')
        self.assertRegex(out, r'WARN\tapi_auth_unknown\t[^\n]*app/api/new/route.ts')

    def test_proxy_prefix(self):
        self.write('app/api/private/form/route.ts', 'const key=process.env.SUPABASE_SERVICE_ROLE_KEY;')
        self.write('proxy.ts', "if (pathname.startsWith('/api/private')) { const user=auth.getUser(); }")
        out = self.scan()
        self.assert_no_hit(out, 'api_auth_unknown')
        self.assert_no_hit(out, 'api_service_auth')

    def test_tenant(self):
        self.sql(self.open_sql())
        self.assert_hit(self.scan(), 'WARN', 'tenant_boundary')

    def test_tenant_member_query(self):
        self.sql(self.open_sql(expr='exists(select 1 from app_a_members where user_id=auth.uid())'))
        self.assert_no_hit(self.scan(), 'tenant_boundary')

    def test_orm(self):
        self.write('package.json', '{"dependencies":{"@supabase/supabase-js":"1"}}')
        self.write('schema.ts', 'const a=pgTable("app_a_profiles",{});')
        self.assert_hit(self.scan(), 'WARN', 'orm_rls')

    def test_owner_registry(self):
        self.sql('create table app_a_profiles(id uuid);')
        registry = self.root / 'apps.tsv'
        registry.write_text('app_b_\tapp-b\tfixture\n')
        self.assert_hit(self.scan(RH_SUPABASE_APPS=str(registry)), 'WARN', 'owner_unknown')

    def test_github_cache(self):
        self.scan(RH_DATA_GITHUB='1', DG_PUBLIC='1')
        self.scan(RH_DATA_GITHUB='1', DG_PUBLIC='1')
        logs = [json.loads(l) for l in (self.root / 'cli-log').read_text().splitlines()]
        api_calls = [l for l in logs if l[0]=='gh' and l[1][0]=='api']
        self.assertEqual(len(api_calls), 2)

    def test_github_public_transition(self):
        self.scan(RH_DATA_GITHUB='1')
        for p in self.state.glob('*.json'):
            obj = json.loads(p.read_text())
            if 'time' in obj:
                obj['time'] = 0
                p.write_text(json.dumps(obj))
        self.assert_hit(self.scan(RH_DATA_GITHUB='1', DG_PUBLIC='1'), 'WARN', 'repo_public')

    def test_github_public_static_escalation(self):
        self.sql('create table app_a_profiles(id uuid);')
        self.assert_hit(self.scan(RH_DATA_GITHUB='1', DG_PUBLIC='1'), 'FAIL', 'rls_off')

    def test_github_permissions(self):
        out = self.scan(RH_DATA_GITHUB='1', DG_GH_ALERT_DENY='1')
        self.assert_hit(out, 'NOTE', 'dependabot_unchecked')

    def api_paths(self):
        logs = [json.loads(l) for l in (self.root / 'cli-log').read_text().splitlines()]
        return [arg for l in logs if l[0] == 'gh' and l[1][:1] == ['api'] for arg in l[1][1:] if arg.startswith('repos/')]

    def line(self, out, kind):
        return next(l for l in out.splitlines() if l.startswith(f'DG\tNOTE\t{kind}\t'))

    def test_dependabot_disabled_is_one_line_without_unchecked(self):
        out = self.scan(RH_DATA_GITHUB='1', DG_GH_ALERT_DENY='1', DG_GH_VULN='404')
        self.assert_hit(out, 'NOTE', 'dependabot_disabled')
        self.assert_no_hit(out, 'dependabot_unchecked')
        line = self.line(out, 'dependabot_disabled')
        self.assertIn('Dependabot のアラートが無効です（有効にする: gh api -X PUT repos/example/app-a/vulnerability-alerts）', line)
        self.assertNotIn('未検査', line)
        self.assertEqual(len([l for l in out.splitlines() if l.split('\t')[2].startswith('dependabot')]), 1)
        self.assertNotIn('fixture-body-never-print', out)

    def test_dependabot_disabled_is_cached(self):
        self.scan(RH_DATA_GITHUB='1', DG_GH_ALERT_DENY='1', DG_GH_VULN='404')
        first = len(self.api_paths())
        out = self.scan(RH_DATA_GITHUB='1', DG_GH_ALERT_DENY='1', DG_GH_VULN='404')
        self.assert_hit(out, 'NOTE', 'dependabot_disabled')
        self.assertEqual(len(self.api_paths()), first)
        self.assertEqual(sum(p.endswith('/vulnerability-alerts') for p in self.api_paths()), 1)

    def test_dependabot_forbidden_or_silent_stays_unchecked(self):
        for code in ('403', 'none', '204'):
            with self.subTest(code=code):
                shutil.rmtree(self.state, ignore_errors=True)
                out = self.scan(RH_DATA_GITHUB='1', DG_GH_ALERT_DENY='1', DG_GH_VULN=code)
                self.assert_hit(out, 'NOTE', 'dependabot_unchecked')
                self.assert_no_hit(out, 'dependabot_disabled')
                self.assertIn('未検査', self.line(out, 'dependabot_unchecked'))

    def test_dependabot_enabled_does_not_probe_status(self):
        out = self.scan(RH_DATA_GITHUB='1', DG_GH_VULN='404')
        self.assert_no_hit(out, 'dependabot_disabled')
        self.assertFalse(any(p.endswith('/vulnerability-alerts') for p in self.api_paths()))

    def test_github_stopped_by_setting_is_not_unchecked(self):
        out = self.scan(RH_DATA_GITHUB='0')
        line = self.line(out, 'github_unchecked')
        self.assertIn('GitHub の点検は止めています（設定 RH_DATA_GITHUB=0）', line)
        self.assertNotIn('未検査', line)
        logs = [json.loads(l) for l in (self.root / 'cli-log').read_text().splitlines()]
        self.assertFalse(any(l[0] == 'gh' for l in logs))

    def test_github_gh_missing_is_unchecked(self):
        (self.bin / 'gh').unlink()
        out = self.scan(RH_DATA_GITHUB='1', PATH=str(self.bin) + ':/usr/bin:/bin')
        line = self.line(out, 'github_unchecked')
        self.assertIn('gh が入っていない', line)
        self.assertIn('未検査', line)

    def test_allow_expiry(self):
        self.sql(self.open_sql())
        (self.root / 'allow.tsv').write_text('policy_open\tpublic.app_a_profiles:app_a_access\t\t2026-11-20\tfixture\n')
        out = self.scan()
        self.assert_hit(out, 'NOTE', 'policy_open')
        self.assert_hit(out, 'NOTE', 'allow_expiring')
        self.assert_hit(self.scan(RH_TODAY='2026-11-21'), 'WARN', 'policy_open')

    def test_allow_too_long(self):
        self.sql(self.open_sql())
        (self.root / 'allow.tsv').write_text('policy_open\tpublic.app_a_profiles:app_a_access\t\t2027-11-20\tfixture\n')
        out = self.scan()
        self.assert_hit(out, 'WARN', 'allow_invalid')
        self.assert_hit(out, 'WARN', 'policy_open')

    def test_allow_hash(self):
        self.sql(self.open_sql())
        out = self.scan()
        h = re.search(r'policy_open[^\n]*md5 ([a-f0-9]{12})', out)[1]
        (self.root / 'allow.tsv').write_text(f'policy_open\tpublic.app_a_profiles:app_a_access\t{h}\t2026-12-01\tfixture\n')
        self.assert_hit(self.scan(), 'NOTE', 'policy_open')
        self.sql(self.open_sql(role='public'))
        self.assert_hit(self.scan(), 'WARN', 'policy_open')

    def test_inline_allow(self):
        self.sql(self.open_sql().replace('create policy', '-- rh-allow: fixture until 2026-12-01\ncreate policy'))
        self.assert_hit(self.scan(), 'NOTE', 'policy_open')

    def test_rls_not_allowable(self):
        self.sql('-- rh-allow: fixture until 2026-12-01\ncreate table app_a_profiles(id uuid);')
        (self.root / 'allow.tsv').write_text('rls_off\tpublic.app_a_profiles\t\t2026-12-01\tfixture\n')
        self.assert_hit(self.scan(), 'WARN', 'rls_off')

    def test_browser_not_allowable(self):
        self.write('.next/static/app.js', 'sb_secret_fixturebrowserkey')
        (self.root / 'allow.tsv').write_text('browser_service_key\tapp-a:.next/static/app.js\t\t2026-12-01\tfixture\n')
        self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')

    def catalog(self, data=None, **env):
        if data is not None:
            (self.root / 'catalog.json').write_text(json.dumps(data))
        self.write('supabase/.temp/project-ref', REF)
        return self.scan(RH_SUPABASE_CATALOG='1', RH_SUPABASE_CATALOG_REFS=REF, **env)

    def test_catalog_first(self):
        self.assert_hit(self.catalog(), 'FAIL', 'rls_off')

    def test_catalog_diff(self):
        self.catalog()
        out = self.catalog(RH_TODAY='2026-11-17')
        self.assert_no_hit(out, 'rls_off')
        self.assert_hit(out, 'INFO', 'catalog_unchanged')
        data = catalog_data()
        data['tables'].append({'target':'public.app_b_profiles','rls':False,'anon':True,'authenticated':True})
        data['tables_total'] = 2
        out = self.catalog(data, RH_TODAY='2026-11-18')
        self.assert_hit(out, 'FAIL', 'rls_off')
        self.assertIn('public.app_b_profiles', out)

    def test_catalog_same_day_still_reported(self):
        self.catalog()
        self.assert_hit(self.catalog(), 'FAIL', 'rls_off')

    def test_catalog_drift(self):
        self.sql('create table app_a_profiles(id uuid); alter table app_a_profiles enable row level security;')
        self.assert_hit(self.catalog(), 'FAIL', 'catalog_drift')

    def test_catalog_drift_safe_direction(self):
        # migration に有効化が無く、本番は有効 → 安全な向きの食い違いは NOTE、静的な rls_off は出さない
        self.sql('create table app_a_profiles(id uuid);')
        data = catalog_data()
        data['tables'][0]['rls'] = True
        out = self.catalog(data)
        self.assert_hit(out, 'NOTE', 'catalog_drift')
        self.assertNotRegex(out, r'DG\t(?:FAIL|WARN)\tcatalog_drift\t')
        self.assertNotRegex(out, r'DG\t(?:FAIL|WARN)\trls_off\t')

    def test_catalog_table_only_in_migration(self):
        # migration にだけある表（本番に無い）は、静的な rls_off を注記に下げる
        self.sql('create table app_a_profiles(id uuid); alter table app_a_profiles enable row level security; create table app_a_legacy(id uuid);')
        data = catalog_data()
        data['tables'][0]['rls'] = True
        out = self.catalog(data)
        self.assertRegex(out, r'DG\tNOTE\trls_off\t[^\t]*\tpublic\.app_a_legacy\t')
        self.assertNotRegex(out, r'DG\t(?:FAIL|WARN)\trls_off\t[^\t]*\tpublic\.app_a_legacy\t')

    def test_catalog_definer_anon_and_authenticated(self):
        data = catalog_data()
        data['tables'][0]['rls'] = True
        data['functions'] = [
            {'target': 'public.app_a_open()', 'search_path': True, 'executable': True, 'anon': True, 'hash': 'aaaaaaaaaaaa'},
            {'target': 'public.app_a_member()', 'search_path': True, 'executable': True, 'anon': False, 'hash': 'bbbbbbbbbbbb'},
        ]
        out = self.catalog(data)
        self.assertRegex(out, r'DG\tWARN\tdefiner_execute\t[^\t]*\tpublic\.app_a_open\(\)\t')
        self.assertRegex(out, r'DG\tINFO\tdefiner_authenticated\t[^\t]*\tpublic\.app_a_member\(\)\t')
        self.assertNotRegex(out, r'DG\tWARN\tdefiner_execute\t[^\t]*\tpublic\.app_a_member\(\)\t')

    def test_storage_member_condition_is_not_bucket_only(self):
        self.sql("create policy app_a_members_read on storage.objects for select to authenticated using (bucket_id = 'app-a-members' and public.app_a_is_member());")
        self.assert_no_hit(self.scan(), 'storage_policy')
        self.sql("create policy app_a_any_read on storage.objects for select to authenticated using (bucket_id = 'app-a-files');", filename='002.sql')
        self.assert_hit(self.scan(), 'WARN', 'storage_policy')

    def test_app_specific_auth_names(self):
        # アプリ独自の名前のログイン確認は、認証の記述として認める
        self.write('app/api/app-a/items/route.ts', "import { getSessionUserId } from '@/lib/server/auth';\nconst key = process.env.SUPABASE_SERVICE_ROLE_KEY;\nexport async function GET(req) { const id = await getSessionUserId(req); if (id === null) return new Response('', { status: 401 }); }\n")
        self.assert_no_hit(self.scan(), 'api_service_auth')

    def test_tenant_boundary_skips_server_only_and_self_only(self):
        self.sql("create table app_a_members(id uuid, org_id uuid, email text); alter table app_a_members enable row level security;"
                 " create policy app_a_server on app_a_members for all to service_role using (true);"
                 " create policy app_a_self on app_a_members for select to authenticated using (email = public.app_a_request_email());")
        self.assert_no_hit(self.scan(), 'tenant_boundary')
        self.sql("create policy app_a_any on app_a_members for select to authenticated using (email is not null);", filename='002.sql')
        self.assert_hit(self.scan(), 'WARN', 'tenant_boundary')

    def test_catalog_zero(self):
        data = catalog_data()
        data.update(tables_total=0, tables=[])
        self.assert_hit(self.catalog(data), 'FAIL', 'catalog_unreadable')

    def test_catalog_missing_sentinel(self):
        data = catalog_data()
        del data['tables_total']
        self.assert_hit(self.catalog(data), 'FAIL', 'catalog_unreadable')

    def test_catalog_no_key(self):
        self.assert_hit(self.catalog(DG_NO_KEY='1'), 'WARN', 'catalog_unchecked')

    def test_catalog_failure_streak(self):
        self.catalog(DG_NO_KEY='1')
        self.catalog(DG_NO_KEY='1', RH_TODAY='2026-11-17')
        self.assert_hit(self.catalog(DG_NO_KEY='1', RH_TODAY='2026-11-18'), 'FAIL', 'catalog_unchecked')

    def test_catalog_args_and_state(self):
        self.catalog()
        log = (self.root / 'cli-log').read_text()
        self.assertNotIn(FAKE_PASSWORD, log)
        self.assertNotIn('postgresql://', log)
        self.assertEqual(json.loads((self.root / 'pg-flags.json').read_text()), {'password_ok':True,'ssl_ok':True,'readonly_ok':True})
        for p in self.state.glob('*'):
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            self.assertNotIn(FAKE_PASSWORD, p.read_text())
        query = (self.root / 'query.sql').read_text()
        self.assertEqual(len(re.findall(r'(?im)^select jsonb_build_object', query)), 1)
        self.assertIn('has_function_privilege', query)

    def test_catalog_policy_shapes(self):
        data = catalog_data()
        data['tables'][0]['rls'] = True
        data['policies'] = [{'target':'public.app_a_profiles','name':'app_a_access','roles':['anon'], 'cmd':'INSERT', 'restrictive':False, 'open':False,'auth_only':False,'check_open':False,'bucket_only':False,'user_metadata':False,'hash':'a'*12}]
        out = self.catalog(data)
        self.assert_no_hit(out, 'policy_open')
        self.assert_no_hit(out, 'policy_insert')
        data['policies'][0].update(open=True, check_open=True)
        self.assert_hit(self.catalog(data), 'INFO', 'policy_insert')

    def test_catalog_view_definer_storage(self):
        data = catalog_data()
        data['views'] = [{'target':'public.app_a_view','materialized':False,'invoker':False,'readable':True,'hash':'b'*12}]
        data['functions'] = [{'target':'public.app_a_func()','executable':True,'search_path':False,'hash':'c'*12}]
        data['buckets'] = [{'target':'app-a-images','public':True}]
        out = self.catalog(data)
        for kind in ('view_owner','definer_path','definer_execute','bucket_public'):
            self.assert_hit(out, 'WARN', kind)

    def probe(self, **env):
        self.sql('create table app_a_profiles(id uuid);')
        self.write('.env.local', f'NEXT_PUBLIC_SUPABASE_URL=https://{REF}.supabase.co\nNEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY={FAKE_KEY}\n')
        return self.scan(RH_SUPABASE_ANON_PROBE='1', **env)

    def test_probe_first_and_no_values(self):
        self.assert_hit(self.probe(), 'WARN', 'anon_readable')
        log = (self.root / 'cli-log').read_text()
        self.assertNotIn(FAKE_KEY, log)
        self.assertNotIn(ROW_VALUE, ''.join(p.read_text() for p in self.state.glob('*')))
        requests = [json.loads(l) for l in (self.root / 'requests.jsonl').read_text().splitlines()]
        self.assertTrue(requests[0]['public_key_ok'])
        self.assertTrue(requests[0]['url'].endswith('?select=*&limit=1'))

    def test_probe_newly_readable(self):
        self.probe(DG_READABLE='0')
        self.assert_hit(self.probe(RH_TODAY='2026-11-17'), 'FAIL', 'anon_readable')

    def test_probe_unchanged(self):
        self.probe()
        self.assert_no_hit(self.probe(RH_TODAY='2026-11-17'), 'anon_readable')

    def test_probe_serial_and_daily(self):
        self.sql('create table app_b_profiles(id uuid);', '002.sql')
        self.probe()
        self.probe()
        rows = [json.loads(l) for l in (self.root / 'requests.jsonl').read_text().splitlines()]
        self.assertEqual(len(rows), 2)
        self.assertGreaterEqual(rows[1]['time'] - rows[0]['time'], 0.95)

    def test_site_scan(self):
        out = self.scan(RH_SITE_URLS='https://example.invalid', DG_HTTP_MODE='site-bad')
        self.assert_hit(out, 'FAIL', 'site_sensitive_path')
        self.assert_hit(out, 'FAIL', 'site_service_key')
        self.assert_hit(out, 'WARN', 'site_sourcemap')
        self.assert_hit(out, 'INFO', 'site_headers')
        self.assertNotIn('sb_secret_fixturebrowserkey', out)

    def test_site_cache_and_serial(self):
        self.scan(RH_SITE_URLS='https://example.invalid', DG_HTTP_MODE='site-good')
        self.scan(RH_SITE_URLS='https://example.invalid', DG_HTTP_MODE='site-good')
        rows = [json.loads(l) for l in (self.root / 'requests.jsonl').read_text().splitlines()]
        self.assertEqual(len(rows), 5)
        for a, b in zip(rows, rows[1:]):
            self.assertGreaterEqual(b['time'] - a['time'], 0.95)

    def test_browser_env_role_not_allowable(self):
        self.write('.env.local', 'NEXT_PUBLIC_SERVICE_ROLE_KEY=' + FAKE_PASSWORD)
        (self.root / 'allow.tsv').write_text('browser_env\tapp-a:.env.local\t\t2026-12-01\tfixture\n')
        self.assert_hit(self.scan(), 'FAIL', 'browser_env')

    def test_browser_multiline_import(self):
        self.write('app/page.tsx', "'use client';\nimport {\n db\n} from '../lib/db.server';")
        self.write('lib/db.server.ts', 'const db=process.env.SUPABASE_SERVICE_ROLE_KEY;')
        self.assert_hit(self.scan(), 'FAIL', 'browser_service_key')

    def test_definer_overloads_not_overwritten(self):
        self.sql('create function app_a_func(input text) returns int language sql security definer as $$ select 1; $$; create function app_a_func(input uuid) returns int language sql security invoker as $$ select 1; $$;')
        self.assert_hit(self.scan(), 'WARN', 'definer_path')

    def test_definer_named_argument_revoke(self):
        self.sql('create function app_a_func(input text) returns int language sql security definer set search_path=public as $$ select 1; $$; revoke execute on function app_a_func(text) from public, anon;')
        self.assert_no_hit(self.scan(), 'definer_execute')

    def test_user_metadata(self):
        self.sql(self.open_sql(expr="auth.jwt()->'user_metadata'->>'role' = 'admin'"))
        self.assert_hit(self.scan(), 'WARN', 'user_metadata')

    def test_storage_bucket_policy(self):
        self.sql("create policy app_a_storage on storage.objects for SELECT to anon using(bucket_id='app-a-images');")
        self.assert_hit(self.scan(), 'WARN', 'storage_policy')

    def test_workspace_column(self):
        self.sql(self.open_sql().replace('org_id', 'workspace_id'))
        self.assert_hit(self.scan(), 'WARN', 'tenant_boundary')

    def test_tenant_correct_column(self):
        self.sql(self.open_sql(expr='org_id = auth.uid()'))
        self.assert_no_hit(self.scan(), 'tenant_boundary')

    def test_auth_service_route(self):
        self.write('app/api/form/route.ts', 'const db=process.env.SUPABASE_SERVICE_ROLE_KEY; export function GET() {}')
        self.assert_hit(self.scan(), 'WARN', 'api_service_auth')

    def test_history_timeout_unchecked(self):
        from unittest.mock import patch
        from contextlib import redirect_stdout
        import io
        guard = dg.Guard.__new__(dg.Guard)
        guard.state = self.state
        self.state.mkdir()
        output = io.StringIO()
        with patch.object(dg, 'git', side_effect=subprocess.TimeoutExpired('git', 20)), redirect_stdout(output):
            dg.history(dg.Repo(self.repo), guard)
        self.assert_hit(output.getvalue(), 'WARN', 'history_unchecked')
        self.assertEqual(list(self.state.iterdir()), [])

    def test_github_logged_out(self):
        out = self.scan(RH_DATA_GITHUB='1', DG_GH_AUTH_RC='1')
        self.assert_hit(out, 'NOTE', 'github_unchecked')
        line = self.line(out, 'github_unchecked')
        self.assertIn('gh にログインしていない', line)
        self.assertIn('未検査', line)
        logs = [json.loads(l) for l in (self.root / 'cli-log').read_text().splitlines()]
        self.assertFalse(any(l[0]=='gh' and l[1][0]=='api' for l in logs))

    def test_inline_missing_expiry(self):
        self.sql(self.open_sql().replace('create policy', '-- rh-allow: fixture\ncreate policy'))
        self.assert_hit(self.scan(), 'WARN', 'policy_open')

    def test_inline_expired(self):
        self.sql(self.open_sql().replace('create policy', '-- rh-allow: fixture until 2026-11-15\ncreate policy'))
        self.assert_hit(self.scan(), 'WARN', 'policy_open')

    def test_catalog_shared_authenticated(self):
        self.new_repo('app-b', REF)
        data = catalog_data()
        data['tables'][0]['rls'] = True
        data['policies'] = [{'target':'public.app_a_profiles','name':'app_a_access','roles':['authenticated'],'cmd':'SELECT','restrictive':False,'open':True,'auth_only':False,'check_open':True,'bucket_only':False,'user_metadata':False,'hash':'d'*12}]
        self.assert_hit(self.catalog(data), 'FAIL', 'policy_authenticated')

    def test_catalog_failure_gap_resets(self):
        self.catalog(DG_NO_KEY='1')
        self.catalog(DG_NO_KEY='1', RH_TODAY='2026-11-17')
        self.assert_hit(self.catalog(DG_NO_KEY='1', RH_TODAY='2026-11-20'), 'WARN', 'catalog_unchecked')

    def test_catalog_query_policy_fallback(self):
        self.catalog()
        query = (self.root / 'query.sql').read_text()
        self.assertIn("case when cmd='INSERT' then with_check else qual end", query)
        self.assertIn("coalesce(with_check,qual,'true')", query)
        self.assertNotIn('select * from', query.lower())

    def test_probe_failure_cached(self):
        self.probe(DG_PROBE_FAIL='1')
        out = self.probe(DG_PROBE_FAIL='1')
        self.assert_hit(out, 'WARN', 'probe_unchecked')
        self.assertEqual(len((self.root / 'requests.jsonl').read_text().splitlines()), 1)

    def test_probe_fallback_to_repo_with_key(self):
        self.write('supabase/.temp/project-ref', REF)
        self.sql('create table app_a_profiles(id uuid);')
        other = self.new_repo('app-b', REF)
        self.write('.env.local', f'NEXT_PUBLIC_SUPABASE_URL=https://{REF}.supabase.co\nNEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY={FAKE_KEY}\n', other)
        self.assert_hit(self.scan(RH_SUPABASE_ANON_PROBE='1'), 'WARN', 'anon_readable')

    def test_probe_does_not_mix_projects(self):
        other_ref = 'zyxwvutsrqponmlkjihg'
        self.new_repo('app-b', other_ref)
        other = self.root / 'repos/app-b'
        self.sql('create table app_b_profiles(id uuid);', repo=other)
        self.write('config.ts', f'const url="https://{other_ref}.supabase.co";')
        self.probe()
        rows = [json.loads(l) for l in (self.root / 'requests.jsonl').read_text().splitlines()]
        self.assertTrue(all('app_b_profiles' not in r['url'] for r in rows))

    def test_owner_registry_matching_prefix(self):
        self.sql('create table app_a_profiles(id uuid);')
        registry = self.root / 'apps.tsv'
        registry.write_text('app_a_\tapp-a\tfixture\n')
        self.assert_no_hit(self.scan(RH_SUPABASE_APPS=str(registry)), 'owner_unknown')

    def test_catalog_allow_expiry_reopens_unchanged(self):
        data = catalog_data()
        data['tables'][0]['rls'] = True
        data['views'] = [{'target':'public.app_a_view','materialized':False,'invoker':False,'readable':True,'hash':'b'*12}]
        (self.root / 'allow.tsv').write_text('view_owner\tpublic.app_a_view\tbbbbbbbbbbbb\t2026-11-16\tfixture\n')
        self.assert_hit(self.catalog(data), 'NOTE', 'view_owner')
        self.assert_hit(self.catalog(data, RH_TODAY='2026-11-17'), 'WARN', 'view_owner')

    def test_probe_allow_expiry_reopens_unchanged(self):
        (self.root / 'allow.tsv').write_text('anon_readable\tpublic.app_a_profiles\t\t2026-11-16\tfixture\n')
        self.assert_hit(self.probe(), 'NOTE', 'anon_readable')
        self.assert_hit(self.probe(RH_TODAY='2026-11-17'), 'WARN', 'anon_readable')

    def test_default_no_production_commands(self):
        self.scan()
        logs = [json.loads(l) for l in (self.root / 'cli-log').read_text().splitlines()]
        self.assertTrue(all(l[0] == 'git' for l in logs))


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(GuardTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(f'DG_TEST_COUNTS {result.testsRun} {len(result.failures)+len(result.errors)}')
    raise SystemExit(0 if result.wasSuccessful() else 1)
