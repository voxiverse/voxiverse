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
| **Linux PC** | A distribution with glibc 2.35 or newer (the package is built on Ubuntu 22.04, which has glibc 2.35): Ubuntu 22.04 and newer, Debian 12 and newer, Fedora 36 and newer, and distributions of the same age. Requires X11 or XWayland (Wayland desktops run the game through XWayland; there is no native Wayland backend). Sound goes through ALSA's `libasound.so.2`, which every desktop distribution installs (PipeWire and PulseAudio are reached through it); without it the game runs silent. | 64-bit Intel/AMD | A Vulkan 1.3 driver: Mesa (open source, AMD and Intel); for NVIDIA, NVIDIA's own driver or `nouveau`/NVK | The `.tar.gz` (`linux-x64`) | **Supported.** Built, tested and played on the development machine. |
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


## Updates

The game updates itself from its GitHub releases (`client/update`). On reaching the title,
once a launch and in the background, it asks GitHub's API for the releases
(`https://api.github.com/repos/voxiverse/voxiverse/releases?per_page=20`). The newest
release whose tag is a version (`v0.5.3`; the rolling `playtest` release and drafts are
passed over) that is newer than the running build and has this computer's package and a
`SHA256SUMS` is offered in the title's lower right corner: "Update available: 0.5.3" and
**Update**. Versions order as semver: `0.4.0-flood.5` is before `0.4.0`. A failed check
shows nothing (the log says why).

**Update** downloads the package into `.voxiverse-update/` inside the install folder
("Downloading 0.5.3: 42%"; the menus and the game go on meanwhile), checks it, unpacks it
there, and swaps it in; the corner then says **Restart to update**, which quits as Quit
Game does (settings saved) and starts the new version with the same arguments, less the
ones that do one thing (`--exec`, `--check`, ...). Any failure is one line ("Update
failed: could not download", "...: the download did not match", "...: this folder cannot
be written; download it from voxiverse.net") and leaves the installed game as it was.

| | Windows | macOS | Linux |
|---|---|---|---|
| Fetches with | `curl.exe` in the system folder (Windows 10 and later), started with no console window (`limited.start_hidden`) | `/usr/bin/curl` | `/usr/bin/curl` or `/bin/curl` |
| Unpacks with | `tar.exe` in the system folder (it reads zips) | `/usr/bin/ditto -x -k` (listed with `/usr/bin/tar`) | `tar` in `/usr/bin` or `/bin` |
| What is swapped | Every entry of the package in the install folder. A running `.exe` cannot be deleted but can be renamed: the old one is renamed aside | `Voxiverse.app` and the package's other files beside it; an app dragged out on its own (to Applications) is swapped alone | Every entry of the package in the install folder |
| Restarts with | the new `voxiverse.exe` | `open -n Voxiverse.app --args ...` | the new `voxiverse` |

Without the system's curl and tar there are no updates (the log says so once). A game not
run from an unpacked package (a developer's `build/`) or whose folder cannot be written
(`Program Files` without administrator rights) does not try: it says so and points to
voxiverse.net.

**The swap.** Each of the package's entries is renamed aside (`<name>.voxiverse-old`),
then the new one renamed in, all inside the install folder (one filesystem, so a rename
is atomic). A rename that fails undoes the ones before it. What was renamed aside is
deleted at the next start, when nothing runs from it. Files in the install folder that are
not the package's (the log, the pipeline cache, screenshots) are not touched. The player's
data lives elsewhere and is never touched: settings, crash reports and the account key in
the user's config folder, saves in the user's data folder (`~/.config/voxiverse` and
`~/.local/share/voxiverse` on Linux, `~/Library/Application Support/voxiverse` on macOS,
`%LOCALAPPDATA%\voxiverse` or `%APPDATA%\voxiverse` on Windows). On macOS the log and the
pipeline cache sit beside the executable inside the app, so they go with the old app.

**What it trusts.** Only two addresses are fetched: the API's list above, and files at
exactly `https://github.com/voxiverse/voxiverse/releases/download/<tag>/<name>` as the
list gives them (GitHub then redirects to its storage). curl runs with explicit arguments
(no shell, no config file): https only, redirects included, TLS 1.2 or newer, at most 5
redirects, the size and the time capped, and the user agent `voxiverse-updater`; nothing
about the player or the computer is sent. The package's SHA-256 must equal its line in the
release's `SHA256SUMS` before anything is unpacked. That is integrity and GitHub's TLS,
**not a signature**: whoever can publish a release on the repository (or take over the
account) can publish an update. The list and `SHA256SUMS` are read by our own code with
every size capped (fuzz targets `update.releases`, `update.sums`). Before unpacking, the
archive's listing must be one folder of the package's name with no absolute path, no `..`
and no link; after, the unpacked tree is walked (without following links) for the same and
for the files every package has.

**Turning it off.** The player: Options, Profile, **Check for updates** (the setting
`updates`, on by default). A build: `build package --no-updater` (or `build --no-updater`:
`-define:VX_UPDATER=false`, which `check` also compiles) leaves the updater out entirely (no check, no setting), for a store such as Steam that
updates the game itself. It never checks in a development build (a version with a commit,
or `0.0.0-dev`) or in a run that does one thing (`--exec` and so `build shot`,
`--benchmark`, `--check`, `--scene`). For testing, a development build checks as the version
`VX_UPDATE_AS` gives, from a folder of releases `VX_UPDATE_SOURCE` names
([debugging.md](debugging.md#switches)); the console's `update` shows the state, checks,
installs, restarts or fakes a phase for screenshots.

**Tested.** The readers, the choice, the listing and tree checks, the swap and its undo are
unit tests on every OS that runs them; the whole update (check, download, checksum,
unpack, swap) runs from a folder of releases in `client/update`'s tests on Linux. Windows'
renames of a running executable, `tar.exe` on a zip, the console-less start of `curl.exe`,
and macOS's `ditto` and `open` have not been run.
