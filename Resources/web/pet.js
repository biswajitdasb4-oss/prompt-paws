// Prompt Paws renderer. It draws the character and plays its clips.
// The Swift app (the "brain") decides where the pet goes and which clip plays, via window.pet.*.
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

const native = (msg) => {
  try { window.webkit.messageHandlers.pet.postMessage(msg); } catch (_) { /* opened in a normal browser */ }
};

for (const level of ['log', 'warn', 'error']) {
  const orig = console[level].bind(console);
  console[level] = (...args) => { orig(...args); native({ type: 'log', level, text: args.map(String).join(' ') }); };
}
addEventListener('error', (e) => native({ type: 'log', level: 'error', text: `${e.message} (${e.filename}:${e.lineno})` }));
addEventListener('unhandledrejection', (e) => native({ type: 'log', level: 'error', text: `unhandled: ${e.reason?.stack || e.reason}` }));

// Every behaviour key the brain may ask for, and what to use when a character has no clip for it.
const FALLBACK = {
  idle: [], walk: ['idle'], run: ['walk'], sit: ['idle'], sleep: ['sit', 'idle'], wake: ['idle'],
  look: ['idle'], think: ['look', 'idle'], nod: ['idle'], no: ['idle'], busy: ['run', 'walk'],
  wave: ['idle'], jump: ['idle'], dance: ['idle'], cheer: ['dance', 'jump', 'wave'],
  thumbs: ['wave', 'idle'], dangle: ['idle'], land: ['jump', 'idle'],
};
// Keys that play once and then report 'finished' (unless character.json says otherwise).
const ONCE = new Set(['wake', 'nod', 'no', 'wave', 'jump', 'thumbs', 'land']);
// If these keys end up on the idle clip, the pet slowly turns its body to look around instead.
const SWAY = new Set(['look', 'think']);

const FOV = 30;          // camera field of view (degrees)
const FILL = 0.62;       // model height as a share of the view height (the rest is room for jumps)
const AIM_Y = 0.62;      // camera looks at this height (model is 1 unit tall, feet at 0)

const canvas = document.getElementById('c');
const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true, powerPreference: 'low-power' });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.NeutralToneMapping;

const scene = new THREE.Scene();
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
scene.environmentIntensity = 0.55;
pmrem.dispose();

const key = new THREE.DirectionalLight(0xfff2e2, 2.2);
key.position.set(-1.6, 2.6, 2.6);
const rim = new THREE.DirectionalLight(0xd6e6ff, 1.6);
rim.position.set(2.2, 2.0, -2.4);
scene.add(key, rim, new THREE.HemisphereLight(0xffffff, 0x3a3a40, 0.5));

const camera = new THREE.PerspectiveCamera(FOV, 1, 0.05, 50);
const dist = (1 / FILL) / (2 * Math.tan(THREE.MathUtils.degToRad(FOV / 2)));
camera.position.set(0, AIM_Y + 0.12, dist);
camera.lookAt(0, AIM_Y, 0);

// Soft contact shadow under the feet (a blurred disc, cheaper and softer than a real shadow map).
const shadow = (() => {
  const c = document.createElement('canvas');
  c.width = c.height = 128;
  const g = c.getContext('2d');
  const grad = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  grad.addColorStop(0, 'rgba(0,0,0,0.55)');
  grad.addColorStop(0.55, 'rgba(0,0,0,0.22)');
  grad.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = grad;
  g.fillRect(0, 0, 128, 128);
  const m = new THREE.Mesh(
    new THREE.PlaneGeometry(0.75, 0.75),
    new THREE.MeshBasicMaterial({ map: new THREE.CanvasTexture(c), transparent: true, depthWrite: false }),
  );
  m.rotation.x = -Math.PI / 2;
  m.position.y = 0.002;
  m.renderOrder = -1;
  return m;
})();
scene.add(shadow);

const pivot = new THREE.Group();   // turns to face the walking direction
scene.add(pivot);

let cfg = {};
let mixer = null;
let resolved = {};                 // behaviour key -> { clip, once, speed, sway }
let current = null;
let currentKey = '';
let baseBox = null;                // model bounds in pivot space (for the click box)
const faceMeshes = [];             // meshes with morph targets (facial expressions)
let faceTarget = {};

const bubble = document.getElementById('bubble');
const zzz = document.getElementById('zzz');
let headBone = null;               // for the sleeping z's
let bubbleAnchor = { x: innerWidth / 2, y: 40 };
let sleeping = false;

let yaw = 0;
let yawTarget = 0;
let sway = false;
let swayAmt = 0;
let lastReportYaw = 1e9;

function resolveKey(k, byName, depth = 0) {
  if (depth > 6) return null;
  const spec = cfg.clips?.[k];
  const s = typeof spec === 'string' ? { clip: spec } : spec;
  if (s?.clip && byName[s.clip]) {
    return { clip: byName[s.clip], once: s.once ?? ONCE.has(k), speed: s.speed ?? 1, fade: s.fade, sway: false };
  }
  for (const fb of FALLBACK[k] || []) {
    const r = resolveKey(fb, byName, depth + 1);
    if (r) return { ...r, once: s?.once ?? ONCE.has(k), sway: SWAY.has(k) && !cfg.clips?.[k] };
  }
  return null;
}

function project(v) {
  const p = v.clone().project(camera);
  return { x: (p.x + 1) / 2 * innerWidth, y: (1 - p.y) / 2 * innerHeight };
}

// Tell the app where the feet are and which area of the window is "the pet" (clicks there are ours).
function report() {
  if (!baseBox) return;
  pivot.updateMatrixWorld(true);
  let minX = Infinity; let minY = Infinity; let maxX = -Infinity; let maxY = -Infinity;
  for (const x of [baseBox.min.x, baseBox.max.x]) {
    for (const y of [baseBox.min.y, baseBox.max.y]) {
      for (const z of [baseBox.min.z, baseBox.max.z]) {
        const p = project(new THREE.Vector3(x, y, z).applyMatrix4(pivot.matrixWorld));
        minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
        minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
      }
    }
  }
  const foot = project(new THREE.Vector3(0, 0, 0));
  const head = project(new THREE.Vector3(0, 1, 0));
  // Shrink the box a little so clicks right next to the pet still reach the app below.
  const padX = (maxX - minX) * 0.1;
  const padY = (maxY - minY) * 0.04;
  native({
    type: 'layout',
    foot,
    height: foot.y - head.y,
    hit: { x: minX + padX, y: minY + padY, w: maxX - minX - 2 * padX, h: maxY - minY - 2 * padY },
  });
  lastReportYaw = yaw;
  bubbleAnchor = { x: (minX + maxX) / 2, y: minY };   // top of the head in the idle pose
  placeBubble();
}

// Keep the bubble above the head and fully inside the window.
const BUBBLE_GAP = 9;   // px from the bubble's bottom edge to the head: 5 for the arrow, 4 of air
function placeBubble() {
  if (bubble.hidden) return;
  const w = bubble.offsetWidth;
  const h = bubble.offsetHeight;
  const x = Math.min(Math.max(bubbleAnchor.x, w / 2 + 2), innerWidth - w / 2 - 2);
  const y = Math.max(bubbleAnchor.y - BUBBLE_GAP, h + 2);
  bubble.style.left = `${x}px`;
  bubble.style.top = `${y}px`;
}

function updateZzz() {
  zzz.hidden = !(sleeping && bubble.hidden);
}

const headPos = new THREE.Vector3();
const ZZZ_LIFT = new THREE.Vector3(0.12, 0.28, 0);
function placeZzz() {
  if (zzz.hidden) return;
  let p = { x: bubbleAnchor.x, y: bubbleAnchor.y + 10 };
  if (headBone) p = project(headBone.getWorldPosition(headPos).add(ZZZ_LIFT));   // a little above the head
  zzz.style.left = `${p.x + 6}px`;
  zzz.style.top = `${p.y}px`;
}

function layout() {
  renderer.setSize(innerWidth, innerHeight, false);
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  report();
  render();
}
addEventListener('resize', layout);

function setFace(map) {
  faceTarget = map || {};
}

function render() {
  renderer.render(scene, camera);
}

// ---- render loop with a frame cap (keeps an old dual-core Mac cool) ----
let fps = 30;
let raf = 0;
let last = 0;
let frames = 0;
let busyMs = 0;
let statsAt = performance.now();

function frame(now) {
  raf = requestAnimationFrame(frame);
  if (now - last < 1000 / fps - 3) return;
  const dt = Math.min((now - last) / 1000, 0.1);
  last = now;
  const t0 = performance.now();

  if (mixer) mixer.update(dt);

  const d = ((yawTarget - yaw + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI;
  yaw += d * Math.min(1, dt * 7);
  swayAmt += ((sway ? 1 : 0) - swayAmt) * Math.min(1, dt * 2);
  pivot.rotation.y = yaw + Math.sin(now / 1000 * 0.8) * 0.65 * swayAmt;

  for (const m of faceMeshes) {
    for (const [name, i] of Object.entries(m.morphTargetDictionary)) {
      const target = faceTarget[name] || 0;
      m.morphTargetInfluences[i] += (target - m.morphTargetInfluences[i]) * Math.min(1, dt * 6);
    }
  }

  if (Math.abs(yaw - lastReportYaw) > 0.12 || swayAmt > 0.05) report();
  render();
  placeZzz();

  frames += 1;
  busyMs += performance.now() - t0;
  if (now - statsAt > 5000) {
    native({ type: 'stats', fps: +(frames * 1000 / (now - statsAt)).toFixed(1), ms: +(busyMs / Math.max(frames, 1)).toFixed(2) });
    frames = 0; busyMs = 0; statsAt = now;
  }
}

// ---- API used by the Swift app ----
window.pet = {
  play(k, fade) {   // fade: blend seconds; default: the clip's "fade" in character.json, else 0.3
    const r = resolved[k];
    if (!r || !mixer) return false;
    const action = mixer.clipAction(r.clip);
    if (action === current && k === currentKey && !r.once) return true;
    action.reset();
    action.enabled = true;
    action.setEffectiveTimeScale(r.speed);
    action.setEffectiveWeight(1);
    action.setLoop(r.once ? THREE.LoopOnce : THREE.LoopRepeat, Infinity);
    action.clampWhenFinished = r.once;
    if (current && current !== action) action.crossFadeFrom(current, fade ?? r.fade ?? 0.3, false);
    action.play();
    current = action;
    currentKey = k;
    sway = r.sway;
    setFace(cfg.faces?.[k]);
    return true;
  },
  face(angle) { yawTarget = angle; },
  setFps(n) {
    fps = n;
    if (n <= 0) {
      cancelAnimationFrame(raf);
      raf = 0;
    } else if (!raf) {
      last = performance.now();
      raf = requestAnimationFrame(frame);
    }
  },
  keys() { return Object.fromEntries(Object.entries(resolved).map(([k, r]) => [k, { clip: r.clip.name, once: r.once, duration: r.clip.duration / r.speed }])); },
  // Claude status bubble: null, or { kind: 'needs' | 'ready' | 'working', text, sub }.
  status(s) {
    if (!s) {
      bubble.hidden = true;
      bubble.dataset.kind = '';
      updateZzz();
      return;
    }
    const isNew = bubble.hidden || bubble.dataset.kind !== s.kind;
    bubble.className = s.kind;
    bubble.dataset.kind = s.kind;
    bubble.querySelector('b').textContent = s.text;
    const sub = bubble.querySelector('small');
    sub.textContent = s.sub || '';
    sub.hidden = !s.sub;
    bubble.hidden = false;
    if (isNew) {
      bubble.classList.add('pop');
      setTimeout(() => bubble.classList.remove('pop'), 300);
    }
    placeBubble();
    updateZzz();
  },
  setSleeping(on) {
    sleeping = on;
    updateZzz();
    placeZzz();
  },
  bubbleKind() { return bubble.hidden ? '' : bubble.dataset.kind; },
  zzzShown() { return !zzz.hidden; },
};

// Box around the skinned mesh as it looks while `clip` plays (a few samples), or as stored without one.
function poseBox(root, clip) {
  const box = new THREE.Box3();
  const m = clip && new THREE.AnimationMixer(root);
  if (m) m.clipAction(clip).play();
  for (let i = 0; i < (m ? 6 : 1); i++) {
    if (m) m.setTime((clip.duration * i) / 6);
    root.updateMatrixWorld(true);
    box.union(new THREE.Box3().setFromObject(root, true));
  }
  if (m) { m.stopAllAction(); m.uncacheRoot(root); }
  return box;
}

// ---- load the character ----
async function load() {
  const params = new URLSearchParams(location.search);
  const base = new URL(params.get('char') || '../characters/robot/', location.href);
  cfg = await (await fetch(new URL('character.json', base))).json();
  const url = new URL(cfg.model, base).href;

  let root;
  let clips;
  if (/\.fbx$/i.test(cfg.model)) {
    root = await new FBXLoader().loadAsync(url);
    clips = root.animations;
  } else {
    const gltf = await new GLTFLoader().loadAsync(url);
    root = gltf.scene;
    clips = gltf.animations;
  }

  root.traverse((o) => {
    if (!headBone && /head$/i.test(o.name) && !o.isMesh) headBone = o;
    if (o.isMesh) {
      o.frustumCulled = false; // skinned meshes move outside their bind-pose bounds
      if (o.morphTargetDictionary && o.morphTargetInfluences) faceMeshes.push(o);
    }
  });

  // Normalise: 1 unit tall, feet on the floor, centred, measured in the idle pose (the pose stored in
  // the file can be shorter or taller: the panda grows ~10% when its Idle plays).
  const byName = Object.fromEntries(clips.map((c) => [c.name, c]));
  root.rotation.y = cfg.facing || 0;
  const box = poseBox(root, resolveKey('idle', byName)?.clip);
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  const s = (cfg.scale || 1) / size.y;
  root.scale.multiplyScalar(s);
  root.position.set(-center.x * s, -box.min.y * s + (cfg.yOffset || 0), -center.z * s);
  pivot.add(root);
  pivot.updateMatrixWorld(true);
  baseBox = new THREE.Box3(box.min.clone().multiplyScalar(s).add(root.position),
    box.max.clone().multiplyScalar(s).add(root.position));

  mixer = new THREE.AnimationMixer(root);
  mixer.addEventListener('finished', (e) => {
    if (e.action === current) native({ type: 'finished', key: currentKey });
  });
  for (const k of Object.keys(FALLBACK)) {
    const r = resolveKey(k, byName);
    if (r) resolved[k] = r;
  }

  layout();
  window.pet.play('idle', 0);
  window.pet.setFps(fps);
  native({
    type: 'ready',
    name: cfg.name || 'Pet',
    credit: cfg.credit || '',
    walkSpeed: cfg.walkSpeed || 0.9,
    runSpeed: cfg.runSpeed || 2.2,
    clips: clips.map((c) => c.name),
    keys: window.pet.keys(),
  });
  window.petReady = true;
}

load().catch((e) => {
  console.error(`load failed: ${e?.stack || e}`);
  native({ type: 'loadFailed', text: String(e?.message || e) });
});
