# v1.12（退会の完全削除で、その会員が聴いた再生記録も消す・合言葉の照合）のテスト
# 使い方：python3 tests/db/test_v112.py [ポート...]   （既定：PostgreSQL 17 = 55417、15 = 55415。テンプレート prod111 = v1.11 まで適用済み）
import subprocess, json, sys, os
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MIG = open(os.path.join(ROOT, "supabase/migration_v1_12_purge_play_events.sql"), encoding="utf-8").read()
RB = open(os.path.join(ROOT, "supabase/rollback/rollback_v1_12.sql"), encoding="utf-8").read()
PORTS = [int(p) for p in sys.argv[1:]] or [55417, 55415]
U = "71000000-0000-4000-8000-000000000001"     # 退会する会員
O = "10000000-0000-4000-8000-000000000003"     # 他の会員（曲の持ち主）
R = []
def ok(n, c, i=""): R.append(c); print(f"  [{'PASS' if c else 'FAIL'}] {n}  {str(i)[:160]}")
for port in PORTS:
    def q(sql, db="t112", role=None):
        if role:
            sql = f"begin; set local role {role}; set local request.jwt.claims = '{json.dumps({'role': role})}';\n{sql};\ncommit;"
        r = subprocess.run(["psql", "-h", "/opt/pgx", "-p", str(port), "-U", "postgres", "-X", "-At", "-q", "-d", db, "-c", sql], capture_output=True, text=True)
        return r.stdout.strip(), next((l for l in r.stderr.splitlines() if "ERROR" in l), "")
    print("== port", port, q("show server_version", "postgres")[0])
    q("drop database if exists t112", "postgres"); q("create database t112 template prod111", "postgres")
    src = q("select md5(prosrc) from pg_proc where proname='account_purge_db'")[0]
    o, e = q(MIG); ok("適用できる", not e, e)
    o, e = q(MIG); ok("2回目の適用も成功（何度実行しても同じ）", not e, e)
    acl = q("select has_function_privilege('service_role','public.account_purge_db(uuid,uuid)','execute')::text || has_function_privilege('authenticated','public.account_purge_db(uuid,uuid)','execute')::text || has_function_privilege('anon','public.account_purge_db(uuid,uuid)','execute')::text")[0]
    ok("権限は変わらない（service_role だけ実行できる）", acl == "truefalsefalse", acl)
    s = q("select value from aimuse_private.settings where key in ('account_deletion_mode','account_purge_enabled') order by key")[0]
    ok("退会の受付・完全削除のスイッチは off のまま", s.split() == ["off", "off"], s)
    # 準備：退会する会員 U、他の会員 O の曲を U が聴いた記録、他の人の記録
    o, e = q(f"""insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values ('{U}', 'u@example.com', now(), '{{"display_name":"退会テスト"}}');
insert into public.artists (user_id, name) values ('{U}', '退会テスト');
insert into public.play_events (track_id, viewer_key, window_start)
  select id, 'u:{U}', date_trunc('hour', now()) from public.tracks where user_id = '{O}' and status = 'public' order by id limit 3;
insert into public.play_events (track_id, viewer_key, window_start)
  select id, k, date_trunc('hour', now()) from (select id from public.tracks where user_id = '{O}' and status = 'public' order by id limit 3) t,
  (values ('u:{O}'), ('ip:abc')) v(k);
update aimuse_private.settings set value = 'all' where key = 'account_deletion_mode';
update aimuse_private.settings set value = 'on' where key = 'account_purge_enabled';""")
    ok("準備", not e, e)
    before = q(f"""select md5(string_agg(x, '|' order by x)) from (
      select 'p:' || e::text x from public.play_events e where viewer_key <> 'u:{U}'
      union all select 't:' || t::text from public.tracks t) s""")[0]
    o, e = q(f"select status from public.account_request_deletion('{U}')", role="service_role"); ok("退会の申請（service_role）", o == "pending", o or e)
    q(f"update aimuse_private.account_deletions set purge_after = now() - interval '1 minute' where user_id = '{U}'")
    o, e = q("select request_id || ',' || lock_token from public.account_purge_claim()", role="service_role")
    req, tok = (o.split(",") + [""])[:2] if o else ("", "")
    ok("完全削除の対象を取り出せる", bool(req), o or e)
    o, e = q(f"select public.account_purge_mark_files('{req}', '{tok}')", role="service_role"); ok("ファイルの手順（ファイルなし）", not e, o or e)
    o, e = q(f"select public.account_purge_db('{req}', '{tok}')", role="service_role"); ok("データの削除の手順", not e, e)
    n = q(f"select count(*) from public.play_events where viewer_key = 'u:{U}'")[0]
    ok("その会員が聴いた再生記録が0件になる（v1.12 の追加分）", n == "0", n)
    after = q(f"""select md5(string_agg(x, '|' order by x)) from (
      select 'p:' || e::text x from public.play_events e where viewer_key <> 'u:{U}'
      union all select 't:' || t::text from public.tracks t) s""")[0]
    ok("他の人の再生記録・全曲（再生数 plays を含む）は1文字も変わらない", after == before)
    o, e = q(f"delete from auth.users where id = '{U}'")   # Edge Function の auth.admin.deleteUser の代わり
    o, e = q(f"select public.account_purge_finish('{req}', '{tok}')", role="service_role"); ok("完了の記録", not e, e)
    st = q(f"select status from aimuse_private.account_deletions where id = '{req}'")[0]; ok("状態が done", st == "done", st)
    # 権限：アプリ（authenticated・anon）からは呼べない
    o, e = q(f"select public.account_purge_db(gen_random_uuid(), gen_random_uuid())", role="authenticated")
    ok("会員（authenticated）からは実行できない", "permission denied" in e, e)
    # 合言葉の照合（Vault の代わりに同じ形の表を用意）
    SEC = "s" * 64
    q("create schema if not exists vault; create table if not exists vault.decrypted_secrets (name text, decrypted_secret text, created_at timestamptz default now()); revoke all on schema vault from public, anon, authenticated;")
    o, e = q("select public.purge_secret_matches('" + SEC + "')", role="service_role"); ok("金庫に合言葉が無ければ false", o == "f", o or e)
    q(f"insert into vault.decrypted_secrets (name, decrypted_secret) values ('aimuse_purge_secret', '{SEC}')")
    o, e = q("select public.purge_secret_matches('" + SEC + "')", role="service_role"); ok("一致すれば true（service_role）", o == "t", o or e)
    o, e = q("select public.purge_secret_matches('" + "s" * 63 + "x')", role="service_role"); ok("1文字でも違えば false", o == "f", o or e)
    o, e = q("select public.purge_secret_matches('short')", role="service_role"); ok("32文字未満は false", o == "f", o or e)
    o, e = q("select public.purge_secret_matches(null)", role="service_role"); ok("空は false", o == "f", o or e)
    o, e = q("select public.purge_secret_matches('" + SEC + "')", role="authenticated"); ok("会員（authenticated）は実行できない", "permission denied" in e, e)
    o, e = q("select public.purge_secret_matches('" + SEC + "')", role="anon"); ok("未ログイン（anon）は実行できない", "permission denied" in e, e)
    rt = q("select pg_get_function_result('public.purge_secret_matches(text)'::regprocedure)")[0]
    ok("戻り値は true/false だけ（合言葉は返さない）", rt == "boolean", rt)
    # 元に戻す → 再適用
    o, e = q(RB); ok("元に戻せる", not e, e)
    ok("元に戻すと v1.9 r4 の関数と同じ中身", q("select md5(prosrc) from pg_proc where proname='account_purge_db'")[0] == src)
    ok("元に戻すと照合の関数も無くなる", q("select to_regprocedure('public.purge_secret_matches(text)') is null")[0] == "t")
    o, e = q(MIG); ok("再適用できる", not e, e)
    # 前提が無い場合は何も変更せずに中止
    q("drop database if exists t112b", "postgres"); q("create database t112b template prod111", "postgres")
    q("drop table public.playlist_tracks; drop table public.playlists;", "t112b")
    h0 = q("select md5(prosrc) from pg_proc where proname='account_purge_db'", "t112b")[0]
    o, e = q(MIG, "t112b"); ok("v1.11 が無ければ中止し、何も変えない", "v1.11" in e and q("select md5(prosrc) from pg_proc where proname='account_purge_db'", "t112b")[0] == h0, e)
    q("drop database if exists t112", "postgres"); q("drop database if exists t112b", "postgres")
print(f"合計 {len(R)} 件 / 不合格 {R.count(False)} 件")
sys.exit(1 if False in R else 0)
