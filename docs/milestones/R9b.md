# R9b: the world's geometry arena grows, and no mesh is ever lost

The second memory row ([R9](R9.md), R9b; split by #87). Arc rules:
[R.md](R.md#rules-for-every-r-milestone).

**Why.** The world's geometry lives in one buffer of fixed size (R8: `CHUNK_QUAD_CAPACITY`
quads). When it cannot place a mesh, `world_add_mesh` returns `.Full`, logs once
(`full_reported`), and `world_apply` marks the chunk meshed without its mesh: a hole in the
world that never fills. `max_meshes` (`1 << 16`, `client/app.odin`) is below the client's
chunk capacity at the largest view (radius 32 plus `CLIENT_DROP_MARGIN`).

**Checked against the code (2026-10-30, #87; corrections to the old R9 text):**

- The arena's allocator is `base.Range_Allocator` (first fit, `range_alloc`, `range_free`);
  freed ranges are reused only when their frame slot comes round (`World_Frame.freed`). A
  mesh's place is its range's offset, which is in its `Cull_Record` (`first_vertex`, R8's
  first quad) and in its commands: moving a range means rewriting those.
- The client's chunk capacity is computed at join (`client/session_net.odin`:
  `game.interest_count(view_radius + CLIENT_DROP_MARGIN, view_height + CLIENT_DROP_MARGIN)`),
  after `world_init` sized the world pass at start-up; so `max_meshes` is sized at join, not
  at start-up.
- A chunk may hold two meshes at once for a frame or more: a bulk edit's group shows its new
  meshes together (`hidden`, `world_show_mesh`) while the old ones are drawn.

## Design (R9b)

### Growth

- The arena starts at `ARENA_START` (32 MiB, 2M quads) and **doubles** when a mesh does not
  fit: a new buffer from R9's allocator (dedicated at that size), the old buffer's whole
  used span copied into its start in the upload pass (`vkCmdCopyBuffer`, before this
  frame's mesh copies, under the label `grow arena`), `Range_Allocator` grown in place
  (`base.range_grow`: the new tail is one free range merged with a free range at the old
  end). Offsets do not change, so records and commands stay valid; only the buffer's address
  in `World_Push` and the cull pass changes, from the next draw. The old buffer is freed when
  this frame slot comes round (R9's deferred frees).
- **The limit** (`arena_limit`): with `VK_EXT_memory_budget`, half of the device-local heaps'
  budget at join minus what the process already uses there (`memory_report`), and at most
  `ARENA_MAX` (1 GiB); without it, 512 MiB. Logged at join.
- Fragmentation: the first-fit allocator stays (meshes are similar sizes); a mesh that does
  not fit while the free total would hold it grows the arena like any other.

### At the limit: the farthest meshes give way

When the arena is at its limit and a mesh does not fit, the meshes **farthest from the
camera** (by the same distance key as water's sort, over `live`) are removed until it fits;
the mesh being added must be nearer than the farthest one
evicted, or it is the one that waits. An evicted chunk keeps its blocks and light, is marked
`evicted` (`Client_Chunk`), and is queued for meshing again when the camera comes within
`evict_radius - 1` chunks of it (`evict_radius`: the distance of the nearest mesh evicted,
remembered; one chunk of hysteresis so a mesh is not evicted and remade every frame at the
boundary). A warning is logged once per session (`render geometry arena full at <limit> MiB:
far chunks dropped and remade when nearer`), and F3 shows the evicted count. No other path
drops a mesh: `Upload_Result.Full` and the failed branch of `world_apply` are removed.

### `max_meshes` from the session

`world_pass_reserve(p, g, meshes)` at join (after `world_init` in `session_net.odin`, the GPU
idle on the loading screen): the mesh pool, `live`, `live_at`, `records`, `is_dirty`,
`water_at`, R7b's visibility bits, the cull tables and statistics buffers are sized for
`meshes = capacity + capacity / 4` (each chunk one mesh, plus a group swap's hidden meshes; a
pool that fills is an assert with the counts, not a dropped mesh: the session finds the real
bound from `client/world.odin`'s groups and replaces `capacity / 4` with it if it is
smaller, saying so). Shrinking happens at the next join only.

### Debug switches and metrics

`debug.arena_start_kib` and `debug.arena_limit_kib` (development builds) to force growth and
eviction; `debug.arena_verify` keeps an XXH64 of each mesh's quads at upload and, after every
growth, reads the arena back (a one-shot copy to a host-visible buffer at the frame's end)
and compares every live range's hash. Metrics `arena_bytes` (the arena's size, per frame),
`meshes_evicted` (per frame); scene counts gain `arena_bytes` (exact).

## The order of the steps (R9b)

1. `base.range_grow` and its tests; `world_pass_reserve` at join; `max_meshes` from capacity.
2. Growth with the copy and the deferred free; `debug.arena_*`.
3. Eviction, `evicted` chunks and their return; `.Full` removed.
4. `--check arena`, the CI step; metrics; docs; history.md (R9 and R9b's specs appended).

## Tests (R9b)

- `base/range_alloc_test.odin`: `test_range_grow` (ranges kept, the new tail free and merged
  with a free end; growth by more than double; growth of a full allocator).
- `client/render/render_test.odin`: `test_arena_limit` (from a `Memory_Report`: with and
  without a budget, the 1 GiB cap); `test_eviction_order` (the farthest first; the mesh being
  added is refused when it is the farthest; the hysteresis radius).
- `client/world_test.odin` (stepped, no GPU, the world's own bookkeeping with a fake pass
  that refuses beyond N quads): an evicted chunk is queued again when the camera comes within
  `evict_radius - 1`, never before; no chunk ends meshed without a mesh unless evicted.
- `--check arena` (`client/arena_check.odin`, a row of `CHECKS`, a CI step on lavapipe under
  validation): (1) `debug.arena_start_kib 1024`, `debug.arena_verify 1`, the `fly` check's
  400-block route: the arena grows at least four times, every growth verified, every chunk the
  server sent within the view is drawn at the end (its mesh shown), memory flat after (the
  `fly` check's arena rule); (2) `debug.arena_limit_kib 4096`, the same route: evictions
  happen, the warning is logged once, every chunk within `evict_radius - 1` of the camera is
  shown at the end, and none is meshed without a mesh.
- `images`: pictures unchanged; counts gain `arena_bytes`.

## Benchmarks (R9b)

`bench compare <the commit before R9b> flight` and `edits`: frame p99 and worst within noise
(a growth is one copy of the used span: its frame is reported, `gpu_upload` in it); `load`
within noise. `vkAllocateMemory` calls during `flight` still at most 10 (R9's check, now with
growth).

## Validation and synchronization

The growth copy: the old buffer's last readers (vertex shading and the cull pass of earlier
frames, ordered by the frame fence for its slot and by queue order) → transfer read; the new
buffer's transfer write → this frame's copies (transfer → transfer) and draws (transfer →
vertex shader storage read, compute read). Synchronization validation on `--check arena`
covers it.

## Left out (R9b)

Compaction of a fragmented arena without growth; moving meshes so adjacent chunks' runs merge
(R5b's candidate: measured only if commands are again the cost); shrinking during a session;
eviction for any other resource.

## Exit check (R9b)

**Gated in CI:** `--check arena` (both parts) under validation; the range, limit, eviction and
world tests; `images` unchanged with `arena_bytes` in the counts; `Upload_Result.Full` gone;
`build check` and the suite. **Measured** (development machine, reported): `flight` frame p99
within noise, at most 10 `vkAllocateMemory` calls.

## Open questions for the owner

None.

## Check by hand (R9b)

In a development build (`./build.sh run`) with `debug.arena_limit_kib 65536`, fly at view radius 32 and look back:
far chunks come back as you return, never a hole near you; the log shows the warning once.
