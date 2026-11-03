// 画面オフ（バックグラウンド）での連続再生：期限付きURLの期限切れ・読み込みの途中停止（ストール）・途中の通信エラー・再生できない曲・ロック画面の操作（Media Session）
// 使い方：node test_bgplay.js <index.html> <iphone|android> [old]   （old を付けると「直す前」の結果として失敗を数えない）
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const [INDEX, DEV, MODE] = process.argv.slice(2);
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? 'PASS' : 'FAIL'}] ${n}${i !== undefined ? '  → ' + JSON.stringify(i).slice(0, 240) : ''}`); };
function wavBuf(sec) { const sr = 8000, n = Math.floor(sr * sec), b = Buffer.alloc(44 + n * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(sr, 24); b.writeUInt32LE(sr * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(Math.sin(i / sr * 2 * Math.PI * 440) * 800), 44 + i * 2);
  return b; }
// 音源の配信（期限・途中停止・途中エラーを再現）。srv.plan[path] = {stallV|errV: 発行番号, bad: true}
const srv = { wav: wavBuf(4), plan: {}, hits: [], offset: 0 };   // offset：ページの時計を進めた分（長時間の再生を短く再現）
const media = async r => {
  const u = new URL(r.request().url()); const p = decodeURIComponent(u.pathname.replace('/media/', '')); const v = +u.searchParams.get('v'); const exp = +u.searchParams.get('exp');
  const range = r.request().headers()['range'] || ''; const from = +((/bytes=(\d+)-/.exec(range) || [])[1] || 0);
  const plan = srv.plan[p] || {}; const body = plan.wav || srv.wav; srv.hits.push({ p, v, from, expired: Date.now() + srv.offset > exp });
  if (plan.stallFirst && plan.stallV == null) plan.stallV = v;   // 最初に使われた発行番号のURLだけ途中で止める
  if (plan.errFirst && plan.errV == null) plan.errV = v;
  if (Date.now() + srv.offset > exp) return r.fulfill({ status: 400, contentType: 'application/json', body: '{"error":"InvalidJWT","message":"exp claim timestamp check failed"}' });
  if (plan.bad) return r.fulfill({ status: 200, contentType: 'audio/wav', body: Buffer.from('not audio at all '.repeat(200)) });
  const cut = plan.cut || 40000;
  if (from >= cut && plan.stallV === v) return new Promise(() => {});                    // 続きの読み込みが返ってこない（通信の途絶）
  if (from >= cut && plan.errV === v) return r.fulfill({ status: 400, body: 'expired' });  // 続きの読み込みが失敗（期限切れなど）
  if ((plan.stallV === v || plan.errV === v) && from < cut) {                            // 最初は途中までだけ返す
    const end = cut - 1; return r.fulfill({ status: 206, contentType: 'audio/wav', headers: { 'Content-Range': `bytes ${from}-${end}/${body.length}`, 'Accept-Ranges': 'bytes' }, body: body.subarray(from, cut) });
  }
  return r.fulfill({ status: 206, contentType: 'audio/wav', headers: { 'Content-Range': `bytes ${from}-${body.length - 1}/${body.length}`, 'Accept-Ranges': 'bytes' }, body: body.subarray(from) });
};
const route = r => { const u = r.request().url();
  if (u.startsWith('http://aimuse.test/media/')) return media(r);
  if (u.startsWith('http://aimuse.test/') && !u.endsWith('.js')) return r.fulfill({ contentType: 'text/html', body: fs.readFileSync(INDEX) });
  if (u.endsWith('/config.js')) return r.fulfill({ contentType: 'text/javascript', body: 'window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k"};' });
  if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
  if (u.includes('react-dom.production') || u.includes('htm.umd')) return r.fulfill({ contentType: 'text/javascript', body: '' });
  if (u.includes('supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
  return r.fulfill({ status: 404, body: '' }); };
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--autoplay-policy=no-user-gesture-required'] });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const errs = [];
  const open = async ttl => {
    const ctx = await b.newContext({ ...dev });
    await ctx.addInitScript(t => {
      window.__mediaBase = 'http://aimuse.test/media'; window.__signTtlMs = t;
      // ページの時計を進める（期限付きURLの「1時間」を短い時間で再現。音声の再生時間には影響しない）
      const _now = Date.now.bind(Date); let off = 0; window.__setOffset = v => { off = v; }; Date.now = () => _now() + off;
      // 画面オフ（ページが見えていない状態）を再現
      let hid = false; window.__setHidden = h => { hid = h; document.dispatchEvent(new Event('visibilitychange')); };
      Object.defineProperty(document, 'visibilityState', { get: () => hid ? 'hidden' : 'visible' });
      Object.defineProperty(document, 'hidden', { get: () => hid });
      // ロック画面の操作（Media Session）を記録して、テストから押せるようにする
      window.__ms = { handlers: {} };
      if (navigator.mediaSession) { const orig = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
        navigator.mediaSession.setActionHandler = (a, f) => { window.__ms.handlers[a] = f; try { orig(a, f); } catch (e) {} }; }
    }, ttl);
    const p = await ctx.newPage(); p.on('pageerror', e => errs.push(e.message)); await p.route('**/*', route);
    await p.goto('http://aimuse.test/'); await p.waitForTimeout(1300);
    await p.locator('button[aria-label="案内を閉じる"]').click().catch(() => {});
    return { ctx, p };
  };
  const H = p => ({
    w: ms => p.waitForTimeout(ms),
    st: () => p.evaluate(() => { const a = document.querySelector('audio'); const t = window.__db.tracks.find(x => x.id === a.dataset.tid);
      return { title: t && t.title, t: +a.currentTime.toFixed(2), paused: a.paused, ended: a.ended, err: a.error && a.error.code }; }),
    play: async title => { await p.locator('.sec', { hasText: '人気ランキング' }).locator('.row', { hasText: title }).first().click(); await p.waitForTimeout(200); },
    // 再生された曲の順番と、曲ごとの最大の再生位置（max）を記録
    watch: async ms => { const seq = []; const end = Date.now() + ms; let last = null; seq.max = {};
      while (Date.now() < end) { const s = await p.evaluate(() => { const a = document.querySelector('audio'); const t = window.__db.tracks.find(x => x.id === a.dataset.tid); return { title: t && t.title, t: a.currentTime, paused: a.paused, ended: a.ended }; });
        if (s.title && s.title !== last && s.t > 0.3) { seq.push(s.title); last = s.title; } if (s.title) seq.max[s.title] = Math.max(seq.max[s.title] || 0, s.t); await p.waitForTimeout(100); }
      return seq; },
    pathOf: title => p.evaluate(t => window.__db.tracks.find(x => x.title === t).audio_path, title),
  });

  // ---- 1. 画面オフのまま長時間：ページを開いたときに発行した期限付きURL（1時間）が途中で切れても、続けて再生できる
  //   1曲目の途中で45分、2曲目の途中でさらに20分たったことにする（合計65分：最初のURLはすべて期限切れ）
  const jump = async (p, min) => { srv.offset += min * 60000; await p.evaluate(o => window.__setOffset(o), srv.offset); };
  let { ctx, p } = await open(3600000); let h = H(p);
  const titles = await p.locator('.sec', { hasText: '人気ランキング' }).locator('.row .t').allInnerTexts();
  await h.play(titles[0]); await p.evaluate(() => window.__setHidden(true));
  await h.w(1500); await jump(p, 45);
  await p.waitForFunction(t => { const a = document.querySelector('audio'); return window.__db.tracks.find(x => x.id === a.dataset.tid).title === t && a.currentTime > 1; }, titles[1], { timeout: 10000 }).catch(() => {});
  await jump(p, 20);
  let seq = await h.watch(12000); let s = await h.st();
  const signs = await p.evaluate(() => window.__log.filter(l => l.op === 'sign').length);
  ok('1 画面オフで3曲目まで順番に最後まで再生（ページを開いて65分後：最初のURLは期限切れでも止まらない）', seq.join() === titles.slice(1, 3).join() && seq.max[titles[2]] > 3.7 && s.paused, { seq, max: seq.max, s });
  ok('1 画面オフの間も、次の曲の期限付きURLを再生前に取り直している', signs >= 2, signs);
  srv.offset = 0;
  ok('1 期限切れのURLで音源を読み込もうとしていない', srv.hits.length >= 3 && !srv.hits.some(x => x.expired), srv.hits.filter(x => x.expired).length);
  await ctx.close();

  // ---- 2. 曲の途中で読み込みが止まる（通信の途絶・電波の切り替えなど）：自動で読み込み直して続きから再生
  ({ ctx, p } = await open(3600000)); h = H(p);
  srv.wav = wavBuf(10); const p0 = await h.pathOf(titles[0]); srv.plan[p0] = { stallFirst: true, cut: 120000 };
  await h.play(titles[0]); await p.evaluate(() => window.__setHidden(true));
  // 再生位置が2秒進まなくなるまで待つ（読み込みが止まった状態）
  let atStall = null; { let prev = -1, same = 0; for (let k = 0; k < 60 && same < 8; k++) { const x = await h.st(); if (x.t > 0 && x.t === prev) same++; else same = 0; prev = x.t; atStall = x; await h.w(250); } }
  const t0 = Date.now(); let resumed = false;
  while (Date.now() - t0 < 30000) { const x = await h.st(); if (x.title === titles[0] && x.t > atStall.t + 1.5) { resumed = true; break; } await h.w(250); }
  s = await h.st();
  ok('2 曲の途中で読み込みが止まっても、自動で読み込み直して続きから再生する', resumed && s.title === titles[0], { atStall, s, sec: ((Date.now() - t0) / 1000).toFixed(1) });
  const reloads = srv.hits.filter(x => x.p === p0 && x.from > 0 && x.v !== srv.plan[p0].stallV);
  ok('2 読み込み直しは新しく取り直した期限付きURLで行う', reloads.length >= 1 || srv.hits.some(x => x.p === p0 && x.v !== srv.plan[p0].stallV), srv.hits.filter(x => x.p === p0).map(x => [x.v, x.from]));
  await ctx.close(); srv.hits = [];

  // ---- 3. 曲の途中で続きの読み込みがエラー（期限切れ・一時的な失敗）：自動で取り直して続きから
  ({ ctx, p } = await open(3600000)); h = H(p);
  const p1 = await h.pathOf(titles[1]); srv.plan[p1] = { errFirst: true, cut: 40000 };
  await h.play(titles[1]); await p.evaluate(() => window.__setHidden(true));
  const t1 = Date.now(); resumed = false; let errSeen = false, maxT = 0, back = false;
  while (Date.now() - t1 < 25000) { const x = await h.st(); if (x.err) errSeen = true;
    if (x.title === titles[1]) { if (x.t > 0 && x.t < maxT - 0.6) back = true; maxT = Math.max(maxT, x.t); if (x.t > 4) { resumed = true; break; } } await h.w(100); }
  ok('3 途中で読み込みエラーになっても、取り直して同じ曲の続きを再生する', resumed, { s: await h.st(), errSeen });
  const rl = srv.hits.filter(x => x.p === p1 && x.v !== srv.plan[p1].errV);
  ok('3 読み込み直しは新しいURLで、止まった位置から続ける（最初に戻らない）', rl.length >= 1 && !back, { back, hits: srv.hits.filter(x => x.p === p1).map(x => [x.v, x.from]) });
  await ctx.close(); srv.hits = []; srv.plan = {}; srv.wav = wavBuf(4);

  // ---- 4. どうしても再生できない曲：止まらずに次の曲へ進む
  ({ ctx, p } = await open(3600000)); h = H(p);
  const p2 = await h.pathOf(titles[1]); srv.plan[p2] = { bad: true };
  await h.play(titles[0]); await p.evaluate(() => window.__setHidden(true));
  seq = await h.watch(22000); s = await h.st();
  ok('4 再生できない曲があっても止まらず、次の曲へ進んで最後まで再生する', seq.join() === [titles[0], titles[2]].join() && seq.max[titles[0]] > 3.7 && seq.max[titles[2]] > 3.7, { seq, max: seq.max, s });
  await ctx.close(); srv.plan = {};

  // ---- 5. ロック画面・通知の操作（Media Session）
  ({ ctx, p } = await open(3600000)); h = H(p); srv.wav = wavBuf(8);
  await h.play(titles[0]); await h.w(800);
  const md = await p.evaluate(() => navigator.mediaSession && navigator.mediaSession.metadata ? { title: navigator.mediaSession.metadata.title, artist: navigator.mediaSession.metadata.artist, art: navigator.mediaSession.metadata.artwork.length } : null);
  const hs = await p.evaluate(() => Object.keys(window.__ms.handlers).sort().join());
  ok('5 ロック画面に曲名・アーティスト名・画像を表示する情報を設定', md && md.title === titles[0] && !!md.artist && md.art >= 1, md);
  ok('5 ロック画面の操作：再生・一時停止・前の曲・次の曲・シーク', ['nexttrack', 'pause', 'play', 'previoustrack', 'seekto'].every(k => hs.split(',').includes(k)), hs);
  await p.evaluate(() => window.__ms.handlers.pause && window.__ms.handlers.pause()); await h.w(400);
  ok('5 ロック画面の「一時停止」で止まり、状態も「一時停止」になる', (await h.st()).paused && await p.evaluate(() => navigator.mediaSession.playbackState) === 'paused');
  await p.evaluate(() => window.__ms.handlers.play && window.__ms.handlers.play()); await h.w(400);
  ok('5 ロック画面の「再生」で再開する', !(await h.st()).paused && await p.evaluate(() => navigator.mediaSession.playbackState) === 'playing');
  await p.evaluate(() => window.__ms.handlers.nexttrack && window.__ms.handlers.nexttrack()); await h.w(800);
  s = await h.st();
  ok('5 ロック画面の「次の曲」で次の曲へ（画面を点けなくても曲を送れる）', s.title === titles[1] && !s.paused && await p.evaluate(() => navigator.mediaSession.metadata.title) === titles[1], s);
  await p.evaluate(() => window.__ms.handlers.seekto && window.__ms.handlers.seekto({ seekTime: 5 })); await h.w(300);
  ok('5 ロック画面のシークで再生位置を移動', Math.abs((await h.st()).t - 5) < 1, await h.st());
  await ctx.close();

  ok('6 画面のエラーなし', errs.length === 0, errs);
  await b.close();
  const bad = R.filter(r => !r[1]).length;
  console.log(`[${DEV}${MODE === 'old' ? ' 修正前' : ''}] 合計 ${R.length} 件 / 不合格 ${bad} 件`);
  process.exit(bad && MODE !== 'old' ? 1 : 0);
})().catch(e => { console.log('ERROR', e.message); process.exit(1); });
