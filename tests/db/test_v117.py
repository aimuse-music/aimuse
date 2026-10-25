# v1.17 アクセス解析：再生数が今までと同じ・管理者の除外・個人情報を残さない・水増し対策・権限・集計・90日削除・元に戻す
# 使い方：python3 tests/db/test_v117.py [ポート...]（既定：55416。テンプレート prod116 = v1.16 まで適用済み）
import subprocess, json, sys, os, uuid
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
rd = lambda p: open(os.path.join(ROOT, p), encoding="utf-8").read()
M17, RB = rd("supabase/migration_v1_17_analytics.sql"), rd("supabase/rollback/rollback_v1_17.sql")
PORTS = [int(p) for p in sys.argv[1:]] or [55416]
U = {"admin": "11111111-1111-4111-8111-111111111111", "hamu": "22222222-2222-4222-8222-222222222222", "mike": "33333333-3333-4333-8333-333333333333"}
PUB, PUB2, HID, PEND = "aaaaaaaa-0000-4000-8000-000000000001", "aaaaaaaa-0000-4000-8000-000000000005", "aaaaaaaa-0000-4000-8000-000000000003", "aaaaaaaa-0000-4000-8000-000000000002"
R = []
def ok(n, c, i=""): R.append(bool(c)); print(f"  [{'PASS' if c else 'FAIL'}] {n}  {str(i)[:160]}")
V = lambda: str(uuid.uuid4())

for port in PORTS:
    def q(sql, who="postgres", db="t117", ip=None):
        if who != "postgres":
            if who == "anon": role, c = "anon", {"role": "anon"}
            else: role, c = "authenticated", {"sub": U[who], "role": "authenticated"}
            h = json.dumps({"cf-connecting-ip": ip} if ip else {})
            sql = f"begin; set local role {role}; set local request.jwt.claims='{json.dumps(c)}'; set local request.headers='{h}';\n{sql};\ncommit;"
        r = subprocess.run(["psql", "-h", "/opt/pgx", "-p", str(port), "-U", "postgres", "-X", "-At", "-q", "-d", db, "-c", sql], capture_output=True, text=True)
        return r.stdout.strip(), next((l for l in r.stderr.splitlines() if "ERROR" in l), "")
    v1 = lambda sql, **k: q(sql, **k)[0]
    track = lambda vid, page, who="anon", ip="198.51.100.7": q(f"select public.analytics_track('{vid}', '{page}')", who, ip=ip)
    nviews = lambda: int(v1("select count(*) from aimuse_private.analytics_views"))
    daily = lambda t: int(v1(f"select coalesce(sum(plays),0) from aimuse_private.analytics_plays_daily where track_id = '{t}'") or 0)
    plays = lambda t, db="t117": int(v1(f"select plays from public.tracks where id = '{t}'", db=db))
    print("== port", port, v1("show server_version", db="postgres"))
    for d in ("t117", "t117old"):
        q(f"drop database if exists {d}", db="postgres"); q(f"create database {d} template prod116", db="postgres")
    snap = "select md5(string_agg(x, '|' order by x)) from (select t::text x from public.tracks t union all select p::text from public.profiles p union all select e::text from public.play_events e union all select s::text from public.track_lyrics_sync s) z"
    inc_src = "select md5(replace(prosrc, E'\\r', '')) from pg_proc where oid = 'public.increment_plays(uuid)'::regprocedure"
    acl = "select proacl::text from pg_proc where oid = 'public.increment_plays(uuid)'::regprocedure"
    d0, src0, acl0 = v1(snap), v1(inc_src), v1(acl)

    # ---- 1. 適用
    o, e = q(M17.replace("\n", "\r\n")); o2, e2 = q(M17)
    ok("1 適用できる（CRLF）・2回目も成功", not e and not e2, e or e2)
    ok("1 適用してもデータ（楽曲・会員・再生記録・歌詞の同期）は変わらない", v1(snap) == d0)
    ok("1 increment_plays の実行権限は変わらない", v1(acl) == acl0, v1(acl))
    ok("1 初期状態：記録は0件・記録はオン・計測開始日あり", nviews() == 0 and v1("select value from aimuse_private.settings where key='analytics_enabled'") == "on" and v1("select value from aimuse_private.settings where key='analytics_started'") != "")

    # ---- 2. 再生数：今までの関数（t117old）と同じ結果になる
    seq = [("anon", "203.0.113.1", PUB), ("anon", "203.0.113.1", PUB), ("anon", "203.0.113.2", PUB), ("anon", None, PUB),
           ("anon", "203.0.113.1", PUB2), ("hamu", None, PUB), ("hamu", None, PUB), ("mike", "203.0.113.1", PUB),
           ("admin", None, PUB), ("anon", "203.0.113.3", HID), ("anon", "203.0.113.3", PEND), ("anon", "bad ip;", PUB),
           ("anon", "2001:db8::1", PUB), ("hamu", None, PUB2)]
    for who, ip, t in seq:
        for d in ("t117", "t117old"): q(f"select public.increment_plays('{t}')", who, db=d, ip=ip)
    same = all(plays(t) == plays(t, "t117old") for t in (PUB, PUB2, HID, PEND))
    pe = lambda d: v1("select count(*) || ':' || count(distinct viewer_key) from public.play_events", db=d)
    ok("2 increment_plays：14通りの再生で再生数・再生記録が今までと同じ", same and pe("t117") == pe("t117old"), f"{plays(PUB)}/{plays(PUB, 't117old')} {pe('t117')}/{pe('t117old')}")
    # 1時間に60回の上限も同じ
    many = ",".join(f"'{t}'" for t in v1("select string_agg(id::text, ',') from (select id from public.tracks where status='public' order by id limit 62) s").split(","))
    for d in ("t117", "t117old"): q(f"select public.increment_plays(id) from public.tracks where id in ({many})", "anon", db=d, ip="203.0.113.60")
    tot = lambda d: v1("select sum(plays) from public.tracks", db=d)
    ok("2 同じ人の上限（1時間に60回）も今までと同じ", tot("t117") == tot("t117old"), f"{tot('t117')} / {tot('t117old')}")
    # count_play は increment_plays と同じ判定（両方を呼んでも1時間に1回）
    p0 = plays(PUB2); q(f"select public.count_play('{PUB2}', '{V()}')", "anon", ip="203.0.113.70"); q(f"select public.increment_plays('{PUB2}')", "anon", ip="203.0.113.70"); q(f"select public.count_play('{PUB2}', null)", "anon", ip="203.0.113.70")
    ok("2 count_play と increment_plays は同じ判定（同じ人×同じ曲は1時間に1回）", plays(PUB2) == p0 + 1, plays(PUB2) - p0)
    o, e = q(f"select public.count_play('{HID}', '{V()}')", "anon", ip="203.0.113.71")
    ok("2 count_play：非公開の曲は数えない", plays(HID) == 0 and not e, e)

    # ---- 3. 日別の再生数（管理者・管理者の端末を除く）
    q("truncate aimuse_private.analytics_plays_daily")
    p0 = plays(PUB); q(f"select public.count_play('{PUB}', '{V()}')", "anon", ip="198.51.100.20")
    ok("3 未ログインの再生：公開の再生数と日別の再生数の両方に1", plays(PUB) == p0 + 1 and daily(PUB) == 1)
    q(f"select public.count_play('{PUB}', '{V()}')", "anon", ip="198.51.100.20")
    ok("3 同じ人の1時間以内の再生は日別にも数えない（二重計測なし）", plays(PUB) == p0 + 1 and daily(PUB) == 1)
    q("delete from public.play_events where viewer_key = 'u:" + U["admin"] + "'")
    q(f"select public.count_play('{PUB}', '{V()}')", "admin")
    ok("3 管理者（ログイン中）の再生：公開の再生数は今までどおり増え、日別には入らない", plays(PUB) == p0 + 2 and daily(PUB) == 1)
    q(f"select public.increment_plays('{PUB2}')", "admin")
    ok("3 古い版のアプリ（increment_plays）でも管理者の再生は日別に入らない", daily(PUB2) == 0)
    adm_vid = V(); q(f"select public.analytics_exclude_device('{adm_vid}')", "admin")
    q(f"select public.count_play('{PUB}', '{adm_vid}')", "anon", ip="198.51.100.21")
    ok("3 管理者としてログインした端末（ログアウト中）の再生は日別に入らない（公開の再生数は増える）", plays(PUB) == p0 + 3 and daily(PUB) == 1)
    q(f"select public.increment_plays('{PUB2}')", "mike")
    ok("3 古い版のアプリ（increment_plays）の会員の再生は日別にも入る", daily(PUB2) == 1)
    # 解析の記録に失敗しても再生数は数える
    q("alter table aimuse_private.analytics_plays_daily rename to analytics_plays_daily_x")
    p1 = plays(PUB2); o, e = q(f"select public.count_play('{PUB2}', '{V()}')", "anon", ip="198.51.100.22"); o2, e2 = q(f"select public.increment_plays('{PUB2}')", "anon", ip="198.51.100.23")
    q("alter table aimuse_private.analytics_plays_daily_x rename to analytics_plays_daily")
    ok("3 日別の集計が失敗しても、再生数は必ず数える（エラーにならない）", plays(PUB2) == p1 + 2 and not e and not e2, e or e2)

    # ---- 4. 画面の表示の記録
    q("truncate aimuse_private.analytics_views")
    a = V(); track(a, "home")
    ok("4 未ログインの表示を記録する", nviews() == 1)
    track(a, "home"); track(a, "home")
    ok("4 同じ端末で同じ画面を30分以内に開き直しても増えない", nviews() == 1)
    track(a, "search")
    ok("4 別の画面は数える", nviews() == 2)
    q("update aimuse_private.analytics_views set created_at = now() - interval '31 minutes' where page = 'home'"); track(a, "home")
    ok("4 30分を過ぎれば同じ画面も数える", nviews() == 3)
    n = nviews(); track(a, "admin"); track(a, "../x"); track(a, "HOME"); q(f"select public.analytics_track('{a}', null)", "anon", ip="198.51.100.7")
    ok("4 決まった画面の名前以外は数えない（管理者画面・不正な名前・空）", nviews() == n)
    track("00000000-0000-0000-0000-000000000000", "guide"); track("11111111-1111-1111-1111-111111111111", "guide")
    ok("4 ランダムな匿名ID（UUID v4）以外は数えない", nviews() == n)
    track(V(), "home", "admin")
    ok("4 管理者（ログイン中）の表示は数えない", nviews() == n)
    m = V(); track(m, "me", "hamu")
    ok("4 一般の会員（ログイン中）の表示は数える", nviews() == n + 1)
    track(adm_vid, "home"); track(adm_vid, "guide")
    ok("4 管理者としてログインしたことがある端末（ログアウト中）の表示は数えない", nviews() == n + 1)
    q("update aimuse_private.settings set value = 'off' where key = 'analytics_enabled'"); track(V(), "home")
    p2 = plays(PUB2); q(f"select public.count_play('{PUB2}', '{V()}')", "anon", ip="198.51.100.24")
    ok("4 停止スイッチ（off）で記録を止められる・再生数は今までどおり数える", nviews() == n + 1 and plays(PUB2) == p2 + 1)
    q("update aimuse_private.settings set value = 'on' where key = 'analytics_enabled'")

    # ---- 5. 個人情報を残さない
    allrows = v1("select coalesce(string_agg(x::text, '|'), '') from (select v::text x from aimuse_private.analytics_views v union all select r::text from aimuse_private.analytics_rate r union all select i::text from aimuse_private.analytics_rate_ids i union all select e::text from aimuse_private.analytics_excluded e union all select p::text from aimuse_private.analytics_plays_daily p) z")
    leaks = [s for s in ["198.51.100.7", "198.51.100", U["hamu"], U["admin"], a, m, adm_vid, "@"] if s in allrows]
    ok("5 解析の記録にIPアドレス・会員ID・匿名IDそのもの・メールアドレスが残らない", not leaks, leaks)
    cols = v1("select string_agg(column_name, ',' order by column_name) from information_schema.columns where table_schema='aimuse_private' and table_name='analytics_views'")
    ok("5 表示の記録の項目は「変換した匿名ID・画面・日付・日時」だけ", cols == "created_at,day,page,vid_hash", cols)
    q("update aimuse_private.settings set value = 'x' || value where key = 'analytics_salt'")
    ok("5 秘密の値が違えば変換値も変わる（匿名IDから推測できない）", v1(f"select aimuse_private.analytics_vid_hash('{a}')") not in allrows)
    q("update aimuse_private.settings set value = substr(value, 2) where key = 'analytics_salt'")

    # ---- 6. 水増し・大量送信の対策
    q("truncate aimuse_private.analytics_views, aimuse_private.analytics_rate, aimuse_private.analytics_rate_ids")
    vids = [V() for _ in range(32)]
    q(";".join(f"select public.analytics_track('{x}', 'home')" for x in vids), "anon", ip="192.0.2.50")
    ok("6 同じ接続元から新しい匿名IDを大量に作っても1時間に30個まで", nviews() == 30, nviews())
    track(vids[0], "search", ip="192.0.2.50")
    ok("6 上限内の匿名IDはその後も数える", nviews() == 31)
    track(vids[31], "search", ip="192.0.2.50")
    ok("6 上限を超えた匿名IDは同じ1時間内は数えない", nviews() == 31)
    track(V(), "home", ip="192.0.2.51")
    ok("6 別の接続元は影響を受けない", nviews() == 32)
    q("update aimuse_private.analytics_rate set hits = 600 where bucket <> 'admin'"); track(vids[1], "guide", ip="192.0.2.50")
    ok("6 同じ接続元から1時間に600件を超えた分は数えない", nviews() == 32)
    big = V(); h = v1(f"select aimuse_private.analytics_vid_hash('{big}')")
    q(f"insert into aimuse_private.analytics_views (vid_hash, page, day, created_at) select '{h}', 'home', (now() at time zone 'Asia/Tokyo')::date, now() - interval '1 hour' from generate_series(1, 200)")
    n = nviews(); track(big, "search", ip="192.0.2.52")
    ok("6 1つの端末で1日200件を超えた分は数えない", nviews() == n)
    o, e = q(f"select public.analytics_exclude_device('{V()}')", "hamu")
    ok("6 会員は端末を除外リストに入れられない（他人の計測を消せない）", "NOT_ALLOWED" in e, e[:60])
    o, e = q(f"select public.analytics_exclude_device('{V()}')", "anon", ip="192.0.2.53")
    ok("6 未ログインでは除外リストを操作できない", "permission denied" in e, e[:60])

    # ---- 7. 権限（管理者以外は解析データを見られない）
    for who in ("anon", "hamu"):
        bad = []
        for t in ("analytics_views", "analytics_daily", "analytics_monthly", "analytics_plays_daily", "analytics_excluded", "analytics_rate"):
            o, e = q(f"select count(*) from aimuse_private.{t}", who, ip="192.0.2.60")
            if not e: bad.append(t)
        for f in ("aimuse_private.analytics_maintain(true)", "aimuse_private.play_count_core('" + PUB + "')", "aimuse_private.analytics_note_play('" + PUB + "', null)", "aimuse_private.analytics_vid_hash('" + V() + "')"):
            o, e = q(f"select {f}", who, ip="192.0.2.60")
            if not e: bad.append(f)
        ok(f"7 {who}：解析の表・内部の関数に直接アクセスできない", not bad, bad)
    o, e = q("select public.admin_analytics()", "hamu"); o2, e2 = q("select public.admin_analytics_ranking(30, 50)", "hamu")
    ok("7 会員が集計を呼ぶとエラー（NOT_ALLOWED）", "NOT_ALLOWED" in e and "NOT_ALLOWED" in e2, e[:50])
    o, e = q("select public.admin_analytics()", "anon", ip="192.0.2.61"); o2, e2 = q("select public.admin_analytics_ranking(30, 50)", "anon", ip="192.0.2.61")
    ok("7 未ログインでは集計の関数を実行できない", "permission denied" in e and "permission denied" in e2, e[:50])
    o, e = q("select public.admin_analytics()", "admin")
    ok("7 管理者は集計を見られる", not e and o.startswith("{"), e)
    fn = v1("select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public','aimuse_private') and (p.proname like 'analytics%' or p.proname in ('count_play','admin_analytics','admin_analytics_ranking','play_count_core')) and has_function_privilege('anon', p.oid, 'execute')")
    ok("7 未ログインで実行できる新しい関数は analytics_track・count_play の2つだけ", fn == "analytics_track,count_play", fn)
    ok("7 解析の記録はアプリ用の領域（public）に置かない", v1("select count(*) from pg_tables where schemaname = 'public' and tablename like 'analytics%'") == "0")
    ok("7 aimuse_private は今までどおりアプリから使えない", v1("select has_schema_privilege('anon','aimuse_private','USAGE') or has_schema_privilege('authenticated','aimuse_private','USAGE')") == "f")

    # ---- 8. 集計の正しさ（日本時間の日付）
    q("truncate aimuse_private.analytics_views, aimuse_private.analytics_daily, aimuse_private.analytics_monthly, aimuse_private.analytics_plays_daily, aimuse_private.analytics_rate, aimuse_private.analytics_rate_ids")
    q("update aimuse_private.settings set value = to_char((now() at time zone 'Asia/Tokyo')::date - 200, 'YYYY-MM-DD') where key in ('analytics_started', 'analytics_raw_from')")
    q("delete from aimuse_private.settings where key = 'analytics_last_maintain'")
    T = "(now() at time zone 'Asia/Tokyo')::date"
    H = lambda k: f"md5('dev{k}')"
    rows = [(0, 1, "home"), (0, 1, "search"), (0, 2, "home"), (1, 1, "home"), (1, 3, "home"), (3, 4, "guide"), (6, 5, "home"), (7, 6, "home"), (20, 1, "artist"), (29, 7, "home"), (30, 8, "home"), (100, 9, "home"), (150, 9, "me")]
    q("insert into aimuse_private.analytics_views (vid_hash, page, day, created_at) values " + ",".join(f"({H(k)}, '{p}', {T} - {d}, now() - interval '{d} days')" for d, k, p in rows))
    q(f"insert into aimuse_private.analytics_excluded (vid_hash) values ({H(99)}) on conflict do nothing")
    q(f"insert into aimuse_private.analytics_views (vid_hash, page, day) values ({H(99)}, 'home', {T})")
    q(f"insert into aimuse_private.analytics_plays_daily (day, track_id, plays) values ({T}, '{PUB}', 3), ({T} - 1, '{PUB}', 2), ({T} - 10, '{PUB2}', 5), ({T} - 40, '{PUB2}', 7)")
    o, e = q("select public.admin_analytics()", "admin"); A = json.loads(o) if o else {}
    s = A.get("summary", {})
    ok("8 今日：訪問者（推計）2・表示3（管理者の端末を除く）", s.get("today") == {"uu": 2, "pv": 3}, s.get("today"))
    ok("8 昨日：訪問者2・表示2", s.get("yesterday") == {"uu": 2, "pv": 2}, s.get("yesterday"))
    ok("8 過去7日：同じ端末は1人として数える（訪問者5・表示7）", s.get("d7") == {"uu": 5, "pv": 7}, s.get("d7"))
    ok("8 過去30日：訪問者7・表示10", s.get("d30") == {"uu": 7, "pv": 10}, s.get("d30"))
    dl = A.get("daily") or []
    ok("8 日別：直近30日を毎日1件ずつ（データのない日は0）", len(dl) == 30 and dl[-1]["pv"] == 3 and dl[-1]["plays"] == 3 and dl[-2]["uu"] == 2 and dl[-11]["plays"] == 5 and sum(x["pv"] for x in dl) == 10, [(x["pv"], x["plays"]) for x in dl[-3:]])
    ml = A.get("monthly") or []
    pvm = v1(f"select count(*) from aimuse_private.analytics_views v where v.vid_hash <> {H(99)} and date_trunc('month', v.day) = date_trunc('month', {T})")
    ok("8 月別：直近12か月・今月の表示数が正しい", len(ml) == 12 and ml[-1]["pv"] == int(pvm), (len(ml), ml[-1] if ml else None, pvm))
    pl = A.get("plays", {})
    ok("8 期間別の再生数（今日3・昨日2・7日5・30日10・計測開始から17）", (pl.get("today"), pl.get("yesterday"), pl.get("d7"), pl.get("d30"), pl.get("all")) == (3, 2, 5, 10, 17), pl)
    pg = {x["page"]: x["pv"] for x in A.get("pages", [])}
    ok("8 画面別の表示数（過去30日）", pg == {"home": 7, "search": 1, "guide": 1, "artist": 1}, pg)
    q(f"insert into aimuse_private.analytics_excluded (vid_hash) values ({H(1)})"); q("delete from aimuse_private.settings where key = 'analytics_last_maintain'")
    A2 = json.loads(q("select public.admin_analytics()", "admin")[0])
    ok("8 あとから除外した管理者の端末は、過去の分（90日以内）も集計から外れる", A2["summary"]["today"] == {"uu": 1, "pv": 1} and A2["daily"][-1]["pv"] == 1, A2["summary"]["today"])
    q(f"delete from aimuse_private.analytics_excluded where vid_hash = {H(1)}")

    # ---- 9. 90日で削除・集計値は残る
    q("insert into aimuse_private.analytics_rate (bucket, window_start, hits) values ('old', now() - interval '3 hours', 5)")
    mx = json.loads(v1("select aimuse_private.analytics_maintain(true)"))   # 8. の集計画面を開いた時点で削除済み
    ok("9 90日より前の生の記録を削除（100日前・150日前の2件）・90日以内は残す", mx.get("result") == "done" and v1(f"select count(*) from aimuse_private.analytics_views where day < {T} - 89") == "0" and v1(f"select count(*) from aimuse_private.analytics_views where day = {T} - 29") == "1", mx)
    ok("9 削除した日の日別の集計値は残る", v1(f"select pv from aimuse_private.analytics_daily where day = {T} - 100") == "1" and v1(f"select pv from aimuse_private.analytics_daily where day = {T} - 150") == "1")
    ok("9 生の記録がそろっている最初の日を更新", v1("select value from aimuse_private.settings where key = 'analytics_raw_from'") == v1(f"select to_char({T} - 89, 'YYYY-MM-DD')"))
    old_m = v1(f"select pv || ':' || uu from aimuse_private.analytics_monthly where month = date_trunc('month', {T} - 150)::date")
    q("delete from aimuse_private.analytics_daily"); v1("select aimuse_private.analytics_maintain(true)")
    ok("9 一部を削除した月の月別の集計値は作り直さない（確定値のまま）", v1(f"select pv || ':' || uu from aimuse_private.analytics_monthly where month = date_trunc('month', {T} - 150)::date") == old_m and old_m == "1:1", old_m)
    ok("9 大量送信の防止用の記録は2時間で削除", v1("select count(*) from aimuse_private.analytics_rate where bucket = 'old'") == "0")
    o = v1("select aimuse_private.analytics_maintain(false)")
    ok("9 1時間以内の再実行はしない（毎日の集計と重なっても安全）", '"skipped"' in o, o)

    # ---- 10. 楽曲別の再生ランキング
    o, e = q("select public.admin_analytics_ranking(7, 50)", "admin"); rk = json.loads(o) if o else []
    ok("10 期間（7日）の再生数で並ぶ・累計は公開中の再生数", rk and rk[0]["track_id"] == PUB and rk[0]["period"] == 5 and rk[0]["total"] == plays(PUB), rk[:1])
    rk0 = json.loads(q("select public.admin_analytics_ranking(0, 50)", "admin")[0])
    ok("10 計測開始からの合計（PUB2 = 12）", next(x["period"] for x in rk0 if x["track_id"] == PUB2) == 12)
    ok("10 審査待ちの曲は出さない・非公開の曲は出す（管理者のみ）", not any(x["track_id"] == PEND for x in rk0) and len(json.loads(q("select public.admin_analytics_ranking(0, 100)", "admin")[0])) == int(v1("select least(count(*), 100) from public.tracks where status in ('public','hidden')")))
    rk3 = json.loads(q("select public.admin_analytics_ranking(3, 1000)", "admin")[0])
    ok("10 想定外の期間は30日・件数は最大100件", len(rk3) <= 100 and next(x["period"] for x in rk3 if x["track_id"] == PUB2) == 5)

    # ---- 11. 集計の呼び出しの上限
    q("update aimuse_private.analytics_rate set hits = 120 where bucket = 'admin'")
    o, e = q("select public.admin_analytics()", "admin")
    ok("11 集計の呼び出しは1時間に120回まで", "RATE_LIMIT" in e, e[:60])

    # ---- 12. 元に戻す・再適用
    d1 = v1(snap.replace("union all select e::text from public.play_events e ", ""))
    o, e = q(RB.replace("\n", "\r\n"))
    ok("12 元に戻せる（CRLF）・2回目も成功", not e and not q(RB)[1], e)
    ok("12 increment_plays の中身・権限が v1.5 と同じに戻る", v1(inc_src) == src0 and v1(acl) == acl0)
    ok("12 解析の表・関数・設定が残らない", v1("select count(*) from pg_tables where tablename like 'analytics%'") == "0" and v1("select count(*) from pg_proc where proname in ('count_play','admin_analytics','analytics_track','play_count_core')") == "0" and v1("select count(*) from aimuse_private.settings where key like 'analytics%'") == "0")
    ok("12 元に戻しても楽曲・会員・歌詞の同期は変わらない", v1(snap.replace("union all select e::text from public.play_events e ", "")) == d1)
    p3 = plays(PUB2); q(f"select public.increment_plays('{PUB2}')", "anon", ip="198.51.100.99")
    ok("12 元に戻した後も再生数は数えられる", plays(PUB2) == p3 + 1)
    ok("12 再適用できる", not q(M17)[1])
    for d in ("t117", "t117old"): q(f"drop database if exists {d}", db="postgres")

print(f"\n合計 {sum(R)}/{len(R)} 件成功" + ("" if all(R) else "  ← 失敗あり"))
sys.exit(0 if all(R) else 1)
