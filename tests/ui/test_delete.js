// Stage 5: track deletion + account withdrawal UI (Chromium, iPhone / Android emulation)
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
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const mk = async (init) => { const c = await b.newContext({ ...dev }); if (init) await c.addInitScript(init); const p = await c.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message)); await p.route('**/*', route); return { c, p, errs }; };
  const { p, errs } = await mk();
  const w = ms => p.waitForTimeout(ms || 500), nav = l => p.locator('nav.nav button', { hasText: l }).click();
  const toast = async () => (await p.locator('.toast').innerText().catch(() => '')).trim();
  const login = async e => { await nav('マイページ'); await w(300); await p.fill('#a-email', e); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('text=ログアウト').waitFor(); await w(700); };
  const logout = async () => { await nav('マイページ'); await w(300); await p.locator('button', { hasText: 'ログアウト' }).click(); await w(800); };
  const homeTitles = async () => { await nav('ホーム'); await w(400); return p.locator('.row .t').allInnerTexts(); };
  const noOverflow = () => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  const rpcCount = n => p.evaluate(n => window.__log.filter(l => l.op === 'rpc' && l.name === n).length, n);

  await p.goto('http://aimuse.test/'); await w(1200);
  ok('0 ゲストのホームにハムハムの公開曲「ひまわり」がある', (await homeTitles()).includes('ひまわり'));

  // ---- 1. 楽曲の削除（本人）
  await login('hamu@test.jp');
  await p.locator('.tabs button', { hasText: '投稿曲' }).click(); await w(300);
  const delBtn = p.locator('button[aria-label="「ひまわり」を削除"]');
  ok('1 マイページの投稿曲に削除ボタン（曲名つきの読み上げ名）', await delBtn.count() === 1);
  await delBtn.click(); await w(300);
  const sheet = await p.locator('.sheet').innerText().catch(() => '');
  ok('1 削除前に確認画面：曲名・状態・すぐ消えること・30日の扱い', ['この曲を削除しますか？', 'ひまわり', '公開中', 'すぐに消えます', '30日'].every(x => sheet.includes(x)), sheet.slice(0, 80));
  await p.screenshot({ path: `${OUT}/${DEV}-d1-confirm.png` });
  ok('1 確認画面が横にはみ出さない', await noOverflow());
  await p.locator('.sheet button', { hasText: 'キャンセル' }).click(); await w(300);
  ok('1 キャンセルすると何も起きない', await rpcCount('delete_my_track') === 0 && await delBtn.count() === 1);
  // 失敗時
  await p.evaluate(() => { window.__fail.deleteTrack = true; });
  await delBtn.click(); await w(200); await p.locator('.sheet button', { hasText: '削除する' }).click(); await w(500);
  const errTxt = await p.locator('.sheet [role=alert]').innerText().catch(() => '');
  ok('1 通信に失敗したら確認画面に理由を表示し、曲は残る', /削除できませんでした/.test(errTxt) && await p.locator('.sheet').count() === 1, errTxt);
  await p.evaluate(() => { window.__fail.deleteTrack = false; });
  await p.locator('.sheet button', { hasText: '削除する' }).click(); await w(600);
  const t1 = await toast();
  ok('1 再試行で削除でき、完了の表示', /「ひまわり」を削除しました/.test(t1) && await p.locator('.sheet').count() === 0, t1);
  ok('1 マイページの一覧から消える', await delBtn.count() === 0);
  ok('1 ホームからすぐに消える', !(await homeTitles()).includes('ひまわり'));
  await nav('検索'); await w(300); await p.fill('#q', 'ひまわり'); await w(500);
  ok('1 検索からも消える', !(await p.locator('.sec .list .row .t').allInnerTexts()).includes('ひまわり'));
  ok('1 サーバーの削除処理（本人のみ・1回の処理）を呼んでいる', await rpcCount('delete_my_track') === 2);
  ok('1 他人の曲（ホーム・検索）には削除ボタンがない', await p.locator('button[aria-label*="を削除"]').count() === 0);

  // ---- 2. 退会：設定 → アカウント削除（ハムハムにもう1曲、公開中の曲がある状態）
  await p.evaluate(() => { const d = window.__db, t = d.tracks.find(x => x.title === 'おぼろ月'); d.tracks.push({ ...t, id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb9', user_id: '22222222-2222-4222-8222-222222222222', artist_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', title: 'なつぞら', artist: 'ハムハム', audio_path: 'x/9.mp3' }); sessionStorage.setItem('fakedb2', JSON.stringify(d)); });
  await p.reload(); await w(1200);
  ok('2 準備：ハムハムの公開曲「なつぞら」がホームにある', (await homeTitles()).includes('なつぞら'));
  await nav('マイページ'); await w(300);
  await p.locator('button', { hasText: '設定（カラーテーマ・アカウント）' }).click(); await w(400);
  ok('2 設定画面に「アカウントを削除（退会）」', await p.locator('button', { hasText: 'アカウントを削除（退会）' }).count() === 1);
  await p.locator('button', { hasText: 'アカウントを削除（退会）' }).click(); await w(400);
  const page = await p.locator('.screen').innerText();
  ok('2 説明：すぐ非公開・30日間取り消し可・30日後に削除・バックアップに残る可能性', ['すぐ', '30日間', '30日後', 'バックアップ', '取り消す'].every(x => page.includes(x)));
  await p.screenshot({ path: `${OUT}/${DEV}-d2-account.png`, fullPage: true });
  ok('2 横にはみ出さない', await noOverflow());
  const submit = p.locator('button', { hasText: '退会を申請する' });
  ok('2 確認のチェックとパスワードを入れるまで申請できない', await submit.isDisabled());
  await p.locator('button[role=checkbox]', { hasText: '上記の内容を確認しました' }).click();
  ok('2 チェックだけでは申請できない', await submit.isDisabled());
  await p.fill('#del-pw', 'wrong'); await submit.click(); await w(600);
  const e2 = await p.locator('[role=alert]').innerText().catch(() => '');
  ok('2 パスワードが違うと申請しない', /パスワードが正しくありません/.test(e2) && await rpcCount('request_my_account_deletion') === 0, e2);
  // 本人確認の有効時間切れ（サーバーが拒否）
  await p.evaluate(() => { window.__staleAuth = true; });
  await p.fill('#del-pw', 'password'); await submit.click(); await w(700);
  const e3 = await p.locator('[role=alert]').innerText().catch(() => '');
  ok('2 サーバーが本人確認を認めなければ申請されない（メッセージ表示）', /本人確認の有効時間/.test(e3) && !(await p.evaluate(() => window.__db.deletions.length)), e3);
  await p.evaluate(() => { window.__staleAuth = false; });
  await p.fill('#del-pw', 'password'); await submit.click(); await w(900);
  const t2 = await toast();
  ok('2 申請できる（取り消し期限を表示）', /退会を申請しました。.*まで取り消せます/.test(t2), t2);
  ok('2 ほかの端末のログインを終了する処理を呼ぶ', await p.evaluate(() => window.__log.some(l => l.op === 'signOut' && l.scope === 'others')));
  const st = await p.locator('.del-status').innerText().catch(() => '');
  ok('2 申請後は「退会手続き中」と取り消し期限・取り消しボタン', /退会手続き中です/.test(st) && /まで(は)?取り消せます/.test(st) && /退会を取り消す/.test(st), st.slice(0, 60));
  ok('2 「完了」とは表示しない', !/完了しました|削除しました/.test(st));
  await p.screenshot({ path: `${OUT}/${DEV}-d3-pending.png` });

  // ---- 3. 手続き中：公開画面から消え、操作できない
  await nav('マイページ'); await w(400);
  ok('3 マイページは手続き中の表示だけ（プロフィール・投稿曲は出さない）', await p.locator('.del-status').count() === 1 && await p.locator('.stats').count() === 0);
  await logout();
  ok('3 ゲストのホームからハムハムの曲（公開中だった「なつぞら」）が消える', !(await homeTitles()).includes('なつぞら') && !(await p.locator('.row .sub').allInnerTexts()).some(t => t.includes('ハムハム')));
  await login('hamu@test.jp');
  await nav('マイページ'); await w(300);
  ok('3 ログインし直しても手続き中のまま（サーバーの状態を表示）', await p.locator('.del-status').count() === 1);
  await nav('ホーム'); await w(300);
  await p.locator('button[aria-label="お気に入りに追加"]').first().click(); await w(300);
  ok('3 お気に入りしようとすると「退会手続き中のため…」', /退会手続き中のため/.test(await toast()), await toast());
  await p.reload(); await w(1200); await nav('マイページ'); await w(300);
  ok('3 再読み込みしても手続き中のまま', await p.locator('.del-status').count() === 1);

  // ---- 4. 取り消し
  await p.locator('button', { hasText: '退会を取り消す' }).click(); await w(900);
  const t4 = await toast();
  ok('4 取り消すと元の公開状態に戻ったと表示', /退会を取り消しました/.test(t4), t4);
  ok('4 公開中だった曲がホームに戻る', (await homeTitles()).includes('なつぞら'));
  await nav('マイページ'); await w(300);
  ok('4 マイページが通常表示に戻る', await p.locator('.del-status').count() === 0 && await p.locator('.stats').count() === 1);
  await nav('ホーム'); await w(300);
  await p.locator('button[aria-label="お気に入りに追加"]').first().click(); await w(300);
  ok('4 取り消し後は操作できる', /お気に入りに追加しました/.test(await toast()), await toast());

  // ---- 5. 管理者は退会できない
  await logout(); await login('ryo@test.jp');
  await nav('マイページ'); await w(300); await p.locator('button', { hasText: '設定（カラーテーマ' }).click(); await w(300);
  await p.locator('button', { hasText: 'アカウントを削除（退会）' }).click(); await w(300);
  ok('5 管理者アカウントには申請ボタンを出さず理由を表示', await p.locator('button', { hasText: '退会を申請する' }).count() === 0 && /管理者アカウントは退会できません/.test(await p.locator('.screen').innerText()));

  // ---- 6. v1.9 SQL 未実行のサーバー
  const x = await mk(() => { window.__noV19 = true; });
  const p2 = x.p;
  await p2.goto('http://aimuse.test/'); await p2.waitForTimeout(900);
  await p2.locator('nav.nav button', { hasText: 'マイページ' }).click(); await p2.waitForTimeout(300);
  await p2.fill('#a-email', 'hamu@test.jp'); await p2.fill('#a-pw', 'password'); await p2.locator('.form button.btn.primary').click(); await p2.locator('text=ログアウト').waitFor(); await p2.waitForTimeout(600);
  ok('6 v1.9未実行でもマイページは通常表示', await p2.locator('.stats').count() === 1 && await p2.locator('.del-status').count() === 0);
  await p2.locator('button', { hasText: '設定（カラーテーマ' }).click(); await p2.waitForTimeout(300);
  await p2.locator('button', { hasText: 'アカウントを削除（退会）' }).click(); await p2.waitForTimeout(300);
  await p2.locator('button[role=checkbox]').click(); await p2.fill('#del-pw', 'password'); await p2.locator('button', { hasText: '退会を申請する' }).click(); await p2.waitForTimeout(800);
  ok('6 v1.9未実行では「準備中」と表示し、申請したことにしない', /準備中/.test(await p2.locator('[role=alert]').innerText().catch(() => '')) && await p2.locator('.del-status').count() === 0);
  ok('6 エラーなし', x.errs.length === 0, x.errs);

  ok('エラーなし', errs.length === 0, errs);
  const f = R.filter(r => !r[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  await b.close();
})();
