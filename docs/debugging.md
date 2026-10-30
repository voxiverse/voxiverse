# Debugging and profiling

Debug builds (`build run`, `build build`) detect most problems automatically and report
where they originated. This document describes what debug builds do, the switches that go
further, debuggers, GPU captures, benchmarking and profiling, and the developer-facing
behaviour of the game's systems. Everything described here is exercised in CI or by
`tools/debugger/test_printers.sh`.

## What debug builds do automatically

| Problem | Result |
|---|---|
| Vulkan misuse | The Khronos validation layer (with synchronization validation) reports it with its spec ID, the names of the objects involved, and the stack of **our** code that made the call. |
| Memory leak / bad free | Listed at exit with the file and line that allocated it; the run fails. |
| Failed `assert`, `panic`, bounds check | A message and a stack trace, after which the program stops (in your debugger, if one is attached). |
| Crash (segfault, access violation, illegal instruction, stack overflow on the main thread) | The signal or exception, the faulting address and a stack trace in the console and the log, followed by the usual crash handling (core dump, Windows Error Reporting, or your debugger). The `crash` command (debug builds) tests this. It is disabled in sanitizer builds, which report crashes themselves. |
| Frame times | Logged at exit: wall-clock and GPU time per frame (avg, p50, p99, max). |
| Everything logged | Written to the console (Info and above) and to `build/voxiverse.log` (everything). The five previous runs' logs are kept as `voxiverse.log.1` (the previous run) to `voxiverse.log.5`. |

Validation requires the layer to be installed (see the README). Without it, the game logs one
warning at startup.

## Reading the log

```
console:    3.214 INFO  server     server player joined name="player"
            3.215 WARN  main       gpu renderdoc is loaded but did not provide API 1.6 (client/gpu/renderdoc.odin:60)
file:       3.214512 | INFO | server | server player joined name="player" | server/server.odin:224
```

Each line contains:

1. the seconds since start;
2. the level;
3. the thread that logged it (`main`, `server`, `worldgen 2`, `mesh 1`);
4. the message: what happened, followed by `key=value` pairs to filter on, for example
   `grep 'pos=\[1,6,4\]' build/voxiverse.log`.

The console adds the source location to warnings and errors; the file includes it on every
line.

In new code, begin each message with the subsystem (`gpu`, `server`, `session`, ...) and
write values in `key=value` form.

## Switches

| Switch | Effect |
|---|---|
| `VX_LOG=debug` | Also shows debug-level messages on the console. |
| `VX_VALIDATION=0` / `1` | Validation off (development builds) / on (also in release builds). |
| `VX_VALIDATION=best` | Adds best-practices advice (logged as "vulkan advice"; does not fail runs). |
| `VX_VALIDATION=gpu` | Adds GPU-assisted validation: checks inside shaders (slow). |
| `VX_BREAK=1` | Stops in the attached debugger on validation errors and wherever `base.debug_break()` is called. |
| `build run --sanitize` | AddressSanitizer build: reports use-after-free and buffer overflows with the offending line (Linux/macOS). |
| `build run --profile` | Writes a profile trace (see [Profiling](#profiling)); combine with `--release`. |
| `build debug [--lldb]` | Starts a debug build in gdb (or lldb) with the Odin printers loaded. |
| `run -- --frames N` | Runs N frames and exits; fails on any validation finding or leak (as CI does). |
| `run -- --capture-frame N` | Under RenderDoc: captures frame N (see [GPU captures](#gpu-captures)). |
| `run -- --exec "cmd; cmd"` | Runs a script of console commands, e.g. `--exec "screen options"` to reproduce a state. Scripts can pause with `wait <frames>` and `wait_world` (until the world has loaded and meshed): `--exec "singleplayer; wait_world; screenshot world; wait 3; quit"`. |
| <kbd>F2</kbd> / `screenshot [name]` | Saves the next frame as `build/screenshots/<name>.png`. CI uploads the folder; the world runs take a screenshot at the start and end of each flight. |
| <kbd>F3</kbd> / `debug` | Overlay: FPS, frame and GPU time per frame and the present mode (FIFO with vsync; IMMEDIATE without, or MAILBOX where the window system offers nothing else), position, client/server chunk counts, chunk memory, session arenas, meshing queue, draws, server tick time. |

Options combine, e.g. `VX_VALIDATION=best,gpu` or `build run --release --profile`.

## Reading a validation message

```
vulkan [VUID-vkCmdDraw-renderpass]: vkCmdDraw(): This call must be issued inside an active render pass.
  at client::draw (client/main.odin:118)
  at client::run_with_gpu (client/main.odin:107)
```

- The bracketed ID can be searched for in the
  [Vulkan specification](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html).
- Objects appear with their names, e.g. `VkImage 0xe000000000e[swapchain image 0]`. Name new
  objects with `gpu.set_name`, and bracket recorded work with `gpu.begin_label`/`end_label`
  (which also times it on the GPU).
- Some checks run on the layer's own thread after the call has returned. Those messages say
  so instead of showing a stack. Use the object names and labels, or `VX_BREAK=1`.

## Variables

Settings (saved), debug switches (`debug.*`, never saved) and, later, game rules are plain
struct fields described by variable tables; see plan.md, "Console and variables".

| Command | Effect |
|---|---|
| `vars [filter]` | Lists variables, their values and their help. |
| `set <name> <value>` / `reset <name>` | Changes a variable / resets it to its default. Out-of-range values are clamped, with a warning. |
| <kbd>F4</kbd> / `tune` | Opens the tuning panel: every variable as a slider or checkbox, live. |

Settings are saved to `settings.cfg` in the user configuration directory
(`~/.config/voxiverse/` on Linux), or to the path in `VX_SETTINGS` (empty: none). Changes made
by `--exec` scripts are never saved, so test runs cannot alter your settings.

To add a variable, add the field to its struct, its default, and one line to the table. A
test checks every table.

## Shader hot reload

In development builds, saving a file in `assets/shaders` recompiles it (through
`build/build-driver shaders`) and swaps the affected pipelines within about a second. A shader
that fails to compile logs glslang's message with file and line, and the previous shader keeps
running. `set debug.hot_reload_shaders 0` disables hot reload.

`scene.glsl` is included by the world, sky and entity shaders (the per-frame scene, sky
colours, clouds); saving it reloads all three. `client/passes.odin` lists the passes and what
they include.

`time <name|0..1>` together with `set rules.daylight_cycle 0` holds the sky still while you
work on it.

## Saves

A save is a universe, which is a directory. It contains:

- `universe.cfg`: the format, seed, the home world's address, and the starter kit;
- `characters/<account>/<name>.json`: each character's world, position and orientation,
  flying state, and inventory by item name; written when it changed;
- `permissions.cfg` and `community.cfg`;
- `worlds/<address>/` for each world visited or edited, containing:
  - `world.cfg`: generator, seed, time, spawn, rules, generator parameters;
  - `entities.cfg`;
  - `regions/`, with the edited chunks only (`r.<x>.<z>.vxr`, 16x16 chunk columns each); the
    rest regenerates from the seed. A chest's contents are its block entity, saved with its
    chunk.

A directory from before universes (a `world.cfg` at the top) becomes a universe when opened,
and its world becomes the home world. Files are replaced through a temporary file, so a crash
during a save keeps the previous save. A region file that fails its checksum is moved aside
(`.damaged-<time>`) with an error, and is never loaded. `server/save_test.odin` covers save,
quit and load, edits surviving unloading, and damaged files.

[saves.md](saves.md) describes the save format and transaction in full.

## Worlds

A universe contains worlds, named by addresses (plan.md, M17). An address consists of a
galaxy of eight Old Turkic symbols and a world of seven. It is written in one of two forms:

- as symbols, `𐰀𐰁𐰄𐰅𐰇𐰉𐰊 𐰋𐰌𐰍𐰎𐰏𐰐𐰒𐰔` (world, then galaxy; seven symbols alone mean the
  current galaxy);
- as a directory name, `0001020304050607-08090a0b0c0d0e` (two hex digits per symbol, galaxy
  first). This form can be typed on any keyboard.

The address alone determines the world's kind (generator parameters, palette, gravity, day
length); the universe seed determines its terrain. The home world is Earth. A world loads when
someone travels there, and unloads (saved, its memory freed) after `WORLD_IDLE_SECONDS`
empty; the home world remains loaded.

| Server command | Effect |
|---|---|
| `travel <address> [character]` | Goes to the world's spawn, carrying the character (`world.travel`; another's: `world.travel.others`). Players use gates. |
| `address` | Shows this world's address in both forms (`info.address`). |
| `worlds` | Lists the loaded worlds and who is in each, and how many are saved (`info.worlds`). |

### Gates

Gates (M18) travel between the worlds of a galaxy. They are rare structures, none within
`worldgen.gate_distance` (2000) blocks of a world's middle. `locate gate` places an admin in
front of the nearest one.

To use a gate, right-click its ring (or use the console's `dial [address]`; `look <yaw>
<pitch>` turns for scripted screenshots) and pick seven symbols. The chevrons lock, both ends
open for 30 s, and walking into the horizon arrives at the dialed world's gate nearest its
middle. Refusals are returned as notices. The server logs `gate dialed`.

Homes, warps, `back` and `tp` remember their world and travel when needed. The client's chat
and console draw the symbols from a fallback font
(`assets/fonts/noto_sans_old_turkic_regular.ttf`).

## Sound

Every sound effect is synthesized at startup (`client/sfx`; there are no recordings) and mixed
by our own mixer (`client/audio/`). miniaudio only opens the sound card. Every Ogg file, including
the music and a pack's sounds, is decoded by our own Odin code, `common/ogg` (see
[The Ogg decoder](#the-ogg-decoder)).

- `build sfx` writes every sound effect to `build/sounds/*.wav` for listening outside the game.
- F3 shows the device, the voices playing, and the sounds played and dropped. The log's last
  `audio` line summarizes the run.
- Without a sound card (CI, a headless machine) the game logs a warning and runs silently.
- `set volume 0..1` sets the player's volume.
- On Linux and macOS the build compiles Odin's miniaudio library once (into the Odin
  installation; Windows ships it), which requires a C compiler.

### The Ogg decoder

`common/ogg` is a Vorbis I decoder and an Ogg reader (M53c). It rejects malformed input with
an `Error` and never allocates beyond `open`'s single block. Its maintenance commands are:

| Command | Effect |
|---|---|
| `build ogg digests` | Rewrites `common/ogg/testdata/digests.txt` (FNV-1a of every decoded `f32` of the music, the small test files and the edge-case files) and prints the lines that changed. A digest changes only with an intended decoder change. |
| `build ogg reference` | Rewrites `common/ogg/testdata/reference/` from the reference decoder (libvorbis through `ffmpeg` on the `PATH`; used only here, and the output is committed): half a second at the start, middle and end of each music file, and each edge-case file whole. `reference.odin` lists which edge-case files have no reference, and why. |
| `build ogg make-test-files` | Rewrites `common/ogg/testdata/edge/` (`tools/ogg/make.odin`): valid Vorbis streams of seeded random packets over a fixed codebook set, one file per feature (every block size, tiny and cut streams, mono, coupled stereo, six channels, floor 0, residue 0 and 2, pages, chained links). Run it only to change those files; the digests and references must then be regenerated. |
| `build ogg fuzz [--seed N] [--iterations N]` | Runs the same fuzzing as `test_ogg_fuzz`, for longer. The input is written to `build/fuzz/current.bin` before each run, so a crash leaves it there. Copy it to `common/ogg/testdata/regress/` and the suite replays it first. |
| `build bench ogg` | Decodes the music with `common/ogg` and with miniaudio, best of three, and reports seconds of audio per CPU second for both and their ratio. |

## Keeping the screen awake

While the player is in a world, not paused and not in the game menu, the screen is kept on.
The request is released otherwise and on exit (`platform.set_keep_awake`, logged as
`platform keep awake`).

| Platform | Mechanism |
|---|---|
| Windows | `SetThreadExecutionState`. |
| Linux | The freedesktop screensaver's `Inhibit` over D-Bus (libdbus loaded at run time), or else the desktop portal's (Wayland desktops); plus `XResetScreenSaver` every 30 s for X's own blanking. |
| macOS | An IOKit power assertion (with M1b's window). |

Where no mechanism responds, the game logs this and does nothing further.

## Debug drawing

`render.debug_line` and `render.debug_box` draw world-space lines for one frame from anywhere
on the main thread. The lines are hidden behind terrain and never hide it. See
`world_debug_lines` in `client/camera.odin`. `set debug.chunk_borders 1` outlines the
camera's chunk and its neighbours' edges.

## Commands

Commands are provided by three surfaces, each with a single purpose:

- **Server commands** act on the world and the players. They start with a slash, in the chat
  and in the console alike.
- The **developer console**'s plain words belong to the client itself and never act on the
  world.
- **Checks and benchmarks** are command-line modes.

### Server commands

Server commands are entered as `/command` in the chat or in the console. Every change to the
world is made by the server, and permissions determine who may run what (see
[Permissions](#permissions)).

Wherever a command takes a player, `@s` denotes you, `@p` the nearest other player, `@r` any
player, and `@a` every player, where that is meaningful (`/give @a`, `/tp @a @s`).
Coordinates may be relative (`~`, `~5`, `~-2`); the first of a run is x, then y, then z.
`/help` lists the commands you may use, and `/help <command>` shows a command's usage and
permission.

The commands most relevant when debugging a world are:

| Command | Effect |
|---|---|
| `/time set <t>`, `/time add <hours>`, `/time query` (and `/time <t>`) | The time of day: `sunrise day noon sunset night midnight` or `0..1` (`world.time`). `/rule daylight_cycle false` stops the clock; `day_length` is seconds per day. |
| `/rule [name] [value]` (`/gamerule`) | Lists the world's rules, shows one, or sets one (`world.rules`): `random_tick_speed`, `drops`, `reach`, ... |
| `/tp <x y z> [yaw pitch]`, `/tp <player>`, `/tp <who> <player>`, `/spawn`, `/setworldspawn [x y z]` | Moves (angles in degrees; `/tp ~ ~10 ~` goes up ten blocks); returns to the world spawn; sets where new players arrive. A new world's spawn is found by the generator's search (dry open land, no tree or structure nearby), chosen once and kept in `world.cfg`. |
| `/setblock <x y z> <block>` | Sets one block, through the bulk edit pipeline (`world.edit.bulk`). |
| `/summon [kind] [count]`, `/kill <kind\|all> [radius]` | Summons sheep in front of you (`world.summon`). Sheep also appear by themselves in daylight on grass 16-40 blocks from a player, at most 6 near one player, and despawn when nobody is within 80 blocks. `/kill` removes the entities of a kind within a radius (`world.kill`). |
| `/locate [biome\|structure] <name>` | Flies to the nearest biome or structure (`teleport.locate`): `village`, `dungeon`, `gate`, ... |
| `/give <player\|@a> <item> [count]`, `/clear [player] [item]`, `/wear`, `/seed` | Items (`items.give`; what does not fit is dropped at the player's feet); puts on all the armour carried; shows the world's seed. |
| `/regen [radius]` | Regenerates the unedited chunks within a radius (1-8 chunks) from the generator in its current configuration (`world.gen`). |
| `/pos1 [x y z]`, `/pos2 [x y z]`, `/sel` | Sets the selection's corners (the block you are looking at, within 128 blocks, or the given coordinates), kept by the server and drawn as a box / clears the selection. |
| `/fill [box] <block>`, `/replace [box] <from> <to>`, `/sphere [x y z] <radius> <block>` | Bulk edits (`world.edit.bulk`; at most 64x64x64 blocks) of the selection, or of a given box `x1 y1 z1 x2 y2 z2`. The server applies them in one pass and sends each touched chunk whole, after a `Bulk_Begin` stating how many follow. |
| `/structure save <name> [box] [clear]`, `/structure paste <name> [x y z] [turns]`, `/structure list` | Keeps the selection (or a box) as `<world>/structures/<name>.vxs` / places one at pos1 (or x y z) through the bulk edit pipeline, turned 0-3 quarters (`world.structure`). |
| `/stats [player] [filter]` | Counters (see [Statistics and events](#statistics-and-events)). |

Minecraft's command names are accepted where the equivalent exists: `/tell`, `/w`, `/say`,
`/gamerule`, `/teleport`.

### The developer console

The developer console is opened with `~`; the chat's `/` commands also work in it. Its
commands are:

| Command | Purpose |
|---|---|
| `singleplayer` | A scratch world, never saved. |
| `universe <name>` | A saved world. Saves go to `VX_SAVES` if it is set. |
| `join`, `leave`, `quit`, `screen` | Session and screen control. |
| `set`, `vars`, `reset` | Settings, `debug.*`, `rules.*` and `worldgen.*`. The last two belong to the server, which announces changes. |
| `screenshot`, `net_trace`, `crash` | Diagnostics. |
| `look <yaw> <pitch>` | Places the camera for a picture. |
| `clear`, `help` | Console housekeeping. |

A plain word that is a server command prompts the user to use the slash. Nothing in the
console duplicates a key, the UI or a server command.

### Scripts

Scripts (`--exec "cmd; cmd"`) are console input typed at startup, with the additional
commands `wait <frames>`, `sleep <seconds>` and `wait_world`. They exist to reproduce a state
and capture its picture.

### Checks

Checks and measurements are implemented in code:

| Check (`--check <name>`) | Description |
|---|---|
| `fly` | The memory check. Flies 400 blocks at 40 blocks/s (view 6 x 3), and fails if either session arena grew or chunk storage exceeded its fixed size. Logs frame times and resident memory. |
| `tour` | The M10 check. Visits every biome (view 4 x 3) and screenshots each (`biome_<name>`), then fails on a biome not found, a frame p99 over 100 ms, chunk generation or meshing p99 on the workers over budget (5 and 10 ms in an optimized build, ten times that otherwise), or memory growth after the first biome. |
| `blast` | The M9 check. Hovers above the spawn (view 4 x 2) and sets off 12 rockets and explosions in turn, then fails on a frame p99 or server tick over 100 ms, a blast not shown whole (its meshes in one frame), arena growth, or chunks that differ from the server's (both sides hash them). |

A check runs with the benchmarks' fixed settings (its own view), after any `--exec` script
(which may prepare the state, e.g. `--exec "set debug.net_trace 1" --check fly`), and then
quits, failing the run if the check failed.

`--check fly` is the M3 exit check. CI runs it on the CPU driver, with AddressSanitizer and
with profiling. CI also runs `--check blast`. F3 shows how many bulk edits were shown whole
and how many late (on a timeout).

F3's `chunks:` line shows how long chunks take to generate (on our own server's workers) and
to light and mesh (ours), as the average and the slowest 1%.

## Permissions

What a player may do is a set of nodes:

- `world.edit` (build), `world.edit.bulk`, `world.fire`, `world.summon`, `world.structure`,
  `world.time`, `world.rules`, `world.gen`;
- `debug.coordinates` (F3 shows position, chunk and the block underneath when
  `rules.show_coordinates` is off);
- `teleport.tp`, `teleport.locate`;
- `server.save`, `server.export`, `server.open_lan`;
- `permissions.edit`;
- the `chat.*`, `moderation.*`, `teleport.*` and `info.*` nodes the commands use.

### Grants

A grant is a node, `x.*` (x and everything under it), `*` (everything), or `-x` (not x).

Grants are resolved as follows:

1. The most specific grant wins.
2. At the same specificity, the player's own grant beats their role's grant, which beats an
   inherited grant.
3. A tie is a denial.

### Roles

Roles grant nodes, inherit other roles, and carry metadata (`prefix`, a chat tag such as
`&c&lAdmin`). Every player has the role `default`. A new world has three roles:

| Role | Grants |
|---|---|
| `default` | Build, chat, travel. |
| `mod` | Inherits `default`; all of chat and moderation, and `teleport.tp`. |
| `admin` | Inherits `mod`; `*`. |

The local player of a world played locally, and every player of a server started with
`--cheats`, has `*`.

### Commands

| Server command | Effect |
|---|---|
| `role list`, `role info <role>` | Lists the roles / shows one role's inherited roles, grants and metadata. |
| `role grant\|revoke <role> <node>` | Grants or revokes a node (`-x` denies). The first grant creates the role. |
| `role inherit\|uninherit <role> <role>`, `role meta <role> <key> [value]`, `role delete <role>` | Manages inheritance and metadata, or deletes a role. |
| `user info <player>`, `user role add\|remove <player> <role>` | Shows a player's roles and grants / adds or removes a role. |
| `user grant\|revoke <player> <node>`, `user meta <player> <key> [value]` | Manages the player's own grants (the most specific) and metadata. |

From the console, prefix the command with `server`, e.g. `server role grant mod world.fire`.
These commands require `permissions.edit`. Each change is sent to the players it affects and
saved in `<world>/permissions.cfg`.

A dedicated server has no owner. To make the first admin, stop the server and edit that file:
add `player alice`, and `role admin` on the next line.

A client requests only what its grants allow (the console reports "not allowed on this
server"). The server checks again, and answers a refusal with a notice, not a disconnect.

## Accounts and characters

The game creates an account on first launch: an Ed25519 key, stored as `account.key` beside
the settings. Whoever holds that file holds the account; back it up.

When joining, the handshake proceeds as follows:

1. The client sends the account and a character name (`Hello`).
2. The server sends a random nonce (`Challenge`).
3. The client sends its signature over the nonce (`Proof`). A wrong signature is refused, and a
   proof is valid for one nonce only.

A character name belongs to the first account that plays it in that universe (otherwise:
`that name is another account's`). An account has at most 8 characters in a universe. From
the Multiplayer screen, the client requests its characters (`Characters`) and chooses one, or
creates one. Singleplayer, `join` and scripts play the settings' `name`.

Each character is stored in `characters/<account>/<name>.json`. A `players/<name>.json` from
before accounts is assigned to the first account that plays that name.

- `ban` also bans the character's account (`ban_account` in community.cfg).
- `account <hex>` in permissions.cfg grants to every character of an account.
- `whois` shows a character's account (`moderation.address`).

## Items

Items are data (`common/game/items.odin`). Every block players may place has its own item,
named after the block. Tools are items of their own (`rocket_launcher`).

### Inventories

An inventory has 30 slots (the first five are the hotbar, followed by a 5x5 grid) and the
stack on the cursor. The server owns the inventory and applies requests with the same code the
client predicts with (`common/game/inventory.odin`). It answers each request with the
inventory (the `inventory` record, whose `acked` field states how far it got); a refused
request is rolled back.

- Placing a block uses one from the hand (or the hotbar), unless the player has
  `items.infinite`.
- Breaking a block drops the block's item where `rules.drops` is set (not for
  `items.infinite`).
- `items.catalog` lets the inventory take any item.
- A player new to a world receives `world.cfg`'s `kit`.

Dropped stacks are entities. They fall, merge with stacks of the same item, are picked up by
walking over them (after half a second; two seconds for the player who dropped them), and
despawn after five minutes.

### Chests

A chest (`server/containers.odin`) is a block with a container block entity of 25 stacks,
kept with its chunk (`server/block_entities.odin`) and created when the block is placed.

Right-clicking a chest sends `Use_Block`. The server then places the entity's slots in that
player's `Inventory` (`chest`, `chest_open`), so that ordinary requests may name slots
`CHEST_BASE ..< ALL_SLOTS` and the client predicts them. The record is copied in before each
request and out after it, and other players viewing the chest are notified.

The chest closes on the `Close` request, or automatically when the player moves more than the
reach plus two blocks away or the block is removed. The entity is removed with its block
(broken, blown up, or edited in bulk; one code path, `entity_lifecycle`), and its contents
spill out. `server/containers_test.odin` covers this behaviour.

### Commands

| Command | Effect |
|---|---|
| `inventory`, `drop [all]` | Opens the inventory / drops from the hand (as E and Q do; for scripts). |
| `use` | Presses the right button once on the target (for scripts): a chest opens and shows its overlay, a sheep is sheared. |
| `/give <player> <item> [count]` | `items.give`; what does not fit is dropped at the player's feet. |
| `server clear [player] [item]` | Empties an inventory, or removes one item from it (`items.clear`; another player's: `items.clear.others`). |
| `server item` | Shows the held item, its ID and its stack size. |

## Statistics and events

Everything the server counts or measures is an *event* (`common/telemetry/`: one kind per row of
`KIND_INFO`, which defines the meaning of its fields). `record` (`server/stats.odin`) emits the
event and adds to the counters the kind names, both the player's and the world's.

### Counters

Counters have dotted names (`blocks.mined.stone`, `distance.walked` in cm, `time.played` in
seconds, `commands.time`, ...). A parent counter is the sum of the counters below it. Counters
are stored in the character's file (`"stats"`) and in `<world>/stats.json`.

In the game, counters are shown by:

- the `stats [player] [filter]` command (30 lines in chat; another player's counters require
  `info.stats.others`);
- the statistics screen (key `K`, or `screen stats`).

### The event log

The event log is `<universe dir>/telemetry/YYYY-MM-DD.jsonl`, one JSON object per line: the
time in ms, the tick, the session, the actor (the player's ID), the kind, the world, the
position, and the kind's fields. It is written by a dedicated thread. A full buffer drops
events and records this in an `events_dropped` line. A day's log stops at 64 MiB. A scratch
world (no save directory) writes nothing.

### Client reports

Client reports (`Client_Info`, `Client_Overlay`, `Client_Perf`) arrive in a
`Telemetry_Report` message, at most six per minute, and are validated. Refusals are counted
in the world's `telemetry.refused`.

### Querying the log

With jq:

```sh
jq -c 'select(.k=="block_mined")' <universe>/telemetry/*.jsonl
```

With DuckDB:

```sql
select k, count(*) from read_json_auto('<universe>/telemetry/*.jsonl') group by 1 order by 2 desc
```

[telemetry.md](telemetry.md) describes collection and consent.

## Chat

`t` opens the chat, and `/` opens it with a command started (`/spawn`; the server runs it, as
the console's `server spawn` does). `say <words>` and `chat [text]` do the same from the
console and from scripts.

The server processes each line as follows:

- it numbers the line;
- it adds the speaker's tag (their role's `prefix` metadata, and `suffix`) and nickname;
- it keeps formatting codes only where the speaker has `chat.format.color`,
  `chat.format.rgb` or `chat.format.style` (otherwise they are shown as written);
- it drops control characters;
- it allows 5 lines at once, then one per second;
- it logs every line (`server chat`).

Each part (tag, name, words) is formatted separately, so no explicit `&r` is needed.

### Formatting codes

| Code | Effect |
|---|---|
| `&0`-`&f` | Colours. |
| `&#rrggbb` | An RGB colour. |
| `&l` | Bold. |
| `&o` | Italic. |
| `&n` | Underline. |
| `&m` | Strikethrough. |
| `&r` | Plain. |
| `&&` | A literal `&`. |

A colour code clears the styles before it.

### Chat commands

| Server command | Effect |
|---|---|
| `ignore <player>` | Stops (or resumes) hearing a player (`chat.ignore`). |
| `mute <player> [30m\|2h\|7d]`, `unmute <player>` | Mutes for a period or permanently (`moderation.mute`). |
| `delmsg <player> [count]` | Removes a player's newest lines from everyone's chat (`chat.delete`). |

### People and places

The following server commands are modelled on EssentialsX's. Enter them as `/name` in chat,
or `server name` in the console. Each requires the permission given in brackets.

| Command | Effect |
|---|---|
| `home [name]`, `sethome [name]`, `delhome <name>`, `homes` | Your homes (`teleport.home`; at most your role's `max_homes` metadata, 3 for `default`). |
| `warp [name]`, `warps` / `setwarp <name>`, `delwarp <name>` | The world's warps (`teleport.warp` / `teleport.warp.set`). |
| `tpa <player>`, `tpahere <player>`, `tpaccept`, `tpdeny` | Requests to go to someone, or for them to come to you (`teleport.tpa`; two minutes to answer). |
| `back`, `top`, `spawn` | Where you were before your last teleport / up onto the highest block / the world spawn. |
| `tp <player>`, `tp <x y z>`, `tp <player> <player>`, `tphere <player>` | `teleport.tp`; moving other players requires `teleport.tp.others`. |
| `msg <player> <words>`, `r <words>`, `me <action>`, `broadcast <words>` | Whisper, reply to the last whisper, an action, a message to everyone (`chat.msg`, `chat.me`, `chat.broadcast`). |
| `nick <nickname\|off> [player]`, `realname <nickname>` | A nickname: a name's letters, formatted as you may format chat, and never another player's name (`chat.nick`; others': `chat.nick.others`). |
| `motd [set <words>]` | The message of the day, shown on joining (setting it requires `server.motd`). |
| `kick <player> [reason]` | `moderation.kick`. |
| `ban <player> [reason]`, `tempban <player> <30m\|2h\|7d> [reason]`, `unban <player>` | `moderation.ban`. |
| `ban-ip <player\|address> [reason]`, `unban-ip <address>` | Bans everyone from that address (`moderation.ban_ip`). |
| `list`, `whois <player>`, `seen <player>`, `afk`, `status` | Who is present; who someone is (their address, with `moderation.address`); when they were last present; away (moving or speaking ends it); ticks, chunks, memory. |

Nobody may kick, ban or mute a player with `moderation.exempt` (admins, the host). The host
cannot be kicked at all. Nicknames, mutes, ignores, homes, warps, bans, last-seen times and
last addresses, and the message of the day are stored in `<world>/community.cfg`.

## Overlays

Every in-game panel is an overlay on a single stack (`client/overlay.odin`): the game menu,
Options, tuning, chat, console, and the quit dialog. Each overlay declares whether it takes
the keyboard, frees the mouse, or pauses the world. The top overlay receives the keys, the
focus and Escape.

## Liquids

Water levels are block IDs (a source, flow levels 1-7, falling), so saves and the protocol
require nothing new.

The server runs scheduled block updates (`server/liquids.odin`): a queue ordered by tick and
position, of which at most 4096 run per tick, so the same edits produce the same water on
every run. Any block change wakes the water next to it; seas and lakes are left alone until
something opens them. Changes made by the world travel as `block` records (not `heard`),
sorted by chunk, in the tick's `state` message. F3's server line shows the updates waiting.

`server/liquids_test.odin` contains the dam break test (the same water twice, both players
matching the server) and the flood test (10 000 blocks flowing within the tick budget; CI
also runs it optimized).

## Structures

A template (`common/game/structure.odin`) is a box of cells, each either a block or void
(which leaves whatever is present). Its `.vxs` file has a palette of block IDs
(`namespace:name`) and runs of cells.

Shipped templates are the base pack's `server/structures/*.vxs` (`assets/packs/voxiverse/`).
They are built in-game, compiled in, and read through the registry; generation reads no
files.

In an Earth world, each structure kind has a set of cells at its spacing. Each cell decides by
a hash whether it holds a structure, where, and at what rotation, so any chunk can work out
which pieces reach into it (`common/worldgen/structures.odin`). Surface structures require
flat land and receive cobblestone foundations; trees keep clear of them; the column tops
include them. Towers and dungeons (rooms and corridors, and a spiral stair in a shaft up to
the surface) are procedural pieces placed the same way.

`locate tower` (or `ruin`, `well`, `dungeon`) flies you to the nearest one, and
`build worldmap` marks them.

`worldgen_test.odin`'s `test_structures` checks that every kind is placed, identically each
time, built identically in any chunk order, and under exact tops. `server_test.odin` saves,
pastes and saves again (also via quarter turns) and checks for the same file.

## World generation

Generators live in `common/worldgen/`. A world records its own generator (`generator = earth` in
`world.cfg`; worlds from before M10 are `classic`). Generation is a pure function of the seed,
the settings and the position, so `build worldmap -seed:N` draws a world from above without
the game (biomes, water depth, hill shading; a 4096-block map in well under a second), and
`-bench:64` generates whole chunk columns and reports the time per chunk.

`common/worldgen/worldgen_test.odin` keeps hashes of two seeds' chunks. CI runs it on Windows,
Linux and macOS, so a platform that rounds differently fails in CI rather than in a player's
world.

The generator's stages appear in the profiler as `worldgen climate`, `worldgen place trees`
and `worldgen terrain`.

### Biome blending

Biome borders blend. Each column samples the climate up to `worldgen.biome_blend` blocks away
(in a different direction per column), so where two climates meet, the surfaces and trees mix
over a band twice that wide instead of meeting at a line. Tree density follows each tree's own
position, not its chunk's.

Worlds created earlier (with no `worldgen.biome_blend` in their `world.cfg`) load with 0, the
previous hard edges, so new chunks still meet their saved ones.

## Network

Client and server communicate only through messages, so the network is where to look when
they disagree.

| Tool | Description |
|---|---|
| F3 `player:` line | Walking or flying, inputs not yet acknowledged by the server, prediction corrections so far, and the visual offset still fading. Corrections should remain near 0: each one means client and server disagreed. |
| F3 `net:` line | Round trip (one ping per second; includes the server's tick wait), bytes per second in each direction, and the most frequent message kind. |
| `set debug.net_latency_ms 150`, `net_jitter_ms`, `net_bandwidth_kbps` | Simulates a slower connection, live. In your own world (the in-process pipe) the stream remains reliable and ordered, as the protocol requires. |
| `set debug.net_loss 10`, `net_duplicate 10` | In a remote game, drops or repeats that percentage of the packets you send (latency and jitter also apply, and jitter reorders), which the reliability layer (`common/netcode/`) must handle. The dedicated server's `Config.conditions` does the same on its side (tests). |
| F3 `server:` line, remote | The link: address, round trip, packets in each direction, reliable records resent, duplicates received. |
| `set debug.net_capture 1` (next remote game), `voxiverse-server --capture file.pcap` | Writes every UDP packet to a pcap file. Open it in Wireshark with `tools/wireshark/voxiverse.lua` (copy it to your Lua plugins folder, or run `wireshark -X lua_script:tools/wireshark/voxiverse.lua build/net.pcap`) to see handshakes, acks, records and the game messages in them. `lua tools/wireshark/check.lua file.pcap` decodes a capture without Wireshark. CI does both. |
| `set debug.net_trace 1` (next world) / `net_trace` (now) | Records every message in both directions to `build/net.trace`. |
| `build netdump [file]` | Prints a trace, decoded by the game's own decoders: `-kind:chunk`, `-sender:client`, `-from:2 -to:3`, `-limit:20`, or `-summary` for counts and bytes per kind (`state` and `snapshot` split by the state and event kinds they carry). Fails if any message does not decode. |
| `build replay [file]` | Feeds the trace's client messages to a fresh server with the same seed, view distance and timing (`-speed:4` for faster). Whatever the server did with them (assert, crash, disconnect) happens again outside the game; its answers go to `build/replay.trace`. Exits non-zero if the server failed or disconnected the client. |

Replays repeat the server's *inputs*, not its exact output. Chunk generation runs on worker
threads, so chunks can arrive in a slightly different order.

### The state model

What the server reports about the world besides chunks (the player, other players, entities,
the inventory, rules, health, the clock, chat, notices, blocks that changed) is the **state
model** (`common/game/state_kinds.odin`). It consists of *records* of typed kinds under a
key, and one-off *events*, encoded by a single codec derived from the value types
(`common/game/schema.odin`).

Records are deltas against one of two baselines:

- what the client was last sent (`state` messages, reliable);
- the newest snapshot the client acknowledged (`snapshot` messages, unreliable: the player's
  motion and other players' and entities' positions).

A new replicated value is a struct plus an entry in `state_kinds.odin`. Afterwards,
`./build.sh schema` regenerates the Wireshark dissector's table; the test
`test_dissector_schema_current` fails while it is stale. A client whose schema hash differs is
refused when joining.

### Bandwidth baselines

`server/bandwidth_test.odin` measures the exact bytes of a scripted session and of a crowd of
100 sheep. `assets/baselines/net/bandwidth.txt` holds the numbers, which are rewritten with
`-define:VX_BANDWIDTH_ACCEPT=true`:

```sh
ODIN_TEST_NAMES=server.test_bandwidth_accept ./build.sh test server
```

## Threads

The server, the worldgen workers and the mesh workers log, assert and allocate in the same
way as the main thread (they inherit its context), and each has its own track in profile
traces.

Odin's `-sanitize:thread` does not instrument memory accesses (as of dev-2026-10, only
function entry and exit), so it finds no races. Threaded code is instead covered by
deterministic tests (`base/queue_test.odin`, `server/server_test.odin`).

## Debuggers

`build debug` builds the game and starts gdb (Linux) or lldb (macOS, or `--lldb`) with the
Odin pretty-printers from `tools/debugger/`. The printers show strings as text, slices and
dynamic arrays as their elements, maps as key/value pairs, unions as the active variant only
(or `nil`), and Vulkan handles as hex. Arguments after `--` are passed to the game.

To use the printers elsewhere, run `source tools/debugger/odin_gdb.py` in gdb, or
`command script import tools/debugger/odin_lldb.py` in lldb (or in CodeLLDB's
`initCommands`).

- **Breakpoints.** Odin's debug information places a procedure's parameters correctly only
  after its first line, so `break some_proc` can show garbage arguments. Break on a line
  inside the body (`break main.odin:113`), or `next` once after stopping.
- **With `VX_BREAK=1`**, the stop is inside `base::debug_break`. `bt` shows the path, and
  `frame function client::draw` (gdb) jumps to your code.
- **Windows.** Debug builds write a `.pdb` next to the `.exe`. `build debug` starts the
  [RAD Debugger](https://github.com/EpicGamesExt/raddebugger) if `raddbg` is on the `PATH`;
  it understands Odin types. [RemedyBG](https://remedybg.itch.io/remedybg) and Visual Studio
  also work.
- **Odin upgrades.** After upgrading Odin, run `tools/debugger/test_printers.sh`: the map
  printer mirrors the runtime's internal layout.

## Graphics

The renderer is Vulkan 1.3 with dynamic rendering, bindless textures and one pipeline layout
(`client/gpu`, `client/render`). Every frame records one command buffer; up to two frames are
in flight (`FRAMES_IN_FLIGHT`).

### Passes

A frame is drawn in these passes, each bracketed by `gpu.begin_label` and `gpu.end_label`.
A label names the pass in validation messages and GPU captures, and times it on the GPU.

| Label | Pass |
|---|---|
| `frame` | The whole frame (a label and a timed section of its own). |
| `upload chunk meshes` | Copies of new chunk meshes from the staging buffer. |
| `world` | Opaque and cutout terrain. |
| `entities` | Avatars, sheep, items, projectiles. |
| `held` | The item in hand, in third person (`held_draw_world`) and first person (`held_draw_view`). |
| `sky` | The sky, after the world, at the far plane. |
| `water` | Translucent terrain, sorted. |
| `debug lines` | Developer overlays (chunk borders, boxes). |
| `ui` | The HUD and menus. |
| `present copy` | Benchmarks only: the offscreen image copied onto the window. |

### Timing

Each pass's GPU time is measured with timestamp queries (`client/gpu/timing.odin`) and read
back once its frame slot's fence has signalled. The results appear in three places:

- the F3 overlay (`GPU x ms`) and the exit log line `gpu frame times`;
- benchmark metrics: `gpu_frame` (without `gpu_present_copy`), `gpu_world`, `gpu_water`,
  `gpu_sky`, `gpu_entities`, `gpu_held`, `gpu_upload`, `gpu_ui`, `gpu_present_copy`;
- in a profiling build, the trace's GPU track, named `GPU (calibrated) <device>, <driver>`.
  With `VK_KHR_calibrated_timestamps` the GPU events sit on the CPU tracks' clock; otherwise
  the track is named `GPU (approximate) ...` and only durations are exact. Each pass carries
  its draw calls and triangles in its arguments.

A frame is GPU-bound when the CPU waits in `wait for frame fence` (the trace's main thread):
the GPU is still drawing the frame recorded `FRAMES_IN_FLIGHT` frames earlier.

### Draw calls and triangles

Every draw goes through `gpu.draw`, `gpu.draw_indexed` or `gpu.draw_indexed_indirect`
(`client/gpu/draw.odin`), which count it. An indirect call counts once as an API call and
once per command it holds as a draw. The counts appear on F3's `render:` line and as
benchmark metrics:

| Metric | Counts |
|---|---|
| `draw_calls` | Every draw of the frame, all passes: an indirect call's commands each. |
| `api_draw_calls` | The `vkCmdDraw*` calls that recorded them, all passes. |
| `world_api_draw_calls` | Of those, the world pass's: one per layer drawn (opaque, cutout, water), more only with `debug.occlusion_stats` (one per chunk queried) or past the device's `maxDrawIndirectCount`. |
| `frame_triangles` | Every triangle drawn in the frame, all passes (thousands). Line lists count none. |
| `world_triangles` | The world pass's triangles, opaque and water (thousands). |
| `world_meshes` | Chunk meshes drawn by the opaque world pass. A mesh is drawn as one command per run of visible face groups, so this is not a count of draws. |

A profiling build's GPU track gives each pass's draws and API calls in its arguments.

### How the world is drawn

The world pass (`client/render/world_pass.odin`, R5) draws each layer (opaque, cutout,
water) with one `vkCmdDrawIndexedIndirect`:

- **The chunk draw table** (`chunk draws`, a device-local buffer) holds one `Chunk_Draw`
  per mesh at its pool slot: the chunk (three `i32`) and its first vertex. A copy writes it
  when the mesh is added (`world_add_mesh`, in `upload chunk meshes`). `world.vert` reads
  it as a per-instance attribute (`in_chunk`, vertex binding 1); each command's
  `firstInstance` is the mesh's slot, so the hardware fetches that mesh's record. The
  chunk's offset from the camera's chunk is computed in integers from the scene's
  `camera_chunk`, so positions stay exact far from the origin.
- **Vertices** come through vertex input (binding 0) as before; the command's
  `vertexOffset` is the run's first vertex in the shared buffer, and the static quad index
  buffer supplies the rest. Pulling them by address (`gl_VertexIndex`) was measured and
  left out: on the development machine it cost `gpu_world`
  5-10% (history.md, R5).
- **`world_cull`** runs before rendering (the `world cull` profile scope). It walks a
  dense list of every mesh's chunk (`live`: 16 bytes a mesh, not the pool), tests each
  against the frustum, sorts what it keeps by distance (a radix sort of 64-bit keys:
  distance bits over the mesh's place), and writes one `VkDrawIndexedIndirectCommand` per
  run of visible face groups into this frame slot's host-visible `world draw commands`
  buffer (doubled when the mesh count needs it): opaque and cutout nearest first, water
  farthest first. Face groups are meshed in the order +x +y +z, crossed, -z -y -x
  (`client/mesh`), so the groups a camera sees are adjacent: two runs a mesh on average.
- **`world_draw` and `world_draw_translucent`** bind each pipeline once and draw the
  frame's spans. The push constants hold only what every world draw shares (the scene's
  address, the texture array, the sampler, the time). With `debug.occlusion_stats`, the
  opaque layer is drawn as one indirect call per queried chunk, each inside its query.

A chunk drawn at another chunk's place points at a table slot written for one mesh and
drawn for another (`live_at`, `world_remove_mesh`); a wrong position or texture in every
chunk points at the push constant or scene layout (`render_test.odin` asserts both against
the shaders' declarations).

Multi-draw indirect has a cost of its own on some drivers. The development machine's
driver generates an indirect call's draws on the GPU when it holds more than a few commands; `views`
measured the world pass 6-10% slower than R4's direct draws, and the same commands recorded
as direct draws as fast as R4's. R5b is that remainder.

### Memory

`Gpu.memory_bytes` is the device memory this process has allocated through
`create_buffer` and `create_image`. Where the driver supports `VK_EXT_memory_budget`,
`gpu.memory_report` also returns the process's use of the device-local heaps and the budget
the driver currently allows. F3's `memory:` line shows both, with the bytes of chunk meshes
uploaded this frame.

### Chunk light

Light is not stored: a chunk's light is a pure function of the blocks within 16 blocks of it
and the column heights there (`common/game/light.odin`). The client computes it for each
chunk before meshing (`client/world.odin`, R4) and keeps it, with the chunk, as its
`Light_Cache`: the light of the chunk and its 1-block border (18³ bytes, `sky << 4 | block`)
that its mesh was made with, and the key of what it was computed from: an XXH3-64 hash of
the 27 chunks' block versions (`Client_Chunk.blocks_version`, bumped by every change to a
chunk's blocks) and the 48 x 48 column heights around.

A mesh task (`Mesh_Task`, on the `mesh` workers) runs in two parts:

1. **Light** (scope `light chunk`, metric `light_chunk`): skipped when the key matches the
   cache (the cached light is the light: `light_reused`).
2. **Mesh** (scope `mesh chunk`, metric `mesh_chunk`): skipped when the chunk's blocks
   within a block of it did not change (`Client_Chunk.geometry`, set by a chunk arriving,
   a neighbour resent, an edit within a block, or a registry swap) and the new light is
   byte for byte the cache's. The chunk then keeps its mesh (`unchanged`).

So an edit lights again every chunk within `LIGHT_MAX` (15) blocks of it, and meshes again
only the chunks within a block of it and those whose light it changed. A registry swap
(`world_remesh_all`) drops every cache: its blocks may light differently.

The workers are `mesh_worker_count()` (`client/session.odin`): a quarter of the cores, at
least two (R4's measurement of half the cores is in history.md).

### Pipelines

Pipelines are created through a `VkPipelineCache` whose data is kept beside the game as
`pipeline-cache.bin` (`client/gpu/pipeline_cache.odin`). The file holds an XXH3-64 hash of
the driver's data, then the data. The data is used only when the hash matches and Vulkan's
header names this GPU's vendor, device and driver cache UUID; otherwise the cache starts
empty and the reason is logged. The cache is written at exit, to a temporary file renamed
over the previous one.

Each creation reports its time and whether the cache supplied it (Vulkan 1.3's pipeline
creation feedback): per pipeline at debug level (`gpu pipeline built`), in total at exit
(`gpu pipelines built=N from_cache=N ms=X`), and as `create pipeline` scopes in a trace.

### Validation

`VX_VALIDATION` controls the Khronos validation layer. Unset, the layer is on in development
builds and off in release builds. Otherwise it is a comma-separated list: `1` or `on` (the
layer, with synchronization validation), `best` (also best-practices advice, logged as
`vulkan advice` and not counted as a finding), `gpu` (also GPU-assisted shader checks), or
`0` or `off`. A run with `--frames N` fails on any validation finding; with `VX_BREAK=1` the
debugger stops at each one.

### GPU captures

[RenderDoc](https://renderdoc.org) (Windows, Linux) records every call, resource and pipeline
state of a frame.

1. Start the game from RenderDoc (Launch Application, or
   `renderdoccmd capture build/voxiverse`).
2. Press F12 in the game, or pass `--capture-frame N` to capture frame N (counted from 1;
   the trace's `frame #N` is the same frame).

Captures are written to `build/captures/voxiverse_frameN.rdc` and listed in the log at exit.
Every buffer, image, pipeline, sampler and per-frame object carries its name, and every pass
its label. Shaders are compiled with debug information (`glslang -g`: line numbers and the
source text), so a capture shows each shader's GLSL source. The richer NonSemantic debug
information (`-gV`, `-gVS`) is not used: it requires
`SPV_KHR_relaxed_extended_instruction`, which Vulkan 1.3 drivers are not required to support,
and `spirv-val` rejects it without that extension. The game communicates with RenderDoc
only when started from it; it never loads RenderDoc itself.

### Visual baselines

`./build.sh images` renders a fixed set of scenes and compares each picture with a baseline
kept in the repository, so a change to the renderer that changes the picture is found by a
test rather than by eye. It runs on Linux only, on lavapipe (Mesa's CPU Vulkan driver) under
`xvfb-run`: the same on every machine, and never a window on the desktop. The build driver
finds lavapipe's manifest in the system's ICD directories and points `VK_DRIVER_FILES` (and
the older `VK_ICD_FILENAMES`) at it, whatever GPU the machine has. CI's Linux game job runs
the same command for every change.

The scenes are listed in `assets/baselines/images/scenes.txt`, one a line, as
`name: script`; the script is console commands separated by `;`, as `--exec` takes them.
`voxiverse --scene <name>` runs one scene and quits: it joins the scratch world at its fixed
spawn and draws offscreen at 640 x 360 (`client/scenes.odin`). Whatever could change the
picture from one run to the next is fixed:

- the benchmarks' settings (`BENCHMARK_SETTINGS`), with no sound device;
- still clouds, no sheep, and still rules: the daylight cycle stopped at the benchmarks'
  time of day (a scene may set another with `/time set`), no random ticks, and no gravity,
  so a player teleported anywhere stays there;
- the water's animation stopped;
- no chat lines and no toasts: they fade with the clock, so they are cleared two frames
  before the picture.

After the scene's own script, the run waits a second for the server to answer, waits until
the world around the player is loaded and meshed, and draws ten more frames. The picture is
the offscreen image itself, not the window's scaled copy of it. It is written to
`build/images/<scene>.png`.

For each scene the comparison reports two numbers: the share of pixels whose largest colour
channel differs from the baseline's by more than 8/255, and the mean absolute difference of
the colour channels. A scene fails when the first is above 0.1% or the second above 0.5/255
(`IMAGE_MAX_SHARE`, `IMAGE_MAX_MEAN` in `tools/build/images.odin`; how they were settled is
in [history.md](history.md), R1). A failed scene also gets `build/images/<scene>.diff.png`:
the baseline in dim grey, the differing pixels in red. Each run's log is
`build/images/<scene>.log`. CI uploads `build/images/` as the `images` artifact when a step
fails.

```
./build.sh images                      # every scene, compared
./build.sh images cave                 # one scene, compared
./build.sh images --accept cave        # render it and make the picture its baseline
./build.sh images --accept all         # every baseline rewritten
```

A change that alters the picture on purpose re-accepts only the scenes it changes, after
looking at their pictures and differences; the commit says which scenes and why. A new
scene is a line in `scenes.txt` and `./build.sh images --accept <name>`.

## Benchmarking

`build bench <scenario>` measures one thing the same way every time, on any machine
(plan.md, M19).

| Scenario | Measures |
|---|---|
| `chunks` | Generating, lighting and meshing a fixed region on one thread, without the game (`tools/bench`). With `-check` (CI), it also fails if the chunk, mesh or vertex counts changed or a stage exceeded a generous budget. |
| `load` | Joining the scratch world until everything around is loaded and meshed: load time, the pools' work, server ticks. |
| `views` | Sixteen still views from the spawn: each GPU pass, triangles, the CPU's frame. |
| `avatars` | Eight players walking in view from the spawn, each holding one of the kit's weapons, drawn as other players are drawn: `avatar_draw` (building their vertices), the entity and held passes, the frame. |
| `flight` | 600 blocks of flight at 40 blocks/s: frames while streaming, generation and meshing, ticks. |
| `edits` | 12 explosions around the spawn: `edit_shown` (from a bulk edit's chunks arriving until all their new meshes are shown), meshing, frames, ticks. It waits for the water they release to settle. The explosions are queued on the in-process server (`server.call_async`), not waited for, so no frame holds a server tick of the driver's waiting (version 2, R2; version 1's frame times did). |
| `server` | The dedicated server alone (`voxiverse-server --benchmark server`): 8 simulated players join over UDP and fly out in 8 directions; ticks, streaming, generation, bytes sent. |

### Benchmark conditions

The game's scenarios run a release build with `--benchmark <scenario>` under fixed conditions:

- fixed settings (`BENCHMARK_SETTINGS` in `client/benchmark.odin`: no vsync; the player's
  settings file is neither read nor written);
- frames drawn offscreen at 1280 x 720 regardless of the window size (`gpu.set_offscreen`; the
  copy onto the window is `gpu_present_copy`, excluded from `gpu_frame`). `-size:WIDTHxHEIGHT`
  (`build bench views -size:2560x1440`) draws at another size; its results are kept as a
  scenario of their own (`views-2560x1440`), since numbers at different sizes never compare;
- the scratch world and its fixed spawn;
- the time of day stopped at late morning, still clouds, no sheep, no sound device.

Each scenario runs three repetitions, each a separate session after a warm-up. It writes
`build/benchmarks/<scenario>/<time>-<commit>.json` (every metric of every repetition, the
exact counts, the resolution, the machine) and a line in `build/benchmarks/history.jsonl`
(each metric's value).

A metric's value is its median, except for the server's load metrics (ticks, streaming,
collecting, bytes sent), where it is the mean: half the server's ticks may do nothing while
the workers catch up, and the heavy ticks are what matters. Results are comparable only on
one machine (identified by its fingerprint) and one scenario version. The metrics are
`base.Metric` (`base/metrics.odin`): recorded in any build, but only while a benchmark is
measuring. `--profile` adds a Spall trace of the run.

### Comparing two versions

`build bench compare <ref> <scenario> [-runs:N] [-size:WIDTHxHEIGHT]` determines whether a
change is faster. It
builds `<ref>` in a git worktree (`build/worktrees/`, kept), runs it and the working tree
alternately N times (default 5), and prints each metric for both with its change and a
Mann-Whitney p value. A change is called only at p < 0.05. With 5 runs each, the smallest
possible p is 0.008; with 3, it is never below 0.1, so use at least 4. Exact counts that
differ are shown first, because the two versions then did different work.

Judge a change with `compare`, never by two runs at different times: on the same machine,
medians move by several percent from run to run.

### How to benchmark a change

1. **Choose the scenarios the change can affect**: `chunks` for generation, light and
   meshing; `load` for streaming; `views` for drawing; `flight` for drawing while streaming;
   `edits` for re-meshing; `server` for the server under load from players. When unsure, run
   several.
2. **Keep the machine otherwise idle and its power steady**: plugged in, nothing else
   compiling or playing, and the same power profile for both sides. `compare` alternates the
   two versions, so slow drift (heat) affects both alike, but noise still widens the spread
   and hides small changes.
3. **Compare against the commit before the change** with
   `build bench compare main <scenario>` (or the commit hash), with the change in the working
   tree. Use the default 5 runs, or `-runs:8` to detect changes of a few percent. Fewer than 4
   runs can never call a change.
4. **Read the counts first.** "COUNTS DIFFER" means the two versions did different work (more
   chunks, fewer vertices). That is a change of work, which may be intended (greedy meshing)
   or a bug; the times then compare different things.
5. **Trust only called changes** (p < 0.05). A difference of a few percent without a call is
   noise; repeat with more runs if it matters.
6. **Record the result in the commit message**: the scenario, the metrics that changed, A and
   B, and p, e.g. "views: gpu_world 1.098 -> 1.181 ms (+7.6%, p 0.008)".
7. **Update pinned counts.** The exact counts in `bench chunks -check` (CI) are pinned. A
   change that alters chunks, meshed chunks or vertices on purpose updates them in
   `tools/bench` in the same commit.

### Smoke runs

`--smoke` (`build bench <scenario> --smoke`, and the game's and server's `--smoke`) runs a
scenario once, briefly, with a small view. CI runs this to keep every scenario working. The
results are written to `<scenario>-smoke` and are not compared with anything.

## Profiling

Measure optimized code. The default development build is lightly optimized (3-8x slower than
release in the chunk pipeline), and `--debug` is not optimized at all (7-15x slower).

The profiling tools, from narrowest to widest:

| Command | Shows |
|---|---|
| `build bench <scenario>` | A benchmark scenario under fixed conditions (see [Benchmarking](#benchmarking)). Run this first, before and after a change for speed. |
| `build perf [game\|server\|bench] [-- arguments]` | Samples a `--release --symbols` build under Linux perf (call stacks from the CPU's branch records where available) and prints the hottest functions per thread. Use `perf report -i build/game.perf` for call graphs, and `--sort srcline` for source lines. Threads carry their names (`server`, `worldgen 1`, `mesh 2`). |
| `build run --release --profile`, then `build trace` | A Spall trace of every instrumented scope and the GPU's passes. `trace` prints each scope's calls and percentiles per thread, a per-second timeline, and the slowest frames and server ticks broken down. |
| The `session mesher` log line | At the end of a session: chunks meshed (`meshed_now`: meshes made on the main thread because a block change could have shown a hole), re-meshed (and why: resent, `dirtied_edit` edits that changed their geometry or light, column tops), `relit_edit` (chunks an edit lit again), `unchanged` (lit again and not meshed: light and geometry as their mesh's), `light_reused` (lit from the cache), and task times (see [Chunk light](#chunk-light)). |
| `set debug.occlusion_stats 1` | Counts the chunks drawn that pass no pixel (hidden behind nearer ones: what occlusion culling would leave out), logged at exit as `render occlusion`. |

### Spall traces

`build run --release --profile` writes `build/voxiverse.spall`, a trace for
[Spall](https://gravitymoth.com/spall/); open it in the web viewer or the native application.
`build trace` summarizes it. A trace identifies itself:

- **The process** is named with the program, version and commit, build, and arguments
  (`Voxiverse 0.1.2+40 (135f897a933a) client, release build, profiling, arguments:
  --benchmark edits`).
- **CPU.** There is one track per thread (`main`, `server`, `mesh 1`..., `worldgen 1`...,
  `save 1`), with nested scopes. A `frame` and a `server tick` carry their number (`#2047`:
  for a frame, the frame count from 1, as `--capture-frame` counts; for a tick, the server's
  tick).
- **GPU.** A track named `GPU (calibrated) <device>, <driver>` holds the frame and every
  `begin_label`/`end_label` pass, on the CPU tracks' clock when the driver supports
  calibrated timestamps. Otherwise the track is named `GPU (approximate) ...`: durations are
  exact, but placement relative to CPU work is not.

### Frame scopes

The main thread's frame (`client/app.odin`, `app_frame`), outermost first:

| Scope | Contents |
|---|---|
| `frame #N` | One frame. It excludes the frame cap's sleep (`frame cap (sleep)`) and `benchmark driver`, which run between frames. |
| `input` | Window events, input and actions. |
| `shader watch and telemetry`, `audio and music` | Per-frame upkeep. |
| `session` | The game: `receive messages` (what the server sent: `apply block change` writes each block and records the change; `settle block changes` then dirties each chunk the frame's changes reach once, and meshes on the spot, as `mesh now (block changed)`, only the chunks where a change could show a see-through hole: a block that drew opaque or cutout faces is gone or replaced, at most 8 chunks a frame; flowing water never meshes here), `prediction tick` (each fixed tick), `aim (raycasts)`, `start meshing` (settles what predictions changed the same way, then hands chunks to the `mesh` workers, holes first: each task is `light chunk`, then `mesh chunk` when its light or geometry changed), `send messages`. |
| `after session (packs, checks, sounds, loading)` | What follows from the session. |
| `ui layout` | Building the HUD and menus (the GPU's `ui` pass draws them). |
| `wait for GPU` | `wait for frame fence` (the GPU is still drawing this slot's previous frame: GPU-bound), `acquire image`, `reset and begin commands`, `read GPU timings`, and rarely `recreate swapchain`. |
| `render` | The CPU side of drawing: `chunk meshes in` (`apply meshes`), `world and ui uploads`, `scene (avatars, entities, view model)`, `entity uploads`, `world cull` (the world's draw commands, R5), `record commands`, `queue submit`, `queue present` (vsync may wait here). |

### Server tick scopes

The server's tick (`server/server.odin`, `tick`): `server tick #N` holds `scheduled calls`,
`saving`, `collect chunks` (worldgen results), `receive messages`, `player` (each player),
`unload idle worlds and audit`; per world, `block updates`, `random ticks`, `entities`,
`containers`, `rewind, gates and rollback`, `changes flush`, `journal`; per player,
`replicate` and `stream` (`request chunk`, `send chunk`, `replica flush`); then
`kicks and packs` and `network flush`.

### Adding scopes

A scope name states what is done, in lower-case words (`apply block change`, not
`apply_block`). The same name means the same work wherever it appears.

Add a scope with `base.profile_scope("name")`, which times the rest of the enclosing block and
compiles to nothing in non-profiling builds, or with `base.profile_scope_number("name", n)`.
A thread that records scopes calls `base.profile_thread_start("name")` first; on a thread
that has not done so, a scope records nothing.

### Reading a trace

`build trace` prints:

- per thread and scope, the calls, total and percentiles;
- a per-second timeline;
- the slowest frames and server ticks, with the scopes directly inside them;
- the slowest three of each as a tree, down to every scope over 0.1 ms (calls merged:
  `apply block change x43`), with time not covered by any scope shown as `(untimed)`.

`python3 tools/debugger/check_spall.py build/voxiverse.spall` validates a trace: it is
well-formed and balanced, every GPU pass lies inside its frame, and passes are aligned when
calibrated.

The dedicated server (`build serve --release --profile`) writes its own trace alongside,
`build/voxiverse-server.spall`; summarize it with `build trace build/voxiverse-server.spall`.
Each run overwrites the previous trace.

### Overhead

**A trace shows where the time goes; take numbers from `build bench`.** A scope costs two
clock reads and a few bytes. On Linux the clock is read through libc (its vDSO, about 60 ns);
spall's own system call took about 900 ns and made scopes that fire thousands of times per
second appear several times slower than they are. With the libc clock, the `server`
benchmark's tick time under `--profile` was within its run-to-run variation of the build
without it (two runs each). Read proportions from a
trace; take numbers, and before/after comparisons, from `build bench` on a build without
`--profile`.

## Findings from the multiplayer hardening (M48j)

- **`odin test` is not the only build that sees a `_test.odin` file.** Odin compiles every
  `.odin` file of a package into every build of it; only `@(test)` procedures are dropped.
  `server/kit_test.odin`'s `@(init)` (the tests' block kit) therefore ran in the game and the
  server, and every new player started with eight stacks of blocks instead of the launcher and
  the mode's weapons. It is now inside `when ODIN_TEST`. Anything else at package level in a
  `_test.odin` file that has an effect (an `@(init)`, a global set at startup) requires the
  same treatment. `build bench party` found this defect: its bots held no weapon.
- **`stats_total("deaths")` counted every death twice.** `die` adds the `deaths` counter and
  the Death event adds `deaths.<cause>`, and `stats_total` sums a name and its dotted
  children. The P list's Deaths column (`tally_of`, `players_put`) now reads the exact keys.
- **Aim pitch must be clamped.** A message with a pitch beyond `PITCH_LIMIT` (`Fire`, and
  therefore any aim computed straight up or down) is refused as invalid and the sender is
  disconnected. Clamp an aim before sending it.
- **The multiplayer profile.** `build bench party` runs 8 players in survival with the pistol,
  rifle and sniper, shooting each other and respawning for 35 seconds, in three repetitions.
  The server's tick has a median of about 1.2 ms, a p99 of 2.0 to 2.1 ms, and a worst case of
  3.2 to 3.6 ms, against the 33.3 ms tick; there are no spikes. The client's frame with eight
  avatars is a manual check, because it requires a window.
- **The multiplayer tests.** `server/party_test.odin` (`test_party_six_clients`,
  `test_party_eight_clients`) runs a stepped server over real UDP, with bots from
  `net_test.odin`'s `Net_Client`, for 6 000 ticks; each takes a few seconds.

## Continuous integration

Every push builds on Windows, Linux and macOS. On Linux, CI also runs real frames on Mesa's
CPU Vulkan driver under the validation layer (normally, with AddressSanitizer, and with
profiling, checking the trace), and checks the gdb/lldb printers. Any validation finding,
leak, sanitizer report, malformed trace or printer regression fails the build.
