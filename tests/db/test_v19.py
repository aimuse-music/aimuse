#!/usr/bin/env python3
"""AIMUSE v1.9 tests: owner track deletion + account withdrawal (local Postgres, Supabase-equivalent roles).
Each call runs in its own committed transaction, so the scenario is stateful (like the real service)."""
import subprocess, json, time, threading, sys
DBN = sys.argv[1] if len(sys.argv) > 1 else "v19t"
BASE = ["psql","-h","/home/pgtest/pg","-p","55432","-U","postgres","-X","-At","-q"]
U = {"ryo":"11111111-1111-4111-8111-111111111111","hamu":"22222222-2222-4222-8222-222222222222","mike":"33333333-3333-4333-8333-333333333333","neko":"44444444-4444-4444-8444-444444444444"}
T = lambda n: f"aaaaaaaa-0000-4000-8000-00000000000{n}"
def psql(db, s):
    p = subprocess.run(BASE+["-d",db], input=s, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return p.stdout.strip(), " ".join(l for l in p.stderr.splitlines() if "ERROR" in l)
def setup():
    psql("postgres", f"drop database if exists {DBN};"); psql("postgres", f"create database {DBN} template v18;")
    for f in ["/home/claude/aimuse/supabase/migration_v1_9_delete.sql", "/home/pgtest/seed_v19.sql"]:
        o, e = psql(DBN, open(f, encoding="utf-8").read()); assert not e, e
def run(who, sql, amr_age=60, method="password"):
    if who == "anon": role, c = "anon", {"role":"anon"}
    elif who == "service": role, c = "service_role", {"role":"service_role"}
    elif who == "postgres": return psql(DBN, sql)
    else:
        role, c = "authenticated", {"sub":U[who], "role":"authenticated"}
        if amr_age is not None: c["amr"] = [{"method":method, "timestamp": int(time.time()) - amr_age}]
    return psql(DBN, f"begin;\nset local role {role};\nset local request.jwt.claims='{json.dumps(c)}';\n{sql};\ncommit;")
sq = lambda sql: run("postgres", sql)[0]
R = []
def ok(n, c, i=None): R.append((n, bool(c))); print(f"[{'PASS' if c else 'FAIL'}] {n}" + (f"  → {i}" if i is not None else ""))

setup()
# ===================== A. 楽曲の削除 =====================
o,e = run("anon", f"select public.delete_my_track('{T(5)}')")
ok("A1 未ログインでは削除できない", "permission denied" in e, e[:70])
o,e = run("mike", f"select public.delete_my_track('{T(5)}')")
ok("A2 他人（ミケ）はハムの曲を削除できない", "楽曲が見つかりません" in e and sq(f"select count(*) from public.tracks where id='{T(5)}'")=="1", e[:70])
o,e = run("mike", f"delete from public.tracks where id='{T(7)}' returning id")
ok("A3 他人の曲をテーブルから直接も削除できない（0件）", o=="" and sq(f"select count(*) from public.tracks where id='{T(7)}'")=="1", (o,e[:60]))
o,e = run("hamu", f"select public.delete_my_track('{T(5)}')")
ok("A4 本人は公開中の曲を削除できる", o=="deleted" and sq(f"select count(*) from public.tracks where id='{T(5)}'")=="0", (o,e[:80]))
o,e = run("anon", f"select count(*) from public.tracks where id='{T(5)}'")
ok("A5 削除した曲は公開一覧・検索（未ログインの取得）からすぐ消える", o=="0")
snap = sq(f"select reason||'|'||(track->>'status')||'|'||jsonb_array_length(reports)||'|'||jsonb_array_length(reviews)||'|'||coalesce(deleted_by::text,'') from aimuse_private.track_deletions where track_id='{T(5)}'")
ok("A6 削除記録：本人削除・削除前は公開中・通報1件・レビュー1件を保存", snap==f"owner|public|1|1|{U['hamu']}", snap)
ok("A7 音源・ジャケットのファイルは30日間残る（復元用）", sq(f"select count(*) from storage.objects where name like '%{T(5)[-12:]}%'")=="2")
o,e = run("hamu", f"delete from storage.objects where bucket_id='audio' and name='{U['hamu']}/{T(5)}.mp3' returning name")
ok("A8 削除後30日間は、本人でもファイルを消せない（復元の保護）", o=="", (o,e[:60]))
ok("A9 お気に入り・レビュー・通報も整合して消える", sq(f"select (select count(*) from public.favorites where track_id='{T(5)}')+(select count(*) from public.reviews where track_id='{T(5)}')+(select count(*) from public.reports where song_id='{T(5)}')")=="0")
o,e = run("hamu", f"select public.delete_my_track('{T(5)}')")
ok("A10 もう一度削除しても安全（削除済みと返る）", o=="already_deleted", (o,e[:60]))
o,e = run("mike", f"select public.delete_my_track('{T(5)}')")
ok("A11 他人が削除済みの曲IDで呼んでも情報を返さない", "楽曲が見つかりません" in e, e[:60])
o,e = run("hamu", f"select public.delete_my_track('{T(4)}')")
ok("A12 本人は審査待ちの曲も削除できる", o=="deleted", (o,e[:60]))
o,e = run("ryo", f"select status_before from public.admin_list_deleted_tracks() where track_id='{T(5)}'")
ok("A13 管理者の削除済み一覧に「削除前：公開中」と表示", o=="public", (o,e[:60]))
o,e = run("ryo", f"select public.admin_restore_track((select deletion_id from public.admin_list_deleted_tracks() where track_id='{T(5)}'))")
ok("A14 既存の30日間復元で、本人が削除した曲も復元できる（非公開で復元）", T(5) in o and sq(f"select status from public.tracks where id='{T(5)}'")=="hidden", (o,e[:80]))
run("postgres", f"update public.tracks set status='public' where id='{T(5)}'")
# 同時に2回押した場合（2つの接続から同時に削除）
res = []
def worker(): res.append(run("hamu", f"select public.delete_my_track('{T(6)}'), pg_sleep(1)")[0].split("|")[0])
th = [threading.Thread(target=worker) for _ in range(2)]; [t.start() for t in th]; [t.join() for t in th]
ok("A15 同時に2回削除しても、片方は「削除済み」になり記録は1件", sorted(res)==["already_deleted","deleted"] and sq(f"select count(*) from aimuse_private.track_deletions where track_id='{T(6)}'")=="1", res)
run("postgres", f"delete from aimuse_private.track_deletions where track_id='{T(6)}'; insert into public.tracks (id,user_id,title,artist,genre,tool,tool_name,audio_path,status) values ('{T(6)}','{U['hamu']}','ハムの公開曲2','ハムハム','J-POP','Suno','Suno','{U['hamu']}/{T(6)}.mp3','public')")
run("postgres", f"update public.profiles set is_banned=true where id='{U['mike']}'")
o,e = run("mike", f"select public.delete_my_track('{T(8)}')")
ok("A16 利用停止中の会員は削除できない", "削除できません" in e, e[:60])
run("postgres", f"update public.profiles set is_banned=false where id='{U['mike']}'")

# ===================== B. 退会の申請 =====================
o,e = run("hamu", f"select * from public.account_request_deletion('{U['hamu']}')")
ok("B1 本人（会員のログイン）でも申請関数は直接呼べない（パスワード照合を通るサーバー処理だけ）", "permission denied" in e, e[:70])
o,e = run("ryo", f"select * from public.account_request_deletion('{U['hamu']}')")
ok("B2 管理者でも他人の退会を申請できない", "permission denied" in e, e[:70])
o,e = run("service", f"select * from public.account_request_deletion('{U['ryo']}')")
ok("B3 管理者アカウントは退会できない", "管理者アカウントは退会できません" in e, e[:70])
o,e = run("anon", f"select * from public.account_request_deletion('{U['hamu']}')")
ok("B4 未ログインは申請できない", "permission denied" in e, e[:60])
o,e = run("hamu", f"select public.account_reauth_failed('{U['hamu']}')")
o2,e2 = run("anon", f"select public.account_reauth_allowed('{U['hamu']}')")
ok("B4b 試行回数の記録・確認も会員・未ログインからは使えない", "permission denied" in e and "permission denied" in e2)
for i in range(4): run("service", f"select public.account_reauth_failed('{U['mike']}')")
o,e = run("service", f"select public.account_reauth_allowed('{U['mike']}')")
run("service", f"select public.account_reauth_failed('{U['mike']}')")
o2,e2 = run("service", f"select public.account_reauth_allowed('{U['mike']}')")
o3,e3 = run("service", f"select public.account_reauth_allowed('{U['hamu']}')")
ok("B4c パスワード照合は1時間に5回失敗すると止まる（他の会員には影響しない）", (o,o2,o3)==("t","f","t"), (o,o2,o3))
run("postgres", f"update aimuse_private.reauth_failures set at=now()-interval '61 minutes' where user_id='{U['mike']}'")
ok("B4d 1時間たてば、また照合できる", run("service", f"select public.account_reauth_allowed('{U['mike']}')")[0]=="t")
before_follow = sq("select public.artist_follower_count(id) from public.artists where name='ミケ'")
o,e = run("service", f"select status, purge_after::date - requested_at::date from public.account_request_deletion('{U['hamu']}')")
ok("B5 パスワード照合を通ったサーバー処理から申請できる（30日後に削除開始）", o=="pending|30", (o,e[:80]))
o2,e2 = run("service", f"select status from public.account_request_deletion('{U['hamu']}')")
ok("B6 二重に申請しても申請は1件のまま", o2=="pending" and sq(f"select count(*) from aimuse_private.account_deletions where user_id='{U['hamu']}'")=="1", o2)
ok("B7 公開中・審査待ちの曲を非公開にし、元の状態を記録", sq(f"select string_agg(status,',' order by id) from public.tracks where user_id='{U['hamu']}'")=="hidden,hidden,hidden"
   and sq(f"select hidden_tracks::text from aimuse_private.account_deletions where user_id='{U['hamu']}'").count('"public"')==2, sq(f"select hidden_tracks from aimuse_private.account_deletions where user_id='{U['hamu']}'"))
mf = sq(f"select string_agg(bucket_id||':'||split_part(name,'/',2),' ' order by bucket_id,name) from aimuse_private.account_deletion_files f join aimuse_private.account_deletions d on d.id=f.request_id where d.user_id='{U['hamu']}'")
ok("B8 削除するファイルの一覧を申請時に記録（音源・ジャケット・アイコン・削除済み曲・使われていないファイル）",
   all(x in mf for x in [f"{T(5)}.mp3", f"{T(5)}.jpg", f"{T(4)}.mp3", f"{T(7)}.mp3", "0000000000ff.mp3", "avatars:"]) and U['mike'] not in mf, mf[:120])
o,e = run("anon", f"select count(*) from public.tracks where user_id='{U['hamu']}'")
o2,e2 = run("anon", f"select count(*) from public.artists where user_id='{U['hamu']}'")
o3,e3 = run("anon", f"select count(*) from public.public_artist_profiles(array(select id from public.artists where user_id='{U['hamu']}'))")
ok("B9 公開画面から消える（曲・アーティスト・プロフィール画像）", (o,o2,o3)==("0","0","0"), (o,o2,o3))
ok("B10 ミケのフォロワー数から、退会手続き中のハムを除外", sq("select public.artist_follower_count(id) from public.artists where name='ミケ'")==str(int(before_follow)-1), before_follow)
o,e = run("anon", f"select count(*) from public.track_reviews('{T(8)}')")
ok("B11 退会手続き中の会員のレビューは表示しない", o=="0", o)
o,e = run("hamu", "select * from public.my_account_deletion()")
ok("B12 本人は状況を確認できる（取り消し可能）", o.startswith("pending|") and o.endswith("|t"), o)
o,e = run("mike", "select count(*) from public.my_account_deletion()")
ok("B13 他人の状況は見えない", o=="0", o)

# ===================== C. 退会手続き中の操作制限（サーバー側） =====================
NEWID = "cccccccc-0000-4000-8000-000000000001"
blocked = {
 "楽曲の投稿": f"insert into public.tracks (id,user_id,title,artist,genre,tool,tool_name,audio_path,status,plays) values ('{NEWID}','{U['hamu']}','x','ハムハム','J-POP','Suno','Suno','{U['hamu']}/{NEWID}.mp3','pending',0)",
 "お気に入り": f"insert into public.favorites (user_id,track_id) values ('{U['hamu']}','{T(1)}')",
 "フォロー": f"insert into public.follows (user_id,artist_id) select '{U['hamu']}', id from public.artists where name='NOCTERA'",
 "レビュー": f"insert into public.reviews (track_id,user_id,rating) values ('{T(1)}','{U['hamu']}',5)",
 "通報": f"insert into public.reports (song_id,reason,reporter_id) values ('{T(8)}','x','{U['hamu']}') returning id",
 "レビューの書き換え": f"update public.reviews set rating=1 where user_id='{U['hamu']}' returning id",
 "アーティスト紹介文": f"update public.artists set bio='x' where user_id='{U['hamu']}' returning id",
 "アーティスト名の変更": f"select public.rename_my_artist((select id from public.artists where user_id='{U['hamu']}'),'ハム2')",
 "プロフィール画像": f"select public.set_my_profile_image('avatar',null)",
 "表示名の変更": f"update public.profiles set display_name='ハム改' where id='{U['hamu']}' returning id",
 "音源ファイルの保存": f"insert into storage.objects (bucket_id,name,owner_id) values ('audio','{U['hamu']}/{NEWID}.mp3','{U['hamu']}') returning name",
 "アイコン画像の保存": f"insert into storage.objects (bucket_id,name,owner_id) values ('avatars','avatar-{NEWID}.jpg','{U['hamu']}') returning name",
 "楽曲の削除": f"select public.delete_my_track('{T(7)}')",
}
for name, sql in blocked.items():
    o,e = run("hamu", sql, amr_age=5)   # 直前にログインし直した状態でも
    ok(f"C 退会手続き中は不可：{name}", e or o=="", (o,e[:70]))
o,e = run("ryo", f"update public.tracks set status='public' where id='{T(5)}' returning id")
ok("C 管理者でも、退会手続き中の会員の曲を公開に戻せない", "公開・審査に戻せません" in e, e[:70])
o,e = run("hamu", "select public.account_purge_claim()")
o2,e2 = run("ryo", "select public.account_purge_claim()")
o3,e3 = run("anon", "select * from public.account_purge_db(gen_random_uuid(),gen_random_uuid())")
ok("C 完全削除の関数は、本人・管理者・未ログインから実行できない", all("permission denied" in x for x in (e,e2,e3)), (e[:50],e2[:50],e3[:50]))

# ===================== D. 取り消し =====================
o,e = run("mike", "select * from public.cancel_my_account_deletion()")
ok("D1 他人（ミケ）はハムの退会を取り消せない", "取り消せる退会申請がありません" in e and sq(f"select status from aimuse_private.account_deletions where user_id='{U['hamu']}'")=="pending", e[:60])
o,e = run("anon", "select * from public.cancel_my_account_deletion()")
ok("D2 未ログインは取り消せない", "permission denied" in e)
# 申請後に、ハムの曲(5)が通報された
run("postgres", f"insert into public.reports (song_id,reason,reporter_id) values ('{T(5)}','新しい通報','{U['mike']}')")
o,e = run("hamu", "select * from public.cancel_my_account_deletion()", amr_age=3*86400)
ok("D3 本人は取り消せる（パスワード再入力は不要）。申請後に通報された曲は非公開のまま", o=="canceled|1|1", (o,e[:70]))
ok("D4 元の状態に戻る（公開中→公開中、非公開→非公開）", sq(f"select string_agg(id::text||'='||status,',' order by id) from public.tracks where user_id='{U['hamu']}'")
   == f"{T(5)}=hidden,{T(6)}=public,{T(7)}=hidden", sq(f"select string_agg(id::text||'='||status,',' order by id) from public.tracks where user_id='{U['hamu']}'"))
o,e = run("hamu", f"insert into public.favorites (user_id,track_id) values ('{U['hamu']}','{T(1)}') returning track_id")
ok("D5 取り消し後は操作できる", T(1) in o, (o,e[:60]))
ok("D6 取り消し後はフォロワー数・レビューも元どおり", sq("select public.artist_follower_count(id) from public.artists where name='ミケ'")==before_follow and run("anon", f"select count(*) from public.track_reviews('{T(8)}')")[0]=="1")
o,e = run("hamu", "select * from public.cancel_my_account_deletion()")
ok("D7 もう一度取り消しても安全（申請がないと返る）", "取り消せる退会申請がありません" in e, e[:60])

# ===================== E. 30日後の完全削除（サーバー側の処理） =====================
o,e = run("service", f"select status from public.account_request_deletion('{U['hamu']}')")
ok("E1 再申請できる（取り消し済みの記録とは別）", o=="pending" and sq(f"select count(*) from aimuse_private.account_deletions where user_id='{U['hamu']}'")=="2", (o,e[:60]))
o,e = run("service", "select count(*) from public.account_purge_claim()")
ok("E2 30日たつまでは削除処理の対象にならない", o=="0", (o,e[:60]))
run("postgres", f"update aimuse_private.account_deletions set purge_after=now()-interval '1 minute' where user_id='{U['hamu']}' and status='pending'")
o,e = run("hamu", "select * from public.cancel_my_account_deletion()")
ok("E3 30日を過ぎたら取り消せない", "期限" in e, e[:60])
o,e = run("hamu", "select can_cancel from public.my_account_deletion()")
ok("E4 状況の確認でも「取り消し不可」と分かる", o=="f", o)
# 2つの処理が同時に取り出そうとする
outs = []
def claim(): outs.append(run("service", "select request_id||','||lock_token from public.account_purge_claim(), pg_sleep(1)")[0])
th = [threading.Thread(target=claim) for _ in range(2)]; [t.start() for t in th]; [t.join() for t in th]
got = [x for x in outs if x]
ok("E5 削除処理を同時に2回動かしても、取り出されるのは1回だけ", len(got)==1, outs)
req, tok = got[0].split("|")[0].split(",")
o,e = run("hamu", "select * from public.cancel_my_account_deletion()")
ok("E6 削除処理が始まった後は取り消せない", "取り消せません" in e, e[:60])
o,e = run("service", f"select * from public.account_purge_pending_files('{req}', gen_random_uuid())")
ok("E7 処理番号が違うと何もできない（二重実行の防止）", "LEASE_LOST" in e, e[:60])
o,e = run("service", f"select bucket_id||':'||name from public.account_purge_pending_files('{req}','{tok}')")
files = [x for x in o.splitlines() if x]
ok("E8 削除するファイルの一覧を取得（ミケ・Ryoのファイルは含まない）", len(files)>=7 and not any(U['mike'] in f or U['ryo'] in f for f in files), len(files))
o,e = run("service", f"select public.account_purge_db('{req}','{tok}')")
ok("E9 ファイルが残っている間はデータを消さない", "FILES_REMAIN" in e and sq(f"select count(*) from public.tracks where user_id='{U['hamu']}'")!="0", e[:60])
# Storage API での削除を一部だけ再現（途中で失敗）
half = files[:3]
for f in half:
    b, n = f.split(":",1); run("postgres", f"delete from storage.objects where bucket_id='{b}' and name='{n}'")
o,e = run("service", f"select public.account_purge_mark_files('{req}','{tok}')")
ok("E10 実際に消えたファイルだけを「削除済み」に記録", o=="3", (o,e[:60]))
o,e = run("service", f"select public.account_purge_fail('{req}','{tok}','storage timeout')")
st = sq(f"select status||'|'||attempts||'|'||coalesce(last_error,'') from aimuse_private.account_deletions where id='{req}'")
ok("E11 途中の失敗を記録（会員は非公開・操作不可のまま）", st=="processing|1|storage timeout", st)
o,e = run("hamu", f"insert into public.favorites (user_id,track_id) values ('{U['hamu']}','{T(1)}')")
ok("E12 削除処理中も操作できない", bool(e))
o,e = run("service", "select count(*) from public.account_purge_claim()")
ok("E12b 失敗直後はすぐに再試行しない（1時間おく）", o=="0", o)
run("postgres", f"update aimuse_private.account_deletions set locked_until=now()-interval '1 second' where id='{req}'")
o,e = run("service", "select request_id||','||lock_token from public.account_purge_claim()")
req2, tok2 = o.split(",")
ok("E13 次回の実行で続きから再開（同じ申請・新しい処理番号）", req2==req and tok2!=tok, o)
o,e = run("service", f"select public.account_purge_mark_files('{req}','{tok}')")
ok("E14 古い処理番号は使えない", "LEASE_LOST" in e, e[:60])
o,e = run("service", f"select bucket_id||':'||name from public.account_purge_pending_files('{req}','{tok2}')")
rest = [x for x in o.splitlines() if x]
ok("E15 残りのファイルだけが対象（済んだものは飛ばす）", len(rest)==len(files)-3, (len(rest),len(files)))
for f in rest:
    b, n = f.split(":",1); run("postgres", f"delete from storage.objects where bucket_id='{b}' and name='{n}'")
run("service", f"select public.account_purge_mark_files('{req}','{tok2}')")
o,e = run("service", f"select public.account_purge_finish('{req}','{tok2}')")
ok("E16 会員が残っている間は「完了」にしない", "DB_NOT_DONE" in e or "USER_REMAINS" in e, e[:60])
o,e = run("service", f"select public.account_purge_db('{req}','{tok2}')")
ok("E17 ファイルが全部消えたらデータを削除", not e and sq(f"select count(*) from public.tracks where user_id='{U['hamu']}'")=="0"
   and sq(f"select count(*) from aimuse_private.track_deletions where track->>'user_id'='{U['hamu']}'")=="0", e[:80])
o,e = run("service", f"select public.account_purge_db('{req}','{tok2}')")
ok("E18 データ削除を再実行しても安全", not e, e[:60])
o,e = run("service", f"select public.account_purge_finish('{req}','{tok2}')")
ok("E19 会員（ログイン情報）が残っている間は「完了」にしない", "USER_REMAINS" in e and sq(f"select status from aimuse_private.account_deletions where id='{req}'")=="processing", e[:60])
run("postgres", f"delete from auth.users where id='{U['hamu']}'")   # Edge Function の auth.admin.deleteUser に相当
o,e = run("service", f"select public.account_purge_finish('{req}','{tok2}')")
left = sq(f"select (select count(*) from public.profiles where id='{U['hamu']}')+(select count(*) from public.artists where user_id='{U['hamu']}')+(select count(*) from public.follows where user_id='{U['hamu']}')+(select count(*) from public.favorites where user_id='{U['hamu']}')+(select count(*) from public.reviews where user_id='{U['hamu']}')+(select count(*) from aimuse_private.account_deletion_files)")
ok("E20 会員の削除を確認してから「完了」。関連データ・ファイル一覧も残らない", not e and sq(f"select status from aimuse_private.account_deletions where id='{req}'")=="done" and left=="0", (e[:60], left))
ok("E21 ミケ・Ryoのデータとファイルは無事", sq(f"select count(*) from public.tracks where user_id in ('{U['mike']}','{U['ryo']}')")=="4"
   and sq(f"select count(*) from storage.objects where name like '{U['mike']}%' or name like '{U['ryo']}%' or owner_id='{U['mike']}'")=="5"
)
o,e = run("service", "select count(*) from public.account_purge_claim()")
ok("E22 完了後はもう取り出されない（重複実行しても何もしない）", o=="0", o)
ok("E23 同じメールアドレスで再登録した場合も、新しい会員として扱われる（記録は会員IDのみ）", sq("select count(*) from information_schema.columns where table_schema='aimuse_private' and table_name='account_deletions' and column_name ilike '%mail%'")=="0")

# ===================== F. 失敗が続いた場合 =====================
run("postgres", f"insert into aimuse_private.account_deletions (user_id,purge_after) values ('{U['mike']}', now()-interval '1 minute')")
for i in range(10):
    o,e = run("service", "select request_id||','||lock_token from public.account_purge_claim()")
    if not o: break
    r_, t_ = o.split(","); run("service", f"select public.account_purge_fail('{r_}','{t_}','test failure {i}')")
    run("postgres", f"update aimuse_private.account_deletions set locked_until=now()-interval '1 second' where id='{r_}' and status='processing'")
st = sq(f"select status||'|'||attempts from aimuse_private.account_deletions where user_id='{U['mike']}'")
ok("F1 10回失敗したら自動の再試行を止め「運営の確認待ち」にする", st=="failed|10", st)
o,e = run("service", "select count(*) from public.account_purge_claim()")
ok("F2 確認待ちは自動で取り出されない", o=="0")
o,e = run("mike", f"insert into public.favorites (user_id,track_id) values ('{U['mike']}','{T(1)}')")
ok("F3 確認待ちの間も、会員は非公開・操作不可のまま", bool(e) and run("anon", f"select count(*) from public.track_reviews('{T(1)}')")[1]=="")
run("postgres", f"update aimuse_private.account_deletions set status='processing', attempts=0, locked_until=null where user_id='{U['mike']}'")
o,e = run("service", "select count(*) from public.account_purge_claim()")
ok("F4 運営が状態を戻せば、再び自動で処理される", o=="1", o)
# 止まったまま（関数がタイムアウト等で fail も呼べなかった）
run("postgres", f"update aimuse_private.account_deletions set attempts=10, locked_until=now()-interval '1 minute' where user_id='{U['mike']}'")
o,e = run("service", "select count(*) from public.account_purge_claim()")
ok("F5 応答なく止まったまま10回に達した処理も「確認待ち」になる", o=="0" and sq(f"select status from aimuse_private.account_deletions where user_id='{U['mike']}'")=="failed", o)

# ===================== G. 取り消し期限と削除処理の競合 =====================
NEKO = U["neko"]
run("postgres", f"insert into auth.users (id,email,email_confirmed_at) values ('{NEKO}','neko@example.com',now())")
def bg(who, sql, out):
    out.append(run(who, sql))
# G1 削除処理が先に取り出して処理中 → その間に取り消しを押しても取り消せない
run("service", f"select * from public.account_request_deletion('{NEKO}')")
run("postgres", f"update aimuse_private.account_deletions set purge_after=now()-interval '1 second' where user_id='{NEKO}' and status='pending'")
oa, ob = [], []
ta = threading.Thread(target=bg, args=("service", "select request_id is not null from public.account_purge_claim(); select pg_sleep(2)", oa)); ta.start()
time.sleep(0.6)
tb = threading.Thread(target=bg, args=("neko", "select * from public.cancel_my_account_deletion()", ob)); tb.start()
ta.join(); tb.join()
ok("G1 削除処理が始まった直後に取り消しを押しても、取り消せない（処理中）", oa[0][0].startswith("t") and "取り消せません" in ob[0][1]
   and sq(f"select status from aimuse_private.account_deletions where user_id='{NEKO}' order by requested_at desc limit 1")=="processing", (oa, ob))
o,e = run("neko", "select can_cancel from public.my_account_deletion()")
ok("G2 処理中は「取り消し不可」と表示される", o=="f", o)
# G3 期限の直前に取り消しを押した（処理中に期限が来た）→ 取り消しが優先され、削除処理は取り出さない
run("postgres", f"update aimuse_private.account_deletions set status='canceled' where user_id='{NEKO}'")
run("service", f"select * from public.account_request_deletion('{NEKO}')")
run("postgres", f"update aimuse_private.account_deletions set purge_after=now()+interval '1.5 seconds' where user_id='{NEKO}' and status='pending'")
oa, ob = [], []
ta = threading.Thread(target=bg, args=("neko", "select status from public.cancel_my_account_deletion(); select pg_sleep(3)", oa)); ta.start()
time.sleep(2.0)   # この時点で期限は過ぎているが、取り消しの処理が先に始まっている
tb = threading.Thread(target=bg, args=("service", "select count(*) from public.account_purge_claim()", ob)); tb.start()
ta.join(); tb.join()
o,e = run("service", "select count(*) from public.account_purge_claim()")
ok("G3 期限直前の取り消しと、期限直後の削除処理が重なっても、取り消しが成立し削除は始まらない",
   oa[0][0].startswith("canceled") and ob[0][0]=="0" and o=="0"
   and sq(f"select status from aimuse_private.account_deletions where user_id='{NEKO}' order by requested_at desc limit 1")=="canceled", (oa, ob, o))
# G4 期限を過ぎたら（削除処理の前でも）取り消せない
run("service", f"select * from public.account_request_deletion('{NEKO}')")
run("postgres", f"update aimuse_private.account_deletions set purge_after=now()-interval '1 second' where user_id='{NEKO}' and status='pending'")
o,e = run("neko", "select * from public.cancel_my_account_deletion()")
ok("G4 期限を過ぎたら、削除処理が始まる前でも取り消せない", "期限" in e, e[:60])
# G5 失敗が続いて「確認待ち」の間も取り消せない
run("postgres", f"update aimuse_private.account_deletions set status='failed' where user_id='{NEKO}' and status='pending'")
o,e = run("neko", "select * from public.cancel_my_account_deletion()")
ok("G5 運営の確認待ち（failed）の間も取り消せない", "取り消せません" in e, e[:60])
o,e = run("service", f"select status from public.account_request_deletion('{NEKO}')")
ok("G6 処理中・確認待ちの間に再申請しても、新しい申請は作られない", o=="failed" and sq(f"select count(*) from aimuse_private.account_deletions where user_id='{NEKO}' and status in ('pending','processing','failed')")=="1", o)

f=[r for r in R if not r[1]]; print(f"\n合計 {len(R)} 件 / 不合格 {len(f)} 件"); [print("  FAIL:",x[0]) for x in f]
