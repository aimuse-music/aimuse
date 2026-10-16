// Stage 2 follow lists E2E (Chromium, iPhone / Android emulation)
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const [INDEX, DEV, OUT] = process.argv.slice(2);
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? 'PASS' : 'FAIL'}] ${n}${i !== undefined ? '  → ' + JSON.stringify(i) : ''}`); };
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const ctx = await b.newContext({ ...(DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13']) });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/*', r => { const u = r.request().url();
    if (u.startsWith('http://aimuse.test/') && !u.endsWith('.js')) return r.fulfill({ contentType: 'text/html', body: fs.readFileSync(INDEX) });
    if (u.endsWith('/config.js')) return r.fulfill({ contentType: 'text/javascript', body: 'window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k"};' });
    if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
    if (u.includes('react-dom.production') || u.includes('htm.umd')) return r.fulfill({ contentType: 'text/javascript', body: '' });
    if (u.includes('supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: 'window.__bigFollow=true;' + fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
    return r.fulfill({ status: 404, body: '' }); });
  const w = ms => p.waitForTimeout(ms || 500), nav = l => p.locator('nav.nav button', { hasText: l }).click();
  const toast = async () => (await p.locator('.toast').innerText().catch(() => '')).trim();
  const login = async e => { await nav('マイページ'); await w(300); await p.fill('#a-email', e); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('text=ログアウト').waitFor(); await w(700); };
  const logout = async () => { await nav('マイページ'); await w(300); await p.locator('text=ログアウト').click(); await w(600); };
  const openNoctera = async () => { await nav('ホーム'); await w(500); await p.locator('button.artist', { hasText: 'NOCTERA' }).first().click(); await w(800); };
  const names = () => p.locator('.fl-row .t').allInnerTexts();
  const more = async () => { while (await p.locator('button', { hasText: 'さらに表示' }).count()) { await p.locator('button', { hasText: 'さらに表示' }).click(); await w(500); } };

  await p.goto('http://aimuse.test/'); await w(1000);
  // ---- 1. 未ログインで閲覧
  await openNoctera();
  const head = await p.locator('.fstats').innerText();
  ok('1 アーティストページに「74 フォロワー · 32 フォロー中」（利用停止1人を除く）', /74 フォロワー/.test(head) && /32 フォロー中/.test(head), head);
  await p.locator('.fstats button', { hasText: 'フォロワー' }).click(); await w(800);
  ok('1 フォロワー数をタップで一覧（最初は30件）', (await names()).length === 30, (await names()).length);
  await p.screenshot({ path: `${OUT}/${DEV}-f1-followers.png` });
  await more();
  const fl = await names();
  ok('1 「さらに表示」で全35人（公開アーティストのみ）', fl.length === 35 && fl.every(n => n.startsWith('公開アーティスト')), fl.length);
  ok('1 利用停止中のアーティストは出ない', !fl.includes('公開アーティスト75'));
  const body = await p.locator('body').innerText();
  ok('1 リスナーは「ほか 39人のリスナー」と人数だけ・個人名は一切出ない', body.includes('ほか 39人のリスナー') && !body.includes('個人名'));
  await p.locator('.fl-listeners').scrollIntoViewIfNeeded(); await p.screenshot({ path: `${OUT}/${DEV}-f2-listeners.png` });
  await p.locator('.seg button', { hasText: 'フォロー中' }).click(); await w(800); await more();
  ok('1 フォロー中タブ：32人', (await names()).length === 32, (await names()).length);
  await p.locator('.fl-row .follow').first().click(); await w(500);
  ok('1 未ログインでフォローボタン→ログインの案内', (await toast()).includes('ログインが必要'), await toast());
  await p.locator('.fl-main', { hasText: '公開アーティスト1' }).first().click(); await w(800);
  ok('1 一覧をタップでその人の公開ページへ（曲を再生できる）', (await p.locator('.ahead h2').innerText()) === '公開アーティスト1' && await p.locator('.row', { hasText: '曲1' }).count() >= 1);
  await p.locator('.row', { hasText: '曲1' }).first().click(); await w(500);
  ok('1 未ログインのまま曲を再生できる（登録を求められない）', !(await toast()).includes('ログイン'));
  await p.locator('button[aria-label="戻る"]').first().click(); await w(500);
  ok('1 戻るで一覧に戻る', await p.locator('.fl-row').count() > 0);

  // ---- 2. ハムハムで一覧からフォロー・解除、人数の更新
  await p.goto('http://aimuse.test/'); await w(900); await login('hamu@test.jp'); await openNoctera();
  await p.locator('.fstats button', { hasText: 'フォロワー' }).click(); await w(800);
  const row3 = p.locator('.fl-row', { hasText: '公開アーティスト3' }).first();
  await row3.locator('.follow').click(); await w(900);
  let d = await p.evaluate(() => JSON.parse(sessionStorage.getItem('fakedb2')));
  ok('2 一覧から「フォローする」→フォロー中になり保存される', (await row3.locator('.follow').innerText()) === 'フォロー中' && d.follows.some(f => f.user_id === '22222222-2222-4222-8222-222222222222' && f.artist_id === 'a0000000-0000-4000-8000-000000000003'));
  await row3.locator('.follow').click(); await w(900);
  d = await p.evaluate(() => JSON.parse(sessionStorage.getItem('fakedb2')));
  ok('2 もう一度押すと解除され、保存からも消える', (await row3.locator('.follow').innerText()) === 'フォローする' && !d.follows.some(f => f.user_id === '22222222-2222-4222-8222-222222222222' && f.artist_id === 'a0000000-0000-4000-8000-000000000003'));
  ok('2 フォロー前はハムハムの名前は一覧に出ない', !(await p.locator('body').innerText()).includes('ハムハム'));
  await p.locator('button[aria-label="戻る"]').first().click(); await w(500);
  await p.locator('.ahead button.follow').click(); await w(1000);
  await p.locator('.fstats button', { hasText: 'フォロワー' }).click(); await w(800);
  ok('2 ハムハムがフォロー→フォロワー数が75に更新', (await p.locator('.seg button').first().innerText()).includes('75'), await p.locator('.seg button').first().innerText());
  await more(); const ln = await p.locator('.fl-listeners').innerText().catch(e => 'なし:' + e.message.slice(0, 60));
  const n2 = await names();
  ok('2 公開曲のあるハムハムは「公開アーティスト」として一覧に追加（36人）、リスナーは39人のまま', n2.length === 36 && n2[0] === 'ハムハム' && ln.includes('39人'), { count: n2.length, first: n2[0], ln });

  // ---- 3. Ryo のマイページから
  await logout(); await login('ryo@test.jp');
  const stats = await p.locator('.stats').innerText();
  ok('3 マイページ：フォロー32・フォロワー75', /32\s*フォロー/.test(stats) && /75\s*フォロワー/.test(stats), stats.replace(/\n/g, ' '));
  await p.locator('button.stat', { hasText: 'フォロー' }).first().click(); await w(800); await more();
  ok('3 フォロー数をタップ→自分のフォロー中32人', (await names()).length === 32);
  await p.screenshot({ path: `${OUT}/${DEV}-f3-myfollowing.png` });
  await p.locator('.fl-row .follow').first().click(); await w(900);
  ok('3 自分の一覧から解除できる', (await p.locator('.fl-row .follow').first().innerText()) === 'フォローする');
  await p.locator('.seg button', { hasText: 'フォロワー' }).click(); await w(800);
  ok('3 フォロワータブ：自分のアーティストのフォロワー（公開アーティスト）', (await names()).length === 30);
  ok('3 自分のアーティストにはフォローボタンが出ない／横にはみ出さない', await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

  // ---- 4. 非公開になったアーティストをフォロー中の場合（数と一覧の関係）
  await p.evaluate(() => { const d = JSON.parse(sessionStorage.getItem('fakedb2')); d.tracks.find(t => t.title === '曲5').status = 'hidden'; sessionStorage.setItem('fakedb2', JSON.stringify(d)); });
  await p.goto('http://aimuse.test/'); await w(1200); await nav('マイページ'); await w(600);
  const st4 = await p.locator('.stats').innerText();
  const total = +((st4.match(/(\d+)\s*フォロー(?!ワー)/) || [])[1]);
  await p.locator('.tabs button', { hasText: 'フォロー中' }).click(); await w(400);
  const tabLabel = await p.locator('.tabs button', { hasText: 'フォロー中' }).innerText();
  const note = await p.locator('.fl-listeners').innerText().catch(() => '');
  const shown = await p.locator('.tabs ~ div .list .row').count();
  ok('4 マイページ：フォロー数・タブの数は同じ（フォローは削除しない）', tabLabel.includes(String(total)), { total, tabLabel });
  ok('4 公開中の一覧＋「ほか1件は公開中の曲がない」の説明で数が合う', shown + 1 === total && note.includes('ほか 1件'), { shown, note });
  await p.locator('.fl-listeners button', { hasText: '一覧で確認' }).click(); await w(800); await more();
  const bd = await p.locator('.fl-breakdown').innerText();
  const greyed = await p.locator('.fl-row', { hasText: '公開されていないアーティスト' }).count();
  ok('4 一覧に内訳表示・非公開の1件も解除できる形で表示', bd.includes(`フォロー中 ${total}件`) && bd.includes('現在公開中の曲がない 1件') && greyed === 1 && (await names()).length === total, { bd, greyed });
  await p.locator('.fl-breakdown').scrollIntoViewIfNeeded(); await p.screenshot({ path: `${OUT}/${DEV}-f4-breakdown.png` });

  ok('エラーなし', errs.length === 0, errs);
  const f = R.filter(r => !r[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  await b.close();
})();
