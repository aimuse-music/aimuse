// 宣伝ページの「AIMUSEで聴く」：/out/<楽曲ID>?src=x
// 1件記録してから AIMUSE（UTM付き）へ移動します。個人情報は保存しません。
import { cfg, rpc, isBot, UUID_RE, aimuseListenUrl } from "../../lib/shared.js";

export const onRequestGet = async ({ params, request, env }) => {
  const id = String(params.id || "");
  const src = new URL(request.url).searchParams.get("src") || "";
  if (!UUID_RE.test(id)) return Response.redirect(cfg(env).aimuseUrl, 302);
  if (!isBot(request)) {
    try { await rpc(env, "boost_record_listen", { p_track: id, p_platform: src }); } catch (e) { /* 記録に失敗しても移動はさせる */ }
  }
  return new Response(null, { status: 302, headers: { location: aimuseListenUrl(env, id, src), "cache-control": "no-store", "x-robots-tag": "noindex" } });
};
