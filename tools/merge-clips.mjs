// Add animation clips from other GLBs to a base model, retargeted onto the base skeleton.
//   node tools/merge-clips.mjs [--only-new] base.glb out.glb Sleep:ground=media/panda/rig-sleep.glb [...]
// Each Higgsfield/Meshy "3d_rigging" run builds its own skeleton (same bone names, but joints up to
// 17 cm apart and bone axes up to 158 deg different), so tracks cannot be copied as they are. For every
// frame this takes each bone's world-space rotation away from its own bind pose and applies the same
// rotation to the base bone; the base keeps its bone lengths, only the hips' movement is copied.
// Each run also places the hips at its own height (70 or 88 cm on the same body), so moves float or sink:
// ":ground" moves the hips every frame so the lowest point of the skinned base mesh stays on the floor;
// ":level" uses one offset (from the first frame) so a jump starts on the floor and keeps its air time,
// raising it only where it would sink into the floor.
// Scale tracks are dropped (Meshy's base Idle scales the whole body x1.176). --only-new leaves out the
// base model's own clips (re-add its Idle as Idle:ground=base.glb to get it at true size and grounded).
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import * as THREE from 'three';

const args = process.argv.slice(2);
const onlyNew = args[0] === '--only-new';
const [basePath, outPath, ...clipArgs] = onlyNew ? args.slice(1) : args;
if (!basePath || !outPath || !clipArgs.length) {
  console.error('usage: node tools/merge-clips.mjs [--only-new] base.glb out.glb Name[:ground|:level]=clip.glb [...]');
  process.exit(1);
}
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const HIPS = 'Hips';

// Rest pose of a skeleton: local rotation and translation per node, and world rotations.
function skeleton(doc) {
  const joints = doc.getRoot().listSkins()[0].listJoints();
  const byName = new Map(joints.map((j) => [j.getName(), j]));
  const worldRest = new Map();
  const restWorld = (node) => {
    if (!node) return new THREE.Quaternion();
    if (!worldRest.has(node)) {
      const q = restWorld(node.getParentNode()).clone().multiply(new THREE.Quaternion(...node.getRotation()));
      worldRest.set(node, q);
    }
    return worldRest.get(node);
  };
  joints.forEach(restWorld);
  return { joints, byName, restWorld };
}

// Value of an animation sampler at time t (LINEAR or STEP; rotations are slerped).
function sample(sampler, t, isRot) {
  const times = sampler.getInput().getArray();
  const vals = sampler.getOutput().getArray();
  const n = isRot ? 4 : 3;
  const get = (i) => Array.from(vals.slice(i * n, i * n + n));
  if (t <= times[0]) return get(0);
  if (t >= times[times.length - 1]) return get(times.length - 1);
  let i = 1;
  while (times[i] < t) i++;
  const a = get(i - 1);
  if (sampler.getInterpolation() === 'STEP') return a;
  const b = get(i);
  const f = (t - times[i - 1]) / (times[i] - times[i - 1]);
  if (isRot) return new THREE.Quaternion(...a).slerp(new THREE.Quaternion(...b), f).toArray();
  return a.map((v, k) => v + (b[k] - v) * f);
}

const base = await io.read(basePath);
const buffer = base.getRoot().listBuffers()[0];
const T = skeleton(base);
const hipsT = T.byName.get(HIPS);
const body = skinnedBody(base);
const ownClips = base.getRoot().listAnimations();

// Every 8th vertex of the skinned mesh with its joints and weights, and the floor height (bind pose).
function skinnedBody(doc) {
  const node = doc.getRoot().listNodes().find((n) => n.getMesh() && n.getSkin());
  const prim = node.getMesh().listPrimitives()[0];
  const pos = prim.getAttribute('POSITION').getArray();
  const jnt = prim.getAttribute('JOINTS_0').getArray();
  const wgt = prim.getAttribute('WEIGHTS_0').getArray();
  const skin = node.getSkin();
  const ibm = skin.getInverseBindMatrices().getArray();
  const joints = skin.listJoints();
  const verts = [];
  for (let i = 0; i < pos.length / 3; i += 8) {
    verts.push({ v: new THREE.Vector3(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]), j: Array.from(jnt.slice(i * 4, i * 4 + 4)), w: Array.from(wgt.slice(i * 4, i * 4 + 4)) });
  }
  const bind = joints.map((_, k) => new THREE.Matrix4().fromArray(ibm, k * 16));
  const meshWorld = nodeWorld(node, () => null);
  let floor = Infinity;
  for (let i = 1; i < pos.length; i += 3) floor = Math.min(floor, new THREE.Vector3(pos[i - 1], pos[i], pos[i + 1]).applyMatrix4(meshWorld).y);
  return { verts, bind, joints, floor };
}

// World matrix of a node; `pose(node)` may return { r, t } to replace its rest rotation/translation.
function nodeWorld(node, pose) {
  if (!node) return new THREE.Matrix4();
  const p = pose(node);
  const m = new THREE.Matrix4().compose(new THREE.Vector3(...(p?.t ?? node.getTranslation())),
    p?.r ?? new THREE.Quaternion(...node.getRotation()), new THREE.Vector3(...node.getScale()));
  return nodeWorld(node.getParentNode(), pose).multiply(m);
}

// Lowest point of the skinned body for joint poses `pose`.
function lowestPoint(pose) {
  const cache = new Map();
  const world = (j) => { if (!cache.has(j)) cache.set(j, nodeWorld(j, pose)); return cache.get(j); };
  const mats = body.joints.map((j, k) => world(j).clone().multiply(body.bind[k]));
  let min = Infinity;
  const v = new THREE.Vector3();
  for (const { v: p, j, w } of body.verts) {
    let y = 0;
    for (let k = 0; k < 4; k++) if (w[k]) y += w[k] * v.copy(p).applyMatrix4(mats[j[k]]).y;
    min = Math.min(min, y);
  }
  return min;
}

for (const arg of clipArgs) {
  const [spec, file] = arg.split('=');
  const [name, flag] = spec.split(':');
  const ground = flag === 'ground';
  const level = flag === 'level';
  let levelShift = null;
  const src = await io.read(file);
  const S = skeleton(src);
  const anim = src.getRoot().listAnimations()[0];
  const tracks = new Map();   // "Bone:path" -> sampler
  for (const ch of anim.listChannels()) {
    if (ch.getSampler().getInterpolation() === 'CUBICSPLINE') throw new Error(`${file}: CUBICSPLINE not supported`);
    tracks.set(`${ch.getTargetNode().getName()}:${ch.getTargetPath()}`, ch.getSampler());
  }
  const times = [...new Set([...tracks.values()].flatMap((s) => Array.from(s.getInput().getArray())))].sort((a, b) => a - b);
  const hipsS = S.byName.get(HIPS);
  const scale = hipsT.getTranslation()[1] / hipsS.getTranslation()[1];   // hips height ratio

  const outRot = new Map(T.joints.map((j) => [j, []]));
  const outHips = [];
  const prev = new Map();
  let shiftMin = Infinity;
  let shiftMax = -Infinity;
  for (const t of times) {
    // Source world rotations at time t.
    const srcWorld = new Map();
    const sWorld = (node) => {
      if (!node) return new THREE.Quaternion();
      if (!srcWorld.has(node)) {
        const tr = tracks.get(`${node.getName()}:rotation`);
        const local = new THREE.Quaternion(...(tr ? sample(tr, t, true) : node.getRotation()));
        srcWorld.set(node, sWorld(node.getParentNode()).clone().multiply(local));
      }
      return srcWorld.get(node);
    };
    // Target world rotations: same world-space change from bind pose as the source bone.
    const tgtWorld = new Map();
    const tWorld = (node) => {
      if (!node) return new THREE.Quaternion();
      if (!tgtWorld.has(node)) {
        const s = S.byName.get(node.getName());
        let w;
        if (s && T.byName.get(node.getName()) === node) {
          const delta = sWorld(s).clone().multiply(S.restWorld(s).clone().invert());
          w = delta.multiply(T.restWorld(node));
        } else {
          w = tWorld(node.getParentNode()).clone().multiply(new THREE.Quaternion(...node.getRotation()));
        }
        tgtWorld.set(node, w);
      }
      return tgtWorld.get(node);
    };
    const locals = new Map();
    for (const j of T.joints) {
      const local = tWorld(j.getParentNode()).clone().invert().multiply(tWorld(j));
      const p = prev.get(j);
      if (p && p.dot(local) < 0) local.set(-local.x, -local.y, -local.z, -local.w);   // keep keys continuous
      prev.set(j, local);
      locals.set(j, local);
      outRot.get(j).push(...local.toArray());
    }
    const tr = tracks.get(`${HIPS}:translation`);
    const sp = tr ? sample(tr, t, false) : hipsS.getTranslation();
    const rest = hipsS.getTranslation();
    const hips = hipsT.getTranslation().map((v, k) => v + (sp[k] - rest[k]) * scale);
    if (ground || level) {
      const pose = (n) => (locals.has(n) ? { r: locals.get(n), t: n === hipsT ? hips : undefined } : null);
      const toFloor = body.floor - lowestPoint(pose);   // world units; move the hips by this much
      if (levelShift === null) levelShift = toFloor;
      const dy = ground ? toFloor : Math.max(levelShift, toFloor);   // level: never below the floor
      const parent = nodeWorld(hipsT.getParentNode(), () => null);
      hips[1] += dy / new THREE.Vector3().setFromMatrixScale(parent).y;
      shiftMin = Math.min(shiftMin, dy);
      shiftMax = Math.max(shiftMax, dy);
    }
    outHips.push(...hips);
  }

  const out = base.createAnimation(name);
  const input = base.createAccessor().setType('SCALAR').setArray(new Float32Array(times)).setBuffer(buffer);
  const add = (node, path, type, arr) => {
    const output = base.createAccessor().setType(type).setArray(new Float32Array(arr)).setBuffer(buffer);
    const smp = base.createAnimationSampler().setInput(input).setOutput(output).setInterpolation('LINEAR');
    out.addSampler(smp).addChannel(base.createAnimationChannel().setTargetNode(node).setTargetPath(path).setSampler(smp));
  };
  for (const j of T.joints) add(j, 'rotation', 'VEC4', outRot.get(j));
  add(hipsT, 'translation', 'VEC3', outHips);
  const how = ground ? 'grounded' : 'levelled';
  const grounded = ground || level ? `, ${how} (hips moved ${(shiftMin * 100).toFixed(1)} to ${(shiftMax * 100).toFixed(1)} cm)` : '';
  console.log(`${name}: ${times.length} keys, ${times.at(-1).toFixed(2)} s${grounded}, from ${file}`);
}

if (onlyNew) {
  const data = new Set(ownClips.flatMap((a) => a.listSamplers().flatMap((smp) => [smp.getInput(), smp.getOutput()])));
  ownClips.forEach((a) => a.dispose());
  data.forEach((acc) => acc?.dispose());
}
await io.write(outPath, base);
console.log(`wrote ${outPath}: ${base.getRoot().listAnimations().map((a) => a.getName()).join(', ')}`);
