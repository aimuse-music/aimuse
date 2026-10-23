# v1.15 歌詞の自動同期（AI）のテスト：解析待ち・重複しない・1日の上限・再試行の制限・停止と再開・提案と採用・手動の同期を守る・権限・元に戻す
# 使い方：python3 tests/db/test_v115.py [ポート...]   （既定：PostgreSQL 17 = 55417、15 = 55415。テンプレート prod111）
# 本番と同じく、service_role には表の直接の権限を付けない状態で確かめる
import subprocess, json, sys, os, math
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
M14 = open(os.path.join(ROOT, "supabase/migration_v1_14_lyrics_sync.sql"), encoding="utf-8").read()
MIG = open(os.path.join(ROOT, "supabase/migration_v1_15_lyrics_auto_sync.sql"), encoding="utf-8").read()
RB = open(os.path.join(ROOT, "supabase/rollback/rollback_v1_15.sql"), encoding="utf-8").read()
PORTS = [int(p) for p in sys.argv[1:]] or [55417, 55415]
U = {k: "10000000-0000-4000-8000-%012d" % i for k, i in [("admin", 1), ("a", 2), ("b", 3), ("w", 4), ("banned", 50)]}
TA = "20000000-0000-4000-8000-000000000001"   # a の公開中の曲
TB = "20000000-0000-4000-8000-000000000002"   # b の公開中の曲
TP = "20000000-0000-4000-8000-000000000003"   # w の審査待ちの曲
LYR = ["[Verse 1]", "あの夜は　少し寒くて", "", "君と歩いた", "【サビ】", "おぼろ月", "（ハミング）"]   # 時刻を付けられる行：1・3・5・6
GOOD = [{"i": 1, "t": 12.3}, {"i": 3, "t": 20}, {"i": 5, "t": 40.1, "e": 45}, {"i": 6, "t": 50}]
META_OK = {"matched_lines": 4, "quality_ok": True, "reasons": [], "est": [], "max_est_run": 0, "ai_ms": 27000, "words": 40, "granularity": "word", "vad_filter": False}
R = []
def ok(n, c, i=""): R.append(bool(c)); print(f"  [{'PASS' if c else 'FAIL'}] {n}  {str(i)[:160]}")
VAULT = """create schema if not exists extensions; create extension if not exists pgcrypto schema extensions;
create schema if not exists vault;
create table if not exists vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text, description text, created_at timestamptz default now());
create or replace view vault.decrypted_secrets as select id, name, secret as decrypted_secret, created_at from vault.secrets;
revoke all on schema vault from public;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
revoke select, insert, update, delete on all tables in schema public from service_role;"""
DATA = """select md5(string_agg(x, '|' order by x)) from (select 't'||t::text x from public.tracks t union all select 'p'||t::text from public.profiles t
  union all select 's'||t::text from public.track_lyrics_sync t union all select 'l'||t::text from public.playlists t union all select 'o'||t::text from storage.objects t) s"""
for port in PORTS:
    def q(sql, who="postgres", db="t115"):
        if who != "postgres":
            if who == "anon": role, c = "anon", {"role": "anon"}
            elif who == "service": role, c = "service_role", {"role": "service_role"}
            else: role, c = "authenticated", {"sub": U[who], "role": "authenticated"}
            sql = f"begin; set local role {role}; set local request.jwt.claims='{json.dumps(c)}';\n{sql};\ncommit;"
        r = subprocess.run(["psql", "-h", "/opt/pgx", "-p", str(port), "-U", "postgres", "-X", "-At", "-q", "-d", db, "-c", sql], capture_output=True, text=True)
        return r.stdout.strip(), next((l for l in r.stderr.splitlines() if "ERROR" in l), "")
    J = lambda o: json.loads(o) if o else None
    job = lambda tid: J(q(f"select to_jsonb(j) from aimuse_private.lyrics_align_jobs j where track_id = '{tid}'")[0])
    claim = lambda: q("select public.lyrics_align_claim()", "service")
    finish = lambda tid, tok, lines, meta: q(f"select public.lyrics_align_finish('{tid}', '{tok}', '{json.dumps(lines, ensure_ascii=False)}'::jsonb, '{json.dumps(meta)}'::jsonb)", "service")
    fail = lambda tid, tok, code: q(f"select public.lyrics_align_fail('{tid}', '{tok}', '{code}')", "service")
    sync = lambda tid: J(q(f"select to_jsonb(s) - 'updated_at' - 'updated_by' from public.track_lyrics_sync s where track_id = '{tid}'")[0])
    ready = lambda: q("update aimuse_private.lyrics_align_jobs set next_try_at = now() - interval '1 second' where state = 'queued'")
    # その曲だけを取り出せる状態にする（ほかの解析待ちは明日に回す）
    def only(tid, requeue=False):
        if requeue: q(f"update aimuse_private.lyrics_align_jobs set state = 'queued' where track_id = '{tid}'")
        q(f"update aimuse_private.lyrics_align_jobs set next_try_at = case when track_id = '{tid}' then now() - interval '1 second' else now() + interval '1 day' end where state = 'queued'")
    print("== port", port, q("show server_version", db="postgres")[0])
    q("drop database if exists t115", db="postgres"); q("create database t115 template prod111", db="postgres")
    o, e = q(VAULT); assert not e, e
    o, e = q(M14); assert not e, e
    lit = "array[" + ",".join("'" + l + "'" for l in LYR) + "]::text[]"
    q(f"update public.tracks set lyrics = {lit}, duration = 258, audio_size = 5631485 where id in ('{TA}', '{TB}', '{TP}')")
    d0 = q(DATA)[0]
    # 1. 適用
    o, e = q(MIG.replace("\n", "\r\n")); ok("1 適用できる（本番と同じ CRLF の形）", not e, e)
    o, e = q(MIG); ok("1 2回目の適用も成功", not e, e)
    ok("1 既存データ（曲・プロフィール・同期・プレイリスト・ファイル）は変わらない", q(DATA)[0] == d0)
    ok("1 適用直後は停止中（AI は動かない）", q("select paused::text || pause_reason from aimuse_private.lyrics_align_settings")[0] == "trueinitial")
    ok("1 適用しただけでは解析待ちは作られない", q("select count(*) from aimuse_private.lyrics_align_jobs")[0] == "0")
    # 2. 権限
    for who in ["anon", "a"]:
        o, e = q("select count(*) from aimuse_private.lyrics_align_jobs", who); ok(f"2 {who}：解析待ちの表を直接読めない", "permission denied" in e, e[:60])
        for f in ["public.lyrics_align_claim()", f"public.lyrics_align_fail('{TA}', gen_random_uuid(), 'X')", "public.lyrics_align_secret_matches(repeat('a',64))",
                  f"public.lyrics_align_finish('{TA}', gen_random_uuid(), '[]'::jsonb, '{{}}'::jsonb)"]:
            o, e = q(f"select {f}", who); ok(f"2 {who}：解析する側の関数を実行できない（{f.split('(')[0]}）", "permission denied" in e, e[:60])
    o, e = q(f"select public.lyrics_align_status('{TA}')", "anon"); ok("2 未ログインは状態を見られない", "permission denied" in e, e[:60])
    for f in ["admin_align_overview()", "admin_align_set_paused(false)", "admin_align_set_cap(100)", f"admin_align_enqueue('{TA}')", "admin_align_enqueue_existing()", f"admin_align_retry('{TA}')"]:
        o, e = q(f"select public.{f}", "a"); ok(f"2 会員は運営の関数を使えない（{f.split('(')[0]}）", "NOT_ALLOWED" in e, e[:60])
    o, e = q(f"select public.lyrics_align_status('{TA}')", "b"); ok("2 他人の曲の状態は見られない", "NOT_ALLOWED" in e, e[:60])
    o, e = q(f"select public.lyrics_align_request('{TA}')", "b"); ok("2 他人の曲の解析は頼めない", "NOT_ALLOWED" in e, e[:60])
    o, e = q(f"select public.lyrics_align_apply('{TA}')", "b"); ok("2 他人の曲の提案は採用できない", "NOT_ALLOWED" in e, e[:60])
    info = q("select count(*) filter (where prosecdef and 'search_path=\"\"' = any(proconfig)), count(*) from pg_proc where pronamespace in ('public'::regnamespace, 'aimuse_private'::regnamespace) and (proname like 'lyrics_align%' or proname like 'admin_align%') and proname not in ('lyrics_align_ineligible', 'lyrics_align_review_stats')")[0]
    a_, b_ = info.split("|"); ok("2 追加した関数（計算だけのものを除く）はすべて SECURITY DEFINER・search_path が空", a_ == b_ and int(b_) >= 17, info)
    o = q("select string_agg(r || '=' || has_function_privilege(r, 'public.lyrics_align_claim()', 'execute')::text, ' ') from unnest(array['anon','authenticated','service_role']) r")[0]
    ok("2 解析する側の関数は service_role だけ", o == "anon=false authenticated=false service_role=true", o)
    # 3. トリガー（承認・歌詞・長さ）
    q(f"update public.tracks set status = 'public', approved_at = now() where id = '{TP}'", "admin")
    j = job(TP); ok("3 管理者が承認して公開 → 解析待ち（approved）", j and j["state"] == "queued" and j["reason"] == "approved", j and (j["state"], j["reason"]))
    o, e = q(f"insert into public.tracks (id, user_id, title, artist, genre, tool, tool_name, audio_path, lyrics, duration) values ('20000000-0000-4000-8000-0000000aa001', '{U['a']}', '新曲', 'テスト歌手', 'J-POP', 'Suno', 'Suno', '{U['a']}/20000000-0000-4000-8000-0000000aa001.mp3', {lit}, 200)", "a")
    ok("3 会員の投稿はそのまま成功し（審査待ち）、解析待ちにはならない", not e and job("20000000-0000-4000-8000-0000000aa001") is None, e)
    q(f"update public.tracks set status = 'public' where id = '20000000-0000-4000-8000-0000000aa001'", "admin")
    q(f"update public.tracks set lyrics = '{{}}'::text[] where id = '20000000-0000-4000-8000-0000000aa001'", "admin")
    j = job("20000000-0000-4000-8000-0000000aa001"); ok("3 歌詞が無くなった曲は「歌詞待ち」", j["state"] == "waiting" and j["reason"] == "no_lyrics", (j["state"], j["reason"]))
    q(f"update public.tracks set lyrics = {lit}, duration = 0 where id = '20000000-0000-4000-8000-0000000aa001'", "admin")
    j = job("20000000-0000-4000-8000-0000000aa001"); ok("3 長さが未登録の曲は「待ち」", j["state"] == "waiting" and j["reason"] == "no_duration", (j["state"], j["reason"]))
    q(f"select public.set_duration_if_missing('20000000-0000-4000-8000-0000000aa001', 200)", "a")
    j = job("20000000-0000-4000-8000-0000000aa001"); ok("3 長さが入ると自動で解析待ち", j["state"] == "queued" and j["reason"] == "duration", (j["state"], j["reason"]))
    q(f"update public.tracks set status = 'hidden' where id = '20000000-0000-4000-8000-0000000aa001'", "admin")
    j = job("20000000-0000-4000-8000-0000000aa001"); ok("3 非公開にした曲は対象外（not_public）", j["state"] == "skipped" and j["reason"] == "not_public", (j["state"], j["reason"]))
    q(f"update public.tracks set status = 'public', duration = 700 where id = '20000000-0000-4000-8000-0000000aa001'", "admin")
    j = job("20000000-0000-4000-8000-0000000aa001"); ok("3 10分を超える曲は対象外（too_long）", j["state"] == "skipped" and j["reason"] == "too_long", (j["state"], j["reason"]))
    q(f"update public.tracks set duration = 200, audio_size = 30000000 where id = '20000000-0000-4000-8000-0000000aa001'", "admin")
    j = job("20000000-0000-4000-8000-0000000aa001"); ok("3 20MB を超える音源は対象外（too_large）", j["state"] == "skipped" and j["reason"] == "too_large", (j["state"], j["reason"]))
    o, e = q("select public.increment_plays('20000000-0000-4000-8000-0000000aa001')", "anon")
    ok("3 再生回数の更新では解析待ちは変わらない", job("20000000-0000-4000-8000-0000000aa001")["reason"] == "too_large", e)
    q("update public.tracks set status = 'hidden' where id = '20000000-0000-4000-8000-0000000aa001'", "admin")
    # 4. 既存曲の一括登録・重複しない
    o, e = q("select public.admin_align_enqueue_existing()", "admin"); r1 = J(o)
    ok("4 既存の公開中の曲をまとめて登録（歌詞のある曲は queued、無い曲は waiting）", r1 and r1.get("queued") == 2 and r1.get("waiting", 0) > 500, r1 or e)
    o, e = q("select public.admin_align_enqueue_existing()", "admin"); r2 = J(o)
    ok("4 2回目は重複しない（すべて duplicate）", r2 and set(r2) == {"duplicate"}, r2 or e)
    o, e = q(f"select public.admin_align_enqueue('{TA}')", "admin"); ok("4 1曲の登録も、登録済みなら重複しない", J(o) == {"result": "duplicate"}, o or e)
    ok("4 1曲につき解析待ちは1行だけ", q(f"select count(*) from aimuse_private.lyrics_align_jobs where track_id = '{TA}'")[0] == "1")
    # 5. 取り出し（停止・同時に1件・1日の上限）
    o, e = claim(); ok("5 停止中は取り出さない", J(o)["status"] == "paused", o or e)
    o, e = q("select public.admin_align_set_paused(false)", "admin"); ok("5 運営が再開できる", J(o) == {"paused": False}, o or e)
    only(TA)
    o, e = claim(); c1 = J(o); est = math.ceil(258 / 60 * 46.63 * 1.2)
    ok("5 1曲だけ取り出す（曲の情報と札を返す）", c1 and c1["status"] == "claimed" and c1["est_neurons"] == est and c1["lyrics"] == LYR and c1["token"], o or e)
    ok("5 取り出す前に、その日の使用量を予約（長さ÷60×46.63×1.2）", q("select reserved || '|' || runs from aimuse_private.lyrics_align_budget")[0] == f"{est}|1")
    o, e = claim(); ok("5 解析中の曲がある間は、次を取り出さない（同時に1曲）", J(o)["status"] == "busy", o)
    T1 = c1["track_id"]
    # 6. 結果の保存（提案）
    o, e = finish(T1, "00000000-0000-4000-8000-000000000000", GOOD, META_OK); ok("6 札が違えば保存しない（stale）", J(o)["status"] == "stale", o or e)
    o, e = finish(T1, c1["token"], GOOD, META_OK); f1 = J(o)
    ok("6 正しい札なら提案として保存（確認待ち review）", f1 and f1["status"] == "review" and f1["quality_ok"] is True and f1["ratio"] == 1, o or e)
    ok("6 同期の時刻そのものは書き換えない（初期は自動で表示しない）", sync(T1) is None)
    j = job(T1); ok("6 提案・照合率・品質を記録（トークンは消える）", j["proposal"] == [{"i": 1, "t": 12.3}, {"i": 3, "t": 20}, {"i": 5, "t": 40.1, "e": 45}, {"i": 6, "t": 50}] and j["meta"]["ratio"] == 1 and j["token"] is None, j["meta"])
    o, e = finish(T1, c1["token"], GOOD, META_OK); ok("6 同じ札で2回は保存できない", J(o)["status"] == "stale", o)
    # 2曲目：品質が低い・形式違い
    only(TP); o, e = claim(); c2 = J(o); T2 = c2["track_id"]
    o, e = finish(T2, c2["token"], [{"i": 1, "t": 12}], {**META_OK, "matched_lines": 1, "quality_ok": True}); f2 = J(o)
    ok("6 照合率が低い（25%）と、品質は不合格（low_quality）", f2["status"] == "review" and f2["quality_ok"] is False and job(T2)["reason"] == "low_quality", o)
    only(T2, True); o, e = claim(); c2 = J(o)
    o, e = finish(T2, c2["token"], [{"i": 0, "t": 1}], META_OK); ok("6 形式の違う結果（見出しに時刻）は保存しない（bad_result・再試行しない）", J(o)["status"] == "bad_result" and job(T2)["state"] == "failed", o)
    only(T2, True); o, e = claim(); c2 = J(o)
    o, e = finish(T2, c2["token"], GOOD, {**META_OK, "quality_ok": "yes", "reasons": ["est_run", "BAD<script>"], "ai_ms": "x", "words": -5}); j = job(T2)
    ok("6 形式の違う付帯情報（品質が文字・数が負）でも保存は止まらず、不合格・0 として扱う", J(o) and J(o)["status"] == "review" and j["meta"]["quality_ok"] is False and j["meta"]["ai_ms"] == 0 and j["meta"]["words"] == 0, o or e)
    ok("6 時刻の検査に落ちた結果は不合格、理由は決まった形の文字だけ記録", j["meta"]["quality_ok"] is False and j["meta"]["reasons"] == ["est_run"], j["meta"])
    # 解析中に歌詞が変わった
    only(T2, True); o, e = claim(); c2 = J(o)
    q(f"update public.tracks set lyrics = array_append(lyrics, '追加の行') where id = '{T2}'", "admin")
    ok("6 解析中に歌詞が変わると、印だけ付ける（rerun）", job(T2)["rerun"] is True and job(T2)["state"] == "running")
    o, e = finish(T2, c2["token"], GOOD, META_OK); ok("6 歌詞が変わっていたら結果を捨てて解析待ちへ（requeued）", J(o)["status"] == "requeued" and job(T2)["state"] == "queued" and job(T2)["proposal"] is None, o)
    # 7. 失敗と再試行の制限
    only(T2); o, e = claim(); c2 = J(o)
    o, e = fail(T2, c2["token"], "AI_ERROR"); j = job(T2)
    ok("7 一時的な失敗：1回目は30分後に再試行", J(o)["status"] == "retry" and j["attempts"] == 1 and j["state"] == "queued", (o, j["next_try_at"]))
    o, e = claim(); ok("7 再試行の時刻までは取り出さない", J(o)["status"] == "idle", o)
    only(T2); o, e = claim(); c2 = J(o); o, e = fail(T2, c2["token"], "AI_TIMEOUT"); ok("7 2回目は2時間後", J(o)["status"] == "retry" and job(T2)["attempts"] == 2, o)
    only(T2); o, e = claim(); c2 = J(o); o, e = fail(T2, c2["token"], "AUDIO_UNAVAILABLE"); j = job(T2)
    ok("7 3回目で打ち切り（failed・gave_up）。以後は取り出さない", J(o)["status"] == "failed" and j["state"] == "failed" and j["reason"] == "gave_up", o)
    q(f"update aimuse_private.lyrics_align_jobs set next_try_at = now() - interval '1 s' where track_id = '{T2}'"); o, e = claim(); ok("7 打ち切った曲は取り出されない", J(o)["status"] == "idle", o)
    o, e = q(f"select public.lyrics_align_request('{T2}')", "w")
    ok("7 打ち切った後も、本人の「作り直す」（回数制限あり）だけで再開できる", J(o) == {"result": "queued"} and job(T2)["attempts"] == 0, o or e)
    only(T2); o, e = claim(); c2 = J(o); o, e = fail(T2, c2["token"], "FREE_LIMIT")
    st = q("select blocked_until > now() + interval '0 s', blocked_until::time from aimuse_private.lyrics_align_settings")[0]
    ok("7 無料枠切れ（FREE_LIMIT）：翌日（世界標準時 0時5分）まで全体を止める・試行回数に数えない", J(o)["status"] == "blocked" and st.startswith("t|") and job(T2)["attempts"] == 0, (o, st))
    ready(); o, e = claim(); ok("7 止めている間は取り出さない", J(o)["status"] == "blocked", o)
    q("update aimuse_private.lyrics_align_settings set blocked_until = now() - interval '1 s'")
    only(T2); o, e = claim(); c2 = J(o); o, e = fail(T2, c2["token"], "AI_AUTH")
    ok("7 トークン無効（AI_AUTH）：全体を停止（運営が再開するまで）", J(o)["status"] == "paused" and q("select paused::text || pause_reason from aimuse_private.lyrics_align_settings")[0] == "trueai_auth", o)
    q("select public.admin_align_set_paused(false)", "admin")
    only(T2); o, e = claim(); c2 = J(o)
    q(f"update aimuse_private.lyrics_align_jobs set lease_until = now() - interval '1 s' where track_id = '{T2}'")
    o, e = claim(); j = job(T2)
    ok("7 解析中のまま止まった曲（10分）は、試行1回として数えて30分後に再試行", j["state"] == "queued" and j["attempts"] == 1 and j["last_error"] == "STALLED", (j["state"], j["attempts"]))
    o, e = fail(T2, c2["token"], "AI_ERROR"); ok("7 止まった後に古い札で記録しようとしても無視（stale）", J(o)["status"] == "stale", o)
    o, e = q("select public.lyrics_align_fail('" + T2 + "', gen_random_uuid(), 'x; select 1')", "service"); ok("7 失敗の理由は決まった形以外は受け付けない（札も違うので無視）", J(o)["status"] == "stale", o)
    # 1日の上限
    o, e = q("select public.admin_align_set_cap(9000)", "admin"); ok("5 上限は 8,000 までしか設定できない", "BAD_DATA" in e, e[:60])
    q(f"select public.admin_align_set_cap({est + 10})", "admin")
    ready(); o, e = claim(); ok("5 その日の予約が上限を超える場合は取り出さない（daily_cap）", J(o)["status"] == "daily_cap", o)
    q("select public.admin_align_set_cap(6000)", "admin")
    # 8. 状態・採用・手動の同期を守る
    owner = "a" if T1 == TA else "b"; other = "b" if owner == "a" else "a"
    o, e = q(f"select public.lyrics_align_status('{T1}')", owner); s1 = J(o)
    ok("8 本人は状態と提案を見られる", s1 and s1["state"] == "review" and s1["proposal"] and s1["meta"]["ratio"] == 1 and "lyrics_hash" not in s1["meta"], o or e)
    o, e = q("select json_agg(x) from public.lyrics_align_my_states() x", owner); ms = J(o)
    mine = set(q(f"select string_agg(id::text, ',') from public.tracks where user_id = '{U[owner]}'")[0].split(","))
    ok("8 自分の曲の状態の一覧（他人の曲は含まない）", ms and all(x["track_id"] in mine for x in ms) and any(x["has_proposal"] and x["track_id"] == T1 for x in ms), len(ms or []))
    edited = [{"i": 1, "t": 12.6}, {"i": 3, "t": 20}, {"i": 5, "t": 39.1, "e": 45}, {"i": 6, "t": 50}]
    o, e = q(f"select public.lyrics_align_apply('{T1}', '{json.dumps(edited)}'::jsonb)", owner); a1 = J(o)
    ok("8 本人が直して採用 → 同期の時刻になる（mixed）", a1 and a1["source"] == "mixed" and sync(T1)["source"] == "mixed", o or e)
    rv = a1["review"]; ok("8 人が直した量を記録（比べた4行・直した2行・差の中央値・最大）", rv["compared"] == 4 and rv["changed"] == 2 and rv["max_abs"] == 1 and rv["median_abs"] == 0.15, rv)
    o, e = q(f"select public.lyrics_sync_get('{T1}')", "anon"); ok("8 採用した同期は再生画面で読める（未ログインでも）", "12.6" in o, o[:80])
    # 手を加えずに採用 → auto、人が保存し直すと mixed
    o, e = q(f"select public.lyrics_align_apply('{T1}')", owner); ok("8 手を加えずに採用 → auto", J(o)["source"] == "auto", o or e)
    o, e = q(f"select public.lyrics_sync_save('{T1}', '{json.dumps(GOOD)}'::jsonb)", owner); ok("8 AI の同期を人が保存し直すと mixed（以後 AI は置き換えない）", J(o)["source"] == "mixed", o or e)
    # 手動の同期がある曲
    q(f"select public.lyrics_sync_save('{TB if T1 == TA else TA}', '[{{\"i\":1,\"t\":5}}]'::jsonb)", "b" if T1 == TA else "a")
    T3 = TB if T1 == TA else TA; own3 = "b" if T1 == TA else "a"
    q(f"update public.tracks set lyrics = lyrics where id = '{T3}'", "admin")
    o, e = q(f"select public.admin_align_enqueue('{T3}')", "admin")
    ok("8 手動で合わせた曲は自動では解析しない（has_sync）", job(T3)["state"] in ("skipped",) and job(T3)["reason"] == "has_sync", (o, job(T3)["state"], job(T3)["reason"]))
    o, e = q(f"select public.lyrics_align_request('{T3}')", own3); ok("8 本人が頼めば解析する（結果は提案だけ）", J(o) == {"result": "queued"}, o or e)
    only(T3); o, e = claim(); c3 = J(o); o, e = finish(T3, c3["token"], GOOD, META_OK)
    ok("8 手動の同期はそのまま（提案は別に保存）", sync(T3)["source"] == "manual" and sync(T3)["lines"] == [{"i": 1, "t": 5}] and job(T3)["state"] == "review", sync(T3))
    o, e = q(f"select public.lyrics_align_apply('{T3}')", "admin"); ok("8 運営でも、投稿者の手動の同期を提案で置き換えられない", "NOT_ALLOWED" in e, e[:80])
    o, e = q(f"select public.lyrics_align_dismiss('{T3}')", own3); ok("8 本人は提案を「使わない」にできる（同期はそのまま）", J(o) == {"ok": True} and job(T3)["state"] == "dismissed" and sync(T3)["source"] == "manual", o or e)
    o, e = q(f"select public.lyrics_align_apply('{T3}')", own3); ok("8 本人なら、後から提案を採用して置き換えられる", J(o)["source"] == "auto" and sync(T3)["source"] == "auto", o or e)
    # 歌詞が変わると提案は使えない
    q(f"update public.tracks set lyrics = array_append(lyrics, 'さらに') where id = '{T3}'", "admin")
    o, e = q(f"select public.lyrics_align_status('{T3}')", own3); s3 = J(o)
    ok("8 歌詞が変わったら古い提案は返さず、自動で解析待ちへ", s3["proposal"] is None and s3["state"] == "queued", (s3["state"], s3["proposal"]))
    o, e = q(f"select public.lyrics_align_apply('{T3}')", own3); ok("8 古い歌詞の提案は採用できない", "NO_PROPOSAL" in e, e[:60])
    # 自動で表示する設定（初期はオフ）
    q("update aimuse_private.lyrics_align_settings set auto_apply = true")
    ready(); o, e = claim(); c4 = J(o); T4 = c4["track_id"]
    o, e = finish(T4, c4["token"], GOOD, META_OK)
    ok("8 （将来）自動で表示する設定がオンで、品質に合格し、AI の同期だけの曲 → 自動で表示（auto）", J(o)["status"] == "applied" and sync(T4)["source"] == "auto", (o, sync(T4)))
    q("update aimuse_private.lyrics_align_settings set auto_apply = false")
    # 9. 「作り直す」の回数制限
    q("truncate aimuse_private.lyrics_align_requests")
    q(f"update aimuse_private.lyrics_align_jobs set state = 'review' where track_id = '{TA}'")
    res = [q(f"select public.lyrics_align_request('{TA}')", "a") for _ in range(3)]
    for k in range(2):
        if J(res[k][0]) == {"result": "queued"}:
            q(f"update aimuse_private.lyrics_align_jobs set state = 'review' where track_id = '{TA}'")
    ok("9 1曲につき1日2回まで（3回目は LIMIT）", "LIMIT" in res[2][1] and not res[0][1] and not res[1][1], [x[1][:40] for x in res])
    q("truncate aimuse_private.lyrics_align_requests")
    q("insert into aimuse_private.lyrics_align_requests (user_id, track_id) select '" + U["a"] + "', gen_random_uuid() from generate_series(1, 5)")
    o, e = q(f"select public.lyrics_align_request('{TA}')", "a"); ok("9 1人につき1日5回まで", "LIMIT" in e, e[:60])
    o, e = q(f"select public.lyrics_align_status('{TA}')", "a"); ok("9 残りの回数を返す", J(o)["requests_left"] == 0, o[:120])
    q("update public.profiles set is_banned = true where id = '" + U["a"] + "'")
    o, e = q(f"select public.lyrics_align_request('{TA}')", "a"); ok("9 利用停止中の会員は頼めない", "NOT_ALLOWED" in e, e[:60])
    q("update public.profiles set is_banned = false where id = '" + U["a"] + "'")
    # 10. 運営の画面・合言葉
    o, e = q("select public.admin_align_overview()", "admin"); ov = J(o)
    ok("10 運営の一覧：設定・今日の予約・状態ごとの数・精度・曲の一覧", ov and ov["settings"]["daily_cap"] == 6000 and ov["today"]["reserved"] > 0 and ov["counts"].get("waiting", 0) > 0 and ov["accuracy"]["songs"] >= 1 and len(ov["jobs"]) > 0, o[:200] or e)
    o, e = q("select public.admin_align_set_paused(true)", "admin"); ok("10 運営は停止できる", J(o) == {"paused": True} and J(claim()[0])["status"] == "paused")
    q("insert into vault.secrets (name, secret) values ('aimuse_align_secret', repeat('k', 64))")
    o1, _ = q("select public.lyrics_align_secret_matches(repeat('k', 64))", "service"); o2, _ = q("select public.lyrics_align_secret_matches(repeat('x', 64))", "service"); o3, _ = q("select public.lyrics_align_secret_matches('short')", "service")
    ok("10 合言葉の照合（一致・不一致・短い）", (o1, o2, o3) == ("t", "f", "f"), (o1, o2, o3))
    o, e = q(f"select public.admin_align_retry('{TA}')", "admin"); ok("10 やり直しは打ち切り・対象外・不採用の曲だけ", "BAD_DATA" in e or J(o), e[:60])
    # 11. 曲の削除
    q("delete from public.tracks where id = '20000000-0000-4000-8000-0000000aa001'")
    ok("11 曲を削除すると解析待ちも消える", job("20000000-0000-4000-8000-0000000aa001") is None)
    # 12. 元に戻す
    sync_before = q("select md5(string_agg(t::text, '|' order by track_id)) from public.track_lyrics_sync t")[0]
    o, e = q(RB); ok("12 元に戻せる（表・関数・トリガーが無くなる）", not e and q("select to_regclass('aimuse_private.lyrics_align_jobs') is null and to_regprocedure('public.lyrics_align_claim()') is null and not exists (select 1 from pg_trigger where tgname = 'tracks_lyrics_align')")[0] == "t", e)
    ok("12 元に戻しても同期の時刻は残る", q("select md5(string_agg(t::text, '|' order by track_id)) from public.track_lyrics_sync t")[0] == sync_before)
    o, e = q(f"select public.lyrics_sync_save('{TA}', '[{{\"i\":1,\"t\":3}}]'::jsonb)", "a"); ok("12 元に戻した後の保存は v1.14 と同じ（manual）", not e and sync(TA)["source"] == "manual", e)
    o, e = q(MIG); ok("12 再適用できる（停止中から）", not e and q("select paused from aimuse_private.lyrics_align_settings")[0] == "t", e)
    q("drop database if exists t115", db="postgres")
print(f"\n合計 {len(R)} 件 / 不合格 {R.count(False)} 件")
sys.exit(1 if False in R else 0)
