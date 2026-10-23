// AIMUSE Edge Function「lyrics-align」の処理本体：歌詞の自動同期（AI）を1回の呼び出しで1曲だけ行う
// ・呼べるのは、データベースの金庫（Vault）の合言葉を持つ定期実行（cron_lyrics_align.sql）だけ。会員・未ログインは 401/403
// ・どの曲を解析するか・1日の上限・同時に1曲・再試行の制限は、すべてデータベースの関数が決める（ここでは決めない）
//     lyrics_align_claim → 音源を取り出す → Workers AI（Whisper・vad_filter=false）→ 歌詞と照合 → 品質の検査
//     → lyrics_align_finish（提案として保存）／失敗は lyrics_align_fail（理由の符号だけを送る）
// ・データベースの同期の時刻・歌詞・楽曲を直接書き換えることはない（関数が規則どおりに扱う）
// ・Cloudflare の API トークン・合言葉・歌詞・音源は、返す内容・記録に含めない
import { alignLyrics, assessQuality } from "./align.js";
import { keyHeaders } from "./supa.js";

export const MODEL = "@cf/openai/whisper-large-v3-turbo";
export const MAX_BYTES = 20 * 1024 * 1024;   // データベース側の上限と同じ
const AI_TIMEOUT_MS = 120_000;              // Supabase の待ち時間の上限（150秒）より短く
const reply = (status, body) => ({ status, body });

export function toBase64(bytes) {
  let s = ""; const CH = 0x8000;
  for (let i = 0; i < bytes.length; i += CH) s += String.fromCharCode.apply(null, bytes.subarray(i, i + CH));
  return btoa(s);
}

export async function handleRun({ admin, keys, callerSecret, env, fetchImpl = fetch, now = () => Date.now() }) {
  // 1. 呼び出し元（合言葉）
  if (!callerSecret || String(callerSecret).length < 32) return reply(401, { code: "LOGIN_REQUIRED" });
  const m = await admin.rpc("lyrics_align_secret_matches", { p_secret: String(callerSecret) });
  if (m.error) return reply(503, { code: "NOT_CONFIGURED" });
  if (m.data !== true) return reply(403, { code: "FORBIDDEN" });
  // 2. 非常用の切り替え（Secrets の AIMUSE_ALIGN_ENABLED が "1" のときだけ動く）
  if (env("AIMUSE_ALIGN_ENABLED") !== "1") return reply(200, { status: "disabled" });
  const acct = env("CF_ACCOUNT_ID"), token = env("CF_AI_TOKEN");
  if (!acct || !/^[0-9a-f]{32}$/i.test(acct) || !token) return reply(503, { code: "NOT_CONFIGURED" });
  // 3. 1曲だけ取り出す（停止中・上限・解析中の曲がある場合は取り出さない）
  const c = await admin.rpc("lyrics_align_claim", {});
  if (c.error) return reply(502, { code: "DB_ERROR" });
  const job = c.data || {};
  if (job.status !== "claimed") return reply(200, { status: job.status || "idle" });
  const fail = async (code, extra = {}) => {
    const f = await admin.rpc("lyrics_align_fail", { p_track: job.track_id, p_token: job.token, p_code: code });
    return reply(200, { status: "failed", code, result: f.data && f.data.status, ...extra });
  };
  if (!(job.duration > 0) || job.duration > 600) return fail("TOO_LONG");
  if (job.audio_size > MAX_BYTES) return fail("AUDIO_TOO_LARGE");
  // 4. 音源（非公開の保存場所から、管理用のキーで取り出す）
  const t0 = now();
  let bytes;
  try {
    const path = String(job.audio_path || "").split("/").map(encodeURIComponent).join("/");
    const r = await fetchImpl(`${keys.url}/storage/v1/object/audio/${path}`, { headers: keyHeaders(keys.secret) });
    if (!r.ok) return fail("AUDIO_UNAVAILABLE");
    bytes = new Uint8Array(await r.arrayBuffer());
  } catch (_) { return fail("AUDIO_UNAVAILABLE"); }
  if (!bytes.length) return fail("AUDIO_UNAVAILABLE");
  if (bytes.length > MAX_BYTES) return fail("AUDIO_TOO_LARGE");
  // 5. Workers AI（Whisper）。検証で中盤まで聞き取れた設定（vad_filter=false・手がかりなし）
  const input = { audio: toBase64(bytes), task: "transcribe", language: "ja", vad_filter: false, condition_on_previous_text: false };
  bytes = null;
  const t1 = now();
  const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), AI_TIMEOUT_MS);
  let res, json;
  try {
    res = await fetchImpl(`https://api.cloudflare.com/client/v4/accounts/${acct}/ai/run/${MODEL}`, {
      method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(input), signal: ctl.signal,
    });
    json = await res.json().catch(() => null);
  } catch (e) {
    return fail(e && e.name === "AbortError" ? "AI_TIMEOUT" : "AI_UNREACHABLE");
  } finally { clearTimeout(timer); }
  const t2 = now();
  const cfCodes = ((json && json.errors) || []).map((x) => x && x.code).filter((x) => typeof x === "number");
  if (res.status === 429 || cfCodes.includes(4006)) return fail("FREE_LIMIT");
  if (res.status === 401 || res.status === 403) return fail("AI_AUTH");
  if (!res.ok || !json || json.success === false || !json.result) return fail("AI_ERROR");
  // 6. 照合と品質の検査
  const lyrics = Array.isArray(job.lyrics) ? job.lyrics : [];
  const al = alignLyrics(lyrics, json.result);
  const qa = assessQuality(lyrics, al, job.duration);
  const lines = al.lines.filter((x) => x.t != null).map((x) => (x.e != null ? { i: x.i, t: x.t, e: x.e } : { i: x.i, t: x.t }));
  const segs = Array.isArray(json.result.segments) ? json.result.segments : [];
  const meta = {
    matched_lines: al.matchedLines, quality_ok: qa.ok, reasons: qa.reasons, est: qa.est, max_est_run: qa.maxEstRun,
    ai_ms: t2 - t1, words: segs.reduce((n, s) => n + (Array.isArray(s.words) ? s.words.length : 0), 0),
    granularity: al.granularity, vad_filter: false,
  };
  const f = await admin.rpc("lyrics_align_finish", { p_track: job.track_id, p_token: job.token, p_lines: lines, p_meta: meta });
  if (f.error) return reply(502, { code: "DB_ERROR" });   // 解析中のまま → 10分後にデータベースが試行1回として戻す
  return reply(200, { status: (f.data && f.data.status) || "unknown", ratio: qa.ratio, quality_ok: qa.ok, reasons: qa.reasons,
    timing_ms: { audio: t1 - t0, ai: t2 - t1 }, est_neurons: job.est_neurons });
}
