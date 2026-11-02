# Rendering internals

The renderer's structure as it appears when debugging or profiling: the passes, the GPU
timings and draw counts, how the world is drawn and culled, chunk light and meshing, and
pipeline creation. Validation, GPU captures and visual baselines are in
[debugging.md](debugging.md#graphics).

## Passes

A frame is drawn in these passes, each bracketed by `gpu.begin_label` and `gpu.end_label`.
A label names the pass in validation messages and GPU captures, and times it on the GPU.

| Label | Pass |
|---|---|
| `frame` | The whole frame (a label and a timed section of its own). |
| `upload chunk meshes` | Copies of new chunk meshes from the staging buffer. |
| `cull` | The world's culling pass (compute, before rendering): the draw commands of the opaque and cutout layers. |
| `world` | Opaque and cutout terrain. |
| `entities` | Avatars, sheep, items, projectiles. |
| `held` | The item in hand, in third person (`held_draw_world`) and first person (`held_draw_view`). |
| `sky` | The sky, after the world, at the far plane. |
| `water` | Translucent terrain, sorted. |
| `debug lines` | Developer overlays (chunk borders, boxes). |
| `ui` | The HUD and menus. |
| `present copy` | Benchmarks only: the offscreen image copied onto the window. |

## Timing

Each pass's GPU time is measured with timestamp queries (`client/gpu/timing.odin`) and read
back once its frame slot's fence has signalled. The results appear in three places:

- the F3 overlay (`GPU x ms`) and the exit log line `gpu frame times`;
- benchmark metrics: `gpu_frame` (without `gpu_present_copy`), `gpu_world`, `gpu_water`,
  `gpu_sky`, `gpu_entities`, `gpu_held`, `gpu_upload`, `gpu_cull`, `gpu_ui`,
  `gpu_present_copy`;
- in a profiling build, the trace's GPU track, named `GPU (calibrated) <device>, <driver>`.
  With `VK_KHR_calibrated_timestamps` the GPU events sit on the CPU tracks' clock; otherwise
  the track is named `GPU (approximate) ...` and only durations are exact. Each pass carries
  its draw calls and triangles in its arguments.

A frame is GPU-bound when the CPU waits in `wait for frame fence` (the trace's main thread):
the GPU is still drawing the frame recorded `FRAMES_IN_FLIGHT` frames earlier.

## Draw calls and triangles

Every draw goes through `gpu.draw`, `gpu.draw_indexed` or `gpu.draw_indexed_indirect`
(`client/gpu/draw.odin`), which count it. An indirect call counts once as an API call and
once per command it holds as a draw. The counts appear on F3's `render:` line and as
benchmark metrics:

| Metric | Counts |
|---|---|
| `draw_calls` | Every draw of the frame, all passes: an indirect call's commands each. |
| `api_draw_calls` | The `vkCmdDraw*` calls that recorded them, all passes. |
| `world_api_draw_calls` | Of those, the world pass's: one per layer drawn (opaque, cutout, water), more only with `debug.occlusion_stats` (one per chunk queried) or past the device's `maxDrawIndirectCount`. |
| `frame_triangles` | Every triangle drawn in the frame, all passes (thousands). Line lists count none. |
| `world_triangles` | The world pass's triangles, opaque and water (thousands). |
| `world_meshes` | Chunk meshes drawn by the opaque world pass. A mesh is drawn as one command per run of visible face groups, so this is not a count of draws. |

The opaque and cutout layers' commands are written on the GPU, so their share of these
counts is the culling pass's own (`Cull_Stats`: meshes in view, triangles, commands that
draw something), read back `FRAMES_IN_FLIGHT` frames late; `draw_calls` counts those
commands, not the ones that draw nothing.

## How the world is drawn

The world pass (`client/render/world_pass.odin`) draws each layer (opaque, cutout, water)
with one `vkCmdDrawIndexedIndirect`:

- **The chunk draw table** (`chunk draws`, a device-local buffer) holds one `Chunk_Draw`
  per mesh at its pool slot: the chunk (three `i32`) and its first vertex. A copy writes it
  when the mesh is added (`world_add_mesh`, in `upload chunk meshes`). `world.vert` reads
  it as a per-instance attribute (`in_chunk`, vertex binding 1); each command's
  `firstInstance` is the mesh's slot, so the hardware fetches that mesh's record. The
  chunk's offset from the camera's chunk is computed in integers from the scene's
  `camera_chunk`, so positions stay exact far from the origin.
- **Vertices** (8 bytes each) come through vertex input (binding 0); the command's
  `vertexOffset` is the run's first vertex in the shared buffer, and the static quad index
  buffer supplies the rest. Pulling them by address (`gl_VertexIndex`) cost `gpu_world`
  5-10% on the development machine, so it is not done.
- **The culling pass** (`world_cull`) runs before rendering: the `world cull` profile
  scope on the CPU, the `cull` label on the GPU. Every mesh shown has a `Cull_Record` (its
  chunk, pool slot, first vertex and each opaque and cutout face group's vertex count:
  80 bytes) in a dense device-local table (`cull records`), in the order of `live`; a mesh
  shown, or moved into a removed one's place, marks its place dirty, and the pass first
  copies the dirty records in from `cull staging`. `world_cull.comp` then runs one
  invocation per record: it tests the chunk's box against the frustum's planes (taken
  from the scene's `view_proj`) and writes `CULL_RUNS` (2) `VkDrawIndexedIndirectCommand`
  per layer at fixed places in this frame slot's `cull commands` buffer: every opaque one,
  then every cutout one. A run of face groups that can face the camera gets one command;
  the others, and every command of a chunk out of view, draw nothing (`instanceCount` 0:
  `drawIndirectCount` is not used). Face groups are meshed in the order +x +y +z, crossed,
  -z -y -x (`client/mesh`), so the groups a camera sees make at most three runs; when there
  are three, the gap with fewer vertices is drawn too (`bridged`: its faces all face away and
  back-face culling drops them), so two commands cover every case
  (`test_runs_of_visible_face_groups`). The pass also counts (`cull stats`, copied to the
  host-visible `cull readback` and read by `world_begin` when the slot comes round again)
  and sets a bit per mesh in view. The CPU never walks the opaque meshes.
- **Water** is culled and sorted on the CPU, farthest first (blending needs it): only
  the meshes with water (`water`, a dense list of their own) are walked, and their commands
  written into the host-visible `world draw commands` buffer.
- **`world_draw` and `world_draw_translucent`** bind each pipeline once and draw: the
  opaque and cutout layers each one indirect call over every mesh's commands, the water
  one over its sorted commands. The push constants hold only what every world draw shares
  (the scene's address, the texture array, the sampler, the time). With
  `debug.occlusion_stats`, the opaque layer is drawn as one indirect call per mesh with
  opaque faces, nearest first, each inside its query; a query counts only for a mesh the
  pass found in view (its bit). `set debug.occlusion_stats 1` counts the chunks drawn that
  pass no pixel (hidden behind nearer ones: what occlusion culling would leave out), logged
  at exit as `render occlusion`.

When culling goes wrong, `--check cull` runs `world_cull.comp` on a fixed set of chunks and
cameras outside the frames and compares every command, bit and count with `cull_reference`,
the same rules on the CPU (`client/render/cull_check.odin`); CI runs it on lavapipe. A chunk
missing at the edge of the screen points at the planes (the scene's `view_proj`); faces
missing on one side of every chunk at `facing`; garbage geometry at the record layout
(`render_test.odin` asserts `Cull_Record`, `Cull_Push` and `Cull_Stats` against the shader's
declarations).

## Memory

`Gpu.memory_bytes` is the device memory this process has allocated through
`create_buffer` and `create_image`. Where the driver supports `VK_EXT_memory_budget`,
`gpu.memory_report` also returns the process's use of the device-local heaps and the budget
the driver currently allows. F3's `memory:` line shows both, with the bytes of chunk meshes
uploaded this frame.

## Chunk light

Light is not stored: a chunk's light is a pure function of the blocks within 16 blocks of it
and the column heights there (`common/game/light.odin`). The client computes it for each
chunk before meshing (`client/engine/world.odin`) and keeps it, with the chunk, as its
`Light_Cache`: the light of the chunk and its 1-block border (18³ bytes, `sky << 4 | block`)
that its mesh was made with, and the key of what it was computed from: an XXH3-64 hash of
the 27 chunks' block versions (`Client_Chunk.blocks_version`, bumped by every change to a
chunk's blocks) and the 48 x 48 column heights around.

A mesh task (`Mesh_Task`, on the `mesh` workers) runs in two parts:

1. **Light** (scope `light chunk`, metric `light_chunk`): skipped when the key matches the
   cache (the cached light is the light: `light_reused`).
2. **Mesh** (scope `mesh chunk`, metric `mesh_chunk`): skipped when the chunk's blocks
   within a block of it did not change (`Client_Chunk.geometry`, set by a chunk arriving,
   a neighbour resent, an edit within a block, or a registry swap) and the new light is
   byte for byte the cache's. The chunk then keeps its mesh (`unchanged`).

So an edit lights again every chunk within `LIGHT_MAX` (15) blocks of it, and meshes again
only the chunks within a block of it and those whose light it changed. A registry swap
(`world_remesh_all`) drops every cache: its blocks may light differently.

The workers are `mesh_worker_count()` (`client/engine/session.odin`): a quarter of the cores, at
least two. The `session mesher` log line at the end of a session reports the work: chunks
meshed (`meshed_now`: meshes made on the main thread because a block change could have shown
a hole), re-meshed (and why: resent, `dirtied_edit` edits that changed their geometry or
light, column tops), `relit_edit` (chunks an edit lit again), `unchanged` (lit again and not
meshed: light and geometry as their mesh's), `light_reused` (lit from the cache), and task
times.

## Pipelines

Pipelines are created through a `VkPipelineCache` whose data is kept beside the game as
`pipeline-cache.bin` (`client/gpu/pipeline_cache.odin`). The file holds an XXH3-64 hash of
the driver's data, then the data. The data is used only when the hash matches and Vulkan's
header names this GPU's vendor, device and driver cache UUID; otherwise the cache starts
empty and the reason is logged. The cache is written at exit, to a temporary file renamed
over the previous one.

Each creation reports its time and whether the cache supplied it (Vulkan 1.3's pipeline
creation feedback): per pipeline at debug level (`gpu pipeline built`), in total at exit
(`gpu pipelines built=N from_cache=N ms=X`), and as `create pipeline` scopes in a trace.

