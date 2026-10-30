# Platforms

Voxiverse is written from scratch on raw Vulkan. It requires a **64-bit computer, a graphics
driver that supports Vulkan 1.3, and an operating system recent enough for the download**.
This document describes, for each system, what those requirements mean, what the project
tests, and what it does not. Where a minimum has not been established, this document says
"not yet known" rather than estimating one.

## Vulkan 1.3

Vulkan is the graphics interface the game uses. It is provided by your graphics driver, not
by the game. Most graphics cards of roughly the last decade have a Vulkan driver, but 1.3 is
a more recent version of the interface. Before concluding that your system cannot run the
game, update your driver to a current release. Which cards are too old is not yet known.

If the game reports that it found no Vulkan 1.3 device, update the driver first.

A computer with no graphics driver of its own (a bare virtual machine, a remote desktop)
needs a software driver such as Mesa's lavapipe, which runs the game slowly.

## Downloads

| Computer | Operating system and minimum version | CPU | Graphics | Download | Status |
|---|---|---|---|---|---|
| **Windows PC** | 64-bit Windows. The lowest supported version is not yet known: CI tests on the current Windows Server image, and Windows 10 and 11 are the intended versions. | 64-bit Intel/AMD | A Vulkan 1.3 driver from your GPU vendor | The `.zip` (`windows-x64`) | **Supported.** CI builds it, runs the tests, and starts the packaged game and server. The game window itself is checked by hand only. |
| **Linux PC** | A distribution with glibc 2.35 or newer (the package is built on Ubuntu 22.04, which has glibc 2.35): Ubuntu 22.04 and newer, Debian 12 and newer, Fedora 36 and newer, and distributions of the same age. Requires X11 or XWayland; native Wayland support is not yet written. | 64-bit Intel/AMD | A Vulkan 1.3 driver: Mesa (open source, AMD and Intel); for NVIDIA, NVIDIA's own driver or `nouveau`/NVK | The `.tar.gz` (`linux-x64`) | **Supported.** CI builds it, runs the tests, and plays it in a virtual display on a software Vulkan driver. |
| **Mac with Apple Silicon** | macOS. The requested minimum is macOS 13 (`MACOS_MINIMUM` in `tools/build`); a tester's report on an older macOS is what changes it. | Apple Silicon (M1 or newer) | Vulkan 1.3 is provided by MoltenVK, which runs on Apple's Metal and is bundled inside the app; there is nothing to install. | A `.app` in a `.zip` (`macos-arm64`). It is ad hoc signed and not notarized, so open it the first time with right-click, Open. | **Builds and packages in CI; not tested on hardware by the project.** CI builds the game and server, runs the unit tests, and produces the `.app` zip. The window, graphics, sound and gamepads are checked only by occasional testers (M47d and M47e in [plan.md](plan.md)). |
| **Mac with an Intel chip** | Not yet known | 64-bit Intel | Through MoltenVK, as above | None yet | **Builds only**, once the Tier 2 job exists ("Tier 2 CI", deferred, in [plan.md](plan.md)). It is not tested by running anything. |
| **Linux on an ARM PC** (ARM servers and laptops) | glibc 2.35 or newer, as above | 64-bit ARM | A Vulkan 1.3 driver (Mesa) | None yet | **Builds only**, once the Tier 2 job exists ("Tier 2 CI", deferred). One extra step is required: the shader compiler has no download for this platform, so install `glslang` and set `GLSLANG` (see [Building for a platform without a download](#building-for-a-platform-without-a-download)). |
| **Windows on an ARM PC** | Not yet known | 64-bit ARM | As for Windows | None | **Not tested.** It may compile; nobody checks. |

At the default view distance the game needs roughly one or two CPU cores and a few hundred MB
of memory. These figures have not yet been measured as minimums ("not yet known").

32-bit systems are not supported on any operating system.

## Tiers

A platform's tier is the commitment the project makes for it, on the model of the Rust
toolchain's tiers.

The last column of the following table is machine-readable: **the Odin target names in
backticks are read by a test** (`tools/build`, `test_platforms_doc_matches`), which fails when
Tier 1 here and `TIER1_TARGETS` in `tools/build/platforms.odin` differ. Keep exactly one row
per tier, in this form.

| Tier | Promise | Targets |
|---|---|---|
| **1** | Blocks a release. CI builds it, runs the full tests and runs the game; release packages ship. | `windows_amd64`, `linux_amd64`, `darwin_arm64` |
| **2** | CI builds it and runs the unit tests. No game run; packages on request. | `linux_arm64`, `darwin_amd64` |
| **3** | Should compile. No CI, best effort. | `windows_arm64` |

macOS arm64 remains a Tier 1 *target*, but its status is "builds and packages in CI; not
tested on hardware by the project". The project has no Mac, so CI does not run the game on
macOS and occasional testers are the only check. This gap against the Tier 1 promise is a
deliberate decision (#35; deferred work: "macOS verification in CI" in [plan.md](plan.md)),
and is listed in the table below.

Other targets (the BSDs, other CPU architectures) are Tier 3, and nobody has tried them.

### CI coverage per target

Every push to `main` runs CI (`.github/workflows/ci.yml`). Changes to documentation alone do
not.

| Target | Current CI coverage | Not covered |
|---|---|---|
| Windows x86_64 (`windows_amd64`) | The "Test" job: format and compile check, the whole test suite, the cross-OS determinism run, a game build, the chunk benchmark, and a short server benchmark. The "Package" job: builds the `.zip`, checks its paths as Explorer sees them, unpacks it, runs `voxiverse-server --version` and a 5 s server, runs `voxiverse --version`, and checks the version resource. | Running the game with a window and a world. The runners have no GPU, so the game is not started beyond `--version` (a software Vulkan driver on the runner would allow it; this has not been tried). The manual checks remain on a real Windows machine. |
| Linux x86_64 (`linux_amd64`) | "Test" (checks, tests, determinism, the smoke suite) and "Game" (the game on a software Vulkan driver in a virtual display: flights, screens, sky, multiplayer, crash handler, AddressSanitizer, profiling, screenshots). The "Package" job builds on Ubuntu 22.04 (glibc 2.35), unpacks the `.tar.gz`, and plays a world from it. | Nothing for Tier 1. Native Wayland is not written; XWayland is used. |
| macOS arm64 (`darwin_arm64`) | The "Test" job on `macos-latest`: the same checks, tests, determinism, game build, chunk benchmark and server benchmark as on Windows. The Cocoa window, input and the Vulkan surface are written (M47d). The build downloads the pinned MoltenVK once (`build/tools/moltenvk/`, cached by hash in CI). | M47d wrote the Cocoa window, MoltenVK integration and input. M47e wrote gamepads, audio, the icon and the `.app` package, which the "Package · macOS arm64" job builds, checks (`plutil`, `codesign --verify`, `--version` of both programs) and uploads as a zip. Running the game in CI, a GPU probe, and any hardware check are not done ("macOS verification in CI", deferred); testers cover them. |
| Linux arm64 (`linux_arm64`) | Nothing. | A CI job on `ubuntu-24.04-arm`: build and unit tests ("Tier 2 CI", deferred, in plan.md), with `GLSLANG` set from the distribution's package, since the pinned shader compiler has no arm64 download. |
| macOS x86_64 (`darwin_amd64`) | Nothing. | A CI job on an Intel macOS runner: build and unit tests ("Tier 2 CI", deferred). The M47e `.app` is built for this target only on request. |
| Windows arm64 (`windows_arm64`) | Nothing. | Everything; this target is best effort. The shader compiler download has no arm64 build either. |

Since #32, `build check` also cross-compiles every Tier 1 target other than the host, so code
that compiles on only one operating system fails before it is pushed.

### Building for a platform without a download

The pinned shader compiler is downloaded for Windows x86_64, Linux x86_64 and macOS (see
`tools/build/glslang.odin`). On macOS the build also downloads MoltenVK
(`tools/build/moltenvk.odin`). On any other host, install `glslangValidator` and run:

```sh
GLSLANG=/path/to/glslangValidator ./build.sh
```

## Reporting a problem

Report problems on the project's issue tracker (linked from the README). Include:

1. **Your operating system and its version**, for example "Windows 11 23H2", "Ubuntu 22.04,
   GNOME on Wayland", or "macOS 15.1".
2. **Your computer's CPU**, for example "Apple M2", "Intel i5-8250U", or "AMD Ryzen 5 3600".
3. **Your graphics card and its driver version.**
   - Windows: Settings, System, Display, Advanced display (the card); the driver version is in
     Device Manager.
   - Linux: `vulkaninfo --summary` (the device name and "driver").
   - macOS: Apple menu, About This Mac.
4. **The game's version.** It is shown on the title screen, small and grey in the lower left.
   Alternatively, run `voxiverse --version`.
5. **The log file**, `voxiverse.log`. It is written beside the game (in the folder you
   unpacked). The logs of the five runs before it are kept beside it, `voxiverse.log.1` (the
   previous run) to `voxiverse.log.5`; after a crash, the crash is in `voxiverse.log.1` once
   the game has been started again. Attach it, or paste the first error line.
6. **What you did, what you expected, and what happened.** If the problem concerns how
   something looks, include a screenshot: F2 saves one to the `screenshots` folder, also
   beside the game.

Settings and saves are not stored in the game folder:

| Platform | Settings (`settings.cfg`) | Saves |
|---|---|---|
| Windows | `%LOCALAPPDATA%\voxiverse\` | `%LOCALAPPDATA%\voxiverse\saves\` |
| Linux | `~/.config/voxiverse/` | `~/.local/share/voxiverse/saves/` |

Do not send saves unless asked.
