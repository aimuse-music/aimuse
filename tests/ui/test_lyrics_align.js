// 歌詞の自動同期（AI・v1.15）の画面：提案は確認待ち（再生画面には出さない）・下書きとして読み込み・確認ポイントで聞き比べ・AI との差の表示・採用・
// 手動の同期を守る（提案は別に表示）・使わない・作り直しの依頼・マイページの印・管理画面（停止と再開・登録・一覧）・v1.15 未適用でも従来どおり
// 使い方: node test_lyrics_align.js <index.html> <iphone|android> <画像の保存先>
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const [INDEX, DEV, OUT] = process.argv.slice(2);
const device = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? 'PASS' : 'FAIL'}] ${n}${i !== undefined ? '  → ' + JSON.stringify(i) : ''}`); };
const B1 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', B3 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3';
const LYR = ['[Verse 1]', '一行目のうた', '二行目のうた', '', '【Chorus】', '三行目のうた', '四行目のうた'];
const MANUAL = [{ i: 1, t: 3 }, { i: 2, t: 6, e: 8 }, { i: 5, t: 11 }, { i: 6, t: 14 }];
const PROP = [{ i: 1, t: 3.1 }, { i: 2, t: 6, e: 8 }, { i: 5, t: 11.2 }, { i: 6, t: 14 }];
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
    await p.evaluate(([B1, B3, LYR, MANUAL, PROP]) => { const db = window.__db; const h = JSON.stringify(LYR);
      db.tracks.forEach(t => { t.lyrics = LYR.slice(); t.duration = 20; });
      db.lyricsSync = { [B1]: { lines: MANUAL, source: 'manual', hash: h, updated_at: '2026-10-23T00:00:00Z' } };
      db.alignJobs = { [B3]: { state: 'review', reason: 'ready', proposal: PROP, meta: { ratio: 0.92, quality_ok: false, est: [5], hash: h } },
                       [B1]: { state: 'review', reason: 'requested', proposal: PROP, meta: { ratio: 1, quality_ok: true, est: [], hash: h } } };
      db.alignSettings = { paused: false, daily_cap: 6000 }; db.alignReserved = 168;
      sessionStorage.setItem('fakedb2', JSON.stringify(db)); }, [B1, B3, LYR, MANUAL, PROP]);
    await p.reload(); await p.waitForTimeout(1000);
    return { ctx, p, errs };
  };
  const w = (p, ms) => p.waitForTimeout(ms || 300);
  const login = async (p, e) => { await p.locator('nav.nav button', { hasText: 'マイページ' }).click(); await w(p); await p.fill('#a-email', e); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('nav.nav button', { hasText: 'マイページ' }).click(); await w(p, 900); };
  const openSong = async (p, title) => {
    await p.locator('nav.nav button', { hasText: 'ホーム' }).click(); await w(p, 300);
    await p.locator('.sec', { hasText: '人気ランキング' }).locator('.row', { hasText: title }).first().click(); await w(p, 500);
    if (await p.locator('.player').count() === 0) { await p.locator('.mini-in').click(); await w(p, 400); }
    if (await p.locator('.player .lyrics').count() === 0) { await p.locator('.player .pill', { hasText: '歌詞' }).click(); await w(p, 400); }
  };
  const setT = async (p, t) => { await p.evaluate(t => { const a = document.querySelector('audio'); a.pause(); a.currentTime = t; }, t); await w(p, 350); };
  const on = p => p.evaluate(() => { const e = document.querySelector('.player .lyrics p.on'); return e ? e.textContent : null; });
  const noHScroll = p => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);

  // ---- 1. 未ログイン：AI の提案は確認待ちなので、再生画面には出さない（従来どおり全文表示）
  let { ctx, p, errs } = await mk();
  await openSong(p, 'ひまわり'); await setT(p, 3.5);
  ok('1 確認待ちの AI の提案は、再生画面に出さない（全文表示・光らせない）', await on(p) === null && await p.locator('.player .lyrics.static').count() === 1);
  await ctx.close();

  // ---- 2. 投稿者（ハムハム・一般会員）：マイページの印 → 下書き → 聞き比べ → 直して保存
  ({ ctx, p, errs } = await mk());
  await login(p, 'hamu@test.jp');
  await p.locator('.tabs button', { hasText: '投稿曲' }).click(); await w(p, 500);
  const btn = p.locator('button[aria-label="「ひまわり」の歌詞の同期（AI の提案あり）"]');
  ok('2 マイページ：AI の提案が届いた曲の「歌詞の同期」ボタンに印', await btn.count() === 1 && (await btn.getAttribute('class')).includes('has-ai'));
  await btn.click(); await w(p, 800);
  const t0 = await p.$$eval('.ls-row .ls-line .mono', e => e.map(x => x.textContent));
  ok('2 同期がまだ無い曲は、AI の提案を下書きとして読み込む', JSON.stringify(t0) === JSON.stringify(['0:03.1', '0:06.0', '0:11.2', '0:14.0']), t0);
  const note = await p.locator('.ls-ai').innerText();
  ok('2 「AI が合わせた下書き」「保存するまで再生画面に出ない」と説明し、照合率を表示', note.includes('AI が合わせた下書き') && note.includes('保存するまで、再生画面には表示されません') && note.includes('92%'), note.slice(0, 80));
  ok('2 品質の検査に落ちた結果は「推定の行を特に確認」と注意', note.includes('推定') && (await p.locator('.ls-ai').getAttribute('class')).includes('warn'));
  ok('2 AI が聞き取れなかった行に「推定」の印', await p.locator('.ls-row').nth(2).locator('.ls-est').count() === 1 && await p.locator('.ls-row').nth(0).locator('.ls-est').count() === 0);
  const cps = await p.$$eval('.ls-ai .row2 button', e => e.map(x => x.textContent));
  ok('2 確認ポイント（歌い出し・最初のサビ・中盤・最後の行など）のボタン', cps.includes('▶ 歌い出し') && cps.includes('▶ 最初のサビ') && cps.includes('▶ 最後の行'), cps);
  await p.locator('.ls-ai button', { hasText: '▶ 最初のサビ' }).click(); await w(p, 400);
  const at = await p.evaluate(() => { const a = document.querySelector('.ls audio'); const r = { t: a.currentTime, playing: !a.paused }; a.pause(); return r; });
  ok('2 確認ポイントを押すと、その行の2秒前から再生（実際の歌声と聞き比べ）', at.t >= 9.1 && at.t < 10.2 && at.playing, at);
  await p.locator('.ls-row').nth(0).locator('button', { hasText: '+0.1' }).click(); await w(p, 100);
  await p.locator('.ls-row').nth(0).locator('button', { hasText: '+0.1' }).click(); await w(p, 100);
  ok('2 直した行に「AI より +0.2秒」と、AI との差を表示', (await p.locator('.ls-row').nth(0).innerText()).includes('AI より +0.2秒'));
  ok('2 直していない行には差を表示しない', await p.locator('.ls-row').nth(1).locator('.ls-diff').count() === 0);
  await p.screenshot({ path: `${OUT}/${DEV}-align-draft.png` });
  ok('2 編集画面は横にはみ出さない', await noHScroll(p));
  await p.locator('header button', { hasText: '保存する' }).click(); await w(p, 600);
  const ap = await p.evaluate(() => window.__log.filter(x => x.op === 'lyrics_align_apply').pop());
  ok('2 保存すると「採用」として送る（直した時刻・mixed）', ap && ap.source === 'mixed' && ap.lines[0].t === 3.3 && ap.lines.length === 4, ap);
  ok('2 保存後に「AI から直した行 1行・ずれの中央値」を表示', (await p.locator('.toast').innerText().catch(() => '')).includes('AI から直した行 1行'));
  await p.locator('header button[aria-label="戻る"]').click(); await w(p, 400);
  await openSong(p, 'ひまわり'); await setT(p, 3.5);
  ok('2 保存した後は、再生画面で時刻どおりに光る', await on(p) === '一行目のうた', await on(p));
  ok('2 画面の読み込みでエラーが出ない', errs.length === 0, errs);
  await ctx.close();

  // ---- 3. 手動で合わせた曲（おぼろ月・投稿者 Ryo）：提案は別に表示し、勝手に置き換えない
  ({ ctx, p, errs } = await mk());
  await login(p, 'ryo@test.jp');
  await openSong(p, 'おぼろ月'); await setT(p, 3.05);
  ok('3 手動の同期はそのまま再生画面に使われる（3.05秒＝1行目）', await on(p) === '一行目のうた');
  await p.locator('.player .lyr-sync-note button').click(); await w(p, 800);
  const t1 = await p.$$eval('.ls-row .ls-line .mono', e => e.map(x => x.textContent));
  ok('3 編集画面は手動の時刻を読み込み、AI の提案では置き換えない', JSON.stringify(t1) === JSON.stringify(['0:03.0', '0:06.0', '0:11.0', '0:14.0']), t1);
  const n3 = await p.locator('.ls-ai').innerText();
  ok('3 「AI の提案があります・今の同期はそのまま」と、読み込む・使わないのボタン', n3.includes('AI の提案があります') && n3.includes('今の同期はそのまま') && await p.locator('.ls-ai button', { hasText: '提案を読み込む' }).count() === 1);
  await p.locator('.ls-ai button', { hasText: '使わない' }).click(); await w(p, 500);
  ok('3 「使わない」を押すと提案を閉じる（同期は変わらない）', await p.locator('.ls-ai').count() === 0 && await p.evaluate(() => window.__log.some(x => x.op === 'lyrics_align_dismiss')) && !(await p.evaluate(() => window.__log.some(x => x.op === 'lyrics_align_apply'))));
  ok('3 「AI で合わせ直す」（今日あと2回）を表示', (await p.locator('button', { hasText: 'AI で合わせ直す' }).count()) === 1 && (await p.locator('.ls-list').innerText()).includes('今日あと2回'));
  await p.locator('button', { hasText: 'AI で合わせ直す' }).click(); await w(p, 600);
  ok('3 依頼すると「解析待ち」になり、今の同期はそのまま', (await p.locator('.ls-list').innerText()).includes('解析待ち') && await p.evaluate(() => window.__log.some(x => x.op === 'lyrics_align_request')));
  ok('3 画面の読み込みでエラーが出ない', errs.length === 0, errs);
  await ctx.close();

  // ---- 4. 管理画面（Ryo は運営）：停止と再開・使用量・一覧・登録
  ({ ctx, p, errs } = await mk());
  await login(p, 'ryo@test.jp');
  await p.locator('button.admin-entry').click(); await w(p, 600);
  await p.locator('.tabs button', { hasText: '歌詞AI' }).click(); await w(p, 600);
  const adm = await p.locator('.screen').innerText();
  ok('4 管理画面に「歌詞AI」：動作中・今日の使用量（予約）168 / 6000・確認待ち2曲', adm.includes('動作中') && adm.includes('168 / 6000') && /2曲\s*確認待ち/.test(adm), adm.slice(0, 200));
  ok('4 曲ごとの状態（確認待ち・照合率）', adm.includes('ひまわり') && adm.includes('確認待ち') && adm.includes('歌詞と合った行 92%'));
  await p.locator('button', { hasText: '停止する' }).click(); await w(p, 500);
  ok('4 停止できる（「再開する」に変わる）', await p.locator('button', { hasText: '再開する' }).count() === 1 && await p.evaluate(() => window.__log.some(x => x.op === 'admin_align_set_paused' && x.paused === true)));
  await p.locator('button', { hasText: '再開する' }).click(); await w(p, 500);
  ok('4 再開できる', await p.locator('button', { hasText: '停止する' }).count() === 1);
  ok('4 自動で採用は初期オフ（すべて確認待ち）', (await p.locator('.screen').innerText()).includes('自動で採用：オフ'));
  await p.locator('button', { hasText: 'オンにする' }).first().click(); await w(p, 300);
  ok('4 オンにする前に基準と「手動の同期は置き換えない」を表示して確認', (await p.locator('.screen').innerText()).includes('照合率 95%以上') && await p.evaluate(() => !window.__log.some(x => x.op === 'admin_align_set_auto')));
  await p.locator('button', { hasText: 'オンにする（確認）' }).click(); await w(p, 500);
  ok('4 確認するとオン → オフにもできる', (await p.locator('.screen').innerText()).includes('自動で採用：オン') && await p.evaluate(() => window.__log.some(x => x.op === 'admin_align_set_auto' && x.on)));
  await p.locator('button', { hasText: 'オフにする' }).click(); await w(p, 500);
  ok('4 オフに戻せる', (await p.locator('.screen').innerText()).includes('自動で採用：オフ'));
  await p.selectOption('select[aria-label="解析する曲"]', B1); await p.locator('button', { hasText: 'この1曲を登録' }).click(); await w(p, 500);
  ok('4 1曲だけ登録：登録済みなら「重複して解析しません」', (await p.locator('.toast').innerText().catch(() => '')).includes('重複して解析しません'));
  await p.locator('button', { hasText: '公開中の曲をまとめて登録' }).click(); await w(p, 300);
  await p.locator('button', { hasText: /公開中の\d+曲を登録する/ }).click(); await w(p, 600);
  ok('4 まとめて登録（確認してから）：結果の件数を表示', (await p.locator('.toast').innerText().catch(() => '')).includes('登録しました：解析待ち 1曲・重複 2曲'), await p.locator('.toast').innerText().catch(() => ''));
  await p.screenshot({ path: `${OUT}/${DEV}-align-admin.png`, fullPage: true });
  ok('4 管理画面は横にはみ出さない（タブ5つ）', await noHScroll(p));
  await p.locator('.panel', { hasText: 'ひまわり' }).locator('button', { hasText: '聞いて確認する' }).click(); await w(p, 800);
  ok('4 一覧から編集画面を開いて聞いて確認できる（運営）', await p.locator('.ls-panel').count() === 1 && (await p.locator('.ls-ai').innerText()).includes('AI が合わせた下書き'));
  ok('4 画面の読み込みでエラーが出ない', errs.length === 0, errs);
  await ctx.close();

  // ---- 5. 一般会員は管理画面の「歌詞AI」を使えない（データベースでも拒否）
  ({ ctx, p, errs } = await mk());
  await login(p, 'hamu@test.jp');
  ok('5 一般会員には管理画面の入口が無い', await p.locator('button.admin-entry').count() === 0);
  const r5 = await p.evaluate(async () => { const r = await window.supabase.createClient('x', 'y').rpc('admin_align_overview'); return r.error && r.error.message; }).catch(() => 'NOT_ALLOWED');
  ok('5 直接呼んでも拒否される（NOT_ALLOWED）', String(r5).includes('NOT_ALLOWED'), r5);
  await ctx.close();

  // ---- 6. v1.15 がまだ適用されていないとき：従来どおり（手動の同期だけ）
  ({ ctx, p, errs } = await mk({ __noV115: true }));
  await login(p, 'hamu@test.jp');
  await p.locator('.tabs button', { hasText: '投稿曲' }).click(); await w(p, 500);
  ok('6 マイページの印は出ない', await p.locator('button.has-ai').count() === 0);
  await p.locator('button[aria-label="「ひまわり」の歌詞の同期"]').click(); await w(p, 800);
  ok('6 編集画面は従来どおり（AI の表示なし・時刻なしから）', await p.locator('.ls-ai').count() === 0 && (await p.$$eval('.ls-row .ls-line .mono', e => e.map(x => x.textContent))).every(x => x === '--:--.-'));
  ok('6 画面の読み込みでエラーが出ない', errs.length === 0, errs);
  await ctx.close();

  await b.close();
  const f = R.filter(x => !x[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  process.exit(f.length ? 1 : 0);
})();
