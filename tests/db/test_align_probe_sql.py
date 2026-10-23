# 検証用の準備・片付けの SQL（supabase/align_probe/setup.sql・teardown.sql）のテスト
# 本番と同じく service_role に表の直接の読み取り権限が無い状態・Supabase と同じ「新しい関数は誰でも実行できる」既定の権限で確かめる
# 使い方：python3 tests/db/test_align_probe_sql.py [ポート...]（既定：PostgreSQL 17 = 55417、15 = 55415。テンプレート prod111）
import subprocess, sys, os
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SETUP = open(os.path.join(ROOT, "supabase/align_probe/setup.sql"), encoding="utf-8").read()
TEAR = open(os.path.join(ROOT, "supabase/align_probe/teardown.sql"), encoding="utf-8").read()
PORTS = [int(p) for p in sys.argv[1:]] or [55417, 55415]
OBORO = "8ff6cf08-3d73-40b7-8dbc-4b09bac917cc"
R = []
def ok(n, c, i=""): R.append(bool(c)); print(f"  [{'PASS' if c else 'FAIL'}] {n}  {str(i)[:160]}")
VAULT = """create schema if not exists extensions; create extension if not exists pgcrypto schema extensions;
create schema if not exists vault;
create table if not exists vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text, description text, created_at timestamptz default now());
create or replace view vault.decrypted_secrets as select id, name, secret as decrypted_secret, created_at from vault.secrets;
create or replace function vault.create_secret(s text, n text, d text) returns uuid language sql as $$ insert into vault.secrets(name, secret, description) values (n, s, d) returning id $$;
revoke all on schema vault from public;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
revoke select, insert, update, delete on all tables in schema public from service_role;"""
GR = """select md5(string_agg(x, '|' order by x)) from (
  select table_schema||'.'||table_name||':'||grantee||':'||privilege_type x from information_schema.role_table_grants where table_schema in ('public','storage')
  union all select 'pol:'||polrelid::regclass::text||':'||polname::text||':'||coalesce(pg_get_expr(polqual, polrelid), '')||':'||coalesce(pg_get_expr(polwithcheck, polrelid), '')||polroles::text from pg_policy
  union all select 'rls:'||oid::regclass::text||relrowsecurity::text||relforcerowsecurity::text from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r') s"""
DATA = "select md5(string_agg(t::text, '|' order by t.id)) from public.tracks t"
for port in PORTS:
    def q(sql, role=None, db="tap"):
        if role: sql = f"begin; set local role {role};\n{sql};\ncommit;"
        r = subprocess.run(["psql", "-h", "/opt/pgx", "-p", str(port), "-U", "postgres", "-X", "-At", "-q", "-d", db, "-c", sql], capture_output=True, text=True)
        return r.stdout.strip(), next((l for l in r.stderr.splitlines() if "ERROR" in l), "")
    print("== port", port, q("show server_version", db="postgres")[0])
    q("drop database if exists tap", db="postgres"); q("create database tap template prod111", db="postgres")
    o, e = q(VAULT); assert not e, e
    a, b = q("select id from public.tracks where status = 'public' order by id limit 2")[0].split("\n")
    p = q("select id from public.tracks where status <> 'public' limit 1")[0]
    # 検証対象の曲（公開中・歌詞あり）を、既存の公開中の曲を写して作る
    o, e = q(f"insert into public.tracks select (jsonb_populate_record(null::public.tracks, to_jsonb(t) || jsonb_build_object('id', '{OBORO}', 'lyrics', array['[Verse 1]', 'あの夜は'], 'audio_sha256', null, 'audio_path', 'probe/oboro.mp3'))).* from public.tracks t where t.id = '{a}'"); assert not e, e
    g0, d0 = q(GR)[0], q(DATA)[0]
    o, e = q(SETUP.replace("\n", "\r\n")); ok("1 適用できる（本番と同じ CRLF の形）", not e and o.endswith("1|f"), (o[-20:], e))
    o, e = q(SETUP); ok("1 2回目の適用も成功（合言葉は1つのまま）", not e and o.endswith("1|f"), (o[-20:], e))
    ok("1 表の権限・RLS のルール・RLS の設定は変わらない", q(GR)[0] == g0)
    ok("1 曲のデータは変わらない", q(DATA)[0] == d0)
    info = q("select string_agg(proname||':'||prosecdef::text||':'||array_to_string(proconfig, ',')||':'||provolatile::text||':'||pg_get_userbyid(proowner), ' ' order by proname) from pg_proc where pronamespace = 'public'::regnamespace and proname::text like 'align_probe%'")[0]
    ok("2 3つとも SECURITY DEFINER・search_path が空・読み取りだけ（stable）・所有者 postgres", info.count(":true:search_path=\"\":s:postgres") == 3, info)
    acl = q("select string_agg(r||'='||has_function_privilege(r, f, 'execute')::text, ' ' order by f, r) from unnest(array['anon','authenticated','service_role','public']) r, unnest(array['public.align_probe_secret_matches(text)','public.align_probe_track(uuid)','public.align_probe_is_admin(uuid)']) f where r <> 'public'")[0]
    ok("2 未ログイン・会員は3つとも実行できず、service_role だけが実行できる", acl.count("anon=false") == 3 and acl.count("authenticated=false") == 3 and acl.count("service_role=true") == 3, acl)
    for role in ["anon", "authenticated"]:
        o, e = q(f"select * from public.align_probe_track('{OBORO}')", role); o2, e2 = q("select public.align_probe_is_admin(gen_random_uuid())", role); o3, e3 = q("select public.align_probe_secret_matches(repeat('a', 64))", role)
        ok(f"2 {role} が直接呼ぶと拒否される（3つとも）", all("permission denied" in x for x in (e, e2, e3)), (e[:40], e2[:40], e3[:40]))
    o, e = q("select count(*) from public.tracks", "service_role"); ok("3 本番と同じく service_role は表を直接読めない", "permission denied" in e, e[:50])
    o, e = q(f"select title is not null, array_length(lyrics, 1) > 0, audio_path is not null from public.align_probe_track('{OBORO}')", "service_role")
    ok("3 検証対象の曲（公開中）は読める", o == "t|t|t", (o, e))
    o, e = q(f"select count(*) from public.align_probe_track('{b}')", "service_role"); ok("3 ほかの公開中の曲は何も返らない", o == "0", (o, e))
    o, e = q(f"select count(*) from public.align_probe_track('{p}')" if p else "select 0", "service_role"); ok("3 公開中でない曲も何も返らない", o == "0", (o, e))
    q(f"update public.tracks set status = 'pending' where id = '{OBORO}'")
    o, e = q(f"select count(*) from public.align_probe_track('{OBORO}')", "service_role"); ok("3 検証対象の曲でも公開中でなくなれば返らない", o == "0", (o, e))
    q(f"update public.tracks set status = 'public' where id = '{OBORO}'")
    o = q("select pg_get_function_result('public.align_probe_track(uuid)'::regprocedure)")[0]
    ok("3 返す列は曲名・歌詞・保存場所・長さだけ（投稿者・会員の情報は含まない）", o == "TABLE(id uuid, title text, lyrics text[], audio_path text, duration integer)", o)
    adm = q("select id from public.profiles where is_admin and not is_banned limit 1")[0]; mem = q("select id from public.profiles where not is_admin limit 1")[0]
    o, e = q(f"select public.align_probe_is_admin('{adm}')::text||public.align_probe_is_admin('{mem}')::text||public.align_probe_is_admin(gen_random_uuid())::text||public.align_probe_is_admin(null)::text", "service_role")
    ok("3 管理者か：管理者 true・会員 false・存在しない ID false・空 false（true/false だけ）", o == "truefalsefalsefalse", (o, e))
    q(f"update public.profiles set is_banned = true where id = '{adm}'")
    o, e = q(f"select public.align_probe_is_admin('{adm}')", "service_role"); ok("3 利用停止中の管理者は false", o == "f", (o, e))
    o = q("select pg_get_function_result('public.align_probe_is_admin(uuid)'::regprocedure)")[0]; ok("3 管理者の確認は true/false だけを返す（名前・メールは返さない）", o == "boolean", o)
    q(f"update public.profiles set is_banned = false where id = '{adm}'")
    o, e = q(TEAR); ok("5 片付けで関数3つと合言葉が消える", not e and o.endswith("0") and q("select count(*) from vault.secrets where name = 'aimuse_align_probe_secret'")[0] == "0", (o, e))
    o, e = q(TEAR); ok("5 片付けは2回実行しても成功", not e, e)
    ok("5 片付けの後も、表の権限・RLS・曲のデータは元のまま", q(GR)[0] == g0 and q(DATA)[0] == d0)
    q("drop database if exists tap", db="postgres")
print(f"\n合計 {len(R)} 件 / 不合格 {R.count(False)} 件"); sys.exit(1 if False in R else 0)
