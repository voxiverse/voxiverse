# Debugging

Debug builds (`build run`, `build build`) detect most problems automatically and report
where they originated. This document covers what debug builds do, the switches that go
further, the developer console and its checks, debuggers, and validation, GPU
captures and visual baselines. Everything described here is
exercised by `tools/debugger/test_printers.sh`.

Related documents: [graphics.md](graphics.md) (the renderer's passes, timings and culling),
[benchmarking.md](benchmarking.md) (benchmarks and profiling),
[network.md](network.md) (network debugging and the state model),
[server.md](server.md) (server commands, permissions, accounts, chat),
[world.md](world.md) (worlds, items, liquids, structures, generation).

## What debug builds do automatically

| Problem | Result |
|---|---|
| Vulkan misuse | The Khronos validation layer (with synchronization validation) reports it with its spec ID, the names of the objects involved, and the stack of **our** code that made the call. |
| Memory leak / bad free | Listed at exit with the file and line that allocated it; the run fails. |
| Failed `assert`, `panic`, bounds check | A message and a stack trace, after which the program stops (in your debugger, if one is attached). |
| Crash (segfault, access violation, illegal instruction, stack overflow on the main thread) | The signal or exception, the faulting address and a stack trace in the console and the log, followed by the usual crash handling (core dump, Windows Error Reporting, or your debugger). The `crash` command (development builds) tests this. A crash also leaves a **bundle**: a folder `crashes/<UTC date_time>-<pid>/` beside the settings file (the dedicated server: in the universe) with `crash.txt` (what, which thread, build, OS, CPU, GPU, uptime), `threads.txt` (every registered thread's stack), `log.txt` (the last 256 KiB of the log, the home directory as `~`) and `actions.txt` (the last 256 actions: button presses, command names, screens and overlays opening and closing, worlds joined and left; `crash.txt`'s `state` is `title`, `loading`, or `world singleplayer`, `world LAN` or `world remote`, never an address). The newest 10 are kept. Nothing is uploaded. The next start of the game offers the folder: when the title first shows and a bundle has no `seen` file, a dialog says the last run closed unexpectedly, with "Open folder" and "Close" (focus on "Close"; Escape and B close it; "and N earlier" when several are unseen). Either button writes `seen` into every unseen bundle. Scripted runs, benchmarks and checks are not asked. The dedicated server prints `crash report from the last run: <path>` at start for unseen bundles and writes `seen`; its `actions.txt` holds joins and leaves (as player counts), saves and command names. A release build's stacks are raw addresses unless it keeps line tables. Sanitizer builds have no bundle: the sanitizer reports crashes itself. |
| Frame times | Logged at exit: wall-clock and GPU time per frame (avg, p50, p99, max). |
| Everything logged | Written to the console (Info and above) and to `build/voxiverse.log` (everything). The five previous runs' logs are kept as `voxiverse.log.1` (the previous run) to `voxiverse.log.5`. |

Validation requires the layer to be installed (see the README). Without it, the game logs one
warning at startup.

## Reading the log

```
console:    3.214 INFO  server     server player joined name="player"
            3.215 WARN  main       gpu renderdoc is loaded but did not provide API 1.6 (client/gpu/renderdoc.odin:60)
file:       3.214512 | INFO | server | server player joined name="player" | server/core/server.odin:224
```

Each line contains:

1. the seconds since start;
2. the level;
3. the thread that logged it (`main`, `server`, `worldgen 2`, `mesh 1`);
4. the message: what happened, followed by `key=value` pairs to filter on, for example
   `grep 'pos=\[1,6,4\]' build/voxiverse.log`.

The console adds the source location to warnings and errors; the file includes it on every
line.

Messages begin with the subsystem (`gpu`, `server`, `session`, ...) and write values in
`key=value` form.

## Switches

| Switch | Effect |
|---|---|
| `VX_LOG=debug` | Also shows debug-level messages on the console. |
| `VX_VALIDATION` | The validation layer; see [Validation](#validation). |
| `VX_BREAK=1` | Stops in the attached debugger on validation errors and wherever `base.debug_break()` is called. |
| `VX_SETTINGS=<path>` | The settings file (empty: none is read or written). The crash bundles and `account.key` live beside it. |
| `VX_SAVES=<dir>` | Where saves go. |
| `VX_UPDATE_AS=<version>` | Development builds only: the updater checks as that version (a development build otherwise never checks; [platforms.md](platforms.md#updates)). |
| `VX_UPDATE_SOURCE=<dir>` | Development builds only: the updater reads `<dir>/releases.json` and downloads from `<dir>/download/<tag>/` over `file://` instead of GitHub (a release build has no way to do this). |
| `build run --sanitize` | AddressSanitizer build: reports use-after-free and buffer overflows with the offending line (Linux/macOS). |
| `build test [<package>...] -sanitize:address` | The tests under AddressSanitizer (also `-sanitize:thread`; Linux/macOS). Runs at the same 512 KiB thread stack as every test run. |
| `build test [<package>...] -o:speed` | The tests at an optimisation level (`none`, `minimal`, `size`, `speed`, `aggressive`). |
| `build test <package> -test-name:<name>` | Only that test (repeatable; `test_x` is the package's own, `pkg.test_x` is taken as written). `ODIN_TEST_NAMES=a,b` does the same. |
| `build run --profile` | Writes a profile trace (see [benchmarking.md](benchmarking.md#profiling)); combine with `--release`. |
| `build debug [--lldb]` | Starts a debug build in gdb (or lldb) with the Odin printers loaded. |
| `run -- --frames N` | Runs N frames and exits; fails on any validation finding or leak. |
| `run -- --capture-frame N` | Under RenderDoc: captures frame N (see [GPU captures](#gpu-captures)). |
| `run -- --exec "cmd; cmd"` | Runs a script of console commands (see [Scripts](#scripts)). |
| `run -- --check <name>` | Runs an exit check (see [Checks](#checks)). |
| `run -- --scene <name>` | Renders one visual-baseline scene offscreen and quits (see [Visual baselines](#visual-baselines)). |
| `run -- --null-audio` | Mixes into the null device (real time, no sound card). |
| `run -- --game <id>` | Straight into a scratch world playing that game, past the title, a script (`--exec`) too, which then runs in it (not with `--scene`, `--check` or `--benchmark`, which choose their own worlds); a world started here (`singleplayer`, a new universe) plays it ([games.md](games.md)); default: `sandbox`. A saved universe plays the game it records. |
| <kbd>F2</kbd> / `screenshot [name]` | Saves the next frame as `build/screenshots/<name>.png`. The world checks take a screenshot at the start and end of each flight. |
| `build shot <name> [--game <id>] -- <script>` | Plays a console script (`;` between its lines, as `--exec` takes it) headless on lavapipe under `xvfb-run` at 1280x720 and quits when it says `quit`: its `screenshot` commands land in `build/screenshots/`, its log and state in `build/shots/<name>/`. It builds the client alone, and only when something it is built from changed (`build/voxiverse.stamp`: the sources, the command line, the compiler; as every build of the game does), and runs it with no sound card. Linux. How a game's screenshots are taken: [games.md](games.md#screenshots). |
| <kbd>F3</kbd> | Overlay: FPS, frame and GPU time per frame and the present mode (FIFO with vsync; IMMEDIATE without, or MAILBOX where the window system offers nothing else), position, client/server chunk counts, chunk memory, session arenas, meshing queue, draws, server tick time, the simulation island you are in (id and chunks), and the line of the game the world plays (`game <id>: ...`). The game's HUD is drawn below it while it is open. |
| <kbd>F4</kbd> | The tuning panel (see [Variables](#variables)). |
| <kbd>F8</kbd> | Development builds: the audio inspector ([audio.md](audio.md)). |

Options combine, e.g. `VX_VALIDATION=best,gpu` or `build run --release --profile`.

## Reading a validation message

```
vulkan [VUID-vkCmdDraw-renderpass]: vkCmdDraw(): This call must be issued inside an active render pass.
  at client::draw (client/main/main.odin:118)
  at client::run_with_gpu (client/main/main.odin:107)
```

- The bracketed ID can be searched for in the
  [Vulkan specification](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html).
- Objects appear with their names, e.g. `VkImage 0xe000000000e[swapchain image 0]`. Name new
  objects with `gpu.set_name`, and bracket recorded work with `gpu.begin_label`/`end_label`
  (which also times it on the GPU).
- Some checks run on the layer's own thread after the call has returned. Those messages say
  so instead of showing a stack. Use the object names and labels, or `VX_BREAK=1`.

## Variables

Settings (saved), debug switches (`debug.*`, never saved), world rules (`rules.*`) and
generator parameters (`worldgen.*`) are plain struct fields described by variable tables.
`rules.*` and `worldgen.*` belong to the world's server, which announces changes.

| Command | Effect |
|---|---|
| `vars [filter]` | Lists variables, their values and their help. |
| `set <name> <value>` / `reset <name>` | Changes a variable / resets it to its default. Out-of-range values are clamped, with a warning. |
| <kbd>F4</kbd> | Opens the tuning panel: every variable as a slider or checkbox, live. |

Settings are saved to `settings.cfg` in the user configuration directory
(`~/.config/voxiverse/` on Linux), or to the path in `VX_SETTINGS`. Changes made by `--exec`
scripts are never saved, so test runs cannot alter your settings.

To add a variable, add the field to its struct, its default, and one line to the table. A
test checks every table.

## Shader hot reload

In development builds, saving a file in `assets/shaders` recompiles it (through
`build/build-driver shaders`) and swaps the affected pipelines within about a second. A shader
that fails to compile logs glslang's message with file and line, and the previous shader keeps
running. `set debug.hot_reload_shaders 0` disables hot reload.

`scene.glsl` is included by the world, sky and entity shaders (the per-frame scene, sky
colours, clouds); saving it reloads all three. `client/engine/passes.odin` lists the passes and what
they include.

`/time <name|0..1>` together with `/rule daylight_cycle false` holds the sky still while you
work on it.

## Sound

Every sound effect is synthesized at startup (`client/sfx`; there are no recordings) and mixed
by our own mixer (`client/audio/`); the platform layer only opens the sound card (`client/platform/audio*.odin`). Every Ogg file, including
the music and a pack's sounds, is decoded by our own Odin code, `common/ogg`.

- `build sfx` writes every recipe of the base pack to `build/sounds/*.wav` and a target report, for listening outside the game.
- F3 shows the device, the voices playing, the DSP callback duration (µs), and the sounds played and dropped. The log's last
  `audio` line summarizes the run.
- `audio_capture` (<kbd>F9</kbd>), the F8 inspector and `build audio` are described in
  [audio.md](audio.md).
- Without a sound card (a headless machine, or Linux without `libasound.so.2`) the game logs one warning and runs silently.
- `set volume 0..1` sets the player's volume.
- On Linux and macOS the build compiles Odin's miniaudio library once (into the Odin
  installation; Windows ships it), which requires a C compiler.

### The Ogg decoder

`common/ogg` is a Vorbis I decoder and an Ogg reader. It rejects malformed input with
an `Error` and never allocates beyond `open`'s single block. Its maintenance commands are:

| Command | Effect |
|---|---|
| `build ogg digests` | Rewrites `common/ogg/testdata/digests.txt` (FNV-1a of every decoded `f32` of the music, the small test files and the edge-case files) and prints the lines that changed. A digest changes only with an intended decoder change. |
| `build ogg reference` | Rewrites `common/ogg/testdata/reference/` from the reference decoder (libvorbis through `ffmpeg` on the `PATH`; used only here, and the output is committed): half a second at the start, middle and end of each music file, and each edge-case file whole. `reference.odin` lists which edge-case files have no reference, and why. |
| `build ogg make-test-files` | Rewrites `common/ogg/testdata/edge/` (`tools/ogg/make.odin`): valid Vorbis streams of seeded random packets over a fixed codebook set, one file per feature (every block size, tiny and cut streams, mono, coupled stereo, six channels, floor 0, residue 0 and 2, pages, chained links). Run it only to change those files; the digests and references must then be regenerated. |
| `build fuzz pack.ogg` | The decoder is fuzzed by the fuzz harness ([fuzzing.md](fuzzing.md)). A minimized crashing input goes to `common/ogg/testdata/edge/regress/` and the suite replays it. |
| `build bench ogg` | Decodes the music with `common/ogg` and with miniaudio, best of three, and reports seconds of audio per CPU second for both and their ratio. |

## Keeping the screen awake

While the player is in a world, not paused and not in the game menu, the screen is kept on.
The request is released otherwise and on exit (`platform.set_keep_awake`, logged at debug
level as `platform keep awake`).

| Platform | Mechanism |
|---|---|
| Windows | `SetThreadExecutionState`. |
| Linux | The freedesktop screensaver's `Inhibit` over D-Bus (libdbus loaded at run time), or else the desktop portal's (Wayland desktops); plus `XResetScreenSaver` every 30 s for X's own blanking. |
| macOS | An IOKit power assertion. |

Where no mechanism responds, the game logs this and does nothing further.

## Debug drawing

`render.debug_line` and `render.debug_box` draw world-space lines for one frame from anywhere
on the main thread. The lines are hidden behind terrain and never hide it. See
`world_debug_lines` in `client/engine/camera.odin`. `set debug.chunk_borders 1` outlines the
camera's chunk and its neighbours' edges.

## Commands

Commands come from three surfaces, each with a single purpose:

- **Server commands** act on the world and the players. They start with a slash, in the chat
  and in the console alike, and are listed in [server.md](server.md).
- The **developer console**'s plain words belong to the client itself and never act on the
  world.
- **Checks and benchmarks** are command-line modes.

### The developer console

The console is opened with `~`. A line starting with `/` is sent to the world's server as a
server command (it needs a world); a plain word is the client's own command. A plain word
that names a server command is answered with a hint to type the slash. The console's
commands are:

| Command | Purpose |
|---|---|
| `singleplayer` | A scratch world, never saved. |
| `universe [--earth] <name>` | Plays the saved universe (created if new: with `--earth` its home world is Earth, as the creation screen's default; else one made from the seed). Saves go to `VX_SAVES` if it is set. |
| `join <host[:port]> [password]`, `leave`, `quit` | Session control. |
| `screen <title\|game\|menu\|inventory [creative]\|stats\|options [tab]\|singleplayer\|universes [<game>\|create]\|multiplayer [direct]\|credits\|quit>` | Switches screens (`singleplayer`: the games; `universes`: a game's page, sandbox's unless named; `create`: its creation screen). |
| `set`, `vars`, `reset` | Variables (see [Variables](#variables)). |
| `screenshot [name]`, `renderdoc [title]`, `net_trace`, `audio_capture`, `crash` | Diagnostics (`crash`: development builds; `renderdoc`: queues a frame capture when attached). |
| `look <yaw> <pitch>`, `camera <first\|behind\|facing> [degrees]` | Places the camera for a picture (<kbd>F5</kbd> cycles the camera modes). |
| `camera at <x> <y> <z> <yaw> <pitch>`, `camera reset` | Development builds: the camera put at a place, looking that way (degrees, as `look`), whatever the game's camera (first person, top-down, free) and whatever the player may do (fly or not); the avatar is drawn, the hand and crosshair are not, and the player stays where it is (the server is told nothing). The world drawn is what the session holds, the chunks within the view radius of the player: a place farther off looks at nothing (it says so), so `/tp` the player nearer first. `camera reset`: the game's camera again. |
| `use`, `hold <item>` | For scripts: presses the right button once on the target (a chest opens, a creature is used); selects the hotbar slot that holds an item. |
| `pad <button> down\|up`, `pad <axis> <value>`, `pad connect <family>`, `pad disconnect` | Development builds: a synthetic gamepad (slot 0), connected by its first button or axis. A trigger is an axis, as a pad reports it: `pad right_trigger 0.7`, or `down` (pulled all the way) and `up`. |
| `key <key> down\|up` | Development builds: a key held or let go as the keyboard would (`key p down` holds the player list open for a screenshot); a mouse key is the mouse's own button where the pointer is (`key mouse_left down` holds the trigger in the world, or presses a UI button under the pointer). |
| `pointer <x> <y>` | Development builds: the pointer moved to a place of the window, in pixels, as the mouse would (a script aims a top-down or free camera's pointer for a screenshot). |
| `export <save> [file]`, `import <file> [name]` | Writes a save as one `.vxu` file / makes a new save from one. |
| `report <note>` | Sends the developer a note with the version and the last console lines (needs Share play data on, in a saved universe). |
| `console`, `clear`, `help` | Console housekeeping. |

Nothing in the console duplicates a key, the UI or a server command.

### Scripts

Scripts (`--exec "cmd; cmd"`) are console input typed at startup, with the additional
commands `ticks <n>` (until the server has run n more ticks: our own server runs them back
to back, as fast as it can, so `ticks 600`, twenty seconds of play, takes a second or two,
and the script goes on once the session has heard the last of them; someone else's server
keeps its time), `wait <frames>`, `sleep <seconds>` (the clock's
time: for what the clock decides, a fade, a toast; play is `ticks`), `wait_world` (until
the world has loaded and meshed; a missing or failed world fails the run) and `wait_joined`
(until the session plays, its world perhaps still loading; likewise). They exist to
reproduce a state and capture its picture:

```
--exec "singleplayer; wait_world; screenshot world; wait 3; quit"
--exec "singleplayer; wait_world; /time set noon; ticks 400; wait_world; screenshot later; quit"
--exec "screen options"
--exec "set debug.net_trace 1" --check fly
```

Until the pointer has moved over the window it is the window's middle (in a script under
`xvfb-run`, until `pointer` moves it), so a top-down or free camera neither aims at a corner
nor pans at an edge.

### Checks

`--check <name>` runs a check with the benchmarks' fixed settings (its own view), after any
`--exec` script (which may prepare the state), and then quits, failing the run if the check
failed. The checks are `fly`, `blast`, `cull` and `hiz`.

| Check | Description |
|---|---|
| `fly` | The memory check. Flies 400 blocks at 40 blocks/s (view 6 x 3), and fails if either session arena grew or chunk storage exceeded its fixed size. Logs frame times and resident memory. |
| `fly_pad` | The same flight on a synthetic gamepad. |
| `tour` | Visits every biome but the planet's ice sheet (view 4 x 3) and screenshots each (`biome_<name>`), then fails on a biome not found, a frame p99 over 100 ms, chunk generation or meshing p99 on the workers over budget (5 and 10 ms in an optimized build, ten times that otherwise), or memory growth after the first biome. |
| `cull` | Runs the world's culling shader on 343 chunks round a camera, from fixed cameras, outside the frames, and fails on any command, in-view bit or count that differs from the CPU's rules (`cull_reference`). Needs no world. |
| `hiz` | Builds the depth pyramid from depth images of five sizes (filled from a hash and from a CPU raster of boxes) and fails on any texel of any level that differs from `hiz_reference`, bit for bit; then runs the occlusion test (`occlusion.glsl`) on 4 096 boxes from four cameras and fails on any verdict that differs from `occlusion_reference`. Needs no world. |
| `blast` | Hovers above the spawn (view 4 x 2) and sets off 12 rockets and explosions in turn, then fails on a frame p99 or server tick over 100 ms, a blast not shown whole (its meshes in one frame), arena growth, or chunks that differ from the server's (both sides hash them). F3 shows how many bulk edits were shown whole and how many late (on a timeout). |
| `audio` | 30 s of a busy session into the null device: fails on underruns, NaN, dropped or late commands, or the callback outside its block. |

F3's `chunks:` line shows how long chunks take to generate (on the server's workers) and to
light and mesh (the client's), as the average and the slowest 1%.

## Overlays

Every in-game panel is an overlay on a single stack (`client/engine/overlay.odin`): the game
menu, Options, tuning, chat, the player menu, console, quit dialog, gate dial, audio
inspector, consent question, Open to LAN and death. Each overlay declares whether it takes the
keyboard, frees the mouse, or pauses the world. The top overlay receives the keys, the focus
and Escape.

## Threads

The server, the worldgen workers and the mesh workers log, assert and allocate in the same
way as the main thread (they inherit its context), and each has its own track in profile
traces.

`build test <package> -sanitize:thread` runs the tests under ThreadSanitizer, which reports
a data race (two threads incrementing one global, say) with both stacks. Threaded code is
also covered by deterministic tests (`common/base/queue_test.odin`,
`server/core/server_test.odin`).

Each option set of `build test` keeps its own binary, log and timing beside the default's
(`build/test/<package>.speed`, `.address`, `.thread`), so a sanitizer run does not rebuild over
the plain one.

## Debuggers

`build debug` builds the game and starts gdb (Linux) or lldb (macOS, or `--lldb`) with the
Odin pretty-printers from `tools/debugger/`. The printers show strings as text, slices and
dynamic arrays as their elements, maps as key/value pairs, unions as the active variant only
(or `nil`), and Vulkan handles as hex. Arguments after `--` are passed to the game.

To use the printers elsewhere, run `source tools/debugger/odin_gdb.py` in gdb, or
`command script import tools/debugger/odin_lldb.py` in lldb (or in CodeLLDB's
`initCommands`).

- **Breakpoints.** Odin's debug information places a procedure's parameters correctly only
  after its first line, so `break some_proc` can show garbage arguments. Break on a line
  inside the body (`break main.odin:113`), or `next` once after stopping.
- **With `VX_BREAK=1`**, the stop is inside `base::debug_break`. `bt` shows the path, and
  `frame function client::draw` (gdb) jumps to your code.
- **Windows.** Debug builds write a `.pdb` next to the `.exe`. `build debug` starts the
  [RAD Debugger](https://github.com/EpicGamesExt/raddebugger) if `raddbg` is on the `PATH`;
  it understands Odin types. [RemedyBG](https://remedybg.itch.io/remedybg) and Visual Studio
  also work.
- **Odin upgrades.** After upgrading Odin, run `tools/debugger/test_printers.sh`: the map
  printer mirrors the runtime's internal layout.

## Graphics

The renderer is Vulkan 1.3 with dynamic rendering, bindless textures and one pipeline layout
(`client/gpu`, `client/render`). Every frame records one command buffer; up to two frames are
in flight (`FRAMES_IN_FLIGHT`). Passes, timings, draw counts, culling, chunk light and
pipelines are in [graphics.md](graphics.md).

### Validation

`VX_VALIDATION` controls the Khronos validation layer. Unset, the layer is on in development
builds and off in release builds. Otherwise it is a comma-separated list: `1` or `on` (the
layer, with synchronization validation), `best` (also best-practices advice, logged as
`vulkan advice` and not counted as a finding), `gpu` (also GPU-assisted shader checks, slow),
or `0` or `off`. A run with `--frames N` fails on any validation finding; with `VX_BREAK=1`
the debugger stops at each one.

### GPU captures

[RenderDoc](https://renderdoc.org) (Windows, Linux) records every call, resource and pipeline
state of a frame.

1. Start the game from RenderDoc (Launch Application, or
   `renderdoccmd capture build/voxiverse`).
2. Press F12 in the game, run the console command `renderdoc [title]`, or pass
   `--capture-frame N` to capture frame N (counted from 1; the trace's `frame #N` is the same frame).

Captures are written to `build/captures/voxiverse_frameN.rdc` and listed in the log at exit.
When supported by the physical device (`pipelineStatisticsQuery`), Vulkan pipeline statistics
are queried across the frame: vertex, clipping, fragment, and compute shader invocations are
displayed on the F3 overlay (`pipeline:`) and logged at exit (`gpu pipeline stats`).
Every buffer, image, pipeline, sampler and per-frame object carries its name, and every pass
its label. Shaders are compiled with debug information (`glslang -g`: line numbers and the
source text), so a capture shows each shader's GLSL source. The richer NonSemantic debug
information (`-gV`, `-gVS`) is not used: it requires
`SPV_KHR_relaxed_extended_instruction`, which Vulkan 1.3 drivers are not required to support,
and `spirv-val` rejects it without that extension. The game communicates with RenderDoc
only when started from it; it never loads RenderDoc itself.

### Visual baselines

`./build.sh images` renders a fixed set of scenes and compares each picture with a baseline
kept in the repository, so a change to the renderer that changes the picture is found by a
test rather than by eye. It runs on Linux only, on lavapipe (Mesa's CPU Vulkan driver) under
`xvfb-run`: the same on every machine, and never a window on the desktop. The build driver
finds lavapipe's manifest in the system's ICD directories and points `VK_DRIVER_FILES` (and
the older `VK_ICD_FILENAMES`) at it, whatever GPU the machine has.

They are part of the gate: `./build.sh test` with no package named (and no `-o:`,
`-sanitize:` or `-test-name:`) renders them after the unit tests and fails if any scene
does, as `./build.sh images` would. On this 8-core machine the 31 scenes take about ten
minutes (four at once; lavapipe draws on the CPU). A narrowed run (`test <package>`) does not
render them, and on Windows and macOS `test` says they were not run.

The scenes are listed in `assets/baselines/images/scenes.txt`, one a line, as
`name: [@WxH] script`; the script is console commands separated by `;`, as `--exec` takes them.
`voxiverse --scene <name>` runs one scene and quits: it joins the scratch world at its fixed
spawn and draws offscreen at 640 x 360, or at the size an `@WxH` before the script gives
(`client/autopilot/scene.odin`; a malformed size is an error naming the line). It takes no
`--exec`, `--benchmark` or `--check`. Whatever could change the picture from one run to the
next is fixed:

- the benchmarks' settings (`BENCHMARK_SETTINGS`), with no sound device;
- still clouds, no creatures, and still rules: the daylight cycle stopped at the benchmarks'
  time of day (a scene may set another with `/time set`), no random ticks, and no gravity,
  so a player teleported anywhere stays there;
- the water's animation stopped;
- time itself: while the script runs (however long the world takes to load) every frame's
  step is 0, and after it the scene draws `SCENE_SETTLE_FRAMES` frames (2.5 s) of exactly
  one tick each (`scene_frame_ms` in `client/engine/autopilot.odin`), so what fades or eases
  (the held item's name, the eye's height, the third-person camera) has finished and what
  never settles (an avatar's breath, the view model's sway) is at the same phase in every
  run, whatever the machine's frame times;
- no chat lines and no toasts: they are cleared two frames before the picture.

A scene whose script starts with `earth` runs on an Earth planet world instead: the scratch
world is made at Earth's address (built on the planet model, as a new universe's home world
is), with the same fixed conditions (still clouds, no gravity, stopped time). It waits only to
have joined (`wait_joined`), not for the land at the spawn it is about to leave. The scene's
script then stands on the surface with `/goto <place>` (a name of `PLANET_PLACES`, or a
latitude and longitude) and frames it with `look`; `earth_everest`, `earth_sahara`, `earth_amazon`, `earth_alps`, `earth_greenland` and `earth_nile` do so.

A scene whose script starts with `screen` is a menu's: it never joins the scratch world, the
menus' animations stand still (every frame's step is 0, so the starfield, the planet's turn
and the stars' settling are as at the start), and after the script it draws ten frames. Two
development commands and a variable serve such scenes: `creation seed <n|text>` sets the
creation screen's seed as if typed, `ignite show` starts Ignite with that screen's galaxy and
planet (no universe is made), and `set debug.ignite_at <seconds>` holds an active Ignite at
that time (a key or click still skips it). The `creation` and `ignite_*` scenes use them, at
1280 x 720. The `title_*` scenes do the same for the title's holiday themes, at 1280 x 720:
each fakes a holiday with the developer command `title_date MM-DD` (or `title_date
YYYY-MM-DD`, and `title_date off` to go back to the local date), and sleeps so the splash's
stamp rings in and settles before the picture. Easter's scene pins April 2026 specifically,
so its baseline is the same every year.

After the scene's own script, the run waits a second for the server to answer, waits until
the world around the player is loaded and meshed, draws ten more frames, and then settles
(above). The picture is
the offscreen image itself, not the window's scaled copy of it. It is written to
`build/images/<scene>.png`.

For each scene the comparison reports two numbers: the share of pixels whose largest colour
channel differs from the baseline's by more than 8/255, and the mean absolute difference of
the colour channels. A scene fails when the first is above 0.1% or the second above 0.5/255
(`IMAGE_MAX_SHARE`, `IMAGE_MAX_MEAN` in `tools/build/images.odin`). A failed scene also gets `build/images/<scene>.diff.png`:
the baseline in dim grey, the differing pixels in red. Each run's log is
`build/images/<scene>.log`.

Scenes render in parallel (about half the cores, at most six), the slowest last time first,
each under a limit of ten times its last rendering (`build/images/<scene>.seconds`), at least
five minutes, as a test package's run is limited; each with its own X display and
its own directory `build/images/<scene>.state/`, which `VX_SETTINGS` (settings, crash bundles)
and `VX_STATE_DIR` (the game's log and pipeline cache, instead of the executable's) point to.

Each scene also writes `build/images/<scene>.counts`, what its picture's frame drew (the
culling pass's statistics and the draw counts: `world_meshes`, `world_triangles`,
`draw_calls`, `api_draw_calls`, `world_api_draw_calls`, `frame_triangles`), one `name
value` a line. It is compared after the picture with the baseline's `<scene>.counts`: each
count must be equal, or within the baseline's `~tolerance` where a line gives one; a
difference fails the scene, naming the count, the baseline and the value. `--accept` writes
both files.

```
./build.sh images                      # every scene, compared
./build.sh images cave                 # one scene, compared
./build.sh images --accept cave        # render it and make the picture its baseline
./build.sh images --accept all         # every baseline rewritten
```

A change that alters the picture on purpose re-accepts only the scenes it changes, after
looking at their pictures and differences; the commit says which scenes and why. A new
scene is a line in `scenes.txt` and `./build.sh images --accept <name>`.

## Reports

`./build.sh test` writes `build/reports/tests.jsonl` (recreated by each run): one JSON object
per line per test that ran, `{"package": "client/main", "test": "test_creative_tab", "result":
"pass", "seconds": 1.25}`. `package` is the driver's package path and `test` the name the runner
prints without its package. `result` is `pass` or `fail`; a test the process died in (started,
never finished) is `fail`. The format also allows `skip`, which nothing produces: core:testing
has no skip. `seconds` is measured by the driver, which stamps the runner's state-change log
lines as it sees them (about every 10 ms), so it is accurate to that.

Each `bench <scenario> -check` run (chunks, telemetry, budgets, script) appends to
`build/reports/bench.jsonl`, one object per judged quantity: `{"bench": "budgets", "scene":
"the save", "metric": "save_slice", "value": 2107, "unit": "us", "limit": 3000, "runs": [2101,
2107, 2175]}`. `value` is what the check judged (the median of the runs; for chunks and
telemetry the median of each repetition's mean) and `runs` is every run's value. `limit` is
left out for a quantity without one: the chunk counts (`chunks`, `meshed`, `vertices`), which
are held to exact values, have one run and no limit. Script lines are the instruction units of
each program (limit: its budget in `common/script/testdata/bench/budgets.txt`), its ratio to
Lua, the geometric mean of the ratios, and the snapshot and restore times. The file is not
cleared between benches, so a clean tree starts from a removed `build/reports/`.
