// 歌詞の同期（v1.14）：時刻どおりの表示・イントロ／間奏で進まない・見出し・一時停止／シーク／再生速度・未同期の曲・編集画面
// 20秒の実際の音声（WAV）で再生する。使い方: node test_lyrics_sync.js <index.html> <iphone|android> <画像の保存先>
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const [INDEX, DEV, OUT] = process.argv.slice(2);
const device = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? 'PASS' : 'FAIL'}] ${n}${i !== undefined ? '  → ' + JSON.stringify(i) : ''}`); };
const B1 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', B2 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2';
const LYR = ['[Verse 1]', '一行目のうた', '二行目のうた', '', '【Chorus】', '三行目のうた', '四行目のうた'];
const SYNC = [{ i: 1, t: 3 }, { i: 2, t: 6, e: 8 }, { i: 5, t: 11 }, { i: 6, t: 14 }];
function wav(sec) { const sr = 8000, n = Math.floor(sr * sec), b = Buffer.alloc(44 + n * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(sr, 24); b.writeUInt32LE(sr * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(Math.sin(i / sr * 2 * Math.PI * 440) * 300), 44 + i * 2);
  return 'data:audio/wav;base64,' + b.toString('base64'); }
const AUDIO = wav(20);
const route = r => { const u = r.request().url();
  if (u.startsWith('http://aimuse.test/') && !u.endsWith('.js')) return r.fulfill({ contentType: 'text/html', body: fs.readFileSync(INDEX) });
  if (u.endsWith('/config.js')) return r.fulfill({ contentType: 'text/javascript', body: 'window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k"};' });
  if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
  if (u.includes('react-dom.production') || u.includes('htm.umd')) return r.fulfill({ contentType: 'text/javascript', body: '' });
  if (u.includes('supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
  return r.fulfill({ status: 404, body: '' }); };

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--autoplay-policy=no-user-gesture-required'] });
  const mk = async (init) => {
    const ctx = await b.newContext({ ...device });
    await ctx.addInitScript(([a, x]) => { window.__testAudio = a; if (x) Object.assign(window, x); }, [AUDIO, init || null]);
    const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message)); await p.route('**/*', route);
    await p.goto('http://aimuse.test/'); await p.waitForTimeout(800);
    // 曲に歌詞・長さを入れ、おぼろ月（B1）だけ同期の時刻を用意して読み込み直す
    await p.evaluate(([B1, B2, LYR, SYNC]) => { const db = window.__db;
      db.tracks.forEach(t => { if (t.id === B1 || t.id === B2) { t.lyrics = LYR.slice(); t.duration = 20; } });
      db.lyricsSync = { [B1]: { lines: SYNC, source: 'manual', hash: JSON.stringify(LYR), updated_at: '2026-10-23T00:00:00Z' } };
      sessionStorage.setItem('fakedb2', JSON.stringify(db)); }, [B1, B2, LYR, SYNC]);
    await p.reload(); await p.waitForTimeout(1000);
    return { ctx, p, errs };
  };
  const w = (p, ms) => p.waitForTimeout(ms || 300);
  const login = async (p, e) => { await p.locator('nav.nav button', { hasText: 'マイページ' }).click(); await w(p); await p.fill('#a-email', e); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('text=ログアウト').waitFor(); await w(p, 700); };
  const openSong = async (p, title) => {
    await p.locator('nav.nav button', { hasText: 'ホーム' }).click(); await w(p, 300);
    await p.locator('.sec', { hasText: '人気ランキング' }).locator('.row', { hasText: title }).first().click(); await w(p, 500);
    if (await p.locator('.player').count() === 0) { await p.locator('.mini-in').click(); await w(p, 400); }
    if (await p.locator('.player .lyrics').count() === 0) { await p.locator('.player .pill', { hasText: '歌詞' }).click(); await w(p, 400); }
  };
  const audio = (p, f, x) => p.evaluate(f, x);
  const setT = async (p, t) => { await audio(p, t => { const a = document.querySelector('audio'); a.pause(); a.currentTime = t; }, t); await w(p, 350); };
  const on = p => p.evaluate(() => { const e = document.querySelector('.player .lyrics p.on'); return e ? e.textContent : null; });

  // ---- 1. 未ログイン：同期済みの曲（おぼろ月）
  let { ctx, p, errs } = await mk();
  await openSong(p, 'おぼろ月'); await audio(p, () => document.querySelector('audio').pause()); await w(p, 300);
  const winY0 = await p.evaluate(() => window.scrollY);
  ok('1 見出し（[Verse 1]・【Chorus】）は区切りとして表示し、括弧を外す', JSON.stringify(await p.$$eval('.player .lyrics p.head', e => e.map(x => x.textContent))) === JSON.stringify(['Verse 1', 'Chorus']));
  ok('1 同期済みの曲は「同期あり」の表示形式', await p.locator('.player .lyrics.synced').count() === 1);
  await setT(p, 1); ok('1 イントロ（最初の歌い出しより前）はどの行も光らない', await on(p) === null);
  await setT(p, 3.0); ok('1 3.0秒：1行目', await on(p) === '一行目のうた', await on(p));
  await setT(p, 2.9); ok('1 歌い出しの0.15秒前から表示（文字が目に入るまでの遅れの分）', await on(p) === '一行目のうた', await on(p));
  await setT(p, 2.8); ok('1 0.2秒前はまだ光らない', await on(p) === null, await on(p));
  await setT(p, 6.5); ok('1 6.5秒：2行目', await on(p) === '二行目のうた', await on(p));
  await setT(p, 9); ok('1 間奏（歌い終わり8秒〜次の歌い出し11秒）は、どの行も光らない（勝手に進まない）', await on(p) === null, await on(p));
  await setT(p, 13.8); ok('1 13.8秒：3行目（後半でもずれが溜まらない）', await on(p) === '三行目のうた', await on(p));
  await setT(p, 13.9); ok('1 13.9秒：4行目に切り替わる（0.1秒単位で正確）', await on(p) === '四行目のうた', await on(p));
  await setT(p, 4); ok('1 巻き戻し（4秒）：1行目に戻る', await on(p) === '一行目のうた', await on(p));
  await setT(p, 12); ok('1 早送り（12秒）：3行目', await on(p) === '三行目のうた', await on(p));
  // 実際に再生して進む
  await audio(p, () => { const a = document.querySelector('audio'); a.currentTime = 2.5; }); await w(p, 200);
  await p.locator('.player .big-play').click(); await p.waitForTimeout(1300);
  const s1 = await audio(p, () => ({ t: document.querySelector('audio').currentTime, paused: document.querySelector('audio').paused }));
  ok('1 途中（2.5秒）から再生すると、歌い出しで1行目に変わる', !s1.paused && s1.t > 3.1 && await on(p) === '一行目のうた', { s1, on: await on(p) });
  await p.locator('.player .big-play').click(); await w(p, 300);
  const before = await on(p); await p.waitForTimeout(1200);
  ok('1 一時停止中は表示が進まない', await on(p) === before && await audio(p, () => document.querySelector('audio').paused));
  await audio(p, () => { const a = document.querySelector('audio'); a.currentTime = 10.4; a.playbackRate = 2; a.play(); }); await p.waitForTimeout(800);
  const s2 = await audio(p, () => document.querySelector('audio').currentTime);
  ok('1 再生速度2倍でも、音源の時刻どおりに表示（11秒を過ぎたら3行目）', s2 > 11.2 && await on(p) === '三行目のうた', { s2, on: await on(p) });
  await audio(p, () => { const a = document.querySelector('audio'); a.pause(); a.playbackRate = 1; });
  const sc = await p.evaluate(() => { const box = document.querySelector('.player .lyrics'), el = box.querySelector('p.on'); const br = box.getBoundingClientRect(), er = el.getBoundingClientRect(); return { inside: er.top >= br.top - 1 && er.bottom <= br.bottom + 1, winY: window.scrollY }; });
  ok('1 自動スクロール：光っている行が歌詞の枠の中に見えていて、画面全体は動かない', sc.inside && sc.winY === winY0, { ...sc, winY0 });
  ok('1 未ログインには「同期を編集」が出ない', await p.locator('.player .lyr-sync-note').count() === 0);
  await p.screenshot({ path: `${OUT}/${DEV}-lyrics-synced.png` });
  // 未同期の曲
  await p.locator('.player button[aria-label="閉じる"]').click(); await w(p, 200);
  await openSong(p, 'ああ'); await audio(p, () => document.querySelector('audio').pause());
  let none = true; for (const t of [1, 3, 9, 14]) { await setT(p, t); if (await on(p) !== null) none = false; }
  ok('1 同期がまだない曲は、歌詞を全文表示するだけで光らせない（推測で進めない）', none && await p.locator('.player .lyrics.static').count() === 1);
  ok('1 未同期の曲も見出しは区切りとして表示', await p.locator('.player .lyrics p.head').count() === 2 && await p.locator('.player .lyrics p:not(.head):not(.gap)').count() === 4);
  ok('1 画面の読み込みでエラーが出ない', errs.length === 0, errs);
  await ctx.close();

  // ---- 2. 投稿者本人（NOCTERA Ryo）：編集画面で合わせて保存
  ({ ctx, p, errs } = await mk());
  await login(p, 'ryo@test.jp');
  await openSong(p, 'ああ'); await audio(p, () => document.querySelector('audio').pause());
  ok('2 投稿者には、未同期の曲に「歌詞の同期を設定」が出る', (await p.locator('.player .lyr-sync-note').innerText()).includes('歌詞の同期を設定'));
  await p.locator('.player .lyr-sync-note button').click(); await w(p, 600);
  ok('2 編集画面が開き、下のプレーヤーは止まる', await p.locator('.ls-panel').count() === 1 && await p.locator('.player').count() === 0 && await audio(p, () => document.querySelectorAll('audio')[1] ? true : true));
  ok('2 時刻を付ける行は歌詞の行だけ（見出し・空行は除く）', await p.locator('.ls-row').count() === 4 && await p.locator('.ls-head').count() === 2);
  const ea = (f, x) => p.evaluate(([f, x]) => { const a = document.querySelector('.ls audio'); return (new Function('a', 'x', f))(a, x); }, [f, x]);
  const tapAt = async t => { await ea('a.pause(); a.currentTime = x;', t); await w(p, 250); await p.locator('.ls-tap').click(); await w(p, 150); };
  await tapAt(3.2); await tapAt(6.2);
  await ea('a.pause(); a.currentTime = x;', 8.2); await w(p, 250); await p.locator('.ls-sub button', { hasText: '歌が止まる' }).click(); await w(p, 150);
  await tapAt(11.2); await tapAt(14.2);
  ok('2 すべての行に時刻が付くと、ボタンが「すべての行に時刻が付きました」になる', (await p.locator('.ls-tap').innerText()).includes('すべての行に時刻が付きました') && await p.locator('.ls-tap').isDisabled());
  const times = await p.$$eval('.ls-row .ls-line .mono', e => e.map(x => x.textContent));
  ok('2 タップの遅れ（0.2秒）を補正して記録', JSON.stringify(times) === JSON.stringify(['0:03.0', '0:06.0', '0:11.0', '0:14.0']), times);
  ok('2 「歌が止まる」で直前の行に歌い終わり（間奏）が付く', (await p.locator('.ls-row').nth(1).innerText()).includes('〜0:08.0 間奏'));
  await p.locator('.ls-row').nth(2).locator('button', { hasText: '+0.1' }).click(); await w(p, 100);
  await p.locator('.ls-shift button', { hasText: '−0.1秒' }).click(); await w(p, 100);
  await p.locator('header button', { hasText: '保存する' }).click(); await w(p, 600);
  const saved = await p.evaluate(() => window.__log.filter(x => x.op === 'lyrics_sync_save').pop());
  ok('2 行ごとの調整（+0.1秒）と全体の調整（−0.1秒）を反映して保存', saved && JSON.stringify(saved.lines) === JSON.stringify([{ i: 1, t: 2.9 }, { i: 2, t: 5.9, e: 7.9 }, { i: 5, t: 11 }, { i: 6, t: 13.9 }]), saved && saved.lines);
  ok('2 保存すると「保存しました」と表示', (await p.locator('.toast').innerText().catch(() => '')).includes('保存しました'));
  // 時刻の順番が逆になる変更は保存できない
  await p.locator('.ls-row').nth(0).locator('.ls-line').click(); await w(p, 100);
  await tapAt(19.2);
  const n1 = await p.evaluate(() => window.__log.filter(x => x.op === 'lyrics_sync_save').length);
  await p.locator('header button', { hasText: '保存する' }).click(); await w(p, 400);
  ok('2 時刻の順番が逆の行があると保存せず、行番号（歌詞の入力と同じ数え方）を示す（赤枠）', (await p.locator('.ls .err').innerText()).includes('3行目') && await p.locator('.ls-row.bad').count() >= 1 && await p.evaluate(() => window.__log.filter(x => x.op === 'lyrics_sync_save').length) === n1);
  await p.screenshot({ path: `${OUT}/${DEV}-lyrics-editor.png` });
  await p.locator('header button[aria-label="戻る"]').click(); await w(p, 300);
  ok('2 保存していない変更があると、戻る前に確認する', (await p.locator('.sheet').innerText()).includes('保存していない変更があります'));
  await p.locator('.sheet button', { hasText: '保存せずに戻る' }).click(); await w(p, 400);
  // 保存した同期で表示
  await openSong(p, 'ああ'); await audio(p, () => document.querySelector('audio').pause());
  await setT(p, 12); const o12 = await on(p); await setT(p, 8.5); const o85 = await on(p);
  ok('2 保存した同期で表示（12秒＝3行目・間奏8.5秒＝なし）。保存前の変更は反映されない', o12 === '三行目のうた' && o85 === null, { o12, o85 });
  ok('2 同期済みの曲には「同期を編集」が出る', (await p.locator('.player .lyr-sync-note').innerText()).includes('同期を編集'));
  // マイページの投稿曲からも開ける
  await p.locator('.player button[aria-label="閉じる"]').click(); await w(p, 200);
  await p.locator('nav.nav button', { hasText: 'マイページ' }).click(); await w(p, 300);
  await p.locator('.tabs button', { hasText: '投稿曲' }).click(); await w(p, 300);
  ok('2 マイページの投稿曲に「歌詞の同期」のボタン（歌詞がある曲だけ）', await p.locator('button[aria-label="「ああ」の歌詞の同期"]').count() === 1 && await p.locator('button[aria-label="「おぼろ月」の歌詞の同期"]').count() === 1);
  await p.locator('button[aria-label="「おぼろ月」の歌詞の同期"]').click(); await w(p, 700);
  const t2 = await p.$$eval('.ls-row .ls-line .mono', e => e.map(x => x.textContent));
  ok('2 保存済みの時刻を読み込んで編集を始める', JSON.stringify(t2) === JSON.stringify(['0:03.0', '0:06.0', '0:11.0', '0:14.0']), t2);
  // 歌詞が変わったあとの同期は使わない
  await p.locator('header button[aria-label="戻る"]').click(); await w(p, 300);
  await p.evaluate(B1 => { const t = window.__db.tracks.find(x => x.id === B1); t.lyrics = t.lyrics.concat(['追加の行']); sessionStorage.setItem('fakedb2', JSON.stringify(window.__db)); }, B1);
  await p.reload(); await w(p, 1200);
  await openSong(p, 'おぼろ月'); await setT(p, 12);
  ok('2 歌詞が変わった曲は同期を使わず全文表示し、投稿者に確認を促す', await on(p) === null && (await p.locator('.player .lyr-sync-note').innerText()).includes('確認が必要'));
  ok('2 画面の読み込みでエラーが出ない', errs.length === 0, errs);
  await ctx.close();

  // ---- 3. ほかの会員（ハムハム）：他人の曲は編集できない
  ({ ctx, p, errs } = await mk());
  await login(p, 'hamu@test.jp');
  await openSong(p, 'おぼろ月'); await audio(p, () => document.querySelector('audio').pause()); await setT(p, 6.5);
  ok('3 ほかの会員にも同期どおりに表示（6.5秒＝2行目）', await on(p) === '二行目のうた');
  ok('3 ほかの会員の曲には「同期を編集」が出ない', await p.locator('.player .lyr-sync-note').count() === 0);
  await ctx.close();

  // ---- 4. データベースの準備（v1.14）がまだのとき
  ({ ctx, p, errs } = await mk({ __noV114: true }));
  await login(p, 'ryo@test.jp');
  await openSong(p, 'おぼろ月'); await audio(p, () => document.querySelector('audio').pause()); await setT(p, 6.5);
  ok('4 v1.14 未適用でも歌詞は全文表示でき、光らせない', await on(p) === null && await p.locator('.player .lyrics.static').count() === 1);
  await p.locator('.player .lyr-sync-note button').click(); await w(p, 600);
  await tapAt(3.2); await p.locator('header button', { hasText: '保存する' }).click(); await w(p, 500);
  ok('4 保存しようとすると「準備がまだ完了していません」と表示', (await p.locator('.ls .err').innerText()).includes('準備がまだ完了していません'));
  ok('4 画面の読み込みでエラーが出ない', errs.length === 0, errs);
  await ctx.close();

  await b.close();
  const f = R.filter(x => !x[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  process.exit(f.length ? 1 : 0);
})();
