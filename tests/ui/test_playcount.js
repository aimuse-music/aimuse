// 再生数：実際に音声が30秒（30秒未満の曲は長さの半分）流れたときだけ1回数える（iPhone / Android / ホーム画面アプリ）
// 一時停止・シーク・読み込み待ち・再生失敗・短時間のスキップは合計に入らない。1曲リピートは1周ごとに送り、1時間の上限はサーバー側
// 使い方：node test_playcount.js <index.html> <iphone|android> <出力フォルダ>
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const [INDEX, DEV] = process.argv.slice(2);
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? 'PASS' : 'FAIL'}] ${n}${i !== undefined ? '  → ' + JSON.stringify(i).slice(0, 220) : ''}`); };
const T1 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', T2 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2', T3 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3';
function wavBuf(sec) { const sr = 8000, n = Math.floor(sr * sec), b = Buffer.alloc(44 + n * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(sr, 24); b.writeUInt32LE(sr * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(Math.sin(i / sr * 2 * Math.PI * 440) * 800), 44 + i * 2);
  return b; }
const wav = sec => 'data:audio/wav;base64,' + wavBuf(sec).toString('base64');
const route = r => { const u = r.request().url();
  if (u.startsWith('http://aimuse.test/slow.wav')) return new Promise(res => setTimeout(() => res(r.fulfill({ contentType: 'audio/wav', body: wavBuf(10) })), 4000));   // 読み込みに4秒かかる音源
  if (u.startsWith('http://aimuse.test/') && !u.endsWith('.js')) return r.fulfill({ contentType: 'text/html', body: fs.readFileSync(INDEX) });
  if (u.endsWith('/config.js')) return r.fulfill({ contentType: 'text/javascript', body: 'window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k",features:{analytics:true}};' });
  if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
  if (u.includes('react-dom.production') || u.includes('htm.umd')) return r.fulfill({ contentType: 'text/javascript', body: '' });
  if (u.includes('supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
  return r.fulfill({ status: 404, body: '' }); };
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--autoplay-policy=no-user-gesture-required'] });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const errsAll = [];
  // audio：音源（data URL か URL）。standalone：ホーム画面に追加したアプリとして開く（iPhone の navigator.standalone・display-mode）
  const open = async (audio, standalone) => {
    const ctx = await b.newContext({ ...dev }); await ctx.addInitScript(([a, sa]) => { window.__testAudio = a;
      if (sa) { Object.defineProperty(navigator, 'standalone', { get: () => true }); const mm = window.matchMedia.bind(window);
        window.matchMedia = q => /display-mode:\s*standalone/.test(q) ? { matches: true, media: q, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} } : mm(q); } }, [audio, !!standalone]);
    const p = await ctx.newPage(); p.on('pageerror', e => errsAll.push(e.message)); await p.route('**/*', route);
    await p.goto('http://aimuse.test/'); await p.waitForTimeout(1300);
    await p.locator('button[aria-label="案内を閉じる"]').click().catch(() => {});
    return { ctx, p };
  };
  const helpers = p => ({
    w: ms => p.waitForTimeout(ms),
    play: async title => { await p.locator('.sec', { hasText: '人気ランキング' }).locator('.row', { hasText: title }).first().click(); await p.waitForTimeout(300); },
    counts: () => p.evaluate(() => { const c = {}; window.__log.filter(l => l.op === 'rpc' && (l.name === 'count_play' || l.name === 'increment_plays')).forEach(l => { c[l.args.tid] = (c[l.args.tid] || 0) + 1; }); return c; }),
    au: () => p.evaluate(() => { const a = document.querySelector('audio'); return { tid: a.dataset.tid, t: a.currentTime, d: a.duration, paused: a.paused, acc: window.__listenMeter && window.__listenMeter.state().acc }; }),
    rate: r => p.evaluate(r => { const a = document.querySelector('audio'); a.defaultPlaybackRate = r; a.playbackRate = r; }, r),
    until: async (f, ms = 30000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await p.evaluate(f)) return true; await p.waitForTimeout(80); } return false; },
    pause: () => p.locator('.mini button[aria-label="一時停止"]').click(),
    resume: () => p.locator('.mini button[aria-label="再生"]').click(),
  });

  // ---- 1. 40秒の曲（基準30秒）。待ち時間を減らすため4倍速で再生（数えるのは音声の再生位置の進み）
  let { ctx, p } = await open(wav(40)); let h = helpers(p);
  const titles = await p.locator('.sec', { hasText: '人気ランキング' }).locator('.row .t').allInnerTexts();
  const idOf = t => t === 'おぼろ月' ? T1 : t === 'ああ' ? T2 : T3;
  await h.rate(4); await h.play('おぼろ月'); await h.rate(4);
  await h.until(() => document.querySelector('audio').currentTime >= 10);
  await h.pause(); await h.w(1500);
  let c = await h.counts(), a = await h.au();
  ok('1 再生ボタンを押しただけ・10秒の再生では数えない', !c[T1] && a.paused, { c, a });
  await h.w(2000);
  ok('1 一時停止の間は再生時間に入らない', Math.abs((await h.au()).acc - a.acc) < 0.01, [(await h.au()).acc, a.acc]);
  await h.resume(); await h.rate(4);
  await h.until(() => window.__listenMeter.state().acc >= 25);
  ok('1 合計25秒（30秒未満）ではまだ数えない', !(await h.counts())[T1]);
  await h.until(() => window.__listenMeter.state().done); await h.w(300);
  a = await h.au(); c = await h.counts();
  ok('1 実際に30秒再生したところで1回だけ数える（count_play）', c[T1] === 1 && a.acc >= 29.9 && a.acc < 32, { c, acc: a.acc, t: a.t });
  await h.until(() => document.querySelector('audio').dataset.tid !== 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', 20000);
  ok('1 最後まで聴いても同じ再生では2回目を数えない', (await h.counts())[T1] === 1);
  await h.pause(); await h.w(300);

  // ---- 2. シーク：飛ばした分は入れない
  await h.play('ああ'); await h.rate(4);
  await h.until(() => document.querySelector('audio').currentTime >= 3);
  await p.evaluate(() => { document.querySelector('audio').currentTime = 37.5; });
  await h.until(() => document.querySelector('audio').dataset.tid !== 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2' || document.querySelector('audio').ended, 15000);
  c = await h.counts();
  ok('2 シークで終わり近くまで飛ばしても、飛ばした分は数えない（再生時間 約5秒）', !c[T2], c);
  await h.pause(); await h.w(300);

  // ---- 3. 短時間のスキップ：5秒で次の曲へ
  await h.play('ひまわり'); await h.rate(1);
  await h.until(() => document.querySelector('audio').currentTime >= 5, 12000);
  const skipBtn = p.locator('.mini button[aria-label="次の曲"]');
  if (await skipBtn.count()) await skipBtn.click(); else { await p.locator('.mini-in').click(); await h.w(300); await p.locator('.player button[aria-label="次の曲"]').click(); await p.locator('.player button[aria-label="閉じる"]').click(); }
  await h.w(1500); c = await h.counts();
  ok('3 5秒でスキップした曲は数えない', !c[T3], c);
  await h.pause().catch(() => {}); await h.w(300);

  // ---- 4. 1曲リピート：1周ごとに30秒を満たせば送る（同じ人×同じ曲は1時間に1回、の上限はサーバー側）
  await p.locator('.mini-in').click(); await h.w(300);
  for (let k = 0; k < 4; k++) { const l = await p.locator('.player button[aria-label^="リピート"]').getAttribute('aria-label'); if (l === 'リピート：1曲') break; await p.locator('.player button[aria-label^="リピート"]').click(); await h.w(150); }
  await p.locator('.player button[aria-label="閉じる"]').click(); await h.w(200);
  const before = (await h.counts())[T1] || 0;
  await h.play('おぼろ月'); await h.rate(4);
  await h.until(() => (window.__log.filter(l => l.op === 'rpc' && l.name === 'count_play' && l.args.tid === 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1').length) >= 3, 40000);
  c = await h.counts(); a = await h.au();
  ok('4 1曲リピート：2周で2回送る（1周の途中では送らない）', c[T1] - before === 2 && a.tid === T1, { sent: c[T1] - before });
  ok('4 送り先は count_play（サーバー側の1時間に1回の上限を通る）', (await p.evaluate(() => window.__log.filter(l => l.op === 'rpc' && l.name === 'increment_plays').length)) === 0);
  await ctx.close();

  // ---- 5. 30秒未満の曲（10秒）：半分（5秒）で数える。ホーム画面アプリとして開く
  ({ ctx, p } = await open(wav(10), true)); h = helpers(p);
  ok('5 ホーム画面アプリとして開いている（standalone）', await p.evaluate(() => navigator.standalone === true && matchMedia('(display-mode: standalone)').matches));
  await h.play('おぼろ月');
  await h.until(() => document.querySelector('audio').currentTime >= 3.5, 8000);
  ok('5 10秒の曲：3.5秒ではまだ数えない', !(await h.counts())[T1]);
  await h.until(() => window.__listenMeter.state().done, 8000); await h.w(300);
  a = await h.au(); c = await h.counts();
  ok('5 10秒の曲：5秒（長さの50％）再生したところで1回数える', c[T1] === 1 && a.acc >= 4.9 && a.acc < 6, { c, acc: a.acc });
  await ctx.close();

  // ---- 6. 再生の失敗：音が出なければ数えない（以前はボタンを押しただけで数えていた）
  ({ ctx, p } = await open('data:audio/wav;base64,AAAAAAAA')); h = helpers(p);
  await h.play('おぼろ月'); await h.w(3500);
  c = await h.counts();
  ok('6 音源を再生できないときは数えない', !c[T1] && !c[T2] && !c[T3], c);
  await ctx.close();

  // ---- 7. 読み込み待ち：音源の読み込みに4秒かかっても、その間は数えない
  ({ ctx, p } = await open('http://aimuse.test/slow.wav')); h = helpers(p);
  const t0 = Date.now(); await h.play('おぼろ月');
  await h.until(() => window.__listenMeter.state().done, 15000); await h.w(300);
  const el = (Date.now() - t0) / 1000; c = await h.counts();
  ok('7 読み込み待ちの4秒は入れず、音が出てから5秒で数える（合計9秒以上かかる）', c[T1] === 1 && el >= 8.5, { c, sec: el.toFixed(1) });
  await ctx.close();

  ok('8 画面のエラーなし', errsAll.length === 0, errsAll);
  await b.close();
  const bad = R.filter(r => !r[1]).length;
  console.log(`[${DEV}] 合計 ${R.length} 件 / 不合格 ${bad} 件`);
  process.exit(bad ? 1 : 0);
})().catch(e => { console.log('ERROR', e.message); process.exit(1); });
