# v1.14 歌詞の同期（各行の歌い出しの時刻）のテスト
# 使い方：python3 tests/db/test_v114.py [ポート...]   （既定：PostgreSQL 17 = 55417、15 = 55415。テンプレート prod111 = v1.11 まで適用済み）
import subprocess, json, sys, os
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MIG = open(os.path.join(ROOT, "supabase/migration_v1_14_lyrics_sync.sql"), encoding="utf-8").read()
RB = open(os.path.join(ROOT, "supabase/rollback/rollback_v1_14.sql"), encoding="utf-8").read()
PORTS = [int(p) for p in sys.argv[1:]] or [55417, 55415]
U = {k: "10000000-0000-4000-8000-%012d" % i for k, i in [("admin", 1), ("a", 2), ("b", 3), ("w", 4), ("unconf", 17), ("banned", 50)]}
TA = "20000000-0000-4000-8000-000000000001"     # a の公開中の曲
TP = "20000000-0000-4000-8000-000000000003"     # w の審査待ちの曲
LYR = ["[Verse 1]", "あの夜は　少し寒くて", "", "君と歩いた", "【サビ】", "おぼろ月", "（ハミング）"]
R = []
def ok(n, c, i=""): R.append(bool(c)); print(f"  [{'PASS' if c else 'FAIL'}] {n}  {str(i)[:150]}")
DATA = """select md5(string_agg(x, '|' order by x)) from (select 't'||t::text x from public.tracks t union all select 'p'||t::text from public.profiles t
  union all select 'f'||t::text from public.favorites t union all select 'w'||t::text from public.follows t union all select 'a'||t::text from public.artists t
  union all select 'l'||t::text from public.playlists t union all select 'lt'||t::text from public.playlist_tracks t union all select 'o'||t::text from storage.objects t) s"""
for port in PORTS:
    def q(sql, who="postgres", db="t114"):
        if who != "postgres":
            role, c = ("anon", {"role": "anon"}) if who == "anon" else ("authenticated", {"sub": U[who], "role": "authenticated"})
            sql = f"begin; set local role {role}; set local request.jwt.claims='{json.dumps(c)}';\n{sql};\ncommit;"
        r = subprocess.run(["psql", "-h", "/opt/pgx", "-p", str(port), "-U", "postgres", "-X", "-At", "-q", "-d", db, "-c", sql], capture_output=True, text=True)
        return r.stdout.strip(), next((l for l in r.stderr.splitlines() if "ERROR" in l), "")
    save = lambda who, tid, lines: q(f"select public.lyrics_sync_save('{tid}', '{json.dumps(lines, ensure_ascii=False)}'::jsonb)->>'count'", who)
    get = lambda who, tid: q(f"select coalesce(json_agg(json_build_object('lines', lines, 'source', source, 'stale', stale)), '[]') from public.lyrics_sync_get('{tid}')", who)
    print("== port", port, q("show server_version", db="postgres")[0])
    q("drop database if exists t114", db="postgres"); q("create database t114 template prod111", db="postgres")
    lit = "array[" + ",".join("'" + l.replace("'", "''") + "'" for l in LYR) + "]::text[]"
    q(f"update public.tracks set lyrics = {lit}, duration = 258 where id in ('{TA}', '{TP}')")
    d0 = q(DATA)[0]
    o, e = q(MIG.replace("\n", "\r\n")); ok("1 適用できる（本番と同じ CRLF の形）", not e, e)
    o, e = q(MIG); ok("1 2回目の適用も成功", not e, e)
    ok("1 既存データ（曲・歌詞・プロフィール・お気に入り・フォロー・アーティスト・プレイリスト・ファイル）は変わらない", q(DATA)[0] == d0)
    # 2. 権限
    o, e = q("select count(*) from public.track_lyrics_sync", "anon"); o2, e2 = q("select count(*) from public.track_lyrics_sync", "a")
    ok("2 表は未ログイン・会員から直接読めない", "permission denied" in e and "permission denied" in e2, (e[:50], e2[:50]))
    o, e = q(f"insert into public.track_lyrics_sync (track_id, lyrics_hash) values ('{TA}', 'x')", "a"); ok("2 表へ直接書き込めない", "permission denied" in e, e[:60])
    o, e = save("anon", TA, []); ok("2 未ログインは保存できない", "permission denied" in e, e[:60])
    # 3. 保存（投稿者本人）
    L = [{"i": 1, "t": 12.345}, {"i": 3, "t": 20, "e": 25.5}, {"i": 5, "t": 40.1}, {"i": 6, "t": 44}]
    o, e = save("a", TA, L); ok("3 投稿者本人は保存できる", o == "4" and not e, o or e)
    o, e = get("anon", TA); g = json.loads(o or "[]")
    ok("3 公開中の曲は未ログインでも読める（時刻は0.01秒単位に丸める）", g and g[0]["lines"] == [{"i": 1, "t": 12.35}, {"i": 3, "t": 20, "e": 25.5}, {"i": 5, "t": 40.1}, {"i": 6, "t": 44}] and g[0]["stale"] is False and g[0]["source"] == "manual", g)
    o, e = save("b", TA, L); ok("3 他の会員は保存できない", "NOT_ALLOWED" in e, e[:80])
    o, e = save("admin", TA, L[:2]); ok("3 管理者は保存できる", o == "2", o or e)
    q(f"update auth.users set email_confirmed_at = null where id = '{U['a']}'")
    o, e = save("a", TA, L); ok("3 メール未確認の会員は保存できない", "NOT_ALLOWED" in e, e[:60])
    q(f"update auth.users set email_confirmed_at = now() where id = '{U['a']}'")
    q(f"update public.profiles set is_banned = true where id = '{U['a']}'")
    o, e = save("a", TA, L); ok("3 利用停止中の会員は保存できない", "NOT_ALLOWED" in e, e[:60])
    q(f"update public.profiles set is_banned = false where id = '{U['a']}'")
    o, e = save("a", "20000000-0000-4000-8000-0000000009ff", L); ok("3 存在しない曲は保存できない", "NOT_FOUND" in e, e[:60])
    # 4. 形式の確認
    bad = [("文字列の時刻", [{"i": 1, "t": "12"}]), ("時刻なし", [{"i": 1}]), ("負の時刻", [{"i": 1, "t": -1}]), ("曲の長さを大きく超える", [{"i": 1, "t": 300}]),
           ("見出しの行", [{"i": 0, "t": 1}]), ("【】の見出し", [{"i": 4, "t": 30}]), ("空行", [{"i": 2, "t": 15}]), ("範囲外の行", [{"i": 99, "t": 1}]),
           ("行番号の逆順", [{"i": 3, "t": 20}, {"i": 1, "t": 30}]), ("時刻の逆戻り", [{"i": 1, "t": 30}, {"i": 3, "t": 20}]),
           ("歌い終わりが歌い出しより前", [{"i": 1, "t": 30, "e": 29}]), ("次の行が前の行の歌い終わりより前", [{"i": 1, "t": 10, "e": 25}, {"i": 3, "t": 20}]),
           ("余計な項目", [{"i": 1, "t": 10, "x": 1}]), ("小数の行番号", [{"i": 1.5, "t": 10}]), ("配列でない", {"i": 1})]
    before = get("a", TA)[0]
    for name, b in bad:
        o, e = q(f"select public.lyrics_sync_save('{TA}', '{json.dumps(b, ensure_ascii=False)}'::jsonb)", "a")
        ok(f"4 拒否：{name}", "BAD_DATA" in e, e[:90])
    ok("4 拒否したときは保存済みの内容が変わらない", get("a", TA)[0] == before)
    o, e = save("a", TA, [{"i": 1, "t": 10}, {"i": 3, "t": 10}]); ok("4 同じ時刻の行は可", o == "2", o or e)
    o, e = save("a", TA, [{"i": 6, "t": 50}]); ok("4 （ハミング）など括弧の行は歌詞として時刻を付けられる", o == "1", o or e)
    # 5. 見える範囲
    o, e = save("w", TP, [{"i": 1, "t": 5}]); ok("5 審査待ちの曲も本人は保存できる", o == "1", o or e)
    ok("5 審査待ちの曲の時刻は、本人と管理者だけが読める", json.loads(get("w", TP)[0])[0]["lines"] and json.loads(get("admin", TP)[0]) and json.loads(get("b", TP)[0]) == [] and json.loads(get("anon", TP)[0]) == [])
    # 6. 歌詞が変わったら要確認
    q(f"update public.tracks set lyrics = array['新しい歌詞'] where id = '{TA}'")
    ok("6 歌詞が変わると stale = true（要確認）", json.loads(get("anon", TA)[0])[0]["stale"] is True)
    o, e = save("a", TA, [{"i": 0, "t": 3}]); ok("6 保存し直すと stale = false", json.loads(get("anon", TA)[0])[0]["stale"] is False, o or e)
    o, e = save("a", TA, []); ok("6 空の一覧で保存すると同期なしに戻る（歌詞はそのまま）", o == "0" and json.loads(get("anon", TA)[0])[0]["lines"] == [] and q(f"select lyrics[1] from public.tracks where id='{TA}'")[0] == "新しい歌詞", o or e)
    # 7. 退会手続き中・削除
    q(f"insert into aimuse_private.account_deletions (user_id, status, requested_at, purge_after) values ('{U['w']}', 'pending', now(), now() + interval '30 days')")
    o, e = save("w", TP, [{"i": 1, "t": 6}]); ok("7 退会手続き中の会員は保存できない", "NOT_ALLOWED" in e, e[:60])
    q(f"delete from aimuse_private.account_deletions where user_id = '{U['w']}'")
    q(f"delete from public.tracks where id = '{TP}'")
    ok("7 曲を削除すると、その曲の時刻も消える", q(f"select count(*) from public.track_lyrics_sync where track_id = '{TP}'")[0] == "0")
    # 8. 元に戻す
    o, e = q(RB); ok("8 元に戻せる（表・関数が無くなる）", not e and q("select to_regclass('public.track_lyrics_sync') is null and to_regprocedure('public.lyrics_sync_save(uuid,jsonb)') is null")[0] == "t", e)
    o, e = q(MIG); ok("8 再適用できる", not e, e)
    q("drop database if exists t114", db="postgres")
print(f"合計 {len(R)} 件 / 不合格 {R.count(False)} 件")
sys.exit(1 if False in R else 0)
