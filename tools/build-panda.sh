#!/bin/bash
# Build Resources/characters/panda/model.glb from the Higgsfield downloads in media/panda/ (free, local):
# retarget every move onto the base model, fix Meshy's material, WebP texture at 1K.
#   tools/build-panda.sh
set -euo pipefail
cd "$(dirname "$0")/.."
M=media/panda
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Clip name in the model (:ground = feet or body on the floor every frame, :level = keeps its air time)
# = file media/panda/rig-<file>.glb (one 3d_rigging run each; ids in README). Idle comes from the base.
clips=("Idle:ground=$M/panda-meshy-ultra.glb")
for pair in Sleep:ground:sleep Wake:ground:wake Sit:ground:sit Walk:ground:walk Wave:ground:wave \
            Cheer:ground:cheer Jump:level:jump Dance:ground:dance Look:ground:look Think:ground:think Shrug:ground:no; do
  IFS=: read -r name mode file <<< "$pair"
  f="$M/rig-$file.glb"
  if [[ -f $f ]]; then clips+=("$name:$mode=$f"); else echo "skip $name: no $f"; fi
done

node tools/merge-clips.mjs --only-new "$M/panda-meshy-ultra.glb" "$TMP/merged.glb" "${clips[@]}"
node tools/fix-material.mjs "$TMP/merged.glb" "$TMP/fixed.glb" '{"metallic":0,"roughness":0.85,"specular":null,"emissive":0.25}' >/dev/null
npx -y @gltf-transform/cli@4 webp "$TMP/fixed.glb" "$TMP/webp.glb" --quality 90
npx -y @gltf-transform/cli@4 resize "$TMP/webp.glb" Resources/characters/panda/model.glb --width 1024 --height 1024
ls -la Resources/characters/panda/model.glb
