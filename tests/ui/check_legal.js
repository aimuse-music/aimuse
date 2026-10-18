// 規約・ポリシー・ガイドラインの表示確認（残っている「要確認」と主な記載）。使い方：node check_legal.js <index.html>
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const INDEX = process.argv[2];
const route = r => { const u = r.request().url();
  if (u.startsWith('http://aimuse.test/') && !u.endsWith('.js')) return r.fulfill({ contentType: 'text/html', body: fs.readFileSync(INDEX) });
  if (u.endsWith('/config.js')) return r.fulfill({ contentType: 'text/javascript', body: 'window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k"};' });
  if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
  if (u.includes('react-dom.production') || u.includes('htm.umd')) return r.fulfill({ contentType: 'text/javascript', body: '' });
  if (u.includes('supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
  return r.fulfill({ status: 404, body: '' }); };
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const p = await (await b.newContext({ ...devices['iPhone 13'] })).newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message)); await p.route('**/*', route);
  await p.goto('http://aimuse.test/'); await p.waitForTimeout(1200);
  await p.locator('button[aria-label="案内を閉じる"]').click().catch(() => {});
  await p.locator('nav.nav button', { hasText: 'マイページ' }).click(); await p.waitForTimeout(400);
  await p.locator('button', { hasText: '利用規約' }).first().click(); await p.waitForTimeout(500);
  for (const tab of ['利用規約', 'プライバシー', 'ガイドライン']) {
    const t = p.locator('.legal ~ *, .tabs button').filter({ hasText: tab }).first(); await t.click().catch(() => {}); await p.waitForTimeout(400);
    const txt = await p.locator('article.legal').innerText();
    const marks = await p.locator('article.legal mark.todo').allInnerTexts();
    console.log(tab, '| 要確認:', JSON.stringify(marks), '| 草案表示:', /草案/.test(txt), '| 東京:', txt.includes('日本（東京）'), '| 13歳:', txt.includes('13歳未満'), '| 管轄:', txt.includes('利用者の住所地'), '| SNS:', txt.includes('SNSアカウント'), '| 運営者:', txt.includes('AIMUSE運営事務局'));
  }
  console.log('errors', JSON.stringify(errs)); await b.close();
})();
