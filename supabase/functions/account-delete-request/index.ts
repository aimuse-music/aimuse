// AIMUSE Edge Function「account-delete-request」：パスワードで本人確認してから退会を申請します。
// ・アプリ（ブラウザ）から、ログイン中の会員のログイン情報（JWT）つきで呼び出します（supabase.functions.invoke）
// ・「Verify JWT（JWT の確認）」はオフにして公開します（新しい形式のキーでは使えないため）。
//   代わりにこの関数の中で、ログイン情報を Supabase の認証サーバーに確認し、さらにパスワードを照合します。
//   公開用キーだけを持つ呼び出しでは、何も実行しません。
// ・キーは Supabase が自動で設定する環境変数から読みます（新しい形式：SUPABASE_SECRET_KEYS / SUPABASE_PUBLISHABLE_KEYS、
//   旧形式：SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY）。管理用の秘密キーは利用者に返しません
// ・この関数の設定（Secrets）
//     AIMUSE_ALLOWED_ORIGINS …… 呼び出しを許可するサイト（カンマ区切り。未設定なら https://aimusemusic.com）
//     AIMUSE_DELETE_MODE ………… off（初期値・誰も申請できない）/ testers / all
//     AIMUSE_DELETE_TESTERS …… testers のときに申請を許可する会員ID（カンマ区切り）
import { handleDeletionRequest, corsHeaders } from "./request.js";
import { resolveKeys, adminClient, passwordVerifier } from "./supa.js";

const env = (k: string) => Deno.env.get(k) ?? null;
const ALLOWED = (env("AIMUSE_ALLOWED_ORIGINS") ?? "https://aimusemusic.com").split(",").map((s) => s.trim()).filter(Boolean);

Deno.serve(async (req: Request) => {
  const cors = corsHeaders(req.headers.get("origin"), ALLOWED);
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: cors });

  const keys = resolveKeys(env);
  if (!keys.url || !keys.secret || !keys.publishable) return Response.json({ code: "NOT_CONFIGURED" }, { status: 503, headers: cors });

  const admin = adminClient(keys);
  const verifyPassword = passwordVerifier(keys);
  const userJwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  // 公開用キー（sb_publishable_…）や旧 anon キーそのものはログイン情報ではないので受け付けない
  const looksLikeUserJwt = userJwt.split(".").length === 3 && userJwt !== keys.publishable;
  let password = "";
  try { password = (await req.json())?.password ?? ""; } catch (_) { /* 空のまま */ }

  try {
    const r = await handleDeletionRequest({
      admin, verifyPassword, userJwt: looksLikeUserJwt ? userJwt : "", password,
      mode: env("AIMUSE_DELETE_MODE") ?? "off", testers: env("AIMUSE_DELETE_TESTERS") ?? "",
    });
    return Response.json(r.body, { status: r.status, headers: cors });
  } catch (e) {
    console.error("account-delete-request", e instanceof Error ? e.message : "error");
    return Response.json({ code: "SERVER_ERROR", message: "申請できませんでした。時間をおいてお試しください" }, { status: 500, headers: cors });
  }
});
