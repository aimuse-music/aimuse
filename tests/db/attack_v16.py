#!/usr/bin/env python3
"""AIMUSE v1.6 profile-edit security & behavior tests (local Postgres, Supabase-equivalent roles).
Each case: optional superuser setup (pre) -> statement as the user's role+JWT -> verify as superuser -> ROLLBACK."""
import subprocess, json, sys
DB = ["psql", "-h", "/home/pgtest/pg", "-p", "55432", "-U", "postgres", "-d", "v16", "-X",
      "-v", "ON_ERROR_STOP=0", "-v", "ON_ERROR_ROLLBACK=on", "-At"]
RYO  = "11111111-1111-4111-8111-111111111111"
HAMU = "22222222-2222-4222-8222-222222222222"
U = "aaaaaaaa-1111-4111-8111-%012d"
def path(owner, kind, n, ext="jpg"): return f"{kind}-{U % (n + (500 if owner == RYO else 0))}.{ext}"   # v1.6 r2: ファイル名に会員IDを含めない（owner は owner_id で管理）
OWN = {}
A_RYO  = f"(select id from public.artists where user_id='{RYO}')"
A_HAMU = f"(select id from public.artists where user_id='{HAMU}')"

def claims(who):
    if who == "anon": return "anon", {"role": "anon"}
    return "authenticated", {"sub": {"hamu": HAMU, "ryo": RYO}[who], "role": "authenticated"}

def run(who, stmt, verify, pre=""):
    role, c = claims(who)
    script = f"""begin;
{pre};
set local role {role};
set local request.jwt.claims = '{json.dumps(c)}';
\\echo ===A===
{stmt};
\\echo ===V===
reset role;
{verify};
rollback;
"""
    out = subprocess.run(DB, input=script, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
    a = out.split("===A===")[1].split("===V===")[0]
    v = out.split("===V===")[1] if "===V===" in out else ""
    clean = lambda t: "\n".join(l for l in t.strip().splitlines()
                                if l.strip() not in ("RESET", "ROLLBACK", "SET")
                                and not l.startswith(("INSERT ", "UPDATE ", "DELETE ", "CONTEXT:", "LINE ", "  ", "HINT:", "DETAIL:"))).strip()
    return clean(a), clean(v)

R = []
def case(group, name, who, stmt, verify, ok, pre=""):
    a, v = run(who, stmt, verify, pre)
    p = ok(a, v)
    R.append((group, name, p))
    print(f"[{'PASS' if p else 'FAIL'}] {group} {name} ({who})\n      操作→ {' '.join(a.split())[:140]}\n      DB  → {' '.join(v.split())[:140]}")

err = lambda a, v: "ERROR" in a
eq  = lambda x: (lambda a, v: v == x)
both = lambda f, g: (lambda a, v: f(a, v) and g(a, v))
prof = lambda uid: f"select coalesce(avatar_path,'null')||'|'||coalesce(header_path,'null') from public.profiles where id='{uid}'"
def obj(n, owner=None):   # superuser setup（持ち主つきで保存済みにする）
    return f"insert into storage.objects (bucket_id,name,owner_id) values ('avatars','{n}','{owner or OWN.get(n, HAMU)}')"
def upl(n, owner=None):   # as user: Storage API は owner_id にログイン中の会員IDを入れて保存する
    return f"insert into storage.objects (bucket_id,name,owner_id) values ('avatars','{n}', coalesce('{owner}', auth.uid()::text))" if owner else \
           f"insert into storage.objects (bucket_id,name,owner_id) values ('avatars','{n}', auth.uid()::text)"
cnt = lambda n: f"select count(*) from storage.objects where bucket_id='avatars' and name='{n}'"
H1, H2, H3, H4, H5 = (path(HAMU, "avatar", i) for i in range(1, 6))
R1 = path(RYO, "avatar", 9); OWN[R1] = RYO
OWN[path(RYO, "avatar", 2)] = RYO
HAMU_HAS_AVATAR = f"{obj(H1)}; update public.profiles set avatar_path='{H1}' where id='{HAMU}'"

print("=== A. 画像の保存（Storage） ===")
case("A", "自分のフォルダに保存", "hamu", upl(H1), cnt(H1), eq("1"))
case("A", "持ち主をRyoと偽って保存", "hamu", upl(path(RYO, "avatar", 2), RYO), cnt(path(RYO, "avatar", 2)), both(err, eq("0")))
for bad in (f"avatar-{U % 3}.svg", f"avatar-{U % 3}.html", "x.jpg", f"{HAMU}/avatar-{U % 3}.jpg", f"../avatar-{U % 3}.jpg", f"sub/avatar-{U % 3}.jpg"):
    case("A", f"不正な名前で保存：{bad}", "hamu", upl(bad), f"select count(*) from storage.objects where name='{bad}'", both(err, eq("0")))
case("A", "保存した画像の公開URLに会員IDが含まれない", "hamu", upl(H1), f"select name from storage.objects where name='{H1}'", lambda a, v: HAMU not in v and v == H1)
case("A", "5個目の保存（1人4個まで）", "hamu", upl(H5), cnt(H5), both(err, eq("0")),
     pre=f"{obj(H1)};{obj(H2)};{obj(H3)};{obj(H4)}")
case("A", "未ログインで保存", "anon", upl(H1), cnt(H1), both(err, eq("0")))
case("A", "利用停止中に保存", "hamu", upl(H1), cnt(H1), both(err, eq("0")),
     pre=f"update public.profiles set is_banned=true where id='{HAMU}'")
case("A", "上書き（update）", "hamu", f"update storage.objects set name='{H2}' where name='{H1}'", cnt(H1), eq("1"), pre=obj(H1))
case("A", "他人の画像一覧を見る", "hamu", f"select count(*) from storage.objects where bucket_id='avatars' and owner_id='{RYO}'", "select 1",
     lambda a, v: a == "0", pre=obj(R1))
case("A", "未ログインで画像一覧を見る", "anon", "select count(*) from storage.objects where bucket_id='avatars'", "select 1",
     lambda a, v: a == "0", pre=obj(R1))

print("\n=== B. 画像の削除 ===")
case("B", "使用中の自分のアイコンを削除（守られる）", "hamu", f"delete from storage.objects where name='{H1}'", cnt(H1), eq("1"), pre=HAMU_HAS_AVATAR)
case("B", "使っていない自分の画像を削除", "hamu", f"delete from storage.objects where name='{H2}'", cnt(H2), eq("0"), pre=f"{HAMU_HAS_AVATAR};{obj(H2)}")
case("B", "他人の画像を削除", "hamu", f"delete from storage.objects where name='{R1}'", cnt(R1), eq("1"), pre=obj(R1))
case("B", "管理者が他人の画像を削除", "ryo", f"delete from storage.objects where name='{H2}'", cnt(H2), eq("0"), pre=obj(H2))

print("\n=== C. プロフィールへの設定（set_my_profile_image） ===")
case("C", "自分の画像をアイコンに設定（古い場所が返る）", "hamu", f"select coalesce(public.set_my_profile_image('avatar','{H2}'),'null')", prof(HAMU),
     lambda a, v: a == H1 and v == f"{H2}|null", pre=f"{HAMU_HAS_AVATAR};{obj(H2)}")
case("C", "背景を設定", "hamu", f"select public.set_my_profile_image('header','{path(HAMU,'header',7)}')", prof(HAMU),
     eq(f"null|{path(HAMU,'header',7)}"), pre=obj(path(HAMU, 'header', 7)))
case("C", "初期画像に戻す（null）", "hamu", "select public.set_my_profile_image('avatar',null)", prof(HAMU), eq("null|null"), pre=HAMU_HAS_AVATAR)
case("C", "他人（Ryo）の画像を自分のアイコンに設定（既存は守られる）", "hamu", f"select public.set_my_profile_image('avatar','{R1}')", prof(HAMU),
     both(err, eq(f"{H1}|null")), pre=f"{HAMU_HAS_AVATAR};{obj(R1)}")
case("C", "保存されていない画像を設定（既存は守られる）", "hamu", f"select public.set_my_profile_image('avatar','{H3}')", prof(HAMU),
     both(err, eq(f"{H1}|null")), pre=HAMU_HAS_AVATAR)
case("C", "アイコン用の画像を背景に設定", "hamu", f"select public.set_my_profile_image('header','{H2}')", prof(HAMU), both(err, eq("null|null")), pre=obj(H2))
case("C", "不明な種類", "hamu", f"select public.set_my_profile_image('admin','{H2}')", prof(HAMU), both(err, eq("null|null")), pre=obj(H2))
case("C", "利用停止中に設定", "hamu", f"select public.set_my_profile_image('avatar','{H2}')", prof(HAMU), both(err, eq("null|null")),
     pre=f"{obj(H2)}; update public.profiles set is_banned=true where id='{HAMU}'")
case("C", "未ログインで設定", "anon", f"select public.set_my_profile_image('avatar','{H2}')", prof(HAMU), both(err, eq("null|null")), pre=obj(H2))
case("C", "profiles の画像列を直接書き換え（自分）", "hamu", f"update public.profiles set avatar_path='{H2}' where id='{HAMU}'", prof(HAMU),
     both(err, eq("null|null")), pre=obj(H2))
case("C", "profiles の画像列を直接書き換え（Ryo）", "hamu", f"update public.profiles set avatar_path=null where id='{RYO}'", prof(RYO),
     both(err, eq(f"{R1}|null")), pre=f"{obj(R1)}; update public.profiles set avatar_path='{R1}' where id='{RYO}'")
case("C", "Ryoの表示名を書き換え", "hamu", f"update public.profiles set display_name='乗っ取り' where id='{RYO}'",
     f"select display_name from public.profiles where id='{RYO}'", eq("NOCTERA Ryo"))
case("C", "自分の表示名を変更（従来どおり可）", "hamu", f"update public.profiles set display_name='ハム' where id='{HAMU}'",
     f"select display_name from public.profiles where id='{HAMU}'", eq("ハム"))
case("C", "is_admin を変更（従来どおり不可）", "hamu", f"update public.profiles set is_admin=true where id='{HAMU}'",
     f"select is_admin from public.profiles where id='{HAMU}'", both(err, eq("f")))

print("\n=== D. 公開API（public_artist_profiles）で非公開情報が漏れないか ===")
SETBOTH = (f"{obj(R1)};{obj(H1)}; update public.profiles set avatar_path='{R1}' where id='{RYO}';"
           f" update public.profiles set avatar_path='{H1}' where id='{HAMU}'")
case("D", "返る列はアーティストID・アイコン・背景の3つだけ", "anon",
     "select pg_get_function_result('public.public_artist_profiles(uuid[])'::regprocedure)", "select 1",
     lambda a, v: a == "TABLE(artist_id uuid, avatar_path text, header_path text)")
case("D", "公開曲のあるRyoだけ返り、公開曲のないハムは返らない", "anon",
     f"select count(*)||':'||string_agg(avatar_path,',') from public.public_artist_profiles(array[{A_RYO},{A_HAMU}])", "select 1",
     lambda a, v: a == f"1:{R1}", pre=SETBOTH)
case("D", "利用停止中の会員の画像は返らない", "anon",
     f"select count(*) from public.public_artist_profiles(array[{A_RYO}])", "select 1", lambda a, v: a == "0",
     pre=f"{SETBOTH}; update public.profiles set is_banned=true where id='{RYO}'")
case("D", "201個目以降のIDは無視（大量指定で負荷をかけられない）", "anon",
     f"select count(*) from public.public_artist_profiles(array(select gen_random_uuid() from generate_series(1,200)) || {A_RYO})", "select 1",
     lambda a, v: a == "0", pre=SETBOTH)
case("D", "200個目までなら返る", "anon",
     f"select count(*) from public.public_artist_profiles(array(select gen_random_uuid() from generate_series(1,199)) || {A_RYO})", "select 1",
     lambda a, v: a == "1", pre=SETBOTH)
case("D", "未ログインで profiles を直接読む", "anon", "select count(*) from public.profiles", "select 1", err)
case("D", "会員が他人の profiles（画像・表示名）を読む", "hamu", f"select count(*) from public.profiles where id='{RYO}'", "select 1", lambda a, v: a == "0")
case("D", "変更履歴を直接読む", "hamu", "select count(*) from aimuse_private.artist_name_history", "select 1", err)

print("\n=== E. アーティスト名の変更 ===")
trk = lambda uid: f"select string_agg(distinct artist, ',') from public.tracks where user_id='{uid}'"
art = lambda uid: f"select name from public.artists where user_id='{uid}'"
hist = f"select count(*)||':'||coalesce(string_agg(old_name||'>'||new_name||':'||by_admin, ','),'') from aimuse_private.artist_name_history"
case("E", "自分のアーティスト名を変更→曲の表示名・履歴も更新", "hamu", f"select public.rename_my_artist({A_HAMU}, '  ハム  スター ')",
     f"{art(HAMU)}; {trk(HAMU)}; {hist}", lambda a, v: a == "ハム スター" and v.splitlines() == ["ハム スター", "ハム スター", "1:ハムハム>ハム スター:false"])
case("E", "Ryoのアーティスト名を変更", "hamu", f"select public.rename_my_artist({A_RYO}, 'ハム')", f"{art(RYO)}; {hist}",
     lambda a, v: "ERROR" in a and v.splitlines() == ["NOCTERA", "0:"])
for nm in ("NOCTERA", "ｎｏｃｔｅｒａ", "Noc Tera", "NOCTERA　"):
    case("E", f"他の会員の名前に変更（なりすまし）：{nm!r}", "hamu", f"select public.rename_my_artist({A_HAMU}, '{nm}')", art(HAMU), both(err, eq("ハムハム")))
for nm in ("AIMUSE公式", "ＡＩＭＵＳＥ", "運営スタッフ", "admin"):
    case("E", f"禁止語：{nm}", "hamu", f"select public.rename_my_artist({A_HAMU}, '{nm}')", art(HAMU), both(err, eq("ハムハム")))
for nm, label in (("''", "空"), ("'   '", "空白のみ"), ("'" + "あ" * 41 + "'", "41文字"), ("'ab' || chr(7) || 'c'", "制御文字"),
                  ("'NOC' || chr(8203) || 'TERA'", "ゼロ幅スペース入り"), ("'ab' || chr(8238) || 'c'", "文字の向きを反転する記号"), ("'ab' || chr(65279) || 'c'", "BOM")):
    case("E", f"不正な名前：{label}", "hamu", f"select public.rename_my_artist({A_HAMU}, {nm})", art(HAMU), both(err, eq("ハムハム")))
case("E", "改行は空白に整えて受け付ける", "hamu", f"select public.rename_my_artist({A_HAMU}, 'ab' || chr(10) || 'c')", art(HAMU), eq("ab c"))
case("E", "24時間で4回目の変更", "hamu", f"select public.rename_my_artist({A_HAMU}, '四回目')", art(HAMU), both(err, eq("ハムハム")),
     pre=f"insert into aimuse_private.artist_name_history (artist_id,user_id,changed_by,old_name,new_name) select {A_HAMU},'{HAMU}','{HAMU}','a','b' from generate_series(1,3)")
case("E", "25時間前の3回は数えない", "hamu", f"select public.rename_my_artist({A_HAMU}, '再開')", art(HAMU), eq("再開"),
     pre=f"insert into aimuse_private.artist_name_history (artist_id,user_id,changed_by,old_name,new_name,changed_at) select {A_HAMU},'{HAMU}','{HAMU}','a','b',now()-interval '25 hours' from generate_series(1,3)")
case("E", "利用停止中に変更", "hamu", f"select public.rename_my_artist({A_HAMU}, '停止中')", art(HAMU), both(err, eq("ハムハム")),
     pre=f"update public.profiles set is_banned=true where id='{HAMU}'")
case("E", "未ログインで変更", "anon", f"select public.rename_my_artist({A_RYO}, 'x')", art(RYO), both(err, eq("NOCTERA")))
case("E", "artists.name を直接書き換え", "hamu", f"update public.artists set name='直接' where user_id='{HAMU}'", art(HAMU), both(err, eq("ハムハム")))
case("E", "自己紹介（bio）を変更（従来どおり本人のみ可）", "hamu", f"update public.artists set bio='よろしく' where user_id='{HAMU}'",
     f"select bio from public.artists where user_id='{HAMU}'", eq("よろしく"))
case("E", "Ryoの自己紹介を変更", "hamu", f"update public.artists set bio='乗っ取り' where user_id='{RYO}'",
     f"select bio from public.artists where user_id='{RYO}'", eq(""))
case("E", "変更後も未ログインで公開曲のアーティスト名が読める（BOOSTの宣伝ページ用）", "anon",
     "select artist from public.tracks where status='public' and title='おぼろ月'", "select 1", lambda a, v: a == "ノクテラ",
     pre=f"update public.artists set name='ノクテラ' where user_id='{RYO}'; update public.tracks set artist='ノクテラ' where user_id='{RYO}'")

print("\n=== F. 管理者用の関数 ===")
for fn in (f"admin_reset_profile_image({A_RYO},'avatar')", f"admin_set_artist_name({A_RYO},'x')", "admin_artist_name_history(10)"):
    case("F", f"一般会員が {fn.split('(')[0]}", "hamu", f"select * from public.{fn}", prof(RYO), both(err, eq(f"{R1}|null")),
         pre=f"{obj(R1)}; update public.profiles set avatar_path='{R1}' where id='{RYO}'")
    case("F", f"未ログインで {fn.split('(')[0]}", "anon", f"select * from public.{fn}", "select 1", err)
case("F", "管理者がハムのアイコンを初期化（古い場所が返る）", "ryo", f"select public.admin_reset_profile_image({A_HAMU},'avatar')", prof(HAMU),
     lambda a, v: a == H1 and v == "null|null", pre=HAMU_HAS_AVATAR)
case("F", "管理者が初期化後にハムの画像ファイルを削除", "ryo", f"delete from storage.objects where name='{H1}'", cnt(H1), eq("0"), pre=obj(H1))
case("F", "管理者がアーティスト名を是正→履歴に管理者として残る", "ryo", f"select public.admin_set_artist_name({A_HAMU},'ハムハム（是正）')",
     f"{art(HAMU)}; {hist}", lambda a, v: v.splitlines() == ["ハムハム（是正）", "1:ハムハム>ハムハム（是正）:true"])
case("F", "管理者が履歴を見る", "ryo", "select count(*) from public.admin_artist_name_history(10)", "select 1", lambda a, v: a == "2",
     pre=f"insert into aimuse_private.artist_name_history (artist_id,user_id,changed_by,old_name,new_name) select {A_HAMU},'{HAMU}','{HAMU}','a','b' from generate_series(1,2)")

fails = [r for r in R if not r[2]]
print(f"\n合計 {len(R)} 件 / 不合格 {len(fails)} 件")
for f in fails: print("  FAIL:", f)
sys.exit(1 if fails else 0)
