# 2026-10-19 本番作業の仕上げ SQL（supabase/prod_2026-10-19_finish.sql）のテスト（PostgreSQL 17・15）
#   v1.12 の適用・pg_net の入れ直し・スイッチ off の確認・既存データが変わらないこと・中止の条件
#   ※ pg_net・pg_cron・Vault は同じ形の偽物で代用します（tests/db/README の「偽の拡張機能」を参照）
import subprocess, sys, os
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SQL = open(os.path.join(ROOT, "supabase/prod_2026-10-19_finish.sql"), encoding="utf-8").read()
RB = open(os.path.join(ROOT, "supabase/rollback/rollback_v1_12.sql"), encoding="utf-8").read()
PORTS = [int(p) for p in sys.argv[1:]] or [55417, 55415]
R = []
def ok(n, c, i=""): R.append(bool(c)); print(f"  [{'PASS' if c else 'FAIL'}] {n}  {str(i)[:160]}")
FP = """select md5(string_agg(x, '|' order by x)) from (
  select 't:' || t::text x from public.tracks t union all select 'e:' || e::text from public.play_events e
  union all select 'a:' || a::text from public.artists a union all select 'p:' || p::text from public.profiles p
  union all select 'f:' || f::text from public.follows f union all select 'l:' || l::text from public.playlists l
  union all select 'lt:' || l::text from public.playlist_tracks l union all select 'u:' || u.id::text from auth.users u
  union all select 's:' || s::text from aimuse_private.settings s) z"""
for port in PORTS:
    def q(sql, db="tpf"):
        r = subprocess.run(["psql", "-h", "/opt/pgx", "-p", str(port), "-U", "postgres", "-X", "-At", "-q", "-d", db, "-c", sql], capture_output=True, text=True)
        return r.stdout.strip(), next((l for l in r.stderr.splitlines() if "ERROR" in l), "")
    def fresh():
        q("drop database if exists tpf", "postgres"); q("create database tpf template prod111", "postgres")
        # 本番と同じ状態：purge_secret_matches だけ先に作成済み・pg_net は public・予定1件・金庫に合言葉
        mig = open(os.path.join(ROOT, "supabase/migration_v1_12_purge_play_events.sql"), encoding="utf-8").read()
        i = mig.index("create or replace function public.purge_secret_matches"); j = mig.rindex("commit;")
        q("begin;\n" + mig[i:j] + "commit;")
        o, e = q("""create schema if not exists extensions; create extension pg_net;
create schema vault; create table vault.secrets (name text); create table vault.decrypted_secrets (name text, decrypted_secret text, created_at timestamptz default now());
insert into vault.secrets values ('aimuse_purge_secret'); insert into vault.decrypted_secrets (name, decrypted_secret) values ('aimuse_purge_secret', repeat('k', 64));
create schema cron; create table cron.job (jobname text, active boolean, command text);
insert into cron.job values ('aimuse-account-purge', true, 'select net.http_post(url := ''/functions/v1/account-purge'')');""")
        return e
    print("== port", port, q("show server_version", "postgres")[0])
    ok("準備（本番と同じ状態）", not fresh())
    before = q(FP)[0]
    ok("準備：pg_net は public・v1.12 は未適用", q("select extnamespace::regnamespace::text from pg_extension where extname='pg_net'")[0] == "public"
       and q("select position('play_events' in prosrc) from pg_proc where proname='account_purge_db'")[0] == "0")
    o, e = q(SQL); ok("実行できる", not e, e)
    ok("結果の5項目がすべて true", o == "t|t|t|t|t", o)
    ok("v1.12：その会員が聴いた再生記録を消す1行が入る", q("select position('play_events' in prosrc) > 0 from pg_proc where proname='account_purge_db'")[0] == "t")
    acl = q("select has_function_privilege('service_role','public.account_purge_db(uuid,uuid)','execute')::text || has_function_privilege('authenticated','public.account_purge_db(uuid,uuid)','execute')::text || has_function_privilege('anon','public.account_purge_db(uuid,uuid)','execute')::text")[0]
    ok("完全削除の関数は service_role だけ", acl == "truefalsefalse", acl)
    ok("pg_net は extensions に移る・送信の関数も使える", q("select extnamespace::regnamespace::text from pg_extension where extname='pg_net'")[0] == "extensions"
       and q("select to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is not null")[0] == "t")
    ok("毎日の予定と金庫の合言葉はそのまま", q("select (select count(*) from cron.job) || '|' || (select count(*) from vault.decrypted_secrets)")[0] == "1|1")
    ok("既存データ（会員・曲・再生数・再生記録・フォロー・プレイリスト・設定）が1文字も変わらない", q(FP)[0] == before)
    o, e = q(SQL); ok("2回目の実行も成功・結果は同じ", not e and o == "t|t|t|t|t", o or e)
    ok("2回目のあとも既存データは同じ", q(FP)[0] == before)
    # 中止の条件
    fresh(); q("select net.http_post(url := 'x', headers := '{}'::jsonb)")
    h0 = q("select md5(prosrc) from pg_proc where proname='account_purge_db'")[0]
    o, e = q(SQL); ok("送信待ちがあれば中止し、v1.12 も含めて何も変えない", "送信待ち" in e and q("select md5(prosrc) from pg_proc where proname='account_purge_db'")[0] == h0
       and q("select extnamespace::regnamespace::text from pg_extension where extname='pg_net'")[0] == "public", e)
    fresh(); q("update aimuse_private.settings set value='testers' where key='account_deletion_mode'")
    o, e = q(SQL); ok("受付のスイッチが off でなければ中止し、何も変えない", "off ではありません" in e and q("select md5(prosrc) from pg_proc where proname='account_purge_db'")[0] == h0
       and q("select extnamespace::regnamespace::text from pg_extension where extname='pg_net'")[0] == "public", e)
    fresh(); q("update aimuse_private.settings set value='on' where key='account_purge_enabled'")
    o, e = q(SQL); ok("完全削除のスイッチが off でなければ中止", "off ではありません" in e, e)
    # 元に戻す
    fresh(); q(SQL); o, e = q(RB)
    ok("元に戻せる（v1.9 r4 の関数に戻る）", not e and q("select position('play_events' in prosrc) from pg_proc where proname='account_purge_db'")[0] == "0", e)
    q("drop database if exists tpf", "postgres")
print(f"合計 {len(R)} 件 / 不合格 {R.count(False)} 件")
sys.exit(1 if False in R else 0)
