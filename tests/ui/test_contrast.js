// 各画面の文字のコントラストを実際の表示から計測（標準テーマ・iPhone/Android）
const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs'), path = require('path');
const [INDEX, DEV, OUT, THEME] = process.argv.slice(2);
const route = r => { const u = r.request().url();
  if (u.startsWith('http://aimuse.test/') && !u.endsWith('.js')) return r.fulfill({ contentType: 'text/html', body: fs.readFileSync(INDEX) });
  if (u.endsWith('/config.js')) return r.fulfill({ contentType: 'text/javascript', body: 'window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k"};' });
  if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
  if (u.includes('react-dom.production') || u.includes('htm.umd')) return r.fulfill({ contentType: 'text/javascript', body: '' });
  if (u.includes('supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
  return r.fulfill({ status: 404, body: '' }); };
const SCAN = () => {
  const parse = c => { const m = (c.match(/[\d.]+/g) || []).map(Number); return { r: m[0], g: m[1], b: m[2], a: m.length > 3 ? m[3] : 1 }; };
  const L = ({ r, g, b }) => { const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
  const cr = (x, y) => { const a = L(x), b = L(y); return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05); };
  const blend = (top, bot) => ({ r: top.r * top.a + bot.r * (1 - top.a), g: top.g * top.a + bot.g * (1 - top.a), b: top.b * top.a + bot.b * (1 - top.a), a: 1 });
  const hex = h => { const n = parseInt(h.slice(1), 16); return { r: n >> 16, g: (n >> 8) & 255, b: n & 255, a: 1 }; };
  // 背景：祖先をたどって色を重ねる。画像（ジャケット等）の上の文字は対象外、グラデーションは全色で最小値
  const bgOf = el => {
    const layers = []; let e = el, grads = null;
    while (e && e.nodeType === 1) {
      const st = getComputedStyle(e);
      const bi = st.backgroundImage;
      if (bi && bi !== 'none') {
        if (/url\(/.test(bi)) return null;
        const cols = (bi.match(/rgba?\([^)]+\)|#[0-9a-f]{6}/gi) || []).map(c => c[0] === '#' ? hex(c) : parse(c));
        if (cols.length && !grads && cols.every(c => c.a > 0.9)) { grads = cols; break; }
        if (cols.length && cols.some(c => c.a < 0.9)) layers.push(...cols.filter(c => c.a > 0).slice(0, 1));
      }
      const bc = parse(st.backgroundColor); if (bc.a > 0) { layers.push(bc); if (bc.a >= 1) break; }
      e = e.parentElement;
    }
    let base = grads || [layers.length && layers[layers.length - 1].a >= 1 ? layers.pop() : parse(getComputedStyle(document.body).backgroundColor)];
    for (let i = layers.length - 1; i >= 0; i--) base = base.map(b => blend(layers[i], b));
    return base;
  };
  const out = [];
  for (const el of document.querySelectorAll('body *')) {
    const own = [...el.childNodes].filter(n => n.nodeType === 3 && n.textContent.trim()).map(n => n.textContent.trim()).join(' ');
    if (!own || !el.getClientRects().length) continue;
    const st = getComputedStyle(el);
    if (st.visibility === 'hidden' || +st.opacity === 0) continue;
    if (el.closest('[disabled],.player .cover,.cover,.tile,.hero,svg,.toast,.feat')) continue;   // 無効ボタン・画像の上の文字・一時表示は対象外
    let op = 1; for (let e = el; e; e = e.parentElement) op *= +getComputedStyle(e).opacity; if (op < 0.99) continue;
    const fs = parseFloat(st.fontSize), bold = +st.fontWeight >= 700, large = fs >= 24 || (fs >= 18.66 && bold);
    let fg = parse(st.color);
    const bgs = bgOf(el); if (!bgs) continue;
    if (fg.a === 0) continue;   // グラデーション文字（装飾）は別途確認
    const ratios = bgs.map(b => cr(fg.a < 1 ? blend(fg, b) : fg, b));
    const r = Math.min(...ratios), need = large ? 3 : 4.5;
    if (r < need) out.push({ text: own.slice(0, 24), cls: (el.className || el.tagName).toString().slice(0, 30), ratio: +r.toFixed(2), need, fs });
  }
  return out;
};
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const dev = DEV === 'android' ? devices['Pixel 7'] : devices['iPhone 13'];
  const ctx = await b.newContext({ ...dev }); const p = await ctx.newPage(); await p.route('**/*', route);
  if (THEME) await p.addInitScript(t => { try { localStorage.setItem('aimuse.theme.guest', t); } catch (e) {} }, THEME);
  const w = ms => p.waitForTimeout(ms || 500), nav = l => p.locator('nav.nav button', { hasText: l }).click();
  const all = {};
  const scan = async name => { all[name] = await p.evaluate(SCAN); await p.screenshot({ path: `${OUT}/${DEV}-c-${name}.png` }); };
  await p.goto('http://aimuse.test/'); await w(1200); await scan('home-guest');
  await nav('検索'); await w(400); await scan('search');
  await nav('マイページ'); await w(400); await scan('me-guest');
  await nav('マイページ'); await p.fill('#a-email', 'ryo@test.jp'); await p.fill('#a-pw', 'password'); await p.locator('.form button.btn.primary').click(); await p.locator('text=ログアウト').waitFor(); await w(700);
  await scan('me-admin');
  await nav('投稿'); await w(400); await scan('upload');
  await nav('ホーム'); await w(400); await scan('home-user');
  await nav('マイページ'); await w(300); await p.locator('button.admin-entry').click(); await w(600); await scan('admin');
  await nav('マイページ'); await w(300); await p.locator('button', { hasText: '設定（カラーテーマ' }).click(); await w(400); await scan('settings');
  await p.locator('button', { hasText: 'アカウントを削除' }).click(); await w(400); await scan('account');
  await nav('ホーム'); await w(300); await p.locator('.row').first().click(); await w(500); await p.locator('[class*=mini]').first().click(); await w(500); await scan('player');
  let n = 0; for (const [k, v] of Object.entries(all)) { n += v.length; console.log(`[${v.length ? 'NG' : 'OK'}] ${k}${v.length ? '  ' + JSON.stringify(v) : ''}`); }
  console.log(`\n[${DEV}${THEME ? ' ' + JSON.parse(THEME).preset : ' standard'}] 基準未満の文字 ${n} 件`);
  await b.close();
})();
