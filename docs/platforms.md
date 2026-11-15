# Platforms

Voxiverse is written from scratch on raw Vulkan. It requires a **64-bit computer, a graphics
driver that supports Vulkan 1.3, and an operating system recent enough for the download**.
This document describes, for each system, what those requirements mean, what the project
tests, and what it does not. Where a minimum has not been established, this document says
"not known" rather than estimating one.

## Vulkan 1.3

Vulkan is the graphics interface the game uses. It is provided by your graphics driver, not
by the game. Most graphics cards of roughly the last decade have a Vulkan driver, but 1.3 is
a more recent version of the interface. Before concluding that your system cannot run the
game, update your driver to a current release. Which cards are too old is not known.

If the game reports that it found no Vulkan 1.3 device, update the driver first.

A computer with no graphics driver of its own (a bare virtual machine, a remote desktop)
needs a software driver such as Mesa's lavapipe, which runs the game slowly.

## Downloads

| Computer | Operating system and minimum version | CPU | Graphics | Download | Status |
|---|---|---|---|---|---|
| **Windows PC** | 64-bit Windows. The lowest supported version is not known: Windows 10 and 11 are the intended versions. | 64-bit Intel/AMD | A Vulkan 1.3 driver from your GPU vendor | The `.zip` (`windows-x64`) | **Supported.** Not tested since remote CI was removed (see below). |
| **Linux PC** | A distribution with glibc 2.35 or newer (the package is built on Ubuntu 22.04, which has glibc 2.35): Ubuntu 22.04 and newer, Debian 12 and newer, Fedora 36 and newer, and distributions of the same age. Requires X11 or XWayland (Wayland desktops run the game through XWayland; there is no native Wayland backend). | 64-bit Intel/AMD | A Vulkan 1.3 driver: Mesa (open source, AMD and Intel); for NVIDIA, NVIDIA's own driver or `nouveau`/NVK | The `.tar.gz` (`linux-x64`) | **Supported.** Built, tested and played on the development machine. |
| **Mac with Apple Silicon** | macOS. The minimum asked for is macOS 13 (`MACOS_MINIMUM` in `tools/build/macos_app.odin`, passed to the linker and written into the app's `Info.plist`). | Apple Silicon (M1 or newer) | Vulkan 1.3 is provided by MoltenVK, which runs on Apple's Metal and is bundled inside the app; there is nothing to install. | A `.app` in a `.zip` (`macos-arm64`). It is ad hoc signed and not notarized, so open it the first time with right-click, Open. | **Never run on hardware by the project.** |
| **Mac with an Intel chip** | Not known | 64-bit Intel | Through MoltenVK, as above | None | **Not built and not run.** Tier 2 target. |
| **Linux on an ARM PC** (ARM servers and laptops) | glibc 2.35 or newer, as above | 64-bit ARM | A Vulkan 1.3 driver (Mesa) | None | **Not built and not run.** Tier 2 target. One extra step is required to build it: the shader compiler has no download for this platform, so install `glslang` and set `GLSLANG` (see [Building for a platform without a download](#building-for-a-platform-without-a-download)). |
| **Windows on an ARM PC** | Not known | 64-bit ARM | As for Windows | None | **Not tested.** It may compile; nobody checks. |

At the default view distance the game needs roughly one or two CPU cores and a few hundred MB
of memory. These figures have not been measured as minimums.

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
| **1** | Blocks a release. It builds, passes the full tests and runs the game on a machine of that OS before a release; release packages ship. | `windows_amd64`, `linux_amd64`, `darwin_arm64` |
| **2** | It builds and passes the unit tests. No game run; packages on request. | `linux_arm64`, `darwin_amd64` |
| **3** | Should compile. Best effort. | `windows_arm64` |

### What is tested, and where

Development and testing happen on one Linux x86_64 machine; there is no remote CI (it was
removed on 2026-11-15). So today:

| Target | Tested | Not tested |
|---|---|---|
| Linux x86_64 (`linux_amd64`) | Everything: `check`, `test`, `system`, `determinism`, the game on a real GPU and on Mesa's lavapipe (`images`). | There is no native Wayland backend; XWayland is used. |
| Windows x86_64 (`windows_amd64`), macOS arm64 (`darwin_arm64`) | `check --cross` compiles the game, the server and the test packages to objects for the target (macOS tests included, Windows tests not). Run it for any change to platform code; the plain `check` and the pre-commit hook skip it (it takes minutes). | Linking, the tests and the game. Both passed all of that on GitHub's runners up to 2026-11-12; nothing has checked them since. A release needs a run on a machine of each OS first. |
| Linux arm64, macOS x86_64, Windows arm64 | Nothing. | Everything. A Linux arm64 build needs `GLSLANG` set from the distribution's package, since the pinned shader compiler has no arm64 download. |

The project has no Mac: macOS has never been run on hardware by the project.

