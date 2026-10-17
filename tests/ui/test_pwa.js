// Stage 6: PWA（ホーム画面に追加・オフライン・更新・ノッチ）— 実際の Service Worker を localhost で動かして確認
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const http = require('http'), fs = require('fs'), path = require('path');
const [PUB, DEV, OUT] = process.argv.slice(2);
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? 'PASS' : 'FAIL'}] ${n}${i !== undefined ? '  → ' + JSON.stringify(i) : ''}`); };
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json' };
let bump = null, down = false;
const CUR = fs.readFileSync(path.join(PUB, 'sw.js'), 'utf8').match(/const VERSION = "([^"]+)"/)[1], NEXT = CUR + '-next';   // down: サーバーに届かない状態（通信切れ）を再現   // 新しい版の公開を再現（BUILD / VERSION を書き換えて配信）
const served = [];
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x'); served.push(u.pathname);
  if (down) return req.socket.destroy();
  if (u.pathname === '/config.js') { res.writeHead(200, { 'Content-Type': 'text/javascript', 'Cache-Control': 'no-cache' }); return res.end('window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k",features:{pwa:true}};'); }
  let f = path.join(PUB, u.pathname === '/' ? 'index.html' : u.pathname);
  if (!f.startsWith(PUB) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end('not found'); }
  let body = fs.readFileSync(f);
  if (bump && (f.endsWith('index.html') || f.endsWith('sw.js'))) body = Buffer.from(body.toString().split(CUR).join(bump));
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream', 'Cache-Control': 'no-cache' }); res.end(body);
});
const pngSize = b => [b.readUInt32BE(16), b.readUInt32BE(20)];
(async () => {
  await new Promise(r => server.listen(0, r)); const ORIGIN = `http://localhost:${server.address().port}`;
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const ctx = await b.newContext({ ...dev, serviceWorkers: 'allow' });
  const cdnRoutes = async (c) => { await c.route(/unpkg|jsdelivr|cdnjs|esm\.sh/, r => { const u = r.request().url();
    if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
    if (u.includes('supabase')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
    return r.fulfill({ contentType: 'text/javascript', body: '' }); });
    await c.route(/fonts\.(googleapis|gstatic)\.com/, r => r.fulfill({ status: 200, contentType: 'text/css', body: '' })); };
  await ctx.route(/unpkg|jsdelivr|cdnjs|esm\.sh/, r => { const u = r.request().url();
    if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
    if (u.includes('supabase')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
    return r.fulfill({ contentType: 'text/javascript', body: '' }); });
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  const w = ms => p.waitForTimeout(ms || 500), nav = l => p.locator('nav.nav button', { hasText: l }).click();
  const toast = async () => (await p.locator('.toast').innerText().catch(() => '')).trim();

  // ---- 1. ホーム画面に追加するための設定
  await p.goto(ORIGIN + '/'); await w(1500);
  const head = await p.evaluate(() => ({
    manifest: !!document.head.querySelector('link[rel=manifest]'), apple: document.head.querySelector('link[rel=apple-touch-icon]')?.getAttribute('href'),
    capable: document.head.querySelector('meta[name=apple-mobile-web-app-capable]')?.content, title: document.head.querySelector('meta[name=apple-mobile-web-app-title]')?.content,
    status: document.head.querySelector('meta[name=apple-mobile-web-app-status-bar-style]')?.content, viewport: document.querySelector('meta[name=viewport]')?.content,
    themeMetas: document.querySelectorAll('meta[name=theme-color]').length }));
  ok('1 head にアプリ情報（manifest）・iPhone用アイコン・ホーム画面用の設定', head.manifest && head.apple === '/icons/apple-touch-icon.png' && head.capable === 'yes' && head.title === 'AIMUSE' && head.status === 'black-translucent' && /viewport-fit=cover/.test(head.viewport) && head.themeMetas === 1, head);
  const man = JSON.parse(fs.readFileSync(path.join(PUB, 'manifest.webmanifest'), 'utf8'));
  ok('1 アプリ名 AIMUSE・単独画面で起動・起動時はホーム', man.name === 'AIMUSE' && man.short_name === 'AIMUSE' && man.display === 'standalone' && man.start_url.startsWith('/') && man.scope === '/' && man.background_color === '#0b0912', { name: man.name, start: man.start_url });
  const icons = man.icons.map(i => { const buf = fs.readFileSync(path.join(PUB, i.src)); return { src: i.src, ok: `${pngSize(buf).join('x')}` === i.sizes, purpose: i.purpose }; });
  ok('1 アイコン：192・512・マスク用512（実際の画像サイズと一致）', icons.length === 3 && icons.every(i => i.ok) && icons.some(i => i.purpose === 'maskable'), icons);
  const apple = pngSize(fs.readFileSync(path.join(PUB, 'icons/apple-touch-icon.png')));
  ok('1 iPhone用アイコン 180×180・透明部分なし', apple.join('x') === '180x180' && fs.readFileSync(path.join(PUB, 'icons/apple-touch-icon.png'))[25] === 2, apple);
  const cdp = await ctx.newCDPSession(p);
  {   // インストール判定は通常の（シークレットでない）ブラウザで行う
    const dir = fs.mkdtempSync('/tmp/claude-0/h/pwprof-');
    const pc = await chromium.launchPersistentContext(dir, { executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', ...dev });
    await cdnRoutes(pc);
    const pp = pc.pages()[0] || await pc.newPage(); await pp.goto(ORIGIN + '/'); await pp.waitForTimeout(1500);
    await Promise.race([pp.evaluate(() => navigator.serviceWorker.ready), pp.waitForTimeout(8000)]);
    const c2 = await pc.newCDPSession(pp);
    const inst = await c2.send('Page.getInstallabilityErrors').catch(e => ({ err: e.message }));
    ok('1 Chrome（Android）がインストール可能と判定（エラーなし）', inst.installabilityErrors && inst.installabilityErrors.length === 0, inst);
    await pc.close();
  }
  const am = await cdp.send('Page.getAppManifest').catch(e => ({ errors: [e.message] }));
  ok('1 manifest の読み込みエラーなし', am.errors && am.errors.length === 0, am.errors);

  { const sv = fs.readFileSync(path.join(PUB, 'sw.js'), 'utf8').match(/const VERSION = "([^"]+)"/)[1], bv = fs.readFileSync(path.join(PUB, 'index.html'), 'utf8').match(/const BUILD = "([^"]+)"/)[1];
    ok('2 Service Worker の版と画面の版（BUILD）が一致', sv === bv, { sv, bv }); }
  // ---- 2. Service Worker：保存するもの・しないもの
  await p.evaluate(() => navigator.serviceWorker.ready); await p.reload(); await w(1500);
  const sw = await p.evaluate(async () => ({ controlled: !!navigator.serviceWorker.controller, keys: await caches.keys() }));
  ok('2 Service Worker が有効（再読み込み後に画面を管理）', sw.controlled && sw.keys.length === 1 && sw.keys[0] === 'aimuse-shell-' + CUR, sw);
  await p.locator('.row', { hasText: 'おぼろ月' }).first().click(); await w(800);
  await nav('マイページ'); await w(300); await p.fill('#a-email', 'hamu@test.jp'); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('text=ログアウト').waitFor(); await w(600);
  const cached = await p.evaluate(async () => { const out = []; for (const k of await caches.keys()) { const c = await caches.open(k); for (const r of await c.keys()) out.push(new URL(r.url).pathname); } return out.sort(); });
  ok('2 保存されているのは案内ページ・アイコン・manifest だけ（画面・設定・音源・会員情報なし）',
     cached.every(x => x === '/offline.html' || x === '/manifest.webmanifest' || x.startsWith('/icons/')) && !cached.some(x => /index|config|audio|mp3|supabase|auth/.test(x)), cached);

  // ---- 3. ログイン状態・テーマの維持（再読み込み・画面の復元）
  await nav('マイページ'); await w(300); await p.locator('button', { hasText: '設定（カラーテーマ' }).click(); await w(300);
  await p.locator('.th-card', { hasText: 'ローズ' }).click(); await p.locator('button', { hasText: '保存する' }).click(); await w(500);
  await p.reload(); await w(1500);
  const st3 = await p.evaluate(() => ({ bg: getComputedStyle(document.documentElement).getPropertyValue('--bg').trim(), meta: document.querySelector('meta[name=theme-color]').content }));
  await nav('マイページ'); await w(400);
  ok('3 再読み込みしてもログイン状態とテーマ（ローズ）を維持、ステータスバーの色もテーマに合わせる', await p.locator('text=ログアウト').count() === 1 && st3.bg === '#0f090d' && st3.meta === '#0f090d', st3);
  await p.locator('button', { hasText: 'ログアウト' }).click(); await w(800);
  const ls = await p.evaluate(() => Object.keys(localStorage));
  ok('3 ログアウトでログイン情報が端末から消える（テーマ以外の個人情報を残さない）', !ls.includes('fake-session') && !ls.includes('aimuse.theme.last'), ls);

  // ---- 4. 再生中の画面切り替え・アプリの切り替え
  await nav('ホーム'); await w(300); await p.locator('.row', { hasText: 'おぼろ月' }).first().click(); await w(700);
  const a1 = await p.evaluate(() => document.querySelector('audio')?.dataset.tid);
  for (const l of ['検索', 'マイページ', '投稿', 'ホーム']) { await nav(l); await w(250); }
  await p.evaluate(() => { const set = v => { Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => v }); document.dispatchEvent(new Event('visibilitychange')); };
    set('hidden'); set('visible'); window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true })); });
  await w(700);
  const a2 = await p.evaluate(() => ({ tid: document.querySelector('audio')?.dataset.tid, audios: document.querySelectorAll('audio').length }));
  ok('4 再生中に画面を切り替え・アプリを切り替えて戻っても、同じ曲のまま（プレーヤーは1つ）', a1 && a2.tid === a1 && a2.audios === 1 && await p.locator('[class*=mini]').count() > 0, { a1, a2 });
  await p.locator('[class*=mini]').first().click(); await w(500);
  ok('4 プレーヤー画面も開ける', await p.locator('.player').count() === 1);
  await p.locator('.player button[aria-label="閉じる"]').click(); await w(300);

  // ---- 5. オフライン
  await ctx.setOffline(true); await w(300);
  const bar = await p.locator('.offline-bar').innerText().catch(() => '');
  ok('5 使用中に通信が切れたら、画面上部にオフラインの案内', /オフラインです/.test(bar), bar);
  await p.screenshot({ path: `${OUT}/${DEV}-p1-offline-bar.png` });
  down = true; await p.reload().catch(() => {}); await w(1000);
  const off = await p.locator('h1').innerText().catch(() => '');
  ok('5 オフラインで開くと、専用の案内ページ（エラー画面にならない）', /インターネットに接続されていません/.test(off), off);
  await p.screenshot({ path: `${OUT}/${DEV}-p2-offline-page.png` });
  ok('5 案内ページも横にはみ出さない', await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  down = false; await ctx.setOffline(false); await w(2500);
  ok('5 つながると自動で AIMUSE に戻る', await p.locator('nav.nav').count() === 1 && await p.locator('.offline-bar').count() === 0);

  // ---- 6. 新しい版の公開 → 更新
  const before = await p.evaluate(async () => (await caches.keys()));
  bump = NEXT;
  await p.evaluate(async () => { const r = await navigator.serviceWorker.getRegistration(); await r.update(); });
  await w(2500);
  const after = await p.evaluate(async () => (await caches.keys()));
  ok('6 新しい版の Service Worker に入れ替わり、古い保存は削除', before[0] === 'aimuse-shell-' + CUR && after.length === 1 && after[0] === 'aimuse-shell-' + NEXT, { before, after });
  await p.evaluate(() => { Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' }); document.dispatchEvent(new Event('visibilitychange')); });
  await w(2500);
  const build = await p.evaluate(() => document.documentElement.outerHTML.match(/const BUILD = "([^"]+)"/)[1]);
  ok('6 アプリに戻ったとき、再生中でなければ新しい版の画面に自動で切り替わる', build === NEXT, build);

  // ---- 7. ノッチ・ホームインジケーター（端末の安全領域を再現）
  const inset = await cdp.send('Emulation.setSafeAreaInsetsOverride', { insets: { top: 47, bottom: 34, left: 0, right: 0 } }).then(() => true).catch(e => e.message);
  if (inset === true) {
    await p.reload(); await w(1500);
    await p.evaluate(() => window.scrollTo(0, 600)); await w(300);
    const geo = await p.evaluate(() => {
      const top = document.querySelector('.top'), nav = document.querySelector('nav.nav'), sh = getComputedStyle(document.body, '::before');
      return { headerTop: Math.round(top.getBoundingClientRect().top), shield: sh.height, navPad: getComputedStyle(nav).paddingBottom, navBottom: Math.round(nav.getBoundingClientRect().bottom), vh: innerHeight };
    });
    ok('7 ノッチ：スクロールしても見出しが時計・ノッチの下にあり、上部は背景色で覆われる', geo.headerTop >= 47 && geo.shield === '47px', geo);
    ok('7 ホームインジケーター：下のメニューに 34px の余白', geo.navPad === '34px' && geo.navBottom === geo.vh, geo);
    await p.screenshot({ path: `${OUT}/${DEV}-p3-safe-area.png` });
    await p.locator('.row').first().click(); await w(500); await p.locator('[class*=mini]').first().click(); await w(500);
    const pl = await p.evaluate(() => { const s = getComputedStyle(document.querySelector('.player')); return { top: s.paddingTop, bottom: s.paddingBottom }; });
    ok('7 プレーヤー画面も上下の安全領域を避ける', parseInt(pl.top) >= 47 && parseInt(pl.bottom) >= 34, pl);
    await p.screenshot({ path: `${OUT}/${DEV}-p4-player-safe.png` });
    await p.locator('.player button[aria-label="閉じる"]').click(); await w(300);
  } else ok('7 安全領域の再現（この Chromium では不可）', false, inset);
  for (const l of ['ホーム', '検索', '投稿', 'マイページ']) { await nav(l); await w(300); if (!(await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth))) ok('7 横スクロールなし：' + l, false); }
  ok('7 すべての画面で横スクロールなし（安全領域あり）', true);

  ok('エラーなし', errs.length === 0, errs);
  const f = R.filter(r => !r[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  await b.close(); server.close();
})();
