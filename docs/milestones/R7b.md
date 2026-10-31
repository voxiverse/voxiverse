# R7b: two-phase occlusion culling in the frame

The second occlusion row ([R7](R7.md), R7b; split by #87). Arc rules:
[R.md](R.md#rules-for-every-r-milestone).

**Why.** 72% of the chunks drawn at the spawn cover no pixel. R7 built the depth pyramid
(`client/render/hiz.odin`), the test (`occlusion.glsl`, `occlusion_reference`) and split the
frame's rendering after the world; R7b uses them to draw only what can be seen, with no frame
ever missing a visible chunk.

**What this builds on:** R6's cull pass (`world_cull.comp`, `Cull_Record`, the dense `live`
table, the cutout prefix, `CULL_RUNS` commands at fixed places, `Cull_Stats` read back
`FRAMES_IN_FLIGHT` frames late, `--check cull` and `cull_reference`); R7's `Hiz`, `hiz_build`,
rendering A and B, scene counts; `debug.occlusion_stats` (`client/settings.odin`), the
occlusion queries in `World_Frame.queries`.

**Checked against the code (2026-10-30, #87; corrections to the old R7 text):**

- **Visibility bits are per pool slot, not per dense place.** `Cull_Stats.visible` today is
  a bit per place in `live`, and a place changes meaning whenever `live_swap` moves a record.
  The bit a mesh carries from one frame to the next is kept per pool slot
  (`Cull_Record.slot`), in a device-local buffer of its own, never read by the CPU.
- **"No popping" needs more than `images`.** The old exit check named only `images`; a still
  scene never shows a chunk missing for one frame after a turn. Added: scenes with motion
  whose baselines are accepted **before** culling is switched on, and `--check occlusion`,
  which counts every chunk culled while a pixel of it could be seen.
- `gpu_world` is the sum of the frame's sections named `world` (timing sums same-named
  sections per frame), so phase 1 and phase 2 draws are both in it; `gpu_cull` likewise
  sums both culling dispatches.

## Design (R7b)

### The two phases

Per frame, in this order:

1. **Cull, phase 1** (before rendering, where `world_cull` dispatches now): a mesh gets its
   commands when it is in the frustum, can face the camera (as now) **and its slot's
   visibility bit is set** (it was seen last frame); otherwise its commands draw nothing.
2. **Rendering A**: `world_draw` of phase 1's commands (opaque, cutout).
3. **The pyramid** (R7) from that depth.
4. **Cull, phase 2** (compute): every mesh in the frustum is tested against the pyramid
   (`occluded`); its slot's bit becomes "not occluded"; it gets phase-2 commands when it is
   not occluded and its bit **was not** set before (phase 1 did not draw it). A mesh outside
   the frustum gets its bit cleared. Phase 2 writes its own command region (the commands
   buffer doubles: phase 1's, then phase 2's, each `CULL_LAYERS * CULL_RUNS` per mesh).
5. **Rendering B**: `world_draw` of phase 2's commands first, then everything after as R7
   left it.

A new mesh's bit starts clear (its slot's bit is zeroed by the upload's copy of its
`Chunk_Draw`), so it is tested in phase 2 in the frame it first appears. A camera cut (a
teleport, a respawn) costs one frame of everything in phase 2: still correct, measured by the
`flight` p99. Water is not occlusion-culled (the CPU's sorted list, as now).

### The shader and its twin

- `world_cull.comp` gains `phase` (push constant), the visibility buffer's address and
  `Hiz_Info`; `Cull_Push` grows to match (the 128-byte push block has room: today 40 bytes).
  The rules are in one function per phase so `cull_reference` (CPU) mirrors them:
  `cull_reference(r, planes, eye, camera_chunk, phase, bit_before, hiz) -> (commands, stats,
  bit_after)`.
- `Cull_Stats` gains `occluded` (meshes in the frustum the test hid), `late` (meshes drawn by
  phase 2) and keeps `drawn`, `triangles`, `commands` summed over both phases; the in-view bits
  become the drawn bits (phase 1 or 2), per dense place as now (the statistics' queries and
  F3 read them).

### Metrics and the overlay

`chunks_occluded` (`Chunks_Occluded`, per frame: `occluded`), `chunks_late`
(`Chunks_Late`: `late`); `world_meshes` is meshes drawn in either phase. F3's `render:` line
shows `occluded` and `late`. Scene counts gain `chunks_occluded ~1%` and `chunks_late` (exact in
a still scene: 0 once settled).

### False occlusion, counted (`debug.occlusion_verify`, `--check occlusion`)

`debug.occlusion_stats` is replaced by `debug.occlusion_verify`: phase 2 also writes, per
mesh, a **verify command** (its opaque and cutout runs, drawn only when the mesh was occluded
this frame); in rendering B, right after the world's phase-2 draws and before anything else
changes depth, the opaque pipeline with colour writes off and depth writes off (a pipeline
variant `world verify`) draws each place's verify command inside its own occlusion query
(`OCCLUSION_QUERIES` per frame at most, the places beyond it counted as unverified). A query
with samples is a **false occlusion**: a chunk hidden while a pixel of it was in front of the
world's depth. The results are read when the slot comes round (as the statistics' queries are
now) and logged with the chunk's position. The old per-mesh nearest-first draw path and its
`near_first` keys are removed.

`--check occlusion` (`client/occlusion_check.odin`, a row of `CHECKS`, a CI step on
lavapipe): in the scratch world with `debug.occlusion_verify 1`, a fixed route of 600 frames
that walks out of a cave mouth, turns 360 degrees in 2 seconds on a hilltop, flies through a
ceiling and teleports twice; fails on any false occlusion, on an unverified place, or when
fewer than 20% of the meshes in the frustum were occluded over the route (not a test of
culling).

### Scenes with motion (`images`)

Added in this row's **first commit, on the code before culling** (so their baselines are what
an uncull'd frame shows): `turn: look 0 0; wait 3; look 120 0` (the picture two frames after
a fast turn), `rise: /tp 24.5 -26 10.5 0 0; wait 3; /tp 24.5 30 10.5 0 -20` (out of the cave
to the surface in one frame), `wall: /fill 18 8 2 30 20 2 stone; /tp 24.5 12 6 180 0; wait 3;
look 0 0` (turning away from a wall that hid everything). The `look` and `/tp` commands take
effect in the next frame and the scene's `SCENE_AFTER` waits ten frames, so each scene's
picture is drawn after the visibility bits of the old view: if phase 2 ever missed a chunk, it
is missing from the picture. With culling on, every scene passes unchanged; no picture is
re-accepted in this row. Exact `wait` frame counts are set in the first commit so the picture
falls in the second frame after the motion (`wait_world` excepted).

### Synchronization

Phase 1's commands → indirect read (as now); depth writes in A → the pyramid's sampled read
(R7); the pyramid's storage writes → phase 2's sampled read (compute → compute); phase 2's
writes to the commands and the visibility buffer → indirect read in B and phase 1's read next
frame (the buffer is shared by both frame slots: phase 1 of frame N+1 runs after phase 2 of
frame N on the one queue; the barrier at the top of `cull_dispatch` gains the visibility
buffer's write → read). Checked by synchronization validation on `--check occlusion` and
`--check blast`.

## The order of the steps (R7b)

1. The three motion scenes and their baselines on the code as it is (one commit).
2. The visibility buffer, its clearing on upload; `cull_reference` with phases; `--check cull`
   extended: for each of its four cameras, the two phases against a pyramid built by
   `hiz_reference` from a CPU raster of its 343 chunks, with random bits before; every command,
   bit and count equal.
3. `world_cull.comp`'s phases, the doubled commands, the frame's order; `images` (unchanged).
4. The statistics, metrics, F3, scene counts accepted (`chunks_occluded`, `chunks_late`).
5. `debug.occlusion_verify`, the `world verify` pipeline, `--check occlusion`, the CI step; the
   old statistics path removed.
6. Measurement; docs/debugging.md; the cost table; history.md (R7 and R7b's specs appended,
   their files removed).

## Tests (R7b)

- `--check cull` (extended, CI) and `--check occlusion` (new, CI), both under validation.
- `images`: the eleven scenes and the three motion scenes unchanged, with counts.
- `client/render/render_test.odin`: `test_cull_reference_phases`: a mesh seen last frame is
  drawn in phase 1 and not in phase 2; a mesh not seen is drawn in phase 2 only when not
  occluded; a mesh out of the frustum clears its bit; a new slot starts clear; a slot reused
  by another mesh starts clear.
- `test_occlusion_is_conservative` (R7) unchanged.

## Benchmarks (R7b)

`bench compare <the commit before R7b> views`, `views-far`, `flight`:

| Metric | Target |
|---|---|
| `views` `gpu_world` | at most 60% of the commit before R7b's (p < 0.05) |
| `views` `gpu_frame` | lower (p < 0.05): the culling's own cost (`gpu_cull` both phases, `gpu_hiz`) is inside it |
| `views-far` `gpu_world`, `chunks_occluded` | reported (the far view is where occlusion grows) |
| `flight` frame p99 and worst | not worse (no rise with p < 0.05) |
| `views` `gpu_cull` | reported, both phases |

## Left out (R7b)

Occlusion culling of water, entities and held items (few; R15 may); occlusion inside a chunk
(per face group or per run); temporal reprojection of the last frame's depth; the read-back
visibility bits for the CPU's water list.

## Exit check (R7b)

**Gated in CI:** `--check occlusion` (no false occlusion over the route, at least 20% occluded)
and the extended `--check cull` pass on lavapipe under validation; `images` passes for every
scene, the motion scenes on baselines accepted before culling, with `chunks_occluded` within
its tolerance and above zero in `cave`, `down`, `north` and `wall`; `build check` and the suite.
**Measured** (development machine, reported): the table above; `views` `gpu_world` at most 60%
of the commit before R7b's.

## Open questions for the owner

None.

## Check by hand (R7b)

Run `./build.sh run`, join the scratch world, turn quickly and fly through the hills with F3
open: no chunk flickers in or out at the edges of hills (the `occluded` count on F3's
`render:` line rising as you go behind a hill). Report any flicker with its screenshot (F2).
