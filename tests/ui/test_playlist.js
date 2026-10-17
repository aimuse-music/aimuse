// プレイリスト：作成・曲の追加/削除・連続再生・公開/非公開・名前の変更・削除（iPhone / Android）
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
function wav(sec) { const sr = 8000, n = Math.floor(sr * sec), b = Buffer.alloc(44 + n * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(sr, 24); b.writeUInt32LE(sr * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(Math.sin(i / sr * 2 * Math.PI * 440) * 800), 44 + i * 2);
  return 'data:audio/wav;base64,' + b.toString('base64'); }
const T1 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', T2 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2';
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--autoplay-policy=no-user-gesture-required'] });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const ctx = await b.newContext({ ...dev }); await ctx.addInitScript(a => { window.__testAudio = a; }, wav(0.9));
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message)); await p.route('**/*', route);
  const w = ms => p.waitForTimeout(ms || 400);
  const nav = l => p.locator('nav.nav button', { hasText: l }).click();
  const toast = async () => (await p.locator('.toast').last().innerText().catch(() => '')).trim();
  const login = async email => { await nav('マイページ'); await w(300); await p.fill('#a-email', email); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('text=ログアウト').waitFor(); await w(900); };
  const logout = async () => { await nav('マイページ'); await w(300); await p.locator('button', { hasText: 'ログアウト' }).click(); await w(700); };
  const plTab = async () => { await nav('マイページ'); await w(300); await p.locator('.tabs button', { hasText: 'プレイリスト' }).click(); await w(300); };
  const tid = () => p.evaluate(() => document.querySelector('audio').dataset.tid);
  const noOverflow = () => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);

  await p.goto('http://aimuse.test/'); await w(1200);
  await login('hamu@test.jp');
  // 1. 作成
  await plTab();
  ok('1 マイページに「プレイリスト 0」のタブ・作成欄が出る', await p.locator('.tabs button', { hasText: 'プレイリスト 0' }).count() === 1 && await p.locator('.pl-new input').count() === 1);
  await p.fill('.pl-new input', '  ドライブ  '); await p.locator('.pl-new button', { hasText: '作成' }).click(); await w(900);
  ok('1 作成すると一覧に出る（前後の空白は除く）', await p.locator('.list .row .t', { hasText: /^ドライブ$/ }).count() === 1 && /作成しました/.test(await toast()), await toast());
  ok('1 新しいプレイリストは非公開', await p.locator('.list .row', { hasText: 'ドライブ' }).locator('.tag', { hasText: '非公開' }).count() === 1);
  // 2. 再生画面から曲を追加
  for (const title of ['おぼろ月', 'ああ']) {
    await nav('ホーム'); await w(300); await p.locator('.list .row', { hasText: title }).first().click();
    await p.evaluate(() => { const a = document.querySelector('audio'); a.pause(); }); await w(300);   // 0.9秒の試験用の音で次の曲に進まないよう止める
    if (await p.locator('.player').count() === 0) { await p.locator('.mini').first().click(); await w(400); }
    await p.locator('.player .pill', { hasText: 'プレイリスト' }).click(); await w(300);
    await p.locator('.sheet .opt', { hasText: 'ドライブ' }).click();
    const added = await p.locator('.sheet .opt.on', { hasText: 'ドライブ' }).waitFor({ timeout: 4000 }).then(() => true).catch(() => false);
    ok(`2 再生画面から「${title}」を追加できる（✓が付く）`, added && (await p.locator('.player .pt .t').innerText()) === title);
    await p.locator('.sheet button', { hasText: '閉じる' }).click(); await w(200);
    await p.locator('.player button[aria-label="閉じる"]').click(); await w(300);
  }
  // 3. プレイリストの画面・連続再生
  await plTab(); await p.locator('.list .row', { hasText: 'ドライブ' }).click(); await w(400);
  ok('3 プレイリストの画面に2曲が追加順に並ぶ', JSON.stringify(await p.locator('.list .row .t').allInnerTexts()) === JSON.stringify(['おぼろ月', 'ああ']));
  await p.locator('button', { hasText: 'すべて再生' }).click(); await w(300);
  const first = await tid();
  await p.locator('.mini').first().click(); await w(300);
  const label = await p.locator('.player .ph .mid b').innerText();
  ok('3 「すべて再生」で1曲目から再生し、再生中のリスト名はプレイリスト名', first === T1 && label === 'ドライブ', { first, label });
  let second = null; for (let i = 0; i < 40 && !second; i++) { await w(100); const t = await tid(); if (t !== first) second = t; }
  ok('3 曲が終わると次の曲へ自動で進む（連続再生）', second === T2, second);
  await p.locator('.player button[aria-label="閉じる"]').click(); await w(200);
  await p.evaluate(() => { const a = document.querySelector('audio'); a.loop = true; }); await w(200);
  const wasPlaying = await p.evaluate(() => !document.querySelector('audio').paused);
  await p.locator('.list .row', { hasText: 'ああ' }).click(); await w(400);
  ok('3 プレイリストの画面で再生中の曲をタップすると一時停止（ほかの一覧と同じ）', wasPlaying && await p.evaluate(() => document.querySelector('audio').paused));
  await p.evaluate(() => { const a = document.querySelector('audio'); a.loop = false; a.pause(); });
  // 4. 曲を外す・公開・名前の変更
  await p.locator('.row', { hasText: 'ああ' }).locator('button[aria-label*="プレイリストから外す"]').click(); await w(900);
  ok('4 曲を外せる', JSON.stringify(await p.locator('.list .row .t').allInnerTexts()) === JSON.stringify(['おぼろ月']) && /外しました/.test(await toast()));
  await p.locator('button', { hasText: '公開する' }).click(); await w(900);
  ok('4 公開にできる（表示が「公開」に変わる）', await p.locator('.ahead .tag', { hasText: /^公開$/ }).count() === 1 && await p.locator('button', { hasText: '非公開にする' }).count() === 1);
  await p.locator('button.link', { hasText: '名前を変更' }).click(); await p.fill('.pl-edit input', '夜のドライブ'); await p.locator('.pl-edit button', { hasText: '保存' }).click(); await w(900);
  ok('4 名前を変更できる', await p.locator('.ahead h2', { hasText: '夜のドライブ' }).count() === 1);
  ok('4 画面の横はみ出しなし', await noOverflow());
  // 5. 他の人から見た公開プレイリスト
  await logout(); await nav('ホーム'); await w(600);
  const card = p.locator('.sec', { hasText: 'みんなのプレイリスト' }).locator('.card', { hasText: '夜のドライブ' });
  ok('5 ログアウト後も、ホームの「みんなのプレイリスト」に公開分が出る', await card.count() === 1);
  await card.click(); await w(400);
  ok('5 他の人には編集・削除・外すボタンが出ない', await p.locator('button', { hasText: /公開する|非公開にする|名前を変更|プレイリストを削除/ }).count() === 0 && await p.locator('button[aria-label*="プレイリストから外す"]').count() === 0);
  await p.locator('button', { hasText: 'すべて再生' }).click(); await w(400);
  ok('5 未ログインでも「すべて再生」できる', await tid() === T1);
  await p.evaluate(() => document.querySelector('audio').pause());
  await p.locator('.mini').first().click(); await w(300); await p.locator('.player .pill', { hasText: 'プレイリスト' }).click(); await w(300);
  ok('5 未ログインで「プレイリストに追加」を開くとログインの案内', await p.locator('.sheet', { hasText: 'ログインすると' }).count() === 1);
  await p.locator('.sheet button', { hasText: '閉じる' }).click(); await p.locator('.player button[aria-label="閉じる"]').click(); await w(200);
  await login('mike@test.jp'); await plTab();
  ok('5 別の会員のマイページには、ハムハムのプレイリストは出ない', await p.locator('.list .row', { hasText: 'ドライブ' }).count() === 0);
  // 6. 非公開に戻すと見えなくなる・削除
  await logout(); await login('hamu@test.jp'); await plTab(); await p.locator('.list .row', { hasText: '夜のドライブ' }).click(); await w(400);
  await p.locator('button', { hasText: '非公開にする' }).click(); await w(900);
  await nav('ホーム'); await w(900);
  ok('6 非公開に戻すとホームの公開一覧から消える', await p.locator('.sec', { hasText: 'みんなのプレイリスト' }).count() === 0);
  await plTab(); await p.locator('.list .row', { hasText: '夜のドライブ' }).click(); await w(400);
  await p.locator('button.link', { hasText: 'プレイリストを削除' }).click(); await w(300);
  ok('6 削除の前に確認が出る', await p.locator('.sheet', { hasText: '削除しますか' }).count() === 1);
  await p.locator('.sheet button', { hasText: '削除する' }).click(); await w(700);
  ok('6 削除するとマイページの一覧に戻り、0件になる（曲そのものは残る）', await p.locator('.tabs button', { hasText: 'プレイリスト 0' }).count() === 1 && await p.evaluate(() => window.__db.tracks.length) >= 3);
  // 7. 書き込みできない会員・未適用
  await p.evaluate(() => { const d = window.__db; d.profiles.find(x => x.display_name === 'ハムハム').is_banned = true; sessionStorage.setItem('fakedb2', JSON.stringify(d)); });
  await plTab(); await p.fill('.pl-new input', 'テスト'); await p.locator('.pl-new button', { hasText: '作成' }).click(); await w(900);
  ok('7 利用停止中の会員は作成できず、理由が表示される', /作成できません/.test(await toast()), await toast());
  ok('エラーなし', errs.length === 0, errs);
  await p.screenshot({ path: `${OUT}/${DEV}-playlist.png` });
  const f = R.filter(r => !r[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  await b.close();
})();
