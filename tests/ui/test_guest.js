// Stage 3: onboarding + guest listening (Chromium, iPhone / Android emulation)
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const [INDEX, DEV, OUT] = process.argv.slice(2);
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? 'PASS' : 'FAIL'}] ${n}${i !== undefined ? '  → ' + JSON.stringify(i) : ''}`); };
const route = r => { const u = r.request().url();
  if (u.startsWith('http://aimuse.test/') && !u.endsWith('.js')) return r.fulfill({ contentType: 'text/html', body: fs.readFileSync(INDEX) });
  if (u.endsWith('/config.js')) return r.fulfill({ contentType: 'text/javascript', body: 'window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k"};' });
  if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
  if (u.includes('react-dom.production') || u.includes('htm.umd')) return r.fulfill({ contentType: 'text/javascript', body: '' });
  if (u.includes('supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
  return r.fulfill({ status: 404, body: '' }); };
const TEXTS = ['AIMUSEへようこそ！', 'AI音楽を、もっと自由に。', '音楽を聴くだけなら会員登録は不要。気になる曲をタップして、すぐに楽しめます。', '楽曲を投稿するには無料会員登録が必要です。'];
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const ctx = await b.newContext({ ...dev }); const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/*', route);
  const w = ms => p.waitForTimeout(ms || 500), nav = l => p.locator('nav.nav button', { hasText: l }).click();
  const toast = async () => (await p.locator('.toast').innerText().catch(() => '')).trim();

  // ---- 1. はじめての訪問（未ログイン）
  await p.goto('http://aimuse.test/'); await w(1200);
  const card = await p.locator('.welcome').innerText().catch(() => '');
  ok('1 ホームに案内が表示され、指定の文言がすべてある', TEXTS.every(t => card.includes(t)), card.slice(0, 60));
  ok('1 案内の下に曲が並び、再生できる状態', await p.locator('.row').count() > 0);
  await p.screenshot({ path: `${OUT}/${DEV}-g1-welcome.png` });
  ok('1 横にはみ出さない', await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

  // ---- 2. ゲストで検索・再生（登録を求められない）
  await nav('検索'); await w(300); await p.fill('#q', 'ああ'); await w(500);
  ok('2 ゲストで検索できる', (await p.locator('.sec .list .row .t').allInnerTexts()).includes('ああ'));
  await p.locator('.sec .list .row', { hasText: 'ああ' }).first().click(); await w(700);
  const t1 = await toast();
  ok('2 ゲストで再生が始まり、ログインを求められない', !/ログイン/.test(t1) && await p.locator('[class*=mini]').count() > 0, t1);
  const plays = await p.evaluate(() => window.__log.filter(l => l.op === 'rpc' && (l.name === 'count_play' || l.name === 'increment_plays')).length);
  ok('2 ゲストの再生も再生数の集計に送られる', plays >= 1, plays);
  await nav('ホーム'); await w(400);
  await p.locator('.row', { hasText: 'おぼろ月' }).first().click(); await w(600);
  await p.locator('[class*=mini]').first().click(); await w(600);
  const before = await p.evaluate(() => document.querySelector('audio')?.dataset.tid);
  await p.locator('button[aria-label*="次"]').first().click().catch(() => {}); await w(600);
  const after = await p.evaluate(() => document.querySelector('audio')?.dataset.tid);
  ok('2 ゲストで次の曲へ進める', before && after && before !== after, { before, after });
  await p.locator('.player button[aria-label="閉じる"]').click(); await w(400);

  // ---- 3. 必要な操作のときだけログインを案内
  await nav('ホーム'); await w(400);
  await p.locator('button[aria-label="お気に入りに追加"]').first().click(); await w(300);
  ok('3 お気に入り→ログインの案内（無料と分かる）', /ログインが必要.*無料/.test(await toast()), await toast());
  await nav('投稿'); await w(400);
  ok('3 投稿→ログイン画面と「会員登録は無料」の説明', (await p.locator('body').innerText()).includes('会員登録は無料') && await p.locator('#a-email').count() === 1);

  // ---- 4. 使い方ページ
  await nav('ホーム'); await w(400); await p.locator('.welcome button', { hasText: '使い方を見る' }).click(); await w(600);
  const g = await p.locator('.screen').innerText();
  ok('4 使い方ページ：聴く・探す・お気に入り・投稿・プロフィール・ホーム画面に追加', ['聴く', '探す', 'お気に入り・フォロー', '投稿する', 'プロフィール', 'ホーム画面に追加'].every(x => g.includes(x)));
  ok('4 「登録不要」「無料会員」の区別が文字で分かる', g.includes('登録不要') && g.includes('無料会員'));
  await p.screenshot({ path: `${OUT}/${DEV}-g2-guide.png`, fullPage: true });
  await p.locator('button[aria-label="戻る"]').click(); await w(500);
  ok('4 戻るでホームに戻る', await p.locator('.welcome').count() === 1);
  await p.locator('.welcome button', { hasText: '無料で会員登録' }).click(); await w(600);
  ok('4 「無料で会員登録」→新規登録の画面が開く', (await p.locator('.seg button.on').innerText()) === '新規登録' && await p.locator('#a-name').count() === 1);
  ok('4 ログイン画面にも「使い方」リンク', await p.locator('.legal-links button', { hasText: '使い方' }).count() === 1);
  await p.goto('http://aimuse.test/#guide'); await p.reload(); await w(1000);
  ok('4 URL #guide で使い方を直接開ける', (await p.locator('.top h1').innerText()) === '使い方');

  // ---- 5. 閉じたら繰り返さない
  await p.goto('http://aimuse.test/'); await w(1000);
  await p.locator('button[aria-label="案内を閉じる"]').click(); await w(300);
  ok('5 ×で案内が消える', await p.locator('.welcome').count() === 0);
  await p.reload(); await w(1000);
  ok('5 再読み込みしても、閉じた案内は出ない', await p.locator('.welcome').count() === 0);

  // ---- 6. ログインしたことのある人には出さない
  const c2 = await b.newContext({ ...dev }); const p2 = await c2.newPage(); await p2.route('**/*', route);
  await p2.goto('http://aimuse.test/'); await p2.waitForTimeout(1000);
  ok('6 新しい端末（未ログイン）では案内が出る', await p2.locator('.welcome').count() === 1);
  await p2.locator('nav.nav button', { hasText: 'マイページ' }).click(); await p2.waitForTimeout(300);
  await p2.fill('#a-email', 'hamu@test.jp'); await p2.fill('#a-pw', 'password'); await p2.locator('.form button.btn.primary').click(); await p2.locator('text=ログアウト').waitFor(); await p2.waitForTimeout(500);
  await p2.locator('nav.nav button', { hasText: 'ホーム' }).click(); await p2.waitForTimeout(500);
  ok('6 ログイン中は案内が出ない', await p2.locator('.welcome').count() === 0);
  await p2.locator('nav.nav button', { hasText: 'マイページ' }).click(); await p2.waitForTimeout(300); await p2.locator('text=ログアウト').click(); await p2.waitForTimeout(600);
  await p2.locator('nav.nav button', { hasText: 'ホーム' }).click(); await p2.waitForTimeout(500);
  ok('6 ログアウト後も、一度ログインした端末では案内を繰り返さない', await p2.locator('.welcome').count() === 0);
  await p2.locator('nav.nav button', { hasText: 'マイページ' }).click(); await p2.waitForTimeout(300);
  await p2.fill('#a-email', 'hamu@test.jp'); await p2.fill('#a-pw', 'password'); await p2.locator('.form button.btn.primary').click(); await p2.locator('text=ログアウト').waitFor(); await p2.waitForTimeout(500);
  const mpLink = p2.locator('.legal-links button', { hasText: '使い方' });
  ok('6 ログイン中のマイページの下に「使い方」リンクがあり、開ける', await mpLink.count() === 1 && (await mpLink.click(), await p2.waitForTimeout(500), (await p2.locator('.top h1').innerText()) === '使い方'));

  // ---- 7. 端末に保存できない環境（プライベートブラウズ等）でも壊れない
  const c3 = await b.newContext({ ...dev }); await c3.addInitScript(() => { Object.defineProperty(window, 'localStorage', { get() { throw new Error('blocked'); } }); });
  const p3 = await c3.newPage(); const e3 = []; p3.on('pageerror', e => e3.push(e.message)); await p3.route('**/*', route);
  await p3.goto('http://aimuse.test/'); await p3.waitForTimeout(1200);
  ok('7 保存できない環境でも案内・曲が表示される', await p3.locator('.welcome').count() === 1 && await p3.locator('.row').count() > 0);
  await p3.locator('button[aria-label="案内を閉じる"]').click(); await p3.waitForTimeout(300);
  ok('7 保存できない環境でも×で閉じられ、エラーにならない', await p3.locator('.welcome').count() === 0 && e3.length === 0, e3);

  ok('エラーなし', errs.length === 0, errs);
  const f = R.filter(r => !r[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  await b.close();
})();
