# Debugging and profiling

Debug builds (`build run`, `build build`) catch most problems by themselves and say where they
came from. This page covers what they do, the switches for going further, debuggers, GPU
captures and profiling. Everything here is exercised in CI or by `tools/debugger/test_printers.sh`.

## What debug builds do automatically

| Problem | What you get |
|---|---|
| Vulkan misuse | The Khronos validation layer (with synchronization validation) reports it with its spec ID, the names of the objects involved, and the stack of **our** code that made the call. |
| Memory leak / bad free | Listed at exit with the file and line that allocated it; the run fails. |
| Failed `assert`, `panic`, bounds check | Message plus stack trace, then the program stops (in your debugger, if attached). |
| Crash (segfault, access violation, illegal instruction, stack overflow on the main thread) | Signal or exception, faulting address and stack trace in the console and log, then the usual crash (core dump / Windows Error Reporting / your debugger). `crash` (debug builds) tests it. Off in sanitizer builds, which report crashes themselves. |
| Frame times | Logged at exit: wall-clock and GPU time per frame (avg, p50, p99, max). |
| Everything logged | Console (Info and up) and `build/voxiverse.log` (everything, overwritten each run). |

Validation needs the layer installed (see README); without it you get one warning at startup.

## Reading the log

```
console:    3.214 INFO  server     server player joined name="player"
            3.215 WARN  main       gpu renderdoc is loaded but did not provide API 1.6 (client/gpu/renderdoc.odin:60)
file:       3.214512 | INFO | server | server player joined name="player" | server/server.odin:224
```

Seconds since start, level, the thread that logged (`main`, `server`, `worldgen 2`, `mesh 1`),
then the message: what happened, then `key=value` pairs to filter on
(`grep 'pos=\[1,6,4\]' build/voxiverse.log`). The console adds the source location to
warnings and errors; the file has it on every line. New code: start messages with the
subsystem (`gpu`, `server`, `session`, ...) and put values in `key=value` form.

## Switches

| Switch | Effect |
|---|---|
| `VX_LOG=debug` | Show debug-level messages on the console too |
| `VX_VALIDATION=0` / `1` | Validation off (development builds) / on (also in release builds) |
| `VX_VALIDATION=best` | Plus best-practices advice (logged as "vulkan advice", does not fail runs) |
| `VX_VALIDATION=gpu` | Plus GPU-assisted validation: checks inside shaders (slow) |
| `VX_BREAK=1` | Stop in the attached debugger on validation errors and wherever `base.debug_break()` is called |
| `build run --sanitize` | AddressSanitizer build: use-after-free, buffer overflows, with the line that did it (Linux/macOS) |
| `build run --profile` | Write a profile trace (see Profiling); combine with `--release` |
| `build debug [--lldb]` | Debug build started in gdb (or lldb) with the Odin printers loaded |
| `run -- --frames N` | Run N frames and exit; fails on any validation finding or leak (what CI does) |
| `run -- --capture-frame N` | Under RenderDoc: capture frame N (see GPU captures) |
| `run -- --exec "cmd; cmd"` | Run a script of console commands, e.g. `--exec "screen options"` to reproduce a state. Scripts can pause: `wait <frames>`, `wait_world` (until the world has loaded and meshed): `--exec "singleplayer; wait_world; screenshot world; wait 3; quit"` |
| <kbd>F2</kbd> / `screenshot [name]` | Save the next frame as `build/screenshots/<name>.png` (CI uploads the folder: the world runs take one at the start and end of each flight) |
| <kbd>F3</kbd> / `debug` | Overlay: FPS, frame and GPU time per frame and the present mode (FIFO with vsync; IMMEDIATE without, or MAILBOX where the window system offers nothing else), position, client/server chunk counts, chunk memory, session arenas, meshing queue, draws, server tick time |

Options combine, e.g. `VX_VALIDATION=best,gpu`, `build run --release --profile`.

## Reading a validation message

```
vulkan [VUID-vkCmdDraw-renderpass]: vkCmdDraw(): This call must be issued inside an active render pass.
  at client::draw (client/main.odin:118)
  at client::run_with_gpu (client/main.odin:107)
```

- The bracketed ID is searchable in the [Vulkan spec](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html).
- Objects appear with their names, e.g. `VkImage 0xe000000000e[swapchain image 0]`. Name new
  objects with `gpu.set_name`; bracket recorded work with `gpu.begin_label`/`end_label` (which
  also times it on the GPU).
- Some checks run on the layer's own thread after the call returned; those say so instead of
  showing a stack. Use the object names and labels, or `VX_BREAK=1`.

## Variables

Settings (saved), debug switches (`debug.*`, never saved) and later game rules are plain
struct fields described by variable tables; see plan.md, "Console and variables".

| | |
|---|---|
| `vars [filter]` | List variables, values and help |
| `set <name> <value>` / `reset <name>` | Change one / back to its default (out-of-range values are clamped, with a warning) |
| <kbd>F4</kbd> / `tune` | Tuning panel: every variable as a slider or checkbox, live |

Settings are saved to `settings.cfg` in the user config directory (`~/.config/voxiverse/` on
Linux), or to the path in `VX_SETTINGS` (empty: none). Changes made by `--exec` scripts are
never saved, so test runs cannot change your settings. New variable: add the field to its
struct, its default, and one line to the table; a test checks every table.

## Shader hot reload

In development builds, saving a file in `assets/shaders` recompiles it (through
`build/build-driver shaders`) and swaps the affected pipelines within about a second. A
shader that fails to compile logs glslang's message with file and line, and the old one
keeps running. `set debug.hot_reload_shaders 0` turns it off. `scene.glsl` is included by
the world, sky and entity shaders (the per-frame scene, sky colours, clouds); saving it
reloads all three (client/passes.odin lists the passes and what they include).
`time <name|0..1>` with `set rules.daylight_cycle 0` holds the sky still while you work.

## Saves

A save is a universe, a directory: `universe.cfg` (format, seed, the home world's address, the
starter kit), `characters/<account>/<name>.json` (each character: their world, where they are
and look, flying, their inventory by item name; written when it changed), `permissions.cfg`,
`community.cfg`, and `worlds/<address>/` for each world visited or edited: its `world.cfg`
(generator, seed, time, spawn, rules, generator parameters), `entities.cfg` and `regions/`
with the edited chunks only (a chest's contents are its block entity, saved with its chunk) (`r.<x>.<z>.vxr`, 16x16 chunk columns each; the rest regenerates
from the seed). A directory from before universes (a `world.cfg` at the top) becomes one when
opened: its world is the home world. Files are replaced through a temporary file, so a crash
mid-save keeps the previous save; a region file that fails its checksum is moved aside
(`.damaged-<time>`) with an error, never loaded. `server/save_test.odin` covers save, quit and
load, edits surviving unloading, and damaged files.

## Worlds

A universe has worlds, named by addresses (plan.md, M17): a galaxy of eight Old Turkic symbols
and a world of seven, shared as `𐰀𐰁𐰄𐰅𐰇𐰉𐰊 𐰋𐰌𐰍𐰎𐰏𐰐𐰒𐰔` (world, then galaxy; seven alone
mean this galaxy) or as a directory name, `0001020304050607-08090a0b0c0d0e` (two hex digits a
symbol, galaxy first: that form types on any keyboard). The address alone sets the world's
kind (generator parameters, palette, gravity, day length); the universe seed its terrain. The
home world is Earth as before. A world loads when someone travels there and unloads (saved,
its memory freed) after `WORLD_IDLE_SECONDS` empty; the home world stays.

| Server command | |
|---|---|
| `travel <address> [character]` | Go there (its spawn), carrying the character (`world.travel`; another's: `world.travel.others`); players use gates |
| `address` | This world's address, both ways of writing it (`info.address`) |
| `worlds` | The loaded worlds and who is in each; how many are saved (`info.worlds`) |

Gates (M18) travel between the worlds of a galaxy: rare structures, none within
`worldgen.gate_distance` (2000) blocks of a world's middle; `locate gate` stands an admin in
front of the nearest. Right-click its ring (or the console's `dial [address]`; `look <yaw>
<pitch>` turns for scripted screenshots), pick seven symbols; the chevrons lock, both ends open
for 30 s, and walking into the horizon arrives at the dialed world's gate nearest its middle.
Refusals come back as notices; the server logs `gate dialed`.

Homes, warps, back and tp remember their world and travel when needed. The client's chat and
console draw the symbols from a fallback font (`assets/fonts/noto_sans_old_turkic_regular.ttf`).

## Sound

Every sound effect is synthesized at startup (`client/sfx`: no recordings) and mixed by our
own mixer (`audio/`); miniaudio only opens the sound card (every Ogg, the music and a pack's
sounds, is decoded by our own Odin code, `common/ogg`: see *The Ogg decoder* below). `build sfx` writes them all to
`build/sounds/*.wav` to listen to outside the game. F3 shows the device, voices playing,
sounds played and dropped; the log's last `audio` line sums up the run. Without a sound card
(CI, a headless box) the game logs a warning and runs silent. `set volume 0..1` is the
player's volume. On Linux and macOS the build compiles Odin's miniaudio library once (into the
Odin install; Windows ships it), which needs a C compiler.

### The Ogg decoder

`common/ogg` is a Vorbis I decoder and an Ogg reader (M53c) that refuses malformed input with
an `Error` and never allocates past `open`'s one block. Its maintenance commands:

| Command | What it does |
|---|---|
| `build ogg digests` | Rewrites `common/ogg/testdata/digests.txt` (FNV-1a of every decoded `f32` of the music, the small test files and the edge-case files) and prints the lines that changed. A digest moves only with a decoder edit that is meant |
| `build ogg reference` | Rewrites `common/ogg/testdata/reference/` from the reference decoder (libvorbis through `ffmpeg` on the PATH; used only here, the output is committed): half a second at the start, middle and end of each music file, and each edge-case file whole. `reference.odin` says which edge-case files have none, and why |
| `build ogg make-test-files` | Rewrites `common/ogg/testdata/edge/` (`tools/ogg/make.odin`): valid Vorbis streams of seeded random packets over a fixed codebook set, one file per feature (every block size, tiny and cut streams, mono, coupled stereo, six channels, floor 0, residue 0 and 2, pages, chained links). Run it only to change them; the digests and references follow |
| `build ogg fuzz [--seed N] [--iterations N]` | The same fuzz as `test_ogg_fuzz`, for longer. The input is written to `build/fuzz/current.bin` before each run, so a crash leaves it there; copy it to `common/ogg/testdata/regress/` and the suite replays it first |
| `build bench ogg` | The music decoded by `common/ogg` and by miniaudio, best of three: seconds of audio per CPU second for both and their ratio |

## Keeping the screen awake

While playing (in a world, not paused, not in the game menu) the screen stays on, released
otherwise and on exit (`platform.set_keep_awake`, logged as `platform keep awake`):
Windows `SetThreadExecutionState`; Linux the freedesktop screensaver's `Inhibit` over D-Bus
(libdbus loaded at run time), else the desktop portal's (Wayland desktops), plus
`XResetScreenSaver` every 30 s for X's own blanking; macOS an IOKit power assertion (with
M1b's window). Where none answers it says so in the log and does nothing.

## Debug drawing

`render.debug_line` / `render.debug_box` draw world-space lines for one frame from anywhere on
the main thread (hidden behind terrain, never hiding it); see `world_debug_lines` in
`client/camera.odin`. `set debug.chunk_borders 1` outlines the camera's chunk and its
neighbours' edges.

## Commands

Three surfaces, each with one job: **server commands** act on the world and the players
(they start with a slash, in the chat and in the console alike); the **developer console**'s plain
words are the client's own (nothing about the world); checks and benchmarks are command-line modes.

**Server commands** (`/command` in the chat, `/command` in the console): every change to the
world is the server's, and permissions decide who may run what (see Permissions). Wherever a
command takes a player, `@s` is you, `@p` the nearest other player, `@r` anyone and `@a`
everyone (where that makes sense: `/give @a`, `/tp @a @s`); coordinates may be relative
(`~`, `~5`, `~-2`: the first of a run is x, then y, then z). `/help` lists what you may use,
`/help <command>` its usage and permission. The ones that matter when debugging a world:

| Command | |
|---|---|
| `/time set <t>`, `/time add <hours>`, `/time query` (and `/time <t>`) | The time of day: `sunrise day noon sunset night midnight` or `0..1` (`world.time`). `/rule daylight_cycle false` stops the clock, `day_length` is seconds per day |
| `/rule [name] [value]` (`/gamerule`) | List the world's rules, show one, set one (`world.rules`): `random_tick_speed`, `drops`, `reach`, ... |
| `/tp <x y z> [yaw pitch]`, `/tp <player>`, `/tp <who> <player>`, `/spawn`, `/setworldspawn [x y z]` | Move (angles in degrees; `/tp ~ ~10 ~` goes up ten); back to the world spawn; new players arrive there. A new world's spawn is the generator's search (dry open land, no tree or structure near), chosen once and kept in `world.cfg` |
| `/setblock <x y z> <block>` | One block, through the bulk edit pipeline (`world.edit.bulk`) |
| `/summon [kind] [count]`, `/kill <kind\|all> [radius]` | Sheep in front of you (`world.summon`; they also come by themselves in daylight on grass 16-40 blocks from a player, at most 6 near one, and go when nobody is within 80); remove the entities of a kind within a radius (`world.kill`) |
| `/locate [biome\|structure] <name>` | Fly to the nearest biome or structure (`teleport.locate`): `village`, `dungeon`, `gate`, ... |
| `/give <player\|@a> <item> [count]`, `/clear [player] [item]`, `/wear`, `/seed` | Items (`items.give`; what does not fit is dropped at their feet); put on all the armor carried; the world's seed |
| `/regen [radius]` | Remake the unedited chunks within a radius (1-8 chunks) from the generator as it is now (`world.gen`) |
| `/pos1 [x y z]`, `/pos2 [x y z]`, `/sel` | The selection's corners (the block you look at, within 128, or coordinates), kept by the server and drawn as a box / forget it |
| `/fill [box] <block>`, `/replace [box] <from> <to>`, `/sphere [x y z] <radius> <block>` | Bulk edits (`world.edit.bulk`; at most 64x64x64 blocks) of the selection, or of a box `x1 y1 z1 x2 y2 z2` given. The server applies them in one pass and sends each touched chunk whole, after a `Bulk_Begin` saying how many follow |
| `/structure save <name> [box] [clear]`, `/structure paste <name> [x y z] [turns]`, `/structure list` | Keep the selection (or a box) as `<world>/structures/<name>.vxs` / put one at pos1 (or x y z) through the bulk edit pipeline, turned 0-3 quarters (`world.structure`) |
| `/stats [player] [filter]` | Counters (see Statistics and events) |

Minecraft's names work where we have the thing: `/tell`, `/w`, `/say`, `/gamerule`, `/teleport`.

**The developer console** (`~`; the chat's `/` commands work in it too): `singleplayer` (a
scratch world, never saved) and `universe <name>` (a saved one; saves go to `VX_SAVES` if set),
`join`, `leave`, `quit`, `screen`; `set`, `vars`, `reset` (settings, `debug.*`, `rules.*` and
`worldgen.*`: the last two are the server's, which announces changes); `screenshot`,
`net_trace`, `crash`; `look <yaw> <pitch>` to place the camera for a picture; `clear`, `help`.
A plain word that is a server command says to use the slash. Nothing in it duplicates a key,
the UI or a server command.

**Scripts** (`--exec "cmd; cmd"`) are console input typed at startup, with `wait <frames>`,
`sleep <seconds>` and `wait_world`: for reproducing a state and taking its picture. Checks
and measurements are code:

| Check (`--check <name>`) | |
|---|---|
| `fly` | The memory check: flies 400 blocks at 40 blocks/s (view 6 x 3); fails if either session arena grew or chunk storage passed its fixed size. Logs frame times and resident memory |
| `tour` | The M10 check: visits every biome (view 4 x 3), screenshots each (`biome_<name>`), then fails on a biome not found, a frame p99 over 100 ms, chunk generation or meshing p99 on the workers over budget (5 and 10 ms in an optimized build, ten times that otherwise), or memory growth after the first biome |
| `blast` | The M9 check: hovers above the spawn (view 4 x 2) and sets off 12 rockets and explosions in turn, then fails on a frame p99 or server tick over 100 ms, a blast not shown whole (its meshes in one frame), arena growth, or chunks that differ from the server's (both sides hash them) |

A check runs with the benchmarks' fixed settings (its own view), after any `--exec` script
(which may set things up: `--exec "set debug.net_trace 1" --check fly`), and quits, failing
the run if it failed.

F3's `chunks:` line shows how long chunks take to generate (on our own server's workers)
and to light and mesh (ours), on average and the slowest 1%.

## Permissions

What a player may do is a set of nodes: `world.edit` (build), `world.edit.bulk`, `world.fire`,
`world.summon`, `world.structure`, `world.time`, `world.rules`, `world.gen`,
`debug.coordinates` (F3 shows position, chunk and block under when `rules.show_coordinates` is off), `teleport.tp`, `teleport.locate`, `server.save`, `server.export`, `server.open_lan`, `permissions.edit`,
and the `chat.*`, `moderation.*`, `teleport.*` and `info.*` nodes the commands
use. A grant is a node, `x.*` (x and everything under it), `*` (everything), or `-x` (not x).
The most specific grant wins; at the same specificity the player's own grant beats their
role's, which beats an inherited one; a tie is a denial.

Roles grant nodes, inherit other roles and carry metadata (`prefix`, a chat tag such as
`&c&lAdmin`). Everyone has the role `default`; a new world has `default` (build, chat,
travel), `mod` (inherits default; all of chat and moderation, `teleport.tp`) and `admin`
(inherits mod; `*`). The local player of a world played here, and every player of a server
started with `--cheats`, has `*`.

| Server command | |
|---|---|
| `role list`, `role info <role>` | The roles / one role's inherits, grants and metadata |
| `role grant\|revoke <role> <node>` | Grant or take back (`-x` denies); the first grant makes the role |
| `role inherit\|uninherit <role> <role>`, `role meta <role> <key> [value]`, `role delete <role>` | |
| `user info <player>`, `user role add\|remove <player> <role>` | A player's roles and grants |
| `user grant\|revoke <player> <node>`, `user meta <player> <key> [value]` | Their own grants (nearest) and metadata |

(From the console: `server role grant mod world.fire`.) They need `permissions.edit`; each
change is sent to the players it affects and saved in `<world>/permissions.cfg`. A dedicated
server has no owner: stop it and edit that file (`player alice` then `role admin` on the next
line) to make the first admin. A client asks only for what its grants allow (the console
says "not allowed on this server"); the server checks again and answers a refusal with a
notice, not a disconnect.

## Accounts and characters

The game makes an account on first launch: an Ed25519 key, `account.key` beside the settings
(whoever has that file is the account; back it up). Joining, the client sends the account
and a character name (`Hello`), the server a random nonce (`Challenge`), the client its
signature over it (`Proof`): a wrong one is refused, and a proof is good for one nonce
only. A character name belongs to the first account that plays it in that universe
(`that name is another account's`); an account has at most 8 there. From the Multiplayer
screen the client asks for its characters (`Characters`) and chooses one, or makes one;
singleplayer, `join` and scripts play the settings' `name`. Each character is kept in
`characters/<account>/<name>.json`; a `players/<name>.json` from before accounts goes to
the first account that plays that name. `ban` bans the character's account too
(`ban_account` in community.cfg); `account <hex>` in permissions.cfg grants to every
character of an account; `whois` shows a character's account (`moderation.address`).

## Items

Items are data (`common/game/items.odin`): every block players may place has its item (its name is
the block's), tools are items of their own (`rocket_launcher`). An inventory is 30 slots (the
first five the hotbar, then a 5x5 grid) and the stack on the cursor; the server owns it and applies requests
with the same code the client predicts with (`common/game/inventory.odin`), answering each with the
inventory (the `inventory` record: its `acked` says how far it got): a refused request is rolled back. Placing a
block uses one from the hand (or the hotbar) unless the player has `items.infinite`; breaking
leaves the block's item where `rules.drops` (not for `items.infinite`); `items.catalog` lets
the inventory take any item. Dropped stacks are entities: they fall, merge with stacks of
their item, are picked up by walking over them (half a second; two for the one who dropped
it) and go after five minutes. A player new to a world gets `world.cfg`'s `kit`.

A chest (`server/containers.odin`) is a block with a container block entity of 25 stacks, kept
with its chunk (`server/block_entities.odin`) and made when the block is placed. Right-clicking
it sends `Use_Block`; the server then puts the entity's slots in that player's `Inventory` (`chest`,
`chest_open`), so the ordinary requests may name slots `CHEST_BASE ..< ALL_SLOTS`, the client
predicts them, and the record is copied in before each request and out after it, and told to
everyone else looking. It closes (the `Close` request, or by itself) when the player goes more
than the reach plus two blocks away or the block is gone; the entity goes with its block
(broken, blown up, edited in bulk: one point, `entity_lifecycle`) and what it held spills out. `server/containers_test.odin` covers it.

| Command | |
|---|---|
| `inventory`, `drop [all]` | Open the inventory / drop from the hand (as E, Q do; scripts) |
| `use` | The right button once on what is aimed at (scripts): a chest opens and shows its overlay, a sheep is sheared |
| `/give <player> <item> [count]` | `items.give`; what does not fit is dropped at their feet |
| `server clear [player] [item]` | Empty an inventory, or of one item (`items.clear`; others' `items.clear.others`) |
| `server item` | What you hold, its id and stack size |

## Statistics and events

Everything the server counts or measures is an *event* (`telemetry/`: one kind per row of
`KIND_INFO`, which says what its fields mean). `record` (server/stats.odin) emits the event
and adds to the counters the kind names, the player's and the world's.

- **Counters** are dotted names (`blocks.mined.stone`, `distance.walked` in cm, `time.played`
  in seconds, `commands.time` ...); a parent is the sum of what is below it. They live in the
  character's file (`"stats"`) and in `<world>/stats.json`. In game: the `stats [player] [filter]`
  command (30 lines in chat; another player's needs `info.stats.others`), and the statistics
  screen (key `K`, or `screen stats`).
- **The log** is `<universe dir>/telemetry/YYYY-MM-DD.jsonl`, one JSON object per line (time in
  ms, tick, session, actor = the player's id, kind, world, position, the kind's fields), written
  by a thread of its own; a full buffer drops events and says so in an `events_dropped` line; a
  day stops at 64 MiB. A scratch world (no save directory) writes nothing.
- **Client reports** (`Client_Info`, `Client_Overlay`, `Client_Perf`) arrive in a `Telemetry_Report`
  message, at most six a minute, validated; refusals count in the world's `telemetry.refused`.
- Looking at a log: `jq -c 'select(.k=="block_mined")' common/telemetry/*.jsonl`, or DuckDB:
  `select k, count(*) from read_json_auto('common/telemetry/*.jsonl') group by 1 order by 2 desc`.

## Chat

`t` opens the chat, `/` opens it with a command started (`/spawn`; the server runs it, as the
console's `server spawn` does); `say <words>` and `chat [text]` do the same from the console
and scripts. The server numbers each line, adds the speaker's tag (their role's `prefix`
metadata, and `suffix`) and nickname, keeps codes only where the speaker has
`chat.format.color`, `chat.format.rgb`, `chat.format.style` (else they show as written),
drops control characters, allows 5 lines at once then one a second, and logs every line
(`server chat`). Each part (tag, name, words) is formatted on its own: no explicit `&r`.
Formatting codes: `&0`-`&f` colours, `&#rrggbb`, `&l` bold, `&o` italic, `&n` underline, `&m`
strike, `&r` plain, `&&` an `&`; a colour clears the styles before it.

| Server command | |
|---|---|
| `ignore <player>` | Stop (or start again) hearing them (`chat.ignore`) |
| `mute <player> [30m\|2h\|7d]`, `unmute <player>` | For a while or for good (`moderation.mute`) |
| `delmsg <player> [count]` | Take back their newest lines from everyone's chat (`chat.delete`) |

Server commands for people and places (after EssentialsX's; `/name` in chat, `server name` in
the console; each needs the permission in brackets):

| Command | |
|---|---|
| `home [name]`, `sethome [name]`, `delhome <name>`, `homes` | Your homes (`teleport.home`; at most your role's `max_homes` metadata, 3 for `default`) |
| `warp [name]`, `warps` / `setwarp <name>`, `delwarp <name>` | The world's warps (`teleport.warp` / `teleport.warp.set`) |
| `tpa <player>`, `tpahere <player>`, `tpaccept`, `tpdeny` | Ask to go to someone, or for them to come (`teleport.tpa`; two minutes to answer) |
| `back`, `top`, `spawn` | Where you were before your last teleport / up onto the highest block / the world spawn |
| `tp <player>`, `tp <x y z>`, `tp <player> <player>`, `tphere <player>` | `teleport.tp`; moving others `teleport.tp.others` |
| `msg <player> <words>`, `r <words>`, `me <action>`, `broadcast <words>` | Whisper, answer the last whisper, an action, to everyone (`chat.msg`, `chat.me`, `chat.broadcast`) |
| `nick <nickname\|off> [player]`, `realname <nickname>` | A nickname: a name's letters, formatted as you may format chat, nobody else's name (`chat.nick`, others' `chat.nick.others`) |
| `motd [set <words>]` | The message of the day, shown on joining (setting it: `server.motd`) |
| `kick <player> [reason]` | `moderation.kick` |
| `ban <player> [reason]`, `tempban <player> <30m\|2h\|7d> [reason]`, `unban <player>` | `moderation.ban` |
| `ban-ip <player\|address> [reason]`, `unban-ip <address>` | Everyone from that address (`moderation.ban_ip`) |
| `list`, `whois <player>`, `seen <player>`, `afk`, `status` | Who is here; who someone is (their address with `moderation.address`); when they were last here; away (moving or speaking ends it); ticks, chunks, memory |

Nobody may kick, ban or mute a player with `moderation.exempt` (admins, the host); the host
cannot be kicked at all. Nicknames, mutes, ignores, homes, warps, bans, last seen and last
address, and the message of the day are kept in `<world>/community.cfg`.

Every in-game panel is an overlay on one stack (`client/overlay.odin`): the game menu,
Options, tuning, chat, console, the quit dialog. Each says whether it takes the keyboard,
frees the mouse or pauses the world; the top one gets the keys, the focus and Escape.

## Liquids

Water levels are block ids (a source, flow levels 1-7, falling), so saves and the protocol
need nothing new. The server runs scheduled block updates (`server/liquids.odin`): a queue
ordered by tick and position, at most 4096 run a tick, so the same edits give the same water
on every run. Any block change wakes the water next to it; seas and lakes are left alone
until something opens them. Changes the world makes travel as `block` records (not `heard`),
sorted by chunk, in the tick's `state` message. F3's server line shows the updates waiting. `server/liquids_test.odin`: the dam
break (the same water twice, both players matching the server) and the flood (10 000 blocks
flowing within the tick budget; CI runs it optimized too).

## Structures

A template (`common/game/structure.odin`) is a box of cells, each a block or void (leave what is
there); its .vxs file has a palette of block ids (`namespace:name`) and runs of cells. Shipped
templates are the base pack's `server/structures/*.vxs` (`assets/packs/voxiverse/`), built
in-game, compiled in and read through the registry (generation reads no files). In an Earth world each structure kind has a set: cells of its spacing each decide by
a hash whether they hold one, where and turned how, so any chunk can work out the pieces
reaching into it (`common/worldgen/structures.odin`); surface ones need flat land and get
cobblestone foundations; trees keep clear; the column tops include them. Towers and dungeons
(rooms and corridors, and a spiral stair in a shaft up to the land) are procedural pieces
through the same placement. `locate tower`
(ruin, well, dungeon) flies you to the nearest; `build worldmap` marks them.
`worldgen_test.odin`'s `test_structures` checks every kind is placed, the same each time,
built the same in any chunk order, under exact tops; `server_test.odin` saves, pastes and
saves again (also via quarter turns) for the same file.

## World generation

Generators live in `worldgen/`; a world records its own (`generator = earth` in
world.cfg; worlds from before M10 are `classic`). Everything is a pure function of the seed,
the settings and the position, so `build worldmap -seed:N` draws a world from above without
the game (biomes, water depth, hill shading; a 4096-block map in well under a second), and
`-bench:64` generates whole chunk columns and reports the time per chunk.
`common/worldgen/worldgen_test.odin` keeps hashes of two seeds' chunks: CI runs it on Windows,
Linux and macOS, so a platform that rounds differently fails there, not in a player's world.
The generator's stages show in the profiler as `worldgen climate`, `worldgen place trees`,
`worldgen terrain`.

`--check fly` is the M3 exit check; CI runs it on the CPU driver, with AddressSanitizer and
with profiling. CI also runs `--check blast`. F3
shows how many bulk edits were shown whole and how many late (on a timeout).


Biome borders blend: each column samples the climate up to `worldgen.biome_blend` blocks away
(a different way per column), so where two climates meet the surfaces and trees mix over a
band twice that wide instead of meeting at a line; tree density follows each tree's own spot,
not its chunk's. Worlds made before (no `worldgen.biome_blend` in their world.cfg) load with 0,
the old hard edges, so new chunks still meet their saved ones.

## Network

Client and server only talk through messages, so the network is where to look when they
disagree.

| | |
|---|---|
| F3 `player:` line | Walking or flying, inputs not yet acknowledged by the server, prediction corrections so far and the visual offset still fading. Corrections should stay near 0: each means client and server disagreed |
| F3 `net:` line | Round trip (a ping a second; includes the server's tick wait), bytes per second each way, the most frequent message kind |
| `set debug.net_latency_ms 150`, `net_jitter_ms`, `net_bandwidth_kbps` | Simulate a slower connection, live. In your own world (the in-process pipe) the stream stays reliable and in order, as the protocol requires |
| `set debug.net_loss 10`, `net_duplicate 10` | In a remote game, drop or repeat that percentage of the packets you send (latency and jitter apply too, and jitter reorders): the reliability layer (`netcode/`) has to cope. The dedicated server's `Config.conditions` does the same on its side (tests) |
| F3 `server:` line, remote | The link: address, round trip, packets each way, reliable records resent, duplicates received |
| `set debug.net_capture 1` (next remote game), `voxiverse-server --capture file.pcap` | Write every UDP packet to a pcap file. Open it in Wireshark with `tools/wireshark/voxiverse.lua` (copy it to your Lua plugins folder, or `wireshark -X lua_script:tools/wireshark/voxiverse.lua build/net.pcap`): handshakes, acks, records and the game messages in them. `lua tools/wireshark/check.lua file.pcap` decodes a capture without Wireshark (CI does both) |
| `set debug.net_trace 1` (next world) / `net_trace` (now) | Record every message both ways to `build/net.trace` |
| `build netdump [file]` | Print a trace, decoded by the game's own decoders: `-kind:chunk`, `-sender:client`, `-from:2 -to:3`, `-limit:20`, or `-summary` for counts and bytes per kind (`state` and `snapshot` split by the state and event kinds they carry). Fails if any message does not decode. |
| `build replay [file]` | Feed the trace's client messages to a fresh server with the same seed, view distance and timing (`-speed:4` for faster). Whatever the server did with them (assert, crash, disconnect) happens again outside the game; its answers go to `build/replay.trace`. Exits non-zero if the server failed or disconnected the client. |

What the server says about the world besides chunks (the player, other players, entities,
the inventory, rules, health, the clock, chat, notices, blocks that changed) is the **state
model** (`common/game/state_kinds.odin`): *records* of typed kinds under a key, and one-off
*events*, encoded by one codec derived from the value types (`common/game/schema.odin`). Records
are deltas against what the client was last sent (`state` messages, reliable) or against the
newest snapshot it acknowledged (`snapshot` messages, unreliable: the player's motion and
other players' and entities' places). A new replicated value is a struct and an entry in
`state_kinds.odin`; then `./build.sh schema` regenerates the Wireshark dissector's table
(the test `test_dissector_schema_current` fails while it is stale). A client whose schema
hash differs is refused when joining. `server/bandwidth_test.odin` measures the bytes of a
scripted session and of a crowd of 100 sheep exactly; `assets/baselines/net/bandwidth.txt`
holds the numbers, rewritten with `-define:VX_BANDWIDTH_ACCEPT=true`
(`ODIN_TEST_NAMES=server.test_bandwidth_accept ./build.sh test server`).

Replays repeat the server's *inputs*, not its exact output: chunk generation runs on worker
threads, so chunks can arrive in a slightly different order.

## Threads

The server and the worldgen and mesh workers log, assert and allocate like the main thread
(they inherit its context) and each has its own track in profile traces. Odin's
`-sanitize:thread` does not instrument memory accesses (as of dev-2026-10: only function
entry and exit), so it finds no races; threaded code is covered by deterministic tests
instead (`base/queue_test.odin`, `server/server_test.odin`).

## Debuggers

`build debug` builds and starts gdb (Linux) or lldb (macOS, or `--lldb`) with Odin
pretty-printers from `tools/debugger/`: strings as text, slices and dynamic arrays as their
elements, maps as key/value pairs, unions as just the active variant (or `nil`), Vulkan handles
as hex. Arguments after `--` go to the game.

To use the printers elsewhere: `source tools/debugger/odin_gdb.py` in gdb,
`command script import tools/debugger/odin_lldb.py` in lldb (or in CodeLLDB's `initCommands`).

- **Breakpoints:** Odin's debug info places a procedure's parameters correctly only after its
  first line, so `break some_proc` can show garbage arguments. Break on a line inside the body
  (`break main.odin:113`), or `next` once after stopping.
- **With `VX_BREAK=1`**, the stop is inside `base::debug_break`; `bt` shows the path, and
  `frame function client::draw` (gdb) jumps to your code.
- **Windows:** debug builds write a `.pdb` next to the `.exe`. `build debug` starts the
  [RAD Debugger](https://github.com/EpicGamesExt/raddebugger) if `raddbg` is on PATH, which
  understands Odin types; [RemedyBG](https://remedybg.itch.io/remedybg) and Visual Studio also work.
- After an Odin upgrade, run `tools/debugger/test_printers.sh`: the map printer mirrors the
  runtime's internal layout.

## GPU captures

[RenderDoc](https://renderdoc.org) (Windows, Linux) records a frame's every call, resource and
pipeline state. Start the game from RenderDoc (Launch Application, or
`renderdoccmd capture build/voxiverse`); then either press F12 in the game, or pass
`--capture-frame N` to capture frame N programmatically. Captures go to
`build/captures/voxiverse_frameN.rdc` and are listed in the log at exit. Our object names and
labels show up in RenderDoc's event browser. (The game only talks to RenderDoc when started
from it; it never loads RenderDoc itself.)

## Benchmarking

`build bench <scenario>` measures one thing the same way every time, on any machine, for
anyone (plan.md, M19):

| Scenario | What it measures |
|---|---|
| `chunks` | Generating, lighting and meshing a fixed region on one thread, without the game (tools/bench). `-check` (CI) also fails if the chunk, mesh or vertex counts changed or a stage blew a generous budget |
| `load` | Joining the scratch world until everything around is loaded and meshed: load time, the pools' work, server ticks |
| `views` | Sixteen still views from the spawn: each GPU pass, triangles, the CPU's frame |
| `flight` | 600 blocks of flight at 40 blocks/s: frames while streaming, generation and meshing, ticks |
| `edits` | 12 explosions round the spawn: `edit_shown` (a bulk edit's chunks arriving to all their new meshes shown), meshing, frames, ticks; it waits for the water they let loose to settle |
| `server` | The dedicated server alone (`voxiverse-server --benchmark server`): 8 simulated players join over UDP and fly out in 8 directions; ticks, streaming, generation, bytes sent |

The game's scenarios run a release build with `--benchmark <scenario>`: fixed settings
(`BENCHMARK_SETTINGS` in client/benchmark.odin: no vsync; the player's settings file is
neither read nor written), frames drawn offscreen at 1280 x 720 whatever the window is
(`gpu.set_offscreen`; the copy onto the window is `gpu_present_copy`, left out of
`gpu_frame`), the scratch world and its fixed spawn, the time
of day stopped at late morning, still clouds, no sheep, no sound device. Each scenario
runs three repetitions, each a session of its own after a warm-up, and writes
`build/benchmarks/<scenario>/<time>-<commit>.json` (every metric of every repetition, the
exact counts, the resolution, the machine) and a line in `build/benchmarks/history.jsonl`
(each metric's value). A metric's value is its median, except for the server's load (ticks,
streaming, collecting, bytes sent), where it is the mean: half its ticks may do nothing
while the workers catch up, and the heavy ones are the point. Results compare only on one machine (its fingerprint) and one
scenario version. The metrics are `base.Metric` (base/metrics.odin): recorded in any build,
only while a benchmark measures. `--profile` adds a Spall trace of the run.

`build bench compare <ref> <scenario> [-runs:N]` answers "is this change faster?": it builds
`<ref>` in a git worktree (`build/worktrees/`, kept), runs it and the working tree
alternately N times (default 5), and prints each metric for both with its change and a
Mann-Whitney p; a change is called only at p < 0.05 (with 5 runs each, the smallest p
possible is 0.008; with 3, never below 0.1: use at least 4). Exact counts that differ are
shown first: then the two did different work. Judge a change by `compare`, never by two
runs at different times: this machine's medians move several percent from run to run.

### How to benchmark a change

1. **Pick the scenarios the change can move**: `chunks` for generation, light and meshing;
   `load` for streaming; `views` for drawing; `flight` for drawing while streaming; `edits`
   for re-meshing; `server` for the server under players. When unsure, run several.
2. **Keep the machine otherwise idle and its power steady**: plugged in, nothing else
   compiling or playing, the same power profile for both sides. `compare` alternates the
   two versions, so slow drift (heat) falls on both alike, but noise still widens the
   spread and hides small changes.
3. **Compare against the commit before the change**:
   `build bench compare main <scenario>` (or the commit hash), with the change in the
   working tree. Use the default 5 runs, or `-runs:8` to see changes of a few percent;
   fewer than 4 can never call a change.
4. **Read the counts first.** "COUNTS DIFFER" means the two did different work (more
   chunks, fewer vertices): a change of work, which may be the point (greedy meshing) or a
   bug; the times then compare different things.
5. **Trust only the called changes** (p < 0.05). A difference of a few percent without a
   call is the noise; repeat with more runs if it matters.
6. **Write the result into the commit message**: the scenario, the metrics that changed,
   A and B, and p, e.g. "views: gpu_world 1.098 -> 1.181 ms (+7.6%, p 0.008)".
7. **Exact counts in `bench chunks -check`** (CI) are pinned: a change that alters chunks,
   meshed chunks or vertices on purpose updates them in tools/bench in the same commit.

`--smoke` (`build bench <scenario> --smoke`, and the game's and server's `--smoke`) runs a
scenario once, short, with a small view: what CI runs to keep every scenario working.
Its results go to `<scenario>-smoke` and compare with nothing.

## Profiling

Measure with optimized code: the default development build is lightly optimized (3-8x slower
than release in the chunk pipeline), `--debug` is not optimized at all (7-15x slower). Four
tools, from narrow to wide:

| Command | What it shows |
|---|---|
| `build bench <scenario>` | A benchmark scenario, under fixed conditions (see Benchmarking): the first thing to run before and after a change for speed |
| `build perf [game\|server\|bench] [-- arguments]` | Samples a `--release --symbols` build under Linux perf (call stacks from the CPU's branch records where it has them) and prints the hottest functions per thread; `perf report -i build/game.perf` for call graphs, `--sort srcline` for source lines. Threads carry their names (`server`, `worldgen 1`, `mesh 2`) |
| `build run --release --profile`, then `build trace` | A Spall trace of every instrumented scope and the GPU's passes; `trace` prints each scope's calls and percentiles per thread, a per-second timeline and the slowest frames and server ticks broken down |
| The `session mesher` log line | At the end of a session: chunks meshed, re-meshed (and why: resent, edits, column tops), mesh times |
| `set debug.occlusion_stats 1` | Counts the chunks drawn that pass no pixel (hidden behind nearer ones: what occlusion culling would leave out); logged at exit as `render occlusion` |

`build run --release --profile` writes `build/voxiverse.spall`, a trace for
[Spall](https://gravitymoth.com/spall/) (open it in the web viewer or the native app):

- **CPU:** one track per thread with nested scopes. Add your own with
  `base.profile_scope("name")`, which times the rest of the enclosing block; it compiles to
  nothing in non-profiling builds.
- **GPU:** a track named `GPU (calibrated)` with the frame and every `begin_label`/`end_label`
  section, on the same clock as the CPU tracks when the driver supports calibrated timestamps.
  Otherwise the track is named `GPU (approximate)`: durations are exact, placement relative
  to CPU work is not.

`python3 tools/debugger/check_spall.py build/voxiverse.spall` checks a trace (well-formed,
balanced, aligned when calibrated).

## Found by the party hardening (M48j)

- **`odin test` is not the only build that sees a `_test.odin` file.** Odin compiles every
  `.odin` file of a package into every build of it; only `@(test)` procedures are dropped.
  `server/kit_test.odin`'s `@(init)` (the tests' block kit) therefore ran in the game and the
  server, and every new player started with eight stacks of blocks instead of the launcher
  and the mode's weapons. It is now inside `when ODIN_TEST`; anything else at package level in a
  `_test.odin` file that has an effect (an `@(init)`, a global set at start-up) needs the same.
  `build bench party` found it: its bots held no weapon.
- **`stats_total("deaths")` counted every death twice**: `die` adds the `deaths` counter and the
  Death event adds `deaths.<cause>`, and `stats_total` sums a name and its dotted children. The
  P list's Deaths column (`tally_of`, `players_put`) now reads the exact keys.
- A message with a pitch past `PITCH_LIMIT` (`Fire`, and so any aim computed straight up or
  down) is refused as invalid and the sender is disconnected: clamp an aim before sending it.
- The party's profile (`build bench party`: 8 players, survival, the pistol, rifle and sniper,
  shooting each other and respawning for 35 seconds, three repetitions): the server's tick has a
  median of about 1.2 ms, a p99 of 2.0 to 2.1 ms and a worst of 3.2 to 3.6 ms against the 33.3 ms
  tick; no spike. The client's frame with eight avatars is a hand check (it needs a window).
- `server/party_test.odin` (`test_party_six_clients`, `test_party_eight_clients`): a stepped
  server over real UDP, bots from `net_test.odin`'s `Net_Client`, 6 000 ticks; a few seconds each.

## In CI

Every push builds on Windows, Linux and macOS. On Linux it also runs real frames on Mesa's CPU
Vulkan driver under the validation layer (normally, with AddressSanitizer, and with profiling,
checking the trace), and checks the gdb/lldb printers. Any validation finding, leak, sanitizer
report, malformed trace or printer regression fails the build.
