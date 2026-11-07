# The layout manifest

Where every file goes. `./build.sh check` reads the table below (the `layout` lint) and fails
on a tracked file whose name matches none of its folder's patterns, and on a tracked file in a
folder the table does not list. **Adding a folder means adding its row here in the same
commit.** The table is the whole truth: there is no exemption, skip list or default pattern.

The rows are `| folder | what belongs there | file-name patterns |`. A pattern is a glob on the
file's name (`*` and `?`), several are separated by commas. A folder's row covers the files
directly in it, not its sub-folders: each sub-folder has its own row.

## Rules

1. **Scratch only in `build/`** (gitignored). Every temporary file, test-built fixture and
   output goes under `build/` (`build/tmp/` for scratch). The `scratch` lint in `check` fails
   when an untracked, non-ignored file exists anywhere else in the tree: commit it (with its
   row here) or delete it.
2. **The folder is the noun** (see *Packages*): a feature has its own folder and
   its files drop the feature's prefix (`client/hud/hotbar.odin`, not `hud_hotbar.odin`).
   Names are singular snake_case. Platform suffixes `_linux`, `_windows`, `_darwin`, `_posix`
   and `_other` stay. A test is `<file>_test.odin`, beside the code it tests; tests spanning
   several packages, and their fixtures, go in `tests/`.
3. **One folder per tool**: a tool is a main package in `tools/<name>/`; code shared between
   tools goes in `common/`. A library-plus-tool pair keeps the library in
   `common/` or `client/` and only the command line in `tools/`.
4. **A new feature gets a new folder** (a package) and a row here. No package sits at the
   root of a collection: imports read `collection:name`.
5. **Fuzz code** is named `fuzz*.odin` (`fuzz.odin`, `fuzz_<target>.odin`; its test is
   `fuzz_test.odin`) in the package that owns the thing fuzzed.

## The cap

Cap: `70` files per package.

The `layout` lint counts the non-test `.odin` files directly in a folder (tests sit beside
their code by rule 2 and are not counted) and fails a folder over the cap; the number is
read from the line above. The largest packages are `server/core` (70 files), `common/game`
(63), `client/engine` (58) and `common/base` (40); every other package has 31 or fewer. The
cap leaves the largest no room beyond it, so a package that keeps growing splits into
feature packages rather than get a bigger number. There is no per-folder allowance (that would
be an exemption) and no per-file line cap. `server/core` is one cycle, which is why it is a
single package.

## Packages

No package sits at the root of `client/` or `server/`; each feature has its own. `server/core`
is the server's one package (its state is one cycle around `Server`, `Client` and `World`);
`client/engine` holds `App`, `Session`, and the state of every feature `App` holds, and the
feature packages (`prompt`, `menu`, `screen`, `dev`, `console`, `overlay`, `hud`, `autopilot`)
import it, in that order, with `client/main` on top. The tests that share a fixture which needs
the whole frame (`ui_frame`, `overlay_fixture`) live in `client/main`. The **cap on files per
package** is enforced by the `layout` lint (see above).

## Folders

| Folder | What belongs | Patterns |
|---|---|---|
| `.` | The repository's own top-level files; `AGENTS.md` is the contract for changes (agents and people), `CLAUDE.md` imports it | `.gitattributes`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`, `LICENSE`, `README.md`, `build.sh`, `build.bat`, `odinup.toml`, `ols.json` |
| `.github` | Repository policy: who reviews guarded paths, and the pull request template | `CODEOWNERS`, `pull_request_template.md` |
| `.github/actions/apt` | The composite action that installs packages | `*.yml` |
| `.github/actions/setup` | The composite action that sets the toolchain up | `*.yml` |
| `.github/workflows` | CI | `*.yml` |
| `.github/ISSUE_TEMPLATE` | Issue forms: playtest feedback | `*.yml` |
| `assets` | The assets' own notes | `*.txt` |
| `assets/baselines/audio` | Audio baselines, compared as text | `*.txt`, `*.decisions` |
| `assets/baselines/images` | Image baselines, their scenes' counts and their scene list | `*.png`, `*.counts`, `*.txt` |
| `assets/baselines/music` | The ear's output on every score | `*.txt` |
| `assets/baselines/net` | The bandwidth baseline | `*.txt` |
| `assets/fonts` | The one font and its licence | `*.ttf`, `*.txt` |
| `assets/music` | Rendered music: Ogg, score and decisions, credits | `*.ogg`, `*.score`, `*.json`, `*.txt`, `*.bin` |
| `assets/packs/voxiverse` | The base pack's manifest | `*.json` |
| `assets/packs/voxiverse/assets/sounds` | The base pack's sound table | `*.json` |
| `assets/packs/voxiverse/assets/textures` | The base pack's texture table | `*.json` |
| `assets/planet` | The home world's relief and its source notes | `*.bin`, `README.md` |
| `assets/sounds` | Sound recipes and the targets of their classes | `*.recipe`, `targets.txt` |
| `assets/packs/voxiverse/data/block_tags` | Block tags | `*.json` |
| `assets/packs/voxiverse/data/blocks` | Blocks | `*.json` |
| `assets/packs/voxiverse/data/game_modes` | Game modes | `*.json` |
| `assets/packs/voxiverse/data/items` | Items | `*.json` |
| `assets/packs/voxiverse/data/models` | Models | `*.json` |
| `assets/packs/voxiverse/data/shapes` | Block shapes | `*.json` |
| `assets/packs/voxiverse/data/sim` | Simulation rules (fluids) | `*.json` |
| `assets/packs/voxiverse/data/entities` | Entity kinds (animals, the engine's own) | `*.json` |
| `assets/packs/voxiverse/server/structures` | Structures | `*.vxs` |
| `assets/shaders` | GLSL sources | `*.vert`, `*.frag`, `*.comp`, `*.glsl` |
| `client/audio` | Mixer, voices, effects, spatialization | `*.odin` |
| `client/audio/synth` | The sound synthesis library: filters, modal, granular, formant and bubble sources, the layer mixer and the recipe parser | `*.odin` |
| `client/audio/testdata` | Audio test input | `*.ogg` |
| `client/autopilot` | The modes that drive the game with nobody at the keys: exit checks (`--check`), benchmarks (`--benchmark`), visual scenes (`--scene`) | `*.odin` |
| `client/console` | The developer console: its view, its command line, its world primitives, startup scripts | `*.odin` |
| `client/dev` | Developer overlays and panels: the audio recorder and inspector, the F3 panels | `*.odin` |
| `client/hud` | The in-game HUD: crosshair and hearts, hotbar, player list, item popup | `*.odin` |
| `client/menu` | The game menu, the player menu, the inventory and statistics sections | `*.odin` |
| `client/overlay` | The overlay stack's drawing and the dialogs: chat, death, dial, LAN, quit, toasts | `*.odin` |
| `client/prompt` | Button prompts: an action's glyph and the prompt bar | `*.odin` |
| `client/screen` | The title, options, credits, universes, creation, ignite, multiplayer and loading screens | `*.odin` |
| `client/engine` | The client's state and machinery: `App`, `Session`, the world copy, settings, input, prediction, sounds, and the state every feature of `App` holds | `*.odin` |
| `client/font` | The font rasterizer | `*.odin` |
| `client/formatted` | Formatted text: drawing and wrapping styled runs | `*.odin` |
| `client/gpu` | Vulkan | `*.odin` |
| `client/main` | The game's main package: entry point, frame and dispatch | `*.odin` |
| `client/mesh` | Chunk meshing | `*.odin` |
| `client/music` | The music: the piece table with its embedded files, and the director that picks what plays | `*.odin` |
| `client/planet` | The planet palette for the title and creation backdrops | `*.odin` |
| `client/platform` | Windows, input and pads per OS | `*.odin` |
| `client/render` | Frame rendering | `*.odin` |
| `client/sfx` | Sound-effect synthesis | `*.odin` |
| `client/steam` | The client's Steam: one interface over the run-time-loaded Steamworks flat API and a fake, and the Workshop (subscribed packs, publishing) | `*.odin` |
| `client/starfield` | The starfield backdrop | `*.odin` |
| `client/testkit` | Helpers the packages' tests share (the base registry, a mode by name); only tests import it | `*.odin` |
| `client/ui` | The UI toolkit | `*.odin` |
| `common/base` | Logging, clocks, jobs, pools, numbers, crash bundles | `*.odin` |
| `common/base/fuzz` | The fuzz harness | `*.odin` |
| `common/game` | The shared game rules, formats and protocol | `*.odin` |
| `common/game/testdata` | Game test input | `*.ogg` |
| `common/limited` | Child processes under a time limit, shared by the driver and the tests | `*.odin` |
| `common/netcode` | UDP connections | `*.odin` |
| `common/ogg` | Ogg and Vorbis | `*.odin` |
| `common/ogg/testdata` | Ogg digests | `*.txt` |
| `common/ogg/testdata/edge` | Edge-case Ogg files | `*.ogg` |
| `common/ogg/testdata/reference` | Reference decodes | `*.s16` |
| `common/platform` | The platform layer both binaries share: reads the machine (arguments, environment, process id, core count, folders, CPU and OS, stdout and stderr, entropy, clocks, stack calls, the system libraries to link) into the `base.Host` at boot | `*.odin` |
| `common/planet` | The home world as a planet: Earth's relief (its file format), other worlds' relief by plate tectonics (`relief_generate`: an address and seed to a relief on the same grid), sunlight, temperature, winds, ocean currents, moisture and rain, Köppen classes, rivers and lakes from the relief, the sampling of the climate, and the peoples' history | `*.odin` |
| `common/intervention` | A world's interventions log: what players did that its history carries forward, and its file | `*.odin` |
| `common/island` | The world's simulation islands: the chunks around its observers, merging and splitting as they meet and part | `*.odin` |
| `common/script` | The script language: compiler, VM, collector, libraries and trace | `*.odin`, `*.vxs` |
| `common/script/testdata/ast` | The parser's AST dumps | `*.vxs`, `*.txt` |
| `common/script/testdata/bench` | The VM's benchmark programs and their instruction budgets | `*.vxs`, `budgets.txt` |
| `common/script/testdata/conformance` | The language's conformance files | `*.vxs` |
| `common/script/testdata/fuzz/script.bytecode/regress` | Mutated bytecode a fuzzer failed on, replayed by the suite | `*.bin` |
| `common/script/testdata/fuzz/script.generated/regress` | Generated programs a fuzzer failed on, replayed by the suite | `*.bin` |
| `common/script/testdata/fuzz/script.snapshot/regress` | Snapshots the restore validation once let through, replayed by the suite | `*.bin` |
| `common/script/testdata/disasm` | Programs and their listings | `*.vxs`, `*.txt` |
| `common/script/testdata/trace` | Programs and their instruction traces | `*.vxs`, `*.txt` |
| `common/steam` | What both Steam packages share: SteamID, loading the library from beside the executable, the fake's tickets | `*.odin` |
| `common/telemetry` | Events, counters and the uploader format | `*.odin` |
| `common/worldgen` | World generators (the Earth one can stand on the planet model's relief) | `*.odin` |
| `docs` | Cheat sheets of how each system works now, and this manifest | `*.md` |
| `server/core` | The server: the world, clients, journal, save, commands, entities, pack files | `*.odin` |
| `server/collector` | The telemetry collector and developer chat | `*.odin` |
| `server/dedicated` | The dedicated server's main package | `*.odin` |
| `server/steam` | The dedicated server's Steam: auth sessions over the game server flat API and a fake | `*.odin` |
| `server/packs` | Reading pack folders from disk (L2b gathers the `pack_*` files) | `*.odin` |
| `tests` | Tests spanning several packages | `*.odin` |
| `tests/crash_fixture` | A child process the crash tests start | `*.odin` |
| `tests/panic_fixture` | A child process the panic tests start | `*.odin` |
| `tests/window_fixture` | A child process the window tests start | `*.odin` |
| `tools/analytics` | The analytics tool | `*.odin` |
| `tools/audiodump` | The audio dump tool | `*.odin` |
| `tools/bench` | The benchmark tool | `*.odin` |
| `tools/build` | The build driver | `*.odin`, `*.txt` |
| `tools/debugger` | Debugger printers and trace helpers | `*.py`, `*.sh` |
| `tools/debugger/printer_test` | The printers' test program | `*.odin` |
| `tools/fuzz` | The fuzz tool | `*.odin` |
| `tools/music` | The music renderer | `*.odin` |
| `tools/music/testdata` | The renderer's test score | `*.score` |
| `tools/music/testdata/corpus` | Public-domain MIDI files for the ear's calibration, with their sources | `*.mid`, `SOURCES.txt` |
| `tools/netdump` | The packet dump tool | `*.odin` |
| `tools/script` | The script tool (run, disasm) | `*.odin` |
| `tools/ogg` | The Ogg tool | `*.odin` |
| `tools/packcheck` | The pack checker | `*.odin` |
| `tools/replay` | The replay tool | `*.odin` |
| `tools/schema` | The schema tool | `*.odin` |
| `tools/sfx` | The sound-effect tool (`build sfx`: recipes to WAVs and a targets report) | `*.odin` |
| `tools/wireshark` | The Wireshark dissector | `*.lua` |
| `tools/planet` | The planet tool (`build planet import`: NOAA ETOPO5 to the relief file; `build planet maps [--address <a>]`: PNGs of the climate model, of Earth's or a generated world) | `*.odin` |
| `tools/worldmap` | The world map tool | `*.odin` |
