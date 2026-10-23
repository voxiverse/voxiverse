# Voxiverse

A voxel world you can build and break, alone or with friends. Written in
[Odin](https://odin-lang.org/) on Windows, Linux and macOS.

This branch is a from-scratch rewrite; [PLAN.md](PLAN.md) has the design and milestones.

## Setup

1. Install the toolchain with [odinup](https://github.com/voxiverse/odinup), once per machine:

   ```sh
   # Linux / macOS
   curl -sSfL https://raw.githubusercontent.com/voxiverse/odinup/main/install.sh | sh
   ```

   ```powershell
   # Windows (PowerShell)
   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/voxiverse/odinup/main/install.ps1 | iex"
   ```

2. In this repository, install the pinned compiler and tools (`odinfmt`, `ols`):

   ```sh
   odinup install
   ```

That's all. The shader compiler is fetched by the build itself on first use (a pinned,
checksum-verified glslang release in `build/tools/`).

Optional, recommended for development: the Vulkan validation layer, which debug builds turn
on automatically and which reports GPU API misuse in the log.

- Linux: `vulkan-validation-layers` (Fedora, Arch) / `vulkan-validationlayers` (Debian, Ubuntu)
- Windows / macOS: the [Vulkan SDK](https://vulkan.lunarg.com/sdk/home)

## Build

`./build.sh <command>` on Linux/macOS, `build <command>` on Windows:

| Command | What it does |
|---|---|
| `check` | Type-check every package (`-vet -strict-style`, warnings are errors) and verify formatting |
| `test` | Run the unit tests |
| `fmt` | Format all sources in place |
| `shaders` | Compile `assets/shaders` to SPIR-V (only what changed) |
| `build` | Build the game into `build/` (debug; `--release`, `--sanitize`, `--profile`) |
| `run` | Build and run; arguments after `--` go to the game, e.g. `run -- --frames 120` |
| `debug` | Build and start in gdb/lldb (RAD Debugger on Windows) with Odin pretty-printers |

Debugging and profiling (validation, leak tracking, stack traces, sanitizer, debuggers with
Odin pretty-printers, RenderDoc captures, CPU/GPU profiling): see [DEBUGGING.md](DEBUGGING.md).

## Running

`build run` opens the title screen. Singleplayer lists your worlds: create one (any text works
as a seed, or leave it empty for a random one), play, or delete. Worlds save every minute and
when you leave; they live in `voxiverse/saves` in your user data directory
(`~/.local/share` on Linux, `%APPDATA%` on Windows, `~/Library/Application Support` on macOS).

| Key | |
|---|---|
| Mouse | Look |
| <kbd>W</kbd> <kbd>A</kbd> <kbd>S</kbd> <kbd>D</kbd> | Walk |
| <kbd>Space</kbd> | Jump; double-tap to fly or stop flying (flying: up) |
| <kbd>Shift</kbd> | Sneak (flying: down) |
| <kbd>Ctrl</kbd> | Sprint |
| Left / right click | Break / place a block (hold to repeat) |
| <kbd>1</kbd>–<kbd>5</kbd>, mouse wheel | Choose the block to place |
| <kbd>Esc</kbd> | Pause menu (Resume, Leave World) |
| <kbd>F3</kbd> | Debug overlay: position, chunks, memory, server tick |
| <kbd>F4</kbd> | Tuning panel: every setting and debug switch, live |
| <kbd>`</kbd> | Console |

The console shows the log and takes commands (`help` lists them); `run -- --exec "cmd; cmd"`
runs commands at startup, e.g. `--exec "set view_radius 8; set view_height 4; singleplayer; tp 0 80 0 45 -20"`.

## Layout

See [PLAN.md](PLAN.md#layout). Packages only depend downward: `base/` depends on nothing,
`game/` never imports platform or GPU code, and `ui/` never imports the renderer.

## License

MIT, see [LICENSE](LICENSE).
