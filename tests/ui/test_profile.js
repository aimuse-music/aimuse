// AIMUSE v1.6 profile editor end-to-end test (Chromium with iPhone / Android emulation)
// usage: node test_profile.js <index.html> <iphone|android> <shots dir>
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const [INDEX, DEV, OUT] = process.argv.slice(2);
const IMG = f => path.join(__dirname, 'img', f);
const device = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
const R = []; const ok = (name, cond, info) => { R.push([name, !!cond]); console.log(`[${cond ? 'PASS' : 'FAIL'}] ${name}${info !== undefined ? '  → ' + JSON.stringify(info) : ''}`); };

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const ctx = await b.newContext({ ...device, defaultBrowserType: undefined });
  const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/*', r => { const u = r.request().url();
    if (u.startsWith('http://aimuse.test/') && !u.endsWith('.js')) return r.fulfill({ contentType: 'text/html', body: fs.readFileSync(INDEX) });
    if (u.endsWith('/config.js')) return r.fulfill({ contentType: 'text/javascript', body: 'window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k"};' });
    if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
    if (u.includes('react-dom.production') || u.includes('htm.umd')) return r.fulfill({ contentType: 'text/javascript', body: '' });
    if (u.includes('supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
    return r.fulfill({ status: 404, body: '' }); });
  const cdp = await ctx.newCDPSession(p);
  const touch = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map((q, i) => ({ x: q[0], y: q[1], id: i })) });
  const w = ms => p.waitForTimeout(ms || 500);
  const nav = l => p.locator('nav.nav button', { hasText: l }).click();
  const toast = async () => (await p.locator('.toast').innerText().catch(() => '')).trim();
  const db = () => p.evaluate(() => JSON.parse(sessionStorage.getItem('fakedb2')));
  const login = async e => { await nav('マイページ'); await w(300); await p.fill('#a-email', e); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('text=ログアウト').waitFor(); await w(700); };
  const logout = async () => { await nav('マイページ'); await w(300); await p.locator('text=ログアウト').click(); await w(600); };
  const openEditor = async () => { await nav('マイページ'); await w(300); await p.locator('button', { hasText: 'プロフィールを編集' }).click(); await w(700); };
  const stageImg = () => p.evaluate(() => { const i = document.querySelector('.crop-stage img'), s = document.querySelector('.crop-stage'); const m = (i.style.transform || '').match(/translate\(([-\d.]+)px, ?([-\d.]+)px\) scale\(([\d.]+)\)/);
    return { x: +m[1], y: +m[2], s: +m[3], w: parseFloat(i.style.width), h: parseFloat(i.style.height), W: s.clientWidth, H: s.clientHeight }; });
  const covers = v => v.x <= 0.5 && v.y <= 0.5 && v.x + v.w * v.s >= v.W - 0.5 && v.y + v.h * v.s >= v.H - 0.5;
  const pickFile = async (kindIdx, which, file) => { const inputs = p.locator('.pe-img').nth(0).locator('xpath=..').locator('input[type=file]');
    const field = p.locator('.form .field').nth(kindIdx); await field.locator('input[type=file]').nth(which).setInputFiles(file); await w(800); };
  const bgOf = sel => p.evaluate(s => [...document.querySelectorAll(s)].map(e => getComputedStyle(e).backgroundImage).filter(x => x && x !== 'none').length, sel);

  await p.goto('http://aimuse.test/'); await w(1000);

  // ---- 1. Ryo（管理者）でログインし、編集画面を開く
  await login('ryo@test.jp');
  ok('1 マイページに「プロフィールを編集」ボタン', await p.locator('button', { hasText: 'プロフィールを編集' }).count() === 1);
  await openEditor();
  ok('1 編集画面が開き、プレビューが表示される', await p.locator('.pe-preview').count() === 1);
  ok('1 アーティスト名・自己紹介の欄に現在の値', await p.inputValue('#pe-aname') === 'NOCTERA');
  ok('1 「写真から選ぶ」「ファイルから選ぶ」が各画像に表示', await p.locator('.drop.small', { hasText: '写真から選ぶ' }).count() === 2 && await p.locator('.drop.small', { hasText: 'ファイルから選ぶ' }).count() === 2);
  ok('1 写真用は accept="image/*"（写真ライブラリが開く）', await p.locator('.form .field').nth(0).locator('input[type=file]').nth(0).getAttribute('accept') === 'image/*');
  ok('1 capture 属性なし（カメラ専用にならない）', await p.locator('input[type=file][capture]').count() === 0);
  await p.screenshot({ path: `${OUT}/${DEV}-1-editor.png`, fullPage: false });

  // ---- 2. 不正なファイル
  for (const [f, label] of [['evil.svg', 'SVG'], ['fake.heic', '読み込めないHEIC'], ['huge.jpg', '20MB超']]) {
    await pickFile(0, 1, IMG(f));
    const t = await toast(); ok(`2 ${label} は拒否され、分かる説明が出る`, t && (await p.locator('.crop-stage').count()) === 0, t);
    await w(2500);
  }

  // ---- 3. アイコン：写真から選ぶ → 切り抜き（ドラッグ・2本指・スライダー）
  await pickFile(0, 0, IMG('photo.jpg'));
  ok('3 切り抜き画面（丸い枠）が開く', await p.locator('.crop-stage.round').count() === 1);
  await p.screenshot({ path: `${OUT}/${DEV}-2-crop-avatar.png` });
  let v0 = await stageImg(); ok('3 初期状態で枠が画像で埋まる', covers(v0), v0);
  const box = await p.locator('.crop-stage').boundingBox(); const cx = box.x + box.width / 2, cy = box.y + box.height / 2;
  // 2本指で拡大
  await touch('touchStart', [[cx - 30, cy], [cx + 30, cy]]);
  for (let i = 1; i <= 6; i++) await touch('touchMove', [[cx - 30 - i * 12, cy], [cx + 30 + i * 12, cy]]);
  await touch('touchEnd', []); await w(200);
  let v1 = await stageImg(); ok('3 2本指で拡大できる', v1.s > v0.s * 1.5, { before: v0.s, after: v1.s });
  // 1本指でドラッグ
  await touch('touchStart', [[cx, cy]]); for (let i = 1; i <= 5; i++) await touch('touchMove', [[cx - i * 15, cy - i * 8]]); await touch('touchEnd', []); await w(200);
  let v2 = await stageImg(); ok('3 ドラッグで位置を動かせる', v2.x < v1.x - 20, { before: v1.x, after: v2.x });
  // 大きく引っ張っても枠の外に空白ができない
  await touch('touchStart', [[cx, cy]]); for (let i = 1; i <= 8; i++) await touch('touchMove', [[cx + i * 80, cy + i * 80]]); await touch('touchEnd', []); await w(200);
  let v3 = await stageImg(); ok('3 引っ張りすぎても枠内に空白ができない', covers(v3), v3);
  // スライダーで縮小（最小は枠いっぱい）
  await p.locator('.crop-zoom').fill('1'); await w(200);
  let v4 = await stageImg(); ok('3 スライダーで縮小、最小でも枠いっぱい', Math.abs(v4.s - v0.s) < 1e-6 && covers(v4), v4);
  await p.locator('.crop-zoom').fill('2'); await w(200);
  await p.locator('button', { hasText: 'この範囲を使う' }).click(); await w(800);
  ok('3 プレビューに新しいアイコン（未保存）', (await p.locator('.pe-img .hint').nth(0).innerText()).includes('未保存'));

  // ---- 4. 背景：ファイルから選ぶ → 横長の枠
  await pickFile(1, 1, IMG('wide.jpg'));
  ok('4 背景は横長（3:1）の枠', await p.evaluate(() => { const s = document.querySelector('.crop-stage'); return !s.classList.contains('round') && Math.abs(s.clientWidth / s.clientHeight - 3) < 0.05; }));
  await p.screenshot({ path: `${OUT}/${DEV}-3-crop-header.png` });
  await p.locator('button', { hasText: 'この範囲を使う' }).click(); await w(800);

  // ---- 5. 名前・自己紹介を変更してプレビュー → 保存
  await p.fill('#pe-aname', 'ノクテラ'); await p.fill('#pe-bio', 'AIと作るJ-POP。\n夜の歌が好きです。'); await p.fill('#pe-name', 'りょう');
  ok('5 プレビューに変更後の名前・背景が出る', (await p.locator('.pe-preview h2').innerText()) === 'ノクテラ' && await p.locator('.pe-preview .pbanner').count() === 1);
  await p.evaluate(() => window.scrollTo(0, 0)); await p.screenshot({ path: `${OUT}/${DEV}-4-preview.png` });
  await p.locator('button', { hasText: '保存する' }).click(); await w(1500);
  let d = await db(); const ryo = d.profiles.find(x => x.display_name === 'りょう');
  ok('5 保存成功のメッセージ', (await toast()) === 'プロフィールを保存しました', await toast());
  ok('5 アイコン・背景がプロフィールに設定された', ryo && ryo.avatar_path && ryo.header_path, ryo);
  ok('5 保存された画像はJPEG・縮小済み（2MB未満）', await p.evaluate(() => window.__log.filter(l => l.op === 'upload').every(l => l.type === 'image/jpeg' && l.size < 1900000)));
  ok('5 アーティスト名・曲の表示名・履歴が更新', d.artists.find(a => a.name === 'ノクテラ') && d.tracks.filter(t => t.user_id === ryo.id).every(t => t.artist === 'ノクテラ') && d.history.length === 1);
  ok('5 自己紹介が保存（改行も保持）', d.artists.find(a => a.name === 'ノクテラ').bio === 'AIと作るJ-POP。\n夜の歌が好きです。');
  ok('5 保存は本人の2ファイルだけ・ファイル名に会員IDを含まない', d.avatars.length === 2 && d.avatars.every(o => o.owner === ryo.id && !o.name.includes(ryo.id)), d.avatars.map(o => o.name));
  // 実際に保存された画像の大きさを確認
  const dims = await p.evaluate(async () => { const out = {}; for (const [k, u] of Object.entries(window.__blobs)) { const i = new Image(); i.src = u; await i.decode(); out[k.split('-')[0]] = [i.naturalWidth, i.naturalHeight]; } return out; });
  ok('5 アイコン512×512・背景1500×500で保存', JSON.stringify(dims.avatar) === '[512,512]' && JSON.stringify(dims.header) === '[1500,500]', dims);

  // ---- 6. 各画面に反映
  await nav('マイページ'); await w(600);
  ok('6 マイページ：アイコン・背景', await bgOf('.profile .avatar>div') === 1 && await p.locator('.pbanner').count() === 1);
  await p.screenshot({ path: `${OUT}/${DEV}-5-mypage.png` });
  await nav('ホーム'); await w(600);
  ok('6 ホームの人気アーティスト：アイコン', await p.evaluate(() => [...document.querySelectorAll('.cover')].some(c => /blob:/.test(c.style.background))));
  await nav('検索'); await w(300); await p.locator('.seg button', { hasText: 'アーティスト' }).click(); await p.fill('#q', 'ノクテラ'); await w(500);
  ok('6 検索結果のアーティスト：アイコン', await p.evaluate(() => [...document.querySelectorAll('.sec .hrow .cover')].some(c => /blob:/.test(c.style.background))));
  await p.locator('.sec .hrow button.artist').first().click(); await w(700);
  ok('6 アーティストページ：背景・アイコン・自己紹介', await p.locator('.pbanner').count() === 1 && (await p.locator('.ahead p').innerText()).includes('夜の歌'));
  await p.screenshot({ path: `${OUT}/${DEV}-6-artist.png` });
  await p.locator('.row').first().locator('xpath=.').click().catch(() => {}); await w(400);
  await p.locator('.mini, .mini-player, [class*=mini]').first().click().catch(() => {}); await w(500);
  const playerIcon = await p.locator('.a-ic').count();
  ok('6 再生画面（楽曲詳細）：アーティスト名の横にアイコン', playerIcon >= 1, playerIcon);
  await p.screenshot({ path: `${OUT}/${DEV}-7-player.png` });
  await p.keyboard.press('Escape').catch(() => {}); await p.goto('http://aimuse.test/'); await w(900);

  // ---- 7. 失敗時に既存データを守る
  const before = (await db()).profiles.find(x => x.display_name === 'りょう').avatar_path;
  await openEditor(); await pickFile(0, 0, IMG('transparent.png')); await p.locator('button', { hasText: 'この範囲を使う' }).click(); await w(500);
  await p.evaluate(() => { window.__fail.setImage = true; }); await p.locator('button', { hasText: '保存する' }).click(); await w(1500);
  d = await db();
  ok('7 プロフィール設定に失敗→既存のアイコンはそのまま', d.profiles.find(x => x.display_name === 'りょう').avatar_path === before);
  ok('7 失敗時、新しく保存した画像は削除される（ゴミが残らない）', d.avatars.length === 2, d.avatars.length);
  ok('7 失敗が画面に表示される', (await p.locator('.form .err').innerText().catch(() => '')).includes('アイコン'));
  await p.evaluate(() => { window.__fail = { upload: true }; }); await p.locator('button', { hasText: '保存する' }).click(); await w(1500);
  d = await db(); ok('7 画像の保存に失敗→既存のアイコンはそのまま', d.profiles.find(x => x.display_name === 'りょう').avatar_path === before && d.avatars.length === 2);
  await p.evaluate(() => { window.__fail = { remove: true }; }); await p.locator('button', { hasText: '保存する' }).click(); await w(1500);
  d = await db(); const after = d.profiles.find(x => x.display_name === 'りょう').avatar_path;
  ok('7 古い画像の削除に失敗→新しいアイコンは設定済み（成功扱い）', after !== before && (await toast()) === 'プロフィールを保存しました');
  ok('7 削除に失敗した古い画像は残る（3ファイル）', d.avatars.length === 3, d.avatars.length);
  await p.evaluate(() => { window.__fail = {}; }); await pickFile(0, 0, IMG('photo.jpg')); await p.locator('button', { hasText: 'この範囲を使う' }).click(); await w(500);
  await p.locator('button', { hasText: '保存する' }).click(); await w(1500);
  d = await db(); ok('7 次の保存で残っていた画像が片付く（2ファイルに戻る）', d.avatars.length === 2, d.avatars.map(o => o.name));

  // ---- 8. 初期画像に戻す
  await p.locator('.form .field').nth(0).locator('button', { hasText: '初期画像に戻す' }).click(); await w(300);
  await p.locator('button', { hasText: '保存する' }).click(); await w(1500);
  d = await db(); const r8 = d.profiles.find(x => x.display_name === 'りょう');
  ok('8 アイコンを初期画像に戻せる（ファイルも削除）', r8.avatar_path === null && d.avatars.length === 1, { avatar: r8.avatar_path, files: d.avatars.length });
  await nav('マイページ'); await w(500);
  ok('8 マイページは頭文字の表示に戻る', (await p.locator('.profile .avatar>div').innerText()).length === 1);
  // もう一度アイコンを設定しておく（他の人からの見え方の確認用）
  await openEditor(); await pickFile(0, 0, IMG('photo.jpg')); await p.locator('button', { hasText: 'この範囲を使う' }).click(); await w(400);
  await p.locator('button', { hasText: '保存する' }).click(); await w(1500);

  // ---- 9. 他のユーザー（ハムハム）
  await logout(); await login('hamu@test.jp');
  await nav('ホーム'); await w(600);
  ok('9 ハムハムにもRyoのアイコンが表示', await p.evaluate(() => [...document.querySelectorAll('.cover')].some(c => /blob:/.test(c.style.background))));
  await openEditor();
  ok('9 ハムハムの編集画面にはハムハムのアーティストだけ', await p.inputValue('#pe-aname') === 'ハムハム' && await p.locator('#pe-art').count() === 0);
  for (const nm of ['ノクテラ', 'ﾉｸﾃﾗ', 'AIMUSE公式']) {
    await p.fill('#pe-aname', nm); await p.locator('button', { hasText: '保存する' }).click(); await w(1200);
    ok(`9 なりすまし・禁止語「${nm}」は保存できない`, (await db()).artists.find(a => a.user_id === '22222222-2222-4222-8222-222222222222').name === 'ハムハム' && (await p.locator('.form .err').innerText()).includes('使用できません'));
  }
  const attack = await p.evaluate(async () => {
    const d = JSON.parse(sessionStorage.getItem('fakedb2')); const ryoAvatar = d.profiles.find(x => x.is_admin).avatar_path; const out = {};
    out.setOthersPath = (await sb.rpc('set_my_profile_image', { p_kind: 'avatar', p_path: ryoAvatar })).error?.message || 'OK';
    out.removeOthers = (await sb.storage.from('avatars').remove([ryoAvatar])).data.length;
    out.uploadOthers = (await sb.storage.from('avatars').upload('11111111-1111-4111-8111-111111111111/avatar-' + uuid4() + '.jpg', new Blob(['x'], { type: 'image/jpeg' }), { contentType: 'image/jpeg' })).error?.message || 'OK';
    out.renameOthers = (await sb.rpc('rename_my_artist', { p_artist: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', p_name: '乗っ取り' })).error?.message || 'OK';
    out.updateOthersBio = (await sb.from('artists').update({ bio: '乗っ取り' }).eq('id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa').select('id')).data.length;
    out.adminReset = (await sb.rpc('admin_reset_profile_image', { p_artist: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', p_kind: 'avatar' })).error?.message || 'OK';
    return out; });
  ok('9 コンソールから他人の画像を設定・削除・保存できない', /あなたの画像ではありません/.test(attack.setOthersPath) && attack.removeOthers === 0 && /row-level/.test(attack.uploadOthers), attack);
  ok('9 コンソールから他人のアーティスト名・自己紹介・管理機能を使えない', /見つかりません/.test(attack.renameOthers) && attack.updateOthersBio === 0 && /管理者のみ/.test(attack.adminReset), attack);

  // ハムハムがアイコンを設定（管理者による初期化の確認用）・正当な名前変更
  await p.goto('http://aimuse.test/'); await w(900); await openEditor();
  await pickFile(0, 1, IMG('transparent.png')); await p.locator('button', { hasText: 'この範囲を使う' }).click(); await w(400);
  await p.fill('#pe-aname', 'ハムスター'); await p.locator('button', { hasText: '保存する' }).click(); await w(1500);
  ok('9 ハムハムの正当な名前変更・アイコン設定は成功', (await db()).artists.some(a => a.name === 'ハムスター') && (await toast()) === 'プロフィールを保存しました', await toast());

  // ---- 10. 管理者：初期化・名義変更の履歴・元に戻す
  await logout(); await login('ryo@test.jp'); await nav('ホーム'); await w(600);
  await p.locator('button.artist', { hasText: 'ハムスター' }).first().click(); await w(700);
  await p.locator('button', { hasText: '管理者：アイコンを初期化' }).click(); await w(200);
  await p.locator('button', { hasText: 'アイコンを削除する' }).click(); await w(1200);
  d = await db(); const hamu = d.profiles.find(x => x.id === '22222222-2222-4222-8222-222222222222');
  ok('10 管理者がハムハムのアイコンを初期化（ファイルも削除）', hamu.avatar_path === null && !d.avatars.some(o => o.owner === hamu.id), hamu);
  await nav('マイページ'); await w(400); await p.locator('button.admin-entry').click(); await w(500);
  await p.locator('.tabs button', { hasText: '名義変更' }).click(); await w(800);
  const hist = await p.locator('.panel').allInnerTexts();
  ok('10 管理者画面に名義変更の履歴', hist.some(t => t.includes('ハムハム → ハムスター')) && hist.some(t => t.includes('NOCTERA → ノクテラ')), hist.length);
  await p.screenshot({ path: `${OUT}/${DEV}-8-admin-names.png` });
  const panel = p.locator('.panel', { hasText: 'ハムハム → ハムスター' });
  await panel.locator('button', { hasText: '変更前の名前に戻す' }).click(); await w(200); await panel.locator('button', { hasText: '「ハムハム」に戻す' }).click(); await w(1200);
  d = await db(); ok('10 管理者が元の名前に戻せる（履歴に運営の変更として残る）', d.artists.some(a => a.name === 'ハムハム') && d.history[0].by_admin === true);

  // ---- 11. 未ログインでもアイコンが見える・表示名は見えない
  await logout(); await nav('ホーム'); await w(700);
  ok('11 未ログインでもアイコンが見える', await p.evaluate(() => [...document.querySelectorAll('.cover')].some(c => /blob:|object\/public\/avatars\//.test(c.style.background))));
  ok('11 表示名「りょう」はどこにも表示されない', !(await p.locator('body').innerText()).includes('りょう'));

  ok('エラーなし', errs.length === 0, errs);
  const f = R.filter(r => !r[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  await b.close();
})();
