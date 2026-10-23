// AIMUSE Edge Function「lyrics-align-probe」の処理本体（歌詞の自動同期の精度を確かめるための、検証専用の機能）
// ・指定した1曲の音源と歌詞を Cloudflare Workers AI（Whisper）で解析し、各行の歌い出しの時刻の推定を「返すだけ」
//   データベースには何も書き込みません（歌詞・同期の時刻・楽曲は変わりません）
// ・呼び出せるのは次のどちらかだけ
//     ① データベースの金庫（Vault）の合言葉を持つ呼び出し（SQL から。合言葉は誰にも表示されない）
//     ② 管理者のログイン情報（JWT）
// ・Cloudflare の API トークンは、この関数の設定（Secrets）にだけ置き、返す内容・記録には一切含めない
// ・Cloudflare の無料枠を超えたときは、Cloudflare 側で失敗する（無料プランは課金されない）。その場合は FREE_LIMIT を返す
import { alignLyrics, lyricKind } from "./align.js";
import { keyHeaders } from "./supa.js";

export const MODEL = "@cf/openai/whisper-large-v3-turbo";
export const NEURONS_PER_MIN = 46.63;      // Cloudflare の料金表（音声1分あたり）
const MAX_BYTES = 20 * 1024 * 1024;        // 音源の上限（AIMUSE の投稿は 50MB まで。検証は 20MB までの曲だけ）
const MAX_SECONDS = 600;                   // 10分を超える曲は解析しない（無料枠を守る）
const AI_TIMEOUT_MS = 120_000;             // Supabase の待ち時間の上限（150秒）より短く
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function toBase64(bytes) {
  let s = ""; const CH = 0x8000;
  for (let i = 0; i < bytes.length; i += CH) s += String.fromCharCode.apply(null, bytes.subarray(i, i + CH));
  return btoa(s);
}

// 歌詞を Whisper への手がかり（initial_prompt）にする：見出し・空行を除き、先頭から 120 文字まで
export function promptFrom(lyrics) {
  return (lyrics || []).filter((l) => lyricKind(l) === "text").join(" ").slice(0, 120);
}

// 確認用の代表的な行：最初の行・最初のサビ・中盤・最後のサビ・最後の行
export function checkpoints(lyrics, lines) {
  const at = (i) => lines.find((x) => x.i === i);
  const texts = lines.map((x) => x.i);
  if (!texts.length) return [];
  const headAfter = (re, from = 0, last = false) => {
    let found = -1;
    (lyrics || []).forEach((l, i) => { if (i >= from && lyricKind(l) === "head" && re.test(l)) { if (found < 0 || last) found = i; } });
    if (found < 0) return null;
    return texts.find((i) => i > found) ?? null;
  };
  const chorus = /chorus|サビ|hook/i;
  const pick = [
    ["歌い出し（最初の行）", texts[0]],
    ["最初のサビ", headAfter(chorus)],
    ["中盤", texts[Math.floor(texts.length / 2)]],
    ["最後のサビ", headAfter(chorus, 0, true)],
    ["最後の行", texts[texts.length - 1]],
  ];
  const seen = new Set(); const out = [];
  for (const [label, i] of pick) { if (i == null || seen.has(i)) continue; seen.add(i); const x = at(i); out.push({ label, i, line: i + 1, text: lyrics[i], t: x ? x.t : null, est: x ? x.est : true }); }
  return out;
}

const reply = (status, body) => ({ status, body });

export async function handleProbe({ admin, keys, userJwt, callerSecret, body, env, fetchImpl = fetch, now = () => Date.now() }) {
  // 1. 呼び出し元の確認
  let who = null;
  if (callerSecret && String(callerSecret).length >= 32) {
    const { data, error } = await admin.rpc("align_probe_secret_matches", { p_secret: String(callerSecret) });
    if (error) return reply(503, { code: "NOT_CONFIGURED" });
    if (data !== true) return reply(403, { code: "FORBIDDEN" });
    who = "server";
  } else if (userJwt) {
    const { data: got, error } = await admin.auth.getUser(userJwt);
    const user = got && got.user;
    if (error || !user || !user.id) return reply(401, { code: "LOGIN_REQUIRED" });
    const p = await restGet(fetchImpl, keys, `profiles?id=eq.${encodeURIComponent(user.id)}&select=is_admin,is_banned`);
    if (!p.ok || !p.rows[0] || p.rows[0].is_admin !== true || p.rows[0].is_banned) return reply(403, { code: "ADMIN_ONLY" });
    who = "admin";
  } else {
    return reply(401, { code: "LOGIN_REQUIRED" });
  }
  // 2. 設定（Cloudflare）
  const acct = env("CF_ACCOUNT_ID"), token = env("CF_AI_TOKEN");
  if (!acct || !/^[0-9a-f]{32}$/i.test(acct) || !token) return reply(503, { code: "NOT_CONFIGURED" });
  // 3. 対象の曲
  const trackId = body && body.track_id;
  if (typeof trackId !== "string" || !UUID.test(trackId)) return reply(400, { code: "BAD_REQUEST" });
  const usePrompt = !!(body && body.prompt === true);
  const t = await restGet(fetchImpl, keys, `tracks?id=eq.${trackId}&select=id,title,lyrics,audio_path,duration`);
  if (!t.ok) return reply(502, { code: "DB_ERROR" });
  const track = t.rows[0];
  if (!track) return reply(404, { code: "NOT_FOUND" });
  const lyrics = Array.isArray(track.lyrics) ? track.lyrics : [];
  if (!lyrics.some((l) => lyricKind(l) === "text")) return reply(422, { code: "NO_LYRICS" });
  if (track.duration > MAX_SECONDS) return reply(422, { code: "TOO_LONG" });
  // 4. 音源（非公開の保存場所から、管理用のキーで取り出す）
  const t0 = now();
  const path = String(track.audio_path || "").split("/").map(encodeURIComponent).join("/");
  let bytes;
  try {
    const r = await fetchImpl(`${keys.url}/storage/v1/object/audio/${path}`, { headers: keyHeaders(keys.secret) });
    if (!r.ok) return reply(502, { code: "AUDIO_UNAVAILABLE" });
    bytes = new Uint8Array(await r.arrayBuffer());
  } catch (_) { return reply(502, { code: "AUDIO_UNAVAILABLE" }); }
  if (!bytes.length || bytes.length > MAX_BYTES) return reply(422, { code: "AUDIO_TOO_LARGE" });
  const t1 = now();
  // 5. Workers AI（Whisper）
  const input = { audio: toBase64(bytes), task: "transcribe", language: "ja", vad_filter: true, condition_on_previous_text: false };
  if (usePrompt) input.initial_prompt = promptFrom(lyrics);
  const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), AI_TIMEOUT_MS);
  let res, json;
  try {
    res = await fetchImpl(`https://api.cloudflare.com/client/v4/accounts/${acct}/ai/run/${MODEL}`, {
      method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(input), signal: ctl.signal,
    });
    json = await res.json().catch(() => null);
  } catch (e) {
    return reply(504, { code: (e && e.name === "AbortError") ? "AI_TIMEOUT" : "AI_UNREACHABLE" });
  } finally { clearTimeout(timer); }
  const t2 = now();
  const cfCodes = ((json && json.errors) || []).map((x) => x && x.code).filter((c) => typeof c === "number");
  if (res.status === 429 || cfCodes.includes(4006)) return reply(429, { code: "FREE_LIMIT", cf_codes: cfCodes });
  if (res.status === 401 || res.status === 403) return reply(502, { code: "AI_AUTH", cf_codes: cfCodes });
  if (!res.ok || !json || json.success === false || !json.result) return reply(502, { code: "AI_ERROR", http: res.status, cf_codes: cfCodes });
  // 6. 照合
  const result = json.result;
  const al = alignLyrics(lyrics, result);
  const t3 = now();
  const segs = Array.isArray(result.segments) ? result.segments : [];
  const words = segs.reduce((n, s) => n + (Array.isArray(s.words) ? s.words.length : 0), 0);
  return reply(200, {
    caller: who, model: MODEL, options: { language: "ja", vad_filter: true, prompt: usePrompt },
    track: { title: track.title, duration: track.duration },
    timing_ms: { audio: t1 - t0, ai: t2 - t1, align: t3 - t2 },
    audio_bytes: bytes.length,
    neurons_estimate: Math.round((track.duration || 0) / 60 * NEURONS_PER_MIN),
    granularity: al.granularity, segments: segs.length, words,
    segment_fields: segs[0] ? Object.keys(segs[0]).sort() : [],
    text_lines: al.textLines, matched_lines: al.matchedLines,
    checkpoints: checkpoints(lyrics, al.lines),
    lines: al.lines.map((x) => ({ ...x, line: x.i + 1, text: lyrics[x.i] })),
    transcript_head: String(result.text || "").slice(0, 400),
  });
}

async function restGet(fetchImpl, keys, q) {
  try {
    const r = await fetchImpl(`${keys.url}/rest/v1/${q}`, { headers: { ...keyHeaders(keys.secret), Accept: "application/json" } });
    if (!r.ok) return { ok: false, rows: [] };
    const rows = await r.json();
    return { ok: true, rows: Array.isArray(rows) ? rows : [] };
  } catch (_) { return { ok: false, rows: [] }; }
}
