// 緊急用：ホーム画面のアプリ（PWA）の Service Worker を止めるための sw.js
// 使い方：GitHub で public/sw.js の中身を、このファイルの中身に置き換えて公開する。
// 利用者が次に AIMUSE を開いた（またはアプリに戻った）ときに、保存した案内ページ・アイコンを消し、Service Worker を解除する。
// 画面（index.html）は保存していないため、利用者の操作は不要。ログイン状態・テーマ（端末の保存領域）には触れない。
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) if (key.startsWith("aimuse-")) await caches.delete(key);
    await self.registration.unregister();
  })());
});
