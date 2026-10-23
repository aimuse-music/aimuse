// AIMUSE Edge Function「lyrics-align」：歌詞の自動同期（AI）。定期実行から呼ばれ、1回に1曲だけ解析する
// ・「Verify JWT」はオフにして公開し、関数の中で合言葉（データベースの金庫）を確認します。会員・未ログインは使えません
// ・この関数の設定（Secrets）
//     AIMUSE_ALIGN_DISABLED …… "1" を入れると何もしない（非常用。ふだんの停止・再開は管理画面。データベースの初期状態は停止中）
//     CF_ACCOUNT_ID …… Cloudflare のアカウントID（32文字）
//     CF_AI_TOKEN …… Cloudflare Workers AI 用の API トークン（Workers AI の権限だけ）
// ・ブラウザからは呼びません（CORS を返さない）
import { handleRun } from "./worker.js";
import { resolveKeys, adminClient } from "./supa.js";

const env = (k: string) => Deno.env.get(k) ?? null;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  const keys = resolveKeys(env);
  if (!keys.url || !keys.secret || !keys.publishable) return Response.json({ code: "NOT_CONFIGURED" }, { status: 503 });
  try {
    const r = await handleRun({ admin: adminClient(keys), keys, env, callerSecret: req.headers.get("x-aimuse-align-secret") });
    return Response.json(r.body, { status: r.status });
  } catch (e) {
    console.error("lyrics-align", e instanceof Error ? e.name : "error");
    return Response.json({ code: "SERVER_ERROR" }, { status: 500 });
  }
});
