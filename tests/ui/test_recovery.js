// パスワード再設定のリンクで開いたとき、新しいパスワードの入力画面が出ること（iPhone / Android の画面サイズ）
// 本物の supabase-js と同じく、リンクの通知（PASSWORD_RECOVERY）は読み込み直後に1回だけ届く偽物（fake-profile.js）で確認する
// 使い方: node test_recovery.js <index.html> <iphone|android> <画像の保存先>
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const [INDEX, DEV, OUT] = process.argv.slice(2);
const device = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
const R = []; const ok = (name, cond, info) => { R.push([name, !!cond]); console.log(`[${cond ? 'PASS' : 'FAIL'}] ${name}${info !== undefined ? '  → ' + JSON.stringify(info) : ''}`); };
const HAMU = '22222222-2222-4222-8222-222222222222';

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const fresh = async () => {
    const ctx = await b.newContext({ ...device, defaultBrowserType: undefined });
    const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
    await p.route('**/*', r => { const u = r.request().url();
      if (u.startsWith('http://aimuse.test/') && !u.endsWith('.js')) return r.fulfill({ contentType: 'text/html', body: fs.readFileSync(INDEX) });
      if (u.endsWith('/config.js')) return r.fulfill({ contentType: 'text/javascript', body: 'window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k"};' });
      if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
      if (u.includes('react-dom.production') || u.includes('htm.umd')) return r.fulfill({ contentType: 'text/javascript', body: '' });
      if (u.includes('supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
      return r.fulfill({ status: 404, body: '' }); });
    return { ctx, p, errs };
  };
  const w = (p, ms) => p.waitForTimeout(ms || 500);
  const toast = async p => (await p.locator('.toast').innerText().catch(() => '')).trim();

  // ---- 1. 再設定のリンク（#access_token=…&type=recovery）で開く
  let { ctx, p, errs } = await fresh();
  await p.goto(`http://aimuse.test/#access_token=jwt-${HAMU}&refresh_token=r&expires_in=3600&token_type=bearer&type=recovery`); await w(p, 1500);
  ok('1 リンクで開くと「新しいパスワードを設定」の画面が出る', await p.locator('text=新しいパスワードを設定').count() === 1);
  ok('1 マイページのタブが選ばれている', await p.locator('nav.nav button.on', { hasText: 'マイページ' }).count() === 1 || await p.locator('h1', { hasText: 'マイページ' }).count() === 1);
  ok('1 アドレスからログイン情報が消えている', !(await p.evaluate(() => location.hash)).includes('access_token'));
  await p.screenshot({ path: `${OUT}/${DEV}-recovery-1.png` });
  await p.fill('#a-newpw', 'abc'); await p.locator('.form button.btn.primary').click(); await w(p, 400);
  ok('1 6文字未満は変更できず、理由が出る', (await p.locator('.err').innerText().catch(() => '')).includes('6文字以上'));
  await p.fill('#a-newpw', 'new-password-123'); await p.locator('.form button.btn.primary').click(); await w(p, 800);
  const log = await p.evaluate(() => window.__log.filter(x => x.op === 'updateUser'));
  ok('1 新しいパスワードを保存（updateUser が1回呼ばれる）', log.length === 1 && log[0].hasPassword, log);
  ok('1 「パスワードを変更しました」と表示され、入力画面が閉じる', (await toast(p)).includes('パスワードを変更しました') && await p.locator('text=新しいパスワードを設定').count() === 0);
  ok('1 ログインしたままマイページに戻る（ログアウトのボタンがある）', await p.locator('text=ログアウト').count() === 1);
  ok('1 画面の読み込みでエラーが出ない', errs.length === 0, errs);
  await ctx.close();

  // ---- 2. 期限切れ・使用済みのリンク（#error=access_denied&error_code=otp_expired&…）
  ({ ctx, p, errs } = await fresh());
  await p.goto('http://aimuse.test/#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired'); await w(p, 1500);
  const e2 = await p.locator('.err').innerText().catch(() => '');
  ok('2 期限切れのリンクは、ログイン画面に理由と次の操作を表示', e2.includes('有効期限') && e2.includes('パスワードを忘れた場合'), e2);
  ok('2 新しいパスワードの入力画面は出ない', await p.locator('text=新しいパスワードを設定').count() === 0);
  await p.screenshot({ path: `${OUT}/${DEV}-recovery-2.png` });
  await p.locator('nav.nav button', { hasText: 'ホーム' }).click().catch(() => {}); await w(p, 300);
  await p.locator('nav.nav button', { hasText: 'マイページ' }).click(); await w(p, 300);
  ok('2 理由の表示は1回だけ（画面を移動すると消える）', await p.locator('.err').count() === 0);
  ok('2 画面の読み込みでエラーが出ない', errs.length === 0, errs);
  await ctx.close();

  // ---- 3. 通常の起動では入力画面は出ない
  ({ ctx, p, errs } = await fresh());
  await p.goto('http://aimuse.test/'); await w(p, 1200);
  await p.locator('nav.nav button', { hasText: 'マイページ' }).click(); await w(p, 300);
  ok('3 通常の起動では新しいパスワードの画面もエラーも出ない', await p.locator('text=新しいパスワードを設定').count() === 0 && await p.locator('.err').count() === 0);
  ok('3 ログイン画面に「パスワードを忘れた場合」がある', await p.locator('text=パスワードを忘れた場合').count() === 1);
  await ctx.close();

  await b.close();
  const f = R.filter(x => !x[1]); console.log(`\n[${DEV}] 合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log('  FAIL:', x[0]));
  process.exit(f.length ? 1 : 0);
})();
