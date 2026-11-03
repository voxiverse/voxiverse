# Benchmarking and profiling

`build bench <scenario>` measures one thing the same way every time, on any machine.
Profiling shows where the time goes inside a run. Take numbers from benchmarks and
proportions from traces.

## Benchmarking

| Scenario | Measures |
|---|---|
| `chunks` | Generating, lighting and meshing a fixed region on one thread, without the game (`tools/bench`). With `-check` (CI), it also fails if the chunk, mesh or vertex counts changed or a stage's median over 5 runs exceeded a generous budget. Another region (`-seed`, `-radius`, `-x`, `-z`) is the scenario `chunks-custom`, never compared with `chunks`. |
| `load` | Joining the scratch world until everything around is loaded and meshed: load time, the pools' work, server ticks. |
| `views` | Sixteen still views from the spawn: each GPU pass, triangles, the CPU's frame. |
| `views-far` | The same views at view radius 24, height 12: what culling and recording cost as the view grows. A name of its own: it never compares with `views`. On a machine whose CPU and GPU share power (an integrated GPU), `frame_record` follows the GPU's load as much as the CPU's work: compare it with `views` drawn at a size that loads the GPU as much (`-size:2560x1440`). |
| `viewmodel` | The view model's vertices for a frame of the biggest model, 2000 frames. |
| `avatars` | Eight players walking in view from the spawn, each holding a weapon, drawn as other players are drawn: `avatar_draw` (building their vertices), the entity and held passes, the frame. |
| `flight` | 600 blocks of flight at 40 blocks/s: frames while streaming, generation and meshing, ticks. |
| `edits` | 12 explosions around the spawn: `edit_shown` (from a bulk edit's chunks arriving until all their new meshes are shown), meshing, frames, ticks. It waits for the water they release to settle. The explosions are queued on the in-process server (`server.call_async`), not waited for, so no frame holds a server tick of the driver's waiting. |
| `audio` | The mixer offline: 64 looping voices on 4 buses, the reverb, a music stream; 10 s of blocks. |
| `server` | The dedicated server alone (`voxiverse-server --benchmark server`): 8 simulated players join over UDP and fly out in 8 directions; ticks, streaming, generation, bytes sent. |
| `party` | The `server` scenario's bots in survival with the kit's weapons, shooting each other. Its universe is `build/benchmarks/party-universe`. |
| `ogg` | The Ogg decoder against miniaudio (see [debugging.md](debugging.md#the-ogg-decoder)). |
| `telemetry` | An event's emit and write cost; `-check` as in CI ([telemetry.md](telemetry.md)). |
| `budgets` | The server's save, audit, counters, journal and flood costs; `-check` as in CI ([saves.md](saves.md)). |
| `script` | The script VM (`build script bench`; [script.md](script.md)). |

### Benchmark conditions

The game's scenarios run a release build with `--benchmark <scenario>` under fixed conditions:

- fixed settings (`BENCHMARK_SETTINGS` in `client/autopilot/benchmark.odin`: no vsync; the player's
  settings file is neither read nor written);
- frames drawn offscreen at 1280 x 720 regardless of the window size (`gpu.set_offscreen`; the
  copy onto the window is `gpu_present_copy`, excluded from `gpu_frame`). `-size:WIDTHxHEIGHT`
  (`build bench views -size:2560x1440`; the game's flag is `--bench-size`) draws at another
  size, 64 to 8192 a side; its results are kept as a scenario of their own
  (`views-2560x1440`), since numbers at different sizes never compare;
- the scratch world and its fixed spawn;
- the time of day stopped at late morning (0.45), still clouds, no sheep, no sound device.

Each scenario runs three repetitions, each a separate session after a warm-up. It writes
`build/benchmarks/<scenario>/<time>-<commit>.json` (every metric of every repetition, the
exact counts, the resolution, the machine) and a line in `build/benchmarks/history.jsonl`
(each metric's value).

A metric's value is its median, except for the server's load metrics (`server_tick`,
`server_stream`, `server_collect` and the like), where it is the mean: half the server's ticks
may do nothing while the workers catch up, and the heavy ticks are what matters. Results are
comparable only on one machine (identified by its fingerprint) and one scenario version. The
metrics are `base.Metric` (`common/base/metrics.odin`): recorded in any build, but only while
a benchmark is measuring. `--profile` adds a Spall trace of the run.

### How `-check` judges a budget

`bench chunks`, `telemetry`, `budgets` and `script` with `-check` measure each budgeted
quantity over 5 runs (`-repetitions N` changes it; `script --smoke` is one) and compare the
**median** with the limit, so one noisy run decides nothing. The table prints every run's value
beside the median, and the result file keeps every run. A scene or stage that fails to run in
any run (an error, a missing result, changed counts) is reported as `bench broken` and fails at
once, without judging budgets: a median never hides it. A median over its limit is
`bench over budget`. The script's time ratios to Lua are the median of the per-run ratios.

### Comparing two versions

`build bench compare <ref> <scenario> [-runs:N] [-size:WIDTHxHEIGHT]` determines whether a
change is faster. It builds `<ref>` in a git worktree (`build/worktrees/`, kept), runs it and
the working tree alternately N times (default 5, at least 2), and prints each metric for both
with its change and a Mann-Whitney p value. A change is called only at p < 0.05. With 5 runs
each, the smallest possible p is 0.008; with 3, it is never below 0.1, so use at least 4.
Exact counts that differ are shown first, because the two versions then did different work.

Judge a change with `compare`, never by two runs at different times: on the same machine,
medians move by several percent from run to run.

### How to benchmark a change

1. **Choose the scenarios the change can affect**: `chunks` for generation, light and
   meshing; `load` for streaming; `views` for drawing; `flight` for drawing while streaming;
   `edits` for re-meshing; `server` for the server under load from players. When unsure, run
   several.
2. **Keep the machine otherwise idle and its power steady**: plugged in, nothing else
   compiling or playing, and the same power profile for both sides. `compare` alternates the
   two versions, so slow drift (heat) affects both alike, but noise still widens the spread
   and hides small changes.
3. **Compare against the commit before the change** with
   `build bench compare main <scenario>` (or the commit hash), with the change in the working
   tree. Use the default 5 runs, or `-runs:8` to detect changes of a few percent.
4. **Read the counts first.** "COUNTS DIFFER" means the two versions did different work (more
   chunks, fewer vertices). That is a change of work, which may be intended (greedy meshing)
   or a bug; the times then compare different things.
5. **Trust only called changes** (p < 0.05). A difference of a few percent without a call is
   noise; repeat with more runs if it matters.
6. **Record the result in the commit message**: the scenario, the metrics that changed, A and
   B, and p, e.g. "views: gpu_world 1.098 -> 1.181 ms (+7.6%, p 0.008)".
7. **Update pinned counts.** The exact counts in `bench chunks -check` (CI) are pinned. A
   change that alters chunks, meshed chunks or vertices on purpose updates them in
   `tools/bench` in the same commit.

### Smoke runs

`--smoke` (`build bench <scenario> --smoke`, and the game's and server's `--smoke`) runs a
scenario once, briefly, with a small view. CI runs this to keep every scenario working. The
results are written to `<scenario>-smoke` and are not compared with anything.

## Profiling

Measure optimized code. The default development build is lightly optimized (3-8x slower than
release in the chunk pipeline), and `--debug` is not optimized at all (7-15x slower).

The profiling tools, from narrowest to widest:

| Command | Shows |
|---|---|
| `build bench <scenario>` | A benchmark scenario under fixed conditions (see [Benchmarking](#benchmarking)). Run this first, before and after a change for speed. |
| `build perf [game\|server\|bench] [-- arguments]` | Samples a `--release --symbols` build under Linux perf (call stacks from the CPU's branch records where available) and prints the hottest functions per thread. Use `perf report -i build/game.perf` for call graphs, and `--sort srcline` for source lines. Threads carry their names (`server`, `worldgen 1`, `mesh 2`). |
| `build run --release --profile`, then `build trace` | A Spall trace of every instrumented scope and the GPU's passes. `trace` prints each scope's calls and percentiles per thread, a per-second timeline, and the slowest frames and server ticks broken down. |
| The `session mesher` log line | The client's meshing work at the end of a session (see [Chunk light](graphics.md#chunk-light)). |
| `set debug.occlusion_stats 1` | Counts the chunks drawn that pass no pixel, logged at exit as `render occlusion` (see [How the world is drawn](graphics.md#how-the-world-is-drawn)). |

### Spall traces

`build run --release --profile` writes `build/voxiverse.spall`, a trace for
[Spall](https://gravitymoth.com/spall/); open it in the web viewer or the native application.
`build trace` summarizes it. A trace identifies itself:

- **The process** is named with the program, version and commit, build, and arguments
  (`Voxiverse 0.1.2+40 (135f897a933a) client, release build, profiling, arguments:
  --benchmark edits`).
- **CPU.** There is one track per thread (`main`, `server`, `mesh 1`..., `worldgen 1`...,
  `save 1`), with nested scopes. A `frame` and a `server tick` carry their number (for example `frame 2047`:
  for a frame, the frame count from 1, as `--capture-frame` counts; for a tick, the server's
  tick).
- **GPU.** A track named `GPU (calibrated) <device>, <driver>` holds the frame and every
  `begin_label`/`end_label` pass, on the CPU tracks' clock when the driver supports
  calibrated timestamps. Otherwise the track is named `GPU (approximate) ...`: durations are
  exact, but placement relative to CPU work is not.

### Frame scopes

The main thread's frame (`client/main/frame.odin`, `app_frame`), outermost first:

| Scope | Contents |
|---|---|
| `frame #N` | One frame. It excludes the frame cap's sleep (`frame cap (sleep)`) and `benchmark driver`, which run between frames. |
| `input` | Window events, input and actions. |
| `shader watch and telemetry`, `audio and music` | Per-frame upkeep. |
| `session` | The game: `receive messages` (what the server sent: `apply block change` writes each block and records the change; `settle block changes` then dirties each chunk the frame's changes reach once, and meshes on the spot, as `mesh now (block changed)`, only the chunks where a change could show a see-through hole: a block that drew opaque or cutout faces is gone or replaced, at most 8 chunks a frame; flowing water never meshes here), `prediction tick` (each fixed tick), `aim (raycasts)`, `start meshing` (settles what predictions changed the same way, then hands chunks to the `mesh` workers, holes first; a task holds references to its 27 chunks' block arrays, not copies, and an edit while it runs writes a fresh array: each task is `light chunk`, then `mesh chunk` when its light or geometry changed), `send messages`. |
| `after session (packs, checks, sounds, loading)` | What follows from the session. |
| `ui layout` | Building the HUD and menus (the GPU's `ui` pass draws them). |
| `wait for GPU` | `wait for frame fence` (the GPU is still drawing this slot's previous frame: GPU-bound), `acquire image`, `reset and begin commands`, `read GPU timings`, and rarely `recreate swapchain`. |
| `render` | The CPU side of drawing: `chunk meshes in` (`apply meshes`), `world and ui uploads`, `scene (avatars, entities, view model)`, `entity uploads`, `world cull` (the world's draw commands), `record commands`, `queue submit`, `queue present` (vsync may wait here). |

### Server tick scopes

The server's tick (`server/core/server.odin`, `tick`): `server tick #N` holds `scheduled calls`,
`saving`, `receive messages`, `player` (each player), `unload idle worlds and audit`; per
world, `block updates`, `random ticks`, `entities`, `containers`, `rewind, gates and
rollback`, `changes flush`, `journal`; per player, `replicate` and `stream` (`request chunk`,
`send chunk`, `replica flush`); then `kicks and packs` and `network flush`. The generator's
stages are `worldgen climate`, `worldgen place trees`, `worldgen terrain` and `worldgen
structures`.

### Adding scopes

A scope name states what is done, in lower-case words (`apply block change`, not
`apply_block`). The same name means the same work wherever it appears.

Add a scope with `base.profile_scope("name")`, which times the rest of the enclosing block and
compiles to nothing in non-profiling builds, or with `base.profile_scope_number("name", n)`.
A thread that records scopes calls `base.profile_thread_start("name")` first; on a thread
that has not done so, a scope records nothing.

### Reading a trace

`build trace` prints:

- per thread and scope, the calls, total and percentiles;
- a per-second timeline;
- the slowest frames and server ticks, with the scopes directly inside them;
- the slowest three of each as a tree, down to every scope over 0.1 ms (calls merged:
  `apply block change x43`), with time not covered by any scope shown as `(untimed)`.

`python3 tools/debugger/check_spall.py build/voxiverse.spall` validates a trace: it is
well-formed and balanced, every GPU pass lies inside its frame, and passes are aligned when
calibrated.

The dedicated server (`build serve --release --profile`) writes its own trace alongside,
`build/voxiverse-server.spall`; summarize it with `build trace build/voxiverse-server.spall`.
Each run overwrites the previous trace.

### Overhead

**A trace shows where the time goes; take numbers from `build bench`.** A scope costs two
clock reads and a few bytes. On Linux the clock is read through libc (its vDSO, about 60 ns),
not through a system call, which would make scopes that fire thousands of times per second
appear several times slower than they are. Read proportions from a trace; take numbers, and
before/after comparisons, from `build bench` on a build without `--profile`.
