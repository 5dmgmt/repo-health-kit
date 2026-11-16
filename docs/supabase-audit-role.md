# Supabase の監査専用接続を設定する

この機能は既定でオフです。利用者が専用の役割とキーチェーンを用意し、設定を有効にすると、本番の目録を読み取ります。アプリの行データを取得する SQL は実行しません。DB の設定変更はこの点検ツールでは行いません。

## 1. 専用の役割を作る

管理者が SQL Editor で、次の SQL を確認して実行します。`data_guard_audit` は監査用の架空の役割名です。アプリの役割に所属させず、アプリの表への権限を与えません。

```sql
create role data_guard_audit login noinherit nosuperuser nocreatedb
  nocreaterole noreplication nobypassrls connection limit 2;
alter role data_guard_audit set default_transaction_read_only = on;
alter role data_guard_audit set statement_timeout = '20s';
grant usage on schema storage to data_guard_audit;
grant select (id, name, public) on storage.buckets to data_guard_audit;
```

パスワードは管理者の安全な対話操作で設定します。`psql` を使う場合は `\password data_guard_audit` で対話入力します。SQL やシェル履歴、設定ファイルに値を書かないでください。

`NOINHERIT` でも `PUBLIC` に与えられた権限は受けます。管理者が次の照会で、監査役割がアプリの表を読めないことを確認してください。結果があれば、共有の `PUBLIC` 権限を含めた権限設計を確認してから有効にします。ツールは権限を自動で変更しません。

```sql
select n.nspname, c.relname
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r', 'p')
  and n.nspname not in ('pg_catalog', 'information_schema', 'storage')
  and n.nspname not like 'pg_toast%'
  and has_table_privilege('data_guard_audit', c.oid,
                         'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER');
```

既定で `PUBLIC` に実行権限のある `SECURITY DEFINER` 関数も確認してください。読み取り専用の指定は、関数が行を返すことまで防ぎません。業務データを返す関数への `PUBLIC` の権限がある場合も、運用を始める前に権限設計を確認します。

`storage.buckets` に RLS がある構成では、列の SELECT 権限だけではバケット一覧が見えないことがあります。管理者が一覧の件数を照合し、必要な監査用方針を設計してください。アプリの行を読める権限や `BYPASSRLS` を代わりに付けないでください。

## 2. キーチェーンに入れる

利用者本人が、点検を実行する Mac のターミナルで次を実行します。`<ref>` は公開 URL のプロジェクト識別子に置き換えます。接続文字列はコマンドの引数に続けず、`-w` の対話で入力します。

```sh
security add-generic-password -U -s repo-health-kit-supabase-audit -a '<ref>' -w
```

対話で入力する中身は、監査専用の役割による `postgresql://` 接続文字列です。接続先・ポート・DB 名は利用者の構成を確認します。パスワード内の記号は URL エンコードします。プーラーを使う場合は独自の役割で接続できるか、先に利用者が確かめてください。

接続文字列を画面に出すコマンドを実行しないでください。点検はキーチェーンからメモリへ読み、`PGHOST`・`PGPORT`・`PGUSER`・`PGPASSWORD`・`PGDATABASE` に分けて子プロセスに渡します。`PGSSLMODE=require`、接続待ちは10秒、SQL は20秒に制限します。`psql -X` を使い、個人の起動スクリプトを読みません。

## 3. 点検を有効にする

`~/.config/repo-health-kit/config.sh` に次を設定します。鍵の値は書きません。

```sh
RH_SUPABASE_CATALOG=1
RH_SUPABASE_CATALOG_REFS='<ref>'
RH_SUPABASE_CATALOG_KEYCHAIN='repo-health-kit-supabase-audit'
```

複数の ref は半角スペースで区切ります。サービス名を変えた場合は、キーチェーン側と設定を合わせます。`psql` 不在・鍵なし・接続失敗は WARN「未検査」、3日連続で FAIL に上がります。表の件数の番兵が欠ける・0件の場合も FAIL です。

目録は1回の SELECT で読みます。対象は RLS、方針、公開ロールの表・関数への権限、VIEW、DEFINER、Storage、Realtime、PostgREST の公開スキーマです。方針や関数本体は DB 側でハッシュにし、本文を返しません。PostgREST の公開スキーマ設定を目録から特定できない構成では `public` を使います。API 側の追加設定は手作業で確認してください。

結果の名前・分類・ハッシュを状態ディレクトリに権限600で保存します。同じ日の再実行では、その日の最初の比較基準を維持します。翌日以降は前回の結果と比べ、新しい指摘を報告し、変わらない指摘は種類ごとの件数にします。静的定義との RLS の食い違いは毎回 FAIL にします。実測の結果も安全性全体の合格を意味しません。

## 4. 無効化と削除

設定を `RH_SUPABASE_CATALOG=0` に戻します。利用者がキーチェーンの専用項目を削除します。

```sh
security delete-generic-password -s repo-health-kit-supabase-audit -a '<ref>'
```

役割も廃止する場合、管理者が依存する権限や方針を確認してから専用役割を削除します。共有の役割・アプリの権限を一括で削除しないでください。
