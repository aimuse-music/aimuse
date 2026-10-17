#!/usr/bin/env python3
"""v1.11 プレイリストの検証（PostgreSQL 17。v1.10 まで適用済み・本番に近いデータ・BOOST 入りの DB をコピーして使う）
使い方: python3 tests/db/test_v111.py [テンプレートDB名（既定 finalchk）]"""
import subprocess, json, sys, threading
TPL = sys.argv[1] if len(sys.argv) > 1 else "finalchk"
DB = "v111t"
BASE = ["psql", "-h", "/opt/pgx", "-p", "55417", "-U", "postgres", "-X", "-At", "-q"]
M = "/home/claude/aimuse/supabase/"
def psql(db, s, single=False):
    cmd = BASE + ["-d", db] + (["-c", s] if single else [])
    p = subprocess.run(cmd, input=None if single else s, capture_output=True, text=True)
    return p.stdout.strip(), " ".join(l for l in p.stderr.splitlines() if "ERROR" in l)
U = {k: "10000000-0000-4000-8000-%012d" % i for k, i in [("admin", 1), ("a", 2), ("b", 3), ("unconf", 17), ("banned", 50), ("w", 4)]}
def run(who, sql):
    if who == "postgres": return psql(DB, sql)
    if who == "anon": role, c = "anon", {"role": "anon"}
    else: role, c = "authenticated", {"sub": U[who], "role": "authenticated"}
    return psql(DB, f"begin;\nset local role {role};\nset local request.jwt.claims='{json.dumps(c)}';\n{sql};\ncommit;")
sq = lambda s: psql(DB, s)[0]
R = []
def ok(n, c, i=None): R.append((n, bool(c))); print(f"[{'PASS' if c else 'FAIL'}] {n}" + (f"  → {i}" if i is not None else ""))
SNAP = """select md5(string_agg(x, E'\\n' order by x)) from (
  select 'fn:'||n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'||md5(p.prosrc)||p.prosecdef x from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','aimuse_private','storage')
  union all select 'col:'||table_schema||'.'||table_name||'.'||column_name from information_schema.columns where table_schema in ('public','aimuse_private','storage')
  union all select 'pol:'||schemaname||'.'||tablename||'.'||policyname||coalesce(qual,'')||coalesce(with_check,'') from pg_policies
  union all select 'grant:'||table_schema||'.'||table_name||':'||grantee||':'||privilege_type from information_schema.role_table_grants where grantee in ('anon','authenticated')
  union all select 'fngrant:'||routine_name||':'||grantee from information_schema.role_routine_grants where grantee in ('anon','authenticated') and routine_schema='public') s"""
DATA = """select md5(string_agg(x, '|' order by x)) from (select 't'||t::text x from public.tracks t union all select 'p'||t::text from public.profiles t
  union all select 'f'||t::text from public.favorites t union all select 'w'||t::text from public.follows t union all select 'r'||t::text from public.reviews t
  union all select 'a'||t::text from public.artists t union all select 'o'||t::text from storage.objects t) s"""

psql("postgres", f"drop database if exists {DB}"); psql("postgres", f"create database {DB} template {TPL}")
s0, d0 = sq(SNAP), sq(DATA)
SQL = open(M + "migration_v1_11_playlists.sql", encoding="utf-8").read()
o, e = psql(DB, SQL.replace("\n", "\r\n"), single=True); ok("1 v1.11 を本番と同じ形（1回のクエリ・CRLF）で適用できる", not e, e[:120])
o, e = psql(DB, SQL, single=True); ok("1 2回実行しても壊れない", not e, e[:120])
ok("1 既存データ（曲・プロフィール・お気に入り・フォロー・レビュー・アーティスト・ファイル）は変わらない", sq(DATA) == d0)
chk = [l.split("|") for l in psql(DB, open(M + "production_checks.sql", encoding="utf-8").read().replace("\n", " \n"))[0].splitlines()]
ok("1 既存の本番確認29項目はすべて OK のまま", len(chk) == 29 and all(r[2] == "OK" for r in chk), [r[:3] for r in chk if r[2] != "OK"])

PUB = sq("select string_agg(id::text, ',' order by id) from (select id from public.tracks where status='public' order by id limit 210) s").split(",")
HID = sq("select id from public.tracks where status='hidden' limit 1")
# 2. 権限
o, e = run("anon", "select * from public.my_playlists()"); o2, e2 = run("anon", "select public.create_playlist('x')")
ok("2 未ログインは自分の一覧・作成ができない", "permission denied" in e and "permission denied" in e2, (e[:40], e2[:40]))
o, e = run("anon", "select count(*) from public.public_playlists()"); ok("2 未ログインでも公開プレイリストは見られる", not e and o == "0", (o, e[:60]))
for who in ["anon", "a"]:
    o, e = run(who, "select count(*) from public.playlists"); o2, e2 = run(who, "insert into public.playlist_tracks (playlist_id, track_id, position) values (gen_random_uuid(), gen_random_uuid(), 1)")
    ok(f"2 {who}: 表を直接読む・書くことはできない（関数経由のみ）", "permission denied" in e and "permission denied" in e2, (e[:40], e2[:40]))
# 3. 作成・名前
o, e = run("a", "select public.create_playlist('  ドライブ   用  ')"); PA = o.splitlines()[-1] if o else ""
ok("3 作成でき、名前の余分な空白は整える", not e and sq(f"select name from public.playlists where id='{PA}'") == "ドライブ 用", (o, e[:60]))
for bad, msg in [("''", "1〜40文字"), ("repeat('あ',41)", "1〜40文字"), ("'a'||chr(8203)||'b'", "使用できない文字")]:
    o, e = run("a", f"select public.create_playlist({bad})"); ok(f"3 不正な名前は作れない（{msg}）", msg in e, e[:60])
for who in ["unconf", "banned"]:
    o, e = run(who, "select public.create_playlist('x')"); ok(f"3 {who}（メール未確認・利用停止）は作成できない", "作成できません" in e, e[:50])
# 4. 曲の追加・削除
o, e = run("a", f"select public.playlist_add_track('{PA}','{PUB[0]}'); select public.playlist_add_track('{PA}','{PUB[1]}'); select public.playlist_add_track('{PA}','{PUB[0]}')")
ids = run("a", "select array_to_string(track_ids, ',') from public.my_playlists()")[0]
ok("4 公開中の曲を追加でき、同じ曲の重複は無視・追加順に並ぶ", not e and ids == f"{PUB[0]},{PUB[1]}", (ids, e[:60]))
o, e = run("a", f"select public.playlist_add_track('{PA}','{HID}')"); ok("4 非公開の曲は追加できない", "公開中の曲だけ" in e, e[:40])
o, e = run("a", f"select public.playlist_remove_track('{PA}','{PUB[0]}')"); ids = run("a", "select array_to_string(track_ids, ',') from public.my_playlists()")[0]
ok("4 曲を外せる", not e and ids == PUB[1], ids)
# 5. 他人のプレイリスト
for sql, lbl in [(f"select public.update_playlist('{PA}','乗っ取り',true)", "変更"), (f"select public.delete_playlist('{PA}')", "削除"), (f"select public.playlist_add_track('{PA}','{PUB[2]}')", "曲の追加"), (f"select public.playlist_remove_track('{PA}','{PUB[1]}')", "曲の削除")]:
    o, e = run("b", sql); ok(f"5 他の会員のプレイリストは{lbl}できない", "見つかりません" in e, e[:40])
ok("5 B の一覧に A の非公開プレイリストは出ない", run("b", "select count(*) from public.my_playlists()")[0] == "0")
ok("5 A のプレイリストは無傷", sq(f"select name||'/'||is_public||'/'||(select count(*) from public.playlist_tracks where playlist_id='{PA}') from public.playlists where id='{PA}'") == "ドライブ 用/false/1")
# 6. 公開設定
ok("6 非公開のうちは公開一覧に出ない", run("anon", "select count(*) from public.public_playlists()")[0] == "0")
o, e = run("a", f"select public.update_playlist('{PA}', null, true)")
row = run("anon", "select row_to_json(x) from public.public_playlists() x")[0]
ok("6 公開にすると未ログインでも見え、会員IDは返さない", not e and PA in row and U["a"] not in row and "user_id" not in row, row[:90])
sq(f"update public.tracks set status='hidden' where id='{PUB[1]}'")
ok("6 曲が非公開になると公開一覧から外れる（公開中の曲が0件なら一覧自体に出ない）", run("anon", "select count(*) from public.public_playlists()")[0] == "0")
sq(f"update public.tracks set status='public' where id='{PUB[1]}'")
sq(f"update public.profiles set is_banned=true where id='{U['a']}'"); n1 = run("anon", "select count(*) from public.public_playlists()")[0]
sq(f"update public.profiles set is_banned=false where id='{U['a']}'")
ok("6 持ち主が利用停止なら公開一覧に出ない", n1 == "0", n1)
sq(f"insert into aimuse_private.account_deletions (user_id, purge_after) values ('{U['a']}', now()+interval '30 days')"); n2 = run("anon", "select count(*) from public.public_playlists()")[0]
o, e = run("a", f"select public.playlist_add_track('{PA}','{PUB[3]}')")
sq(f"delete from aimuse_private.account_deletions where user_id='{U['a']}'")
ok("6 退会手続き中は公開一覧に出ず、書き込みもできない", n2 == "0" and "変更できません" in e, (n2, e[:40]))
o, e = run("a", f"select public.update_playlist('{PA}', '新しい名前', false)")
ok("6 名前の変更・非公開に戻せる", not e and sq(f"select name||'/'||is_public from public.playlists where id='{PA}'") == "新しい名前/false" and run("anon", "select count(*) from public.public_playlists()")[0] == "0")
# 7. 上限
sq(f"insert into public.playlists (user_id, name) select '{U['b']}', 'p'||i from generate_series(1,45) i")
outs = []
def mk(): outs.append(run("b", "select public.create_playlist('同時')"))
th = [threading.Thread(target=mk) for _ in range(10)]; [t.start() for t in th]; [t.join() for t in th]
ok("7 1人50個まで（10件同時に作っても50個を超えない）", sq(f"select count(*) from public.playlists where user_id='{U['b']}'") == "50" and sum("50個まで" in e for _, e in outs) == 5, sq(f"select count(*) from public.playlists where user_id='{U['b']}'"))
PB = sq(f"select id from public.playlists where user_id='{U['b']}' limit 1")
sq(f"insert into public.playlist_tracks (playlist_id, track_id, position) select '{PB}', id::uuid, row_number() over () from unnest(string_to_array('{','.join(PUB[:200])}', ',')) id")
o, e = run("b", f"select public.playlist_add_track('{PB}','{PUB[205]}')"); ok("7 1つのプレイリストに200曲まで", "200曲まで" in e, e[:40])
# 8. 削除・連鎖
o, e = run("a", f"select public.delete_playlist('{PA}')"); ok("8 プレイリストを削除でき、中の曲の並びも消える（曲そのものは残る）", not e and sq(f"select count(*) from public.playlist_tracks where playlist_id='{PA}'") == "0" and sq(f"select count(*) from public.tracks where id='{PUB[1]}'") == "1")
n0 = sq(f"select count(*) from public.playlist_tracks where track_id='{PUB[0]}'")
sq(f"update public.tracks set status='hidden' where id='{PUB[0]}'"); sq(f"delete from public.tracks where id='{PUB[0]}'")
ok("8 曲が削除されると各プレイリストから外れる", n0 == "1" and sq(f"select count(*) from public.tracks where id='{PUB[0]}'") == "0" and sq(f"select count(*) from public.playlist_tracks where track_id='{PUB[0]}'") == "0", n0)
before_other = sq(f"select count(*) from public.playlists where user_id<>'{U['b']}'")
sq(f"delete from auth.users where id='{U['b']}'"); ok("8 会員を削除するとその会員のプレイリストも消え、他の会員の分は残る", sq(f"select count(*) from public.playlists where user_id='{U['b']}'") == "0" and sq(f"select count(*) from public.playlists where user_id<>'{U['b']}'") == before_other)
# 9. 元に戻す
psql("postgres", f"drop database if exists {DB}"); psql("postgres", f"create database {DB} template {TPL}")
psql(DB, SQL, single=True); o, e = psql(DB, open(M + "rollback/rollback_v1_11.sql", encoding="utf-8").read(), single=True)
ok("9 rollback_v1_11.sql で適用前と完全に同じ構造に戻る（データも不変）", not e and sq(SNAP) == s0 and sq(DATA) == d0, e[:80])
psql("postgres", f"drop database if exists {DB}")
f = [r for r in R if not r[1]]; print(f"\n合計 {len(R)} 件 / 不合格 {len(f)} 件"); [print("  FAIL:", x[0]) for x in f]
sys.exit(1 if f else 0)
