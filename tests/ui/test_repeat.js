// 再生：リピート（オフ／全曲／1曲）・シャッフル・ミニプレーヤーと全画面の同期（1秒の実際の音声で再生を進める）
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
// 0.9秒の小さな音（WAV）
function wav(sec) { const sr = 8000, n = Math.floor(sr * sec), b = Buffer.alloc(44 + n * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(sr, 24); b.writeUInt32LE(sr * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(Math.sin(i / sr * 2 * Math.PI * 440) * 800), 44 + i * 2);
  return 'data:audio/wav;base64,' + b.toString('base64'); }
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--autoplay-policy=no-user-gesture-required'] });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const ctx = await b.newContext({ ...dev }); await ctx.addInitScript(a => { window.__testAudio = a; }, wav(0.9));
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message)); await p.route('**/*', route);
  const w = ms => p.waitForTimeout(ms || 400);
  const st = () => p.evaluate(() => { const a = document.querySelector('audio'); const mini = document.querySelector('.mini button[aria-label="一時停止"], .mini button[aria-label="再生"]');
    const big = document.querySelector('.player .big-play'); return { tid: a.dataset.tid, paused: a.paused, ended: a.ended, t: a.currentTime, loop: a.loop, mini: mini && mini.getAttribute('aria-label'), big: big && big.getAttribute('aria-label') }; });
  // 曲の終わりのちょうどその瞬間に調べると、次の再生が始まる直前（ended=true）に当たることがある。繰り返す設定の確認では、その瞬間を避けて調べ直す
  const stS = async () => { let s = await st(); for (let k = 0; k < 6 && s.ended; k++) { await w(120); s = await st(); } return s; };
  // 再生された曲の順番を記録（変わるたびに1件）
  await p.exposeFunction('__rec', () => {});
  const watch = async ms => { const seq = []; const end = Date.now() + ms; let last = null, restarts = 0, lastT = 0;
    while (Date.now() < end) { const s = await st(); if (s.tid !== last) { seq.push(s.tid); last = s.tid; lastT = 0; } else if (s.t + 0.2 < lastT) restarts++; lastT = s.t; await w(60); }
    return { seq, restarts }; };
  const short = id => id ? id.slice(-1) : '-';
  const openPlayer = async () => { if (await p.locator('.player').count() === 0) { await p.locator('.mini-in').click(); await w(300); } };
  const closePlayer = async () => { if (await p.locator('.player').count()) { await p.locator('.player button[aria-label="閉じる"]').click(); await w(200); } };
  const setRepeat = async m => { await openPlayer(); for (let k = 0; k < 4; k++) { const l = await p.locator('.player button[aria-label^="リピート"]').getAttribute('aria-label'); if (l === 'リピート：' + m) break; await p.locator('.player button[aria-label^="リピート"]').click(); await w(150); } };
  const setShuffle = async on => { await openPlayer(); const cur = await p.locator('.player button[aria-label="シャッフル"]').getAttribute('aria-pressed'); if ((cur === 'true') !== on) { await p.locator('.player button[aria-label="シャッフル"]').click(); await w(150); } };
  const playRank = async title => { await p.locator('.sec', { hasText: '人気ランキング' }).locator('.row', { hasText: title }).first().click(); await w(250); };

  await p.goto('http://aimuse.test/'); await w(1300);
  await p.locator('button[aria-label="案内を閉じる"]').click().catch(() => {}); await w(200);
  const titles = await p.locator('.sec', { hasText: '人気ランキング' }).locator('.row .t').allInnerTexts();

  // ---- 1. リピートオフ：順番に進み、最後の曲で止まる
  await playRank(titles[0]);
  let r = await watch(4200); let s = await st();
  ok('1 リピートオフ：3曲を順番に再生し、最後で止まる', r.seq.length === 3 && s.paused && s.mini === '再生', { seq: r.seq.map(short), s });
  ok('1 止まったとき、ミニプレーヤーの表示も「再生」に戻る（表示と実際が一致）', s.mini === '再生');

  // ---- 2. 全曲リピート：最後のあと先頭に戻って続ける
  await setRepeat('全曲'); await closePlayer(); await playRank(titles[0]); await w(100);
  if ((await st()).paused) { await p.locator('.mini button[aria-label="再生"]').click(); }
  r = await watch(4600); s = await stS();
  ok('2 全曲リピート：最後の曲のあと先頭に戻って再生が続く', r.seq.length >= 4 && r.seq[3] === r.seq[0] && !s.paused, { seq: r.seq.map(short) });

  // ---- 3. 1曲リピート：同じ曲を繰り返す（以前は曲の終わりで止まっていた）
  await setRepeat('1曲'); const one = (await st()).tid;
  r = await watch(3200); s = await stS();
  ok('3 1曲リピート：曲の終わりで止まらず、同じ曲を最初から繰り返す', r.seq.length === 1 && r.seq[0] === one && r.restarts >= 2 && !s.paused, { seq: r.seq.map(short), restarts: r.restarts, s });
  ok('3 1曲リピート中は、全画面の表示が「一時停止」（再生中）で、実際にも再生中', s.big === '一時停止' && !s.paused);
  // 端末によって loop が効かない場合の予備（曲の終わりの合図で最初から再生し直す）
  await p.evaluate(() => { const a = document.querySelector('audio'); a.loop = false; });
  r = await watch(2400); s = await stS();
  ok('3 予備の仕組み：繰り返しの設定が効かない端末でも、終わりの合図で同じ曲を再生し直す', r.seq.length === 1 && r.restarts >= 1 && !s.paused, { restarts: r.restarts, s });
  await p.locator('.player button[aria-label="次の曲"]').click(); await w(300);
  ok('3 1曲リピート中でも「次の曲」を押せば次へ進む', (await st()).tid !== one);

  // ---- 4. 1曲だけの一覧で全曲リピート
  await setRepeat('全曲'); await closePlayer();
  await p.locator('.sec', { hasText: '人気ランキング' }).locator('.row', { hasText: titles[0] }).first().click(); await w(200);
  await p.evaluate(() => { });
  await p.locator('nav.nav button', { hasText: '検索' }).click(); await w(300); await p.fill('#q', 'ひまわり'); await w(500);
  await p.locator('.sec .list .row', { hasText: 'ひまわり' }).first().click(); await w(300);
  r = await watch(2800); s = await stS();
  ok('4 曲が1つだけの一覧でも、全曲リピートで繰り返す', r.seq.length === 1 && r.restarts >= 2 && !s.paused, { seq: r.seq.map(short), restarts: r.restarts });
  await p.locator('nav.nav button', { hasText: 'ホーム' }).click(); await w(300);

  // ---- 5. シャッフル＋リピートオフ：全曲を1回ずつ、重複なしで再生して止まる
  await setRepeat('オフ'); await setShuffle(true); await closePlayer(); await playRank(titles[1]);
  if ((await st()).paused) await p.locator('.mini button[aria-label="再生"]').click();
  r = await watch(4200); s = await st();
  ok('5 シャッフル＋リピートオフ：3曲を1回ずつ（重複なし）再生して止まる', r.seq.length === 3 && new Set(r.seq).size === 3 && s.paused && s.mini === '再生', { seq: r.seq.map(short) });

  // ---- 6. シャッフル＋全曲リピート：一巡ごとに全曲、同じ曲が続かない
  await setRepeat('全曲'); await closePlayer(); await playRank(titles[2]);
  if ((await st()).paused) await p.locator('.mini button[aria-label="再生"]').click();
  r = await watch(6400);
  const firstRound = new Set(r.seq.slice(0, 3)).size === 3, noDup = r.seq.every((x, i) => i === 0 || x !== r.seq[i - 1]);
  ok('6 シャッフル＋全曲リピート：最初の一巡で全曲を再生し、その後も続く。同じ曲が2回続かない', r.seq.length >= 5 && firstRound && noDup, { seq: r.seq.map(short) });
  await setShuffle(false);

  // ---- 7. 画面の外からの一時停止・再生（ロック画面・イヤホンのボタンを再現）と、表示の同期
  await closePlayer(); if ((await st()).paused) await p.locator('.mini button[aria-label="再生"]').click(); await w(200);
  await p.evaluate(() => document.querySelector('audio').pause()); await w(300); s = await st();
  ok('7 外から一時停止されたら、ミニプレーヤーの表示も「再生」に変わる', s.paused && s.mini === '再生', s);
  await p.evaluate(() => document.querySelector('audio').play()); await w(300); s = await st();
  ok('7 外から再生されたら、表示も「一時停止」（再生中）に変わる', !s.paused && s.mini === '一時停止', s);
  await p.locator('.mini button[aria-label="一時停止"]').click(); await w(200); await openPlayer(); s = await st();
  ok('7 ミニで止めると、全画面プレーヤーも「再生」表示（同期）', s.paused && s.big === '再生', s);
  await p.locator('.player .big-play').click(); await w(300); await closePlayer(); s = await st();
  ok('7 全画面で再生すると、ミニも「一時停止」表示（同期）', !s.paused && s.mini === '一時停止', s);
  await p.screenshot({ path: `${OUT}/${DEV}-r-mini.png` });

  ok('エラーなし', errs.length === 0, errs);
  const f = R.filter(r => !r[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  await b.close();
})();
