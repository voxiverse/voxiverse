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

**Why.** R3 took block records' meshing off the main thread (`mesh now` no longer appears in
`edits`) and halved the worst frame, but frame p99 fell 31% (4.76 -> 3.28 ms against
0be56e1), not half. R3's split (decided 2026-10-30, unattended): what is left in the p99
frames is not block records. In a profiled `edits` run, the frames at or above p99 spend on
average 1.25 ms in `session` (0.74 `receive messages`: decoding and storing the bulk edit's
resent chunks, `world_set_chunk`'s neighbour checks; 0.48 `start meshing`: `task_fill`
copying 27 block arrays, 216 KiB, per job) and 0.98 ms in `record commands`, while the
GPU's own frame p99 is 2.1-2.5 ms. Half of R2's p99 is 2.38 ms: reachable only when the
CPU side of an edit's frame fits behind the GPU's. R5 removes most of the recording; R4
changes what a mesh job reads. This row comes after them, so it measures what they leave.

**Design (decided).**

- **Snapshots by reference.** A mesh (or R4's light) job takes references to its
  neighbourhood's block arrays instead of copies: the client's arrays are copy-on-write
  (a reference count per array in the client's `Block_Arrays`; `world_set_block` and
  `world_set_chunk` write to a fresh array when the current one is referenced by a job, and
  the job releases its references when its result is taken). The server's chunk storage is
  untouched.
- **Chunk arrival measured, then cut.** With snapshots by reference, profile `edits` again;
  whatever of `receive messages` is still over 0.3 ms in a p99 frame (decoding, the 27
  neighbour lookups per chunk) is the next step: decode into a fresh array without the
  scratch copy, one neighbour pass per frame for all arrived chunks.

**Tests.** A job's snapshot is unchanged by an edit made while it runs (a test writes the
live world between `task_fill` and the job); an array referenced by a job is never handed
out again until released; the R3 tests unchanged.

**Exit check.** `bench compare` on `edits` against the commit before R3 (0be56e1): frame
p99 at most half (2.38 ms on the development machine at that commit's 4.76), p < 0.05;
`start meshing` p99 under 0.1 ms in a profiled run; `images` passes.

## R6: GPU culling

**Why.** After R5 the CPU still walks every mesh twice a frame; at larger view distances
that walk grows with radius² × height.

**Design (decided).** A compute pass before rendering reads every `Chunk_Draw` record and
the frustum (from the scene buffer), and writes the indirect commands: a culled run gets
`instanceCount` 0 (no `drawIndirectCount`). Face-group culling (the runs facing away) moves
into the same shader. Opaque and cutout draws need no order; translucent draws keep the
CPU's sorted list (water is a small part of the scene). The CPU walk of the opaque pool is
removed.

**Steps.** (1) The cull compute pipeline and its label (`cull`). (2) Barriers between the
compute writes and the indirect reads. (3) Remove the CPU opaque walk. (4) GPU time of
`cull` as a metric (`gpu_cull`).

**Tests.** `images` passes; a culling unit test on the compute shader's logic, run on
lavapipe (a fixed set of chunks and a camera, the resulting instance counts).

**Exit check.** `frame_record` on `views` within noise of R5 or better; a new scenario,
`views-far` (`views` at view radius 24, height 12, its own name so it never compares with
`views`), has `frame_record` within 20% of `views`; `gpu_cull` under 0.1 ms on `views`.

## R5b: the indirect draws' cost (after R6)

**Why.** R5 drew each world layer with one `vkCmdDrawIndexedIndirect` (3 world API calls,
from 1547 draws), but against 8a0879e on `views` (development machine) `frame_record` fell 48.0-49.5% over three five-run compares (half not
reached) and `gpu_world` rose 4.3-9.6% (p 0.008-0.095), `gpu_water` 24% (0.055 -> 0.068
ms). Measured in R5: the same commands recorded as direct draws cost what 8a0879e's did
on the GPU (water 0.056 ms), so the GPU cost is the driver's indirect path, not the
shaders; with the driver's generated draws turned off (its
`generated_indirect_threshold` option, a diagnostic) the world pass took 2.29 ms, so that path is already the driver's faster one.
Of what is left of `frame_record`, about 0.1 ms is the driver recording the two world
indirect calls and 0.1 ms is `world_cull` (walk, sort, writing commands). R6 replaces
`world_cull`'s walk and writes with a compute pass, which changes both numbers; this row
comes after it, so it measures what R6 leaves.

**Design (decided 2026-10-30, unattended: measure, then cut, as R3b).**

- **Measured first.** `bench compare 8a0879e views` after R6, and a profiled `views` run:
  the CPU left in `world cull` and `record commands`, and the GPU's world and water time
  against 8a0879e's.
- **Then cut, in this order, each kept only if `bench compare` shows it:** the chunk
  record as a 12-byte attribute (`R32G32B32_SINT`: the first vertex moves to a second
  table for R6's shader); fewer commands for the same triangles (R8's water runs and quad
  records, if R8 has landed, else meshes of one region allocated next to each other in
  the vertex buffer so adjacent chunks' runs merge into one command where their ranges
  touch); the water layer as one command per contiguous range.
- **Not done:** setting driver options from the game, direct draws for small layers, a
  per-driver path.

**Tests.** `images` passes with no re-accept; R5's and R6's tests unchanged.

**Exit check.** `bench compare 8a0879e views`: `frame_record` at most half (p < 0.05);
`gpu_world` within noise or better; `images` passes.

## R7: occlusion culling

**Why.** 72% of the chunks drawn at the spawn cover no pixel.

**Design (decided).** Two-phase occlusion culling with a hierarchical depth buffer:

1. Draw the chunks visible last frame (a per-chunk visibility bit in a storage buffer).
2. Build the depth pyramid from that depth (compute, max-reduction for reverse Z: the
   pyramid holds the farthest depth of each texel's footprint, written as storage images).
3. Test every chunk's bounding box against the pyramid; draw the newly visible ones;
   update the visibility bits.

No chunk that is visible is ever missing from a frame (no popping), because phase 3 draws
what phase 1 missed. The depth image becomes sampled and storage-usable; the pyramid is
per frame slot.

**Steps.** (1) Visibility bits. (2) Pyramid build. (3) The two phases in the cull pass.
(4) `debug.occlusion_stats` reports culled counts from the new path. (5) Metrics
`gpu_hiz`, `chunks_occluded`.

**Tests.** `images` passes (every scene, including flight-like scenes added for this
milestone if R1's set lacks a scene with motion: two frames with a moved camera).

**Exit check.** `bench compare` on `views`: `gpu_world` at most 60% of R6's; `flight`
frame p99 not worse.

## R8: compact geometry

**Why.** A quad is stored as four 8-byte vertices and six indices; the index buffer is
sized per layer (`MAX_QUADS_PER_LAYER` 24 576), and water gets neither greedy merging nor
face-group culling.

**Design (decided).**

- **Quad pulling.** A mesh stores one 16-byte record per quad instead of four 8-byte
  vertices: position and size in sixteenths, face, texture layer, surface and drop bits, and
  the four corners' AO (2 bits each) and light (8 bits each); the vertex shader expands six
  vertices per quad from `gl_VertexIndex / 6` and `gl_VertexIndex % 6`. No index buffer. The record
  layout is fixed in `client/mesh/mesh.odin` and mirrored in `world.glsl`, with a test that
  both agree.
- **Water** merges its top faces greedily where level and light agree, and uses face-group
  runs like the opaque layers.

**Tests.** Golden meshes of the benchmark region (vertex count, quad count) updated with
their new numbers; `images` passes.

**Exit check.** Geometry memory for `views` (bytes in the arena) at most 55% of R7's;
`gpu_world` within noise or better; `mesh_faces` within noise or better.

## R9: memory

**Why.** One allocation per resource; a full vertex buffer silently loses meshes; the mesh
limit is below the chunk capacity.

**Design (decided).**

- **Sub-allocation.** `client/gpu/allocator.odin`: per memory type, 64 MiB blocks with a
  TLSF-style free list; resources at or above 32 MiB get a dedicated allocation. All
  `create_buffer` and `create_image` calls go through it. `Gpu.memory_bytes` counts block
  bytes; a new metric counts `vkAllocateMemory` calls.
- **The world's geometry arena grows.** When the quad arena cannot place a mesh, it grows
  by a block (up to a limit derived from `VK_EXT_memory_budget` when present, else 512 MiB)
  and moves live ranges with a GPU copy in the upload pass; meshes are never dropped. If
  the limit is reached, the farthest meshes are evicted and re-requested when the camera
  comes closer, and a warning is logged once.
- `max_meshes` derives from the client's chunk capacity.

**Tests.** Allocator unit tests (fragmentation, coalescing, dedicated); a client test that
fills the arena past its first size and keeps every mesh; the old `.Full` path removed.

**Exit check.** `vkAllocateMemory` calls during `flight` at most 10; `images` passes;
`flight` frame p99 within noise or better.

## R10: uploads off the graphics queue

**Why.** Chunk uploads are copies at the start of the frame's command buffer, competing
with drawing, and bounded by an 8 MiB per-frame staging buffer.

**Design (decided).** A transfer queue: a queue of a transfer-capable family other than
the graphics family when one exists, else a second queue of the graphics family, else the
graphics queue itself (the code path is the same). A 32 MiB staging ring; uploads recorded
on the transfer queue's own command buffers; a timeline semaphore orders them before the
frame that first draws the mesh; queue-family ownership transfers when the families
differ. `world_apply` shows a mesh only when its upload's timeline value has been reached.

**Tests.** Synchronization validation clean on lavapipe and locally; a client test that
uploads more than one ring's worth in a frame and shows every mesh within three frames.

**Exit check.** `flight`: frame p99 and worst at most 80% of R9's, p < 0.05; `gpu_upload`
gone from the graphics queue's sections.

## R11: the frame graph and an HDR target

**Why.** Every pass draws into the swapchain format inside one rendering scope; there is
nowhere to put post-processing, half-resolution passes or intermediate images, and each new
pass would need hand-written barriers.

**Design (decided).** A small frame graph (`client/gpu/graph.odin`), not a general one:
passes declared each frame with the images and buffers they read and write; images are
transient, allocated from R9's allocator and aliased where lifetimes do not overlap;
barriers are derived from the declarations (synchronization2). The scene renders into an
`R16G16B16A16_SFLOAT` colour target; a final `tonemap` pass writes the swapchain image.
The tonemap is the identity in this milestone (clamp, then the sRGB encode the swapchain
already did), so the picture is unchanged; the offscreen benchmark path becomes the graph's
output size.

**Tests.** `images` passes with no re-accept; graph unit tests (barrier derivation, aliasing
of two non-overlapping images).

**Exit check.** `gpu_frame` on `views` within 5% of R10's; validation clean.

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
- **Tonemapping and exposure** beyond R11's identity.

## Water: what this arc changes and what it does not

The water rules (sources, seven flow levels, the five-tick step) are server simulation,
moved onto data by M49 with byte-identical results; this arc does not change them. What
made water expensive on the client is addressed by R3 (no main-thread meshing for water,
changes coalesced per chunk per frame), R4 (light computed once per change, re-meshing only
where light changed) and R8 (water meshed compactly). Changes to the rules themselves (a
faster flow, water levels as an M49 channel rather than block ids, settling a basin in one
step) change the state hash and the bandwidth baselines; they are questions for the owner
and the simulation arc, not for this one.
