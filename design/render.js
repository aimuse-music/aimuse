const { chromium } = require('/opt/npm-tools/node_modules/playwright');
const fs = require('fs');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const jobs = [['icon.svg', 192, 'icon-192.png'], ['icon.svg', 512, 'icon-512.png'], ['icon-maskable.svg', 512, 'icon-maskable-512.png'],
                ['icon.svg', 180, 'apple-touch-icon.png'], ['icon.svg', 32, 'favicon-32.png']];
  for (const [src, n, out] of jobs) {
    const p = await b.newPage({ viewport: { width: n, height: n }, deviceScaleFactor: 1 });
    const svg = fs.readFileSync(src, 'utf8');
    await p.setContent(`<html><body style="margin:0">${svg.replace('<svg ', `<svg width="${n}" height="${n}" `)}</body></html>`);
    await p.screenshot({ path: '../public/icons/' + out, clip: { x: 0, y: 0, width: n, height: n } });
    await p.close();
  }
  await b.close();
})();
