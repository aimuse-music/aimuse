// AIMUSE Edge Function「account-delete-request」：パスワードで本人確認してから退会を申請します。
// ・アプリ（ブラウザ）から、ログイン中の会員のログイン情報つきで呼び出します（supabase.functions.invoke）
// ・管理用の秘密キー（SUPABASE_SERVICE_ROLE_KEY）と公開用キー（SUPABASE_ANON_KEY）は Supabase が自動で設定し、
//   この関数の中だけで使います（ブラウザには渡しません）
// ・呼び出しを許可するサイト：AIMUSE_ALLOWED_ORIGINS（カンマ区切り。未設定なら https://aimusemusic.com）
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { handleDeletionRequest, corsHeaders } from "./request.js";

const ALLOWED = (Deno.env.get("AIMUSE_ALLOWED_ORIGINS") ?? "https://aimusemusic.com")
  .split(",").map((s) => s.trim()).filter(Boolean);

Deno.serve(async (req: Request) => {
  const cors = corsHeaders(req.headers.get("origin"), ALLOWED);
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: cors });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !serviceKey || !anonKey) return Response.json({ code: "NOT_CONFIGURED" }, { status: 503, headers: cors });

  const opts = { auth: { persistSession: false, autoRefreshToken: false } };
  const admin = createClient(url, serviceKey, opts);
  const verifyPassword = async (email: string, password: string) => {
    const pub = createClient(url, anonKey, opts);   // 照合専用（保存しない）
    const { data, error } = await pub.auth.signInWithPassword({ email, password });
    if (error) {
      // 400番台＝パスワード違いなど（失敗として数える） / それ以外＝一時的な障害（数えない）
      const rejected = typeof error.status === "number" && error.status >= 400 && error.status < 500 && error.status !== 429;
      return { ok: false, rejected };
    }
    return { ok: true, userId: data.user?.id, temporaryJwt: data.session?.access_token };
  };

  const userJwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  let password = "";
  try { password = (await req.json())?.password ?? ""; } catch (_) { /* 空のまま */ }

  try {
    const r = await handleDeletionRequest({ admin, verifyPassword, userJwt, password });
    return Response.json(r.body, { status: r.status, headers: cors });
  } catch (e) {
    console.error("account-delete-request", e);
    return Response.json({ code: "SERVER_ERROR", message: "申請できませんでした。時間をおいてお試しください" }, { status: 500, headers: cors });
  }
});
