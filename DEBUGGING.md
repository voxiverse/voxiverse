# Debugging

Debug builds (`build run`, `build build`) catch most problems by themselves and say where
they came from. This page lists what they do and the switches for going further.

## What debug builds do automatically

| Problem | What you get |
|---|---|
| Vulkan misuse | The Khronos validation layer (with synchronization validation) reports it with its spec ID, the names of the objects involved, and the stack of **our** code that made the call. |
| Memory leak / bad free | Listed at exit with the file and line that allocated it; the run fails. |
| Failed `assert`, `panic`, bounds check | Message plus stack trace, then the program stops (in your debugger, if attached). |
| Everything logged | Console (Info and up) and `build/voxiverse.log` (everything, overwritten each run). |

Validation needs the layer installed (see README); without it you get one warning at startup.

## Switches

| Switch | Effect |
|---|---|
| `VX_LOG=debug` | Show debug-level messages on the console too |
| `VX_VALIDATION=0` | Validation off (debug builds) |
| `VX_VALIDATION=1` | Validation on (also works in release builds) |
| `VX_VALIDATION=best` | Plus best-practices advice (logged as "vulkan advice", does not fail runs) |
| `VX_VALIDATION=gpu` | Plus GPU-assisted validation: checks inside shaders (slow) |
| `VX_BREAK=1` | Stop in the attached debugger on validation errors and wherever `base.debug_break()` is called |
| `build run --sanitize` | Debug build with AddressSanitizer: use-after-free, buffer overflows, with the line that did it (Linux/macOS) |
| `build run -- --frames N` | Run N frames and exit; fails on any validation finding or leak (what CI does) |

Options combine: `VX_VALIDATION=best,gpu`.

## Reading a validation message

```
vulkan [VUID-vkCmdDraw-renderpass]: vkCmdDraw(): This call must be issued inside an active render pass.
  at client::draw (client/main.odin:118)
  at client::run_with_gpu (client/main.odin:107)
```

- The bracketed ID is searchable in the [Vulkan spec](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html).
- Objects appear with their names, e.g. `VkImage 0xe000000000e[swapchain image 0]`. Name new
  objects with `gpu.set_name` and bracket recorded work with `gpu.begin_label`/`end_label`.
- Some checks run on the layer's own thread after the call returned; those say so instead of
  showing a stack. Use the object names and labels, or set `VX_BREAK=1`.

## Debuggers

Debug builds carry full debug info (DWARF on Linux/macOS, a `.pdb` next to the `.exe` on
Windows).

- **Linux:** `gdb --args build/voxiverse` or `lldb -- build/voxiverse`; in VS Code, the CodeLLDB
  extension.
- **Windows:** [RAD Debugger](https://github.com/EpicGamesExt/raddebugger),
  [RemedyBG](https://remedybg.itch.io/remedybg) or Visual Studio: open `build\voxiverse.exe`.
- **macOS:** `lldb -- build/voxiverse`.

Run with `VX_BREAK=1` to stop right at a validation error with our code on the stack.

## GPU captures

[RenderDoc](https://renderdoc.org) (Windows, Linux) captures a frame with every draw call,
resource and pipeline state. Launch `build/voxiverse` from RenderDoc (Launch Application); the
object names and command labels show up in its event browser.

## In CI

Every push builds on Windows, Linux and macOS, and on Linux runs real frames on Mesa's CPU
Vulkan driver under the validation layer, once normally and once with AddressSanitizer. Any
validation finding, leak or sanitizer report fails the build.
