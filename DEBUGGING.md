# Debugging and profiling

Debug builds (`build run`, `build build`) catch most problems by themselves and say where they
came from. This page covers what they do, the switches for going further, debuggers, GPU
captures and profiling. Everything here is exercised in CI or by `tools/debugger/test_printers.sh`.

## What debug builds do automatically

| Problem | What you get |
|---|---|
| Vulkan misuse | The Khronos validation layer (with synchronization validation) reports it with its spec ID, the names of the objects involved, and the stack of **our** code that made the call. |
| Memory leak / bad free | Listed at exit with the file and line that allocated it; the run fails. |
| Failed `assert`, `panic`, bounds check | Message plus stack trace, then the program stops (in your debugger, if attached). |
| Crash (segfault, access violation, illegal instruction, stack overflow on the main thread) | Signal or exception, faulting address and stack trace in the console and log, then the usual crash (core dump / Windows Error Reporting / your debugger). `crash` (debug builds) tests it. Off in sanitizer builds, which report crashes themselves. |
| Frame times | Logged at exit: wall-clock and GPU time per frame (avg, p50, p99, max). |
| Everything logged | Console (Info and up) and `build/voxiverse.log` (everything, overwritten each run). |

Validation needs the layer installed (see README); without it you get one warning at startup.

## Reading the log

```
console:    3.214 INFO  server     server player joined name="player"
            3.215 WARN  main       gpu renderdoc is loaded but did not provide API 1.6 (gpu/renderdoc.odin:60)
file:       3.214512 | INFO | server | server player joined name="player" | server/server.odin:224
```

Seconds since start, level, the thread that logged (`main`, `server`, `worldgen 2`, `mesh 1`),
then the message: what happened, then `key=value` pairs to filter on
(`grep 'pos=\[1,6,4\]' build/voxiverse.log`). The console adds the source location to
warnings and errors; the file has it on every line. New code: start messages with the
subsystem (`gpu`, `server`, `session`, ...) and put values in `key=value` form.

## Switches

| Switch | Effect |
|---|---|
| `VX_LOG=debug` | Show debug-level messages on the console too |
| `VX_VALIDATION=0` / `1` | Validation off (debug builds) / on (also in release builds) |
| `VX_VALIDATION=best` | Plus best-practices advice (logged as "vulkan advice", does not fail runs) |
| `VX_VALIDATION=gpu` | Plus GPU-assisted validation: checks inside shaders (slow) |
| `VX_BREAK=1` | Stop in the attached debugger on validation errors and wherever `base.debug_break()` is called |
| `build run --sanitize` | AddressSanitizer build: use-after-free, buffer overflows, with the line that did it (Linux/macOS) |
| `build run --profile` | Write a profile trace (see Profiling); combine with `--release` |
| `build debug [--lldb]` | Debug build started in gdb (or lldb) with the Odin printers loaded |
| `run -- --frames N` | Run N frames and exit; fails on any validation finding or leak (what CI does) |
| `run -- --capture-frame N` | Under RenderDoc: capture frame N (see GPU captures) |
| `run -- --exec "cmd; cmd"` | Run a script of console commands, e.g. `--exec "screen options"` to reproduce a state. Scripts can pause: `wait <frames>`, `wait_world` (until the world has loaded and meshed): `--exec "singleplayer; wait_world; screenshot world; wait 3; quit"` |
| <kbd>F2</kbd> / `screenshot [name]` | Save the next frame as `build/screenshots/<name>.png` (CI uploads the folder: the world runs take one at the start and end of each flight) |
| <kbd>F3</kbd> / `debug` | Overlay: position, client/server chunk counts, chunk memory, session arenas, meshing queue, draws, server tick time |

Options combine, e.g. `VX_VALIDATION=best,gpu`, `build run --release --profile`.

## Reading a validation message

```
vulkan [VUID-vkCmdDraw-renderpass]: vkCmdDraw(): This call must be issued inside an active render pass.
  at client::draw (client/main.odin:118)
  at client::run_with_gpu (client/main.odin:107)
```

- The bracketed ID is searchable in the [Vulkan spec](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html).
- Objects appear with their names, e.g. `VkImage 0xe000000000e[swapchain image 0]`. Name new
  objects with `gpu.set_name`; bracket recorded work with `gpu.begin_label`/`end_label` (which
  also times it on the GPU).
- Some checks run on the layer's own thread after the call returned; those say so instead of
  showing a stack. Use the object names and labels, or `VX_BREAK=1`.

## Variables

Settings (saved), debug switches (`debug.*`, never saved) and later game rules are plain
struct fields described by variable tables; see PLAN.md, "Console and variables".

| | |
|---|---|
| `vars [filter]` | List variables, values and help |
| `set <name> <value>` / `reset <name>` | Change one / back to its default (out-of-range values are clamped, with a warning) |
| <kbd>F4</kbd> / `tune` | Tuning panel: every variable as a slider or checkbox, live |

Settings are saved to `settings.cfg` in the user config directory (`~/.config/voxiverse/` on
Linux), or to the path in `VX_SETTINGS` (empty: none). Changes made by `--exec` scripts are
never saved, so test runs cannot change your settings. New variable: add the field to its
struct, its default, and one line to the table; a test checks every table.

## Shader hot reload

In development builds, saving a file in `assets/shaders` recompiles it (through
`build/build-driver shaders`) and swaps the affected pipelines within about a second. A
shader that fails to compile logs glslang's message with file and line, and the old one
keeps running. `set debug.hot_reload_shaders 0` turns it off. `scene.glsl` is included by
the world and sky shaders (the per-frame scene, sky colours, clouds); saving it reloads both.
`time <name|0..1>` with `set rules.daylight_cycle 0` holds the sky still while you work.

## Saves

A world is a directory: `world.cfg` (text: format, seed, player, rules) and `regions/` with
the edited chunks only (`r.<x>.<z>.vxr`, 16x16 chunk columns each; the rest regenerates from
the seed). Files are replaced through a temporary file, so a crash mid-save keeps the previous
save; a region file that fails its checksum is moved aside (`.damaged-<time>`) with an error,
never loaded. `server/save_test.odin` covers save, quit and load, edits surviving unloading,
and damaged files.

## Debug drawing

`render.debug_line` / `render.debug_box` draw world-space lines for one frame from anywhere on
the main thread (hidden behind terrain, never hiding it); see `world_debug_lines` in
`client/camera.odin`. `set debug.chunk_borders 1` outlines the camera's chunk and its
neighbours' edges.

## World commands

| Command | |
|---|---|
| `singleplayer` / `leave` | Enter a scratch world (never saved: for scripts and tests) / leave the world |
| `world <name>`, `save` | Play a saved world (created if new) / save now (the server also autosaves every minute and when you leave). Saves go to `VX_SAVES` if set |
| `set view_radius 6; set view_height 3` | View distance in chunks for the next world (default 12 x 6) |
| `time [sunrise\|day\|noon\|sunset\|night\|midnight\|0..1]` | Show the time of day, or set it (the server's clock; singleplayer). `set rules.daylight_cycle 0` stops it, `rules.day_length` is seconds per day |
| `tp <x> <y> <z> [yaw pitch]` | Move the player (feet position; a request to the server, which allows it in singleplayer; also before joining) |
| `set rules.<name> <value>`, `vars rules` | Game rules (gravity, speeds, jump height, reach, flying): the server's, so `set` asks it and it announces the change to the client's prediction |
| `break`, `place [block]` | Break the aimed block / place one against its face, as the mouse buttons do (scripts: `tp ... ; wait 30; break`) |
| `fly_test <blocks> [quit]` | The memory check: waits for the world to load, flies straight at 40 blocks/s, then fails if either session arena grew or chunk storage passed its fixed size. Logs frame times and resident memory. With `quit` it exits, failing the run on a failed check. |

`--exec "fly_test 1500 quit"` is the M3 exit check; CI runs smaller versions on the CPU
driver, with AddressSanitizer and with profiling.

## Network

Client and server only talk through messages, so the network is where to look when they
disagree.

| | |
|---|---|
| F3 `player:` line | Walking or flying, inputs not yet acknowledged by the server, prediction corrections so far and the visual offset still fading. Corrections should stay near 0: each means client and server disagreed |
| F3 `net:` line | Round trip (a ping a second; includes the server's tick wait), bytes per second each way, the most frequent message kind |
| `set debug.net_latency_ms 150`, `net_jitter_ms`, `net_bandwidth_kbps` | Simulate a slower connection, live. The stream stays reliable and in order, as the protocol requires; packet loss, duplication and reordering arrive with the UDP transport (M7), whose reliability layer they test. |
| `set debug.net_trace 1` (next world) / `net_trace` (now) | Record every message both ways to `build/net.trace` |
| `build netdump [file]` | Print a trace, decoded by the game's own decoders: `-kind:chunk`, `-sender:client`, `-from:2 -to:3`, `-limit:20`, or `-summary` for counts and bytes per kind. Fails if any message does not decode. |
| `build replay [file]` | Feed the trace's client messages to a fresh server with the same seed, view distance and timing (`-speed:4` for faster). Whatever the server did with them (assert, crash, disconnect) happens again outside the game; its answers go to `build/replay.trace`. Exits non-zero if the server failed or disconnected the client. |

Replays repeat the server's *inputs*, not its exact output: chunk generation runs on worker
threads, so chunks can arrive in a slightly different order.

## Threads

The server and the worldgen and mesh workers log, assert and allocate like the main thread
(they inherit its context) and each has its own track in profile traces. Odin's
`-sanitize:thread` does not instrument memory accesses (as of dev-2026-10: only function
entry and exit), so it finds no races; threaded code is covered by deterministic tests
instead (`base/queue_test.odin`, `server/server_test.odin`).

## Debuggers

`build debug` builds and starts gdb (Linux) or lldb (macOS, or `--lldb`) with Odin
pretty-printers from `tools/debugger/`: strings as text, slices and dynamic arrays as their
elements, maps as key/value pairs, unions as just the active variant (or `nil`), Vulkan handles
as hex. Arguments after `--` go to the game.

To use the printers elsewhere: `source tools/debugger/odin_gdb.py` in gdb,
`command script import tools/debugger/odin_lldb.py` in lldb (or in CodeLLDB's `initCommands`).

- **Breakpoints:** Odin's debug info places a procedure's parameters correctly only after its
  first line, so `break some_proc` can show garbage arguments. Break on a line inside the body
  (`break main.odin:113`), or `next` once after stopping.
- **With `VX_BREAK=1`**, the stop is inside `base::debug_break`; `bt` shows the path, and
  `frame function client::draw` (gdb) jumps to your code.
- **Windows:** debug builds write a `.pdb` next to the `.exe`. `build debug` starts the
  [RAD Debugger](https://github.com/EpicGamesExt/raddebugger) if `raddbg` is on PATH, which
  understands Odin types; [RemedyBG](https://remedybg.itch.io/remedybg) and Visual Studio also work.
- After an Odin upgrade, run `tools/debugger/test_printers.sh`: the map printer mirrors the
  runtime's internal layout.

## GPU captures

[RenderDoc](https://renderdoc.org) (Windows, Linux) records a frame's every call, resource and
pipeline state. Start the game from RenderDoc (Launch Application, or
`renderdoccmd capture build/voxiverse`); then either press F12 in the game, or pass
`--capture-frame N` to capture frame N programmatically. Captures go to
`build/captures/voxiverse_frameN.rdc` and are listed in the log at exit. Our object names and
labels show up in RenderDoc's event browser. (The game only talks to RenderDoc when started
from it; it never loads RenderDoc itself.)

## Profiling

`build run --release --profile` writes `build/voxiverse.spall`, a trace for
[Spall](https://gravitymoth.com/spall/) (open it in the web viewer or the native app):

- **CPU:** one track per thread with nested scopes. Add your own with
  `base.profile_scope("name")`, which times the rest of the enclosing block; it compiles to
  nothing in non-profiling builds.
- **GPU:** a track named `GPU (calibrated)` with the frame and every `begin_label`/`end_label`
  section, on the same clock as the CPU tracks when the driver supports calibrated timestamps.
  Otherwise the track is named `GPU (approximate)`: durations are exact, placement relative
  to CPU work is not.

`python3 tools/debugger/check_spall.py build/voxiverse.spall` checks a trace (well-formed,
balanced, aligned when calibrated).

## In CI

Every push builds on Windows, Linux and macOS. On Linux it also runs real frames on Mesa's CPU
Vulkan driver under the validation layer (normally, with AddressSanitizer, and with profiling,
checking the trace), and checks the gdb/lldb printers. Any validation finding, leak, sanitizer
report, malformed trace or printer regression fails the build.
