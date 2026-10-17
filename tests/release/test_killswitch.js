const { chromium, devices } = require('/opt/npm-tools/node_modules/playwright');
const http = require('http'), fs = require('fs'), path = require('path');
const PUB = '/home/claude/aimuse/public', KILL = '/home/claude/aimuse/release/sw_killswitch.js';
let kill = false;
const server = http.createServer((req, res) => { const u = new URL(req.url, 'http://x');
  if (u.pathname === '/config.js') { res.writeHead(200, { 'Content-Type': 'text/javascript' }); return res.end('window.AIMUSE_CONFIG={supabaseUrl:"https://x.supabase.co",supabaseAnonKey:"k"};'); }
  let f = u.pathname === '/sw.js' && kill ? KILL : path.join(PUB, u.pathname === '/' ? 'index.html' : u.pathname);
  if (!fs.existsSync(f)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'Content-Type': f.endsWith('.js') ? 'text/javascript' : f.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream', 'Cache-Control': 'no-cache' }); res.end(fs.readFileSync(f)); });
(async () => {
  await new Promise(r => server.listen(0, r)); const O = `http://localhost:${server.address().port}`;
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const ctx = await b.newContext({ ...devices['iPhone 13'] });
  await ctx.route(/cdnjs|unpkg|jsdelivr/, r => { const u = r.request().url();
    if (u.includes('react.production')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'libs.js')) });
    if (u.includes('supabase')) return r.fulfill({ contentType: 'text/javascript', body: fs.readFileSync(path.join(__dirname, 'fake-profile.js')) });
    return r.fulfill({ contentType: 'text/javascript', body: '' }); });
  await ctx.route(/fonts\./, r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
  const p = await ctx.newPage(); await p.goto(O + '/'); await p.evaluate(() => navigator.serviceWorker.ready); await p.reload(); await p.waitForTimeout(1200);
  await p.evaluate(() => localStorage.setItem('aimuse.theme.guest', JSON.stringify({v:1,preset:'ocean',accent:'#5ab8ff',bg:'#06101e',button:'#2f74ff'})));
  const before = await p.evaluate(async () => ({ reg: !!(await navigator.serviceWorker.getRegistration()), caches: await caches.keys() }));
  kill = true;
  await p.evaluate(async () => { const r = await navigator.serviceWorker.getRegistration(); await r.update(); }); await p.waitForTimeout(2500);
  await p.reload(); await p.waitForTimeout(1500);
  const after = await p.evaluate(async () => ({ reg: !!(await navigator.serviceWorker.getRegistration()), caches: await caches.keys(), theme: localStorage.getItem('aimuse.theme.guest') !== null, app: !!document.querySelector('nav.nav') }));
  const okk = before.reg && before.caches.length === 1 && !after.reg && after.caches.length === 0 && after.theme && after.app;
  console.log(`[${okk ? 'PASS' : 'FAIL'}] 緊急停止用 sw.js：Service Worker と保存が消え、アプリは通常どおり表示・テーマは維持  → ${JSON.stringify({ before, after })}`);
  await b.close(); server.close();
})();
