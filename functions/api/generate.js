// AI宣伝文の生成（管理者のみ）
// ・AI は Cloudflare Workers AI（無料枠：1日1万ニューロン。無料プランでは超過しても課金されず、エラーで止まります）
// ・APIキーは不要。Cloudflare の「AI」バインディングを設定したときだけ動きます
// ・1日の利用回数の上限は Supabase の boost_settings（初期30回）で管理します
import { json, rpc } from "../../lib/shared.js";

export const AI_MODEL = "@cf/qwen/qwen3-30b-a3b-fp8";

const TONES = {
  emotional: "感動系（心を揺さぶる、情景が浮かぶ、余韻のある言葉）",
  cool: "かっこいい系（クールで洗練、短く鋭い言葉）",
  love: "恋愛系（切なさや胸の高鳴りを感じる、ロマンチックな言葉）",
  friendly: "親しみやすい系（気軽で温かい、話しかけるような口調）",
  simple: "シンプル系（飾らず要点だけ、落ち着いた口調）",
};
const PLATFORMS = ["x", "instagram", "tiktok", "youtube"];

function clean(s, max) {
  return String(s == null ? "" : s).replace(/[\u0000-\u001f]/g, " ").trim().slice(0, max);
}

function extractJson(text) {
  const t = String(text || "").replace(/<think>[\s\S]*?<\/think>/g, "").trim();
  const start = t.indexOf("{");
  const end = t.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try { return JSON.parse(t.slice(start, end + 1)); } catch { return null; }
}

// 絵文字の候補：絵文字以外（文字・記号・URLなど）は除外して最大10個
const EMOJI_RE = /^(?:\p{Extended_Pictographic}|\p{Regional_Indicator})(?:\p{Emoji_Modifier}|\uFE0F|\u200D(?:\p{Extended_Pictographic})\uFE0F?|\p{Regional_Indicator})*$/u;
export function emojiList(v) {
  const list = Array.isArray(v) ? v : [];
  const seen = new Set();
  return list.map((x) => String(x || "").trim()).filter((x) => x.length <= 16 && EMOJI_RE.test(x) && !seen.has(x) && seen.add(x)).slice(0, 10);
}

function tags(v) {
  const list = Array.isArray(v) ? v : String(v || "").split(/[\s,、]+/);
  return list.map((x) => String(x).trim()).filter(Boolean)
    .map((x) => (x.startsWith("#") ? x : "#" + x)).slice(0, 15).join(" ");
}

export const onRequestPost = async ({ request, env }) => {
  if (!env || !env.AI || typeof env.AI.run !== "function") {
    return json({ error: "ai_not_connected", message: "AIは未接続です（テンプレートで作成できます）" }, 503);
  }
  const auth = request.headers.get("authorization") || "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!jwt) return json({ error: "unauthorized", message: "ログインが必要です" }, 401);

  let input;
  try { input = await request.json(); } catch { return json({ error: "bad_request", message: "入力が正しくありません" }, 400); }
  const title = clean(input && input.title, 60);
  const artist = clean(input && input.artist, 40);
  const genre = clean(input && input.genre, 40);
  const tone = TONES[input && input.tone] ? input.tone : "simple";
  if (!title || !artist) return json({ error: "bad_request", message: "曲名とアーティスト名が必要です" }, 400);

  // 管理者確認＋1日の上限チェック（管理者以外はここで拒否される）
  let q;
  try { q = await rpc(env, "boost_ai_take_quota", {}, jwt); } catch { q = { ok: false, status: 502 }; }
  if (!q.ok) {
    const forbidden = q.status === 400 || q.status === 401 || q.status === 403;
    return json({ error: forbidden ? "forbidden" : "quota_check_failed", message: forbidden ? "管理者のみ利用できます" : "利用回数の確認に失敗しました" }, forbidden ? 403 : 502);
  }
  if (!q.body || !q.body.allowed) {
    return json({ error: "daily_limit", message: `本日のAI生成の上限（${q.body && q.body.limit}回）に達しました。テンプレートは引き続き使えます`, usage: q.body }, 429);
  }

  const system = [
    "あなたは日本の音楽プロモーション担当です。AIで制作された楽曲を配信するサービス「AIMUSE」の楽曲をSNSで紹介する文章を書きます。",
    "事実として与えられていない情報（再生数、受賞歴、ランキング、歌詞の内容、アーティストの経歴）は書かないでください。",
    "誇大表現や「今だけ」「限定」などの煽りは使わないでください。URLは書かないでください（後で自動で付けます）。",
    "出力は次の形のJSONだけにしてください。説明文やコードブロックは不要です。",
    '{"x":{"body":"","hashtags":[]},"instagram":{"body":"","hashtags":[]},"tiktok":{"body":"","hashtags":[]},"youtube":{"title":"","body":"","hashtags":[]},"emojis":[]}',
    "x.body は全角100文字以内で短く印象的に、ハッシュタグは2〜3個。",
    "instagram.body は3〜5行の紹介文、ハッシュタグは8〜12個。",
    "tiktok.body は動画の説明文として1〜2行、ハッシュタグは4〜6個。",
    "youtube.title は全角40文字以内、youtube.body は2〜3行、ハッシュタグは3〜5個。",
    "ハッシュタグには必ず #AIMUSE と #AI音楽 を含めてください。",
    "本文には雰囲気に合う絵文字を自然に1〜3個使ってください（使いすぎない）。",
    "emojis には、この曲の雰囲気に合う絵文字を6〜8個、1個ずつ配列で入れてください（文字は入れない）。",
  ].join("\n");
  const user = `曲名：${title}\nアーティスト：${artist}\nジャンル：${genre || "未設定"}\n文章の雰囲気：${TONES[tone]}\n/no_think`;

  let raw;
  try {
    raw = await env.AI.run(AI_MODEL, {
      messages: [{ role: "system", content: system }, { role: "user", content: user }],
      max_tokens: 1200,
      temperature: 0.8,
    });
  } catch (e) {
    const msg = String((e && e.message) || e);
    const limit = /limit|quota|neuron|429|capacity/i.test(msg);
    return json({ error: limit ? "ai_free_limit" : "ai_failed", message: limit ? "AIの無料枠（本日分）を使い切りました。テンプレートをご利用ください" : "AIの生成に失敗しました", detail: msg.slice(0, 300) }, 502);
  }
  const text = typeof raw === "string" ? raw
    : raw && typeof raw.response === "string" ? raw.response
    : raw && raw.response && typeof raw.response === "object" ? JSON.stringify(raw.response)
    : raw && raw.choices && raw.choices[0] && raw.choices[0].message ? raw.choices[0].message.content
    : "";
  const data = extractJson(text);
  if (!data) return json({ error: "ai_bad_output", message: "AIの出力を読み取れませんでした。もう一度お試しください", detail: String(text).slice(0, 300) }, 502);

  const out = {};
  for (const p of PLATFORMS) {
    const d = data[p] || {};
    out[p] = { title: p === "youtube" ? clean(d.title, 100) : "", body: clean(d.body, 2000).replace(/\\n/g, "\n"), hashtags: tags(d.hashtags) };
    // clean() で改行が消えるため、本文は改行を保ったまま再整形
    if (typeof d.body === "string") out[p].body = d.body.replace(/\r/g, "").replace(/[\u0000-\u0009\u000b-\u001f]/g, " ").trim().slice(0, 2000);
  }
  return json({ ok: true, model: AI_MODEL, tone, usage: q.body, result: out, emojis: emojiList(data.emojis) });
};
