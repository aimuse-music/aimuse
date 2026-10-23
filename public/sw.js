// AIMUSE Service Worker（ホーム画面に追加したアプリ用）
// 方針：
//  ・保存するのは「オフライン時の案内ページ」「アイコン」「アプリ情報（manifest）」だけ
//  ・画面（index.html）・接続設定（config.js）は保存しない → 公開した最新版を毎回読み込む
//  ・音源・画像・会員情報など Supabase とのやり取り、外部サイト（フォント等）には一切関わらない（保存もしない）
//  ・版（VERSION）を変えて公開すると、新しい Service Worker に入れ替わり、古い保存は削除される
const VERSION = "2026-10-24.1";            // index.html の BUILD と同じ値にする
const CACHE = "aimuse-shell-" + VERSION;
const PRECACHE = ["/offline.html", "/manifest.webmanifest", "/icons/icon-192.png", "/icons/icon-512.png",
                  "/icons/icon-maskable-512.png", "/icons/apple-touch-icon.png", "/icons/favicon-32.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(PRECACHE.map((u) => new Request(u, { cache: "reload" })))).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) if (key !== CACHE) await caches.delete(key);
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;          // Supabase・音源・フォント等は通常どおり（保存しない）
  if (req.mode === "navigate") {
    // 画面は常にネットから。つながらないときだけ案内ページ
    event.respondWith(fetch(req).catch(async () => (await caches.match("/offline.html")) || new Response("オフラインです", { status: 503, headers: { "Content-Type": "text/plain; charset=utf-8" } })));
    return;
  }
  if (PRECACHE.includes(url.pathname)) {
    event.respondWith(caches.match(url.pathname).then((hit) => hit || fetch(req)));
  }
  // それ以外（config.js など）は何もしない＝通常どおりネットから
});
