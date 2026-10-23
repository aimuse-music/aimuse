// AIMUSE Edge Function「lyrics-align-probe」：歌詞の自動同期の精度を確かめる検証専用の機能（データベースには書き込まない）
// ・「Verify JWT」はオフにして公開し、関数の中で呼び出し元を確認します（金庫の合言葉、または管理者のログイン情報）
// ・この関数の設定（Secrets）
//     CF_ACCOUNT_ID …… Cloudflare のアカウントID（32文字）
//     CF_AI_TOKEN …… Cloudflare Workers AI 用の API トークン（Workers AI の読み取り・編集だけの権限）
// ・ブラウザからは呼びません（CORS を返さない）。検証が終わったら関数ごと削除します
import { handleProbe } from "./probe.js";
import { resolveKeys, adminClient } from "./supa.js";

const env = (k: string) => Deno.env.get(k) ?? null;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  const keys = resolveKeys(env);
  if (!keys.url || !keys.secret || !keys.publishable) return Response.json({ code: "NOT_CONFIGURED" }, { status: 503 });
  const userJwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  let body = null;
  try { body = await req.json(); } catch (_) { /* 空のまま */ }
  try {
    const r = await handleProbe({
      admin: adminClient(keys), keys, env, body,
      callerSecret: req.headers.get("x-aimuse-probe-secret"),
      userJwt: userJwt.split(".").length === 3 && userJwt !== keys.publishable ? userJwt : "",
    });
    return Response.json(r.body, { status: r.status });
  } catch (e) {
    console.error("lyrics-align-probe", e instanceof Error ? e.name : "error");
    return Response.json({ code: "SERVER_ERROR" }, { status: 500 });
  }
});
