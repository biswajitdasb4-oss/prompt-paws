// Fix the material of a Meshy GLB: Meshy leaves metalness unset (glTF default 1 = metal), roughness 0.41,
// specular x2 and the colour texture as full glow, so fur and cloth look like shiny plastic.
//   node tools/fix-material.mjs in.glb out.glb '{"metallic":0,"roughness":0.85,"specular":null,"emissive":0.25}'
// Rewrites the first material (JSON chunk only; the binary chunk is copied as is).
import { readFileSync, writeFileSync } from 'node:fs';
const [inp, out, optsJson] = process.argv.slice(2);
const o = JSON.parse(optsJson);
const buf = readFileSync(inp);
const jsonLen = buf.readUInt32LE(12);
const j = JSON.parse(buf.subarray(20, 20 + jsonLen).toString('utf8'));
const bin = buf.subarray(20 + jsonLen);
const m = j.materials[0];
m.pbrMetallicRoughness.metallicFactor = o.metallic;
m.pbrMetallicRoughness.roughnessFactor = o.roughness;
if (o.specular == null) {
  delete m.extensions.KHR_materials_specular;
} else {
  m.extensions.KHR_materials_specular.specularColorFactor = [o.specular, o.specular, o.specular];
}
if (!o.emissive) { delete m.emissiveTexture; delete m.emissiveFactor; } else { m.emissiveFactor = [o.emissive, o.emissive, o.emissive]; }
if (o.singleSided) m.doubleSided = false;
const used = new Set();
for (const mat of j.materials) for (const k of Object.keys(mat.extensions || {})) used.add(k);
j.extensionsUsed = [...used];
let js = Buffer.from(JSON.stringify(j), 'utf8');
const pad = (4 - (js.length % 4)) % 4;
js = Buffer.concat([js, Buffer.alloc(pad, 0x20)]);
const head = Buffer.alloc(20);
head.writeUInt32LE(0x46546c67, 0); head.writeUInt32LE(2, 4);
head.writeUInt32LE(20 + js.length + bin.length, 8);
head.writeUInt32LE(js.length, 12); head.writeUInt32LE(0x4e4f534a, 16);
writeFileSync(out, Buffer.concat([head, js, bin]));
console.log('wrote', out, JSON.stringify(m));
