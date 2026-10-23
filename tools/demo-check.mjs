// Check the browser demo in headless Chrome, on a desktop and a phone screen: the panda loads, the story
// runs to the end (click the panda, click Yes), free play changes the bubble and the mode, a drag moves the
// panda, and nothing logs an error. Screenshots go to build/review/demo/.
//   tools/build-site.sh && node tools/demo-check.mjs
// Needs Playwright (found in the npx cache), like tools/review.mjs.
import { createServer } from 'node:http';
import { readFile, mkdir, readdir } from 'node:fs/promises';
import { extname, join, resolve } from 'node:path';
import { homedir } from 'node:os';

const root = resolve('build/site');
const outDir = resolve('build/review/demo');

const npx = join(homedir(), '.npm/_npx');
let pwPath = null;
for (const d of await readdir(npx)) {
  const p = join(npx, d, 'node_modules/playwright-core/index.mjs');
  try { await readFile(p); pwPath = p; break; } catch { /* keep looking */ }
}
if (!pwPath) throw new Error('playwright-core not found in ~/.npm/_npx (run: npx playwright-core --version)');
const { chromium } = await import(pwPath);

const types = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.json': 'application/json',
  '.glb': 'model/gltf-binary', '.png': 'image/png', '.jpg': 'image/jpeg' };
const server = createServer(async (req, res) => {
  try {
    let path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (path.endsWith('/')) path += 'index.html';
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

let failures = 0;
const check = (ok, what) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) failures += 1;
};

await mkdir(outDir, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true, args: ['--use-angle=metal', '--enable-gpu'] });

const screens = [
  ['desktop', { width: 1440, height: 900 }, 'light'],
  ['phone', { width: 390, height: 844 }, 'dark'],
];
for (const [name, viewport, colorScheme] of screens) {
  const page = await browser.newPage({ viewport, deviceScaleFactor: 2, colorScheme });
  const errors = [];
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) errors.push(`${m.type()}: ${m.text()}`); });
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  page.on('response', (r) => { if (r.status() >= 400) errors.push(`${r.status()}: ${r.url()}`); });
  const demo = (expr) => page.evaluate(expr);
  const shot = (step, opts = {}) => page.screenshot({ path: `${outDir}/${name}-${step}.png`, ...opts });
  // A wait that runs out says what the demo was doing and what it logged, then stops the check.
  const waitFor = async (what, fn, timeout) => {
    try {
      await page.waitForFunction(fn, null, { timeout });
    } catch {
      const state = await demo(() => window.demo && { phase: window.demo.phase, session: window.demo.session('my-app'),
        activity: window.demo.activity, caption: document.querySelector('#caption').textContent }).catch(() => null);
      check(false, `${name}: ${what} (waited ${timeout / 1000} s)\n       demo: ${JSON.stringify(state)}`
        + errors.map((x) => `\n       ${x}`).join('')
        + '\n       If the Mac slept during the check, its timers stopped: run it again with the Mac awake.');
      await browser.close();
      server.close();
      console.log(`demo-check: ${failures} FAILED`);
      process.exit(1);
    }
  };

  await page.goto(`http://localhost:${port}/`);
  await waitFor('the panda loads', () => window.demo?.ready === true, 90000);
  check(true, `${name}: the panda loads`);
  await page.waitForTimeout(1500);
  await shot('1-intro');

  await page.click('#overlay [data-action="play"]');
  await waitFor('story: Claude starts working', () => window.demo.session('my-app') === 'working', 15000);
  check(await demo(() => window.demo.bubble()) === 'working', `${name}: story: the bubble says Working`);
  await waitFor('story: Claude needs you', () => window.demo.session('my-app') === 'needs', 20000);
  await page.waitForTimeout(800);
  check(await demo(() => window.demo.bubble()) === 'needs', `${name}: story: the bubble says Needs you`);
  check(await demo(() => window.demo.front()) === 'Chrome', `${name}: story: the browser is in front`);
  await shot('2-needs');

  const c = await demo(() => window.demo.hitCenter());
  await page.mouse.click(c.x, c.y);
  await page.waitForTimeout(500);
  check(await demo(() => window.demo.front()) === 'Terminal', `${name}: story: a click on the panda brings Terminal to the front`);
  await shot('3-opened');

  await page.click('.ask .opt.first');
  await waitFor('story: Claude finishes', () => window.demo.session('my-app') === 'ready', 15000);
  check(await demo(() => window.demo.bubble()) === 'ready', `${name}: story: the bubble says Your turn`);
  check(await demo(() => window.demo.front()) === 'Chrome', `${name}: story: you went back to the browser while Claude worked`);
  await page.waitForTimeout(900);
  check(await demo(() => window.demo.activity) === 'cheer', `${name}: story: the panda cheers`);
  await shot('4-done');
  await waitFor('story ends in free play', () => window.demo.phase === 'free', 10000);
  check(true, `${name}: story ends in free play`);

  await page.click('[data-session="api-server"][data-state="needs"]');
  await page.waitForTimeout(400);
  check(await demo(() => window.demo.bubble()) === 'needs', `${name}: free play: a second session that needs you shows in the bubble`);
  check(await page.isVisible('#tabs'), `${name}: free play: Terminal shows two tabs`);
  await page.click('[data-session="my-app"][data-state="needs"]');
  await page.waitForTimeout(400);
  check(await page.evaluate(() => document.querySelector('#pet').contentDocument.querySelector('#bubble small').textContent) === '2 sessions',
    `${name}: free play: two sessions that need you show "2 sessions"`);
  await shot('5-two');

  await page.click('[data-mode="sleep"]');
  await page.waitForTimeout(600);
  check(await demo(() => window.demo.activity) === 'sleep', `${name}: free play: Sleep puts the panda to sleep`);
  await page.click('[data-mode="stay"]');
  await page.waitForTimeout(300);
  check(await demo(() => window.demo.activity) === 'wake', `${name}: free play: Stay wakes it up`);
  await page.waitForTimeout(2500);

  // The clicks on the controls can scroll the panda off a phone's screen: bring it back before the drag.
  await demo(() => document.querySelector('#petHit').scrollIntoView({ block: 'center', behavior: 'instant' }));
  const d = await demo(() => window.demo.hitCenter());
  await page.mouse.move(d.x, d.y);
  await page.mouse.down();
  await page.mouse.move(d.x - 60, d.y - 30, { steps: 8 });
  check(await demo(() => window.demo.activity) === 'dragged', `${name}: a drag picks the panda up`);
  await page.mouse.up();
  const e = await demo(() => window.demo.hitCenter());
  check(Math.abs(e.x - (d.x - 60)) < 4 && Math.abs(e.y - (d.y - 30)) < 4, `${name}: the drop puts it where the pointer let go`);
  await page.waitForTimeout(1200);
  await shot('6-page', { fullPage: true });

  check(errors.length === 0, `${name}: no errors or warnings${errors.map((x) => `\n       ${x}`).join('')}`);
  await page.close();
}

await browser.close();
server.close();
console.log(failures ? `demo-check: ${failures} FAILED` : 'demo-check: OK');
process.exit(failures ? 1 : 0);
