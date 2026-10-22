# The panda's moves

Each move is one Meshy "3D rigging" run (through Higgsfield, 8 credits each) on the panda's 3D model, with
an animation from Meshy's animation library (https://docs.meshy.ai/en/api/animation-library).
Raw downloads: `rig-<file>.glb` (skeleton and move only). `tools/build-panda.sh` retargets each onto the
panda, puts it on the floor and builds `Resources/characters/panda/model.glb`.

| Move | Meshy animation | File |
|---|---|---|
| Idle | 0 | came with the 3D model (`panda-meshy-ultra.glb`) |
| Sleep | 269 | `rig-sleep.glb` |
| Wake | 346 | `rig-wake.glb` |
| Sit | 363 | `rig-sit.glb` |
| Walk | 613 | `rig-walk.glb` |
| Wave | 290 | `rig-wave.glb` |
| Cheer | 298 | `rig-cheer.glb` |
| Jump | 466 | `rig-jump.glb` |
| Dance | 22 | `rig-dance.glb` |
| Look | 333 | `rig-look.glb` |
| Think | 36 | `rig-think.glb` |
| Shrug | 317 | `rig-no.glb` |
