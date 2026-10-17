// AIMUSE Edge Function「account-purge」：退会申請から30日を過ぎたアカウントを完全削除します。
// ・1日1回、Supabase の定期実行（Cron）から呼び出す想定です（手順は README を参照）
// ・呼び出しには合言葉（AIMUSE_PURGE_SECRET）が必要です。合言葉はサーバーの設定にだけ保存します
// ・管理用の秘密キー（SUPABASE_SERVICE_ROLE_KEY）は Supabase が自動で設定し、この関数の中だけで使います
// ・結果として返すのは件数だけです（会員ID・メールアドレス・ファイル名は返しません）
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { runPurge, sameSecret } from "./purge.js";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const secret = Deno.env.get("AIMUSE_PURGE_SECRET") ?? "";
  if (secret.length < 32) return new Response("Not configured", { status: 503 });
  if (!sameSecret(secret, req.headers.get("x-aimuse-purge-secret") ?? "")) {
    return new Response("Forbidden", { status: 403 });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return new Response("Not configured", { status: 503 });
  const sb = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

  try {
    const result = await runPurge(sb, { maxJobs: 3, deadline: Date.now() + 100_000 });
    return Response.json(result);
  } catch (e) {
    console.error("account-purge", e);
    return Response.json({ error: "purge failed" }, { status: 500 });
  }
});
