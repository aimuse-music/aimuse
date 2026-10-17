// AIMUSE Edge Function「account-purge」：退会申請から30日を過ぎたアカウントを完全削除します。
// ・1日1回、Supabase の定期実行（Cron）から呼び出す想定です（手順は README を参照）
// ・「Verify JWT」はオフにして公開し、合言葉（AIMUSE_PURGE_SECRET）で呼び出し元を確認します
// ・停止スイッチ：AIMUSE_PURGE_ENABLED が "true" のときだけ動きます（初期値は停止）。
//   データベース側にも同じスイッチ（account_purge_enabled）があり、両方がオンのときだけ削除します
// ・キーは Supabase が自動で設定する環境変数から読みます（新しい形式・旧形式の両方に対応）
// ・結果として返すのは件数だけです（会員ID・メールアドレス・ファイル名は返しません）
import { runPurge, sameSecret } from "./purge.js";
import { resolveKeys, adminClient } from "./supa.js";

const env = (k: string) => Deno.env.get(k) ?? null;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const secret = env("AIMUSE_PURGE_SECRET") ?? "";
  if (secret.length < 32) return new Response("Not configured", { status: 503 });
  if (!sameSecret(secret, req.headers.get("x-aimuse-purge-secret") ?? "")) return new Response("Forbidden", { status: 403 });
  if (env("AIMUSE_PURGE_ENABLED") !== "true") return Response.json({ disabled: true }, { status: 503 });

  const keys = resolveKeys(env);
  if (!keys.url || !keys.secret || !keys.publishable) return new Response("Not configured", { status: 503 });

  try {
    const result = await runPurge(adminClient(keys), { maxJobs: 3, deadline: Date.now() + 100_000 });
    return Response.json(result);
  } catch (e) {
    console.error("account-purge", e instanceof Error ? e.message.split(":")[0] : "error");
    return Response.json({ error: "purge failed" }, { status: 500 });
  }
});
