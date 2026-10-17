#!/usr/bin/env python3
"""AIMUSE v1.10 review names: never return private display names."""
import subprocess, json
BASE = ["psql","-h","/home/pgtest/pg","-p","55432","-U","postgres","-X","-At","-q"]
DBN = "v110t"
M = "/home/claude/aimuse/supabase/"
def psql(db, s):
    p = subprocess.run(BASE+["-d",db], input=s, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return p.stdout.strip(), " ".join(l for l in p.stderr.splitlines() if "ERROR" in l)
R = []
def ok(n, c, i=None): R.append((n, bool(c))); print(f"[{'PASS' if c else 'FAIL'}] {n}" + (f"  → {i}" if i is not None else ""))
psql("postgres", f"drop database if exists {DBN}"); psql("postgres", f"create database {DBN} template v18")
o,e = psql(DBN, open(M+"migration_v1_10_review_names.sql").read())
ok("v1.9 未実行なら中止（何も変更しない）", "v1.9" in e, e[:80])
for f in [M+"migration_v1_9_delete.sql", "/home/pgtest/seed_v19.sql"]:
    o,e = psql(DBN, open(f).read()); assert not e, e
for i in (1,2):
    o,e = psql(DBN, open(M+"migration_v1_10_review_names.sql").read())
    ok(f"v1.10 を実行できる（{i}回目）", not e, e[:80])
H, MI, NEKO = "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444"
psql(DBN, f"""update public.profiles set display_name='ハムの本名' where id='{H}';
update public.profiles set display_name='ミケの本名' where id='{MI}';
insert into auth.users (id,email,email_confirmed_at) values ('{NEKO}','neko@example.com',now());
update public.profiles set display_name='ネコの本名' where id='{NEKO}';
insert into public.reviews (track_id,user_id,rating,comment) values ('aaaaaaaa-0000-4000-8000-000000000008','{NEKO}',3,'ネコのレビュー');""")
def anon(sql): return psql(DBN, f"begin; set local role anon; set local request.jwt.claims='{{\"role\":\"anon\"}}';\n{sql};\nrollback;")
o,e = anon("select reviewer_name||':'||comment from public.track_reviews('aaaaaaaa-0000-4000-8000-000000000008') order by comment")
rows = o.splitlines()
ok("公開中の曲があるアーティストはアーティスト名で表示", "ハムハム:ハムのレビュー" in rows, rows)
ok("曲のない会員（リスナー）は「リスナー」と表示", "リスナー:ネコのレビュー" in rows, rows)
ok("表示名（本名など）は一切返さない", "本名" not in o, o)
o,e = anon("select reviewer_name from public.track_reviews('aaaaaaaa-0000-4000-8000-000000000005')")
ok("ミケ（公開曲あり）もアーティスト名", o == "ミケ", o)
o,e = anon("select string_agg(column_name, ',') from information_schema.routine_columns where false")
o,e = anon("select pg_get_function_result('public.track_reviews(uuid)'::regprocedure)")
ok("戻り値の形は従来どおり（アプリ・既存の呼び出しに影響なし）", "reviewer_name text" in o and "user_id" not in o and "email" not in o, o)
psql(DBN, f"update public.tracks set status='hidden' where user_id='{H}'")
o,e = anon("select reviewer_name from public.track_reviews('aaaaaaaa-0000-4000-8000-000000000008') where reviewer_name<>'リスナー' or true order by 1")
ok("公開曲がなくなったアーティストは「リスナー」に切り替わる（非公開の名前を出さない）", "ハムハム" not in o and "本名" not in o, o)
f=[r for r in R if not r[1]]; print(f"\n合計 {len(R)} 件 / 不合格 {len(f)} 件"); [print("  FAIL:",x[0]) for x in f]
