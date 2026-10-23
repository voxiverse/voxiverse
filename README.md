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

## Build

`./build.sh <command>` on Linux/macOS, `build <command>` on Windows:

| Command | What it does |
|---|---|
| `check` | Type-check every package (`-vet -strict-style`, warnings are errors) and verify formatting |
| `test` | Run the unit tests |
| `fmt` | Format all sources in place |
| `shaders` | Compile `assets/shaders` to SPIR-V (only what changed) |

## Layout

See [PLAN.md](PLAN.md#layout). Packages only depend downward: `base/` depends on nothing,
`game/` never imports platform or GPU code, and `ui/` never imports the renderer.

## License

MIT, see [LICENSE](LICENSE).
