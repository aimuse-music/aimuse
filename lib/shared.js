// サーバー処理（Cloudflare Pages Functions）の共通部品
// ここに書くのは「ブラウザに公開されても問題ない値」だけです。
// 秘密の値（APIキーなど）は Cloudflare の環境変数・バインディングに保存し、コードには書きません。

// AIMUSE と同じ Supabase プロジェクト（公開用キー。データはRLSで保護）
export const PUBLIC_DEFAULTS = {
  SUPABASE_URL: "https://tqtrvjmjfthlrwwligmu.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_p1C-sr805QLLx4LARKcFcw_NFzm3r1H",
  // AIMUSE の公開URL（public/config.js の aimuseUrl と同じ値にする）
  AIMUSE_URL: "https://aimusemusic.com",
  // 将来 AIMUSE に曲ごとのページができたら、その形を設定します（{id} が楽曲IDに置き換わる）
  // 例："https://aimusemusic.com/#track={id}"。空欄のあいだは AIMUSE のトップへ移動します
  AIMUSE_TRACK_URL: "",
};

export function cfg(env) {
  return {
    supabaseUrl: (env && env.SUPABASE_URL) || PUBLIC_DEFAULTS.SUPABASE_URL,
    anonKey: (env && env.SUPABASE_ANON_KEY) || PUBLIC_DEFAULTS.SUPABASE_ANON_KEY,
    aimuseUrl: (env && env.AIMUSE_URL) || PUBLIC_DEFAULTS.AIMUSE_URL,
    trackUrl: (env && env.AIMUSE_TRACK_URL) || PUBLIC_DEFAULTS.AIMUSE_TRACK_URL,
  };
}

export function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

// Supabase の関数（RPC）を呼ぶ。userJwt を渡すと、その人の権限で実行される
export async function rpc(env, name, args, userJwt) {
  const c = cfg(env);
  const res = await fetch(`${c.supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: c.anonKey,
      authorization: `Bearer ${userJwt || c.anonKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(args || {}),
  });
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }
  return { ok: res.ok, status: res.status, body };
}

// SNSのリンクプレビュー取得や検索ロボットなど、人ではないアクセスを判定
const BOT_RE = /bot|crawler|spider|preview|facebookexternalhit|twitterbot|slackbot|discordbot|linkedinbot|whatsapp|telegrambot|line-poker|embedly|skypeuripreview|headless|curl|wget|python-requests|go-http-client/i;
export function isBot(request) {
  const ua = request.headers.get("user-agent") || "";
  if (!ua) return true;
  if (BOT_RE.test(ua)) return true;
  const purpose = (request.headers.get("sec-purpose") || request.headers.get("purpose") || request.headers.get("x-purpose") || "").toLowerCase();
  return purpose.includes("prefetch") || purpose.includes("preview");
}

// 重複クリック対策：同じ端末からの短時間の連続クリックは1回として数える
// ・クッキーの中身は「1」だけ（個人や端末を識別する値は入れない）
// ・対象のリンク/曲のパスだけに送られ、30分で自動的に消える
export const DEDUPE_SECONDS = 1800;
export function seenRecently(request, name) {
  const c = request.headers.get("cookie") || "";
  return c.split(/;\s*/).some((kv) => kv === `${name}=1`);
}
export function dedupeCookie(name, path) {
  return `${name}=1; Max-Age=${DEDUPE_SECONDS}; Path=${path}; Secure; HttpOnly; SameSite=Lax`;
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const PLATFORM_IDS = ["x", "instagram", "tiktok", "youtube"];

// AIMUSE で公開中の曲を1件取得（公開用キー＝未ログインと同じ権限。公開中の曲しか読めない）
export async function getPublicTrack(env, id) {
  if (!UUID_RE.test(String(id || ""))) return null;
  const c = cfg(env);
  const q = `${c.supabaseUrl}/rest/v1/tracks?id=eq.${id}&status=eq.public&select=id,title,artist,genre,image_path,approved_at,created_at`;
  const res = await fetch(q, { headers: { apikey: c.anonKey, authorization: `Bearer ${c.anonKey}` } });
  if (!res.ok) throw new Error("tracks " + res.status);
  const rows = await res.json();
  return rows && rows[0] ? rows[0] : null;
}

// ジャケット画像の期限付きURL（公開中の曲の画像だけ発行できる）
export async function signCover(env, path, seconds = 3600) {
  if (!path) return null;
  const c = cfg(env);
  const enc = String(path).split("/").map(encodeURIComponent).join("/");
  const res = await fetch(`${c.supabaseUrl}/storage/v1/object/sign/covers/${enc}`, {
    method: "POST",
    headers: { apikey: c.anonKey, authorization: `Bearer ${c.anonKey}`, "content-type": "application/json" },
    body: JSON.stringify({ expiresIn: seconds }),
  });
  if (!res.ok) return null;
  const j = await res.json();
  const u = j && (j.signedURL || j.signedUrl);
  if (!u) return null;
  return u.startsWith("http") ? u : `${c.supabaseUrl}/storage/v1${u.startsWith("/") ? "" : "/"}${u}`;
}

export function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
}

// 曲ページのURL（設定済み・AIMUSEと同じサイト内・楽曲IDが正しい場合だけ）。それ以外は null
export function trackPageUrl(env, trackId) {
  const c = cfg(env);
  if (!c.trackUrl || !UUID_RE.test(String(trackId || ""))) return null;
  let u, base;
  try { u = new URL(c.trackUrl.replace(/\{id\}/g, trackId)); base = new URL(c.aimuseUrl); } catch { return null; }
  if (u.protocol !== "https:" || u.origin !== base.origin) return null;
  return u;
}

export function aimuseListenUrl(env, trackId, src) {
  const c = cfg(env);
  const q = new URLSearchParams({ utm_source: PLATFORM_IDS.includes(src) ? src : "boost", utm_medium: "social", utm_campaign: "aimuse_boost", utm_content: trackId || "" });
  const page = trackPageUrl(env, trackId);
  if (page) {
    // UTMはハッシュ（#）より前に付ける
    q.forEach((v, k) => page.searchParams.set(k, v));
    return page.toString();
  }
  return `${c.aimuseUrl.replace(/\/+$/, "")}/?${q.toString()}`;
}
