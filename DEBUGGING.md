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
            3.215 WARN  main       gpu renderdoc is loaded but did not provide API 1.6 (gpu/renderdoc.odin:60)
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
| `VX_VALIDATION=0` / `1` | Validation off (debug builds) / on (also in release builds) |
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
struct fields described by variable tables; see PLAN.md, "Console and variables".

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

A world is a directory: `world.cfg` (text: format, seed, time, spawn, starter kit, rules), `players/<name>.json` (each player:
where they are and look, flying, their inventory by item name; written when it changed),
`permissions.cfg`, `community.cfg`, `entities.cfg` and `regions/` with
the edited chunks only (`r.<x>.<z>.vxr`, 16x16 chunk columns each; the rest regenerates from
the seed). Files are replaced through a temporary file, so a crash mid-save keeps the previous
save; a region file that fails its checksum is moved aside (`.damaged-<time>`) with an error,
never loaded. `server/save_test.odin` covers save, quit and load, edits surviving unloading,
and damaged files.

## Sound

Every sound effect is synthesized at startup (`client/sfx`: no recordings) and mixed by our
own mixer (`audio/`); miniaudio only opens the sound card. `build sfx` writes them all to
`build/sounds/*.wav` to listen to outside the game. F3 shows the device, voices playing,
sounds played and dropped; the log's last `audio` line sums up the run. Without a sound card
(CI, a headless box) the game logs a warning and runs silent. `set volume 0..1` is the
player's volume. On Linux and macOS the build compiles Odin's miniaudio library once (into the
Odin install; Windows ships it), which needs a C compiler.

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

## World commands

| Command | |
|---|---|
| `singleplayer` / `leave` | Enter a scratch world (never saved: for scripts and tests) / leave the world |
| `world <name>`, `save` | Play a saved world (created if new) / save now (the server also autosaves every minute and when you leave). Saves go to `VX_SAVES` if set |
| `set view_radius 6; set view_height 3` | View distance in chunks for the next world (default 12 x 6) |
| `time [sunrise\|day\|noon\|sunset\|night\|midnight\|0..1]` | Show the time of day, or set it (the server's clock; singleplayer). `set rules.daylight_cycle 0` stops it, `rules.day_length` is seconds per day |
| `tp <x> <y> <z> [yaw pitch]` | Move the player (feet position; a request to the server, which allows it in singleplayer; also before joining). Like every arrival it lands: the player is held there until the blocks are loaded, then stands where they fit (out of blocks, upwards) |
| `spawn`, `setworldspawn [x y z]` | Back to the world spawn (landing on the ground of its column: on whatever stands there now) / new players arrive here (or there), exactly, looking as you look. A new world's spawn is the generator's search (dry open land, no tree or structure near), chosen once and kept in `world.cfg` |
| `set rules.<name> <value>`, `vars rules` | Game rules (gravity, speeds, jump height, reach, flying): the server's, so `set` asks it and it announces the change to the client's prediction |
| `break`, `place [block]` | Hit the aimed critter, else break the aimed block / place one against its face, as the mouse buttons do (scripts: `tp ... ; wait 30; break`) |
| `summon` | A critter three blocks in front of you (`world.summon`). Critters also come by themselves in daylight, on grass 16-40 blocks from a player, at most 6 near one; they go when nobody is within 80 blocks. The server's `entities.cfg` keeps them with the world. F3 counts the entities near you |
| `pos1`, `pos2`, `sel` | The aimed block becomes the selection's first / second corner (drawn as a box) / forget the selection |
| `fill <block>`, `replace <from> <to>`, `clear` | Bulk edits of the selection (`world.edit.bulk`; at most 64x64x64 blocks). The server applies them in one pass and sends each touched chunk whole, after a `Bulk_Begin` saying how many follow; the client shows them all in one frame once all are meshed |
| `sphere <radius> [block]`, `explode [radius]` | A ball of block (default air) / an explosion (carves, knocks back, hurts critters) at the aimed block |
| `fire` | Fire a rocket where you look, as the launcher (hotbar 7) does: it flies, falls a little and explodes on what it hits |
| `fly` | Start or stop flying (as a double-tap of jump does) |
| `locate <biome>` | Fly to the nearest place of a biome (Earth worlds; `teleport.locate`): ocean, frozen_ocean, beach, river, plains, forest, taiga, tundra, desert, mountains |
| `set worldgen.<name> <value>`, `vars worldgen` | The Earth generator's settings (the server's, like rules; F4 too), saved with the world; chunks already made keep their blocks until `regen` |
| `server <command...>` | Send a server command as is, with coordinates: `server fill 0 60 0 9 62 9 water` (scripts, tests; the server checks each command's permission) |
| `structure save <name> [clear]`, `structure paste <name> [turns]`, `structure list` | Keep the selection as `<world>/structures/<name>.vxs` (air as void, or with `clear` as air) / put one (the world's, else a shipped one) at the aimed block through the bulk edit pipeline, turned 0-3 quarters |
| `regen [radius]` | Remake the unedited chunks within radius (chunks, 1-8) from the generator as it is now |
| `tour_test [quit]` | The M10 check: visits every biome (`locate`), screenshots each (`biome_<name>`), then fails on a biome not found, a frame p99 over 100 ms, chunk generation or meshing p99 on the workers over budget (5 and 10 ms in an optimized build, ten times that unoptimized), or memory growth after the first biome |
| `blast_test <shots> [quit]` | The M9 check: waits for the world, hovers above it and fires rockets and radius-6 explosions in turn, then fails on a frame p99 or server tick over 100 ms, a blast not shown whole (its meshes in one frame), arena growth, or chunks that differ from the server's (both sides hash them) |
| `fly_test <blocks> [quit]` | The memory check: waits for the world to load, flies straight at 40 blocks/s, then fails if either session arena grew or chunk storage passed its fixed size. Logs frame times and resident memory. With `quit` it exits, failing the run on a failed check. |

F3's `chunks:` line shows how long chunks take to generate (on our own server's workers)
and to light and mesh (ours), on average and the slowest 1%.

## Permissions

What a player may do is a set of nodes: `world.edit` (build), `world.edit.bulk`, `world.fire`,
`world.explode`, `world.summon`, `world.structure`, `world.time`, `world.rules`, `world.gen`,
`teleport.tp`, `teleport.locate`, `server.save`, `server.open_lan`, `permissions.edit`,
`debug.hash`, and the `chat.*`, `moderation.*`, `teleport.*` and `info.*` nodes the commands
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

Items are data (`game/items.odin`): every block players may place has its item (its name is
the block's), tools are items of their own (`rocket_launcher`). An inventory is 30 slots (the
first five the hotbar, then a 5x5 grid) and the stack on the cursor; the server owns it and applies requests
with the same code the client predicts with (`game/inventory.odin`), answering each with the
inventory (`Inventory_Update`, how far it got): a refused request is rolled back. Placing a
block uses one from the hand (or the hotbar) unless the player has `items.infinite`; breaking
leaves the block's item where `rules.drops` (not for `items.infinite`); `items.catalog` lets
the inventory take any item. Dropped stacks are entities: they fall, merge with stacks of
their item, are picked up by walking over them (half a second; two for the one who dropped
it) and go after five minutes. A player new to a world gets `world.cfg`'s `kit`.

| Command | |
|---|---|
| `inventory`, `drop [all]` | Open the inventory / drop from the hand (as E, Q do; scripts) |
| `server give <player> <item> [count]` | `items.give`; what does not fit is dropped at their feet |
| `server clear [player] [item]` | Empty an inventory, or of one item (`items.clear`; others' `items.clear.others`) |
| `server item` | What you hold, its id and stack size |

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

Every in-game panel is an overlay on one stack (`client/overlays.odin`): the game menu,
Options, tuning, chat, console, the quit dialog. Each says whether it takes the keyboard,
frees the mouse or pauses the world; the top one gets the keys, the focus and Escape.

## Liquids

Water levels are block ids (a source, flow levels 1-7, falling), so saves and the protocol
need nothing new. The server runs scheduled block updates (`server/liquids.odin`): a queue
ordered by tick and position, at most 4096 run a tick, so the same edits give the same water
on every run. Any block change wakes the water next to it; seas and lakes are left alone
until something opens them. Changes the world makes travel as one `Blocks_Changed` per chunk
per tick. F3's server line shows the updates waiting. `server/liquids_test.odin`: the dam
break (the same water twice, both players matching the server) and the flood (10 000 blocks
flowing within the tick budget; CI runs it optimized too).

## Structures

A template (`game/structure.odin`) is a box of cells, each a block or void (leave what is
there); its .vxs file has a palette of block names and runs of cells. Shipped templates are
`assets/structures/*.vxs`, built in-game and compiled into `worldgen` (generation reads no
files). In an Earth world each structure kind has a set: cells of its spacing each decide by
a hash whether they hold one, where and turned how, so any chunk can work out the pieces
reaching into it (`worldgen/structures.odin`); surface ones need flat land and get
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
`worldgen/worldgen_test.odin` keeps hashes of two seeds' chunks: CI runs it on Windows,
Linux and macOS, so a platform that rounds differently fails there, not in a player's world.
The generator's stages show in the profiler as `worldgen climate`, `worldgen place trees`,
`worldgen terrain`.

`--exec "fly_test 1500 quit"` is the M3 exit check; CI runs smaller versions on the CPU
driver, with AddressSanitizer and with profiling. CI also runs `blast_test 12 quit`. F3
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
| `build netdump [file]` | Print a trace, decoded by the game's own decoders: `-kind:chunk`, `-sender:client`, `-from:2 -to:3`, `-limit:20`, or `-summary` for counts and bytes per kind. Fails if any message does not decode. |
| `build replay [file]` | Feed the trace's client messages to a fresh server with the same seed, view distance and timing (`-speed:4` for faster). Whatever the server did with them (assert, crash, disconnect) happens again outside the game; its answers go to `build/replay.trace`. Exits non-zero if the server failed or disconnected the client. |

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

## Profiling

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

## In CI

Every push builds on Windows, Linux and macOS. On Linux it also runs real frames on Mesa's CPU
Vulkan driver under the validation layer (normally, with AddressSanitizer, and with profiling,
checking the trace), and checks the gdb/lldb printers. Any validation finding, leak, sanitizer
report, malformed trace or printer regression fails the build.
