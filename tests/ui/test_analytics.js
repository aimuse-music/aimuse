// v1.17 アクセス解析：画面の表示の送信・管理者の除外・再生数の送り先（二重に数えない）・管理者の集計画面・プライバシーポリシー（iPhone / Android）
// 使い方：node test_analytics.js <index.html> <iphone|android> <出力フォルダ>
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const [INDEX, DEV, OUT] = process.argv.slice(2);
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? 'PASS' : 'FAIL'}] ${n}${i !== undefined ? '  → ' + JSON.stringify(i).slice(0, 200) : ''}`); };
const V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const route = feat => r => { const u = r.request().url();
  if (u.startsWith('http://aimuse.test/') && !u.endsWith('.js')) return r.fulfill({ contentType: 'text/html', body: fs.readFileSync(INDEX) });
  if (u.endsWith('/config.js')) return r.fulfill({ contentType: 'text/javascript', body: `window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k",features:{analytics:${feat}}};` });
  if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
  if (u.includes('react-dom.production') || u.includes('htm.umd')) return r.fulfill({ contentType: 'text/javascript', body: '' });
  if (u.includes('supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
  return r.fulfill({ status: 404, body: '' }); };
const wav = sec => { const sr = 8000, n = Math.floor(sr * sec), b = Buffer.alloc(44 + n * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(sr, 24); b.writeUInt32LE(sr * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(Math.sin(i / sr * 2 * Math.PI * 440) * 800), 44 + i * 2);
  return 'data:audio/wav;base64,' + b.toString('base64'); };   // 再生数は実際に音が流れてから数えるため、本物の短い音声を使う
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--autoplay-policy=no-user-gesture-required'] });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const open = async (feat = true) => { const ctx = await b.newContext({ ...dev }); await ctx.addInitScript(a => { window.__testAudio = a; }, wav(6)); const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message)); await p.route('**/*', route(feat)); return { ctx, p, errs }; };
  let { ctx, p, errs } = await open();
  const w = ms => p.waitForTimeout(ms || 400);
  const nav = l => p.locator('nav.nav button', { hasText: l }).click();
  const calls = n => p.evaluate(n => window.__log.filter(l => l.op === 'rpc' && l.name === n).map(l => l.args), n);
  const login = async e => { await nav('マイページ'); await w(300); await p.fill('#a-email', e); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('text=ログアウト').waitFor(); await w(700); };
  const logout = async () => { await nav('マイページ'); await w(300); await p.locator('button', { hasText: 'ログアウト' }).click(); await w(800); };
  const noOverflow = () => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
  // 再生して、数える基準（6秒の曲なので半分の3秒）まで聴いてから一時停止する
  const play = async title => { await nav('ホーム'); await w(300); await p.locator('.row', { hasText: title }).first().click();
    await p.waitForFunction(() => window.__listenMeter && window.__listenMeter.state().done, null, { timeout: 9000 }).catch(() => {}); await w(300);
    await p.locator('.mini button[aria-label="一時停止"]').click().catch(() => {}); await w(200); };

  // ---- 1. 未ログインの訪問者
  await p.goto('http://aimuse.test/'); await w(1200);
  await p.locator('button[aria-label="案内を閉じる"]').click().catch(() => {});
  let t = await calls('analytics_track');
  const vid = await p.evaluate(() => localStorage.getItem('aimuse.vid'));
  ok('1 未ログインでもホームの表示を1回送る', t.length === 1 && t[0].p_page === 'home', t);
  ok('1 送るのは匿名ID（UUID v4）と画面の名前だけ（会員ID・メールは送らない）', V4.test(vid) && t[0].p_vid === vid && Object.keys(t[0]).sort().join() === 'p_page,p_vid', t[0]);
  await nav('検索'); await w(300); await p.fill('#q', 'お'); await w(300); await p.fill('#q', 'おぼ'); await w(400);
  t = await calls('analytics_track');
  ok('1 画面を移ると送る・同じ画面の再描画（検索の入力）では送らない', t.map(x => x.p_page).join() === 'home,search', t.map(x => x.p_page));
  await p.reload(); await w(1200);
  t = await calls('analytics_track');
  ok('1 再読み込みしても同じ匿名ID（重複はサーバー側で30分に1回にまとめる）', t.length === 1 && t[0].p_vid === vid, t);

  // ---- 2. 再生数（count_play だけを呼ぶ。二重に数えない）
  await play('おぼろ月');
  let cp = await calls('count_play'), ip = await calls('increment_plays');
  ok('2 再生すると count_play を1回だけ呼ぶ（increment_plays は呼ばない）', cp.length === 1 && ip.length === 0 && cp[0].p_vid === vid && !!cp[0].tid, { cp, ip });
  await p.evaluate(() => { window.__noV117 = true; });
  await play('ひまわり');
  cp = await calls('count_play'); ip = await calls('increment_plays');
  ok('2 v1.17 のSQLが未実行なら、従来の increment_plays で1回だけ数える', cp.length === 2 && ip.length === 1, { cp: cp.length, ip: ip.length });
  await play('ああ');
  cp = await calls('count_play'); ip = await calls('increment_plays');
  ok('2 未実行と分かった後は increment_plays だけを呼ぶ（毎回の失敗をしない）', cp.length === 2 && ip.length === 2, { cp: cp.length, ip: ip.length });
  await nav('検索'); await w(300); await nav('ホーム'); await w(300); await nav('マイページ'); await w(300);
  t = await calls('analytics_track');
  ok('2 未実行と分かった後は画面の表示も送らない', t.filter(x => x.p_page === 'me').length === 0, t.map(x => x.p_page));
  await p.evaluate(() => { window.__noV117 = false; });

  // ---- 3. 一般の会員
  await p.reload(); await w(1200);
  await login('hamu@test.jp');
  t = await calls('analytics_track');
  ok('3 一般の会員の表示も数える（会員IDは送らない）', t.length >= 1 && t.every(x => x.p_vid === vid && Object.keys(x).length === 2), t);
  ok('3 一般の会員の端末は除外しない', (await calls('analytics_exclude_device')).length === 0 && await p.evaluate(() => localStorage.getItem('aimuse.adminDevice')) === null);
  ok('3 一般の会員には管理者画面の入口が出ない', await p.locator('.admin-entry').count() === 0);
  await logout();

  // ---- 4. 管理者：ログイン中・ログアウト後も送らない
  await p.reload(); await w(1200);
  await login('ryo@test.jp');
  const ex = await calls('analytics_exclude_device');
  ok('4 管理者でログインすると、この端末を計測から外す（匿名IDを送る）', ex.length === 1 && ex[0].p_vid === vid && await p.evaluate(() => localStorage.getItem('aimuse.adminDevice')) === '1', ex);
  const before = (await calls('analytics_track')).length;
  await nav('検索'); await w(300); await nav('ホーム'); await w(300);
  ok('4 管理者のログイン中は画面の表示を送らない', (await calls('analytics_track')).length === before);
  await play('ひまわり');
  cp = await calls('count_play');
  ok('4 管理者の再生も公開中の再生数には数える（日別の集計はサーバー側で除外）', cp.length >= 1, cp.length);
  await logout(); await p.reload(); await w(1200);
  await nav('検索'); await w(300); await nav('ホーム'); await w(300);
  ok('4 管理者としてログインした端末は、ログアウト後も画面の表示を送らない', (await calls('analytics_track')).length === 0);
  await play('おぼろ月');
  cp = await calls('count_play');
  ok('4 ログアウト後の再生は匿名IDつきで送る（サーバー側で日別の集計から外す）', cp.length === 1 && cp[0].p_vid === vid, cp);

  // ---- 5. 管理者の集計画面
  await login('ryo@test.jp');
  await nav('マイページ'); await w(300); await p.locator('.admin-entry').click(); await w(500);
  const tabs = await p.locator('.tabs button').allInnerTexts();
  ok('5 管理者画面に「アクセス解析」タブ（既存のタブはそのまま）', ['投稿審査', '通報', '楽曲管理', '名義変更', '歌詞AI', 'アクセス解析'].every(x => tabs.some(y => y.startsWith(x))), tabs);
  await p.locator('.tabs button', { hasText: 'アクセス解析' }).click(); await w(900);
  const txt = await p.locator('.an').innerText();
  ok('5 今日・昨日・過去7日・過去30日の訪問者・表示数・再生数', ['今日', '昨日', '過去7日', '過去30日'].every(x => txt.includes(x)) && (await p.locator('.an-card').count()) === 4 && txt.includes('訪問者（推計）'), txt.slice(0, 120));
  ok('5 訪問者数は推計値と明記（実際の人数と一致しない）', txt.includes('端末・ブラウザごとの推計値') && txt.includes('実際の人数とは一致しません'));
  ok('5 日別の推移：30本の棒', await p.locator('.an-chart rect.an-bar').count() === 30);
  await p.locator('.an-chart rect[fill="transparent"]').nth(29).click(); await w(200);
  ok('5 棒をタップすると、その日の表示数・訪問者・再生数を表示', /表示数 \d+・訪問者（推計） \d+・再生 \d+/.test(await p.locator('.an-sel').innerText()), await p.locator('.an-sel').innerText());
  await p.locator('.an-metrics .chip', { hasText: '再生数' }).click(); await w(200);
  ok('5 表示する数値を切り替えられる（再生数）', await p.locator('.an-metrics .chip.on').innerText() === '再生数');
  await p.locator('.an .seg button', { hasText: '月別' }).click(); await w(300);
  ok('5 月別の推移：12本の棒・注意書き', await p.locator('.an-chart rect.an-bar').count() === 12 && (await p.locator('.an').innerText()).includes('その月に1回以上訪れた端末の数'));
  ok('5 画面別の表示数（日本語の画面名）', (await p.locator('.an-page span').allInnerTexts()).join() === 'ホーム,検索,アーティスト,マイページ,規約・ポリシー');
  const rk = await p.locator('.an-rrow').count();
  ok('5 楽曲別の再生ランキング（既定は30日）・期間と累計の両方', rk > 0 && (await p.evaluate(() => window.__log.filter(l => l.op === 'ranking').map(l => l.days))).join() === '30' && /回/.test(await p.locator('.an-rrow .an-n b').first().innerText()) && /累計 \d+回/.test(await p.locator('.an-rrow .an-n span').first().innerText()), rk);
  await p.locator('.an .seg button', { hasText: '7日' }).click(); await w(500);
  ok('5 期間を切り替えると、その期間で読み直す（7日）', (await p.evaluate(() => window.__log.filter(l => l.op === 'ranking').map(l => l.days))).join() === '30,7');
  ok('5 期間の再生数・累計の違いを説明', (await p.locator('.an').innerText()).includes('管理者の再生を含みません') && (await p.locator('.an').innerText()).includes('計測開始前の分も含みます'));
  ok('5 横にはみ出さない', await noOverflow());
  fs.mkdirSync(OUT, { recursive: true });
  await p.locator('.an').screenshot({ path: path.join(OUT, `analytics_${DEV}.png`) });
  await p.evaluate(() => { window.__anBig = true; }); await p.locator('.an button', { hasText: '最新の状態に更新' }).click(); await w(700);
  ok('5 大きな数（1,234,574）でも崩れない', (await p.locator('.an-card').first().innerText()).includes('1,234,574') && await noOverflow() && await p.evaluate(() => [...document.querySelectorAll('.an-card')].every(c => c.scrollWidth <= c.clientWidth + 1)));
  await p.evaluate(() => { window.__anBig = false; window.__anRate = true; }); await p.locator('.an button', { hasText: '最新の状態に更新' }).click(); await w(600);
  ok('5 読み込みすぎの上限：前の数値を残したまま案内を表示', (await p.locator('.an').innerText()).includes('しばらく待ってから') && await p.locator('.an-card').count() === 4);
  await p.evaluate(() => { window.__anRate = false; });
  await p.locator('.tabs button', { hasText: '投稿審査' }).click(); await w(300);
  ok('5 ほかのタブ（投稿審査）は今までどおり開ける', await p.locator('.tabs button.on').innerText().then(s => s.startsWith('投稿審査')));
  await p.evaluate(() => { window.__noV117 = true; }); await p.locator('.tabs button', { hasText: 'アクセス解析' }).click(); await w(600);
  ok('5 v1.17 のSQLが未実行なら、その旨を表示', (await p.locator('.screen').innerText()).includes('v1.17 のSQL'));
  await p.evaluate(() => { window.__noV117 = false; });
  await logout();
  // 一般の会員が管理者画面を開いても見られない（DB側でも NOT_ALLOWED）
  await login('hamu@test.jp');
  const denied = await p.evaluate(async () => (await window.supabase.createClient('', '').rpc('admin_analytics')).error?.message || '');
  ok('5 一般の会員が集計を呼ぶと NOT_ALLOWED', /NOT_ALLOWED/.test(denied), denied);
  await logout();

  // ---- 6. プライバシーポリシー
  await nav('マイページ'); await w(300); await p.locator('button', { hasText: 'プライバシーポリシー' }).first().click(); await w(600);
  const pol = await p.locator('article.legal').innerText().catch(() => '');
  ok('6 第2条：匿名ID・画面の種類・日時を記録し、会員ID・メール・IPは保存しないと記載', pol.includes('アクセス数を集計するとき') && pol.includes('会員ID・メールアドレス・IPアドレスは保存せず'));
  ok('6 第6条：「アクセス解析ツールを使用していません」を改め、匿名IDの保存と外部ツール不使用を記載', !pol.includes('Cookieやアクセス解析ツールを使用していません') && pol.includes('ランダムな識別子（匿名ID）を保存します') && pol.includes('外部の事業者のアクセス解析ツールを使用していません'));
  ok('6 第7条：90日で削除・集計値のみ保存・不正防止の記録は2時間以内に削除', pol.includes('90日を過ぎたものから順次削除') && pol.includes('2時間以内に削除します'));
  ok('6 改定日を表示（今回の改定と前回の改定）', /改定日：\d{4}年\d{1,2}月\d{1,2}日（アクセス数の集計について追記）、2026年10月24日（歌詞の自動同期について追記）/.test(pol));
  ok('6 画面のエラーなし', errs.length === 0, errs);
  await ctx.close();

  // ---- 7. 機能スイッチ off：画面の表示は送らない・再生数は今までどおり
  ({ ctx, p, errs } = await open(false));
  await p.goto('http://aimuse.test/'); await p.waitForTimeout(1200);
  await p.locator('button[aria-label="案内を閉じる"]').click().catch(() => {});
  await p.locator('nav.nav button', { hasText: '検索' }).click(); await p.waitForTimeout(300);
  await p.locator('nav.nav button', { hasText: 'ホーム' }).click(); await p.waitForTimeout(300);
  await p.locator('.row', { hasText: 'おぼろ月' }).first().click();
  await p.waitForFunction(() => window.__listenMeter && window.__listenMeter.state().done, null, { timeout: 9000 }).catch(() => {}); await p.waitForTimeout(300);
  await p.locator('.mini button[aria-label="一時停止"]').click().catch(() => {}); await p.waitForTimeout(200);
  ok('7 機能スイッチ off：画面の表示は送らない', (await p.evaluate(() => window.__log.filter(l => l.op === 'rpc' && l.name === 'analytics_track').length)) === 0);
  ok('7 機能スイッチ off でも再生数は1回だけ数える', (await p.evaluate(() => window.__log.filter(l => l.op === 'rpc' && (l.name === 'count_play' || l.name === 'increment_plays')).length)) === 1);
  ok('7 画面のエラーなし', errs.length === 0, errs);
  await ctx.close(); await b.close();
  const bad = R.filter(r => !r[1]).length;
  console.log(`[${DEV}] 合計 ${R.length} 件 / 不合格 ${bad} 件`);
  process.exit(bad ? 1 : 0);
})().catch(e => { console.log('ERROR', e.message); process.exit(1); });
