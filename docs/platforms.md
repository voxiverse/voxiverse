# Platforms: will it run on my computer?

Voxiverse is a game written from scratch on raw Vulkan, so what it needs is a **64-bit
computer, a graphics driver that supports Vulkan 1.3, and an operating system new enough
for the download**. This page says, per system, what that means, what the project tests
and what it does not. Where a minimum is not known yet, it says "not yet known" instead
of guessing.

**What "Vulkan 1.3" means in practice.** Vulkan is the graphics interface the game talks to.
It comes with your graphics driver, not with the game. Most graphics cards of the last
decade or so have a Vulkan driver, but 1.3 is the newer version of it: update your
driver to a current one before deciding it does not work. Which cards are too old is
not yet known. If the game says
it found no Vulkan 1.3 device, the driver is the first thing to update. A computer with
no graphics driver of its own (a bare virtual machine, a remote desktop) needs a software
one such as Mesa's lavapipe, which runs the game slowly.

## What to download

| Your computer | OS and minimum version | CPU | Graphics | Download | Status today |
|---|---|---|---|---|---|
| **Windows PC** | Windows, 64-bit; the lowest version is not yet known (CI tests on the current Windows Server image; Windows 10 and 11 are the intended ones) | 64-bit Intel/AMD | Vulkan 1.3 driver from your GPU maker | the `.zip` (`windows-x64`) | **supported**: CI builds it, runs the tests and starts the packaged game and server; the game window itself is checked by hand only |
| **Linux PC** | A distribution with glibc 2.35 or newer (the package is built on Ubuntu 22.04, which has glibc 2.35): Ubuntu 22.04 and newer, Debian 12 and newer, Fedora 36 and newer, and distributions of the same age. Needs X11 or XWayland (native Wayland is not written yet). | 64-bit Intel/AMD | Vulkan 1.3 driver: Mesa (open source, AMD and Intel; NVIDIA's own driver or `nouveau`/NVK) | the `.tar.gz` (`linux-x64`) | **supported**: CI builds it, runs the tests, and plays it in a virtual display on a software Vulkan driver |
| **Mac with Apple Silicon** | macOS; macOS 13 is asked for (`MACOS_MINIMUM` in `tools/build`; a tester's report on an older macOS is what moves it) | Apple Silicon (M1 or newer) | Vulkan 1.3 is provided by MoltenVK, which sits on Apple's Metal and comes inside the app: there is nothing to install | a `.app` in a `.zip` (`macos-arm64`; ad hoc signed, not notarized: the first opening is by right-click, Open) | **builds and packages in CI; not tested on hardware by the project**: CI builds the game and server, runs the unit tests and makes the `.app` zip; the window, graphics, sound and pads are looked at only by occasional testers (M47d and M47e in [plan.md](plan.md)) |
| **Mac with an Intel chip** | not yet known | 64-bit Intel | through MoltenVK, as above | none yet | **builds only**, once the Tier 2 job exists ("Tier 2 CI", deferred, in [plan.md](plan.md)); it is not tested by running anything |
| **Linux on an ARM PC** (ARM servers and laptops) | glibc 2.35 or newer, as above | 64-bit ARM | Vulkan 1.3 driver (Mesa) | none yet | **builds only**, once the Tier 2 job exists ("Tier 2 CI", deferred); one extra step: the shader compiler has no download for it, so install `glslang` and set `GLSLANG` (see below) |
| **Windows on an ARM PC** | not yet known | 64-bit ARM | as Windows | none | **not tested**: it may compile, nobody checks |

The game needs about a core or two and a few hundred MB of memory at the default view
distance; those numbers are not measured as minimums yet ("not yet known").

32-bit systems are not supported on any OS.

## The tiers (for developers)

A platform's tier is what the project promises for it. It is the same idea as the Rust
toolchain's tiers. The table's last column is the machine-readable one: **the Odin target
names in backticks are read by a test** (`tools/build`, `test_platforms_doc_matches`),
which fails when Tier 1 here and `TIER1_TARGETS` in `tools/build/platforms.odin` differ.
Keep one row per tier, in this form.

| Tier | Promise | Targets |
|---|---|---|
| **1** | Blocks a release. CI builds it, runs the full tests and runs the game; release packages ship. | `windows_amd64`, `linux_amd64`, `darwin_arm64` |
| **2** | CI builds it and runs the unit tests. No game run; packages on request. | `linux_arm64`, `darwin_amd64` |
| **3** | Should compile. No CI, best effort. | `windows_arm64` |

macOS arm64 stays a Tier 1 *target*, but its status is "builds and packages in CI; not
tested on hardware by the project": there is no Mac in the project, so CI does not run the
game there and occasional testers are the only check. That gap against the Tier 1 promise is
a decision (#35, deferred work: "macOS verification in CI" in [plan.md](plan.md)), listed below. Other targets (BSDs, other CPUs) are Tier 3 and
nobody has tried them.

### What CI does today, per target

Every push to `main` runs CI (`.github/workflows/ci.yml`). Documentation-only changes do
not.

| Target | What CI does today | What is missing |
|---|---|---|
| Windows x86_64 (`windows_amd64`) | The "Test" job: format and compile check, the whole test suite, the cross-OS determinism run, a game build, the chunk benchmark, a short server benchmark. The "Package" job: builds the `.zip`, checks its paths as Explorer sees them, unpacks it, runs `voxiverse-server --version` and a 5 s server, and `voxiverse --version`, and checks the version resource. | Running the game with a window and a world: the runners have no GPU, so the game is not started past `--version` (a software Vulkan driver on the runner would do; not tried). The by-hand checks stay on a real Windows machine. |
| Linux x86_64 (`linux_amd64`) | "Test" (checks, tests, determinism, optimized tests) and "Game" (the game on a software Vulkan driver in a virtual display: flights, screens, sky, multiplayer, crash handler, AddressSanitizer, profiling, screenshots); the "Package" job builds on Ubuntu 22.04 (glibc 2.35), unpacks the `.tar.gz` and plays a world from it. | Nothing for Tier 1. Native Wayland is not written (XWayland is used). |
| macOS arm64 (`darwin_arm64`) | The "Test" job on `macos-latest`: the same checks, tests, determinism, game build, chunk and server benchmark as Windows. The Cocoa window, input and the Vulkan surface are written (M47d); the build downloads the pinned MoltenVK once (`build/tools/moltenvk/`, cached by hash in CI). | M47d wrote the Cocoa window, MoltenVK and input; M47e wrote gamepads, audio, the icon and the `.app` package, which the "Package · macOS arm64" job builds, checks (`plutil`, `codesign --verify`, `--version` of both programs) and uploads as a zip. Running the game in CI, a GPU probe and any hardware check are not done ("macOS verification in CI", deferred); testers cover them. |
| Linux arm64 (`linux_arm64`) | Nothing. | A CI job on `ubuntu-24.04-arm`: build and unit tests ("Tier 2 CI", deferred, in plan.md); `GLSLANG` set from the distribution's package, since the pinned shader compiler has no arm64 download. |
| macOS x86_64 (`darwin_amd64`) | Nothing. | A CI job on an Intel macOS runner: build and unit tests ("Tier 2 CI", deferred); the `.app` of M47e built for it only on request. |
| Windows arm64 (`windows_arm64`) | Nothing. | Anything; it is best effort. The shader compiler download has no arm64 build either. |

From #32 on, `build check` also cross-compiles every Tier 1 target that is not the host,
so code that only compiles on one OS fails before a push.

### Building for a platform without a download

The pinned shader compiler is downloaded for Windows x86_64, Linux x86_64 and macOS (see
`tools/build/glslang.odin`); on macOS the build also downloads MoltenVK (`tools/build/moltenvk.odin`). On another host, install `glslangValidator` and run
`GLSLANG=/path/to/glslangValidator ./build.sh`.

## Found a problem?

Please report it at the project's issue tracker (the link is on the README) with:

1. **Your operating system and its version** (for example "Windows 11 23H2", "Ubuntu 22.04,
   GNOME on Wayland", "macOS 15.1").
2. **Your computer's CPU** (for example "Apple M2", "Intel i5-8250U", "AMD Ryzen 5 3600").
3. **Your graphics card and its driver version.** Windows: Settings, System, Display,
   Advanced display (the card), and the driver version in Device Manager. Linux:
   `vulkaninfo --summary` (the device name and "driver"). macOS: Apple menu, About This
   Mac.
4. **The game's version**: shown on the title screen, small and grey in the lower left; or run
   `voxiverse --version`.
5. **The log file**, `voxiverse.log`: it is written beside the game (in the folder you
   unpacked), and replaced each time you start the game, so copy it before you start
   again. Attach it, or paste the first error line.
6. What you did, what you expected and what happened; a screenshot (F2 saves one to the
   `screenshots` folder, also beside the game) if it is about how something looks.

Settings and saves are not in the game folder: `settings.cfg` is in
`%LOCALAPPDATA%\voxiverse\` (Windows) or `~/.config/voxiverse/` (Linux), saves in
`%LOCALAPPDATA%\voxiverse\saves\` or `~/.local/share/voxiverse/saves/`. Do not send saves
unless asked.
