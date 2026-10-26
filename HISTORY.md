# Voxiverse: finished milestones

The detailed sections of milestones that are done, moved out of PLAN.md so the plan stays
short. The table in PLAN.md keeps one row per milestone with what was done; code comments
that cite "PLAN.md, M<n>" for a finished milestone mean its section here.

## M9-M12: making and changing the world

The world after M8 is grassy hills, one cave noise and a critter; edits are one block at a
time. These four milestones make it worth exploring and easy to reshape, in this order
because each needs the one before: bulk edits are how worldgen is debugged, water is
filled and structures are pasted; worldgen gives water somewhere to be (oceans, lakes) and
structures somewhere to stand.

### M9: bulk edits and explosions

- **One edit pipeline** on the server: a shape (sphere, box) and an operation (set, replace
  A with B, carve: air sparing bedrock). Applied chunk by chunk; each touched chunk is
  marked edited (saved), column tops are recomputed once per touched column, and every
  client that has a touched chunk is sent the whole chunk again (under the network backlog
  budget) instead of thousands of single-block messages.
- **No prediction** for bulk edits: the result arrives as chunks one round trip later. What
  must feel instant (the flash, debris, sound of an explosion) comes from an `Explosion`
  message played on arrival, and locally at once for the one who fired.
- **Client side:** relight and remesh the touched chunks and their neighbours, the visible
  ones urgently (M4's no-x-ray rule), the rest within a per-frame budget.
- **Limits:** a largest edit volume and an edit rate per player; commands are cheats.
- **Selections:** two corners (`pos1`/`pos2` from the aimed block), drawn as a box;
  `fill`, `replace`, `sphere`, `clear` act on them. M12's `structure save` uses them too.
- **The rocket launcher:** a creative hotbar item. The rocket is an M8 entity (ballistic,
  no AI), simulated on the server; on hitting a block or entity it explodes: a sphere is
  carved, entities and players nearby are knocked back (players stay invulnerable), debris
  particles and a synthesized boom play where it happened.
- **Exit check, `blast_test`:** like `fly_test`, a console command that fires a volley of
  radius-6 rockets along a path and fails on a server tick or client frame over budget, a
  see-through hole, memory growth, or a chunk that differs between the server and two
  clients (chunk hashes compared).

### M10: the worldgen framework

- **Generators are pipelines** in their own package (`worldgen/`), chosen per world
  (`world.cfg: generator = earth`), deterministic per chunk from the seed. Stages, each with
  its own seed: climate (temperature, humidity, continentalness, erosion noise) and biome
  lookup; terrain shape (a 3D density: base height from splines over the climate, plus 3D
  noise for cliffs and overhangs); surface rules per biome (grass, sand, snow, stone
  layers); carvers (caves, ravines); features (ores, trees, boulders, plants).
- **Crossing chunk borders without seams:** features are placed from a per-chunk RNG and
  every chunk also runs the placements of its 8 neighbours, writing only its own blocks;
  a feature fits within one chunk's margin (trees, boulders). Bigger things are M12's.
- **Parameters are a variable table** (`worldgen.*`): tunable live from the console or F4,
  saved with the world, and `regen` regenerates the chunks around you after a change.
- **Column tops for sky light** come from the generator (including trees), replacing
  M3's analytic `column_height`: with overhangs, the top is no longer a formula.
- **Noise library:** OpenSimplex2-style gradient noise, fractal sums, domain warping,
  written in integer-friendly ways so every OS gives bit-identical worlds.
- **New blocks:** water (still), snow, ice, clay, log, leaves, coal/iron/copper ore, tall
  grass and flowers (cross-shaped models), cactus. Textures generated, as before.
- **Renderer:** a cutout pass (alpha-tested: leaves, plants) and a translucent pass (water:
  drawn after the opaque world, back to front per chunk, its surface gently moving).
- **Tools:** `build worldmap -seed N -size 4096` renders a top-down map (biomes, heights,
  water) to a PNG in seconds, without the game; per-stage timings in the profiler and F3.
- **Exit check:** map hashes per seed equal on all three CI platforms; chunk generation and
  meshing p99 within budget on worker threads; `fly_test` across every biome stays flat in
  memory and within frame budget; a CI screenshot per biome.

### M11: liquids

- **Water states are block ids:** a source and flow levels 1-7 (and falling), so palettes,
  saves and the protocol need no block metadata.
- **Scheduled block updates** on the server: a queue of (due tick, position), so only what
  changes is looked at; a per-tick budget; updates in unloaded chunks wait with them.
- **Minecraft's rules:** down first, then sideways losing a level per block and preferring
  the nearest way down within 4 blocks; a new source between two sources over solid
  ground; placing or breaking next to water schedules its neighbours.
- **Network:** water changes travel as per-chunk batches of changed blocks each tick, not
  one message per block.
- **Players:** swimming in the shared physics (buoyancy, drag, jump to rise), so
  prediction stays exact; underwater fog and tint; sky light falls off through water.
- **Exit check:** a dam-break test (a filled pool, a wall removed) ends in the same water
  every run and on the server and two clients; 10 000 flowing blocks stay within the tick
  budget; swimming has physics tests like walking's.

### M12: structures

- **Templates:** select a box in-game and `structure save <name>`: a `.vxs` file (palette and
  runs, like region files, plus size, origin and which air should stay air). `structure
  paste <name> [rotation]` goes through M9's pipeline. Templates that ship with the game
  live in `assets/structures` (our own builds: within the assets rule).
- **Placement:** each generator lists structure sets with a spacing; the world is cut into
  cells, each cell picks deterministically whether and where its structure goes, so its box
  is known before any of its chunks is generated. A chunk applies every structure piece
  that overlaps it, after terrain and before features; foundations fill down to the
  ground, and the space inside is cleared.
- **Procedural structures** (dungeons as rooms joined by corridors, towers of any height)
  produce the same pieces through the same placement API.
- **Exit check:** a structure spanning several chunks is identical whichever order its
  chunks are generated in; save, paste and save again gives the same file; placements are
  the same for a seed on every run; `worldmap` marks them.

## M13: players together

Mechanisms, not gameplay: what servers and content will be built on. Each feature is a
permission node from the start.

- **World spawn:** chosen once when a world is made (the generator's search, now standing
  clear of trees and structures) and stored in world.cfg; `setworldspawn` moves it. Joining
  for the first time, `spawn`, and every teleport land through one safe-landing step: wait
  until the column is loaded, then stand on the highest spot with ground under it and two
  blocks of air above.
- **Overlays and focus:** the pause menu, options, tuning panel, quit dialog, console and
  chat become entries on one stack. Each declares whether it takes the keyboard, frees the
  mouse or pauses the world; the top one gets the keys and Escape; game controls run only
  when nothing takes the keyboard. The console's line editing (readline keys, history, Tab)
  is a widget any overlay uses.
- **Chat:** `t` opens it, `/` opens it with a command started. Lines fade over the game when
  closed. The server checks each message (length, rate, mute), formats it (the sender's
  tag, name and permitted codes) and sends it to everyone who does not ignore the sender;
  it logs chat. Chat commands share the command table with the console's server commands.
- **Permissions:** nodes are dotted names (`chat.format`, `chat.delete`, `world.edit.bulk`,
  `server.stop`); grants may end in `*` (everything under) or start with `-` (denied).
  Roles grant nodes and inherit other roles; players get roles and their own grants; the
  most specific grant wins, a denial over an allow at the same depth. Roles and players
  carry metadata (prefix, suffix, name colour, anything later). `permissions.cfg` in the
  world directory; edited with `role` and `user` commands or by hand. The owner of a
  singleplayer world and a dedicated server's `--admin` names get `*`. Every server action
  asks one `allowed(player, node)`; today's cheats switch becomes nodes.
- **Formatted text:** `&0`-`&f`, `&#rrggbb`, `&l` bold, `&o` italic, `&n` underline, `&m`
  strikethrough, `&r` reset, parsed in one place (`game/format.odin`). Each part of a chat
  line (tag, name, message) is formatted on its own, so a tag's colour never leaks into
  the name. The UI draws it (bold: drawn twice a pixel apart; italic: slanted), the console
  too.
- **Commands (EssentialsX-style):** places and teleports (spawn, setworldspawn,
  home/sethome/delhome/homes, warp/setwarp/delwarp/warps, tpa/tpahere/tpaccept/tpdeny,
  back, top, tp); messaging (msg, r, me, broadcast, ignore, nick/realname, motd);
  moderation (mute, kick, ban, tempban, unban, ban-ip, deleting chat messages); who and
  status (list, whois, seen, afk, status: tick time, memory, chunks, players). Homes,
  warps, bans and nicknames are kept with the world.
- **Exit check:** permission resolution tests (wildcards, negation, inheritance,
  specificity); focus routing tests (which overlay gets a key, Escape order); chat over UDP
  between two players with roles, tags, colours, a mute and an ignore; spawn and teleport
  landings never inside blocks (tests on worlds with trees and structures at the spot).

## M14: items and player data

Still mechanisms, not gameplay: what an item does, how many a stack holds, whether placing
uses one up are data and permissions a server or content sets.

- **Items:** kinds as a data table (`game/items.odin`: name, stack size, the block it
  places, tool, tags); every placeable block has its item; today's hotbar items (blocks,
  the launcher) become item kinds. A stack is a kind and a count (and room for data later).
- **Containers:** server-owned slots: each player's inventory (main slots, the hotbar, the
  stack on the cursor), the API any later container (chests) uses. Clients ask with
  container actions (pick up, place, split, swap with a hotbar key, drop, quick-move);
  the server applies them under the shared rules and confirms or corrects; the client
  predicts as it does edits, and rolls back a refusal.
- **Using items:** placing a block uses one from the held stack unless the player has
  `items.infinite` (the owner of a world played here: creative by permission, not by
  mode); breaking a block drops its item where the rule says (`rules.drops`).
- **Dropped items:** entities that fall, merge with neighbours, and are picked up by players
  walking over them (room permitting), despawning after a while.
- **Inventory overlay:** `e` opens it over the game (an overlay: frees the mouse, does not
  pause); drag and drop, right-click splits, shift-click moves, number keys swap with the
  hotbar, tooltips with the item's name; the hotbar shows counts.
- **Player data:** `<world>/players/<name>.json` holds everything kept about a player
  (position, look, flying, inventory; M15 adds statistics): loaded on joining, written
  atomically when changed, only online players in memory. Existing worlds' `player.*`
  lines in world.cfg move there on load. Homes and the like stay in community.cfg (the
  world's view of a player), the player file is the player's own state.
- **Commands:** `give <player> <item> [count]`, `clear [player] [item]`, `item` (what you
  hold), each a node.
- **Exit check:** container action tests (every action, full stacks, refusals); two players
  over UDP drop, pick up and move stacks and agree with the server; a refused action rolls
  back the prediction; inventories survive save and load exactly; a world with world.cfg
  players loads into player files; UI tests drag, split and shift-click.

## M15: polish

- **Biome transitions:** biomes are hard thresholds on smooth climate, so surfaces and
  features switch at a line. The thresholds are jittered per column by fine noise, so a
  band of 6-12 blocks mixes both sides (dithered, as the pixel look wants), and tree and
  plant densities blend across it instead of switching. New golden hashes.
- **Keep the screen awake** while in a world, not in menus: Windows
  `SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED)`; X11 `XScreenSaverSuspend`
  (else the freedesktop `Inhibit` call); macOS an IOKit power assertion. In `platform/`,
  released on leaving a world and on exit.
- **Five hotbar slots over a 5x5 inventory:** 30 slots, every row five wide; the overlay is
  one five-column grid with the hotbar as its bottom row; number keys 1-5. Inventories
  saved at the old size keep their stacks (what no longer fits is given back in order, the
  rest dropped at the player's feet on joining).
- **Exit check:** worldgen tests that a border band mixes surfaces and features (and
  screenshots of a few borders); the keep-awake call made and released (a platform test
  where the OS allows it, else a logged check); inventory tests at the new size; an old
  36-slot player file loads.

## M16: accounts and characters

- **Accounts:** the client makes an Ed25519 keypair on first launch (`core:crypto`), kept
  beside the settings; the public key is the account. `Hello` carries it and the server
  answers with a challenge the client signs, so nobody can join as someone else without a
  central login service. A universe's first sight of a key registers it there.
- **Characters:** an account has characters in each universe (a name, unique in that
  universe; appearance later). The client chooses one before joining (a small screen; the
  last one played by default); the universe keeps them. Chat, the player list, permissions and community data
  name characters; permissions can also grant to an account (all its characters).
- **Data:** everything kept about a player (M14's player files: where they are, their
  inventory; M29's statistics) becomes the character's, kept by the universe:
  `characters/<account>/<character>.json`. Existing player files become characters of a
  placeholder account, claimed by the first key that joins with that name.
- **Exit check:** over UDP, a client can't join with another's key or take a character
  name in use by another account; a character's data survives a restart; old player
  files migrate; the challenge refuses replays.

## M17: many worlds, named by addresses

A universe (one server) hosts many worlds and loads them in and out. Grounded: worlds are
flat voxel spaces (a world border can make them finite), not spheres; travel is a short
transition while the destination streams in, not flying through rendered space.

### Addresses: how many worlds

The address space is sized after the observable universe, so "every planet has an
address" is roughly true, and the numbers can be checked:

- **Galaxies:** about 2·10¹¹ to 2·10¹² in the observable universe (Hubble deep-field
  counts gave ~2·10¹¹; Conselice et al. 2016 extrapolated ~2·10¹² counting faint ones;
  New Horizons background-light measurements (2021) point back toward a few 10¹¹).
- **Stars per galaxy:** about 10¹¹ (the Milky Way: 1-4·10¹¹), so 10²² to 10²⁴ stars.
- **Planets per star:** at least one on average (microlensing, Cassan et al. 2012: ~1.6
  bound planets per Milky Way star; Kepler's occurrence rates agree in order).
- **So:** ~10¹¹ planets per galaxy, ~10²³ to 10²⁴ in the observable universe.

One flat address cannot match that and stay dialable (36 symbols would need 17 per
address; 72 symbols, 13). The universe's own structure gives two levels instead:

| Part | Symbols | How many | Matches |
|---|---|---|---|
| Galaxy | 8 of 40, ordered, none twice: 40·39·…·33 | 3.1·10¹² | ~10¹¹-10¹² galaxies |
| World in its galaxy | 7 of 40, ordered, none twice: 40·39·…·34 | 9.4·10¹⁰ | ~10¹¹ planets per galaxy |
| Both | 15 | 2.9·10²³ | ~10²³-10²⁴ planets |

Everyday dialing is seven symbols within the gate's galaxy; another galaxy takes all 15
(rarer, later). Every count is a permutation (order matters, no symbol twice), so the
numbers above are exact: `math.perm(40, 8)`, `math.perm(40, 7)`. Should the estimates
move, change the symbol count or lengths here, not the idea.

### Symbols

40 letters of Old Turkic (Orkhon, U+10C00-U+10C48): angular, runic, unreadable to nearly
everyone (so they read as alien), and a historic script with no living community (unlike
Tifinagh or the Canadian syllabics, which look alien but are people's writing today).
Runic reads as Vikings, Glagolitic as Slavic ornament, Linear B is too pictographic to
dial at a glance. The 40, by index (0-39):

    10C00 10C01 10C04 10C05 10C07 10C09 10C0A 10C0B 10C0C 10C0D
    10C0E 10C0F 10C10 10C12 10C14 10C15 10C18 10C1C 10C22 10C24
    10C26 10C27 10C28 10C2B 10C2C 10C2D 10C31 10C32 10C36 10C38
    10C39 10C3A 10C3C 10C3D 10C41 10C42 10C43 10C44 10C45 10C47

A few pairs are close (indices 2/25, 11/23, 15/31, 29/30); M18 settles the final set on the
dialing overlay at its real size. They are real Unicode, so addresses copy into chat and
outside the game (Windows has the script in Segoe UI Historic, others in Noto). In the
game they come from a fallback font: Noto Sans Old Turkic (15 KB, SIL Open Font License,
its licence beside it as JetBrains Mono's), used for what JetBrains Mono lacks. JetBrains
Mono has Latin, Greek, Cyrillic and symbols, none of these; no font has all of Unicode (a
TrueType font holds at most 65,535 glyphs), and Nerd Fonts add icons in the private use
area, not scripts.

### The rest

- **Addresses:** a galaxy and a world in it, as above. An address is a world's id in its
  universe and its directory (`worlds/<address>/`, the symbols' indices in hex: file
  systems need not know the script). The address alone decides the
  world's kind: its generator and parameters (sea level, terrain, climate offsets, biome
  mix, block palette), rules (gravity, day length) and sky (M28's astronomy too), so an
  address shared between players means the same kind of world in any universe; the world
  seed is the universe seed and the address hashed, so the terrain itself differs. The
  universe's home world keeps today's Earth parameters exactly; its address is derived
  from the universe seed. Whether every address leads somewhere is a universe setting
  (default: all; a fraction makes discovery matter).
- **Worlds:** each has its own generator, parameters, rules, sky, chunks, entities,
  liquids, spawn and save. An unvisited world costs nothing but its address; it gets a
  directory once visited or edited.
- **Loading:** a world is loaded while someone is in it (and briefly after); unloaded, it
  is only its save. Workers and the chunk memory pool are shared, sized by players as
  today. Cost scales with loaded worlds and their loaded chunks, never with how many
  worlds exist.
- **Players:** in one world at a time; the client holds only that world's chunks. A
  travel message tells it the new world's rules, sky and spawn; it drops its chunks, plays
  a short transition, and M13's landing holds the player until the destination's blocks
  are there. Characters (M16) are the universe's, so inventories travel with them; homes,
  warps and back remember their world.
- **Commands:** `travel <address> [character]` (until M18's gates), `worlds` (the loaded
  and saved ones), `address` (this world's).
- **Exit check:** two players over UDP in different worlds of one universe; one travels to
  the other's carrying their inventory and lands safely; one address gives the same
  parameters in two universes and different terrain; an unloaded world takes no tick
  time; memory flat over repeated travel; each world's save stays its own; the client
  never holds two worlds' chunks.

## M18: gates

- **Gates:** a structure on M12's placement API (programmatic, like towers): a ring with
  seven chevrons (and eight more, dark until a gate can reach other galaxies), its lowest
  row set in its platform so one walks in level. Rare (one 1024-block cell in three or so,
  on flat dry plains, forest, taiga, tundra or desert), and none within `gate_distance`
  (2000 blocks) of the world's middle, where players begin: finding one is late-game
  (`locate gate` puts an admin in front of the nearest). Travellers arrive at the dialed
  world's gate nearest its middle. Worlds made before gates have none
  (`worldgen.gates 0`).
- **Dialing:** using a gate opens an overlay of the 40 symbols; choosing seven in order
  locks the chevrons one by one (seen and heard by everyone near). The gate then opens
  for a while (the destination's gate opens too); walking in travels (M17) to the
  destination's gate. Misdials (this world's address, another galaxy, a gate already
  open at either end, a world without gates) are refused with a word. Arriving, one
  faces away from the far gate, which does not send back.
- **Done:** chevrons lock every 0.4 s, the gates stay open 30 s (`Config.gate_open` for
  tests); `Dial` (protocol 15) names the gate's block and the address; the server sets
  the lit chevrons and horizon blocks wherever the chunks are loaded and puts them back
  on closing. Right-click a ring (or the console's `dial [address]`) to dial.
- **Exit check:** over UDP, dialing opens the gate and carries a player to the dialed
  world's gate and back; gate placements match on every platform (worldgen hashes); a
  misdial is refused; the dialing overlay in UI tests.

## M19: performance

Profiled from first principles. Times are from one 4-core machine with integrated graphics:
compare them with each other, not across machines. Numbers are per chunk unless said.

- **Tools** (DEBUGGING.md, Profiling): `build bench` (generate, light and mesh of a fixed
  region on one thread, deterministic; `-check` in CI pins its counts and budgets),
  `build perf` (Linux perf on a `--release --symbols` build, per named thread), `build
  trace` (a Spall trace summarized), the `session mesher` log line; the benchmarking
  system below replaced a first `view_test` and history file. Build profiles: an optimized
  development build by default (debug builds are 7-15x slower in these loops, which is
  what looked like the mesher churning).
- **Loading** (the spawn's 5733 chunks: 6.0 s → 1.7 s; server tick time over a flight
  1430 → 330 ms):
  - workers idled most of each tick (16 chunks queued per worker, refilled once a tick):
    64 per worker;
  - a column's climate and trees worked out again for each of its ~24 chunks: a per-worker
    `Column_Cache`, and chunks requested whole columns at a time so it hits (generate
    0.333 → 0.188 ms on one thread);
  - 48 chunks a tick sent at most (the cap once the workers kept up): a byte budget;
  - water wake-ups looked up ~1700 cells per chunk collected: a per-chunk water flag;
  - the server thread worked out each column's tops itself (most of `stream`): tops jobs
    on the workers, a column's chunks sent once its tops are known.
- **Chunk work:** light filled its region block by block (0.389 → 0.163 ms: rows); caves
  interpolated every solid block (generate 0.200 → 0.169 ms: cells that cannot hold cave
  skipped, bit for bit the same blocks).
- **GPU** (sixteen views from the spawn: 2.34 → 1.70 ms a frame; triangles 517k → 291k):
  - meshes grouped by face direction, only the groups that can face the camera drawn (517k
    → 331k triangles, 2.34 → 1.85 ms);
  - greedy meshing of evenly lit faces (331k → 291k, 1.85 → 1.73 ms; exact:
    `test_greedy_meshing_is_exact`);
  - chunks drawn nearest first, so the depth test spares hidden fragments (the worst views
    most: the world pass's p99 2.9 → 1.8 ms).
- **Benchmarking (designed after the first round showed its gaps; built next).** What the
  first round had (the chunk benchmark, exit checks printing numbers, Spall, perf, a
  history file) did not hold together: the player's settings, window size, time of day,
  drifting clouds and random critters leaked into results; single runs with no warm-up
  or noise estimate; correctness checks doubling as measurements; most timings only in
  profiling builds; no way to compare two versions under the same conditions.
  - **Scenarios, in code, in the game binary.** A scenario fixes everything that changes
    the numbers: the world (the scratch world's seed and generator), the settings
    (resolution, vsync off, field of view, view distance, UI scale; the player's settings
    file is never read nor written), the conditions (a fixed time of day with the cycle
    stopped, the clouds at a fixed place, no natural critters or a seeded random source,
    no sound device), a camera script, a warm-up, and the metrics it reports. It runs by
    itself: `voxiverse --benchmark <scenario>`, wrapped as `build bench <scenario>` (a
    release build). A scenario has a version, bumped when its script changes; results of
    different versions are never compared.
  - **The scenarios:** `chunks` (generate, light and mesh per chunk on one thread: the
    present tool, same result format), `load` (join to a fully meshed world: workers,
    ticks, streaming), `views` (fixed views: GPU time per pass, triangles, the CPU's
    recording), `flight` (streaming while moving: frames, generation and meshing
    throughput, ticks, memory), `edits` (bulk edits and explosions: re-meshing), `server`
    (a headless server, simulated players moving, liquids and entities: tick time as
    players grow).
  - **Metrics in release builds.** A registry of named timers and counters (an enum in
    `base`), cheap enough to leave in (two clock reads and an atomic index into a
    fixed ring of samples per metric), recorded only while a benchmark runs. The GPU's
    per-pass timestamps, read back every frame already, feed it too. Spall stays for
    looking inside a frame.
  - **Fixed resolution.** GPU scenarios draw into an offscreen 1280 x 720 target whatever
    the window is (then copied to it, timed apart), so the window manager, fullscreen or
    the screen cannot change the work measured.
  - **Method.** Warm-up first (discarded); several repetitions; each metric reported as
    the median of the repetitions' medians with its spread. A result file per run in
    `build/benchmarks/` (never committed): the scenario and its version, the commit, the build
    profile, the resolution obtained, the machine (CPU, cores, GPU, driver, OS; a
    fingerprint to group by), and every metric per repetition. Results compare only
    within one machine.
  - **Comparison.** `build bench compare <ref> [scenarios] [-runs:N]` builds `<ref>` in a
    git worktree under `build/worktrees/`, then runs the reference and the working tree
    alternately (A B A B ...: heat and background load fall on both alike) and prints each
    metric's change, flagged when the two sets of runs differ beyond chance (a
    Mann-Whitney test). `<ref>` must have the benchmark system (from the commit that
    adds it on).
  - **Checks stay checks.** Exit checks (fly_test, tour_test, blast_test) stay pass/fail
    gates and lose their side numbers to the scenarios. In CI: the deterministic counts
    exactly (as `bench -check` does now), timing only within coarse budgets (shared
    runners are too noisy for more), the result files kept as artifacts.
  - **Phases:** (1) scenarios with fixed conditions, the metrics registry, the result
    format, `views`, `load` and `flight` (done: client/benchmark.odin, base/metrics.odin,
    base/bench_result.odin; `chunks` writes the same results; `view_test` and the old
    history file gone); (2) repetitions, statistics, `compare` (done: tools/build/compare.odin;
    comparing the code with itself calls nothing though single medians move up to 6%; its
    first use turned down the clouds' skipping); (3) the
    offscreen target (done: gpu/offscreen.odin; `views` in a 1280 x 720 and a 640 x 360
    window: the same GPU frame within 0.5%, only the copy onto the window differs); (4)
    `edits` and `server` with simulated players (done: `edits` measures `edit_shown`, a
    bulk edit's re-meshing latency, not the settling, which is the water's ticks;
    dedicated/bench.odin's 8 bots over UDP; the server's load metrics are means, the
    rest medians: half its ticks send nothing while generation catches up); (5) CI and a
    "how to benchmark a change" procedure in DEBUGGING.md (done: `--smoke` runs each
    scenario once, short, with a small view; CI runs the server's on every platform and
    the game's on Linux's CPU driver, a few seconds each).
- **Commands, the console and scripts (designed at M19's close; done with it).** They had
  blurred: the developer console mirrored a dozen server commands (fill, explode, time,
  spawn ...), duplicated keys (fire, drop, inventory, dial, break, place), and carried
  the exit checks; players' commands sat beside test-only ones (explode, hash). Three
  surfaces, each with one job:
  - **Server commands** (`/` in the chat): everything that acts on the world or the
    server, one registry (server/admin.odin), each command a permission node; roles
    (player, moderator, admin, from permissions.cfg) decide who may run what. All changes
    to the world are the server's: there is no separate developer registry, only
    permissions. Personal (/ignore: muting someone for yourself; /msg, /r, /me, /afk,
    /nick, /realname, /motd, /list, /whois, /seen, /status, /address, /worlds), getting
    about (/home, /warp, /tpa ..., /back, /spawn, /top), moderation (/mute: muting someone
    for everyone, a moderator's job; /unmute, /delmsg, /kick, /ban ...), administration
    (/give, /clear, /tp, /tphere, /travel, /setworldspawn, /setwarp, /time, /save,
    /open_lan, /summon, /locate, /regen), and world editing for builders and admins:
    /pos1 and /pos2 (the aimed block, worked out by the server) keep each player's
    selection on the server, which tells the client its box to draw; /fill, /replace,
    /clear, /sphere and /structure act on it. One-offs made for tests go: /explode,
    /hash (the checks reach the server directly).
  - **The developer console** (the `~` key) is the developers' and holds primitives:
    the session (singleplayer, join, leave, quit, screen), variables (set, vars,
    reset: settings, debug.*, rules.*, worldgen.*), capture and diagnostics (screenshot,
    net_trace, crash), placing the camera for a picture (tp, look), and `server
    <command>`: any server command, sent as the chat sends it, with the developer's
    permissions. Nothing that duplicates a key or the UI, no mirrors of server commands,
    no tests.
  - **Scripts** (`--exec`) are console input typed at startup, with `wait` and
    `wait_world`: for reproducing a state and taking its picture (CI's sky through a
    day, a bug's setup). Nothing that checks or measures: that is code. **Checks** (the
    exit checks: flight, tour, blast) become `--check <name>` like `--benchmark
    <scenario>`, no longer console commands.
- **Also done at the close:** the server frees the chunks a moving player left (the old
  area less the new) instead of looking at every loaded chunk whenever anyone moves: that
  pass took up to 13 ms a tick with 8 players flying (`build bench server --profile`); a full
  sweep stays every 10 s. `debug.occlusion_stats` counts chunks drawn that pass no pixel.
- **Left, measured, for later:**
  - occlusion culling (chunks' faces connected through open space, a search from the
    camera's chunk): 72% of the chunks drawn at the spawn's views pass no pixel (under the
    ground, behind hills), 39% in flight: the next step for the GPU;
  - clouds: ~0.2 ms of a 1.7 ms frame; empty-space skipping tried and dropped (slower);
  - light is worked out for a chunk's whole 48³ neighbourhood each time it is meshed (27x
    the work if light were kept per chunk): the biggest CPU cost left in meshing, worth it
    only when meshing is a bottleneck again.

## M20: the first public build's experience

The release builds (M21) put the game in front of players who are not its developers: what
they see first has to make sense without knowing how it is made. Every screen is looked at
as a player meets it.

- **Game menu:** Back to Game, Options, Open to LAN, and Save and Quit to Title (or
  Disconnect on someone else's server); "Game Paused" under the title only when it is.
- **Words.** Nothing on a player's screen speaks the code's language: no universe, scratch
  world, chunk or seed where a player did not ask for it. The nomenclature table keeps the
  code's words; the screens say save, world, server. A reviewed list of every player-facing
  string is the check.
- **Reference: Minecraft Java's screens**, which most players already know (minecraft.wiki:
  Title Screen, Select World, Loading world screen; its Options): where a screen of ours has
  a counterpart, it works like it unless there is a reason not to.
- **Title screen:**
  - four buttons, one above the other: Singleplayer, Multiplayer, Options, Quit Game
    (Minecraft's order);
  - a starfield streaming towards the viewer, a warp, unhurried: streaks of whole pixels,
    mostly white with a hint of colour (pale blue, gold, violet), never flashing; drawn as
    UI quads (no new pass); Options' **Reduce motion** holds it still;
  - the version in grey in the lower left (the commit until M21 stamps versions).
- **Singleplayer** (was "Universes"; Minecraft's Select World): its saves, newest played
  first, each showing its name and when it was last played; select one and Play (or
  double-click it); **Create New Save** (a screen: the name; the seed under "More
  options"); **Edit** (a screen: rename, **Open Folder**: the save's directory in the
  system's file manager, `explorer`, `open` or `xdg-open` started by the platform layer);
  **Delete** (confirmed); Back. A "save" is what the code calls a universe (nomenclature).
- **Multiplayer:**
  - no name field: the name lives in Options (and is asked for the first time a player
    goes to Multiplayer without one);
  - "Looking for servers on your network" with its dots counting up (. .. ...), so it is
    clearly looking; found servers listed as they answer;
  - **Direct Connection** (Minecraft's name) opens its screen: the address (the last one
    remembered), a password if the server asks, Join, Cancel; a kept server list with Add
    Server, Edit and Delete comes later.
- **Loading screen:** joining a world (singleplayer, a server, a gate's or `/travel`'s
  arrival) shows a screen until the world around the player is there and drawn, instead of
  a world building itself in view: what is happening in words ("Connecting to the server",
  "Starting the world", "Loading the world", "Arriving"), a bar (with its percentage) for
  the chunks around the player loaded and meshed (the same test as `wait_world`), a small map of the columns around filling in
  (as Minecraft's chunk map, in our pixels), and Cancel back to where one came from. A failure
  (a refused join, a lost connection) says why in plain words, with Back.
- **Options**, from research (Minecraft Java's options; the Game Accessibility Guidelines'
  basic list, whose most complained-of issues are remapping, text size, colour and
  subtitles; Luanti's settings, keys bound by their place on the keyboard). Today it is one
  list of every setting variable, raw. Kept: what this game has and a player can use; left
  out: knobs for things the game does not have (particles, music, resource packs, mipmaps,
  graphics APIs, languages while there is one). Tabs, the same from the title and in game:
  - **Video:** display mode (windowed, fullscreen), VSync, max frame rate when VSync is off
    (30, 60, 120, 144, 240, unlimited), field of view (degrees), render distance (one slider
    in chunks; the height follows it), GUI scale (Auto, 1-4), brightness (lifts the darkest
    light levels: caves at night), clouds (on, off: a cost on weak GPUs), show FPS;
  - **Sound:** master volume (more sliders when there is music and more kinds of sound);
  - **Controls:** mouse sensitivity, invert Y, sneak and sprint each hold or toggle, key
    bindings: every action remappable, bound by physical key position (layouts other than
    QWERTY work), with Reset;
  - **Accessibility:** reduce motion (stills the title's stars, and later camera bob and
    shake), chat text size;
  - **Profile:** your name.
  Plain labels, real units, discrete choices where a slider would only confuse; changes
  apply at once and are saved on leaving. Debug and tuning switches stay in F4 and the
  console, never in Options. Later, when the game has them: subtitles for sounds (the
  guidelines' fourth complaint), sound categories, languages.
- **Sneaking** (Minecraft's): holding sneak lowers the eyes and the body (1.8 -> 1.5 blocks
  tall: under a 1.5-block gap), slows walking (as now), and on the ground keeps the player on
  the block: a move that would step off an edge is cut, axis by axis, so one can lean over a
  ledge to build. Shared physics (game/physics.odin), so the server and the client's
  prediction agree; other players see the lower body and name tag.
- **Exit check:** as in the table.

## M21: builds and releases

**What a release needs to carry.** Fonts and structure templates are compiled in (`#load`),
textures and sounds are generated at start-up; the only files the game reads besides the
player's settings and saves are its 14 compiled shaders (116 KB, `shaders/` beside the
executable). So no asset archive format: a release build compiles the SPIR-V in too, and
the game is one self-contained executable (the server another). Development builds keep
reading `build/shaders` for hot reload. An archive format earns its keep only with large
authored assets (music, resource packs, mods); our assets are made by code, so it waits
until something needs it. The package itself is compressed (zip, tar.gz): compressing
inside it again would buy nothing.

- **Profiles** (done early, in M19): the default development build is `-o:minimal` with
  debug info and the dev aids (`base.DEV`: the tracking allocator, validation, hot reload):
  it compiles in about the time of an unoptimized one and runs 3-5x faster; `--debug` is
  unoptimized for stepping through code; `--release` is `-o:speed` without the dev aids
  (half a minute to compile); `--release --symbols` adds line tables with the dev aids
  still off, for profilers (`build perf`). M21 adds: `--release` carries its shaders
  (`#load_directory` of `build/shaders`, `VX_EMBED_SHADERS`), and the packaged game is a
  windowed program on Windows (no console; it logs to its file).
- **Windows icon and version info:** Odin's `-resource:<file.rc>` compiles a resource script
  with the Windows SDK's `rc.exe` (found as it finds the linker) and links it in. The build
  writes `build/voxiverse.rc`: `1 ICON "voxiverse.ico"` and a `VERSIONINFO` block (product,
  version, commit: the file's Details tab). The icon is drawn by code (`build icon`: a 16 x 16
  grass block, scaled texel for texel to 16, 32, 48 and 256 pixels, PNG images in an .ico;
  a first version, to be redrawn). The window class loads it too (`LoadIconW(module, 1)` for
  `hIcon` and `hIconSm`), or the title bar and taskbar keep the default. Checked in CI by
  reading the resources out of the Windows executable.
- **Versions:** `0.<milestone>.<patch>` (`v0.21.0` when this lands), from git, and the
  commit, passed in with `-define` (`base/version.odin`): on a tagged commit with nothing
  uncommitted, the tag's version; after it, `0.21.0+<commits since>` (semver's build metadata:
  after 0.21.0, where `0.21.0-dev` would sort before it; `0.0.0-dev` before
  any tag). Shown by `--version`, in the log's first line, on the title screen and in the
  server's `status`. The protocol version stays its own.
- **Release names:** a release can have a name for players ("Pre-Alpha 1"): the version
  tag's message (`git tag -a v0.21.0 -m "Pre-Alpha 1"`; a lightweight tag has none). It is
  stamped in too: the title screen says "Voxiverse Pre-Alpha 1 (0.21.0)", and so does the
  Release's title. Files keep the version (sortable, no spaces).
- **Packages** (`build package`: a release build, then the archive in `build/dist/`):
  - Windows x64: `voxiverse-0.21.0-windows-x64.zip`: `voxiverse.exe`, `voxiverse-server.exe`.
    `vulkan-1.dll` comes with every GPU driver. Unsigned: SmartScreen warns about an unknown
    publisher until we pay for code signing (later, documented in the README).
  - Linux x64: `voxiverse-0.21.0-linux-x64.tar.gz` (keeps the executable bit), built on the
    oldest supported runner (Ubuntu 22.04, glibc 2.35) so it runs on older distributions;
    `libvulkan.so.1` comes from the system.
  - macOS (after M1b: the game has no macOS window yet, so no package until then)
    universal (arm64 + x86_64, `lipo`): `Voxiverse.app` in a zip, with the server
    beside it. macOS has no Vulkan of its own: the bundle carries MoltenVK
    (`Contents/Frameworks/libMoltenVK.dylib`, Apache 2.0), loaded directly in place of a
    loader: the one library we ship beside an executable, because there is no other way.
    Ad-hoc signed (Apple Silicon needs a signature); not notarized, so the first launch
    needs right-click Open until we join Apple's developer program (later, documented).
  - Every package holds one folder of its own name (unpacking never scatters files). A
    development build's name carries its commit (`voxiverse-0.21.0+5-1a2b3c4d5e6f-windows-x64.zip`), so builds between releases are told apart.
  - Every package: `README.txt` (running, where saves and settings live, the server's
    options), `LICENSE`, and the fonts' and MoltenVK's licences. Debug symbols go in a
    separate archive per platform (for crash reports), not in the player's package (later:
    a release build has no symbols yet).
- **CI:** the toolchain setup is a local composite action (`.github/actions/setup`), shared
  by the jobs: the Odin release odinup.toml pins, downloaded prebuilt by
  `laytan/setup-odin` (pinned to a commit) rather than odinup's build from source, whose
  LLVM comes from the system and is not in a cache; odinfmt built from the pinned ols
  revision, cached. Jobs are named for what they do and the platform they do it for
  ("Test · Windows x64", "Package · Linux x64"). Every push builds the packages and keeps
  them 30 days as workflow artifacts, each the package file itself, not zipped again (for
  testers: downloading them needs a GitHub login); a `v*` tag builds them, writes
  `SHA256SUMS`, and makes a **draft** GitHub Release with `gh release create --draft`, its
  notes from the milestone's row: nothing is public until it is
  looked at and published by hand, so a tag pushed by mistake never ships. Each package is unpacked on its own OS and
  run from there: Linux reaches a world on the CPU driver; Windows' zip is read as
  Explorer reads it (one folder; no `./` paths, which Explorer shows as an empty zip that
  will not extract), then answers `--version`
  (and its version information is read back) and starts the server; that proves it needs
  nothing beside it.
- **Later, if the repository goes private:** a private repository's release files are not
  downloadable by the public. The packages then go to Cloudflare R2 (S3's API: the `aws`
  command the runners have), `releases/<version>/`, and a manual "publish" workflow writes
  `releases/latest.json`, which a static site's Download button reads. Packaging stays as
  it is; only the publishing step changes.
- **Saves and settings** already live in the user's data directory, so upgrading is
  replacing the folder; a client and server of different protocols say so on joining.
- **Exit check:** as in the table.

## M22: inventory and item icons

- **Inventory mouse tweaks** (after the Mouse Tweaks mod): shift-drag quick-moves every
  slot passed; right-drag puts one in each slot passed; left-drag shares the cursor's
  stack evenly over the slots passed; double-click gathers every stack of that item onto
  the cursor; the wheel over a slot moves one at a time between the hotbar and the rest.
- **Middle click picks the block aimed at:** the hotbar slot holding its item is selected;
  with `items.catalog` a stack of it goes into the hand when none is there. In the
  inventory, middle click on a slot gives a full stack of it (catalog).
- **Square slots, item icons, a smaller hotbar:** names do not fit square slots, so items
  get icons generated at start-up (a block's item: a small three-face cube from its
  textures; tools: pixel sprites by code), in a UI icon atlas; names in tooltips; counts
  in the corner.
- **Built as:** the UI atlas is RGBA8 (glyphs white with coverage as alpha; `ui.add_icon` keeps images that survive an atlas clear); `client/icons.odin` makes 32 px icons (blocks: a cube from the textures, plants flat, the launcher a sprite); new inventory actions `Put`, `Gather`, `Move_One` (shared code, so the server and the prediction agree); `pick` is a binding (middle button); `screen inventory` and `screen game` console commands.
- **Not here:** landing dust and the Windows list (M27).
- **Exit check:** UI tests for each mouse tweak and for pick block; an icon for every item
  (none blank), looked at once in a screenshot of the inventory.
- **Revised after review:** the catalog is a **Creative tab** (only with `items.catalog`), not a column beside the inventory: tabs in the title row, the Inventory tab the 5x5 grid over the hotbar, the Creative tab a search field (`matching_items`: names containing the text) and the catalog grid over the same hotbar, so a stack goes straight into a hotbar slot. While the search has focus, the inventory key and the number and drop keys type instead. `screen inventory creative` opens it.
- **After the first playtest:** icons are 128 px, each pixel the average of 4 x 4 samples (smooth silhouette, each texel still a flat patch), drawn smaller with a linear filter (`Draw_Command.smooth`; the UI atlas is 2048 square); a dropped stack is thrown at 9 blocks/s (was 4).
- **Holding the drop key** (in the game and over an inventory slot) drops one, then repeats after 0.35 s, each gap 0.8 of the last from 0.25 s down to 0.04 s (`drop_repeat`); with Ctrl it still drops the whole stack once.

## M22b: equipment

- **Slots:** `Equipment` beside the inventory: head, chest, legs, feet, offhand (an enum
  `Equip_Slot`; `[Equip_Slot]Stack` in `game.Inventory`, saved with it, in the inventory
  update). Items say which slot they fit (`Item_Info.equip: Maybe(Equip_Slot)`); the
  offhand takes any item. New actions on the same pipeline (shared code, predicted):
  `Equip` (click a slot with the cursor: swaps if the item fits, else refused) and shift-click
  quick-equips an armor item from any slot.
- **Items:** a cap, a tunic, trousers and boots, pixel sprites by code like the launcher.
  No stats, no recipes: the catalog gives them. Worn items show on the avatar (boxes
  coloured in the entity pass, the same for yours and others', sent in the player's
  snapshot so UDP clients see them).
- **The preview:** the real avatar drawn by the entity pass into an off-screen image
  (new `gpu` render-to-texture: a colour image used as target, then sampled like the UI
  atlas, one per frame slot), shown in the overlay's left column, its head and body turning
  toward the cursor within limits. Shown on the Inventory tab only. Needs a validated
  layout transition (validation stays at zero messages).
- **Built as:** `Equip_Slot` (Head..Offhand) and `Armor` (cap, tunic, trousers, boots; item ids from `ARMOR_ITEMS`); `Inventory.equipment`, addressed as slots `EQUIP_BASE ..< TOTAL_SLOTS` by the same actions (a slot takes only what fits it; shift-click equips and unequips); kept in the player file under slots 100+; `Player_Worn` (server kind 32) tells the others, on change and on joining; `avatar_draw` is shared by other players' avatars and the preview; `gpu.Target` is a colour image in the swapchain's format plus depth, drawn into before the frame's own rendering and sampled by the UI as `ui.Image` (`draw_image`); the entity pass takes the world's pipeline for a second set of buffers. `wear` puts on all armor carried.
- **Not here:** protection values, durability, a second preview angle, rings and hands.
- **Exit check:** as in the table.

## M22c: plants need support

- A plant (`Tall_Grass`, `Poppy`, `Dandelion`) needs a block that holds it (grass, dirt, sand
  as today's worldgen puts them on) directly below. When a block changes the server checks
  the block above it (the same place water already reacts to changes), breaks a plant that
  lost its support, and drops its item (tall grass: nothing until M24's seeds). Cactus keeps
  its own rule.
- Drops from a broken plant use the existing dropped-stack path (`spawn_item` with the
  small random hop), so breaking by hand and by losing support give the same result.
- Bulk edits (explosions, selections) go through the same check, batched.
- **Built as:** `game.block_is_plant` / `plant_supported` (grass, dirt, sand); `server/plants.odin`: `plant_check` runs from `set_block` on the block above and `plants_check_box` after a bulk edit; one `block_drop` for hand-breaking and lost support; tall grass has no item drop; placing a plant is refused (server and the client's prediction) where nothing holds it; Earth worldgen clears plants under a structure's floor.
- **Exit check:** as in the table.

## M23: sheep

The one animal is a sheep, so it is called one, and it is the first thing a player does
something to rather than at. Minecraft's sheep is the reference where nothing here says
otherwise.

- **The name:** `Critter` becomes `Sheep` everywhere (code, `summon sheep`, the entities
  file); a save's `critter` is read as `sheep`.
- **Using an entity:** right click on an aimed entity (the client already aims at entities
  for hitting) sends `Use_Entity{id}`; the server checks reach (as for hitting) and calls
  the kind's use procedure. Entity kinds get a table of procedures (think, use) in place of
  the switch in `think`, for the next kinds to fill in. Using an entity takes precedence
  over placing a block behind it.
- **Shearing by hand:** using a sheep with wool drops 1-3 white wool (dropped items, as a
  broken block's) and leaves it shorn. No shears: no tools have durability yet.
- **Regrowing:** a shorn sheep that grazes on grass eats it (the block becomes dirt, as in
  Minecraft) and has its wool back. Grazing is the critter's existing idle behaviour, now
  aimed at a grass block in front of it.
- **The model:** wool is the body's outer box; shorn, the body is the smaller pink-grey
  inner box. The shorn flag goes in the entity's replicated state (protocol bump).
- **White wool:** a block (opaque, breakable, placeable; its own generated texture) and
  its item.
- **Not here:** dyes, colours other than white (M25 brings black), shears.
- **Built as:** `Entity_Kind.Sheep` (was Critter; `summon sheep`, `critter` still read from old saves); client message `Use_Entity` (kind 15) queued like `Attack`, protocol 18; `Entity_Entry.shorn` replicated every tick; `ENTITY_BEHAVIOUR` table of procedures per kind (just `use` so far; the brain stays the sheep's own `think`); shorn is the 8th field of a sheep's line in entities.cfg; a shorn sheep with grass ahead grazes more, and eats it with its head down (10 ticks before the graze ends); `Wool` block, texture, icon, soft sound.
- **Exit check:** server tests: using a sheep drops wool and shears it; a shorn sheep is
  shorn after save and load; grazing regrows the wool and turns the grass to dirt; using a
  shorn sheep does nothing. Over UDP, a second client sees the sheep shorn. A save written
  before this milestone loads with sheep where its critters were.

## M24: random ticks and farming

Blocks that change on their own, with Minecraft's rules, and the first crop on them.

- **Random ticks:** every server tick, each loaded chunk has 3 blocks picked at random
  (Minecraft's default; the rule `rules.random_tick_speed`, 0 turns it off); a picked
  block whose kind has a random tick runs it. Changes go through the one path for block
  changes (edits, light, column tops, sending).
- **Grass:** spreads to dirt next to it (a 3 x 5 x 3 neighbourhood, as Minecraft) when the
  dirt has light 9 or more above it; turns to dirt when an opaque block is on top.
- **A hoe:** the second tool (no durability yet); using it on grass or dirt with air above
  makes farmland.
- **Farmland:** a block a little lower than a full block (15/16); moist when water is within
  4 blocks across on its level or one above, shown darker; dry farmland with nothing
  planted turns back to dirt on a random tick, moist farmland never does. No trampling.
- **Seeds and wheat:** breaking tall grass drops seeds 1 time in 8. Seeds are used on
  farmland to plant wheat: a cross-shaped cutout plant in 8 stages (block states, as water
  keeps its levels), textures generated per stage. On a random tick wheat may grow one
  stage: more likely on moist farmland (Minecraft's chance, simplified to 1 in 3 moist,
  1 in 6 dry). Ripe wheat breaks into 1 wheat and 1-3 seeds; unripe into 1 seed. Wheat on
  a block that is no longer farmland breaks.
- **Not here:** bone meal, other crops, trampling, light needed by crops.
- **Built as:** `rules.random_tick_speed` (3); `server/random_ticks.odin` (picks in each ready, non-uniform chunk; `random_tick` per block; no stored light on the server, so "lit" is open sky above the column's top or a lamp within 6); blocks `Farmland`, `Farmland_Moist`, `Wheat_0..7` (wheat needs farmland: `plant_supported(plant, below)`); items: the `Hoe` tool and `Seeds`/`Wheat` materials (ids from `MATERIAL_ITEMS`; seeds place `Wheat_0`); tilling is an `Edit` of `Farmland` the server checks for a hoe in hand; farmland is not opaque (so neighbours' faces show) and drawn a sixteenth low by a vertex flag in the layer word (`TILLED`/`LOWERED`, `world.vert`); collision stays a full block; `fill` takes farmland and wheat blocks.
- **Exit check:** server tests with a fixed seed: grass spreads into lit dirt and not into
  dark dirt, and dies under stone; farmland is moist by water and dry without, and dry bare
  farmland reverts; wheat ripens within the time its chances imply (a statistical bound
  over many plants); drops by stage; stages and farmland kept through save and load. One
  screenshot of a field in every stage.

## M25: breeding

Sheep have lambs, and lambs inherit. The rule is real genetics kept tiny: two genes, each
with a common dominant form and a rare recessive one.

- **Feeding:** using wheat on an adult sheep uses one wheat and makes it ready to breed for
  30 seconds (hearts over it). Two ready sheep within 8 blocks walk to each other and a
  lamb appears between them; each parent then waits 5 minutes before it can breed again.
- **Lambs:** half size, grow up in 10 minutes (game time while the world is loaded); a lamb
  cannot be shorn or bred; feeding one wheat brings its growing up forward by a tenth.
- **Genes:** each sheep carries two copies of two genes, saved with it:
  - wool: white (dominant) or black (recessive): a black sheep has two black copies and
    drops black wool (a new block, as white);
  - coat: plain (dominant) or spotted (recessive): spotted sheep have dark patches on
    their wool (drawn; their wool drops white or black as their wool gene says).
  A lamb takes one copy of each gene from each parent at random; one copy in a thousand
  flips (a mutation). Sheep found in the wild carry each recessive copy 1 time in 10, so
  about 1 in 100 shows each trait. Related sheep share copies, so breeding within a family
  shows recessive traits more often: nothing extra is coded for that; it follows.
- **Seeing it:** none of the genes is shown in words; only the wool and the spots.
- **Built as:** `game/genetics.odin` (`Genes` as four copies in a bit set; `genes_child`, `genes_wild`); sheep flags (`Shorn, Lamb, Black, Spotted, In_Love`) replace the shorn flag in `Entity_Entry`; sheep have genes, growth, love and wait (saved as four more fields; old lines load); `Use_Entity` with wheat feeds (not used up with items.infinite); ready sheep within 8 blocks walk straight at each other (state `Mate`) and the lower id has the lamb; `Wool_Black` block.
- **Exit check:** genetics tests: two carriers give black lambs 25% of the time (within a
  tolerance over many draws); over generations, sibling lines show more recessive traits
  than random pairing; mutation at its rate. A server test: two fed sheep make a lamb whose
  genes come from them; it grows up on time; genes, age and wait times through save and
  load. Over UDP, a second client sees the lamb small and the colours right.

## M26: events and counters (the foundation for stats, analytics and an RPG)

Re-planned after M25 (see "Why the plan changed" below). One pipeline; everything that
measures play hangs off it, so nothing is counted twice or in a different way.

- **One call:** `event(kind, actor, fields)` in a new package `telemetry/` (depends on
  `base` only). `Event_Kind` is an enum with a table (name, field names and types, version),
  so a kind cannot be emitted with the wrong fields and every kind is documented in one
  place. An event carries: wall time (ms), server tick, session id, actor (the player's id
  in the world, mapped to an anonymous `pid` on the way out), world address, position (block
  coordinates, when it has one), and up to four typed fields (i64, f64, a short string).
  Emitting is a ring-buffer push; nothing blocks the tick. A burst drops the oldest and
  counts what it dropped (itself an event).
- **Consumers** (each a procedure on the drained batch, in the writer thread, never the
  tick): (1) **counters**: a table maps event kinds to dotted counters (`blocks.mined.stone`,
  `distance.walked`, `items.picked.<item>` ... the list in M29's old text, kept below), a
  parent's total is the sum of its children (asked, not stored); (2) **the local log**:
  JSON lines in `<world or server dir>/telemetry/YYYY-MM-DD.jsonl`, a size cap per day;
  (3) M27's upload spool.
- **What is emitted** (server side; it is authoritative): sessions (join, leave, duration,
  client version/OS/GPU/view distance as told by the client's hello, frame-time and network
  summaries), gameplay (edits with block and position, item picked/dropped/used/**crafted
  later**, entities hit/killed, chat counts, commands, teleports and travel, gate dials,
  explosions, sheep fed/sheared/born), progression hooks (nothing yet, but the kind
  table has room: `xp`, `level`, `death` with cause and place), performance (tick time
  p50/p99 and players online each minute, chunk wait, edit confirmation latency, bytes
  sent), and **position samples** (every 10 s per player: where, in which world, doing
  what: heat maps and "where do players die or leave"). Client events the server cannot see
  (overlays opened and how long, settings changed from what to what, launch to playing,
  menu path) ride in a `Telemetry` client message, rate-capped, size-limited and validated;
  singleplayer takes the same path.
- **Counters stored** with the character (`"stats": {...}`, M16) and the world's totals in
  `<world>/stats.json`, written when dirty; only online players in memory.
- **Seeing it:** `stats [player] [filter]` in chat, and a stats overlay (a command and a
  key): scrollable, searchable tree, numbers by unit; the server sends a player's stats
  on request, paged. Others' stats need `info.stats.others`.
- **What an MMO RPG needs from this** (so the kinds are chosen on purpose): item sources and
  sinks (what enters and leaves the economy, from where), time to progress, deaths by cause
  and place, who plays with whom, session length and return rate, content use (which
  structures, biomes, gates are visited), server health (tick, bandwidth, players).
- **Built as:** `telemetry/` (`Kind` + `KIND_INFO`, `Event` with two short strings and three numbers, a 16k ring, a writer thread, `sink_flush` for tests); `server/stats.odin` (`record`, `record_world`, `stat_add`, `stats_tick`, `tick_summary`, `stats_request`, `telemetry_report`); counters kept in the character file (`stats`) and `<world>/stats.json`; protocol 19: `Stats_Request`/`Stats_Page`, `Telemetry_Report`; `client/stats_ui.odin` (key K, `screen stats`), `client/telemetry.odin`. Rules `info.stats` (everyone) and `info.stats.others` (not the default role).
- **Left for later** (not needed to start measuring): `distance.swum`, `time.underwater`, `biomes.visited`, `structures.found`, `stats top`, per-world breakdown inside a character's counters, the sheep-size and settings-changed client events, queueing client reports across a leave.
- **Exit check:** a scripted session (walk, swim, fly, mine, place, pick up, fight, chat,
  teleport, shear, feed) gives exactly the expected counters and the same after save and
  load; the local log has the expected kinds and fields in order; a burst of 100k events
  never stalls the tick (tick p99 within budget) and the drop counter says what was lost;
  the day cap holds; malformed or oversized client reports are refused; many players with
  thousands of counters save and load within budget; UI tests for the overlay's search and
  scrolling; the overlay over UDP shows the server's numbers.

Counter names (from the old M29): `blocks.mined.<block>`, `blocks.placed.<block>`,
`distance.walked` / `flown` / `swum` / `fallen` (cm), `jumps`, `items.picked.<item>`,
`items.dropped.<item>`, `items.used.<item>`, `entities.hit.<kind>`, `entities.killed.<kind>`,
`explosions`, `rockets.fired`, `chat.lines`, `chat.whispers`, `commands.<name>`,
`teleports.<how>`, `time.played`, `time.away`, `time.flying`, `time.underwater` (seconds),
`sessions`, `structures.found.<kind>`, `biomes.visited.<biome>`, `sheep.fed`, `sheep.sheared`,
`sheep.born`.

## M26b: commands, cleaned

Asked for by the player: a slash command is executed on the server, the console's plain words
are client commands; almost every command is a server command; the useful ones of Minecraft
adapted.

- **Console:** a line starting with `/` is sent as the chat sends it (a world is needed); the
  plain commands are the client's own (`screen`, `screenshot`, `singleplayer`, `universe`,
  `join`, `leave`, `quit`, `set`, `vars`, `look`, `net_trace`, ...); a plain word that is a server
  command answers "use /name"; Tab completes slash commands from the names the server sent.
  Gone: `server <command>`, the client's `tp` (now `/tp`), `wear` (now `/wear`).
- **Server (`server/commands_world.odin`):** selectors `@s @p @r` (one) and `@a` (everyone) wherever
  a command takes a player (give, clear, tp, tphere, stats); `~` coordinates (the first of a run
  is x, then y, then z); `/tp <x y z> [yaw pitch]`; `/setblock`; `/time set|add|query`; `/rule`
  (list, show, set); `/kill <kind|all> [radius]`; `/seed`; `/summon [kind] [count]`; `/wear`;
  `/help [command]`; `/locate [biome|structure] <name>` (it was never removed from the server:
  the console's `server locate` was what went); aliases `/tell /w /say /gamerule /teleport`.
- **Not taken from Minecraft, on purpose:** `/gamemode` (permissions and rules say what a player
  may do), `/weather`, `/difficulty`, `/enchant`, `/execute`, `/data`, `/title`, `/playsound`;
  `/clone` and `/xp` and `/effect` wait for what they need (a copy op in the bulk edits;
  M28's progression).

## M27: remote telemetry (a collector and the lake)

So that play data and crash reports reach the developer without anyone copying files.

- **Transport: our own netcode, not HTTP.** TLS from a native-Odin game with no shipped
  libraries is the expensive part of "send data to a server"; the game already has a
  reliable authenticated UDP protocol with account keys. A **collector** is the dedicated
  server binary in another mode (`voxiverse-server --collector`) that accepts only
  `Telemetry_Batch` messages (a signed batch of M26 events, or a report) and writes them;
  it keeps no worlds and does not log source addresses. The data is not secret (no names,
  no chat text, no addresses: players are an anonymous `pid`, a salted hash of the account
  key), so lack of encryption on the wire is accepted for now; if that changes, the cost is
  in the netcode, once, for everything.
- **Uploading:** the client and any server queue events in M26's spool (`telemetry/spool/*.jsonl`
  beside the settings, size and age capped: 50 MB / 14 days), and send batches of at most
  32 KiB every 30 s and at exit, resending until acknowledged; the collector's address is a
  setting with a default; singleplayer and dedicated servers upload too (their own server
  events as `source=server`).
- **Consent:** off until the player has been asked once, on first launch, in the game's own
  words ("Share anonymous play data to help improve Voxiverse?" Yes / No, changeable in
  Options > Profile); No means nothing is queued, nothing is sent (tested). Reports a player
  sends on purpose (below) are always theirs to send.
- **Crashes and reports:** the crash handler writes a report file (version, OS, GPU, the
  last 200 log lines, the stack); the next launch offers to send it (consent or not: it asks
  that once) as a `report` batch; a `report <text>` command and a menu button send the
  current log tail with the player's note.
- **The lake:** the collector writes `lake/dt=YYYY-MM-DD/source=<client|server|report>/<hour>.jsonl`
  (append-only, rotated hourly, never rewritten). That directory *is* the data lake: files in
  partitioned folders, queried in place with DuckDB (`select ... from read_json_auto('lake/**/*.jsonl')`).
  `tools/analytics` is a thin CLI over it with the questions asked most (sessions and
  retention, funnels from launch to playing, events per kind, slowest moments, economy flow,
  deaths and positions as a heat-map PNG) and `tools/lake-sync` pulls a collector's lake to a
  local directory, so the assistant can be told "sync and summarize" instead of being handed
  files.
- **Operations** (documented in `docs/telemetry.md`, not code): run the collector on a small
  VPS under a service manager, rsync or object-store sync of `lake/` for backup, retention
  policy (raw 180 days, then aggregated), how to delete a `pid`'s data on request.
- **Built as:** `collector/` (`collector.odin`: the collector, `upload.odin`: the uploader); protocol 20: `Telemetry_Batch` and `Telemetry_Ack`, spoken after the usual Hello/Challenge/Proof; the uploader reads the server's own day files past a cursor (`upload.cursor`) instead of keeping a second spool, so the log on disk is the spool; the collector's `cursors.txt` makes a batch idempotent across restarts; `server.Config.upload`; settings `share_data`, `share_asked`, `collector`; the consent dialog on the title screen; `report <note>`; `voxiverse-server --collector` and `--telemetry host:port`; `tools/analytics`, `tools/lake-sync.sh`, `docs/telemetry.md`.
- **Left for later:** crash reports sent by themselves (the crash handler already logs; the report is a command today), a client's events when it plays on another's server, encryption on the wire.
- **Exit check:** a test with a collector, two clients and a server: batches arrive, verified
  and written to the right partitions; the collector down for a while, the spool keeps and
  resends everything exactly once; a forged signature, an oversized batch, a flood and an
  unknown kind are refused; consent off sends no packets at all; a crash report round-trips;
  `tools/analytics` summarizes a recorded run.

## M28: character attributes, modifiers and health

The part an RPG stands on, and what the equipment slots (M22b) were waiting for.

- **Derived stats:** one function `derive(character) -> Derived` from base attributes,
  worn and held items' modifiers and timed effects, producing the numbers physics and rules
  read (walk, sprint and jump multipliers, extra jumps, max health, reach); the server and
  the client's prediction call it with the same inputs (the equipment is already replicated
  in the inventory), so prediction stays exact.
- **Item modifiers:** `Item_Info.modifiers` (a short list of kind + amount), so boots can
  make you faster and a charm give a double jump, with no code per item (the backlog's
  "item systems" note, done as data).
- **Health, damage, death:** health and a max, fall damage (from the shared physics),
  explosion damage, death and respawn at the world's spawn (what is dropped is a rule); each
  emits M26 events with cause and place. Health shown as a bar by the hotbar.
- **Progression hook:** a table maps M26 events to experience (`xp` per kind, a level curve
  as data), the level and xp are character state, shown in the stats overlay; no rewards
  yet beyond a number, but the pipeline from "something happened" to "the character grew" is
  there and tested.
- **Exit check:** server and client agree on a tick-by-tick run with a speed modifier and a
  double jump (prediction tests, both ways); fall and explosion damage by the rules' numbers;
  death, respawn and the dropped items; xp and level from a scripted session, kept through
  save and load; the events carry the right causes.

## M29: hardening

Cheap insurance before more is built on the foundation.

- A "still world" test harness (random ticks, wandering sheep and the weather of a world
  off by one switch) used by every test that compares worlds, replacing the per-test rules
  patches, and a repeat-run job in CI that runs the suite twice and fails on a difference
  between runs.
- Benchmark scenarios record the telemetry events' cost (emit, drain, write) and fail on a
  regression, as the other costs do.
- The Windows pass (below) when a Windows machine is at hand.

## M30: blocks that hold things (the chest)

Some blocks need data of their own (a chest's contents, later a sign's text or a
teleporter's name). Minecraft calls these block entities; here they are records kept with
a block.

- **The record:** keyed by the block's position, owned by the server, stored per chunk and
  saved with it (a new section in the region format, versioned). Made when its block is
  placed, removed when it is broken; on load, a record whose block is not there is dropped
  (and logged).
- **To clients:** sent only when needed (a chest's contents when it is opened, then its
  changes while it is open), never with the chunk.
- **The chest:** a block (generated texture; a real chest model later) whose record is a
  server-owned container of 25 slots, the size of the inventory, moved with the existing
  container messages (M14). Using it opens an overlay with the chest above the player's
  inventory. Several players may have it open: each sees the others' moves. Breaking it
  drops everything in it. From the creative catalog for now (there is no crafting).
- **Not here:** double chests, hoppers, locks, signs.
- **Exit check:** a chest filled, saved, quit and loaded holds the same; unloaded and
  reloaded with its chunk, the same; broken, it drops every stack; two players over UDP
  moving items in one chest see each other's moves and end up agreeing with the server; a
  record without its block is dropped on load.

- **As built:** the records are one file per world (`containers.cfg`), not a section of
  the region format, so a record is kept while its chunk is unloaded and checked against its
  block (within half a second) once the chunk loads; the open chest's slots travel inside the
  `Inventory_Update` and requests name them as slots after the equipment (`CHEST_BASE`), so
  the client predicts them with the same code; a block removed by a bulk edit or an explosion
  is found by the sweep, not by the edit. Right-clicking a chest sends `Use_Block` (protocol
  22); the console has `use` for scripts. No permission node yet (anyone may open a chest).

## M31: item ledger and audit

**Why this, now.** The game is heading to an economy (traders, gold, shops, teleporter
fees) and to strangers sharing a server. Both stand on one fact: the number of each item
in the world is never wrong. Today items are made and unmade in about fifteen places
(`block_drop`, `admin_give`, `give_kit`, shearing, death drops, `used_to_place`, wheat
fed, `item_tick` expiry and merging, chests, `players.odin`'s spill on arrival) and
nothing checks that they agree: a duplication bug would show up first as a ruined
economy. M26 measures play, M28 gave characters state; this makes items trustworthy
before anything is priced.

**Design decided.**

- **`server/ledger.odin`**: `Ledger` is a field of `Server` (one per universe, in memory;
  not saved: the audit is relative to a baseline, below). It holds, per item and per
  `Reason`, a `[Item][Reason]i64` count. One call changes it:
  `ledger(s, reason, item, count)`; `count` is positive for a faucet and negative for a
  sink. `Reason` is an enum, append-only, in two groups:
  - Faucets: `Drop_Block` (what a broken block leaves, `block_drop`), `Drop_Mob` (wool),
    `Give` (`admin_give`), `Kit` (`give_kit`), `Catalog` (taking from the creative
    catalog with `items.catalog`), `Spill_Old` (items found with no owner on load).
  - Sinks: `Place` (`used_to_place`), `Use` (fed, planted, tilled), `Clear`
    (`admin_clear`), `Expire` (`item_tick`'s age), `Catalog_Return` (a stack put back
    in the catalog), `Void` (anything the world refuses, e.g. a world with no room).
  - Moves are not ledger entries: pick up, drop, merge, chest in and out, equip, death
    spill and travel only change where an item is, never how many exist. They are
    checked by the audit.
- **Scope entries.** The audit looks at what is in memory: online players' inventories
  (slots, cursor, worn, a chest being looked at), the containers and the item entities
  of loaded worlds. Items entering that scope (a player joins, a world loads) and
  leaving it (leave, unload) are recorded as `Scope_In` / `Scope_Out` by the one
  function each already goes through (`player_joined`/`player_left`,
  `world_loaded`/`world_unloaded`), with the sum they carry. So the balance
  `held_now - held_at_baseline == sum of all entries` holds for any interval.
- **`audit(s) -> Audit_Report`**: sums every holding above, per item; with a baseline
  (`audit_baseline(s)` stores the sums and zeroes the ledger) returns for each item the
  difference between what is held and what the ledger says should be. An empty report is
  a balanced one. Dedicated servers run it every five minutes and on `/audit`
  (permission `admin.audit`), logging a line per unbalanced item at `error` and an
  `Audit_Failed` event; it never fixes anything (a fix would hide the bug).
  Cost is bounded: it walks inventories, container records and the entity list, which
  are all counts already held; a test budgets it at 200 players and 3000 item entities.
- **Telemetry.** Two kinds, `Item_Created` and `Item_Destroyed` (text: item; n0: count;
  n1: the reason's number; counters `items.created.%t` and `items.destroyed.%t`),
  emitted by the one `ledger` call, so faucets and sinks are measured by the same
  stream the economy will be read from. `tools/analytics` gets a `faucets` report:
  per item, created and destroyed by reason over a period.
- **Multiplayer safety, the fuzz.** The audit is only worth what tries to break it. A
  test drives `game.inventory_apply` with random actions (every action kind, indices
  in and out of range, counts negative and huge, cursor held and empty) and checks the
  items conserved or the action refused, and the inventory valid (`inventory_valid`
  already exists). Then two clients over UDP send 2000 random inventory requests each,
  drop, pick up, shift-click into a chest both look at, die mid-way, and travel; the
  audit is balanced throughout. Anything the fuzz finds is fixed in this milestone with
  its own test.
- **Left out:** offline characters on disk (they are out of the scope, so a character
  save/load pair is a `Scope_Out`/`Scope_In` that the test checks matches); persisting
  the ledger across restarts; per-character ledgers; prices; a trade log (trades come
  with traders); `items.infinite` places and breaks without items, so it records
  nothing.

**Order of work.** The ledger and `Reason` with the audit on the existing tests'
scenarios (every one that touches items asserts a balanced audit at its end: this
finds the missing call sites); the telemetry kinds and `faucets`; the `/audit` command
and the periodic run; the fuzz and what it finds.

**Exit check.** `server/ledger_test.odin`: a scripted session through every faucet and
every sink in the lists above ends with a balanced audit and the expected per-reason
counts; a stack duplicated by the test through a hook compiled only into tests is
reported by item and amount, and a stack deleted likewise; travel, a chest, death,
disconnecting with a full inventory and reconnecting, and an unload and reload of a
world leave the audit balanced; the fuzz above (game level, then two clients over
UDP) ends balanced; the audit stays within its budget at 200 players and 3000 item
entities; `telemetry` tests for the two new kinds; the whole suite twice (M29's
repeat run). The table row is filled in with what was done and a line added to the cost
table.

**Done, and where it differs from the design.** `Reason` lives in `game/reason.odin`
(not the server) so the analytics tool names the reasons from the event's number.
`Catalog_Return` is what a second `Take` does to the stack already on the cursor
(the catalog replaces it). A saved character's overflow, spilled on joining, is
`Spill_Old`; the inventory carried in is `Scope_In`. The UDP fuzz sends requests whose
fields are in range (the decoder disconnects the client for any other, which is its
own check); slots and arguments out of range are fuzzed at the game level, where
`inventory_apply` is conserved or refuses. The fuzz found no bug. Not done: persisting
the ledger, per-character ledgers, a `faucets` view per period.

## M32: the audio engine, first half

The original M32 section was the whole engine core; it outgrew one session, so what is
built is here and the rest is M32a in PLAN.md.

- **Voices.** `audio.play` returns a `Voice_Id` (generation in the high 24 bits, slot in the
  low 8), allocated from a game-thread table; the audio thread reports ends on a return ring
  (`poll`, `drain`) and a slot is reused only after its end was read, so a stale handle does
  nothing. Commands: stop (with a fade), fade, gain, pitch and cutoff per voice, all smoothed
  per block. 128 voices, 64 real: ranked each block by priority then audibility, the rest
  virtual (position, fades and loops go on; they resume at the right sample).
- **Sources.** Memory sounds, cubic (Catmull-Rom) resampling, loops with loop points that
  wrap the interpolator's taps (seamless), fade in.
- **Buses.** World, Player, UI under Effects; Effects, Ambience, Music under Master. Gain,
  mute, low-pass, up to four duck rules (trigger bus, threshold, amount, attack, release),
  snapshots crossfaded over a time. `audio/bus.odin`.
- **DSP.** `audio/dsp.odin`: a zero-delay state-variable filter (its response is tested
  against the analytic one), a look-ahead limiter (window minimum averaged over the window,
  program-dependent release; sample peaks stay under -1 dBFS), a BS.1770 K-weighted meter
  with a histogram for integrated loudness (a 997 Hz sine at -20 dBFS reads -20.0 LUFS).
  A NaN or infinity from a sound or the filters never reaches the device; counted.
- **Game.** `client/sounds.odin` plays on the World and Player buses; Options Sound has
  Master, Music, Ambience and Effects; the mixer is on the heap (280 KB); the F3 audio line
  shows real voices and the momentary loudness.
- **Tests.** `audio/mixer_test.odin`, `audio/dsp_test.odin`: plays once, ring flood, handles
  and table, gapless loop (100 loops, and no click when pitched), virtual voices and resume,
  priority, fades, ducking, snapshot, bus gain/mute/cutoff, voice cutoff sweep, NaN guard,
  digital silence, determinism, filter response and stability, limiter, meter.

## M32a: the audio engine, second part

M32a was cut at the session's size: the DSP, the resampler and scheduling are done; the
streams, the capture, the real-time thread and the cost scenario are M32c in PLAN.md.

- **Resampling.** `audio/sinc.odin`: a Kaiser-windowed sinc (beta 10.06, 100 dB, 32 taps a
  side, cut-off at 0.45 of the rate) in a 1024-points-a-sample table read with linear
  interpolation. A step above 1 stretches the kernel by the step (up to 8), so pitched-up
  sounds and sources at a higher rate are filtered before they alias. A voice uses it
  unless its sound is at the mixer's rate and its step is within a semitone of 1 (cubic
  stays there). `resample_sound` converts a sound offline. The sound effects (16 kHz) now
  go through it. Measured: pass-band error under 0.1 dB to 0.38 of the rate, image and
  alias residual under -90 dB.
- **True-peak limiter.** The detector sees seven interpolated points between samples (a
  32-tap Kaiser sinc, beta 6) and treats the highest as the peak, 16 frames after the
  point happened, so `limiter_delay` is the look-ahead plus 16. 16 taps and 4x left
  0.1-0.2 dB over at 0.3-0.4 of the rate; the test measures with an independent 8x, 129-tap
  reconstruction and holds -1 dBTP within 0.05 dB. A step in a sound's start now makes
  the limiter act earlier than a sample-peak one did (an overshoot is a peak).
  `limiter_set_ceiling` backs the listener's safety ceiling.
- **Compressor.** Feed-forward, linked, soft knee, a peak follower (5 ms) ahead of attack
  and release on the gain reduction in dB. Night mode is -24 dB, 4:1, 6 dB knee, +3 dB,
  5 ms and 200 ms. Switching it off sets ratio 1 and lets the reduction release.
- **Reverb.** `audio/space.odin`: 8 lines (29.7-67.3 ms) mixed by a Hadamard matrix scaled to be
  orthogonal, per-line gain from the RT60, a one-pole damping in the loop, six early
  reflections, two decorrelated outputs. RT60 is within 10% at 0.5, 1.5 and 3 s (Schroeder
  integration, -5 to -25 dB); it is exactly linear. `set_reverb`, `set_bus_reverb` (a send
  per bus, ramped per block), the return joins Master before the listener's stage; the
  mixer stops running it when the tail is inaudible and clears it.
- **Scheduling.** `Play.start_frame` is a mixer frame (`clock(m)` reads the frames mixed);
  a voice waits, unmixed and uncounted as virtual, then renders from the exact frame in
  its block, in any block size, also an hour in; a frame already past starts at once and
  counts in `Stats.late`. Commands other than play still take effect at the next mix
  (M32c's capture stamps them).
- **Listener.** `set_listener(Listener{mono, swap, crossfeed, night, ceiling_db})`, applied
  to Master ahead of the limiter, so the ceiling holds for all of it.
- **Tests.** `audio/engine_test.odin`; `test_bus_mute_and_gain` uses quieter tones (its sum
  of two 0.4 steps crossed the true-peak ceiling). The suite passes at both optimization levels.
- **Differs from the design.** No THD+N figure for the reverb: it is linear, the test
  asserts that exactly. 8x instead of 4x oversampling. Not done: moved to M32c.

## M32c: the audio engine, last part

Streams, capture and replay, held commands, the real-time thread, the game's side of the
listener's options and the audio benchmark. The engine core is done; what is left of audio
is M32b (tools) and the milestones on top.

- **Streams.** `audio/stream.odin`. `add_stream(m, ogg_bytes, loop, crossfade, inline)` registers
  an Ogg in memory as a sound id, decoded by miniaudio's `ma_decoder` (it carries its own
  stb_vorbis, so nothing else is linked: `vendor:stb/vorbis` has no library on a
  source-built Odin, as on Linux CI, and its symbols collide with miniaudio's on macOS;
  the first push found both). A stream has one voice at a time (a second `play`
  is dropped and counted in `dropped`). The decoder writes mono samples (the channels
  averaged) at the file's rate into a 65 536-sample ring; the voice reads a window of it
  copied to a stage, through the same cubic or sinc as any sound (pitch, cut-off, buses,
  fades, priority and virtualization all work; a virtual stream voice keeps its place in
  time and lets the ring move on). A loop is the decoder's: the end of the file is
  crossfaded (equal power, at most a quarter of the file) into its start and the ring is
  endless. An underrun (the ring has not what the voice needs) is counted (`Stats.underruns`,
  `stream_underruns`), never skipped over: the voice holds its place, silent for that block.
  When a voice ends the stream restarts for the next (an epoch counter: the decoder resets,
  and the mixer reads nothing until it says so). `inline` streams have no thread: `mix` decodes
  them itself each block, so tests and replays do not depend on timing. A decoder thread
  starved for 200 ms (`stream_pause`) costs nothing (the ring holds 1.3 s); starved for more,
  the underrun is counted and the voice goes on from where it was. `streams_close` joins
  and frees.
- **Capture.** `audio/capture.odin`. The recorder is on the audio thread's side (the game
  preallocates: `capture_start(m, capacity)`), not the game thread's as first written: the
  facts a replay needs, the size of each `mix` call and the frame each command was applied
  on, are the audio thread's. Records are appended without allocating; a full recorder
  counts what it lost (`overflow`) and stops. The file is a header (rate, start clock, bus
  and voice counts, the size of `Play`), a checksum per sound (or per stream's file), then
  the records with each command's raw bytes (good for the build that wrote it, a debugging
  artifact, not a save format). `capture_parse` checks sizes, counts, enums, bus and sound
  indices and handle slots before anything is trusted. `capture_replay` pushes the commands
  with their recorded frames and calls `mix` with the recorded sizes into a fresh mixer with
  the same sounds (streams inline): the samples are bit-identical, tested live against
  replay, through a file, and (checked by hand: the checksum of the test scene is the same)
  from -o:none to -o:aggressive. A capture begun mid-session cannot replay bit for bit (the
  voices playing are state the file lacks): M32b's rolling capture adds a snapshot.
- **Commands on frames.** Every setter takes `at: u64 = 0`, a mixer frame (`clock(m)` plus
  slack). The audio thread moves commands from the ring to a table of 128 waiting ones
  (`held`) and applies, in arrival order, those whose frame has come; a block is cut at the
  next waiting frame, so a command lands on its frame exactly in the middle of a call. One
  that comes after its frame is applied at once and counted in `Stats.late`. A table full of
  waiting commands leaves the rest in the ring until room is made. The mixer now takes commands
  at every block, not only at the start of a call.
- **The real-time thread.** `audio/device.odin`. miniaudio's context is opened with the
  real-time thread priority (its WASAPI backend joins MMCSS's Pro Audio itself); each
  callback flushes denormals (FTZ/DAZ through `_mm_setcsr`, x86-64 only: this toolchain's
  inline assembly is amd64-only, so arm64 relies on the filters' and reverb's own flushing,
  which Apple's chips do not need), times itself (`cb_last_ns`, `cb_max_ns`), and the device's
  clock is compared with the system's over a span that starts five seconds in
  (`drift_ppm`, +17 ppm here over ten seconds); `output_latency` gives the milliseconds from a
  command to the card. The hour-long drift run is for a person to watch (the log line at
  exit carries all of these); the simulated hour of scheduling is M32a's test.
- **The game's side.** Options > Sound gets Mono sound, Swap ears, Night mode, Headphone
  cross-feed and Loudest sound (`ceiling_db`, default -1); `audio_listener` sends them when
  they change. The log line at exit has underruns, late, the callback maximum and the drift.
  The sound effects are converted to the mixer's rate at load (`resample_sound`, as M32a
  said; the device may then differ from 48 kHz, which only costs the cheap path) and
  declared as having nothing above 8 kHz.
- **Speed.** The 64-voice scenario cost 94% of a core at first. Now: `sinc_fast` reads the
  kernel by phase (a 1025-row table, two rows, 8 lanes) for a step of 1 or less; the new
  `set_bandwidth(sound, hz)` declares a sound's highest content, and when
  `bandwidth * step <= 0.4 * the sound's rate` a pitch-up uses the unstretched kernel too
  (a 16 kHz effect pitched to 1.25 has no content near the new Nyquist, so the stretch only
  cost time); a sound with no declared bandwidth keeps the stretch. The true-peak limiter
  skips its FIR while the last 32-39 samples times the FIR's largest gain are under the
  ceiling (the same output: only a loud mix needs it). The voice loop keeps its state in
  locals and runs without bounds checks (every index there is derived from the position
  checks above it). The scenario is 4.4% of this machine's core.
- **`build bench audio`** (`client/benchmark.odin`, `Bench_Kind.Audio`, metric `audio_mix`): no
  world and no GPU work, the mixer offline: 64 looping voices (16 kHz noise-and-tone
  sounds converted at load; a quarter pitched 0.8-1.25, the rest within 3%, a fifth
  low-passed) on World, Player, Ambience and UI, the reverb on two of them, a duck and a looping
  stream on Music; 1000 blocks of 480 frames a repetition, three repetitions. Counts
  (voices, real voices, underruns, late) must not change. A release build fails past 5% of
  a core on the median block; the CI smoke step runs it with the others.
- **Tests.** `audio/stream_test.odin` (equals its decode, inline and threaded; a seamless
  loop and the same period every pass; pitch and stop; one voice; garbage; a starved
  decoder; denormals), `audio/capture_test.odin` (bit-identical replay, damaged and
  mismatched files refused, overflow counted, a command on its frame, many waiting
  commands), `client/effects_spectrum_test.odin` (the break/place/step scene's third-octave
  bands within 1 dB of what M32a's mixer made; the numbers were taken before any of M32c
  changed, and the effects now go through the converted path). The suite passes at
  -o:none and -o:speed; `audio/testdata/tone.ogg` is a 14 KB fixture made with ffmpeg
  (3 s, 440 Hz left and 660 Hz right).
- **Differs from the design.** Streams are mono (the channels averaged): a stereo stream is
  M33's if music needs it (two mono streams started on one frame would do). The recorder is
  on the audio thread's side. The golden checksum of the test scene is held only on Linux
  x86-64 (the maths library is part of it); elsewhere the test compares live with replay.
  The latency in the overlay is M32b's (the numbers are in `Stats` and `output_latency`).
- **Found by CI.** The mixer (843 KB with the phase table) was built by `m^ = {rate = rate}`,
  which made a temporary on the stack: a Windows thread has 1 MB, so every audio test died
  without a word there (Linux threads have 8 MB). `mixer_init` and `reverb_init` now zero in
  place. Checked locally with `ulimit -s 1024`: the previous commit's tests die, these pass.
  Keep structs of this size off the stack.

## M32b: audio tools (capture, dump, baselines)

The audio side of what the network has in `netdump`, `replay` and the Wireshark
dissector, the GPU has in RenderDoc and the validation layers, and everything has in
`build bench`: so a bug is a file to open, and quality cannot drift without a test
failing.

- **`build audiodump <capture>`** (`tools/audiodump`, reading M32's capture): prints a
  timeline (frame, time, command, sound name, bus, gain, pitch, priority) and the engine's
  decisions: which voices were virtualized, stolen or dropped and why (priority, audibility,
  ring full, instance limit); summaries per sound and per bus (plays, peak voices);
  `--bus <name> --wav out.wav` writes any bus's audio (or the master) to a file;
  `--spectrogram <bus>` writes a PNG; `--report` prints per-bus integrated and short-term
  loudness (BS.1770), loudness range, true peak, correlation, clipping and limiter
  activity, and the real-time counters. Filters: `--from/--to` seconds, `--sound`, `--bus`.
  Like `netdump`, it works on a capture from a player's machine (a `report` command's
  attachment can include the last capture ring).
- **A rolling capture** (M32c built the recorder, `audio/capture.odin`, on the audio
  thread's side; a capture begun mid-session cannot replay bit for bit because the voices
  then playing are state the file lacks, so this adds a snapshot of the mixer's state at
  the ring's start): the recorder can keep the last 60 seconds in memory (a ring) and
  write it on a key press, on an underrun or with a crash report, so the moment before a
  glitch is saved without having asked for it.
- **The freeze-and-solo inspector (dev builds, overlay):** a key freezes the last half
  second of mixing; the overlay lists the voices then (sound, bus, gain, pitch, state,
  priority) with per-bus meters and spectrum; clicking a voice or bus solos or mutes it
  and loops the frozen block through the real mix so it can be listened to alone (the
  RenderDoc event list, for ears). Occlusion rays and the reverb's room are drawn as debug
  lines when M35 lands (the hooks are here). Off in release builds. The overlay also shows
  `output_latency`, the callback's `cb_last_ns`/`cb_max_ns`, `underruns`, `late` and the
  clock's `drift_ppm` (all in `audio.Stats` since M32c).
- **Quality baselines** (`tools/audio_baseline`, files in `assets/baselines/audio/`):
  scenarios rendered offline from scripted event lists with fixed seeds: a block-break
  burst (many materials at once), a walk from a field into a cave and out, a title to
  world transition with music, a 64-voice stress. Each stores per-bus numbers: integrated
  loudness, true peak, loudness range, energy in third-octave bands, decay times of marked
  sounds, and a checksum of the samples. CI renders them and compares: loudness within
  0.5 LU, peaks and bands within 1 dB, checksums exact on the same OS and optimization level
  (the numbers are what holds across OSes). `build audio --accept <scenario>` rewrites a
  baseline on purpose and the diff is reviewed like code; a sound retuned without
  accepting its baseline fails CI. Later milestones add their scenarios (M34's music,
  M35's space, M36's effects, M37's tour).
- **Cost baselines:** the `audio` scenario in `build bench` (M19's system): mix time per
  block (average, p50, p99, max), voices real and virtual, stream decode time, underruns
  and late callbacks, under the fixed conditions of the 64-voice stress with music and the
  reverb on; results in `build/benchmarks/`; `compare` and the CI step fail past a margin
  like the other scenarios. A Spall trace of the audio thread (`build trace` exists)
  shows the blocks.
- **Real-time health in CI:** a smoke run of the game on the CPU driver mixing into the
  null device for 30 seconds asserts zero underruns, zero NaN, zero dropped commands and
  the callback's worst case under its budget.
- **The null device and a file device:** `audio.device_open` can open a device that pulls
  blocks at real rate without a sound card, and one that writes a WAV as fast as it can
  (what `build audio` and the baselines use), so no test depends on hardware.
- **Tests:** a capture round-trips (written, read, replayed, identical); the dump's
  timeline names a voice stolen in a built case and a ring-full drop; the loudness report
  matches M32's meter on a known signal; a changed gain in a baseline scenario fails the
  comparison and the accept command makes it pass; the rolling capture holds exactly the
  last N seconds; the cost scenario runs and its comparison fails for a deliberately slowed
  mix.
- **Exit check:** the four baselines and the cost scenario pass in CI on all three OSes
  (checksums per OS); a built-in bug (a mis-scaled gain) shows as a failed baseline with
  the dump naming the sound; the inspector seen once in a screenshot.

**What was built.** `audio/analyze.odin`: an `Analysis` that the mixer calls after every
block through `Mixer.probe` (nil in the game; the hook is called from the audio thread's
`mix_block`, so analysis allocates only when attached). It keeps the audio of the buses asked
for, runs a BS.1770 meter on every bus, and notes each voice's story (started, virtualized by
rank or inaudible, restored, ended, stopped, dropped: a play that did nothing, found by a Done
voice that never had a step). Loudness range is taken from the histogram of 400 ms blocks,
not 3 s ones, and the loudest figure is the momentary one (no short-term meter yet). True peak
uses the limiter's own 8x filter, run only where a neighbourhood could beat the sample peak.
Capture version 2 adds each sound's name (`set_sound_name`, 24 bytes; the game's sounds are
`Stone.Break.0` and so on) and the live mixer's dropped count. `tools/audiodump` replays a
capture through a fresh mixer with `client.sounds_init`; a capture whose sound table differs
(streams, another build) still prints its timeline and says why the rest is missing.
`audio/baseline.odin` and `client/audio_baseline_test.odin`: four scripted scenarios
(burst, cave_walk, title_to_world, stress), numbers per bus compared within 0.5 LU, 1 dB and
25% (decay), and a checksum per OS and optimization level (`Linux.Minimal` is what
`build test` produces); `build audio --accept <scenario|all>` rewrites, `--wav <dir>` writes a
WAV and a capture per scenario. The cost baseline is M32c's `audio` bench scenario, which
`bench compare` already runs. Not built (M32d): the rolling capture, the inspector,
spectrograms, the null and file devices, the 30 s smoke run.

## M32d: audio tools, the rest (rolling capture, devices, smoke run)

What M32b left, less the inspector and the crash and checksum parts (M32e).

- **The rolling capture** (`audio/capture.odin`). `capture_start_ring` keeps the last 2^16
  records in a ring and, every 15 s (`CAPTURE_SNAP_SECONDS`), a `Mixer_State` taken on the
  audio thread at the start of a mix call: voices, buses, ducks, limiter, meter, reverb,
  compressor, listener, cross-feed, clock. Six slots, used in turn; a dump starts from the
  oldest state whose records the ring still holds (with a margin the audio thread may be
  overwriting) and is not the slot the next one would take. `capture_ring_save` detaches the
  recorder for 5 ms, writes, and reattaches with the next state forced (the mixes of the
  gap are not in the file, so older states are not used again). File version 3: the header
  names the state's size, hash and the stream voices it had (a decoder's ring is not part
  of it: those replay silent, with a warning); `capture_parse` checks the hash and the
  indices a replay would use; `capture_replay` restores the state, then pushes the records.
  Commands held for their frame are not in the state: each is recorded when applied. Drops
  are records of their own (`DROPPED n commands` in the timeline: written on the call after
  the ring found itself full, not the instant). Tested: a ring that wrapped many times,
  begun long before the dump, replays from the middle to the very samples played; a second
  save after the first does too; a damaged state is refused.
- **Devices without a card** (`audio/device.odin`). `device_open_null` is a thread that asks
  for a 10 ms block by the wall clock through the same `pump` the card's callback uses (so
  the stats, timing and drift are measured the same way); `device_open_file` mixes nothing
  by itself: `device_render(frames)` mixes that many as fast as it can into memory (at most
  300 s) and the WAV is written at close. (Decision: as fast as it can means the caller's
  clock, not a free-running thread: a thread would race ahead of the game it listens to.)
  `audio/wav.odin`'s `wav_write` replaces `audiodump`'s own.
- **Spectrograms** (`audio/spectrogram.odin`): 4096-point Hann windows, a log frequency axis
  from 40 Hz to 20 kHz, dB below full scale as colour; `build audiodump <capture>
  -bus:Music -spectrogram:out.png`.
- **In the game** (`client/audio_debug.odin`): the ring runs from the start (not in a
  benchmark); F9 and the `audio_capture` command write `captures/audio-<n>.vxac`, and so
  does an underrun (once in 30 s, at most 8 files a run).
- **`--check audio`** (`client/audio_check.odin`; `--null-audio` is the flag under it): the
  game mixes into the null device for 30 s while sound events are played round the camera
  every 60 ms; fails on an underrun, non-finite sample, dropped or late command, a callback
  over 30 ms (three blocks: a card buffers two or three periods; one preempted callback on
  a software-rasterizer runner was seen at 9.5 ms, so one block would flake), a mix that is
  not the wall clock's length, or a ring that writes nothing. A Linux CI step runs it. The
  checks' settings are silent: the check sets the volume itself, or every voice is virtual
  (this was seen in the first run and is why).
- **Not done (M32e):** the freeze-and-solo inspector, the crash report and `report`
  attachments of the ring, the macOS and Windows checksums (they need those CI runs).

