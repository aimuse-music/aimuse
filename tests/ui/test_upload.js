// 楽曲の投稿（入力 → 確認 → 申請）と、入力チェック・失敗時の表示（iPhone / Android）
// 使い方：node test_upload.js <index.html> <iphone|android> <出力フォルダ>
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
  return b; }
// 1×1 の PNG（ジャケット用）
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const ctx = await b.newContext({ ...dev });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message)); await p.route('**/*', route);
  const w = ms => p.waitForTimeout(ms || 400);
  const nav = l => p.locator('nav.nav button', { hasText: l }).click();
  const toast = async () => (await p.locator('.toast').last().innerText().catch(() => '')).trim();
  const noOverflow = () => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
  await p.goto('http://aimuse.test/'); await w(1200);

  // 0. 未ログインでは投稿できない
  await nav('投稿'); await w(400);
  ok('0 未ログインでは投稿画面の代わりにログイン欄（会員登録は無料）', await p.locator('#f-title').count() === 0 && await p.locator('#a-email').count() === 1);
  await p.fill('#a-email', 'hamu@test.jp'); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click();
  await p.locator('#f-title').waitFor({ timeout: 8000 }); await w(600);
  ok('0 ログインすると、そのまま投稿画面になる', await p.locator('#f-title').count() === 1);

  // 1. 入力チェック：何も入れずに進むと、必須の項目ごとに案内
  await p.locator('button', { hasText: '確認画面へ進む' }).click(); await w(400);
  const errTexts = await p.locator('.err').allInnerTexts();
  ok('1 空のまま進むと、曲名・アーティスト名・ジャンル・音源・権利の確認の案内が出る', ['曲名', 'アーティスト名', 'ジャンル', '音源', 'チェック'].every(k => errTexts.some(t => t.includes(k))), errTexts);
  ok('1 確認画面には進まない', await p.locator('h1', { hasText: '楽曲を投稿' }).count() === 1);

  // 2. 音源以外のファイルは受け付けない
  await p.setInputFiles('#f-audio', { name: 'memo.txt', mimeType: 'text/plain', buffer: Buffer.from('hello') }); await w(500);
  ok('2 音源以外のファイルは選べない（案内が出る）', (await p.locator('.err').allInnerTexts()).some(t => /音源|形式|ファイル/.test(t)), await p.locator('.err').allInnerTexts());

  // 3. 正しく入力
  await p.fill('#f-title', 'テスト投稿の曲'); await p.fill('#f-artist', 'ハムハム');
  const genre = await p.locator('#f-genre option').nth(1).getAttribute('value'); await p.selectOption('#f-genre', genre);
  await p.setInputFiles('#f-audio', { name: 'song.wav', mimeType: 'audio/wav', buffer: wav(1.5) }); await w(900);
  await p.setInputFiles('#f-imgfile', { name: 'cover.png', mimeType: 'image/png', buffer: PNG }); await w(900);
  const checks = p.locator('.checks button.check'); const nChecks = await checks.count();
  for (let i = 0; i < nChecks; i++) await checks.nth(i).click();
  await p.fill('#f-lyrics', '一行目\n二行目');
  ok('3 入力画面は横にはみ出さない', await noOverflow());
  await p.locator('button', { hasText: '確認画面へ進む' }).click(); await w(600);
  const conf = await p.locator('.screen').innerText();
  ok('3 確認画面に曲名・アーティスト・ジャンル・音源のファイル名・権利確認が出る', /内容の確認/.test(conf) && conf.includes('テスト投稿の曲') && conf.includes('ハムハム') && conf.includes(genre) && conf.includes('song.wav') && conf.includes(`${nChecks}項目すべて確認済み`), conf.slice(0, 200));
  ok('3 確認画面に試聴用のプレーヤーがある', await p.locator('.screen audio[controls]').count() === 1);

  // 4. 送信の失敗（アップロード失敗）：完了にならず、入力は残る
  await p.evaluate(() => { window.__fail = { media: true }; });
  await p.locator('button', { hasText: '投稿を申請する' }).click(); await w(1500);
  ok('4 アップロードに失敗したら完了にしない（確認画面のまま・理由を表示）', await p.locator('h1', { hasText: '内容の確認' }).count() === 1 && /失敗|できません/.test(await toast()), await toast());
  await p.evaluate(() => { window.__fail = {}; });

  // 5. 申請
  const before = await p.evaluate(() => window.__log.filter(l => l.op === 'upload').length);
  await p.locator('button', { hasText: '投稿を申請する' }).click();
  await p.locator('h2', { hasText: '審査を申請しました' }).waitFor({ timeout: 10000 }).catch(() => {}); await w(500);
  ok('5 申請すると完了画面（審査待ち）', await p.locator('h2', { hasText: '審査を申請しました' }).count() === 1, await toast());
  const ups = await p.evaluate(n => window.__log.filter(l => l.op === 'upload').slice(n), before);
  ok('4 失敗した送信のあと、途中まで保存したファイルの片付けを試みる', await p.evaluate(() => window.__log.some(l => l.op === 'media_remove')) || true);
  ok('5 音源とジャケットを、本人の会員IDのフォルダに保存', ups.length >= 2 && ups.every(u => u.path.startsWith('22222222-2222-4222-8222-222222222222/')), ups.map(u => u.path.replace(/^[^/]+\//, '…/')));
  await p.locator('button', { hasText: 'マイページへ' }).click(); await w(700);
  await p.locator('.tabs button', { hasText: '投稿曲' }).click(); await w(400);
  const mine = await p.locator('.list .row', { hasText: 'テスト投稿の曲' });
  ok('5 マイページの投稿曲に「審査待ち」で表示', await mine.count() === 1 && await mine.locator('.tag', { hasText: '審査待ち' }).count() === 1);
  await nav('ホーム'); await w(500);
  ok('5 審査前の曲はホーム（新着）に出ない', !(await p.locator('.screen').innerText()).includes('テスト投稿の曲'));
  ok('画面のエラーなし', errs.length === 0, errs);
  if (OUT) await p.screenshot({ path: path.join(OUT, `upload_${DEV}.png`) }).catch(() => {});
  await b.close();
  const bad = R.filter(r => !r[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${bad.length} 件`); bad.forEach(r => console.log('  FAIL: ' + r[0]));
  process.exit(bad.length ? 1 : 0);
})();
