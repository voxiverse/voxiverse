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
| Frame times | Logged at exit: wall-clock and GPU time per frame (avg, p50, p99, max). |
| Everything logged | Console (Info and up) and `build/voxiverse.log` (everything, overwritten each run). |

Validation needs the layer installed (see README); without it you get one warning at startup.

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
