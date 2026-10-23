# v1.16 十分な精度の曲だけを自動で採用する：基準・設定のオン／オフ・手動の同期を守る・歌詞の変更・権限・元に戻す
# 使い方：python3 tests/db/test_v116.py [ポート...]（既定：PostgreSQL 17 = 55417、15 = 55415。テンプレート prod111）
import subprocess, json, sys, os
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
rd = lambda p: open(os.path.join(ROOT, p), encoding="utf-8").read()
M14, M15, M16, RB = rd("supabase/migration_v1_14_lyrics_sync.sql"), rd("supabase/migration_v1_15_lyrics_auto_sync.sql"), rd("supabase/migration_v1_16_lyrics_auto_apply.sql"), rd("supabase/rollback/rollback_v1_16.sql")
PORTS = [int(p) for p in sys.argv[1:]] or [55417, 55415]
U = {"admin": "10000000-0000-4000-8000-000000000001", "a": "10000000-0000-4000-8000-000000000002", "b": "10000000-0000-4000-8000-000000000003"}
TA, TB = "20000000-0000-4000-8000-000000000001", "20000000-0000-4000-8000-000000000002"
LYR = ["[Verse 1]"] + [f"歌詞の行{k}" for k in range(1, 21)]          # 時刻を付けられる行：1〜20
GOOD = [{"i": k, "t": 10 + k * 5} for k in range(1, 21)]
META = lambda m=20, ok=True, est=None, run=0: {"matched_lines": m, "quality_ok": ok, "reasons": [], "est": est or [], "max_est_run": run, "granularity": "word", "vad_filter": False}
R = []
def ok(n, c, i=""): R.append(bool(c)); print(f"  [{'PASS' if c else 'FAIL'}] {n}  {str(i)[:150]}")
for port in PORTS:
    def q(sql, who="postgres", db="t116"):
        if who != "postgres":
            role, c = ("service_role", {"role": "service_role"}) if who == "service" else ("authenticated", {"sub": U[who], "role": "authenticated"})
            sql = f"begin; set local role {role}; set local request.jwt.claims='{json.dumps(c)}';\n{sql};\ncommit;"
        r = subprocess.run(["psql", "-h", "/opt/pgx", "-p", str(port), "-U", "postgres", "-X", "-At", "-q", "-d", db, "-c", sql], capture_output=True, text=True)
        return r.stdout.strip(), next((l for l in r.stderr.splitlines() if "ERROR" in l), "")
    J = lambda o: json.loads(o) if o else None
    sync = lambda t: J(q(f"select to_jsonb(s) - 'updated_at' - 'updated_by' from public.track_lyrics_sync s where track_id = '{t}'")[0])
    job = lambda t: J(q(f"select to_jsonb(j) from aimuse_private.lyrics_align_jobs j where track_id = '{t}'")[0])
    def run(t, lines=GOOD, meta=None):   # その曲だけを取り出して結果を保存
        q(f"update aimuse_private.lyrics_align_jobs set next_try_at = case when track_id = '{t}' then now() - interval '1 s' else now() + interval '1 day' end where state = 'queued'")
        c = J(q("select public.lyrics_align_claim()", "service")[0])
        assert c and c["status"] == "claimed" and c["track_id"] == t, c
        return J(q(f"select public.lyrics_align_finish('{t}', '{c['token']}', '{json.dumps(lines, ensure_ascii=False)}'::jsonb, '{json.dumps(meta or META())}'::jsonb)", "service")[0])
    requeue = lambda t: q(f"update aimuse_private.lyrics_align_jobs set state = 'queued', next_try_at = now() where track_id = '{t}'")
    print("== port", port, q("show server_version", db="postgres")[0])
    q("drop database if exists t116", db="postgres"); q("create database t116 template prod111", db="postgres")
    q("revoke select, insert, update, delete on all tables in schema public from service_role")
    for m in (M14, M15): o, e = q(m); assert not e, e
    lit = "array[" + ",".join(f"'{l}'" for l in LYR) + "]::text[]"
    q(f"update public.tracks set lyrics = {lit}, duration = 200, audio_size = 4000000 where id in ('{TA}', '{TB}')")
    d0 = q("select md5(string_agg(t::text, '|' order by id)) from public.tracks t")[0]
    o, e = q(M16.replace("\n", "\r\n")); ok("1 適用できる（CRLF）・2回目も成功", not e and not q(M16)[1], e)
    ok("1 適用しただけでは自動で採用しない（設定はオフのまま）・データは変わらない", q("select auto_apply from aimuse_private.lyrics_align_settings")[0] == "f" and q("select md5(string_agg(t::text, '|' order by id)) from public.tracks t")[0] == d0)
    o, e = q("select public.admin_align_set_auto(true)", "a"); ok("2 会員は自動で採用する設定を変えられない", "NOT_ALLOWED" in e, e[:60])
    o, e = q("select public.admin_align_set_auto(true)", "b"); ok("2 他の会員も不可", "NOT_ALLOWED" in e)
    o, e = q("select has_function_privilege('anon', 'public.admin_align_set_auto(boolean)', 'execute')"); ok("2 未ログインは実行できない", o == "f")
    q("update aimuse_private.lyrics_align_settings set paused = false")
    q(f"select aimuse_private.lyrics_align_enqueue('{TA}', 'existing', false, null)"); q(f"select aimuse_private.lyrics_align_enqueue('{TB}', 'existing', false, null)")
    # 3. 設定オフ：十分な精度でも確認待ち
    r = run(TA); ok("3 設定がオフなら、精度が十分でも確認待ち（同期の時刻は作らない）", r["status"] == "review" and r["auto_ok"] is True and sync(TA) is None, r)
    o, e = q("select public.admin_align_set_auto(true)", "admin"); ok("3 運営は自動で採用する設定をオンにできる", J(o) == {"auto_apply": True}, o or e)
    # 4. 設定オン：基準を満たす曲だけ自動で採用
    requeue(TA); r = run(TA)
    ok("4 十分な精度（照合率100%・推定なし）→ 自動で採用（auto）・再生画面で読める", r["status"] == "applied" and sync(TA)["source"] == "auto" and "50" in q(f"select public.lyrics_sync_get('{TA}')", "a")[0], r)
    requeue(TB); r = run(TB, meta=META(m=18, est=[19, 20], run=2))
    ok("4 照合率 90%（95%未満）→ 確認待ち（auto_ok=false）", r["status"] == "review" and r["auto_ok"] is False and sync(TB) is None, r)
    requeue(TB); r = run(TB, meta=META(m=20, est=[5, 6], run=2))
    ok("4 推定の行が2行続く → 確認待ち", r["status"] == "review" and r["auto_ok"] is False, r)
    requeue(TB); r = run(TB, meta=META(m=20, est=[3, 9], run=1))
    ok("4 推定の行が 5%を超える（20行中2行）→ 確認待ち", r["status"] == "review" and r["auto_ok"] is False, r)
    requeue(TB); r = run(TB, meta=META(ok=False))
    ok("4 時刻の品質の検査に不合格 → 確認待ち（low_quality）", r["status"] == "review" and job(TB)["reason"] == "low_quality", r)
    requeue(TB); r = run(TB, meta={k: v for k, v in META().items() if k != "est"})
    ok("4 推定の行の情報が無い結果は、自動で採用しない", r["status"] == "review" and r["auto_ok"] is False, r)
    # 5. 手動の同期を守る
    q(f"select public.lyrics_sync_save('{TB}', '[{{\"i\":1,\"t\":3}}]'::jsonb)", "b")
    q(f"select public.lyrics_align_request('{TB}')", "b"); r = run(TB)
    ok("5 手動の同期がある曲は、精度が十分でも置き換えない（提案だけ）", r["status"] == "review" and sync(TB)["source"] == "manual" and sync(TB)["lines"] == [{"i": 1, "t": 3}], (r, sync(TB)))
    q(f"select public.lyrics_sync_save('{TA}', '{json.dumps(GOOD[:5])}'::jsonb)", "a")
    ok("5 自動で採用した同期を投稿者が直すと mixed", sync(TA)["source"] == "mixed")
    q(f"select public.lyrics_align_request('{TA}')", "a"); r = run(TA)
    ok("5 手直し済み（mixed）の同期も、自動では置き換えない", r["status"] == "review" and sync(TA)["source"] == "mixed" and len(sync(TA)["lines"]) == 5, r)
    # 6. 歌詞が変わったとき
    q(f"update public.track_lyrics_sync set source = 'auto' where track_id = '{TA}'")   # AI の同期だけの状態にする
    q(f"update public.tracks set lyrics = array_append(lyrics, '新しい行') where id = '{TA}'", "admin")
    g = J(q(f"select json_agg(x) from public.lyrics_sync_get('{TA}') x", "a")[0])
    ok("6 歌詞が変わると古い同期は stale（再生画面は使わない）・自動で解析待ちへ", g[0]["stale"] is True and job(TA)["state"] == "queued", (g[0]["stale"], job(TA)["state"]))
    r = run(TA, lines=GOOD + [{"i": 21, "t": 120}], meta=META(m=21))
    ok("6 新しい歌詞で十分な精度なら、古い AI の同期を新しい同期に置き換える", r["status"] == "applied" and len(sync(TA)["lines"]) == 21 and J(q(f"select json_agg(x) from public.lyrics_sync_get('{TA}') x", "a")[0])[0]["stale"] is False, r)
    q(f"update public.track_lyrics_sync set source = 'manual' where track_id = '{TA}'")
    q(f"update public.tracks set lyrics = array_append(lyrics, 'さらに') where id = '{TA}'", "admin"); r = run(TA, lines=GOOD + [{"i": 21, "t": 120}, {"i": 22, "t": 125}], meta=META(m=22))
    ok("6 手動の同期は、歌詞が変わって古くなっても自動では置き換えない（提案だけ）", r["status"] == "review" and sync(TA)["source"] == "manual" and len(sync(TA)["lines"]) == 21, r)
    # 8. 基準を満たす確認待ちの曲をまとめて採用（既存曲向け）
    q("select public.admin_align_set_auto(false)", "admin")
    T = [f"20000000-0000-4000-8000-00000000000{k}" for k in (6, 7, 8, 9)]
    q(f"update public.tracks set status = 'public', lyrics = {lit}, duration = 200, audio_size = 4000000 where id in ({','.join(repr(x) for x in T)})")
    for x in T: q(f"select aimuse_private.lyrics_align_enqueue('{x}', 'existing', false, null)")
    run(T[0]); run(T[1], meta=META(m=18, est=[19, 20], run=2)); run(T[2]); run(T[3])
    q(f"select public.lyrics_sync_save('{T[2]}', '[{{\"i\":1,\"t\":4}}]'::jsonb)", "admin")        # 手動の同期を先に保存
    q(f"update public.tracks set lyrics = array_append(lyrics, '追加') where id = '{T[3]}'", "admin")   # 歌詞が変わった（提案は古い）
    q(f"update aimuse_private.lyrics_align_jobs set state = 'review' where track_id = '{T[3]}'")
    d1 = q("select md5(string_agg(s::text, '|' order by track_id)) from public.track_lyrics_sync s")[0]
    o, e = q("select public.admin_align_apply_ready()", "a"); ok("8 会員はまとめて採用できない", "NOT_ALLOWED" in e, e[:60])
    o, e = q("select public.admin_align_apply_ready()", "admin"); pv = J(o)
    ok("8 まず一覧だけ（何も変えない）：採用する曲と、採用しない曲の理由", pv and pv["run"] is False and q("select md5(string_agg(s::text, '|' order by track_id)) from public.track_lyrics_sync s")[0] == d1, o[:200] or e)
    ap = {x["track_id"] for x in pv["apply"]}; sk = {x["track_id"]: x["why"] for x in pv["skip"]}
    ok("8 基準を満たす曲だけが「採用する」", T[0] in ap and T[1] not in ap and T[2] not in ap and T[3] not in ap, (ap, sk))
    ok("8 理由：基準に届かない・手動の同期あり・古い歌詞の提案", sk.get(T[1]) == "below_standard" and sk.get(T[2]) == "has_manual_sync" and sk.get(T[3]) == "old_lyrics", sk)
    o, e = q("select public.admin_align_apply_ready(true)", "admin"); rr = J(o)
    ok("8 実行すると、一覧の曲だけを同期の時刻にする（auto）", rr and {x["track_id"] for x in rr["apply"]} == ap and sync(T[0])["source"] == "auto" and job(T[0])["state"] == "applied", o[:160] or e)
    ok("8 対象外の曲は変わらない（手動の同期はそのまま・基準未満は確認待ちのまま）", sync(T[2])["lines"] == [{"i": 1, "t": 4}] and sync(T[1]) is None and job(T[1])["state"] == "review" and sync(T[3]) is None)
    ok("8 採用した同期は再生画面で読める（stale でない）", J(q(f"select json_agg(x) from public.lyrics_sync_get('{T[0]}') x", "a")[0])[0]["stale"] is False)
    o, e = q("select public.admin_align_apply_ready(true)", "admin"); ok("8 2回目は何も採用しない（重複しない）", J(o)["apply"] == [], o[:120])
    # 7. 元に戻す
    o, e = q(RB); ok("7 元に戻せる（設定はオフ・関数が無くなる・同期は残る）", not e and q("select auto_apply from aimuse_private.lyrics_align_settings")[0] == "f" and q("select to_regprocedure('public.admin_align_set_auto(boolean)') is null")[0] == "t" and sync(TA) is not None, e)
    o, e = q(M16); ok("7 再適用できる", not e, e)
    q("drop database if exists t116", db="postgres")
print(f"\n合計 {len(R)} 件 / 不合格 {R.count(False)} 件"); sys.exit(1 if False in R else 0)
