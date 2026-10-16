// 宣伝ページ・SNSプレビュー用のジャケット画像：/cover/<楽曲ID>
// AIMUSEの画像は非公開保存のため、公開中の曲に限り期限付きURLで取得して返します。
import { getPublicTrack, signCover } from "../../lib/shared.js";

const ALLOWED = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"];

export const onRequestGet = async ({ params, env }) => {
  let t = null;
  try { t = await getPublicTrack(env, params.id); } catch (e) { return new Response("unavailable", { status: 503 }); }
  if (!t || !t.image_path) return new Response("not found", { status: 404, headers: { "cache-control": "public, max-age=300" } });
  const signed = await signCover(env, t.image_path, 600);
  if (!signed) return new Response("not found", { status: 404 });
  const img = await fetch(signed);
  const type = (img.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
  if (!img.ok || !ALLOWED.includes(type)) return new Response("not found", { status: 404 });
  return new Response(img.body, {
    headers: { "content-type": type, "cache-control": "public, max-age=3600", "x-content-type-options": "nosniff" },
  });
};
