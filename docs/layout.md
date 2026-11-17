# The layout manifest

Where every file goes. `./build.sh check` reads the table below (the `layout` lint) and fails
on a tracked file whose name matches none of its folder's patterns, and on a tracked file in a
folder the table does not list. **Adding a folder means adding its row here in the same
commit.** The table is the whole truth: there is no exemption, skip list or default pattern.

The rows are `| folder | what belongs there | file-name patterns |`. A pattern is a glob on the
file's name (`*` and `?`), several are separated by commas. A folder's row covers the files
directly in it, not its sub-folders: each sub-folder has its own row. A row whose folder has a
`<game>` segment is a shape: it covers that folder of every game (rule 6).

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
6. **A game is a folder, `games/<game>/`**, named by the game's id (singular snake_case).
   Its rows are shapes, not folders: `<game>` stands for any game's name, so a new game adds
   no row here, and the build driver finds its packages by listing `games/`, so it adds no
   entry to a package list either. A game is three packages, as the engine is:
   `games/<game>` is its shared package (its rules, constants and the record types both
   sides use; it imports `common:` and `core:`, never `server:` or `client:`),
   `games/<game>/server` its server part (it exports the game's `core.Game`; no `client:`)
   and `games/<game>/client` its client part (it exports the game's `engine.Game`), each
   with its tests beside it. Its pack, if it has one, is `games/<game>/pack`, laid out as a
   pack ([packs.md](packs.md)): each of its folders follows the base pack's row of the same
   path (`games/<game>/pack/data/game_modes` is `assets/packs/voxiverse/data/game_modes`), so
   a game's pack adds no row either (`layout_folder` in the `layout` lint). The packages are
   named for the game, `package <game>`, `package <game>_server` and `package <game>_client`
   (as `server/steam` is `steam_server`), so no two games' parts share a name, and code
   names an import of one by it: `stopwatch.seconds(...)`, and in the lists of games
   `stopwatch_server.GAME`. Each shape gets its row with the first game that has one (a
   shape no game has is a stale row, as a folder with no file is). Nothing outside `games/`
   imports a game except the executables' main packages (`client/main`, `server/dedicated`;
   a game's client part `client/main` alone), the tools that read a session's trace
   (`tools/netdump`, `tools/replay`: the server parts' list) and the benchmarks
   (`tools/bench`, to time a game's own model), a game imports no other game, and a part
   imports no other part of its game but the shared package (but for the client part's
   tests, which play the game against its server part): the `import` lint in `check`, which
   also checks the package names. The main packages reach the games through the lists the
   driver writes from `games/` into `build/generated/games` (the packages `generated:games`
   and `generated:games/client`), so those lists are no file either.

## The cap

Cap: `70` files per package.

The `layout` lint counts the non-test `.odin` files directly in a folder (tests sit beside
their code by rule 2 and are not counted) and fails a folder over the cap; the number is
read from the line above. The largest packages are `client/engine` (69 files),
`server/core` (69), `common/game` (58) and `common/base` (34); every other package has 31
or fewer (the `layout` lint holds these counts to the tree, so they are never stale). The
cap leaves the largest no room beyond it, so a package that keeps growing splits into
feature packages rather than get a bigger number. There is no per-folder allowance (that would
be an exemption) and no per-file line cap. `server/core` is one cycle, which is why it is a
single package; what needs none of its state lives below it (`server/path`, `server/store`).

## Packages

No package sits at the root of `client/` or `server/`; each feature has its own. `server/core`
is the server's one package (its state is one cycle around `Server`, `Client` and `World`);
below it, `server/path` finds ways through the blocks from a `game.Block_Query` alone,
`server/grid` keeps a network's parts over the blocks it is told of, and
`server/store` keeps a universe's files as files (the save transaction, backups, export,
migrations, compaction), so neither knows a server and the server imports both;
`client/engine` holds `App`, `Session`, and the state of every feature `App` holds, and the
feature packages (`prompt`, `menu`, `screen`, `dev`, `console`, `overlay`, `hud`, `autopilot`)
import it, in that order, with `client/main` on top. The tests that share a fixture which needs
the whole frame (`ui_frame`, `overlay_fixture`) live in `client/main`. The **cap on files per
package** is enforced by the `layout` lint (see above).

## Folders

| Folder | What belongs | Patterns |
|---|---|---|
| `.` | The repository's own top-level files; `AGENTS.md` says how work is done here, `CLAUDE.md` imports it | `.gitattributes`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`, `LICENSE`, `README.md`, `build.sh`, `build.bat`, `odinup.toml`, `ols.json` |
| `.github/workflows` | The release workflow: a version tag's packages, built on each platform's own system (not a gate) | `release.yml` |
| `.githooks` | Git hooks: `pre-commit` runs `build check`, `commit-msg` checks the subject | `*` |
| `assets` | The assets' own notes | `*.txt` |
| `assets/catalog` | Earth's content as data before it is in the game (the schemas in its README) | `README.md` |
| `assets/catalog/fauna` | Animals, one file per biome | `*.json` |
| `assets/catalog/flora` | Plants and fungi, one file per biome | `*.json` |
| `assets/catalog/structures` | Built and natural features, one file per group | `*.json` |
| `assets/catalog/materials` | Rocks, minerals and soils | `*.json` |
| `assets/catalog/crops` | Domesticated plants and animals | `*.json` |
| `assets/catalog/cultures` | Peoples of Earth's past, one file per region | `*.json` |
| `assets/baselines/audio` | Audio baselines, compared as text | `*.txt`, `*.decisions` |
| `assets/baselines/images` | Image baselines, their scenes' counts and their scene list | `*.png`, `*.counts`, `*.txt` |
| `assets/baselines/music` | The ear's output on every score | `*.txt` |
| `assets/baselines/net` | The bandwidth baseline | `*.txt` |
| `assets/fixtures/save-v6` | A universe of save format 6 written by that format's server (a sandbox world with sheep, a dropped stack, counters): the migrations' tests open it | `*.cfg` |
| `assets/fixtures/save-v6/characters/581908591313bb46a2c4097685ed7fdc65970aa9085a25e0a63e7c35edc0a104` | Its character | `*.json` |
| `assets/fixtures/save-v6/worlds/011f27002221130f-0f18141d071e19` | Its home world | `*.cfg`, `*.json` |
| `assets/fixtures/save-v6/worlds/011f27002221130f-0f18141d071e19/journal` | Its edit journal | `*.vxj` |
| `assets/fixtures/save-v7` | A universe of save format 7 written by that format's server, the commit before the sheep left the engine (a sandbox world with the base pack's sheep, a dropped stack, counters) | `*.cfg` |
| `assets/fixtures/save-v7/characters/581908591313bb46a2c4097685ed7fdc65970aa9085a25e0a63e7c35edc0a104` | Its character | `*.json` |
| `assets/fixtures/save-v7/worlds/09180a2606240d00-030c231f211b1a` | Its home world | `*.cfg`, `*.json` |
| `assets/fixtures/save-v7/worlds/09180a2606240d00-030c231f211b1a/journal` | Its edit journal | `*.vxj` |
| `assets/fixtures/save-v8` | A universe of save format 8 written by that format's server, the commit before the markets left the engine (a planet world with its economy and interventions files, a trader with cargo and seen prices) | `*.cfg` |
| `assets/fixtures/save-v8/characters/01ff5021b7bbecff5ed759200066950cd0ffd9cf7734206027c3588a8d6f6d0a` | Its character | `*.json` |
| `assets/fixtures/save-v8/worlds/111a140f0413180e-14040022162710` | Its home world | `*.cfg`, `*.json`, `*.vxe`, `*.vxi` |
| `assets/fixtures/save-v8/worlds/111a140f0413180e-14040022162710/journal` | Its edit journal | `*.vxj` |
| `assets/fixtures/save-v9` | A universe of save format 9 written by that format's dedicated server, the commit before machines (a new sandbox universe, saved as it stopped) | `*.cfg` |
| `assets/fixtures/save-v9/worlds/2202051d0f201024-021a220c110a0e` | Its home world | `*.cfg`, `*.json` |
| `assets/fixtures/save-v9/worlds/2202051d0f201024-021a220c110a0e/journal` | Its edit journal | `*.vxj` |
| `assets/fonts` | The one font and its licence | `*.ttf`, `*.txt` |
| `assets/music` | Rendered music: Ogg, score and decisions, credits, soundfont | `*.ogg`, `*.score`, `*.json`, `*.txt`, `*.bin`, `*.sf2` |
| `assets/packs/voxiverse` | The base pack's manifest | `*.json` |
| `assets/packs/voxiverse/assets/sounds` | The base pack's sound table | `*.json` |
| `assets/packs/voxiverse/assets/textures` | The base pack's texture table | `*.json` |
| `assets/planet` | The home world's relief and climate files and their source notes | `*.bin`, `README.md` |
| `assets/sounds` | Sound recipes and the targets of their classes | `*.recipe`, `targets.txt` |
| `assets/packs/voxiverse/data/block_tags` | Block tags | `*.json` |
| `assets/packs/voxiverse/data/blocks` | Blocks | `*.json` |
| `assets/packs/voxiverse/data/game_modes` | Game modes | `*.json` |
| `assets/packs/voxiverse/data/items` | Items | `*.json` |
| `assets/packs/voxiverse/data/models` | Models | `*.json` |
| `assets/packs/voxiverse/data/shapes` | Block shapes | `*.json` |
| `assets/packs/voxiverse/data/recipes` | Recipes (the crafting grid's; a game's machines' processes) | `*.json` |
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
| `client/engine` | The client's state and machinery: `App`, `Session`, the world copy, settings, input, prediction, sounds, the client side of a game (`Game`), and the state every feature of `App` holds | `*.odin` |
| `client/font` | The font rasterizer | `*.odin` |
| `client/formatted` | Formatted text: drawing and wrapping styled runs | `*.odin` |
| `client/gpu` | Vulkan | `*.odin` |
| `client/main` | The game's main package: entry point, frame and dispatch | `*.odin` |
| `client/mesh` | Chunk meshing | `*.odin` |
| `client/texture` | The block textures drawn by code (one generator each, from a toolkit of tileable noise, cells, bricks, bevels, ramps and dithering), run at build time into the atlas the client carries, and a texture layer's mips | `*.odin` |
| `client/music` | The music: the piece table with its embedded files, and the director that picks what plays | `*.odin` |
| `client/planet` | The planet palette for the title and creation backdrops | `*.odin` |
| `client/platform` | Windows, input and pads per OS | `*.odin` |
| `client/render` | Frame rendering | `*.odin` |
| `client/sfx` | Sound-effect synthesis | `*.odin` |
| `client/steam` | The client's Steam: one interface over the run-time-loaded Steamworks flat API and a fake, and the Workshop (subscribed packs, publishing) | `*.odin` |
| `client/starfield` | The starfield backdrop | `*.odin` |
| `client/testkit` | Helpers the packages' tests share (the base registry, a mode by name); only tests import it | `*.odin` |
| `client/overview` | Seeing and commanding from above, for a game's client part: a selection of its side's entities (click, double click, box, control groups, rings on the ground), the fog of war its side sees, the minimap | `*.odin` |
| `client/playtest` | A game's client tests' rig: its server part on a stepped server, a session playing it over the harness's network and an App drawing its HUD; only tests import it | `*.odin` |
| `client/ui` | The UI toolkit | `*.odin` |
| `client/update` | The updater (docs/platforms.md, "Updates"): reading GitHub's releases and SHA256SUMS, choosing the version to offer, downloading, checking and unpacking a package, swapping it in for the installed one and restarting | `*.odin` |
| `common/access` | Who a player is and what it may do: accounts (key pairs, proofs of a nonce), the admins' list, permission nodes and grants | `*.odin` |
| `common/starmap` | A world's gate address: its glyphs, its derivation from a seed, its character and motif; a universe's seed as the player sees it | `*.odin` |
| `common/base` | Logging, clocks, jobs, pools, numbers, crash bundles | `*.odin` |
| `common/base/fuzz` | The fuzz harness | `*.odin` |
| `common/game` | The shared game rules and formats: blocks, items, entities, physics, packs and the registry, chunks, saves' encodings | `*.odin` |
| `common/game/testdata` | Game test input | `*.ogg` |
| `common/game/testdata/fuzz/pack.png/regress` | PNG textures a fuzzer failed on, replayed by the suite | `*.bin` |
| `common/protocol` | How client and server talk, above the rules they share: the messages and their codec, records and events (replication, the schema, the engine's state kinds), the transport and traces, client prediction, fetching packs | `*.odin` |
| `common/limited` | Child processes under a time limit, shared by the driver and the tests | `*.odin` |
| `common/netcode` | UDP connections | `*.odin` |
| `common/ogg` | Ogg and Vorbis | `*.odin` |
| `common/ogg/testdata` | Ogg digests | `*.txt` |
| `common/ogg/testdata/edge` | Edge-case Ogg files | `*.ogg` |
| `common/ogg/testdata/reference` | Reference decodes | `*.s16` |
| `common/platform` | The platform layer both binaries share: reads the machine (arguments, environment, process id, core count, folders, CPU and OS, stdout and stderr, entropy, clocks, stack calls, the system libraries to link) into the `base.Host` at boot | `*.odin` |
| `common/planet` | The home world as a planet: Earth's relief (its file format), other worlds' relief by plate tectonics (`relief_generate`: an address and seed to a relief on the same grid), sunlight, temperature, winds, ocean currents, moisture and rain, Köppen classes, rivers and lakes from the relief, the sampling of the climate, and the peoples' history | `*.odin` |
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
| `games` | Where the games live (rule 6) | `README.md` |
| `games/<game>` | A game's shared package: its rules, constants and the record types both sides use (the shape of every game's folder) | `*.odin`, `README.md` |
| `games/<game>/server` | A game's server part: its `core.Game` and its tests | `*.odin` |
| `games/<game>/client` | A game's client part: its `engine.Game` and its tests | `*.odin` |
| `server/core` | The server: the world, clients, journal, save, commands, entities, pack files | `*.odin` |
| `server/core/creatures_pack` | The pack of `CREATURES_GAME`, the engine's tests' game with neutral creatures of its own | `pack.json` |
| `server/core/creatures_pack/data/entities` | Its creatures | `*.json` |
| `server/store` | A universe's files as files, whatever server runs: their names, the save transaction (a batch staged, committed, recovered), backups and restores, export and import, migrations, compacting region files, the packs a universe lists and the registry built from them | `*.odin` |
| `server/path` | Pathfinding over the blocks for a body of a size: a walker's way from one block to another (A*), and fields: the way to one goal from every block of an area, which many walkers share | `*.odin` |
| `server/grid` | Networks over blocks (power lines, pipes): the parts that blocks of a grid's kinds and the machines they reach form, kept as blocks change | `*.odin` |
| `server/play` | What the server parts of games share, built on the game API alone (docs/games.md): phases and their clocks, a walled arena from a template, watchers, the admin's settings, what is kept of players by name, squads (shared routes, formations, fighting) | `*.odin` |
| `server/playtest` | A game's server tests' rig: the game on a stepped server with its players, waiting for its phases, the host's commands and what each player was told; only tests import it | `*.odin` |
| `server/collector` | The telemetry collector and developer chat | `*.odin` |
| `server/dedicated` | The dedicated server's main package | `*.odin` |
| `server/steam` | The dedicated server's Steam: auth sessions over the game server flat API and a fake | `*.odin` |
| `server/packs` | Reading pack folders from disk (L2b gathers the `pack_*` files) | `*.odin` |
| `tests` | Tests spanning several packages | `*.odin` |
| `tests/crash_fixture` | A child process the crash tests start | `*.odin` |
| `tests/panic_fixture` | A child process the panic tests start | `*.odin` |
| `tests/window_fixture` | A child process the window tests start | `*.odin` |
| `tools/analytics` | The analytics tool | `*.odin` |
| `tools/atlas` | The block texture atlas's maker: the driver runs it into `build/textures/` before anything compiles the client | `*.odin` |
| `tools/audiodump` | The audio dump tool | `*.odin` |
| `tools/bench` | The benchmark tool | `*.odin` |
| `tools/build` | The build driver | `*.odin`, `*.txt` |
| `tools/build/game_template` | The game `build new-game` stamps out, a file each, `#load`ed (`@id@`: the new game's id) | `*.txt` |
| `tools/debugger` | Debugger printers and trace helpers | `*.py`, `*.sh` |
| `tools/debugger/printer_test` | The printers' test program | `*.odin` |
| `tools/fuzz` | The fuzz tool | `*.odin` |
| `tools/music` | The music renderer, and the list of corpus files it downloads | `*.odin`, `corpus.txt` |
| `tools/music/testdata` | The renderer's test score | `*.score` |
| `tools/music/testdata/corpus` | Public-domain MIDI files for the ear's calibration, with their sources | `*.mid`, `SOURCES.txt` |
| `tools/netdump` | The packet dump tool | `*.odin` |
| `tools/script` | The script tool (run, disasm) | `*.odin` |
| `tools/ogg` | The Ogg tool | `*.odin` |
| `tools/packcheck` | The pack checker | `*.odin` |
| `tools/sheet` | The texture sheets (`build sheet`: every pack's block textures, large and named, and tiled as in the world, to `build/sheets/`) | `*.odin` |
| `tools/replay` | The replay tool | `*.odin` |
| `tools/schema` | The schema tool | `*.odin` |
| `tools/sfx` | The sound-effect tool (`build sfx`: recipes to WAVs and a targets report) | `*.odin` |
| `tools/wireshark` | The Wireshark dissector | `*.lua` |
| `tools/planet` | The planet tool (`build planet import`: NOAA ETOPO5 to the relief file; `build planet climate`: the climate file; `build planet maps [--address <a>]`: PNGs of the climate model, of Earth's or a generated world) | `*.odin` |
| `tools/worldmap` | The world map tool | `*.odin` |
