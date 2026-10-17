#!/usr/bin/env python3
"""Server-side permission tests for AIMUSE.
Each case runs the statement the way Supabase's API (PostgREST) runs it:
  SET ROLE authenticated/anon + request.jwt.claims = the user's JWT.
Then, still inside the same transaction, the real DB state is checked as
superuser, and everything is rolled back so cases are independent."""
import subprocess, json, sys

DB = ["psql", "-h", "/home/pgtest/pg", "-p", "55432", "-U", "postgres", "-d", "aimuse", "-X", "-v", "ON_ERROR_STOP=0", "-v", "ON_ERROR_ROLLBACK=on"]
RYO  = "11111111-1111-4111-8111-111111111111"
HAMU = "22222222-2222-4222-8222-222222222222"
T_PUB, T_PEND, T_HID, T_HAMU = ("aaaaaaaa-0000-4000-8000-00000000000%d" % i for i in (1, 2, 3, 4))
REPORT = "bbbbbbbb-0000-4000-8000-000000000001"

def claims(who):
    if who == "anon": return ("anon", {"role": "anon"})
    uid = {"hamu": HAMU, "ryo": RYO}[who]
    return ("authenticated", {"sub": uid, "role": "authenticated", "email": who + "@example.com"})

def run(who, stmt, verify):
    role, c = claims(who)
    script = f"""begin;
set local role {role};
set local request.jwt.claims = '{json.dumps(c)}';
\\echo ===ATTACK===
{stmt};
\\echo ===VERIFY===
reset role;
{verify};
rollback;
"""
    p = subprocess.run(DB + ["-At"], input=script, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out = p.stdout
    attack = out.split("===ATTACK===")[1].split("===VERIFY===")[0].strip()
    verify_out = out.split("===VERIFY===")[1] if "===VERIFY===" in out else ""
    verify_out = "\n".join(l for l in verify_out.strip().splitlines() if l.strip() not in ("RESET", "ROLLBACK") and not l.startswith(("INSERT ","UPDATE ","DELETE "))).strip()
    return attack, verify_out

results = []
def case(no, name, who, stmt, verify, ok):
    attack, state = run(who, stmt, verify)
    passed = ok(attack, state)
    short = " ".join(attack.split())[:110]
    results.append((no, name, who, passed))
    print(f"[{'PASS' if passed else 'FAIL'}] {no} {name} ({who})\n        attack → {short}\n        DB     → {state}")

err  = lambda a, s: "ERROR" in a
def unchanged(expected):  # attack had no effect: DB value is what it was
    return lambda a, s: s == expected
st = lambda tid: f"select status from public.tracks where id='{tid}'"

print("=== 3. 他人の投稿の承認・却下 ===")
case(3, "他人の審査待ちを承認", "hamu", f"update public.tracks set status='public', approved_at='x' where id='{T_PEND}'", st(T_PEND), unchanged("pending"))
case(3, "他人の審査待ちを却下", "hamu", f"update public.tracks set status='rejected', reject_reason='x' where id='{T_PEND}'", st(T_PEND), unchanged("pending"))
case(3, "自分の投稿を自分で承認（審査すり抜け）", "hamu", f"update public.tracks set status='public' where id='{T_HAMU}'", st(T_HAMU), unchanged("pending"))
case(3, "最初から公開状態で投稿", "hamu",
     f"insert into public.tracks (id,user_id,title,artist,genre,tool,tool_name,audio_path,status) values ('cccccccc-0000-4000-8000-000000000001','{HAMU}','x','x','J-POP','Suno','Suno','{HAMU}/cccccccc-0000-4000-8000-000000000001.mp3','public')",
     "select coalesce((select status from public.tracks where id='cccccccc-0000-4000-8000-000000000001'),'none')", lambda a, s: s in ("none", "pending"))
case(3, "審査済み日時・再生数を偽装して投稿", "hamu",
     f"insert into public.tracks (id,user_id,title,artist,genre,tool,tool_name,audio_path,approved_at,plays) values ('cccccccc-0000-4000-8000-000000000002','{HAMU}','x','x','J-POP','Suno','Suno','{HAMU}/cccccccc-0000-4000-8000-000000000002.mp3','2026/01/01',0)",
     "select coalesce((select status||'|'||coalesce(approved_at,'null') from public.tracks where id='cccccccc-0000-4000-8000-000000000002'),'none')", lambda a, s: s in ("none", "pending|null"))
case(3, "他人名義（Ryo）で投稿", "hamu",
     f"insert into public.tracks (id,user_id,title,artist,genre,tool,tool_name,audio_path) values ('cccccccc-0000-4000-8000-000000000003','{RYO}','x','x','J-POP','Suno','Suno','{RYO}/cccccccc-0000-4000-8000-000000000003.mp3')",
     "select count(*) from public.tracks where id='cccccccc-0000-4000-8000-000000000003'", unchanged("0"))

print("\n=== 4. 他人の楽曲の公開・非公開 ===")
case(4, "他人の公開曲を非公開に", "hamu", f"update public.tracks set status='hidden' where id='{T_PUB}'", st(T_PUB), unchanged("public"))
case(4, "他人の非公開曲を公開に", "hamu", f"update public.tracks set status='public' where id='{T_HID}'", st(T_HID), unchanged("hidden"))
case(4, "他人の曲の題名・再生数を改ざん", "hamu", f"update public.tracks set title='乗っ取り', plays=999999 where id='{T_PUB}'",
     f"select title||'|'||plays from public.tracks where id='{T_PUB}'", unchanged("おぼろ月|0"))
case(4, "自分の非公開化された曲を勝手に公開へ戻す", "hamu", f"update public.tracks set status='public' where id='{T_HAMU}'", st(T_HAMU), unchanged("pending"))

print("\n=== 5. 他人の楽曲の削除 ===")
for tid, label in ((T_PUB, "公開曲"), (T_HID, "非公開曲"), (T_PEND, "審査待ち")):
    case(5, f"他人の{label}を削除", "hamu", f"delete from public.tracks where id='{tid}'",
         f"select count(*) from public.tracks where id='{tid}'", unchanged("1"))
case(5, "他人の音源ファイルを削除（Storage）", "hamu", f"delete from storage.objects where name like '{RYO}/%'",
     f"select count(*) from storage.objects where name like '{RYO}/%'", unchanged("3"))
case(5, "他人のファイルを上書きアップロード", "hamu", f"insert into storage.objects (bucket_id,name) values ('audio','{RYO}/aaaaaaaa-0000-4000-8000-000000000009.mp3')",
     f"select count(*) from storage.objects where name='{RYO}/aaaaaaaa-0000-4000-8000-000000000009.mp3'", unchanged("0"))
case(5, "他人のアーティストを削除", "hamu", f"delete from public.artists where user_id='{RYO}'",
     f"select count(*) from public.artists where user_id='{RYO}'", unchanged("1"))
case(5, "他人のアーティスト紹介文を改ざん", "hamu", f"update public.artists set bio='乗っ取り' where user_id='{RYO}'",
     f"select bio from public.artists where user_id='{RYO}'", unchanged(""))

print("\n=== 6. 通報の対応 ===")
case(6, "通報一覧を読む", "hamu", "select count(*) from public.reports", "select 'n/a'", lambda a, s: a.strip() == "0")
case(6, "通報を対応済みにする", "hamu", f"update public.reports set status='resolved', action='keep' where id='{REPORT}'",
     f"select status from public.reports where id='{REPORT}'", unchanged("open"))
case(6, "通報を削除する", "hamu", f"delete from public.reports where id='{REPORT}'",
     f"select count(*) from public.reports where id='{REPORT}'", unchanged("1"))
case(6, "対応済みの状態で通報を作る", "hamu",
     f"insert into public.reports (song_id,reason,reporter_id,status,action) values ('{T_PUB}','x','{HAMU}','resolved','hide')",
     "select count(*) from public.reports where status='resolved'", unchanged("0"))

print("\n=== 7. 管理者用の関数（RPC）を直接呼ぶ ===")
for fn in ("admin_stats()", "admin_list_members(50,0)", f"admin_set_member_ban('{RYO}',true)", f"admin_set_member_ban('{HAMU}',false)",
           "admin_orphan_files(1)", "admin_list_deleted_tracks()", "admin_restore_track(gen_random_uuid())", "admin_check_request_headers()"):
    case(7, f"RPC {fn.split('(')[0]}", "hamu", f"select public.{fn}", "select 'n/a'", err)
case(7, "RPC 他人の曲の再生時間を書き換え", "hamu", f"select public.set_duration_if_missing('{T_PUB}',123)",
     f"select duration from public.tracks where id='{T_PUB}'", unchanged("0"))
case(7, "未ログインで管理者RPC", "anon", "select public.admin_stats()", "select 'n/a'", err)
case(7, "未ログインで曲を非公開に", "anon", f"update public.tracks set status='hidden' where id='{T_PUB}'", st(T_PUB), unchanged("public"))
case(7, "内部の関数を直接呼ぶ（media_path_in_use）", "hamu", f"select public.media_path_in_use('audio','x')", "select 'n/a'", err)

print("\n=== 8. is_admin の自己昇格 ===")
case(8, "自分の is_admin を true に", "hamu", f"update public.profiles set is_admin=true where id='{HAMU}'",
     f"select is_admin from public.profiles where id='{HAMU}'", unchanged("f"))
case(8, "表示名の変更に紛れて is_admin も変更", "hamu", f"update public.profiles set display_name='ハム', is_admin=true where id='{HAMU}'",
     f"select is_admin from public.profiles where id='{HAMU}'", unchanged("f"))
case(8, "プロフィールを is_admin=true で新規作成", "hamu", f"insert into public.profiles (id,is_admin) values ('{HAMU}',true)",
     f"select count(*)||'|'||bool_or(is_admin) from public.profiles where id='{HAMU}'", unchanged("1|false"))
case(8, "管理者Ryoの権限を外す", "hamu", f"update public.profiles set is_admin=false where id='{RYO}'",
     f"select is_admin from public.profiles where id='{RYO}'", unchanged("t"))
case(8, "管理者の表示名を書き換え", "hamu", f"update public.profiles set display_name='乗っ取り' where id='{RYO}'",
     f"select display_name from public.profiles where id='{RYO}'", unchanged("NOCTERA Ryo"))
case(8, "自分の利用停止フラグを操作", "hamu", f"update public.profiles set is_banned=true where id='{HAMU}'",
     f"select is_banned from public.profiles where id='{HAMU}'", unchanged("f"))
case(8, "表示名を「AIMUSE運営」に（なりすまし）", "hamu", f"update public.profiles set display_name='AIMUSE運営' where id='{HAMU}'",
     f"select display_name from public.profiles where id='{HAMU}'", unchanged("ハムハム"))

# 新規登録時（Supabase Authが auth.users に行を作る）に user_metadata で管理者を名乗る
case(8, "新規登録時に user_metadata で is_admin=true を送る", "anon", "select 1",
     "insert into auth.users (id,email,email_confirmed_at,raw_user_meta_data) values ('44444444-4444-4444-8444-444444444444','evil@example.com',now(),'{\"is_admin\":true,\"display_name\":\"AIMUSE運営\"}'); "
     "select is_admin::text||'|'||display_name as r from public.profiles where id='44444444-4444-4444-8444-444444444444'",
     unchanged("false|会員"))

print("\n=== 9. 見えてはいけない情報の取得 ===")
case(9, "他人のプロフィール", "hamu", f"select count(*) from public.profiles where id<>'{HAMU}'", "select 'n/a'", lambda a, s: a.strip() == "0")
case(9, "会員のメールアドレス（auth.users）", "hamu", "select email from auth.users", "select 'n/a'", err)
case(9, "他人の審査待ち・非公開の曲", "hamu", f"select count(*) from public.tracks where user_id='{RYO}' and status<>'public'", "select 'n/a'", lambda a, s: a.strip() == "0")
case(9, "他人の非公開音源のファイル（署名URL発行）", "hamu", f"select count(*) from storage.objects where name in ('{RYO}/{T_PEND}.mp3','{RYO}/{T_HID}.mp3')", "select 'n/a'", lambda a, s: a.strip() == "0")
case(9, "他人のお気に入り・フォロー", "hamu", f"select (select count(*) from public.favorites where user_id<>'{HAMU}')+(select count(*) from public.follows where user_id<>'{HAMU}')", "select 'n/a'", lambda a, s: a.strip() == "0")
case(9, "削除記録（非公開スキーマ）", "hamu", "select count(*) from aimuse_private.track_deletions", "select 'n/a'", err)
case(9, "非公開設定（再生数の秘密の値）", "hamu", "select value from aimuse_private.settings", "select 'n/a'", err)
case(9, "再生記録（play_events）", "hamu", "select count(*) from public.play_events", "select 'n/a'", lambda a, s: "ERROR" in a or a.strip() == "0")
case(9, "未ログインでプロフィール", "anon", "select count(*) from public.profiles", "select 'n/a'", err)
case(9, "未ログインで審査待ちの曲", "anon", "select count(*) from public.tracks where status<>'public'", "select 'n/a'", lambda a, s: a.strip() == "0")

print("\n=== 10. 管理者 NOCTERA Ryo の正常な操作 ===")
case(10, "承認", "ryo", f"update public.tracks set status='public' where id='{T_HAMU}'", st(T_HAMU), unchanged("public"))
case(10, "却下", "ryo", f"update public.tracks set status='rejected', reject_reason='x' where id='{T_HAMU}'", st(T_HAMU), unchanged("rejected"))
case(10, "公開→非公開", "ryo", f"update public.tracks set status='hidden' where id='{T_PUB}'", st(T_PUB), unchanged("hidden"))
case(10, "非公開→公開", "ryo", f"update public.tracks set status='public' where id='{T_HID}'", st(T_HID), unchanged("public"))
case(10, "非公開曲の削除", "ryo", f"delete from public.tracks where id='{T_HID}'", f"select count(*) from public.tracks where id='{T_HID}'", unchanged("0"))
case(10, "公開中の曲は直接削除できない（安全装置）", "ryo", f"delete from public.tracks where id='{T_PUB}'", f"select count(*) from public.tracks where id='{T_PUB}'", unchanged("1"))
case(10, "通報を読む", "ryo", "select count(*) from public.reports", "select 'n/a'", lambda a, s: a.strip() == "1")
case(10, "通報を対応済みに", "ryo", f"update public.reports set status='resolved', action='keep' where id='{REPORT}'", f"select status from public.reports where id='{REPORT}'", unchanged("resolved"))
case(10, "他人の審査待ちの曲を見る", "ryo", f"select count(*) from public.tracks where user_id='{HAMU}'", "select 'n/a'", lambda a, s: a.strip() == "1")
case(10, "RPC admin_stats", "ryo", "select (public.admin_stats()->>'tracks_pending')", "select 'n/a'", lambda a, s: "ERROR" not in a)
case(10, "RPC admin_list_members", "ryo", "select count(*) from public.admin_list_members(50,0)", "select 'n/a'", lambda a, s: a.strip() == "2")
case(10, "自分の is_admin もアプリからは変更不可", "ryo", f"update public.profiles set is_admin=false where id='{RYO}'", f"select is_admin from public.profiles where id='{RYO}'", unchanged("t"))

fails = [r for r in results if not r[3]]
print(f"\n合計 {len(results)} 件 / 不合格 {len(fails)} 件")
for f in fails: print("  FAIL:", f)
sys.exit(1 if fails else 0)
