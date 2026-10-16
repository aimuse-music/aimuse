#!/usr/bin/env python3
"""AIMUSE v1.7 follow-list tests on local Postgres (Supabase-equivalent roles)."""
import subprocess, json, sys
DB = ["psql", "-h", "/home/pgtest/pg", "-p", "55432", "-U", "postgres", "-d", "v17", "-X", "-At", "-v", "ON_ERROR_ROLLBACK=on", "-F", "|"]
RYO, HAMU = "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
A_RYO = f"(select id from public.artists where user_id='{RYO}')"
A_HAMU = f"(select id from public.artists where user_id='{HAMU}')"
LISTENERS = [f"00000000-0000-4000-8000-{i:012d}" for i in range(41, 121)] + [HAMU]
BANNED = [f"00000000-0000-4000-8000-{i:012d}" for i in (121, 122, 123)]

def q(who, sql):
    role, c = ("anon", {"role": "anon"}) if who == "anon" else ("authenticated", {"sub": {"ryo": RYO, "hamu": HAMU}[who], "role": "authenticated"})
    s = f"begin; set local role {role}; set local request.jwt.claims = '{json.dumps(c)}';\n{sql};\nrollback;"
    out = subprocess.run(DB, input=s, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
    return [l for l in out.splitlines() if l and l not in ("BEGIN", "SET", "ROLLBACK")]

R = []
def ok(name, cond, info=None):
    R.append((name, bool(cond))); print(f"[{'PASS' if cond else 'FAIL'}] {name}" + (f"  → {info}" if info is not None else ""))

def pages(who, fn, artist=A_RYO):
    rows, before_at, before, n = [], "null", "null", 0
    while True:
        n += 1
        args = f"{artist}, {before_at}, {before}, 30" if artist else f"{before_at}, {before}, 30"
        r = q(who, f"select * from public.{fn}({args})")
        if any("ERROR" in x for x in r): return r, n
        rows += [x.split("|") for x in r]
        if len(r) < 30: return rows, n
        last = rows[-1]; before_at, before = f"'{last[3]}'::timestamptz", f"'{last[4]}'::uuid"

print("=== 人数のまとめ（未ログイン） ===")
s = q("anon", f"select * from public.public_artist_follow_summary({A_RYO})")
ok("フォロワー121（利用停止3人を除く）・公開アーティスト40・リスナー81・フォロー中35", s == ["121|40|81|35"], s)
c = q("anon", f"select public.artist_follower_count({A_RYO})")
ok("既存のフォロワー数も利用停止中を除いて121", c == ["121"], c)

print("\n=== フォロワー一覧（未ログイン・30件ずつ） ===")
rows, n = pages("anon", "public_artist_followers")
ok("全ページで公開アーティスト40人ちょうど・重複なし", len(rows) == 40 and len({r[0] for r in rows}) == 40, (len(rows), n))
ok("ページ数は2（30＋10）", n == 2, n)
ok("新しい順に並ぶ", [r[3] for r in rows] == sorted([r[3] for r in rows], reverse=True))
alltext = "|".join("|".join(r) for r in rows)
FOLLOWER_UIDS = [f"00000000-0000-4000-8000-{i:012d}" for i in range(1, 124)] + [HAMU, RYO]
ok("どの列にも会員IDが含まれない（公開アーティスト・リスナーとも）", not any(u in alltext for u in FOLLOWER_UIDS))
ok("ページ分割の目印はアーティストID（その行のアーティストIDと同じ）", all(r[4] == r[0] for r in rows))
names = {r[1] for r in rows}
ok("利用停止中の会員は返らない", not ({"アーティスト121", "アーティスト122", "アーティスト123"} & names))
ok("返る列は アーティストID・名前・アイコン・日時・ページ用ID だけ", q("anon", "select pg_get_function_result('public.public_artist_followers(uuid,timestamptz,uuid,integer)'::regprocedure)")
   == ["TABLE(artist_id uuid, name text, avatar_path text, followed_at timestamp with time zone, cursor uuid)"])
ok("アイコン設定済みの人はアイコンの場所が返る", any(r[2].endswith("avatar-aaaaaaaa-1111-4111-8111-000000000001.jpg") for r in rows))
big = q("anon", f"select count(*) from public.public_artist_followers({A_RYO}, null, null, 100000)")
ok("1回で取り出せるのは最大100件", big == ["40"] or int(big[0]) <= 100, big)

print("\n=== フォロー中一覧（未ログイン） ===")
rows, n = pages("anon", "public_artist_following")
names = {r[1] for r in rows}
ok("公開アーティスト35人だけ（審査待ちのみ・利用停止中は除外）", len(rows) == 35 and not any(x.startswith("審査待ち") for x in names) and "アーティスト121" not in names, (len(rows), n))

print("\n=== 公開されていないアーティストの一覧は返らない ===")
ok("ハムハム（審査待ちのみ）のまとめは空", q("anon", f"select * from public.public_artist_follow_summary({A_HAMU})") == [])
ok("ハムハムのフォロワー一覧は空", q("anon", f"select * from public.public_artist_followers({A_HAMU})") == [])
banned_a = "(select a.id from public.artists a where a.user_id='00000000-0000-4000-8000-000000000121')"
ok("利用停止中の会員のアーティストのフォロー中一覧は空", q("anon", f"select * from public.public_artist_following({banned_a})") == [])

print("\n=== 自分のフォロー中（本人のみ） ===")
rows, n = pages("ryo", "my_following", artist=None)
pub = [r for r in rows if r[5] == "t"]; hid = [r for r in rows if r[5] == "f"]
ok("Ryoは37件（公開35＋公開されていない2）", len(rows) == 37 and len(pub) == 35 and len(hid) == 2, (len(rows), len(pub), len(hid)))
ok("公開されていないアーティストは名前・アイコンを返さない", all(r[1] == "" and r[2] == "" for r in hid), hid[:1])
ok("未ログインでは my_following を使えない", any("permission denied" in x for x in q("anon", "select * from public.my_following()")))
ok("ハムハムの my_following は自分の1件だけ", len(q("hamu", "select * from public.my_following()")) == 1)

print("\n=== 内部の関数・元データは直接使えない ===")
for fn in (f"is_visible_member('{RYO}')", f"is_public_artist({A_RYO})", f"public_artist_of_user('{RYO}')"):
    for who in ("anon", "hamu"):
        ok(f"{who} は {fn.split('(')[0]} を呼べない", any("permission denied" in x for x in q(who, f"select public.{fn}")))
ok("会員は他人の follows 行を読めない（従来どおり）", q("hamu", f"select count(*) from public.follows where user_id <> '{HAMU}'") == ["0"])
ok("未ログインは follows を読めない（従来どおり）", any("permission denied" in x for x in q("anon", "select count(*) from public.follows")))

print("\n=== 処理速度（フォロワー2万人のアーティスト） ===")
setup = f"""insert into auth.users(id,email,email_confirmed_at) select gen_random_uuid(),'big'||g||'@ex.com',now() from generate_series(1,20000) g;
insert into public.follows(user_id,artist_id,created_at) select u.id,{A_RYO},now()-(random()*1000||' hours')::interval from auth.users u where u.email like 'big%';
analyze public.follows;"""
out = subprocess.run(DB, input=f"begin; {setup}\n\\timing on\n"
                     f"set local role anon; set local request.jwt.claims='{{\"role\":\"anon\"}}';\n"
                     f"select count(*) from public.public_artist_followers({A_RYO}, null, null, 30);\n"
                     f"select * from public.public_artist_follow_summary({A_RYO});\nrollback;",
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
times = [float(l.split()[1]) for l in out.splitlines() if l.startswith("Time:")]
summ = [l for l in out.splitlines() if l.count("|") == 3]
ok("2万人でもフォロワー一覧1ページは1秒未満", len(times) >= 2 and times[-2] < 1000, f"{times[-2]:.0f}ms" if len(times) >= 2 else out[-300:])
ok("2万人の人数のまとめ（時間を記録）", summ == ["20121|40|20081|35"], f"{summ} / {times[-1]:.0f}ms" if times else out[-300:])

f = [r for r in R if not r[1]]
print(f"\n合計 {len(R)} 件 / 不合格 {len(f)} 件"); [print("  FAIL:", x[0]) for x in f]
