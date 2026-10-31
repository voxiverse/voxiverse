# R1-R15: a modern Vulkan voxel renderer (issue #67)

This arc takes the renderer from a CPU-driven forward renderer to a GPU-driven voxel
renderer: draws generated and culled on the GPU, occlusion culling, compact geometry,
streaming off the graphics queue, an explicit frame graph with an HDR target, far terrain
at a fraction of the cost, and a client that absorbs block changes without stalling. Each
row is one session's work for an implementing model working alone from this document, in
order; each leaves the game shippable.

## Where the renderer stands

Measured on the development machine (release build, `build bench`, medians of three
repetitions, 1280 x 720 offscreen) at the commit this arc was planned on (13932f5):

| Scenario | Measure | Value |
|---|---|---|
| `views` | `draw_calls` per frame | 1547 |
| `views` | `world_meshes` drawn | 540 |
| `views` | `frame_record` (CPU: culling, sorting, recording, submit) | 1.07 ms |
| `views` | `gpu_frame` / `gpu_world` / `gpu_sky` | 2.17 / 1.50 / 0.52 ms |
| `views -size:2560x1440` (smoke) | `gpu_frame` / `gpu_sky` | 5.65 / 2.35 ms |
| `flight` | `mesh_chunk` / of which `light_chunk` | 2.56 / 1.95 ms |
| `edits` | frame p99 / worst | 24-39 / 28-53 ms |

What produces those numbers (file references as of 13932f5):

- **Draws are CPU-driven.** Each frame the CPU walks the whole mesh pool twice
  (`client/render/world_pass.odin`, `world_draw`, `world_draw_translucent`), tests five
  frustum planes per mesh, sorts, and records one push constant and one to four
  `vkCmdDrawIndexed` per mesh and layer (`draw_layer`: one draw per run of visible face
  groups). Geometry is read through vertex-input attributes, and the chunk's position comes
  from the push constant, so draws cannot be merged.
- **Nothing hidden is culled.** The occlusion queries (`debug.occlusion_stats`) only count:
  72% of the chunks drawn at the spawn, and 39% in flight, cover no pixel
  (history.md, M19).
- **Light dominates meshing.** Light is not stored: every mesh job recomputes a 48³
  breadth-first light region (`common/game/light.odin`, `light_chunk`), 76% of a mesh job's
  time. A block change dirties every chunk within `LIGHT_MAX` (15) blocks, 8 to 27 chunks
  (`client/world.odin`, `world_set_block` → `remesh_box`), whether or not their light
  changed.
- **Block changes stall the main thread.** `world_set_block` runs once per received
  `Block_Record` and meshes the up to eight chunks within one block of it synchronously
  (`mesh_now`, `URGENT_TASKS` 8), each a 27-array copy and a 48³ light pass; the next
  record in the same chunk makes that mesh stale. Flowing water produces such records
  continuously: the `edits` scenario's worst frames are 40 ms of `mesh now (block
  changed)` inside `receive messages` (see a profiled run's tree).
- **One queue, one allocation per resource.** Uploads are copies on the graphics command
  buffer from an 8 MiB per-frame staging buffer; there is no transfer queue. Every buffer
  and image has its own `vkAllocateMemory` (`client/gpu/resources.odin`). The vertex buffer
  is a fixed 16M vertices (128 MiB) with a first-fit allocator and no compaction; when it is
  full, a chunk is marked clean without its new mesh and never retried
  (`client/world.odin`, `world_apply`). `max_meshes` (65 536) is below the client's chunk
  capacity at the largest view (119 315).
- **No frame structure.** Every pass draws into the 8-bit sRGB swapchain image (or the
  benchmark's offscreen image) inside one dynamic-rendering scope: no HDR target, no
  intermediate targets, no post-processing. The sky pass runs a cloud-slab DDA of up to 160
  steps per pixel, each a buffer-device-address load (`assets/shaders/scene.glsl`,
  `cloud_hit`), and world fragments seen through the slab run it again.
- **Far terrain costs the same as near terrain.** Every chunk out to the view radius is a
  full-detail mesh; view distance is capped at 32 chunks by the protocol.

## Where the renderer stands after R5b (checked against the code 2026-10-30, #87)

The table above is the arc's starting point. What R1-R6 and R5b built, which every open row
below starts from (names as they are in the code now):

- **The frame** (`client/app.odin`, the `render` scope): `world_begin` → `session_apply`
  (meshes in) → `world_upload` (copies on the graphics command buffer from the frame slot's
  8 MiB staging, label `upload chunk meshes`) → the scene (`scene_upload`) → the entity, held
  and debug uploads (CPU-built vertices into per-slot mapped buffers) → `world_cull` (the
  compute pass, label `cull`) → **one** `gpu.begin_rendering` scope (colour cleared, depth
  cleared to 0 with `storeOp` `DONT_CARE`): `world_draw` (opaque, cutout), `entity_draw`,
  `held_draw_world`, `sky_draw`, `world_draw_translucent` (water), `debug_draw`,
  `held_draw_view` (after `gpu.clear_depth`), `ui_draw` → `end_frame` (offscreen copy,
  screenshot, submit, present). Every pass draws into the 8-bit sRGB swapchain format.
- **One depth image** shared by both frames in flight (`Swapchain.depth`, or
  `Offscreen.depth` in benchmarks and scenes; `DEPTH_FORMAT` `D32_SFLOAT`, usage
  `DEPTH_STENCIL_ATTACHMENT` only, so it cannot be sampled). Reverse Z: near is 1, far is 0,
  so **the farthest depth of a region is its minimum**.
- **Meshes**: 8-byte vertices (`mesh.Vertex`: `packed` position in sixteenths, face, AO;
  `layer` texture layer, sky, block, surface, drop) in one 128 MiB device-local buffer
  (`CHUNK_VERTEX_CAPACITY` 16M vertices, `base.Range_Allocator`, first fit); a shared index
  buffer of `MAX_QUADS_PER_LAYER` (24 576) quads; layers opaque, cutout, translucent one
  after another in a mesh's range, each in seven face groups (`FACE_GROUPS`: +x +y +z, both
  ways, -z -y -x). Water is not merged (`merge_faces` skips it).
- **Drawing is indirect.** `Chunk_Draw` (chunk `[3]i32`, first vertex) per pool slot, read by
  `world.vert` as a per-instance vertex attribute picked by `firstInstance`. Culling is
  `world_cull.comp`, one invocation per `Cull_Record` in a dense table kept in `live` order
  (`live_at`, swap-removal, dirty places copied before the dispatch; the meshes with cutout
  faces are its first `cutouts` places, "the cutout prefix"). It writes `CULL_RUNS` (2)
  commands per mesh per opaque and cutout layer at fixed places (`bridged`: the smaller gap
  between three runs is drawn too); each layer is one `vkCmdDrawIndexedIndirect`. Statistics
  (`Cull_Stats`: drawn, triangles, commands, then one in-view bit per dense place) are read
  back `FRAMES_IN_FLIGHT` frames late. `--check cull` compares the shader with
  `cull_reference` on lavapipe (343 chunks, four cameras). Water is culled and sorted
  farthest-first on the CPU from a list of its own (`p.water`).
- **Occlusion statistics** (`debug.occlusion_stats`): the opaque layer drawn one mesh at a
  time nearest first, each in an occlusion query (`OCCLUSION_QUERIES` 4096), counted only
  for meshes the cull pass found in view; logged at exit.
- **GPU timing** (`client/gpu/timing.odin`): every `begin_label`/`end_label` pair is a
  section; `GPU_SECTION_METRICS` maps names to metrics, and **sections with the same name are
  summed per frame** (two `world` sections give one `gpu_world` sample).
- **Memory**: one `vkAllocateMemory` per buffer and image (`gpu.allocate`), counted in
  `Gpu.memory_bytes`; `VK_EXT_memory_budget` read when present (`memory_report`). A full
  vertex buffer returns `.Full` from `world_add_mesh`, logs once (`full_reported`), and
  `world_apply` marks the chunk meshed without its mesh. `max_meshes` is `1 << 16`.
- **One queue** (`usable_queue_family`: graphics and present), `FRAMES_IN_FLIGHT` 2, no
  timeline semaphores.
- **Descriptors**: one bindless set (binding 0 sampled images, `texture2D`/`texture2DArray`
  by id, `SHADER_READ_ONLY_OPTIMAL`; binding 1 three samplers) and one pipeline layout with
  128 bytes of push constants, shared by every graphics and compute pipeline. No storage
  images, no uniform buffers: per-frame data is read by buffer device address.
- **Scenarios**: `views` (version 2, sixteen still views), `views-far` (version 1, radius 24,
  height 12), `flight` (version 2), `edits` (version 2), `viewmodel`, `avatars` (version 1,
  `avatar_draw`); `--smoke` runs of `load views flight edits audio viewmodel` on lavapipe in
  CI, where timing means nothing. `images`: eleven scenes at 640 x 360
  (`client/scenes.odin`, `SCENE_SIZE`), on lavapipe, thresholds from R1.
- **Where R5b left the GPU**: `gpu_world` +14% on `views` against 8a0879e (the driver's cost
  per indirect command); the 12-byte chunk record, merged runs and one water command were not
  measured, left to R8.

## Rules for every R milestone

These hold unless a milestone states an exception.

1. **Client and rendering only.** The server, the simulation, the protocol and the save
   format do not change; the state hash, the bandwidth baselines
   (`assets/baselines/net/`) and the audio baselines stay byte-identical. Liquids belong to
   M49, which keeps their results byte-identical; this arc changes only how the client
   absorbs the changes they produce.
2. **The picture does not change** unless the milestone says it does. From R1 on, every
   milestone ends with `./build.sh images` passing; a milestone that changes the picture on
   purpose says which scenes and why, and re-accepts only those.
3. **Speed is shown, not claimed.** Each milestone names its metrics; its report gives
   `./build.sh bench compare <the commit before it> <scenario>` output (five runs, medians,
   p values) for each, run with the benchmark window on its own workspace. A change called
   "within noise" is reported as such.
4. **Validation stays clean.** `VX_VALIDATION=1 ./build/voxiverse --check blast` (a
   development build) exits 0 with no finding, and CI's lavapipe runs stay green.
5. **Portable Vulkan only.** A feature is used only when Vulkan 1.3 core guarantees it, or
   when lavapipe, MoltenVK 1.4 (pinned in `tools/build/moltenvk.odin`), Mesa ANV/RADV and
   current NVIDIA and AMD drivers all expose it; it is requested at device creation and the
   device is refused, with a clear log line, when it is missing. Used by this arc:
   `multiDrawIndirect`, `drawIndirectFirstInstance` (core features, universally exposed),
   compute shaders, storage images, `timelineSemaphore` (1.2 core). Not used:
   `drawIndirectCount`, mesh shaders, ray tracing, sampler min/max reduction.
6. **Documentation.** The milestone updates docs/debugging.md (Graphics, Profiling) to the
   documentation standard (SerenityOS and Ladybird's `Documentation/`), adds its row's
   result to the cost table, and appends its outcome to history.md.

7. **What CI gates, and what the development machine measures (2026-10-30, #87).** CI has
   no GPU: its Vulkan is lavapipe, where a time means nothing. So every exit check has two
   halves. **Gated in CI** (the row is not done unless they pass there): correctness against
   a CPU reference (`--check <name>`, as `--check cull`: the GPU's output compared value for
   value with the same rules run on the CPU, for fixed and generated inputs), `images`
   (pictures and, from R7, their scene counts: rule 8), unit and property tests, the exact
   counts of `build bench chunks -check`, and validation with synchronization validation
   (`VX_VALIDATION=1` turns it on; every `--check` in CI is a development build, so it runs
   under both). **Measured on the development machine** (rule 3): every speed claim, by
   `./build.sh bench compare <the commit before the row> <scenario>` (five runs, medians,
   Mann-Whitney p < 0.05), reported in the row's history entry with the command. A speed
   target missed is reported as missed (as R3b, R5 and R5b did), never met by changing the
   scenario. **No test asserts a time** (T5); a time budget that CI can judge on a CPU (the
   meshing of a level of detail, an allocator's operations) goes in `build bench budgets
   -check` or `build bench chunks -check`, judged on CI's release-like build with the margin
   those already use.
8. **Scene counts (from R7, 2026-10-30, #87).** Each `images` scene also writes what its
   frame drew: `images/<scene>.counts`, one `name value` line per count, beside its picture;
   `build images` compares them with `assets/baselines/images/<scene>.counts` (LF-pinned in
   `.gitattributes`) and `--accept` writes both. A count the CPU or a compute pass computes
   from integers (meshes, triangles, commands, bytes, allocations) must be equal; a count
   that depends on rasterization (chunks occluded) is written `name value ~tolerance` and
   must be within it (1% and at least 1, R1's reasoning: lavapipe's rasterization is
   deterministic, Mesa versions may differ at an edge). This is how CI sees the work a frame
   does when it cannot see its time: a change that draws more triangles, more commands or
   more meshes in a fixed scene fails, and is re-accepted only knowingly.
9. **Every new GPU pass has a CPU twin.** A compute shader that decides something (culling,
   occlusion, a reduction, a level of detail, an instance transform) has a reference function
   on the CPU with the same rules, and a `--check` that compares them on lavapipe for fixed
   and generated inputs, as R6's `--check cull`; a mutation of the shader (a flipped
   comparison, an off-by-one) must fail it, tried once by hand and said so in the report.
   Where floating-point rounding can put a GPU and CPU result on opposite sides of a
   comparison, the check's generator keeps its inputs a stated margin away from the
   boundary, and counts the cases on each side so it is a test of both.
10. **Each row's spec is its own file** (`docs/milestones/R<n>.md`, from #87). This file
    keeps the arc's starting point, these rules, the held R14 and the visual changes that
    wait for the owner.

## R1: visual baselines

Done: its spec and outcome are in history.md, "R1: visual baselines".

## R2: the edits benchmark measures the game, not its driver

Done: its spec and outcome are in history.md, "R2: the edits benchmark measures the game, not
its driver". Its `edits` baseline (version 2) is the one R3 halves.

## R3: block changes absorbed once per chunk per frame

Done: its spec and outcome are in history.md, "R3: block changes absorbed once per chunk per
frame". Its exit check's frame p99 half is R3b's (below, after R5).

## R4: light computed once per chunk version, re-meshing only where light changed

Done: its spec and outcome are in history.md, "R4: light computed once per chunk version,
re-meshing only where light changed".

## R5: vertex pulling and multi-draw indirect

Done: its spec and outcome are in history.md, "R5: multi-draw indirect". Vertex pulling
was measured and left to R8; the exit check's `frame_record` half and `gpu_world` are
R5b's (below, after R6).

## R3b: an edit's frames hide behind the GPU

Done: its spec and outcome are in history.md, "R3b: an edit's frames hide behind the GPU".
Its exit check's frame p99 half is left to the GPU's own frame and R5b and R6.

## R6: GPU culling

Done: its spec and outcome are in history.md, "R6: GPU culling". `gpu_world` rose with it
(fixed commands for every mesh, no nearest-first order): R5b measures that too.

## R5b: the indirect draws' cost (after R6)

Done: its spec and outcome are in history.md, "R5b: the indirect draws' cost". `gpu_world` stayed above 8a0879e's; R8 is left it.

## R7: the depth pyramid and the occlusion test

Spec: [R7.md](R7.md) (checked against the code and split by #87: the pyramid, the test, the
frame's rendering split, scene counts).

## R7b: two-phase occlusion culling

Spec: [R7b.md](R7b.md) (split from R7 by #87).

## R8: compact geometry

Spec: [R8.md](R8.md) (checked against the code by #87: quad records packed after meshing,
water's flat faces merged, its surface an open question).

## R9: a GPU memory allocator

Spec: [R9.md](R9.md) (checked against the code and split by #87: the allocator and every
resource on it).

## R9b: the geometry arena grows, no mesh lost

Spec: [R9b.md](R9b.md) (split from R9 by #87).

## R10: uploads off the graphics queue

Spec: [R10.md](R10.md) (checked against the code by #87).

## R11: the frame graph and an HDR target

Spec: [R11.md](R11.md) (checked against the code by #87).

## R11b: the look

**Why.** R11 gives the scene an HDR target and a tonemap pass that is the identity. The owner
decided (2026-10-30) the look that goes on it. This section is the spec; nothing is built yet.

**Design (decided).** Each effect is its own toggle in Options (Graphics), on by default, with
every tunable (below) a data value that hot-reloads. CI screenshots each effect on and off.

1. **Tonemap and exposure.** A neutral AgX-style tonemap (hues stay true as they brighten)
   replaces R11's identity. Exposure follows eye adaptation (a caves-to-daylight and back
   transition) from the average log luminance of the HDR target, computed in a compute pass
   in the frame graph; the tonemap reads the exposure from a GPU buffer, with no CPU
   readback. Reduce motion makes adaptation instant. Tunables: adaptation speed up and down,
   exposure minimum and maximum, exposure bias.
2. **A colour grade per world.** A small 3D lookup table (32 cubed) built on load from the
   world's palette (the palettes already come from the world's address; same address, same
   table), applied after the tonemap. Tunable: grade strength (0 is the identity table).
3. **Dithering at the output.** Ordered (blue-noise texture, generated, no asset file) noise of
   under one output step added before the swapchain's quantization, removing banding in sky
   and fog gradients. It is applied to the scene only: the UI is drawn after the tonemap pass
   and stays clean. Block textures keep nearest filtering and their palette quantization; the
   dither is at the output's resolution and one output step, so it does not soften them.
   Tunable: strength.
4. **Water.** A reflection of the sky at grazing angles (Schlick fresnel; the sky colour from
   the sky model's horizon and zenith, no screen-space trace) and a fade of the water's
   opacity and colour with depth (the depth behind the surface from the depth target).
   Tunables: fresnel strength and power, depth fade distance.
5. **Foliage.** Grass and leaves sway in a wind computed in the vertex shader from the
   server's time (the world tick, not the client clock), the block's position and a fixed
   noise, so every player sees the same motion. Reduce motion sets the sway to zero.
   Tunables: sway amount, wind speed.

**Not in R11b (the owner's choice):** bloom, light shafts, vignette, film grain, sun
shadows, anti-aliasing; they stay in "Visual changes that wait for the owner".

**Data.** The tunables live in one data file (in the format the other hot-reloaded renderer
data uses), with the starting values listed in the report for the owner to tune.

**Tests.** The grade table is deterministic per address and the identity at strength 0;
the tonemap's reference function agrees with the shader on a grid (as `--check cull` does);
adaptation steps toward the target at the set speed and is instant under Reduce motion;
the wind at a given tick and position is the same on two clients and zero under Reduce motion;
the dither leaves UI pixels unchanged and a flat gradient banding-free; each toggle off gives
`images` output identical to R11's; hot reload changes a tunable without a restart.

**Exit check.** The `images` baselines are re-accepted with the new look and still catch a
change (as R1 requires: a mutation of a tunable fails them). The effects' GPU cost is measured
with `bench compare` against R11's last commit on `views` and `views -size:2560x1440`, each
effect's cost reported on its own; the budget is stated from that measurement (decided now:
until measured, at most 15% more `gpu_frame`, to be replaced by the measured figure plus 25%
headroom). CI screenshots with each effect on and off. Check by hand: look at those
screenshots and tune the starting values.

## R12: the sky at a fraction of the cost

**Why.** At 2560 x 1440 the sky pass is 2.35 ms of a 5.65 ms GPU frame: a 160-step DDA per
pixel through the cloud slab, each step a dependent storage-buffer load.

**Design (decided).**

- **Clouds at reduced resolution.** The cloud slab is traced at half resolution in each
  dimension into its own target (graph pass `clouds`), storing colour and the hit distance;
  the sky pass and world fragments read it with a depth-aware upsample instead of tracing.
- **The cloud map as an image.** The 256 x 256-bit map becomes an `R8_UNORM` image read
  with texel fetches, not buffer-address loads.
- **Scene constants** read in the sky and world shaders move from buffer-address loads to
  a uniform buffer.

This changes the picture slightly at cloud edges: `images` scenes with clouds are
re-accepted after the owner has looked at the before and after images (listed under "Check
by hand"; the milestone does not wait).

**Exit check.** `views -size:2560x1440` (full run): `gpu_sky` at most 30% of baseline,
`gpu_world` not worse; `images` passes after the re-accept.

## R13: far terrain at level of detail

**Why.** Every chunk out to the radius is full detail; the view distance cannot grow
without its cost growing with radius² × height.

**Design (decided).** Client-side level of detail for loaded chunks: beyond a radius of
`lod_start` chunks (default 8), chunks are meshed from a 2 x 2 x 2 downsampled grid (the
most common opaque block of each 2³ cell; light from the cached light, R4), and beyond
`2 * lod_start` from 4 x 4 x 4. Seams between levels are covered by skirts (downward faces
along level borders). Level changes swap meshes in one frame (as mesh groups do), never
showing a hole. No server change: this uses the chunks the client already has.

**Tests.** Downsampling unit tests; `images` gets two far-view scenes (accepted in this
milestone, reviewed by hand).

**Exit check.** `views-far` (R6): `gpu_world` at most 60% of the same scenario with LOD
disabled (`debug.lod 0`), `world_triangles` at most 40%.

## R14: far terrain beyond the interest area

**Why.** View distance is limited by what the server streams (radius 32 by the protocol).

**This milestone changes the protocol** and needs the owner's decision before it starts;
it is specified here so the decision is about a concrete design. A new message
`Far_Columns`: for columns beyond the interest cylinder up to `far_radius` (default 64), the
column's top height and top block per 4 x 4 block cell, palette-compressed, sent once and
when a column top changes (columns are already tracked: `Column`). The client renders them
as a heightfield with the world's textures beyond the last LOD ring. The bandwidth
baselines gain a far-column line and are re-accepted.

**Exit check.** Set when the owner approves the design.

## R15: entities and held items on the GPU

**Why.** Entity boxes and held models are rebuilt as vertices on the CPU every frame
(`entity_pass.odin`, `held_pass.odin`; eight avatars cost 0.10 ms of CPU, `avatar_draw`).
Cheap today; it grows with entity count.

**Design (decided).** Model meshes (box sets, voxel item models) uploaded once into the
geometry arena; per-instance transforms and pose data (limb angles) in a per-frame storage
buffer; one instanced indirect draw per pass.

**Exit check.** `avatars`: `avatar_draw` at most 25% of baseline; `images` passes
(held-item scenes).

## Visual changes that wait for the owner

Each of these changes how the game looks; none is in the loop's order until the owner has
decided the look. Each is specified when it is approved.

- **Texture filtering:** anisotropic filtering (the device limit is read but no sampler sets
  it) and linear mip blending for the block textures.
- **Sun shadows:** cascaded shadow maps from the sun and moon, which the voxel light
  currently stands in for.
- **Anti-aliasing:** TAA or SMAA on the HDR target (R11).
- **Tonemapping and exposure** beyond R11's identity: decided, now R11b (tonemap, grade,
  dither, water, foliage); bloom, light shafts, vignette and film grain stay here.

## Water: what this arc changes and what it does not

The water rules (sources, seven flow levels, the five-tick step) are server simulation,
moved onto data by M49 with byte-identical results; this arc does not change them. What
made water expensive on the client is addressed by R3 (no main-thread meshing for water,
changes coalesced per chunk per frame), R4 (light computed once per change, re-meshing only
where light changed) and R8 (water meshed compactly). Changes to the rules themselves (a
faster flow, water levels as an M49 channel rather than block ids, settling a basin in one
step) change the state hash and the bandwidth baselines; they are questions for the owner
and the simulation arc, not for this one.
