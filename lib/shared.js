// サーバー処理（Cloudflare Pages Functions）の共通部品
// ここに書くのは「ブラウザに公開されても問題ない値」だけです。
// 秘密の値（APIキーなど）は Cloudflare の環境変数・バインディングに保存し、コードには書きません。

// AIMUSE と同じ Supabase プロジェクト（公開用キー。データはRLSで保護）
export const PUBLIC_DEFAULTS = {
  SUPABASE_URL: "https://tqtrvjmjfthlrwwligmu.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_p1C-sr805QLLx4LARKcFcw_NFzm3r1H",
  // AIMUSE の公開URL（public/config.js の aimuseUrl と同じ値にする）
  AIMUSE_URL: "",
};

export function cfg(env) {
  return {
    supabaseUrl: (env && env.SUPABASE_URL) || PUBLIC_DEFAULTS.SUPABASE_URL,
    anonKey: (env && env.SUPABASE_ANON_KEY) || PUBLIC_DEFAULTS.SUPABASE_ANON_KEY,
    aimuseUrl: (env && env.AIMUSE_URL) || PUBLIC_DEFAULTS.AIMUSE_URL,
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
