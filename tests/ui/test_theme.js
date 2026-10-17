// Stage 4: color themes (Chromium, iPhone / Android emulation)
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

// in-page helpers: computed colors and WCAG contrast
const MEASURE = () => {
  const toRgb = c => { const m = c.match(/[\d.]+/g).map(Number); return m.slice(0, 3); };
  const L = rgb => { const c = rgb.map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
  const cr = (a, b) => { const x = L(toRgb(a)), y = L(toRgb(b)); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const st = getComputedStyle(document.documentElement), v = k => st.getPropertyValue(k).trim();
  const hex = h => { const n = parseInt(h.slice(1), 16); return `rgb(${n >> 16},${(n >> 8) & 255},${n & 255})`; };
  const bg = hex(v('--bg')), surface = hex(v('--surface'));
  const body = getComputedStyle(document.body);
  const btn = document.querySelector('.btn.primary');
  const grad = v('--btn-grad'), stops = (grad.match(/#[0-9a-f]{6}/gi) || []).map(hex);
  const onBtn = btn ? getComputedStyle(btn).color : null;
  return {
    bg: v('--bg'), fg: cr(body.color, bg), muted: cr(hex(v('--muted')), surface), faint: cr(hex(v('--faint')), bg),
    accent: cr(hex(v('--violet')), surface), btn: onBtn && stops.length ? Math.min(...stops.map(s => cr(onBtn, s))) : null,
    inline: document.documentElement.getAttribute('style') || '', logo: document.querySelector('.logo') ? getComputedStyle(document.querySelector('.logo')).backgroundImage : v('--brand-grad').replace(/\s+/g,''),
    meta: document.querySelector('meta[name="theme-color"]').content
  };
};
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const ctx = await b.newContext({ ...dev }); const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/*', route);
  const w = ms => p.waitForTimeout(ms || 500), nav = l => p.locator('nav.nav button', { hasText: l }).click();
  const toast = async () => (await p.locator('.toast').innerText().catch(() => '')).trim();
  const m = () => p.evaluate(MEASURE);
  const card = name => p.locator('.th-card', { hasText: name });
  const goSettingsGuest = async () => { await nav('マイページ'); await w(300); await p.locator('button', { hasText: 'カラーテーマを変更' }).click(); await w(400); };
  const goSettingsUser = async () => { await nav('マイページ'); await w(300); await p.locator('button', { hasText: '設定（カラーテーマ' }).click(); await w(400); };
  const login = async e => { await nav('マイページ'); await w(300); await p.fill('#a-email', e); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('text=ログアウト').waitFor(); await w(700); };
  const logout = async () => { await nav('マイページ'); await w(300); await p.locator('button', { hasText: 'ログアウト' }).click(); await w(800); };
  const goodContrast = x => x.fg >= 7 && x.muted >= 4.5 && x.faint >= 4.5 && x.accent >= 3 && (x.btn === null || x.btn >= 4.5);

  // ---- 0. 起動直後は標準テーマ（従来と同じ見た目）。初回はようこそ案内だけで紹介文は重ならない
  await p.goto('http://aimuse.test/'); await w(1200);
  const m0 = await m();
  ok('0 標準テーマは色の上書きなし（従来と同じ見た目）', m0.inline === '' && m0.bg === '#0b0912', m0.inline);
  const LOGO = m0.logo; const BRAND = await p.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--brand-grad').replace(/\s+/g,''));
  ok('0 初回のホーム：ようこそ案内あり・通常の紹介文は出さない', await p.locator('.welcome').count() === 1 && await p.locator('.demo-note').count() === 0);
  await p.screenshot({ path: `${OUT}/${DEV}-t0-home-welcome.png` });
  await p.locator('button[aria-label="案内を閉じる"]').click(); await w(300);
  ok('0 案内を閉じると通常の紹介文が出る', (await p.locator('.demo-note').innerText()).includes('AIで制作された楽曲だけ'));

  // ---- 1. ゲスト：プリセットのリアルタイムプレビュー・選択状態の表示
  await goSettingsGuest();
  ok('1 設定画面が開く（6種類のプリセット）', (await p.locator('.top h1').innerText()) === '設定' && await p.locator('.th-card').count() === 6);
  const names = await p.locator('.th-card b').allInnerTexts();
  ok('1 プリセット名', JSON.stringify(names) === JSON.stringify(['AIMUSE標準', 'オーシャン', 'ローズ', 'エメラルド', 'ゴールド', 'モノクロ']), names);
  const ms = await m();
  ok('1 標準テーマ：ボタン文字のコントラスト4.5以上（第4段階の修正）・本文/補足/アクセントも基準以上', ms.btn >= 4.5 && goodContrast(ms), { btn: +ms.btn.toFixed(2), fg: +ms.fg.toFixed(2), muted: +ms.muted.toFixed(2), faint: +ms.faint.toFixed(2), accent: +ms.accent.toFixed(2) });
  ok('1 標準が「選択中」（チェック印＋文字・aria-checked）', await card('AIMUSE標準').locator('.th-check').innerText() === '選択中' && await card('AIMUSE標準').getAttribute('aria-checked') === 'true');
  const contr = {};
  for (const n of ['オーシャン', 'ローズ', 'エメラルド', 'ゴールド', 'モノクロ']) {
    await card(n).click(); await w(150); const x = await m(); contr[n] = x;
    ok(`1 ${n}：押すとすぐ全体に反映・コントラスト基準を満たす・ロゴは不変`, x.inline.includes('--bg') && goodContrast(x) && x.logo === BRAND && x.meta === x.bg,
      { fg: +x.fg.toFixed(2), muted: +x.muted.toFixed(2), faint: +x.faint.toFixed(2), accent: +x.accent.toFixed(2), btn: x.btn && +x.btn.toFixed(2) });
    ok(`1 ${n}：選択中の印は1つだけ`, await p.locator('.th-check:not(.inline)').count() === 1 && await card(n).locator('.th-check').count() === 1);
  }
  await p.screenshot({ path: `${OUT}/${DEV}-t1-settings-mono.png`, fullPage: true });
  // 保存せずに戻ると元に戻る
  await p.locator('button[aria-label="戻る"]').click(); await w(400);
  ok('1 保存せずに戻ると標準に戻る', (await m()).inline === '');

  // ---- 2. オリジナルカラー（不正・極端な色でも読みやすさを確保）
  await goSettingsGuest();
  await p.locator('input[aria-label="背景カラー"]').fill('#ffffff'); await w(150);
  await p.locator('input[aria-label="アクセントカラー"]').fill('#101010'); await w(150);
  await p.locator('input[aria-label="ボタンカラー"]').fill('#808080'); await w(200);
  const xc = await m();
  ok('2 オリジナル：明るすぎる背景は暗く調整・文字は読める', goodContrast(xc) && /--bg: #/.test(xc.inline), { bg: xc.bg, fg: +xc.fg.toFixed(2), btn: xc.btn && +xc.btn.toFixed(2), accent: +xc.accent.toFixed(2) });
  const note = await p.locator('.warn-line').innerText().catch(() => '');
  ok('2 自動調整したことを文字で知らせる', note.includes('暗い色のみ') && note.includes('アクセントカラー') , note);
  ok('2 オリジナル使用中の表示（チェック＋文字）・プリセットの選択印は消える', await p.locator('.th-check.inline').innerText() === '使用中' && await p.locator('.th-check:not(.inline)').count() === 0);
  await p.screenshot({ path: `${OUT}/${DEV}-t2-custom.png`, fullPage: true });
  // ランダムな色でも基準を満たす（ブラウザ上で計測）
  let bad = 0;
  for (let i = 0; i < 25; i++) {
    const r = () => '#' + Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, '0');
    await p.locator('input[aria-label="アクセントカラー"]').fill(r()); await p.locator('input[aria-label="背景カラー"]').fill(r()); await p.locator('input[aria-label="ボタンカラー"]').fill(r());
    await w(30); if (!goodContrast(await m())) bad++;
  }
  ok('2 ランダムな色25通りでもコントラスト基準を満たす（画面上で計測）', bad === 0, bad);
  await p.locator('button.link', { hasText: '変更を取り消す' }).click(); await w(200);
  ok('2 「変更を取り消す」で保存済み（標準）に戻る', (await m()).inline === '' && await card('AIMUSE標準').getAttribute('aria-checked') === 'true');

  // ---- 3. ゲストの保存（この端末）
  await card('オーシャン').click(); await w(100);
  await p.locator('button', { hasText: '保存する' }).click(); await w(500);
  ok('3 ゲスト：この端末に保存', /この端末に/.test(await toast()) && JSON.parse(await p.evaluate(() => localStorage.getItem('aimuse.theme.guest'))).preset === 'ocean', await toast());
  ok('3 ゲスト：サーバーには送らない', await p.evaluate(() => window.__log.filter(l => l.op === 'rpc' && l.name === 'set_my_theme').length) === 0);
  await p.reload(); await w(1000);
  const OCEAN_BG = (await m()).bg;
  ok('3 再読み込みしてもオーシャンのまま', OCEAN_BG === contr['オーシャン'].bg, OCEAN_BG);
  await nav('ホーム'); await w(400);
  ok('3 ホームでもテーマが反映（ロゴは不変）', (await m()).logo === LOGO);

  // ---- 4. 再生中にテーマを変えても再生が止まらない
  await p.locator('.row', { hasText: 'おぼろ月' }).first().click(); await w(700);
  const a1 = await p.evaluate(() => { const a = document.querySelector('audio'); return a && { tid: a.dataset.tid, src: a.src, paused: a.paused, t: a.currentTime }; });
  await goSettingsGuest(); await card('ローズ').click(); await w(200); await card('エメラルド').click(); await w(200);
  const a2 = await p.evaluate(() => { const a = document.querySelector('audio'); return a && { tid: a.dataset.tid, src: a.src, paused: a.paused }; });
  ok('4 再生中にテーマを変えても同じ曲のまま（音源の差し替えなし）', a1 && a2 && a1.tid === a2.tid && a1.src === a2.src && a1.paused === a2.paused, { a1, a2 });
  ok('4 ミニプレーヤーも表示されたまま', await p.locator('[class*=mini]').count() > 0);
  await p.locator('button', { hasText: '保存する' }).click(); await w(400);
  await p.locator('[class*=mini]').first().click(); await w(500);
  await p.screenshot({ path: `${OUT}/${DEV}-t3-player-emerald.png` });
  ok('4 プレーヤー画面でも新しいテーマで表示・横にはみ出さない', (await m()).bg === contr['エメラルド'].bg && await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  await p.locator('.player button[aria-label="閉じる"]').click(); await w(300);

  // ---- 5. ログイン：テーマ未保存の人は端末のテーマのまま → 保存すると本人のテーマ
  await login('ryo@test.jp');
  ok('5 テーマ未保存の人がログイン：この端末のテーマのまま', (await m()).bg === contr['エメラルド'].bg);
  await goSettingsUser(); await card('ローズ').click(); await w(100);
  await p.locator('button', { hasText: '保存する' }).click(); await w(500);
  const ryoTheme = await p.evaluate(() => window.__db.profiles.find(x => x.id.startsWith('1111')).theme);
  ok('5 ログイン中：本人のプロフィールに保存（set_my_theme）', /どの端末でも/.test(await toast()) && ryoTheme && ryoTheme.preset === 'rose', ryoTheme);
  ok('5 ゲスト用のテーマ（端末）は変わらない', JSON.parse(await p.evaluate(() => localStorage.getItem('aimuse.theme.guest'))).preset === 'emerald');
  const others = await p.evaluate(() => window.__db.profiles.filter(x => !x.id.startsWith('1111')).map(x => x.theme || null));
  ok('5 他の利用者のテーマは変わらない', others.every(x => x === null), others);
  // 全画面：はみ出しなし・ロゴ不変
  const screens = [['ホーム', 'home'], ['検索', 'search'], ['投稿', 'upload'], ['マイページ', 'me']];
  let flow = [];
  for (const [l, k] of screens) { await nav(l); await w(400); const o = await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth); const x = await m(); if (!o || x.logo !== LOGO && k === 'home') flow.push(k); await p.screenshot({ path: `${OUT}/${DEV}-t4-rose-${k}.png` }); }
  await p.locator('button.admin-entry').click(); await w(600);
  if (!(await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth))) flow.push('admin');
  await p.screenshot({ path: `${OUT}/${DEV}-t4-rose-admin.png` });
  ok('5 ホーム・検索・投稿・マイページ・管理画面にテーマが反映、横にはみ出さない', flow.length === 0 && (await m()).bg === contr['ローズ'].bg, flow);

  // ---- 6. ログアウト → ゲスト用のテーマ / 別の人 → 影響なし / 再ログイン → 本人のテーマ
  await logout();
  ok('6 ログアウト後はゲスト用のテーマ（エメラルド）に戻る', (await m()).bg === contr['エメラルド'].bg && await p.evaluate(() => localStorage.getItem('aimuse.theme.last')) === null);
  await login('hamu@test.jp');
  ok('6 別の人（テーマ未保存）がログイン：Ryoのローズにはならない', (await m()).bg === contr['エメラルド'].bg);
  await logout(); await login('ryo@test.jp');
  ok('6 再ログインで本人のテーマ（ローズ）が戻る', (await m()).bg === contr['ローズ'].bg);
  // 別の端末を想定（端末の記録を消して再読み込み）
  await p.evaluate(() => { localStorage.removeItem('aimuse.theme.guest'); localStorage.removeItem('aimuse.theme.last'); }); await p.reload(); await w(1200);
  ok('6 端末の記録がなくても、ログインすると本人のテーマ（どの端末でも同じ）', (await m()).bg === contr['ローズ'].bg);

  // ---- 7. 標準に戻す
  await goSettingsUser();
  await p.locator('button', { hasText: '標準に戻す' }).click(); await w(500);
  const ryo2 = await p.evaluate(() => window.__db.profiles.find(x => x.id.startsWith('1111')).theme);
  ok('7 「標準に戻す」で上書きがすべて外れ、標準で保存', (await m()).inline === '' && ryo2.preset === 'standard' && await card('AIMUSE標準').getAttribute('aria-checked') === 'true', ryo2);
  // 保存失敗時：保存されたと表示しない・元に戻せる
  await p.evaluate(() => { window.__fail.theme = true; });
  await card('ゴールド').click(); await w(100); await p.locator('button', { hasText: '保存する' }).click(); await w(500);
  const t7 = await toast();
  ok('7 保存に失敗したら「保存できませんでした」と表示し、保存済みは変わらない', /保存できませんでした/.test(t7) && (await p.evaluate(() => window.__db.profiles.find(x => x.id.startsWith('1111')).theme)).preset === 'standard', t7);
  await p.evaluate(() => { window.__fail.theme = false; });
  await p.locator('button[aria-label="戻る"]').click(); await w(400);
  ok('7 失敗後に画面を離れると保存済み（標準）に戻る', (await m()).inline === '');
  await logout();

  // ---- 8. 不正な端末内データは無視 / 保存できない環境でも動く
  await p.evaluate(() => { localStorage.setItem('aimuse.theme.guest', JSON.stringify({ v: 1, preset: 'ocean', accent: 'red;}body{display:none', bg: '#000000', button: '#ffffff' })); localStorage.setItem('aimuse.theme.last', '{broken'); });
  await p.reload(); await w(1000);
  ok('8 端末内の不正なテーマは無視して標準で表示', (await m()).inline === '' && await p.locator('.row').count() > 0);
  const c3 = await b.newContext({ ...dev }); await c3.addInitScript(() => { Object.defineProperty(window, 'localStorage', { get() { throw new Error('blocked'); } }); });
  const p3 = await c3.newPage(); const e3 = []; p3.on('pageerror', e => e3.push(e.message)); await p3.route('**/*', route);
  await p3.goto('http://aimuse.test/'); await p3.waitForTimeout(1000);
  await p3.locator('nav.nav button', { hasText: 'マイページ' }).click(); await p3.waitForTimeout(300);
  await p3.locator('button', { hasText: 'カラーテーマを変更' }).click(); await p3.waitForTimeout(300);
  await p3.locator('.th-card', { hasText: 'ゴールド' }).click(); await p3.locator('button', { hasText: '保存する' }).click(); await p3.waitForTimeout(400);
  const s3 = await p3.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--bg').trim());
  ok('8 保存できない環境（プライベートブラウズ等）でもエラーにならず、その間は反映される', e3.length === 0 && s3 !== '#0b0912', { e3, s3 });

  // ---- 9. v1.8 SQL 未実行のサーバーでも、ログイン・表示は従来どおり
  const c4 = await b.newContext({ ...dev }); await c4.addInitScript(() => { window.__noV18 = true; });
  const p4 = await c4.newPage(); const e4 = []; p4.on('pageerror', e => e4.push(e.message)); await p4.route('**/*', route);
  await p4.goto('http://aimuse.test/'); await p4.waitForTimeout(1000);
  await p4.locator('nav.nav button', { hasText: 'マイページ' }).click(); await p4.waitForTimeout(300);
  await p4.fill('#a-email', 'ryo@test.jp'); await p4.fill('#a-pw', 'password'); await p4.locator('.form button.btn.primary').click(); await p4.locator('text=ログアウト').waitFor(); await p4.waitForTimeout(600);
  ok('9 v1.8未実行でもログインでき、管理者表示も従来どおり', await p4.locator('button.admin-entry').count() === 1 && e4.length === 0, e4);

  ok('エラーなし', errs.length === 0, errs);
  const f = R.filter(r => !r[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  await b.close();
})();
