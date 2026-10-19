// C1：機能スイッチ（PWA・退会）の確認。localhost で実際の Service Worker を動かす
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const http = require('http'), fs = require('fs'), path = require('path');
const [PUB, DEV] = process.argv.slice(2);
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? 'PASS' : 'FAIL'}] ${n}${i !== undefined ? '  → ' + JSON.stringify(i) : ''}`); };
let features = null;   // config.js に入れる features（null＝書かない）
const server = http.createServer((req, res) => { const u = new URL(req.url, 'http://x');
  if (u.pathname === '/config.js') { res.writeHead(200, { 'Content-Type': 'text/javascript', 'Cache-Control': 'no-cache' });
    return res.end('window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k"' + (features === null ? '' : ',features:' + features) + '};'); }
  const f = path.join(PUB, u.pathname === '/' ? 'index.html' : u.pathname);
  if (!f.startsWith(PUB) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end(); }
  const t = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.png': 'image/png', '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml' }[path.extname(f)] || 'application/octet-stream';
  res.writeHead(200, { 'Content-Type': t, 'Cache-Control': 'no-cache' }); res.end(fs.readFileSync(f)); });
(async () => {
  await new Promise(r => server.listen(0, r)); const O = `http://localhost:${server.address().port}`;
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const mk = async () => { const c = await b.newContext({ ...dev, serviceWorkers: 'allow' });
    await c.route(/cdnjs|unpkg|jsdelivr/, r => { const u = r.request().url();
      if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
      if (u.includes('supabase')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
      return r.fulfill({ contentType: 'text/javascript', body: '' }); });
    await c.route(/fonts\./, r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
    const p = await c.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message)); return { c, p, errs }; };
  const pwaState = p => p.evaluate(async () => ({ manifest: !!document.querySelector('link[rel=manifest]'), capable: !!document.querySelector('meta[name=apple-mobile-web-app-capable]'),
    reg: !!(await navigator.serviceWorker.getRegistration()), caches: (await caches.keys()).filter(k => k.startsWith('aimuse-')).length }));
  const login = async (p, email) => { await p.locator('nav.nav button', { hasText: 'マイページ' }).click(); await p.waitForTimeout(300);
    await p.fill('#a-email', email); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('text=ログアウト').waitFor(); await p.waitForTimeout(500); };
  const openSettings = async p => { await p.locator('nav.nav button', { hasText: 'マイページ' }).click(); await p.waitForTimeout(300); await p.locator('button', { hasText: '設定（カラーテーマ' }).click(); await p.waitForTimeout(300); };

  // ---- 1. 初期状態（features を書かない＝今の本番の config.js と同じ）：PWA・退会ともオフ
  features = null; let x = await mk();
  await x.p.goto(O + '/'); await x.p.waitForTimeout(1500);
  let s = await pwaState(x.p);
  ok('1 初期状態：PWA はオフ（manifest なし・Service Worker なし）', !s.manifest && !s.capable && !s.reg && s.caches === 0, s);
  await login(x.p, 'hamu@test.jp'); await openSettings(x.p);
  ok('1 初期状態：設定画面に退会の入口が出ない', await x.p.locator('button', { hasText: 'アカウントを削除（退会）' }).count() === 0);
  ok('1 カラーテーマなど、ほかの設定は従来どおり', await x.p.locator('.th-card').count() === 6);
  // 実際の本番用 config.js の初期値も確認
  const real = fs.readFileSync(path.join(PUB, 'config.js'), 'utf8');
  ok('1 本番用 config.js のスイッチは true か false で明記（公開後は pwa・accountDeletion とも true）', /pwa:\s*(true|false)/.test(real) && /accountDeletion:\s*(true|false)/.test(real), (real.match(/(pwa|accountDeletion):\s*\w+/g) || []).join(' '));

  // ---- 2. 退会オフでも、手続き中の方には状況と取り消しを表示（本人が戻せなくなる事故を防ぐ）
  await x.p.evaluate(() => { const d = window.__db, now = Date.now(); d.deletions.push({ user_id: '22222222-2222-4222-8222-222222222222', status: 'pending', requested_at: new Date(now).toISOString(), purge_after: new Date(now + 29 * 86400000).toISOString(), hidden: [] }); sessionStorage.setItem('fakedb2', JSON.stringify(d)); });
  await x.p.reload(); await x.p.waitForTimeout(1300);
  await x.p.locator('nav.nav button', { hasText: 'マイページ' }).click(); await x.p.waitForTimeout(400);
  ok('2 退会オフでも、手続き中の方のマイページには状況と「退会を取り消す」が出る', await x.p.locator('.del-status').count() === 1 && await x.p.locator('button', { hasText: '退会を取り消す' }).count() === 1);
  await x.p.locator('button', { hasText: '退会を取り消す' }).click(); await x.p.waitForTimeout(700);
  ok('2 退会オフでも取り消しはできる', await x.p.locator('.del-status').count() === 0);
  ok('エラーなし（初期状態）', x.errs.length === 0, x.errs); await x.c.close();

  // ---- 3. 検証者用の入口（#account-delete-test）：その端末だけ入口を表示（申請できるかはサーバーが判定）
  x = await mk(); await x.p.goto(O + '/#account-delete-test'); await x.p.waitForTimeout(1300);
  ok('3 検証者用のURLで開くと、URLの末尾（#…）はすぐ消える', !(await x.p.evaluate(() => location.hash)));
  await login(x.p, 'hamu@test.jp'); await openSettings(x.p);
  ok('3 検証者用のURLで開いた端末では、退会の入口が出る', await x.p.locator('button', { hasText: 'アカウントを削除（退会）' }).count() === 1);
  await x.p.evaluate(() => { window.__deleteMode = 'off'; });
  await x.p.locator('button', { hasText: 'アカウントを削除（退会）' }).click(); await x.p.waitForTimeout(300);
  await x.p.locator('button[role=checkbox]').click(); await x.p.fill('#del-pw', 'password'); await x.p.locator('button', { hasText: '退会を申請する' }).click(); await x.p.waitForTimeout(700);
  const msg = await x.p.locator('[role=alert]').innerText().catch(() => '');
  ok('3 入口が見えても、サーバーが受け付けなければ申請されない（「準備中」と表示）', /準備中/.test(msg) && await x.p.locator('.del-status').count() === 0 && await x.p.evaluate(() => window.__db.deletions.length === 0), msg);
  await x.c.close();
  x = await mk(); await x.p.goto(O + '/'); await x.p.waitForTimeout(1200); await login(x.p, 'hamu@test.jp'); await openSettings(x.p);
  ok('3 ほかの端末（通常のURL）では出ない', await x.p.locator('button', { hasText: 'アカウントを削除（退会）' }).count() === 0); await x.c.close();

  // ---- 4. 書き間違い・文字列の "true" などはオフ扱い
  features = '{pwa:"true",accountDeletion:1}'; x = await mk(); await x.p.goto(O + '/'); await x.p.waitForTimeout(1500);
  s = await pwaState(x.p); await login(x.p, 'hamu@test.jp'); await openSettings(x.p);
  ok('4 true 以外の値（"true"・1 など）はオフ扱い', !s.manifest && !s.reg && await x.p.locator('button', { hasText: 'アカウントを削除（退会）' }).count() === 0, s); await x.c.close();

  // ---- 5. 退会オン
  features = '{accountDeletion:true}'; x = await mk(); await x.p.goto(O + '/'); await x.p.waitForTimeout(1200); await login(x.p, 'hamu@test.jp'); await openSettings(x.p);
  ok('5 退会オン：入口が出る（PWA はオフのまま＝個別に切り替わる）', await x.p.locator('button', { hasText: 'アカウントを削除（退会）' }).count() === 1 && !(await pwaState(x.p)).reg); await x.c.close();

  // ---- 6. PWA オン → オフ（オフにすると、登録済みの Service Worker と保存を消す）
  features = '{pwa:true}'; x = await mk(); await x.p.goto(O + '/'); await x.p.evaluate(() => navigator.serviceWorker.ready); await x.p.reload(); await x.p.waitForTimeout(1200);
  s = await pwaState(x.p);
  ok('6 PWA オン：manifest と Service Worker が有効（退会はオフのまま）', s.manifest && s.capable && s.reg && s.caches === 1, s);
  await x.p.evaluate(() => localStorage.setItem('aimuse.theme.guest', JSON.stringify({ v: 1, preset: 'ocean', accent: '#5ab8ff', bg: '#06101e', button: '#2f74ff' })));
  features = '{pwa:false}'; await x.p.reload(); await x.p.waitForTimeout(1500); await x.p.reload(); await x.p.waitForTimeout(1200);
  s = await pwaState(x.p);
  ok('6 PWA をオフに戻すと、端末の Service Worker と保存が消える（テーマは残る）', !s.manifest && !s.reg && s.caches === 0 && await x.p.evaluate(() => !!localStorage.getItem('aimuse.theme.guest')), s);
  ok('6 オフに戻した後もアプリは通常どおり表示', await x.p.locator('nav.nav').count() === 1 && x.errs.length === 0, x.errs); await x.c.close();

  const f = R.filter(r => !r[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  await b.close(); server.close();
})();
