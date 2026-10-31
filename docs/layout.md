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
2. **The folder is the noun** (the target; see *The move*): a feature has its own folder and
   its files drop the feature's prefix (`client/hud/hotbar.odin`, not `hud_hotbar.odin`).
   Names are singular snake_case. Platform suffixes `_linux`, `_windows`, `_darwin`, `_posix`
   and `_other` stay. A test is `<file>_test.odin`, beside the code it tests; tests spanning
   several packages, and their fixtures, go in `tests/`.
3. **One folder per tool**: a tool is a main package in `tools/<name>/`; code shared between
   tools goes in `tools/lib/` or `common/`. A library-plus-tool pair keeps the library in
   `common/` or `client/` and only the command line in `tools/`.
4. **A new feature gets a new folder** (a package) and a row here. No package sits at the
   root of a collection: imports read `collection:name`.
5. **Fuzz code** is named `fuzz*.odin` (`fuzz.odin`, `fuzz_<target>.odin`; its test is
   `fuzz_test.odin`) in the package that owns the thing fuzzed.

## The move (state of the work: L1 of 3)

Packages are being split into feature packages (milestone row L1; spec in
[milestones/L1.md](milestones/L1.md)). Until a split is done its package's row carries the
broad pattern `*.odin`; a finished split narrows the row to the names the folder allows. The
**cap on files per package** (rule 5 of the owner's decisions, #96) is switched on by L3, when
the layout it counts is the layout it will keep: a cap that the unsplit `client` and `server`
fail cannot be switched on first, and a per-folder allowance is an exemption.

## Folders

| Folder | What belongs | Patterns |
|---|---|---|
| `.` | The repository's own top-level files | `.gitattributes`, `.gitignore`, `LICENSE`, `README.md`, `build.sh`, `build.bat`, `odinup.toml`, `ols.json` |
| `.github/actions/apt` | The composite action that installs packages | `*.yml` |
| `.github/actions/setup` | The composite action that sets the toolchain up | `*.yml` |
| `.github/workflows` | CI | `*.yml` |
| `assets` | The assets' own notes | `*.txt` |
| `assets/baselines/audio` | Audio baselines, compared as text | `*.txt`, `*.decisions` |
| `assets/baselines/images` | Image baselines and their scene list | `*.png`, `*.txt` |
| `assets/baselines/net` | The bandwidth baseline | `*.txt` |
| `assets/fonts` | The one font and its licence | `*.ttf`, `*.txt` |
| `assets/music` | Rendered music: Ogg, score and decisions, credits | `*.ogg`, `*.score`, `*.json`, `*.txt` |
| `assets/packs/voxiverse` | The base pack's manifest | `*.json` |
| `assets/packs/voxiverse/assets/sounds` | The base pack's sound table | `*.json` |
| `assets/packs/voxiverse/assets/textures` | The base pack's texture table | `*.json` |
| `assets/packs/voxiverse/data/block_tags` | Block tags | `*.json` |
| `assets/packs/voxiverse/data/blocks` | Blocks | `*.json` |
| `assets/packs/voxiverse/data/game_modes` | Game modes | `*.json` |
| `assets/packs/voxiverse/data/items` | Items | `*.json` |
| `assets/packs/voxiverse/data/models` | Models | `*.json` |
| `assets/packs/voxiverse/data/shapes` | Block shapes | `*.json` |
| `assets/packs/voxiverse/server/structures` | Structures | `*.vxs` |
| `assets/shaders` | GLSL sources | `*.vert`, `*.frag`, `*.comp`, `*.glsl` |
| `client` | The game client (being split into feature packages by L2) | `*.odin` |
| `client/audio` | Mixer, voices, effects, spatialization | `*.odin` |
| `client/audio/testdata` | Audio test input | `*.ogg` |
| `client/font` | The font rasterizer | `*.odin` |
| `client/gpu` | Vulkan | `*.odin` |
| `client/mesh` | Chunk meshing | `*.odin` |
| `client/platform` | Windows, input and pads per OS | `*.odin` |
| `client/render` | Frame rendering | `*.odin` |
| `client/sfx` | Sound-effect synthesis | `*.odin` |
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
| `common/telemetry` | Events, counters and the uploader format | `*.odin` |
| `common/worldgen` | World generators | `*.odin` |
| `docs` | Documents and this manifest | `*.md` |
| `docs/milestones` | Milestone specs | `*.md` |
| `server` | The server (being split into feature packages by L2) | `*.odin` |
| `server/collector` | The telemetry collector | `*.odin` |
| `server/dedicated` | The dedicated server's main package | `*.odin` |
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
| `tools/netdump` | The packet dump tool | `*.odin` |
| `tools/ogg` | The Ogg tool | `*.odin` |
| `tools/packcheck` | The pack checker | `*.odin` |
| `tools/replay` | The replay tool | `*.odin` |
| `tools/schema` | The schema tool | `*.odin` |
| `tools/sfx` | The sound-effect tool | `*.odin` |
| `tools/wireshark` | The Wireshark dissector | `*.lua` |
| `tools/worldmap` | The world map tool | `*.odin` |
