// Edge Function「lyrics-align」の処理本体（worker.js）のテスト
// データベースは手元の PostgreSQL 17 に v1.14＋v1.15 を入れたものを service_role で実際に呼ぶ（本番と同じく service_role に表の権限なし）。
// 音源の保存場所と Cloudflare Workers AI は偽物（失敗・無料枠切れ・時間切れを注入できる）。
// 使い方: node tests/edge/test_lyrics_align.mjs [ポート]（既定 55417。テンプレート prod111）
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import { handleRun, MODEL } from "../../supabase/functions/lyrics-align/worker.js";

const PORT = process.argv[2] || "55417";
const ROOT = new URL("../../", import.meta.url).pathname;
const DB = "t115e";
const pg = (sql, db = DB) => {
  try { return { out: execFileSync("psql", ["-h", "/opt/pgx", "-p", PORT, "-U", "postgres", "-X", "-At", "-q", "-d", db, "-v", "ON_ERROR_STOP=1"], { input: sql, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }).trim(), err: null }; }
  catch (e) { return { out: "", err: String(e.stderr || e.message).split("\n").find((l) => l.includes("ERROR")) || String(e.message) }; }
};
const lit = (v) => (v === null || v === undefined ? "null" : `'${String(typeof v === "object" ? JSON.stringify(v) : v).replace(/'/g, "''")}'`);
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? "PASS" : "FAIL"}] ${n}${i !== undefined ? "  → " + JSON.stringify(i).slice(0, 220) : ""}`); };

// 準備：v1.14・v1.15・金庫の代わり
pg(`drop database if exists ${DB}`, "postgres"); pg(`create database ${DB} template prod111`, "postgres");
const setup = `create schema if not exists vault;
create table if not exists vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text, created_at timestamptz default now());
create or replace view vault.decrypted_secrets as select id, name, secret as decrypted_secret, created_at from vault.secrets;
revoke all on schema vault from public;
revoke select, insert, update, delete on all tables in schema public from service_role;`;
for (const s of [setup, fs.readFileSync(ROOT + "supabase/migration_v1_14_lyrics_sync.sql", "utf8"), fs.readFileSync(ROOT + "supabase/migration_v1_15_lyrics_auto_sync.sql", "utf8")]) {
  const r = pg(s); if (r.err) { console.log("setup failed", r.err); process.exit(1); }
}
const SECRET = "s".repeat(64);
pg(`insert into vault.secrets (name, secret) values ('aimuse_align_secret', '${SECRET}')`);
const LYR = ["[Verse 1]", "あの夜は　少し寒くて", "君と肩を寄せ合って歩いた", "白い息が　夜空に溶けて", "何も言えずに笑ってた", "", "【Chorus】", "おぼろ月の下で", "君の名前を呼んだ",
  "届かなくても　いいから", "この想いだけは消さないで", "", "[Verse 2]", "季節はめぐり　春が来て", "桜の道を一人で歩く", "あの日の君の横顔を", "今でも覚えているよ", "",
  "[Chorus]", "おぼろ月の下で", "君の名前を呼んだ", "届かなくても　いいから", "この想いだけは消さないで", "[Outro]", "おぼろ月"];
const TRUE = {}; { let t = 12; LYR.forEach((l, i) => { if (!l.trim() || /^\s*(\[|【)/.test(l)) { if (/Verse 2|Chorus\]|Outro/.test(l)) t += 9; return; } TRUE[i] = t; t += [...l].length * 0.33 + 0.6; }); }
const T = ["20000000-0000-4000-8000-000000000001", "20000000-0000-4000-8000-000000000002", "20000000-0000-4000-8000-000000000006"];
const lyrLit = "array[" + LYR.map((l) => `'${l}'`).join(",") + "]::text[]";
pg(`update public.tracks set lyrics = ${lyrLit}, duration = 180, audio_size = 4000000 where id in (${T.map(lit).join(",")})`);
const call = (name, args = {}) => {
  const params = Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}${typeof v === "object" && v !== null ? "::jsonb" : ""}`).join(", ");
  const r = pg(`begin; set local role service_role; set local request.jwt.claims='{"role":"service_role"}';
    select coalesce(json_agg(t), '[]') from (select * from public.${name}(${params})) t; commit;`);
  if (r.err) return { data: null, error: { message: r.err } };
  const rows = JSON.parse(r.out || "[]");
  return rows.length === 1 && Object.keys(rows[0]).length === 1 && Object.keys(rows[0])[0] === name ? { data: rows[0][name], error: null } : { data: rows, error: null };
};
const admin = (inject = {}) => ({ calls: [], async rpc(name, args) { this.calls.push(name); if (inject[name]) return inject[name](args); return call(name, args); } });
const asAdmin = (sql) => pg(`begin; set local role authenticated; set local request.jwt.claims='{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}'; ${sql}; commit;`);
const job = (id) => JSON.parse(pg(`select to_jsonb(j) from aimuse_private.lyrics_align_jobs j where track_id = '${id}'`).out || "null");
const only = (id) => pg(`update aimuse_private.lyrics_align_jobs set next_try_at = case when track_id = '${id}' then now() - interval '1 s' else now() + interval '1 day' end where state = 'queued'`);

// Whisper に似た結果（単語の時刻つき・誤認識を少し含む）
function whisper({ drop = [], shift = 0 } = {}) {
  const segs = [];
  Object.keys(TRUE).map(Number).filter((i) => !drop.includes(i)).forEach((i) => {
    const cs = [...LYR[i].replace(/\s/g, "").replace("寒くて", "さむくて").replace("名前", "なまえ")]; const st = TRUE[i] + shift, d = 0.33;
    const words = []; for (let q = 0; q < cs.length; q += 3) words.push({ word: cs.slice(q, q + 3).join(""), start: st + q * d, end: st + Math.min(cs.length, q + 3) * d });
    segs.push({ start: st, end: st + cs.length * d, text: cs.join(""), words });
  });
  return { text: segs.map((s) => s.text).join(" "), segments: segs, transcription_info: {} };
}
const AUDIO = new Uint8Array(4096).map((_, k) => k % 251);
function fakeFetch(opt = {}) {
  const log = [];
  const f = async (url, init = {}) => {
    log.push({ url: String(url), headers: init.headers || {}, body: init.body });
    if (String(url).includes("/storage/v1/object/audio/")) {
      if (opt.audio === "404") return new Response("", { status: 404 });
      if (opt.audio === "big") return new Response(new Uint8Array(21 * 1024 * 1024), { status: 200 });
      return new Response(AUDIO, { status: 200 });
    }
    if (String(url).startsWith("https://api.cloudflare.com/")) {
      if (opt.ai === "timeout") { const e = new Error("aborted"); e.name = "AbortError"; throw e; }
      if (opt.ai === "free") return Response.json({ success: false, errors: [{ code: 4006, message: "daily free allocation" }] }, { status: 429 });
      if (opt.ai === "auth") return Response.json({ success: false, errors: [{ code: 10000, message: "Authentication error" }] }, { status: 401 });
      if (opt.ai === "500") return Response.json({ success: false, errors: [{ code: 3000 }] }, { status: 500 });
      if (opt.beforeAi) opt.beforeAi();
      return Response.json({ success: true, result: opt.result || whisper() });
    }
    return new Response("", { status: 404 });
  };
  return { f, log };
}
const ENV = { AIMUSE_ALIGN_ENABLED: "1", CF_ACCOUNT_ID: "0123456789abcdef0123456789abcdef", CF_AI_TOKEN: "cf-token-SECRET-xyz" };
const keys = { url: "https://proj.supabase.co", secret: "sb_secret_TEST", publishable: "sb_publishable_TEST" };
const run = (o = {}) => { const ff = fakeFetch(o.fetch); const a = admin(o.inject); return handleRun({ admin: a, keys, callerSecret: o.secret === undefined ? SECRET : o.secret, env: (k) => ({ ...ENV, ...(o.env || {}) })[k] ?? null, fetchImpl: ff.f }).then((r) => ({ ...r, log: ff.log, calls: a.calls })); };

// 1. 呼び出し元・切り替え
let r = await run({ secret: null }); ok("1 合言葉なしは 401（データベースも呼ばない）", r.status === 401 && r.calls.length === 0);
r = await run({ secret: "x".repeat(64) }); ok("1 合言葉が違えば 403（取り出さない）", r.status === 403 && !r.calls.includes("lyrics_align_claim"));
r = await run({ env: { AIMUSE_ALIGN_ENABLED: null } }); ok("1 AIMUSE_ALIGN_ENABLED が無ければ何もしない（disabled）", r.status === 200 && r.body.status === "disabled" && !r.calls.includes("lyrics_align_claim"));
r = await run({ env: { CF_AI_TOKEN: null } }); ok("1 Cloudflare の設定が無ければ 503（取り出さない）", r.status === 503 && !r.calls.includes("lyrics_align_claim"));
// 2. 停止中
asAdmin(`select public.admin_align_enqueue_existing()`);
r = await run(); ok("2 停止中（適用直後）は取り出さず、音源も AI も使わない", r.body.status === "paused" && r.log.length === 0, r.body);
asAdmin(`select public.admin_align_set_paused(false)`);
// 3. 成功
only(T[0]);
r = await run();
const cf = r.log.find((l) => l.url.startsWith("https://api.cloudflare.com/")); const sent = cf && JSON.parse(cf.body);
ok("3 成功：提案として保存（review・品質に合格）", r.status === 200 && r.body.status === "review" && r.body.quality_ok === true && r.body.ratio === 1, r.body);
ok("3 Cloudflare へは vad_filter=false・日本語・手がかりなし・指定のモデル", sent && sent.vad_filter === false && sent.language === "ja" && sent.condition_on_previous_text === false && !("initial_prompt" in sent) && cf.url.endsWith("/ai/run/" + MODEL));
ok("3 音源をそのまま Base64 で送る", sent.audio === Buffer.from(AUDIO).toString("base64"));
ok("3 トークンは Authorization だけ。管理用のキーは Cloudflare に送らない", cf.headers.Authorization === "Bearer " + ENV.CF_AI_TOKEN && !JSON.stringify(cf.headers).includes("sb_secret"));
ok("3 返す内容にトークン・合言葉・歌詞・管理用のキーを含めない", !JSON.stringify(r.body).includes("SECRET") && !JSON.stringify(r.body).includes(SECRET) && !JSON.stringify(r.body).includes("おぼろ") && !JSON.stringify(r.body).includes("sb_secret"));
let j = job(T[0]);
ok("3 提案の時刻は正解に近い（各行 0.5秒以内）", j.proposal.length === 17 && j.proposal.every((x) => Math.abs(x.t - TRUE[x.i]) <= 0.5), j.proposal.slice(0, 3));
ok("3 同期の時刻そのものは書き換えない（確認待ち）", pg(`select count(*) from public.track_lyrics_sync`).out === "0");
ok("3 データベースの関数だけを使う（表を直接読み書きしない）", r.calls.every((n) => ["lyrics_align_secret_matches", "lyrics_align_claim", "lyrics_align_finish"].includes(n)) && !r.log.some((l) => l.url.includes("/rest/v1/")));
ok("3 今日の予約量を記録（約170 ＝ 3分×46.63×1.2）", pg(`select reserved from aimuse_private.lyrics_align_budget`).out === String(Math.ceil(180 / 60 * 46.63 * 1.2)));
// 4. 品質が低い（中盤が丸ごと聞き取れない）
only(T[1]);
r = await run({ fetch: { result: whisper({ drop: [13, 14, 15, 16, 19, 20, 21, 22] }) } });
ok("4 中盤が聞き取れない結果は品質不合格（low_quality・理由 est_run）", r.body.status === "review" && r.body.quality_ok === false && r.body.reasons.includes("est_run") && job(T[1]).reason === "low_quality", r.body);
// 5. 失敗：音源なし → 再試行、3回で打ち切り
only(T[2]);
r = await run({ fetch: { audio: "404" } }); ok("5 音源を取り出せない → 再試行の予定（AI は呼ばない）", r.body.code === "AUDIO_UNAVAILABLE" && r.body.result === "retry" && !r.log.some((l) => l.url.includes("cloudflare")), r.body);
only(T[2]); r = await run({ fetch: { ai: "500" } }); ok("5 AI の失敗 → 2回目の再試行の予定", r.body.code === "AI_ERROR" && r.body.result === "retry" && job(T[2]).attempts === 2);
only(T[2]); r = await run({ fetch: { ai: "timeout" } }); ok("5 時間切れ → 3回目で打ち切り（無料枠を使い続けない）", r.body.code === "AI_TIMEOUT" && r.body.result === "failed" && job(T[2]).state === "failed");
only(T[2]); r = await run(); ok("5 打ち切った曲は、もう取り出さない", r.body.status === "idle" && r.log.length === 0, r.body);
// 6. 無料枠切れ・トークン無効
asAdmin(`select public.admin_align_retry('${T[2]}')`); only(T[2]);
r = await run({ fetch: { ai: "free" } }); ok("6 Cloudflare の無料枠切れ → 翌日まで全体を止める", r.body.code === "FREE_LIMIT" && r.body.result === "blocked");
r = await run(); ok("6 止めている間は、音源も AI も使わない", r.body.status === "blocked" && r.log.length === 0, r.body);
pg(`update aimuse_private.lyrics_align_settings set blocked_until = now() - interval '1 s'`); only(T[2]);
r = await run({ fetch: { ai: "auth" } }); ok("6 トークン無効 → 全体を停止（運営が直して再開するまで）", r.body.code === "AI_AUTH" && r.body.result === "paused");
r = await run(); ok("6 停止中は何もしない", r.body.status === "paused" && r.log.length === 0);
asAdmin(`select public.admin_align_set_paused(false)`);
// 7. 解析中に歌詞が変わった
only(T[2]);
r = await run({ fetch: { beforeAi: () => asAdmin(`update public.tracks set lyrics = array_append(lyrics, '追加') where id = '${T[2]}'`) } });
ok("7 解析中に歌詞が変わったら結果を捨てて解析待ちへ（requeued）", r.body.status === "requeued" && job(T[2]).state === "queued" && job(T[2]).proposal === null, r.body);
// 8. 保存に失敗した（データベースの一時的な失敗）
only(T[2]);
r = await run({ inject: { lyrics_align_finish: () => ({ data: null, error: { message: "network (injected)" } }) } });
ok("8 結果の保存に失敗したら 502。解析中のまま残り、10分後にデータベースが戻す", r.status === 502 && job(T[2]).state === "running");
pg(`update aimuse_private.lyrics_align_jobs set lease_until = now() - interval '1 s' where track_id = '${T[2]}'`);
r = await run(); ok("8 止まった曲は試行1回として解析待ちに戻る（すぐには取り出さない）", job(T[2]).state === "queued" && job(T[2]).last_error === "STALLED", r.body);
// 9. 大きすぎる音源（保存場所の情報と実際の大きさが違った場合も）
only(T[2]);
r = await run({ fetch: { audio: "big" } }); ok("9 20MB を超える音源は解析しない（AI を呼ばない・対象外）", r.body.code === "AUDIO_TOO_LARGE" && r.body.result === "skipped" && !r.log.some((l) => l.url.includes("cloudflare")));
// 10. 同時に呼ばれても1曲だけ（データベースのロック）
asAdmin(`select public.admin_align_retry('${T[2]}')`); pg(`update aimuse_private.lyrics_align_jobs set state = 'queued', next_try_at = now() - interval '1 s' where track_id in ('${T[1]}', '${T[2]}')`);
const claimSql = `begin; set local role service_role; select public.lyrics_align_claim()->>'status'; select pg_sleep(0.5); commit;`;
const par = await Promise.all([0, 1, 2].map(() => new Promise((res) => { const p = spawn("psql", ["-h", "/opt/pgx", "-p", PORT, "-U", "postgres", "-X", "-At", "-q", "-d", DB, "-c", claimSql]); let o = ""; p.stdout.on("data", (d) => (o += d)); p.on("close", () => res(o.trim())); })));
ok("10 3つ同時に取り出しても、解析中になるのは1曲だけ", par.filter((x) => x === "claimed").length === 1 && pg(`select count(*) from aimuse_private.lyrics_align_jobs where state = 'running'`).out === "1", par);
// 11. 上限
pg(`update aimuse_private.lyrics_align_jobs set state = 'queued', token = null where state = 'running'`);
asAdmin(`select public.admin_align_set_cap(100)`);
only(T[1]); r = await run(); ok("11 その日の上限を超える曲は取り出さない（音源も AI も使わない）", r.body.status === "daily_cap" && r.log.length === 0, r.body);

pg(`drop database if exists ${DB}`, "postgres");
const f = R.filter((x) => !x[1]); console.log(`\n合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach((x) => console.log("  FAIL:", x[0]));
process.exit(f.length ? 1 : 0);
