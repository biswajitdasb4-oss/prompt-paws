// Prompt Paws browser demo.
// The panda is drawn by the app's own renderer (web/pet.js) in an iframe, like the Mac app's see-through
// window. This file plays the other parts: the Mac app's brain (a port of Brain.swift and the bubble rules
// in App.swift), and Claude Code (two pretend sessions, a Terminal window and a short story).

let W = 760;             // stage size in its own pixels (wide layout; phones get a tall one); CSS scales it
let H = 475;
const MENU = 26;         // menu bar height
const PET = 200;         // pet window size (the app has 160, 220 and 300)
const NAP_AFTER = 180;   // seconds without input before the panda naps, as in the app
const CALM = new Set(['idle', 'look', 'think', 'sit', 'walk', 'run', 'follow', 'emote']);
const MOVING = new Set(['walk', 'run', 'follow', 'approach']);

const $ = (sel) => document.querySelector(sel);
const rand = (a, b) => a + Math.random() * (b - a);
const pick = (list) => list[Math.floor(Math.random() * list.length)];
const now = () => performance.now() / 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

const wrap = $('#stageWrap');
const stage = $('#stage');
const frame = $('#pet');
const hitBtn = $('#petHit');
const term = $('#term');
const browser = $('#browser');
const screenEl = $('#screen');
const tabsEl = $('#tabs');

// ---- stage: scale to the page, pointer position in stage pixels ----

let scale = 1;
new ResizeObserver(() => {
  const narrow = wrap.clientWidth < 560;
  stage.classList.toggle('narrow', narrow);
  W = narrow ? 400 : 760;
  H = narrow ? 560 : 475;
  scale = wrap.clientWidth / W;
  stage.style.transform = `scale(${scale})`;
  wrap.style.height = `${Math.round(H * scale)}px`;
  if (ready) {
    feet = clamp(feet);
    place();
  }
}).observe(wrap);

function toStage(e) {
  const r = stage.getBoundingClientRect();
  return { x: (e.clientX - r.left) / scale, y: (e.clientY - r.top) / scale };
}

let mouse = { x: 400, y: 300 };
stage.addEventListener('pointermove', (e) => { mouse = toStage(e); });
let lastInput = now();
for (const type of ['pointermove', 'pointerdown', 'keydown', 'wheel', 'touchstart']) {
  addEventListener(type, () => { lastInput = now(); }, { passive: true });
}

// Windows: a click brings one to the front, and the menu bar shows its app.
let zTop = 2;
function focusWindow(win) {
  win.style.zIndex = String(++zTop);
  $('#appName').textContent = win.dataset.app;
}
for (const win of [term, browser]) win.addEventListener('pointerdown', () => focusWindow(win));

// ---- the renderer (pet.js in the iframe) ----

let pet = null;          // window.pet inside the iframe, once the panda has loaded
let ready = false;
let foot = { x: PET / 2, y: PET * 0.8 };
let hit = { x: 0, y: 0, w: 0, h: 0 };
let bodyHeight = 100;
let walkSpeed = 0.24;
let runSpeed = 0.43;
let keys = {};
let readyResolve;
const petReady = new Promise((r) => { readyResolve = r; });

// pet.js reports to the Mac app through window.webkit.messageHandlers; here they come to this function.
function onPetMessage(msg) {
  if (msg.type === 'layout') {
    foot = msg.foot;
    hit = msg.hit;
    bodyHeight = Math.max(40, msg.height);
    hitBtn.style.width = `${hit.w}px`;
    hitBtn.style.height = `${hit.h}px`;
    place();
  } else if (msg.type === 'finished') {
    clipFinished(msg.key);
  } else if (msg.type === 'loadFailed') {
    showFallback();
  }
}

function webglWorks() {
  try { return !!document.createElement('canvas').getContext('webgl2'); } catch { return false; }
}

function showFallback() {
  $('#loading').hidden = true;
  $('#fallback').hidden = false;
  hitBtn.hidden = true;
}

async function loadPet() {
  const cfg = await (await fetch('characters/panda/character.json')).json();
  walkSpeed = cfg.walkSpeed || walkSpeed;
  runSpeed = cfg.runSpeed || runSpeed;
  frame.addEventListener('load', async () => {
    const win = frame.contentWindow;
    const handler = { postMessage: onPetMessage };
    try {
      if (win.webkit && typeof win.webkit === 'object') win.webkit.messageHandlers = { pet: handler };
      else win.webkit = { messageHandlers: { pet: handler } };
    } catch { /* checked below */ }
    if (win.webkit?.messageHandlers?.pet !== handler) {
      // No way to hear from pet.js: use the layout it reports in Chrome for this window size.
      const k = frame.clientWidth / 200;
      onPetMessage({ type: 'layout', foot: { x: 100 * k, y: 176 * k }, height: 123 * k, hit: { x: 63 * k, y: 54 * k, w: 74 * k, h: 129 * k } });
    }
    const t0 = now();
    while (!win.petReady) {
      if (now() - t0 > 60) { showFallback(); return; }
      await sleep(100);
    }
    pet = win.pet;
    keys = pet.keys();
    win.dispatchEvent(new Event('resize'));   // pet.js reports its layout again, now to us
    ready = true;
    $('#loading').hidden = true;
    hitBtn.hidden = false;
    clip = '';
    facing = 0;
    feet = clamp({ x: W * 0.8, y: H - 24 });
    place();
    start('idle', { for: 1.5 });
    applyFps();
    showBubble();
    readyResolve();
  }, { once: true });
  frame.src = 'web/index.html?char=../characters/panda/';
}

if (webglWorks()) {
  loadPet().catch(showFallback);
} else {
  showFallback();
}

// Stop drawing while the stage is off screen or the tab is hidden (the app does the same when hidden).
let paused = false;
new IntersectionObserver(([e]) => { paused = !e.isIntersecting; applyFps(); }).observe(wrap);
document.addEventListener('visibilitychange', applyFps);
function applyFps() {
  if (!pet) return;
  pet.setFps(paused || document.hidden ? 0 : activity === 'sleep' ? 10 : 30);
}

// ---- the brain (a port of Brain.swift; screen y grows downwards here) ----

let mode = reduceMotion ? 'stay' : 'roam';
let modeBeforeSleep = mode;
let activity = 'idle';
let until = 0;
let target = null;
let feet = { x: 0, y: 0 };
let clip = '';
let facing = 0;
let clicks = 0;
let celebrating = false;
let approached = false;
let followResting = false;
let pressed = false;
let dragging = false;
let dragStart = null;
let dragOffset = null;
let lastTick = now();

function tick() {
  requestAnimationFrame(tick);
  const t = now();
  const dt = Math.min(t - lastTick, 0.1);
  lastTick = t;
  if (!ready || paused || dragging) return;
  const idleFor = t - lastInput;
  if (activity === 'sleep') {
    if (mode !== 'sleep' && idleFor < 1.5) start('wake');   // a nap ends when you are back
    return;                                                 // sleep mode: only you can wake it
  }
  if (mode === 'sleep' && activity !== 'land') return start('sleep');
  if (idleFor > NAP_AFTER && CALM.has(activity)) return start('sleep');
  if (MOVING.has(activity)) move(dt);
  if (t >= until) next();
}
requestAnimationFrame(tick);

function move(dt) {
  const chasing = activity === 'follow' || activity === 'approach';
  const goal = chasing ? besideMouse() : (target ?? feet);
  const dx = goal.x - feet.x;
  const dy = goal.y - feet.y;
  const d = Math.hypot(dx, dy);

  if (activity === 'follow' && followResting) {
    if (d < bodyHeight * 0.5) return;
    followResting = false;
  }
  if (d <= 3) {
    if (activity === 'approach') start('wave');
    else if (activity === 'follow') {
      followResting = true;
      play('idle');
      face(0);
    } else next();
    return;
  }
  const fast = chasing ? d > bodyHeight * 5 : activity === 'run';
  const speed = (fast ? runSpeed : walkSpeed) * bodyHeight;
  const step = Math.min(speed * dt, d);
  feet.x += (dx / d) * step;
  feet.y += (dy / d) * step;
  play(fast ? 'run' : 'walk');
  face(Math.atan2(dx, dy));
  place();
}

// Stand next to the pointer, not on it.
function besideMouse() {
  const side = feet.x < mouse.x ? -1 : 1;
  return clamp({ x: mouse.x + side * bodyHeight * 0.55, y: mouse.y + bodyHeight * 0.45 });
}

function next() {
  if (activity === 'sit') return start('wake');   // stand up before doing anything else
  if (mode === 'sleep') return start('sleep');
  if (celebrating) {
    celebrating = false;
    return start('emote', { key: 'thumbs' });
  }
  if (claude.needs.length) return attention();
  const roam = mode === 'roam';
  const r = Math.floor(Math.random() * 100);
  if (claude.working.length) {
    // Claude is working: stay calm (the bubble says what is going on).
    if (r < 12 && roam) return start('walk', { to: randomPoint(160) });
    if (r < 55) return start('think', { for: rand(3, 6) });
    if (r < 80) return start('look', { for: rand(3, 5) });
    if (r < 90) return start('emote', { key: 'nod' });
    return start('idle', { for: rand(2, 4) });
  }
  if (!roam) {
    if (r < 40) return start('idle', { for: rand(4, 8) });
    if (r < 65) return start('look');
    if (r < 87) return start('sit', { for: rand(15, 40) });
    return start('emote', { key: pick(['nod', 'wave', 'dance', 'thumbs']) });
  }
  if (r < 22) return start('walk', { to: Math.random() < 0.7 ? randomPoint(300) : randomPoint() });
  if (r < 50) return start('idle', { for: rand(3, 8) });
  if (r < 65) return start('look');
  if (r < 80) return start('sit', { for: rand(15, 40) });
  if (r < 84) return start('follow');
  if (r < 87) return start('run', { to: randomPoint(500) });
  return start('emote', { key: pick(['dance', 'jump', 'wave', 'thumbs', 'nod']) });
}

// A session needs you: walk over once (roam mode only), then wave every few seconds.
function attention() {
  if (mode === 'roam' && !approached) {
    approached = true;
    const goal = besideMouse();
    if (Math.hypot(goal.x - feet.x, goal.y - feet.y) > bodyHeight * 1.2) return start('approach');
  }
  if (activity === 'wave') start('idle', { for: rand(3, 5) });
  else start('wave');
}

function claudeChanged(newNeeds, newReady, hadNeeds) {
  if (newNeeds) approached = false;
  if (!ready || dragging || paused || mode === 'sleep' || activity === 'sleep') return;
  if (newNeeds) next();
  else if (newReady) {
    celebrating = true;
    start('cheer', { for: 3.4 });
  } else if (hadNeeds && !claude.needs.length && ['approach', 'wave'].includes(activity)) next();
}

function start(a, o = {}) {
  const t = now();
  activity = a;
  target = o.to ? clamp(o.to) : null;
  followResting = false;
  switch (a) {
    case 'idle': play('idle'); face(0); until = t + (o.for ?? rand(2, 5)); break;
    case 'look': play('look'); face(0); until = t + (o.for ?? rand(3, 5)); break;
    case 'think': play('think'); face(0); until = t + (o.for ?? 4); break;
    case 'sit': play('sit'); face(0); until = t + (o.for ?? rand(15, 40)); break;
    case 'walk':
    case 'run': {
      target = target ?? randomPoint();
      const speed = (a === 'run' ? runSpeed : walkSpeed) * bodyHeight;
      until = t + Math.hypot(target.x - feet.x, target.y - feet.y) / Math.max(speed, 1) + 3;
      break;
    }
    case 'follow': until = t + (o.for ?? rand(6, 10)); break;
    case 'approach': until = t + 20; break;
    case 'sleep': play('sleep'); face(0); until = Infinity; break;
    case 'wake': play('wake', true); face(0); until = t + length('wake') + 0.3; break;
    case 'wave': play('wave', true); face(0); until = t + length('wave') + 0.3; break;
    case 'emote': {
      const k = o.key ?? 'nod';
      play(k, true); face(0); until = t + length(k) + 0.3;
      break;
    }
    case 'cheer': play('cheer'); face(0); until = t + (o.for ?? 3.4); break;
    case 'land': play('land', true); until = t + length('land') + 0.3; break;
    case 'dragged': play('dangle'); face(0); until = Infinity; break;
  }
  pet?.setSleeping(a === 'sleep');
  applyFps();
}

function clipFinished(key) {
  if (key === clip && ['emote', 'land', 'wake', 'wave'].includes(activity)) next();
}

function setMode(m) {
  if (m === 'sleep' && mode !== 'sleep') modeBeforeSleep = mode;
  mode = m;
  updateControls();
  if (!ready || dragging) return;
  if (m === 'sleep') start('sleep');
  else if (activity === 'sleep') start('wake');
  else if (m === 'stay' && MOVING.has(activity)) start('idle', { for: 2 });
}

// ---- click, drag and drop ----

function mouseDown(p) {
  pressed = true;
  dragging = false;
  dragStart = p;
  dragOffset = { x: feet.x - p.x, y: feet.y - p.y };
}

function mouseDragged(p) {
  if (!pressed || !ready) return;
  if (!dragging) {
    if (Math.hypot(p.x - dragStart.x, p.y - dragStart.y) <= 4) return;
    dragging = true;
    start('dragged');
  }
  feet = clamp({ x: p.x + dragOffset.x, y: p.y + dragOffset.y });
  place();
}

function mouseUp() {
  pressed = false;
  if (!ready) return;
  if (dragging) {
    dragging = false;
    start('land');
    return;
  }
  // A session needs you, else it's your turn in one: show the one waiting longest.
  const oldest = (list) => list.slice().sort((a, b) => a.at - b.at)[0];
  const s = oldest(claude.needs) ?? oldest(claude.ready);
  if (s) {
    openSession(s.name);
    if (activity !== 'sleep') start('wave');
  } else clicked();
}

function clicked() {
  if (activity === 'sleep') {
    if (mode === 'sleep') setMode(modeBeforeSleep);
    else start('wake');
    return;
  }
  clicks += 1;
  start('emote', { key: ['wave', 'jump', 'nod', 'dance'][clicks % 4] });
}

hitBtn.addEventListener('pointerdown', (e) => {
  if (!ready || e.button > 0) return;
  e.preventDefault();
  hitBtn.setPointerCapture(e.pointerId);
  mouseDown(toStage(e));
});
hitBtn.addEventListener('pointermove', (e) => { if (pressed) mouseDragged(toStage(e)); });
hitBtn.addEventListener('pointerup', () => { if (pressed) mouseUp(); });
hitBtn.addEventListener('pointercancel', () => { if (pressed) mouseUp(); });
hitBtn.addEventListener('click', (e) => {
  if (e.detail !== 0 || !ready) return;   // pointer clicks are handled above; detail 0 is the keyboard
  pressed = true;
  mouseUp();
});

// ---- drawing helpers ----

function play(key, restart = false) {
  if (key === clip && !restart) return;
  clip = key;
  pet?.play(key);
}

function face(angle) {
  const d = Math.atan2(Math.sin(angle - facing), Math.cos(angle - facing));
  if (Math.abs(d) < 0.05) return;
  facing = angle;
  pet?.face(angle);
}

function length(key) { return keys[key]?.duration ?? 1.5; }

// Where the feet may go: on the stage, with the head and the bubble below the menu bar.
function bounds() {
  const half = Math.max(hit.w / 2, bodyHeight * 0.35);
  return { minX: half, maxX: W - half, minY: MENU + bodyHeight * 1.45 + 2, maxY: H - 4 };
}

function clamp(p) {
  const b = bounds();
  return { x: Math.min(Math.max(p.x, b.minX), b.maxX), y: Math.min(Math.max(p.y, b.minY), b.maxY) };
}

function randomPoint(near) {
  if (near) {
    const r = near * (W / 1440);   // the app's distances are for a real screen
    return clamp({ x: feet.x + rand(-r, r), y: feet.y + rand(-r * 0.6, r * 0.6) });
  }
  const b = bounds();
  return { x: rand(b.minX, b.maxX), y: rand(b.minY, b.maxY) };
}

function place() {
  const x = Math.round(feet.x - foot.x);
  const y = Math.round(feet.y - foot.y);
  frame.style.transform = `translate(${x}px, ${y}px)`;
  hitBtn.style.transform = `translate(${x + hit.x}px, ${y + hit.y}px)`;
}

// ---- Claude Code: two pretend sessions ----

const SCRIPTS = {
  'my-app': {
    ask: 'Add a dark mode switch to the settings page',
    reply: "I'll add a switch to the settings page and remember the choice.",
    reads: [['Read(src/settings.js)', 'Read 84 lines'], ['Read(src/theme.js)', 'Read 31 lines']],
    edit: { file: 'src/settings.js', diff: ['+ <Switch label="Dark mode" checked={dark} onChange={setDark} />'] },
    after: [['Update(src/settings.js)', 'Updated src/settings.js with 12 additions'], ['Bash(npm test)', '24 passed']],
    done: 'Done. The settings page has a dark mode switch, and the choice is saved.',
  },
  'api-server': {
    ask: 'Find out why the login test fails',
    reply: "I'll run the test and read the login code.",
    reads: [['Bash(npm test -- login)', '1 failed: the login expires too early'], ['Read(src/auth.js)', 'Read 112 lines']],
    edit: { file: 'src/auth.js', diff: ['- const LOGIN_TTL = 60', '+ const LOGIN_TTL = 60 * 60'] },
    after: [['Update(src/auth.js)', 'Updated src/auth.js with 1 addition and 1 removal'], ['Bash(npm test -- login)', '6 passed']],
    done: 'Fixed. Logins expired after 60 seconds instead of one hour.',
  },
};

const sessions = {};
for (const name of Object.keys(SCRIPTS)) sessions[name] = { name, state: 'off', at: 0, lines: [], open: false, draft: null, run: 0 };
let claude = summary();
let termTab = 'my-app';

function summary() {
  const list = Object.values(sessions).filter((s) => s.state !== 'off');
  return {
    needs: list.filter((s) => s.state === 'needs'),
    ready: list.filter((s) => s.state === 'ready'),
    working: list.filter((s) => s.state === 'working'),
  };
}

function setSession(name, state) {
  const s = sessions[name];
  if (s.state === state) return;
  const hadNeeds = claude.needs.length > 0;
  const before = s.state;
  s.state = state;
  s.at = now();
  if (state !== 'off') s.open = true;
  claude = summary();
  claudeChanged(state === 'needs' && before !== 'needs', state === 'ready' && before !== 'ready', hadNeeds);
  showBubble();
  updateStatusIcon();
  renderTerm();
  updateControls();
}

// The most useful line for the bubble: needs you > your turn > working (App.swift).
function bubbleFor(c) {
  const who = (list) => (list.length === 1 ? list[0].name : `${list.length} sessions`);
  if (c.needs.length) return { kind: 'needs', text: 'Needs you', sub: who(c.needs) };
  if (c.ready.length) return { kind: 'ready', text: 'Your turn', sub: who(c.ready) };
  if (c.working.length) return { kind: 'working', text: 'Working', sub: who(c.working) };
  return null;
}

function showBubble() { pet?.status(bubbleFor(claude)); }

function updateStatusIcon() {
  const icon = $('#statusIcon');
  const kind = claude.needs.length ? 'needs' : claude.ready.length ? 'ready' : '';
  icon.className = `status-icon ${kind}`;
  icon.querySelector('use').setAttribute('href', kind === 'needs' ? '#i-hand' : kind === 'ready' ? '#i-check' : '#i-paw');
}

// The click on the panda: bring Terminal to the front with that session's tab selected.
let onOpened = null;
function openSession(name) {
  termTab = name;
  focusWindow(term);
  renderTerm();
  term.classList.remove('flash');
  void term.offsetWidth;
  term.classList.add('flash');
  onOpened?.();
}

function push(name, ...lines) {
  sessions[name].lines.push(...lines);
  if (name === termTab) renderTerm();
}
const tool = ([t, out]) => [{ k: 'tool', t }, { k: 'out', t: out }];

// The lines a session shows in a state (free play jumps straight to a state).
function transcript(name, state) {
  const sc = SCRIPTS[name];
  if (state === 'off') return [];
  const lines = [{ k: 'prompt', t: sc.ask }, { k: 'say', t: sc.reply }, ...sc.reads.flatMap(tool)];
  if (state === 'ready') lines.push(...sc.after.flatMap(tool), { k: 'say', t: sc.done });
  return lines;
}

function answer(name, choice) {
  const s = sessions[name];
  if (s.state !== 'needs') return;
  onAnswered?.();
  if (choice === 'no') {
    push(name, { k: 'say', t: "OK, I won't change it. What should I do instead?" });
    setSession(name, 'ready');
    return;
  }
  setSession(name, 'working');
  finishWork(name);
}
let onAnswered = null;

async function finishWork(name) {
  const s = sessions[name];
  const run = ++s.run;
  for (const step of SCRIPTS[name].after) {
    await sleep(1500);
    if (run !== s.run) return;
    push(name, ...tool(step));
  }
  await sleep(1300);
  if (run !== s.run) return;
  push(name, { k: 'say', t: SCRIPTS[name].done });
  setSession(name, 'ready');
}

// ---- the Terminal window ----

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function renderTerm() {
  const names = Object.keys(sessions).filter((n) => n === 'my-app' || sessions[n].state !== 'off');
  if (!names.includes(termTab)) termTab = 'my-app';
  tabsEl.hidden = names.length < 2;
  tabsEl.replaceChildren(...names.map((n) => {
    const b = el('button', n === termTab ? 'on' : '', n);
    b.type = 'button';
    b.addEventListener('click', () => { termTab = n; renderTerm(); });
    return b;
  }));

  const s = sessions[termTab];
  $('#termTitle').textContent = `${termTab} · ${s.open ? 'claude' : 'zsh'}`;
  const out = [];
  if (!s.open) {
    const ln = el('div', 'ln shell', `~/${termTab} $ `);
    ln.append(el('span', 'caret'));
    out.push(ln);
  }
  for (const line of s.lines) {
    if (line.k === 'prompt') out.push(el('div', 'ln prompt', `> ${line.t}`));
    else if (line.k === 'say') {
      const ln = el('div', 'ln say');
      ln.append(el('span', 'dot', '●'), ` ${line.t}`);
      out.push(ln);
    } else if (line.k === 'tool') {
      const [, fn, arg] = line.t.match(/^(\w+)\((.*)\)$/);
      const ln = el('div', 'ln tool');
      ln.append(el('span', 'dot ok', '●'), ' ', el('b', '', fn), `(${arg})`);
      out.push(ln);
    } else if (line.k === 'out') out.push(el('div', 'ln out', `  └ ${line.t}`));
  }
  if (s.open && s.state === 'working') out.push(el('div', 'ln spin', '* Working…'));
  if (s.state === 'needs') out.push(askBox(termTab));
  if (s.open && (s.state === 'ready' || s.state === 'off')) {
    const ln = el('div', 'ln prompt input', `> ${s.draft ?? ''}`);
    ln.append(el('span', 'caret'));
    out.push(ln);
  }
  screenEl.replaceChildren(...out);
  screenEl.scrollTop = screenEl.scrollHeight;
}

function askBox(name) {
  const { file, diff } = SCRIPTS[name].edit;
  const box = el('div', 'ask');
  box.append(el('div', 'ask-title', 'Edit file'), el('div', 'ask-file', file));
  const pre = el('div', 'ask-diff');
  for (const d of diff) pre.append(el('div', d.startsWith('+') ? 'add' : 'del', d));
  box.append(pre, el('div', 'ask-q', `Do you want to make this edit to ${file.split('/').pop()}?`));
  const opts = [['yes', '1. Yes'], ['always', "2. Yes, and don't ask again this session"], ['no', '3. No, and tell Claude what to do instead']];
  for (const [a, label] of opts) {
    const b = el('button', `opt${a === 'yes' ? ' first' : ''}`, label);
    b.type = 'button';
    b.addEventListener('click', () => answer(name, a));
    box.append(b);
  }
  return box;
}

// ---- the story ----

const CANCEL = Symbol('cancel');
let storyRun = 0;
let phase = 'intro';

function setPhase(p) {
  phase = p;
  for (const id of ['intro', 'story', 'free']) $(`#dock-${id}`).hidden = id !== p;
  $('#overlay').hidden = p !== 'intro';
  hitBtn.classList.remove('hint');
}

function caption(text, hint = false) {
  $('#caption').textContent = text;
  hitBtn.classList.toggle('hint', hint);
}

function resetSessions() {
  for (const s of Object.values(sessions)) Object.assign(s, { state: 'off', at: 0, lines: [], open: false, draft: null, run: s.run + 1 });
  claude = summary();
  termTab = 'my-app';
  onOpened = null;
  onAnswered = null;
  showBubble();
  updateStatusIcon();
  renderTerm();
}

async function startStory() {
  const run = ++storyRun;
  const wait = async (ms) => {
    await sleep(ms);
    if (run !== storyRun) throw CANCEL;
  };
  const waitFor = async (cond) => {
    while (!cond()) await wait(100);
  };
  try {
    setPhase('story');
    resetSessions();
    focusWindow(term);
    if (mode === 'sleep') setMode(modeBeforeSleep);
    if (!ready) {
      caption('Loading the panda…');
      await Promise.race([petReady, sleep(60000)]);
      if (run !== storyRun) return;
    }
    const me = sessions['my-app'];
    const sc = SCRIPTS['my-app'];
    me.open = true;
    renderTerm();
    caption('You ask Claude Code for a change in your project.');
    await wait(900);
    me.draft = '';
    for (const ch of sc.ask) {
      me.draft += ch;
      renderTerm();
      await wait(reduceMotion ? 5 : 38);
    }
    await wait(350);
    me.draft = null;
    push('my-app', { k: 'prompt', t: sc.ask });
    setSession('my-app', 'working');
    caption('Claude starts working. The bubble over the panda says so.');
    await wait(1500);
    push('my-app', { k: 'say', t: sc.reply });
    await wait(1600);
    caption('You switch to your browser while Claude works.');
    focusWindow(browser);
    for (const step of sc.reads) {
      await wait(1500);
      push('my-app', ...tool(step));
    }
    await wait(1400);

    let opened = false;
    let answered = false;
    onOpened = () => { opened = true; };
    onAnswered = () => { answered = true; };
    setSession('my-app', 'needs');
    caption('Claude needs your OK to edit a file, but its window is hidden. Click the panda.', true);
    await waitFor(() => opened || answered);
    if (!answered) {
      caption('The panda brought the right Terminal tab to the front. Now answer Claude: click Yes.');
      await waitFor(() => answered);
    }
    hitBtn.classList.remove('hint');
    caption('Claude gets back to work, so you go back to your browser.');
    await wait(1000);
    focusWindow(browser);
    await waitFor(() => me.state === 'ready');
    caption("Claude is done. It's your turn again, and the panda cheers.");
    await wait(4500);
    setPhase('free');
  } catch (e) {
    if (e !== CANCEL) throw e;
  }
}

function skipToFree() {
  storyRun += 1;
  setPhase('free');
  resetSessions();
  for (const s of Object.values(sessions)) s.open = s.name === 'my-app';
  sessions['my-app'].lines = transcript('my-app', 'working');
  setSession('my-app', 'working');
  focusWindow(term);
}

// ---- free play controls ----

function setFromControl(name, state) {
  const s = sessions[name];
  s.run += 1;   // stop any pretend work still running
  s.lines = transcript(name, state);
  s.open = name === 'my-app' || state !== 'off';
  if (state !== 'off') termTab = name;
  setSession(name, state);
  renderTerm();
}

function updateControls() {
  for (const b of document.querySelectorAll('[data-session]')) {
    b.setAttribute('aria-pressed', String(sessions[b.dataset.session].state === b.dataset.state));
  }
  for (const b of document.querySelectorAll('[data-mode]')) {
    b.setAttribute('aria-pressed', String(mode === b.dataset.mode));
  }
}

for (const b of document.querySelectorAll('[data-session]')) {
  b.addEventListener('click', () => setFromControl(b.dataset.session, b.dataset.state));
}
for (const b of document.querySelectorAll('[data-mode]')) {
  b.addEventListener('click', () => setMode(b.dataset.mode));
}
for (const b of document.querySelectorAll('[data-action="play"]')) {
  b.addEventListener('click', () => {
    const r = wrap.getBoundingClientRect();
    if (r.top < 0 || r.bottom > innerHeight) wrap.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'center' });
    startStory();
  });
}
for (const b of document.querySelectorAll('[data-action="free"]')) b.addEventListener('click', skipToFree);

resetSessions();
setPhase('intro');
updateControls();
focusWindow(term);

// For tools/demo-check.mjs: read-only views of the state.
window.demo = {
  get ready() { return ready; },
  get phase() { return phase; },
  get activity() { return activity; },
  get mode() { return mode; },
  bubble: () => pet?.bubbleKind() ?? '',
  session: (name) => sessions[name].state,
  front: () => $('#appName').textContent,
  layout: () => ({ foot, hit, bodyHeight }),
  hitCenter: () => {
    const r = hitBtn.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  },
};
