// 楽曲ごとの宣伝ページ：/s/<楽曲ID>?src=x
// ・誰でも見られる公開ページ（ログイン不要）。AIMUSEで公開中の曲だけ表示する
// ・SNSに貼ったとき、ジャケット画像つきのプレビュー（OGP）が出るようにする
// ・「AIMUSEで聴く」は /out/<楽曲ID> を通して記録してから AIMUSE へ移動する
import { cfg, esc, getPublicTrack, PLATFORM_IDS, trackPageUrl } from "../../lib/shared.js";

const HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "public, max-age=300",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "x-frame-options": "DENY",
  "content-security-policy": "default-src 'none'; img-src 'self' https://*.supabase.co data:; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
};

const CSS = `
:root{color-scheme:dark;--bg:#0b0912;--surface:#15121f;--line:#2c2742;--fg:#f2eefb;--muted:#9d95b8;--faint:#6b6488;--grad:linear-gradient(120deg,#b46bff 0%,#7c5cff 45%,#5a72ff 100%);--glow:rgba(140,100,255,.35)}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--fg);font-family:"Zen Kaku Gothic New","Hiragino Sans","Hiragino Kaku Gothic ProN","Noto Sans JP",system-ui,sans-serif;line-height:1.6}
body{min-height:100vh;display:flex;justify-content:center;padding:max(24px,env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) max(28px,env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left))}
main{width:100%;max-width:440px;display:flex;flex-direction:column;align-items:center;text-align:center}
.brand{font-family:"Unbounded",system-ui,sans-serif;font-weight:700;font-size:15px;letter-spacing:.08em;background:var(--grad);-webkit-background-clip:text;background-clip:text;color:transparent;margin:4px 0 22px;text-decoration:none}
.art{width:min(78vw,320px);aspect-ratio:1;border-radius:22px;object-fit:cover;box-shadow:0 18px 60px var(--glow);background:var(--grad);display:grid;place-items:center;font-family:"Unbounded",sans-serif;font-size:72px;color:#fff}
h1{font-size:24px;line-height:1.3;margin:24px 0 4px;font-weight:900;word-break:break-word}
.artist{color:var(--muted);font-weight:700;margin:0}
.chips{display:flex;gap:8px;justify-content:center;flex-wrap:wrap;margin:14px 0 26px}
.chip{font-size:12px;font-weight:700;padding:3px 11px;border-radius:999px;border:1px solid var(--line);color:var(--muted)}
.cta{display:flex;align-items:center;justify-content:center;gap:8px;width:100%;min-height:54px;border-radius:16px;background:var(--grad);color:#fff;font-weight:900;font-size:17px;text-decoration:none;box-shadow:0 8px 30px var(--glow)}
.cta:active{transform:scale(.98)}
.note{color:var(--faint);font-size:12px;margin-top:14px}
.about{margin-top:34px;padding:16px;border:1px solid var(--line);border-radius:16px;background:var(--surface);font-size:13px;color:var(--muted);text-align:left}
.about b{color:var(--fg)}
`;

function page({ title, desc, ogImage, url, body }) {
  return `<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>${esc(title)}</title><meta name="description" content="${esc(desc)}"><meta name="theme-color" content="#0b0912">
<meta property="og:type" content="music.song"><meta property="og:site_name" content="AIMUSE"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}"><meta property="og:url" content="${esc(url)}">
${ogImage ? `<meta property="og:image" content="${esc(ogImage)}"><meta name="twitter:image" content="${esc(ogImage)}">` : ""}
<meta name="twitter:card" content="${ogImage ? "summary_large_image" : "summary"}"><meta name="twitter:title" content="${esc(title)}"><meta name="twitter:description" content="${esc(desc)}">
<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=Zen+Kaku+Gothic+New:wght@400;700;900&family=Unbounded:wght@700&display=swap" rel="stylesheet">
<style>${CSS}</style></head><body><main>${body}</main></body></html>`;
}

export const onRequestGet = async ({ params, request, env }) => {
  const c = cfg(env);
  const url = new URL(request.url);
  const src = PLATFORM_IDS.includes(url.searchParams.get("src")) ? url.searchParams.get("src") : "";
  let t = null;
  try { t = await getPublicTrack(env, params.id); } catch (e) {
    return new Response(page({ title: "AIMUSE", desc: "AIで制作された楽曲だけを集めた音楽配信サービス", url: url.href,
      body: `<a class="brand" href="${esc(c.aimuseUrl)}">AIMUSE</a><p>一時的に表示できません。時間をおいてお試しください。</p><a class="cta" href="${esc(c.aimuseUrl)}">AIMUSEを開く</a>` }), { status: 503, headers: { ...HEADERS, "cache-control": "no-store" } });
  }
  if (!t) {
    return new Response(page({ title: "AIMUSE", desc: "AIで制作された楽曲だけを集めた音楽配信サービス", url: url.href,
      body: `<a class="brand" href="${esc(c.aimuseUrl)}">AIMUSE</a><p>この曲は現在公開されていません。</p><a class="cta" href="${esc(c.aimuseUrl)}">AIMUSEでほかの曲を聴く</a>` }), { status: 404, headers: HEADERS });
  }
  const title = `${t.title} / ${t.artist} | AIMUSE`;
  const desc = `${t.artist}の「${t.title}」${t.genre ? `（${t.genre}）` : ""}をAIMUSEで配信中。AIで制作された楽曲だけを集めた音楽配信サービス。`;
  const coverPath = t.image_path ? `/cover/${t.id}` : "";
  const ogImage = coverPath ? `${url.origin}${coverPath}` : "";
  const out = `/out/${t.id}${src ? `?src=${src}` : ""}`;
  const body = `<a class="brand" href="${esc(out)}">AIMUSE</a>
${coverPath ? `<img class="art" src="${esc(coverPath)}" alt="${esc(t.title)} のジャケット" width="320" height="320">` : `<div class="art" role="img" aria-label="ジャケット画像なし">${esc(String(t.title).slice(0, 1))}</div>`}
<h1>${esc(t.title)}</h1><p class="artist">${esc(t.artist)}</p>
<div class="chips">${t.genre ? `<span class="chip">${esc(t.genre)}</span>` : ""}<span class="chip">AI音楽</span></div>
<a class="cta" href="${esc(out)}">▶ AIMUSEで聴く</a>
<p class="note">無料・会員登録なしで再生できます。${trackPageUrl(env, t.id) ? "" : "AIMUSEを開いたら、下の「検索」で曲名を入力してください。"}</p>
<div class="about"><b>AIMUSEとは</b><br>AIを使って制作された楽曲だけを集めた音楽配信サービスです。</div>`;
  return new Response(page({ title, desc, ogImage, url: `${url.origin}/s/${t.id}`, body }), { headers: HEADERS });
};
