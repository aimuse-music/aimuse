// 宣伝用の短縮リンク：/go/<code>
// クリックを1件記録してから AIMUSE へ移動します。
// 記録するのは「どのリンクが・いつ」だけ（IPアドレス・端末情報・Cookieは保存しません）。
import { cfg, rpc, isBot, seenRecently, dedupeCookie } from "../../lib/shared.js";

function page(msg, status) {
  const html = `<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>AIMUSE</title></head><body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#0b0912;color:#f2eefb;font-family:system-ui,sans-serif;text-align:center;padding:24px"><p>${msg}</p></body></html>`;
  return new Response(html, { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

function redirect(url, cookie) {
  const headers = { location: url, "cache-control": "no-store", "referrer-policy": "no-referrer-when-downgrade", "x-robots-tag": "noindex" };
  if (cookie) headers["set-cookie"] = cookie;
  return new Response(null, { status: 302, headers });
}

async function handle(context, record) {
  const { params, env, request } = context;
  const code = String(params.code || "");
  const c = cfg(env);
  if (!/^[A-Za-z0-9]{6,12}$/.test(code)) {
    return c.aimuseUrl ? redirect(c.aimuseUrl) : page("リンクが正しくありません。", 404);
  }
  // ロボット・SNSのプレビュー取得・30分以内の同じ端末からの再クリックは数えない
  const shouldRecord = record && !isBot(request) && !seenRecently(request, "bg");
  let r;
  try {
    r = await rpc(env, "boost_resolve_link", { p_code: code, p_record: shouldRecord });
  } catch (e) {
    r = { ok: false };
  }
  if (r.ok && typeof r.body === "string" && r.body.startsWith("https://")) return redirect(r.body, shouldRecord ? dedupeCookie("bg", `/go/${code}`) : null);
  if (r.ok) return c.aimuseUrl ? redirect(c.aimuseUrl) : page("このリンクは見つかりませんでした。", 404);
  // 計測サーバーに繋がらない場合も、利用者は AIMUSE へ移動させる（クリックは記録されない）
  return c.aimuseUrl ? redirect(c.aimuseUrl) : page("一時的に表示できません。時間をおいてお試しください。", 503);
}

export const onRequestGet = (context) => handle(context, true);
export const onRequestHead = (context) => handle(context, false);
