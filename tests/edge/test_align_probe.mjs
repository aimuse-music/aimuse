// Edge Function「lyrics-align-probe」の処理本体（probe.js）のテスト。Supabase と Cloudflare は偽物で再現（実際の通信はしない）
// 使い方: node tests/edge/test_align_probe.mjs
import { handleProbe, toBase64, promptFrom, MODEL } from "../../supabase/functions/lyrics-align-probe/probe.js";
import fs from "node:fs";
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? "PASS" : "FAIL"}] ${n}${i !== undefined ? "  → " + JSON.stringify(i).slice(0, 220) : ""}`); };

const SECRET = "s".repeat(64), TOKEN = "cf-token-XYZ-" + "t".repeat(30), ACCT = "0123456789abcdef0123456789abcdef";
const TRACK = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1";
const LYR = ["[Verse 1]", "あの夜は　少し寒くて", "君と歩いた", "", "【Chorus】", "おぼろ月の下で", "君の名前を呼んだ", "[Outro]", "おぼろ月"];
const AUDIO = new Uint8Array(300_000).map((_, i) => (i * 31) % 256);
const CF_OK = { success: true, errors: [], result: { text: "あの夜は少し寒くて君と歩いたおぼろ月の下で君の名前を呼んだおぼろ月",
  segments: [{ start: 12, end: 18, text: "あの夜は少し寒くて 君と歩いた", words: [{ word: "あの夜は", start: 12, end: 13.2 }, { word: "少し寒くて", start: 13.3, end: 15 }, { word: "君と歩いた", start: 15.5, end: 17.8 }] },
    { start: 30, end: 36, text: "おぼろ月の下で 君の名前を呼んだ", words: [{ word: "おぼろ月の下で", start: 30, end: 32.5 }, { word: "君の名前を呼んだ", start: 33, end: 35.8 }] },
    { start: 50, end: 52, text: "おぼろ月", words: [{ word: "おぼろ月", start: 50, end: 51.6 }] }] } };

function world(o = {}) {
  const log = [];
  const env = (k) => ({ CF_ACCOUNT_ID: ACCT, CF_AI_TOKEN: TOKEN, ...(o.env || {}) })[k] ?? null;
  const admin = {
    async rpc(name, args) { log.push({ rpc: name }); if (o.noRpc) return { data: null, error: { message: "function not found" } }; return { data: name === "align_probe_secret_matches" && args.p_secret === SECRET, error: null }; },
    auth: { async getUser(jwt) { return jwt === "jwt-admin" ? { data: { user: { id: "u-admin" } }, error: null } : jwt === "jwt-member" ? { data: { user: { id: "u-member" } }, error: null } : { data: { user: null }, error: { status: 401 } }; } },
  };
  const keys = { url: "https://p.supabase.co", secret: "sb_secret_K", publishable: "sb_publishable_P" };
  const fetchImpl = async (url, init = {}) => {
    const method = init.method || "GET"; log.push({ url, method, headers: init.headers || {}, body: init.body });
    const J = (s, b) => ({ ok: s >= 200 && s < 300, status: s, json: async () => b, arrayBuffer: async () => new ArrayBuffer(0) });
    if (url.includes("/rest/v1/profiles")) return J(200, [{ is_admin: url.includes("u-admin") && !o.bannedAdmin, is_banned: !!o.bannedAdmin }]);
    if (url.includes("/rest/v1/tracks")) return o.noTrack ? J(200, []) : J(200, [{ id: TRACK, title: "おぼろ月", lyrics: o.lyrics || LYR, audio_path: "u-admin/" + TRACK + ".mp3", duration: o.duration ?? 258 }]);
    if (url.includes("/storage/v1/object/audio/")) { if (o.audioFail) return J(404, {}); const b = o.bigAudio ? new Uint8Array(21 * 1024 * 1024) : AUDIO; return { ok: true, status: 200, arrayBuffer: async () => b.buffer.slice(0) }; }
    if (url.startsWith("https://api.cloudflare.com/")) {
      if (o.cfThrow) { const e = new Error("aborted"); e.name = o.cfThrow; throw e; }
      if (o.cf) return J(o.cf.status, o.cf.body);
      return J(200, CF_OK);
    }
    return J(404, {});
  };
  return { log, env, admin, keys, fetchImpl };
}
const run = (o = {}, a = {}) => { const w = world(o); return handleProbe({ admin: w.admin, keys: w.keys, env: w.env, fetchImpl: w.fetchImpl, body: a.body ?? { track_id: TRACK }, callerSecret: a.secret ?? null, userJwt: a.jwt ?? "" }).then((r) => ({ ...r, log: w.log })); };

// 1. 呼び出し元の確認
let r = await run({}, {}); ok("1 合言葉もログイン情報も無ければ 401（Cloudflare を呼ばない）", r.status === 401 && !r.log.some((l) => String(l.url || "").includes("cloudflare")));
r = await run({}, { secret: "x".repeat(64) }); ok("1 違う合言葉は 403", r.status === 403 && r.body.code === "FORBIDDEN");
r = await run({}, { secret: "short" }); ok("1 短い合言葉は合言葉として扱わず 401", r.status === 401);
r = await run({ noRpc: true }, { secret: SECRET }); ok("1 照合の関数が無い（準備前）は 503", r.status === 503 && r.body.code === "NOT_CONFIGURED");
r = await run({}, { jwt: "jwt-member" }); ok("1 管理者でない会員は 403", r.status === 403 && r.body.code === "ADMIN_ONLY");
r = await run({ bannedAdmin: true }, { jwt: "jwt-admin" }); ok("1 利用停止中は 403", r.status === 403);
r = await run({}, { jwt: "forged" }); ok("1 偽のログイン情報は 401", r.status === 401);
// 2. 設定
r = await run({ env: { CF_AI_TOKEN: null } }, { secret: SECRET }); ok("2 トークンが未設定なら 503（Cloudflare を呼ばない）", r.status === 503 && !r.log.some((l) => String(l.url || "").includes("cloudflare")));
r = await run({ env: { CF_ACCOUNT_ID: "../x" } }, { secret: SECRET }); ok("2 アカウントIDの形式が違えば 503", r.status === 503);
// 3. 対象の曲
r = await run({}, { secret: SECRET, body: { track_id: "1;drop" } }); ok("3 曲IDの形式が違えば 400", r.status === 400);
r = await run({ noTrack: true }, { secret: SECRET }); ok("3 曲が無ければ 404", r.status === 404);
r = await run({ lyrics: ["[Intro]", ""] }, { secret: SECRET }); ok("3 歌詞が無ければ 422（解析しない）", r.status === 422 && r.body.code === "NO_LYRICS" && !r.log.some((l) => String(l.url || "").includes("storage")));
r = await run({ duration: 900 }, { secret: SECRET }); ok("3 10分を超える曲は 422（無料枠を守る）", r.status === 422 && r.body.code === "TOO_LONG");
r = await run({ audioFail: true }, { secret: SECRET }); ok("3 音源を取り出せなければ 502", r.status === 502 && r.body.code === "AUDIO_UNAVAILABLE");
r = await run({ bigAudio: true }, { secret: SECRET }); ok("3 20MB を超える音源は 422（Cloudflare を呼ばない）", r.status === 422 && !r.log.some((l) => String(l.url || "").includes("cloudflare")));
// 4. Cloudflare の失敗
r = await run({ cf: { status: 429, body: { success: false, errors: [{ code: 4006, message: "you have used up your daily free allocation" }] } } }, { secret: SECRET });
ok("4 無料枠を使い切ったら FREE_LIMIT（429）", r.status === 429 && r.body.code === "FREE_LIMIT");
r = await run({ cf: { status: 200, body: { success: false, errors: [{ code: 4006 }] } } }, { secret: SECRET }); ok("4 エラー番号 4006 でも FREE_LIMIT", r.body.code === "FREE_LIMIT");
r = await run({ cf: { status: 401, body: { success: false, errors: [{ code: 10000 }] } } }, { secret: SECRET }); ok("4 トークンが無効なら AI_AUTH", r.status === 502 && r.body.code === "AI_AUTH");
r = await run({ cf: { status: 500, body: { success: false, errors: [{ code: 3043, message: "internal" }] } } }, { secret: SECRET }); ok("4 その他の失敗は AI_ERROR（エラー番号だけを返す）", r.body.code === "AI_ERROR" && JSON.stringify(r.body.cf_codes) === "[3043]" && !JSON.stringify(r.body).includes("internal"));
r = await run({ cfThrow: "AbortError" }, { secret: SECRET }); ok("4 時間切れは AI_TIMEOUT", r.status === 504 && r.body.code === "AI_TIMEOUT");
r = await run({ cfThrow: "TypeError" }, { secret: SECRET }); ok("4 接続できなければ AI_UNREACHABLE", r.status === 504 && r.body.code === "AI_UNREACHABLE");
// 5. 成功
r = await run({}, { secret: SECRET });
const cf = r.log.find((l) => String(l.url || "").startsWith("https://api.cloudflare.com/"));
const sent = JSON.parse(cf.body);
ok("5 成功：200・各行の推定と確認用の代表行を返す", r.status === 200 && r.body.lines.length === 5 && r.body.checkpoints.length >= 3, r.body.checkpoints);
ok("5 代表行：歌い出し・最初のサビ・最後の行", ["歌い出し（最初の行）", "最初のサビ", "最後の行"].every((k) => r.body.checkpoints.some((c) => c.label === k)) && r.body.checkpoints.find((c) => c.label === "最初のサビ").text === "おぼろ月の下で");
ok("5 推定した時刻（単語の時刻あり）", r.body.granularity === "word" && Math.abs(r.body.lines[0].t - 12) < 0.3 && Math.abs(r.body.lines[2].t - 30) < 0.3, r.body.lines.map((x) => x.t));
ok("5 Cloudflare へは指定のモデル・アカウントの URL に、トークンを Authorization で送る", cf.url === `https://api.cloudflare.com/client/v4/accounts/${ACCT}/ai/run/${MODEL}` && cf.headers.Authorization === `Bearer ${TOKEN}`);
ok("5 音源を Base64 にして送る（元のデータと一致）・日本語・無音の除去", sent.audio === Buffer.from(AUDIO).toString("base64") && sent.language === "ja" && sent.vad_filter === true && !("initial_prompt" in sent));
ok("5 返す内容・記録にトークンと管理用のキーが含まれない", !JSON.stringify(r.body).includes(TOKEN) && !JSON.stringify(r.body).includes("sb_secret") && !JSON.stringify(r.body).includes(SECRET));
ok("5 データベースに書き込まない（読み取りと照合の関数だけ）", r.log.filter((l) => l.url && l.url.includes("/rest/v1/")).every((l) => l.method === "GET") && r.log.filter((l) => l.rpc).every((l) => l.rpc === "align_probe_secret_matches"));
ok("5 音源は管理用のキーで非公開の保存場所から取り出す（Cloudflare には管理用のキーを送らない）", r.log.find((l) => String(l.url || "").includes("/storage/")).headers.apikey === "sb_secret_K" && !JSON.stringify(cf.headers).includes("sb_secret"));
ok("5 使うニューロンの見積もり（4分18秒で約200）", r.body.neurons_estimate === 201, r.body.neurons_estimate);
r = await run({}, { secret: SECRET, body: { track_id: TRACK, prompt: true } });
const sent2 = JSON.parse(r.log.find((l) => String(l.url || "").startsWith("https://api.cloudflare.com/")).body);
ok("5 prompt: true のときだけ、歌詞の先頭（見出しを除く・120文字まで）を手がかりに渡す", sent2.initial_prompt === promptFrom(LYR) && !sent2.initial_prompt.includes("Verse") && sent2.initial_prompt.length <= 120);
r = await run({}, { jwt: "jwt-admin" }); ok("5 管理者のログイン情報でも実行できる", r.status === 200 && r.body.caller === "admin");
// 6. そのほか
ok("6 Base64 の変換は大きなデータでも正しい", toBase64(new Uint8Array(200_000).fill(255)) === Buffer.alloc(200_000, 255).toString("base64"));
const a = fs.readFileSync(new URL("../../supabase/functions/account-purge/supa.js", import.meta.url), "utf8"), b = fs.readFileSync(new URL("../../supabase/functions/lyrics-align-probe/supa.js", import.meta.url), "utf8");
ok("6 接続部品（supa.js）は他の関数と同じ内容", a === b);

const f = R.filter((x) => !x[1]); console.log(`\n合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach((x) => console.log("  FAIL:", x[0]));
process.exit(f.length ? 1 : 0);
