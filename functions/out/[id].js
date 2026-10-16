// 宣伝ページの「AIMUSEで聴く」：/out/<楽曲ID>?src=x
// 1件記録してから AIMUSE（UTM付き）へ移動します。個人情報は保存しません。
// ロボットと、30分以内の同じ端末からの再クリックは数えません。
import { cfg, rpc, isBot, UUID_RE, aimuseListenUrl, seenRecently, dedupeCookie } from "../../lib/shared.js";

export const onRequestGet = async ({ params, request, env }) => {
  const id = String(params.id || "");
  const src = new URL(request.url).searchParams.get("src") || "";
  if (!UUID_RE.test(id)) return Response.redirect(cfg(env).aimuseUrl, 302);
  const headers = { location: aimuseListenUrl(env, id, src), "cache-control": "no-store", "x-robots-tag": "noindex" };
  if (!isBot(request) && !seenRecently(request, "bo")) {
    try {
      const r = await rpc(env, "boost_record_listen", { p_track: id, p_platform: src });
      if (r.ok && r.body === true) headers["set-cookie"] = dedupeCookie("bo", `/out/${id}`);
    } catch (e) { /* 記録に失敗しても移動はさせる */ }
  }
  return new Response(null, { status: 302, headers });
};
