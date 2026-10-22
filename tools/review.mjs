// Render a character in headless Chrome for review: turntable views + one still per behaviour key.
//   node tools/review.mjs [characterFolderName] [outDir]
// Needs a staged build (./build.sh --web) and Playwright (found in the npx cache).
import { createServer } from 'node:http';
import { readFile, mkdir, readdir } from 'node:fs/promises';
import { extname, join, resolve } from 'node:path';
import { homedir } from 'node:os';

const charName = process.argv[2] || 'robot';
const outDir = resolve(process.argv[3] || `build/review/${charName}`);
const root = resolve('build/Prompt Paws.app/Contents/Resources');

const npx = join(homedir(), '.npm/_npx');
let pwPath = null;
for (const d of await readdir(npx)) {
  const p = join(npx, d, 'node_modules/playwright-core/index.mjs');
  try { await readFile(p); pwPath = p; break; } catch { /* keep looking */ }
}
if (!pwPath) throw new Error('playwright-core not found in ~/.npm/_npx (run: npx playwright-core --version)');
const { chromium } = await import(pwPath);

const types = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.glb': 'model/gltf-binary',
  '.gltf': 'model/gltf+json', '.bin': 'application/octet-stream', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.webp': 'image/webp', '.fbx': 'application/octet-stream', '.ktx2': 'image/ktx2' };
const server = createServer(async (req, res) => {
  try {
    const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const file = resolve(join(root, path));
    if (!file.startsWith(root)) throw new Error('outside');
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[extname(file).toLowerCase()] || 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404); res.end();
  }
}).listen(0);
const port = server.address().port;

await mkdir(outDir, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true, args: ['--use-angle=metal', '--enable-gpu'] });
const page = await browser.newPage({ viewport: { width: 420, height: 420 }, deviceScaleFactor: 2 });
const logs = [];
page.on('console', (m) => logs.push(`${m.type()}: ${m.text()}`));
page.on('pageerror', (e) => logs.push(`pageerror: ${e.message}`));
await page.goto(`http://localhost:${port}/web/index.html?char=../characters/${charName}/`);
await page.waitForFunction(() => window.petReady === true, null, { timeout: 90000 });
// Grey backdrop behind the transparent canvas so the renders are easy to look at.
await page.addStyleTag({ content: 'html,body{background:#6d7178 !important}' });

const keys = await page.evaluate(() => window.pet.keys());
console.log('keys:', JSON.stringify(keys));

const shots = [];
for (const [label, angle] of [['front', 0], ['three-quarter', Math.PI / 4], ['side', Math.PI / 2], ['back', Math.PI]]) {
  await page.evaluate((a) => { window.pet.play('idle', 0); window.pet.face(a); }, angle);
  await page.waitForTimeout(1600);
  const f = join(outDir, `turn-${label}.png`);
  await page.screenshot({ path: f });
  shots.push(f);
}
await page.evaluate(() => window.pet.face(0.5));
for (const k of Object.keys(keys)) {
  await page.evaluate((key) => window.pet.play(key, 0), k);
  await page.waitForTimeout(Math.min(1500, Math.max(500, keys[k].duration * 1000 * 0.6)));
  const f = join(outDir, `key-${k}.png`);
  await page.screenshot({ path: f });
  shots.push(f);
}
// Claude status bubbles and the sleeping z's.
const bubbles = [
  ['needs', { kind: 'needs', text: 'Needs you', sub: 'my-app' }],
  ['ready', { kind: 'ready', text: 'Your turn', sub: 'website' }],
  ['working', { kind: 'working', text: 'Working', sub: '2 sessions' }],
];
for (const [name, s] of bubbles) {
  await page.evaluate((st) => { window.pet.play('idle', 0); window.pet.face(0); window.pet.status(st); }, s);
  await page.waitForTimeout(900);
  const f = join(outDir, `bubble-${name}.png`);
  await page.screenshot({ path: f });
  shots.push(f);
}
await page.evaluate(() => { window.pet.status(null); window.pet.play('sleep', 0); window.pet.setSleeping(true); });
await page.waitForTimeout(2200);
shots.push(join(outDir, 'sleep-zzz.png'));
await page.screenshot({ path: shots.at(-1) });
// Bubble clearance at every app size (Small, Medium, Large): the gap between the bubble's arrow tip and
// the top of the head, measured on pixels (frozen frame, shot without and with the bubble).
const clearance = [];
for (const size of [160, 220, 300]) {
  await page.setViewportSize({ width: size, height: size });
  await page.evaluate(() => { window.pet.setSleeping(false); window.pet.face(0); window.pet.play('idle', 0); window.pet.status(null); });
  await page.waitForTimeout(1500);
  await page.evaluate(() => window.pet.setFps(0));
  const bare = await page.screenshot();
  await page.evaluate(() => window.pet.status({ kind: 'ready', text: 'Your turn', sub: 'my-app' }));
  await page.waitForTimeout(500);
  const f = join(outDir, `bubble-${size}.png`);
  const shown = await page.screenshot({ path: f });
  shots.push(f);
  const gap = await page.evaluate(async ([a, b, scale]) => {
    const pixels = async (b64) => {
      const img = new Image();
      img.src = `data:image/png;base64,${b64}`;
      await img.decode();
      const c = document.createElement('canvas');
      c.width = img.width; c.height = img.height;
      const g = c.getContext('2d');
      g.drawImage(img, 0, 0);
      return g.getImageData(0, 0, c.width, c.height);
    };
    const p = await pixels(a);
    const q = await pixels(b);
    const diff = (d, i, r, g, bl) => Math.abs(d[i] - r) + Math.abs(d[i + 1] - g) + Math.abs(d[i + 2] - bl);
    const [br, bg, bb] = [109, 113, 120];   // the grey backdrop
    let head = -1;
    let tip = -1;
    for (let y = 0; y < p.height; y++) {
      for (let x = 0; x < p.width; x++) {
        const i = (y * p.width + x) * 4;
        if (head < 0 && diff(p.data, i, br, bg, bb) > 40) head = y;
        if (diff(q.data, i, p.data[i], p.data[i + 1], p.data[i + 2]) > 60) tip = y;
      }
    }
    return Math.round((head - tip) / scale);
  }, [bare.toString('base64'), shown.toString('base64'), 2]);
  await page.evaluate(() => window.pet.setFps(30));
  clearance.push([size, gap]);
}
const tight = clearance.filter(([, gap]) => gap < 2);
console.log(`bubble clearance (arrow tip to head, CSS px): ${clearance.map(([s, g]) => `${s}: ${g}`).join(', ')}`
  + (tight.length ? '  FAIL: bubble touches the head' : '  OK'));

await page.waitForTimeout(5500); // let one stats message go out
console.log('console:', logs.length ? `\n  ${logs.join('\n  ')}` : 'clean');
console.log(`wrote ${shots.length} images to ${outDir}`);
await browser.close();
server.close();
