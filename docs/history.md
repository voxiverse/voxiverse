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

## M32e: audio tools, what is left (inspector, crash and report attachment)

- **The inspector** (`audio/inspect.odin`, `client/audio_inspector.odin`; F8, dev builds,
  the `Audio_Inspector` overlay: takes the mouse, the game runs on). A freeze takes the
  ring's *newest* window (`capture_ring_bytes(m, newest = true)`: at most one state interval,
  15 s, so a replay costs a fraction of a second, not the 75 s the oldest state may cover),
  replays it through a mixer of its own with the live mixer's sounds, and keeps the voices
  (from the window's plays and state) with the engine's last decision about each, every
  bus's peak, a spectrum of Master and the last half second of Master. The live mixer's
  output is replaced by that loop through a `Monitor` (an atomic pointer read at the end of
  `mix`; the live mix goes on and the ring goes on recording): not muting buses, which
  would have muted the loop too. The panel: device counters (latency, callback, underruns,
  late, drift), the buses with a level bar and a button, the spectrum, the frozen voices
  newest first with a button each. The button cycles solo, mute, off; a pick rewrites the
  window's commands (plays and voice commands of what is not kept, the state's voices) and
  replays it. Streams are never replayed (their plays and voices are dropped; a second
  mixer must not pull from the live mixer's streams). Buses form a tree (World feeds
  Effects), so soloing World also shows level on Effects: that is right, not a bug.
  Pitfalls met: a `defer` in an `if` block runs at its end (a freed state, a hung replay);
  `--check audio` opens the inspector 12 s in, solos World, screenshots it as
  `audio_inspector` and fails if nothing froze, the window has no voices or the replay fails.
  Tests in `audio/inspect_test.odin`.
- **A crash leaves the window beside its report.** While any voice plays, the game saves the
  ring every 30 s to `captures/audio-last.vxac` (`audio_ring_autosave`) and tells the crash
  handler (`base.debug_attach`: a path in a fixed buffer, since the handler may not
  allocate); the crash log then says `crash attached file=... age_s=N`. Seen with a
  deliberate `crash` in a dev build: the file is there and `build audiodump` reads it.
- **`report`** names the last ring file written (`audio window:` line) and copies it beside
  the report, in `telemetry/reports/` (at most 4 MB; a larger one is only named). Decision
  that departs from the plan's: the uploader sends text only (`MAX_BATCH_TEXT`), so the
  `.vxac` waits there and is not uploaded; sending binaries needs a protocol change and is
  not worth one for this.
- **Checksums:** `test_audio_baselines` now logs `audio baseline <scenario> checksum <key>
  <value>` for each scenario, so CI's macOS and Windows test logs carry them. Committing
  them needs a CI run of this commit: the milestone M32f.

### M32f: the checksums of macOS and Windows

M32e makes `test_audio_baselines` log every scenario's checksum (`audio baseline <scenario>
checksum <key> <value>`). After this commit's CI run (the Test step's log, macOS and Windows
jobs): add each line as `checksum <key> <value>` to `assets/baselines/audio/<scenario>.txt`
(keys `Darwin.Minimal` and `Windows.Minimal`; the text format is the existing one), run
`build audio` to see it pass on Linux, and commit. If the macOS or Windows run's samples
differ from run to run on one OS, that is a finding: record it in the section instead and
leave that OS compared by numbers only. Exit check: the next CI run passes with the
checksums in.

- **Result:** the checksums were stable over two CI runs on each OS and are in the four baselines. burst and cave_walk match on all three OSes; title_to_world and stress differ per OS (different libm/float paths), so each OS keeps its own checksum.

### M38: determinism (one numbers policy, a state hash, a desync detector, a cross-OS job)

**Why.** Everything in the foundation arc stands on the simulation being a function of
its inputs: the journal replays onto a snapshot (M40), a rollback must land on an exact
hash (M40), script state is snapshotted and restored (M42), a dry run judges a pack by
running it (M45), and a client on macOS must predict what a Linux server decides. Today
that holds by luck, and the survey for this section found where it does not:

- `game/physics.odin` moves the player with `math.sin`, `math.cos` and `math.exp`, and
  `game/entity.odin` with `math.exp`. In Odin's `core:math` these four (with `pow`, `tan`
  and `fmuladd`) are LLVM intrinsics: calls into each OS's libm (glibc, Apple's, the UCRT),
  which round differently, and which `-o:speed` may fold at compile time with yet another
  result. Prediction and the server run the same code on different machines. The server's
  own uses (`server/entities.odin`, `items.odin`, `selection.odin`) decide sheep turns,
  thrown drops and spawn places. `worldgen/gates.odin` squares with `math.pow`.
- State randomness is `core:math/rand`'s default generator: ChaCha8 with 1 KiB of state
  per stream (`World.tick_rng`, `Entities.rng`), a stream that is the toolchain's to
  change, and `@r` in `server/commands_world.odin` draws from the unseeded
  `context.random_generator`.
- Odin seeds each map's hash from the address of its table
  (`base:runtime map_seed_from_map_data`), so iteration order differs from run to run and
  between OSes. `random_ticks` walks `w.chunks.by_pos` and draws the RNG chunk by chunk:
  which blocks grow depends on where the map was allocated. `unload_unwanted` and `regen`
  free chunks in map order, which decides pool slot reuse. `changes_flush` sends
  `Block_Changed`, whole chunks and columns in map order, and `replicate` sends
  `Entity_Despawn` in the order of `c.known`.
- Chunk jobs finish in thread order and arrive a timing-dependent number of ticks later,
  the server is paced by the wall clock, and nothing hashes or compares state at all.
  The one cross-OS check is worldgen's golden (`test_earth_same_everywhere`), at one
  optimization level.

**Design.**

*The policy* is `docs/determinism.md` (the decisions above in full, with the reason for
each rule), short enough to read before touching shared code:

1. State floats are IEEE `f32`/`f64` with default rounding. No `math.fmuladd`, no
   fast-math. Odin does not contract `a*b + c` (checked while writing this section: an
   arm64 `-o:speed` build emits no `fmadd`); the cross-OS job is what guards it.
2. Transcendentals in state come from `base/numbers.odin`: `sin`, `cos`, `sincos` (on
   `core:math.sincos_f64`, Odin code ported from Cephes, no intrinsic) and `exp` (our own
   port of FreeBSD's `e_exp.c`, the same source `core:math.ln` came from), each for `f32`
   (computed in `f64`, rounded once) and `f64`. Allowed from `core:math`: `sqrt`, `abs`,
   `min`, `max`, `clamp`, `floor`, `ceil`, `trunc`, `round`, `mod`, `atan2`, `asin`, `acos`,
   `ln`, `smoothstep`, `lerp` (correctly rounded, or plain Odin code). Integer powers are
   multiplications.
3. Randomness in state is `base.Rng` (`base/rng.odin`): xoshiro256** seeded through
   splitmix64, 32 bytes of state; `rng_make(seed: u64)`, `rng_u64`, `rng_u32`,
   `rng_int_max(n)` and `rng_int_range(lo, hi)` (Lemire's multiply-shift with rejection),
   `rng_f32` (top 24 bits × 2^-24), `rng_f64` (top 53 bits × 2^-53), `rng_f32_range`,
   `rng_f64_range` (`lo + (hi - lo) * u`, that order). Each stream is seeded from its
   world's seed XOR a named constant (the ones in use today stay). `crypto` randomness
   (nonces, keys) is never state.
4. Nothing that reaches state or the wire depends on map iteration order: walk a pool in
   slot order, or the keys sorted (`base.keys_sorted(m, less, allocator)`, with
   `game.chunk_pos_less` and `game.block_pos_less`: y, then z, then x, as `changes_flush`
   already sorts its batches). Maps stay for lookup.
5. No wall clock in state: time is ticks. The wall clock paces the live server and times
   stats and telemetry. Real-time bans and the damaged-file suffix are not state.
6. A float is cast to an integer only when it is known to be in range (positions are,
   inside the world's bounds). Out-of-range and NaN casts differ between x64 and arm64.
7. A toolchain bump (`odinup.toml`) can change `core:math`'s Odin code. The cross-OS job
   and worldgen's golden run on every commit, so a bump that changes state fails CI on
   the bump itself.

*The lint*, in `build check` (`tools/build/determinism.odin`): every non-test `.odin`
file in `game/`, `server/` and `worldgen/` is searched for `math.sin`, `math.cos`,
`math.tan`, `math.pow`, `math.exp`, `math.fmuladd`, `math.sinh`, `math.cosh`, `math.tanh`,
`math.gamma`, `math.lgamma`, `math.erf`, `math.erfc` and `rand.`. A hit fails with
`file:line: <call> in shared code: use base.<name> (docs/determinism.md)`. A line that is
not state says so with a trailing `// numbers: <why>`, and the lint takes that as the
exception: `prediction_decay`'s visual offset, the pipe's simulated jitter in
`game/transport.odin`. Map order cannot be linted by text. It is caught by the
side-by-side run below, whose two servers' maps sit at different addresses.

*The fixes* (step 2): `random_ticks` walks the chunk pool in slot order. `unload_unwanted`
and `regen` sort their drop lists before unloading. `changes_flush` sorts
`ch.blocks`, `ch.chunks`, `busy` and `ch.columns` before sending. `replicate` sorts `gone`.
`@r` draws from a world stream (`World.command_rng`, seed XOR `0xc0de_0001`). Physics, entity
movement, sheep, thrown drops, selection rays and gates use the policy's functions.
Every `rand.` in `server/` and `game/genetics.odin` (`genes_wild` takes `^base.Rng`) moves
to `base.Rng`. Tests that pinned a number from the old stream or the old libm (sheep,
breeding, drops, physics) get their expected values derived again from the new code, not
loosened. Worldgen's golden must not move (gates' `pow(x, 2)` becomes `x * x`, exact either
way).

*The stepped server* (`server/stepped.odin`): `Config.stepped` starts no thread.
`step(s) -> State_Hash` runs one tick on the caller's thread, frees the temp allocator and
returns the tick's hash. `base.Jobs` with zero workers runs each job inside `jobs_submit`
(today it asserts a worker), and a stepped server makes its chunk jobs that way: a
requested chunk is generated during the tick that asked for it and collected at the
start of the next, in request order. Autosave counts ticks
(`AUTOSAVE_SECONDS * TICK_RATE` since the last save) on every server, live or stepped.
In-process input comes through the local pipe with no simulated conditions, so what the
harness sends before `step` is handled in that tick. One local player: the server takes
one pipe, and several deterministic players wait for M50's bot harness.

*The state hash* has two halves.

- `game/state_hash.odin`, shared: a `Hasher` (u64 words, little-endian, each mixed as
  `h = (h ~ w) * 0x0000_0100_0000_01b3`, finished with splitmix64's finalizer) and one
  reflective walker over `core:reflect` with two outputs. `hash_value(h, v: any)` folds a
  value in. `dump_value(b, path, v: any)` writes one line per leaf:
  `entities[3].body.velocity.x = 0x3f8ccccd (1.1)`. Integers, enums, bools and bit_sets are
  their bytes. Floats are their bits (so -0 is not 0). Arrays, structs and unions (tag,
  then value) are walked. Slices, dynamic arrays and strings are a length, then their
  elements. Arrays of plain integers (chunk blocks) are hashed as bytes in one go. A map, a
  pointer or a procedure panics with the field's path: keyed state is hashed by hand, in
  sorted order. A field added later is hashed without anyone remembering to.
- `server/state_hash.odin`: `Hash_Section :: enum u8 {Clock, Rules, Players, Inventories,
  Entities, Chunks, Liquids, Containers, Gates, Random, Ledger}` and `State_Hash :: struct
  {tick: u64, root: u64, sections: [Hash_Section]u64}`. Per world, in `s.worlds` order:
  Clock is the clock and tick. Rules is `w.rules`. Players is each playing client in index
  order (world address, `player`, `look`, `health`, `max_health`, `teleported`). Inventories
  is each one's `inventory`. Entities is `next_id` and `entities.list` in order. Chunks is
  each chunk changed this tick, sorted, as position and blocks. Liquids is the update heap
  as stored. Containers is sorted by position. Gates is the `gates` list. Random is the RNG
  states. Ledger is entries and baseline, sorted by item and reason. The root chains:
  `root(t) = mix(root(t-1), t, sections(t))`, so a divergence stays visible from its first
  tick on. `world_hash(w)` hashes every loaded chunk, sorted, for checkpoints.
  `state_dump(s, sections, b)` writes the dump lines of the sections asked for. Chunks are
  dumped as one line per chunk, `chunks[(x, y, z)] = <hash>`, so a dump names the chunk.
  Hashing runs only on stepped servers: a live tick costs nothing more.
- `Config.perturb: Perturb {tick: u64, what: enum {None, Entity_Yaw, Player_Velocity}}`
  (tests only, refused unless `stepped`). At that tick's start it adds one ulp to the first
  entity's `yaw` or the first player's `velocity.x`. This is the deliberately introduced
  nondeterminism.

*The scripted session* (`server/determinism_test.odin`). A stepped server: seed 38, the
Earth generator, view radius 4, height 2, no save directory, default rules, natural sheep
on. A mirror client sits on the pipe. It is latency_test's predicting client grown up: it
answers the challenge with a fixed key seed, keeps the chunks it is sent, predicts with
`game.prediction_tick` and reconciles. The script is a pure function of the tick:

- every tick: a sine-steered walk with a jump every 35 ticks;
- sprinting over ticks 1000-2000, sneaking over 2000-2300, flying over 4000-5000;
- breaking the block looked at and placing stone, every 40 ticks over 300-3900;
- `/summon` four sheep at 600, `/give` shears at 1200 and shearing the nearest at 1300;
- a water source by `/setblock` at 2500;
- a `/fill`ed field of farmland and wheat at 3000, for random ticks;
- a rocket into the ground ahead at 6000 (bulk edit, drops, knockback);
- `/time` at 7000, a `/gamerule` change at 7500;
- a stack dropped at 8000, a chest placed and filled at 9000.

`DETERMINISM_TICKS :: #config(VX_DETERMINISM_TICKS, 2000)`: the everyday suite runs 2 000
ticks, `build determinism` runs 10 000. The script stops at the tick count. The test runs
two such sessions **side by side**, A and B, each with its own mirror, stepped A then B
each tick. It asserts that their maps' tables sit at different addresses (so map order
would differ) and compares roots every tick. At the first difference it dumps the
differing sections of both and returns a `Divergence {tick, section, a, b: string}` with
the first differing dump line. The run fails with
`diverged at tick 5000: entities: entities[0].yaw = 0x3f8ccccd (1.1) vs 0x3f8ccccc (1.1)`.
Across the run the test also checks:

- every section except Containers and Gates took more than one value (the script really
  exercises them);
- the mirror's predicted state equals the server's at every `Player_Update`, with no
  corrections (no latency);
- at each checkpoint (every 1 000 ticks and the last), `world_hash` of the chunks the
  mirror holds, hashed by the mirror from its own copies, equals the server's for the same
  chunks.

*The log and the cross-OS job.* With `-define:VX_DETERMINISM_LOG=<path>`, session A writes
`build/determinism/<ODIN_OS>.<optimization>.txt`:

- a header: `determinism 1 seed=38 ticks=10000 os=Linux opt=Minimal odin=<ODIN_VERSION>`;
- a line per tick: `<tick> <root> clock=<h> rules=<h> ...`;
- at each checkpoint, `dump <tick>`, the full dump, and `world <hash>`;
- `end <root>`.

That is about 2.5 MB of text. `build determinism` (`tools/build/main.odin`) runs the test at
`-o:minimal` and at `-o:speed` with `VX_DETERMINISM_TICKS=10000` and a log each, then
compares the two. `build determinism --compare <dir>` compares every log in a directory
against the first in name order. It checks that the headers agree except for os and opt,
then names, per file, the first differing tick, its differing sections, and the first
differing line of the next checkpoint's dump. It exits non-zero on any difference. In CI,
each Test job gets a step `build determinism` and uploads `build/determinism/` as
`determinism-<os>`. A new job, `determinism` (ubuntu, `needs: build`, the setup action
without dev), downloads the three, runs `build determinism --compare`, and is green only
when all six logs agree.

*The desync detector.* `Prediction_Check {sequence: u32, fields: [Player_Field]u32}` is
`Client_Kind.Prediction_Check` (20), `PROTOCOL_VERSION` 23. `Player_Field` names `position`,
`velocity`, `on_ground`, `flying`, `crouched`, `jump_held` and `air_jumps`, each a 32-bit fold
of `hash_value` over that field.

- The client (`client/session.odin`): every `DESYNC_CHECK_INPUTS` (30) inputs, it hashes
  the state it just predicted, by field, and sends the check after that input. It sends
  nothing while any of the 27 chunks around the player is missing.
- The server (`server/players.odin`): it keeps a client's check until it applies that
  input, then hashes its own state the same way. It judges the check only if the player
  has been **quiet** for `DESYNC_QUIET_TICKS` (60, two seconds, longer than any round trip
  it should judge). Quiet means `c.disturbed` (the last tick something besides the
  player's own inputs could have changed its movement) is that far back.
- `c.disturbed` is set by `disturb(c)`. It is called by every write to `c.player` outside
  `simulate_player`: landing, spawn, saved state, knockback in `entities.odin`, the
  admin's spectating. It is also called by a teleport, by a rules or mods change, by an
  input refused or dropped, and by `changes_flush` for any changed block within 4 blocks of
  the player's box.
- A mismatch is logged as
  `desync player=<name> sequence=<n> fields=velocity,position`. It is counted in
  `Stats.desyncs`, judged and skipped checks in `Stats.checks_judged` and
  `Stats.checks_skipped`, and all three go in the minute's tick summary.
- The Wireshark dissector learns the message, and `check.lua` keeps decoding every packet.

**The order of the steps** (each leaves the suite passing):

1. `docs/determinism.md`, `base/numbers.odin`, `base/rng.odin` and their tests. Then the
   lint, which fails on today's code, and the replacements until it passes.
2. The order fixes (sorted keys, pool order, `@r`).
3. Zero-worker jobs, the stepped server, the state hash and dump, `Perturb`.
4. The scripted session and its tests, the log, `build determinism` and `--compare`.
5. The CI step and job.
6. The desync detector, its message and the dissector.

If the session must split, the remainder is M38b: step 6, with its two tests as the exit
check.

**Left out:**

- Saving and loading mid-session with the hash intact (RNG state is not saved yet: M49
  migrates saves).
- More than one deterministic player (M50's bots).
- Replay of recorded traces by tick (`tools/replay` stays timed; replay by tick comes with
  M40's journal).
- A hash log on live servers.
- Desync dumps sent back to the client, and desyncs shown in F3.
- Lockstep determinism of the live server.
- Cross-OS identity of audio, which stays in the replayable tier.
- Linting map iteration by type.

**Tests:**

- `base/numbers_test.odin`: `sin`, `cos` and `exp` within 1 ulp of correctly rounded values
  over a table of 64 inputs (including large arguments, ±0, subnormals, ±Inf and NaN). A
  golden table of their exact bits, recorded on Linux, runs on all three OSes as an
  ordinary test.
- `base/rng_test.odin`:
  - the first eight `rng_u64` of seed 1 against fixed values;
  - `rng_int_max` uniform within chi-square bounds over 10^5 draws;
  - ranges inclusive and exclusive as named;
  - a state copy continues the same stream.
- `tools/build/determinism_test.odin`, the lint: a file with `math.sin` fails with its line,
  the same line with `// numbers:` passes, and the shared tree passes.
- `game/state_hash_test.odin`:
  - a struct's hash changes with any one field;
  - -0 and 0 differ;
  - padding never enters (two values equal field by field, with different padding bytes,
    hash alike);
  - a map field panics with its path;
  - the dump lines name nested paths.
- `server/determinism_test.odin`:
  - `test_determinism_session`: the side-by-side run and its checks above;
  - `test_divergence_named`: 600 ticks with B perturbed at tick 500, once per kind. The
    report names tick 500, the right section and the field path (`entities[0].yaw`,
    `players[0].player.velocity.x`).
  - `test_stepped_jobs_in_order`: two stepped servers hold the same pool slots for the
    same chunks after streaming and unloading.
- `server/latency_test.odin`, extended:
  - `test_no_desync_with_latency`: the M4 script at 200 ms and jitter, with checks. Zero
    desyncs, and at least half the checks judged, so the quiet rule is not vacuous.
  - `test_desync_caught`: the same run, with the client nudging its predicted
    `velocity.x` by one ulp after every prediction. Desyncs are reported, naming
    `velocity`.
- `game/protocol_test.odin`: `Prediction_Check` round-trips.

**Exit check:**

- `build determinism` passes on Linux: both optimization levels give identical logs of the
  10 000-tick session.
- `test_divergence_named` names the perturbed field for both kinds.
- The two desync tests pass.
- The whole suite and `build check`, including the lint, pass.
- The CI run of the commit has the `determinism` job green: the six logs, three OSes by two
  optimization levels, agree.

**Check by hand:**

- A LAN game between a Linux host and a Windows or macOS client: walk, swim, fly and build
  for ten minutes. Expect no `desync` line in the host's log, and `checks_judged` above zero
  in its tick summary.

- **Result** (what differs from the section, and what was found):
  - The numbers golden is one FNV hash over the bits of `sin`, `cos`, `exp` of 64 inputs
    (recorded on Linux), not a table of bits; accuracy is checked against libm (2 ulp for
    sine and cosine, 1 for exp).
  - `Config.perturb` puts its ulp into the state the tick *leaves* (not its start): a one-ulp
    velocity is otherwise absorbed by the next tick's arithmetic. Section paths of 2-4 element
    arrays read `.x .y .z .w` (`players[0].player.velocity.x`).
  - `base.keys_sorted` is generic and `core:slice`'s `sort_by` is aliased in `base` so
    `-vet` does not call the import unused (a generic body is checked only when used).
  - The mirror counts a correction as a failure except in the 30 ticks after the rocket
    (6000): its blast moves the player, a correction by design.
  - `containers_tick`'s drop list, `entity_gone`'s despawn list and `regen`/`unload_unwanted`
    are sorted too (the section named only some).
  - Desync counts go in the minute's tick summary *log line* (the telemetry event has three
    numbers only): `desyncs`, `checks_judged`, `checks_skipped`; `Stats` carries them too.
  - `PROTOCOL_VERSION` is 23 (it was 22 when the section was written: the section's 23
    assumed one more bump).
  - A `Test` flake seen once while the suite ran in parallel: `test_breeding_lamb_to_adult`
    (a wall-clock window on a live server); it passed on every re-run alone. Not touched.


## M39: the state model (typed records and events, one codec, two lanes)

**Why.** M43's scripts subscribe to "the events M39 defines", M46 replicates its new voxel
channels "via M39", M48 replicates pack-defined entity components through it, and M44's
quests, dialogue and per-character objectives all need to reach the client. Each of
those would be a hand-written message today. The survey for this section found:

- 35 server messages in `game/protocol.odin` (1690 lines), each with a struct, a kind
  number, a name in `message_kind_name`, an encoder case, a decoder case with its own
  validation, a test block in `protocol_test.odin`, a table entry in
  `tools/wireshark/voxiverse.lua` (field layouts written by hand, for some kinds only)
  and a case in the client's switch (`client/session_net.odin`). A new replicated value
  touches all eight.
- Change tracking is ad hoc and different per feature: `health_told` (a last-sent copy),
  `worn_sent` (compared only when `inv_changed` is set), `inv_changed` (a dirty flag, then
  the whole inventory, 80 to 160 bytes, for one moved stack), `known` (a set diffed into
  `Entity_Spawn`/`Entity_Despawn`), `teleported` (a flag consumed once).
- The per-tick traffic is sent whole every tick with no delta at all: `Entities` is 37
  bytes per entity per tick whether it moved or not (a field of 100 grazing sheep is
  110 KB/s to each player), `Players` 37 bytes per player, `Player_Update` 52 bytes.
- Nothing measures bandwidth: the `server` bench scenario's `server_sent` counts streamed
  chunk bytes only, `game.Traffic` counts per message kind but nothing records it, and
  no baseline exists to be "no worse" than.
- The rules already travel through a reflective table (`write_vars` over
  `rules_table()`), and M38's `game/state_hash.odin` walks any value by its type info:
  the two pieces a schema-derived codec is built from.

**Design.**

*What moves and what stays.* The state model is the server-to-client direction only.

- **Moves** (22 messages): `Player_Update`, `Players`, `Entities`, `Entity_Spawn`,
  `Entity_Despawn`, `Entity_Hurt`, `Explosion`, `Health`, `Inventory_Update`,
  `Player_Worn`, `Player_Joined`, `Player_Left`, `Rules_Changed`, `Time`, `Grants`,
  `Variables`, `Selection`, `Notice`, `Chat_Line`, `Chat_Delete`, `Block_Changed`,
  `Blocks_Changed`.
- **Stays a message** (13), by rule:
  - the handshake and the connection: `Welcome`, `Reject`, `Challenge`, `Characters`,
    `World_Changed`;
  - answers to one client's request: `Pong`, `Edit_Result`, `Stats_Page`,
    `Telemetry_Ack`;
  - bulk streams with their own encodings: `Chunk_Message`, `Unload_Chunk`, `Column`,
    `Bulk_Begin` (M46 moves chunk data onto layers).

  The client-to-server messages (inputs and requests) are not state and stay as they
  are, except two fields below.

*Records, events and lanes.* A **state kind** is a replicated value type with a key; a
**record** is one value of a state kind under one key. An **event kind** is a one-off
value with no key and no history. Every state kind is on one of two **lanes**:

- **Reliable lane**: a `State` message (`Server_Kind.State`, 36), reliable and ordered.
  A changed record is sent as a delta against the value last sent to that client: the
  ordered stream guarantees the client holds it. Events go here too.
- **Snapshot lane**: a `Snapshot` message (`Server_Kind.Snapshot`, 37), unreliable,
  for values that change nearly every tick. A record is sent as a delta against the
  newest snapshot the client has acknowledged (Quake 3's model). A value that changed
  keeps being sent until a snapshot holding it is acknowledged, so the newest value
  always arrives without a reliable channel.

The game's kinds, in `game/state_kinds.odin` (`State_Kind` and `Event_Kind` enums, one
table `@(rodata) STATE_KINDS := [State_Kind]State_Kind_Info{...}` and `EVENT_KINDS`):

| State kind | Key | Lane | Value (fields) | Replaces |
|---|---|---|---|---|
| `Own_Player` | none | snapshot | `acked: u32` (tag `acked`), `state: Player_State`, `teleports: u8`, `yaw, pitch: f32` | `Player_Update` |
| `Health` | none | reliable | `health, max: f32` | `Health` |
| `Inventory` | none | reliable | `Inventory_State {acked: u32` (tag `acked`), `inventory: Inventory}` | `Inventory_Update` |
| `Rules` | none | reliable | `game.Rules` (check: the var table's ranges) | `Rules_Changed` |
| `Clock` | none | reliable | `time: f64, tick: u32`: the world time at that server tick | `Time` |
| `Grants` | none | reliable | `text` (max 16384), `commands` (max 16384) | `Grants` |
| `Variables` | none | reliable | `text` (max 4096) | `Variables` |
| `Selection` | none | reliable | `corners: [2]Maybe(Block_Pos)` | `Selection` |
| `Player` | `u16` player | reliable | `Player_Record {name` (max 16, check `name_valid`), `worn: [WORN_SLOTS]Item}` | `Player_Joined`, `Player_Left`, `Player_Worn` |
| `Player_Motion` | `u16` player | snapshot | `position: [3]f64, yaw, pitch: f32, flying, crouched: bool` | `Players` |
| `Entity` | `u32` entity | reliable | `Entity_Record {kind: Entity_Kind, stack: Stack}` | `Entity_Spawn`, `Entity_Despawn` |
| `Entity_Motion` | `u32` entity | snapshot | `position: [3]f64, yaw, pitch: f32, flags: Sheep_Flags` | `Entities` |
| `Block` | `Block_Pos` | reliable, write-through | `Block_Record {block: Block, heard: bool}` | `Block_Changed` (heard), `Blocks_Changed` (quiet) |

| Event kind | Fields | Replaces |
|---|---|---|
| `Notice` | `text` (max 1024) | `Notice` |
| `Chat_Line` | `id: u32, sender: u16, text` (max 1024) | `Chat_Line` |
| `Chat_Delete` | `id: u32` | `Chat_Delete` |
| `Entity_Hurt` | `entity: u32` | `Entity_Hurt` |
| `Entity_Died` | `entity: u32` (sent before the `Entity` record's removal) | `Entity_Despawn {died = true}` |
| `Explosion` | `position: [3]f64, radius: f32` | `Explosion` |

Notes on the kinds:

- `teleports` is a counter that wraps, replacing `Player_Update.teleported`: the client
  snaps (no smoothing, and takes `yaw`/`pitch`) when it changes. The server keeps its
  `teleported` flag as it is (it is hashed state); the counter is a new `Client` field,
  not hashed.
- An entity's existence is reliable (`Entity`: what it is) and its motion is on the
  snapshot lane (`Entity_Motion`: where it is). The client draws an entity once it holds
  both. The same split holds for players.
- `Clock` is an anchor, not the time: the server puts it at join, on travel, when the
  time is set and when `day_length` or `daylight_cycle` change. The client computes the
  time at a snapshot's tick with `advance_time(time, (tick - anchor tick) / TICK_RATE,
  rules)`. The once-a-second `Time` (8 bytes a second to every client) goes away. Client
  time is the free tier (`docs/determinism.md`), so the client's sum need not equal the
  server's bit for bit.
- `Welcome` and `World_Changed` keep their `rules`: the client predicts from the first
  input on. The server seeds that client's `Rules` copy with the same value
  (`replica_seed`), so the record travels only when a rule changes.
- `Block` is **write-through**: the server keeps no per-client copy (it cannot keep
  every block per client). Every `Block` record is a whole value. `changes_flush` keeps
  its rule that a chunk with more than 64 changes in a tick goes whole as a `Chunk`.

*The schema* (`game/schema.odin`). `schema_make(states: []State_Kind_Info, events:
[]Event_Kind_Info, allocator) -> (Schema, Schema_Error)` walks each value type's
`runtime.Type_Info`, as `state_hash.odin` does, and builds a flat field list per kind.

- **Fields are leaves.** Nested structs are flattened into their fields: `Own_Player`
  has `acked`, `state.position`, `state.velocity`, `state.on_ground`, ... as separate
  fields. Arrays of scalars (`[3]f64`) are one field. Fixed and enumerated arrays of
  structs (`[INVENTORY_SLOTS]Stack`, `[Equip_Slot]Stack`) are one field whose changes are
  sent element by element. At most 62 fields a kind.
- **Supported types** (after `distinct` and base types):
  - `bool`: u8 0 or 1;
  - unsigned integers (`u8`, `u16`, `u32`, `u64`): a varint;
  - signed integers (`i32`, `int`, `i64`): a zigzag varint;
  - `f32`, `f64`: their bits (4 and 8 bytes), finite only (`read_f32`/`read_f64`);
  - enums: a varint, checked against the enum's declared values;
  - `bit_set`: the underlying integer, bits outside the set refused;
  - fixed and enumerated arrays, as above;
  - `Maybe(T)` and other unions: a tag byte, then the variant;
  - `string`: a varint length, then UTF-8. A string field must carry a tag
    `` `net:"max=N"` ``, or `schema_make` refuses it (ground rule 6: every length is
    capped).

  `codec.odin` gains `write_varint64`, `read_varint64`, `write_svarint64` and
  `read_svarint64`, with the same one-encoding rule as the 32-bit ones.
- **Tags** (Odin struct field tags): `net:"max=N"` for strings; `net:"acked"` marks the
  field holding the sequence of the input or request the value reflects (prediction
  below).
- **Refused, as a value** (no panics a test must catch, per the sizing rules): pointers,
  slices, dynamic arrays, maps, procedures, `any`, untagged strings, more than 62
  fields. `Schema_Error {kind, path, reason}` names the field
  (`inventory.slots[].count: int is fine; inventory.note: string has no net:"max"`).
- **Each kind** in the table has: `name` (lower case, the wire and tool name), `value:
  typeid`, `key: Key_Type {None, Player, Entity, Block}`, `lane: Lane {Reliable,
  Snapshot}`, `write_through: bool`, `priority: u8` (snapshot lane: lower goes first),
  `max_records: int` (`Player` `MAX_PLAYERS`, `Entity` and `Entity_Motion`
  `MAX_KNOWN_ENTITIES` (moved from `server/entities.odin` to `game`), singletons 1),
  `version: u8` (bumped when a value keeps its type but changes meaning), and `check:
  proc(value: rawptr) -> bool` (validation the types cannot say: block ids, rule ranges,
  names; nil if none).
- `schema_text(schema, b)` writes the schema, one line per kind and per field, e.g.
  `state own_player 1 key=none lane=snapshot` and
  `  field state.position [3]f64`. `schema_hash` is `game.Hasher` over that text.
  `SCHEMA` (the game's schema) is built once per process. The server builds it in
  `server_init`, the client in `App` init, tools where they decode, from the constant
  tables; it is not a global.

*The wire.* A `State` message:

```
u8 kind (State)  varint tick
then groups until the message ends:
  varint id      (state kinds 0..n-1 in enum order, then event kinds n..)
  varint count   (1..remaining bytes)
  count entries
```

A record entry is `varint64 head` (bits 0-1 the op: 0 change, 1 create, 2 remove; bits
2.. the field mask of a change), then the key, then the fields:

- **create**: every field, absolute;
- **change**: the masked fields only, as deltas;
- **remove**: nothing.

An event entry is every field, absolute. Field encodings in a change:

- integers: the zigzag difference from the baseline, in the field's width with
  wrapping (an `acked` one input on is one byte);
- floats, bools, enums, bit_sets, strings, unions and arrays of scalars: the new value
  whole;
- arrays of structs: a varint count of changed elements, then for each a varint index
  and the element whole.

Keys, within a group (entries sorted by key):

- player and entity ids: a varint difference from the previous key (the first from 0);
- `Block_Pos`: `varint (local index + 1)` when in the same chunk as the previous key,
  else `0` followed by the chunk position (three svarints) and the local index. A
  chunk's water batch costs 4 bytes a block, as `Blocks_Changed` does.

The decoder (`read_state`) checks:

- every id is known;
- op 3 is refused;
- mask bits name fields of the kind;
- a change or remove names a key the receiver holds; a create names one it does not;
- records per kind stay within `max_records`;
- keys are in range (`MAX_PLAYERS`; `Block_Pos` inside the world, as
  `read_block_pos`);
- every value passes its type's rules and the kind's `check`;
- the message ends exactly at the last entry.

Order inside one tick's `State` message: creates and changes first (by kind order, then
key), then the events in the order they were raised (consecutive events of one kind make
one group), then removals. So an `Entity_Hurt` for an entity made this tick finds it,
and `Entity_Died` comes before its `Entity` removal.

A `Snapshot` message:

```
u8 kind (Snapshot)  varint tick  varint back  u8 part  u8 parts
groups as above (snapshot-lane kinds only)
```

- `back` is how many ticks before `tick` the baseline is (0: none, every record a
  create).
- A snapshot is split at record boundaries into parts of at most `SNAPSHOT_PART_BYTES
  :: 1150` (each one unreliable record: a test in `server/` asserts it is at most
  `netcode.FRAGMENT_SIZE`, 1176), at most `SNAPSHOT_PARTS :: 8` parts (9.2 KB a tick,
  276 KB/s, well under the connection's 2 MiB/s).
- Removal is explicit (op 2). A record absent from a snapshot keeps its baseline value.

*Replicas and the ring* (`game/replica.odin`, shared by the server, the client, test
clients and tools):

- **`Replica`**: per kind, the records a receiver holds. Per kind an array sorted by key
  (binary search; no map, so no map order reaches the wire) of `{key, value}`, the
  values in a per-kind byte array of the value type's size. Strings in kept values are
  owned copies, freed on replace and removal. Per record it also keeps `waiting: u32`
  (the server's snapshot priority, below). Keys are `Key :: struct {a, b, c: i32}` (an id
  in `a`, or a `Block_Pos`).
- **`Snapshot_Ring`**: the last `SNAPSHOT_RING :: 32` snapshots (just over a second at
  30 Hz), each a tick and the full set of snapshot-lane records as of that tick.
- **`Receiver`**: a `Replica`, a `Snapshot_Ring`, the newest complete snapshot tick (the
  ack), and parts being gathered.
  - `receive_state(rx, data) -> iterator` and `receive_snapshot(rx, data) -> iterator`
    decode a message and yield `Received {kind, op, key, value: rawptr, mask}` (events
    yield their value). Values are views valid until the next receive.
  - A snapshot whose baseline is not in the ring is dropped and counted
    (`rx.dropped`).
  - Parts are applied as they arrive, each against the same baseline.
  - A snapshot becomes a baseline (stored in the ring and acknowledged) only once all its
    parts have arrived.

*The server side* (`server/replica.odin`; `Client` gains `replica: game.Replica`, `ring:
game.Snapshot_Ring`, `acked_snapshot: u32`, `pending` events, and `teleports`):

- `state_put(s, c, kind, key, value)` sets the record's value for this tick. Several
  puts in a tick coalesce: the last wins.
- `state_remove(s, c, kind, key)` removes it.
- `event_send(s, c, value)` and `event_broadcast(s, value, world)` queue an event (the
  value's type names its kind, through the table).
- **Keyed kinds are views**, rebuilt every tick. `Player`, `Player_Motion`, `Entity` and
  `Entity_Motion` records not put in a tick are removed at the flush, so the server code
  says only what the client should see now. Singletons persist until put again.
- `replica_flush(s, c)`, once per client at the end of the tick (after `stream`, before
  `host_flush`):
  - reliable lane: compares each put record with the client's copy field by field
    (bits, so -0 differs from 0), writes creates, changes with their masks, the events
    and removals into `State` messages (split at entry boundaries under
    `MAX_MESSAGE_SIZE`), and updates the copy;
  - snapshot lane: builds snapshot `tick` from the newest acknowledged baseline still in
    the ring (or none), takes the records that differ from it by priority until
    `SNAPSHOT_PARTS` is full, writes them, and stores in the ring what the client will
    hold if it all arrives: the sent records' new values, the rest their baseline values.
- **Snapshot priority**, integers only so it is deterministic: records waiting longest
  first (`waiting`, the ticks a changed record has gone unsent), then kind `priority`
  (`Own_Player` 0, `Player_Motion` 1, `Entity_Motion` 2), then the squared distance
  from the player in whole blocks, then the key. What is taken is then written grouped
  by kind and sorted by key.
- `Input` gains `snapshot: u32`, the client's newest complete snapshot (a varint, 0:
  none). The server keeps the highest it has seen.
- **Travel**: the pending `State` is flushed, then `World_Changed` is sent. Then both
  sides drop their keyed records (no removals sent; entity ids are per world) and the
  ring, so the next snapshot has no baseline. `disconnect` flushes the pending `State`
  before `Reject`, so a last `Notice` arrives.
- **Joining**: `Hello` gains `schema: u64`. A server whose `schema_hash` differs refuses
  with `Reject "this server runs a different version of the game (state schema
  <server's> vs <yours>)"`, checked after the protocol version. `PROTOCOL_VERSION`
  becomes 24.
- **Send sites move.** Each `send_message`/`broadcast` of a moved message becomes a put
  or an event at the same place:
  - `simulate_player` puts `Own_Player`;
  - `health_tick` puts `Health` (`health_told` goes);
  - the end of the tick puts `Inventory` (`inv_changed` goes);
  - `replicate` (`server/entities.odin`, renamed `entities_put`) puts `Entity` and
    `Entity_Motion` for every entity in view (`known` goes; the 256 cap stays as
    `max_records`);
  - `send_players` becomes `players_put`: `Player` (name, `worn_of` the inventory) and
    `Player_Motion` for every other player in the world (`worn_sent` goes);
  - `changes_flush` puts `Block`;
  - `refresh_grants`, `selection_set`, the worldgen variables, the clock and the rules
    put theirs;
  - `notice`, chat, `entity_hurt_shown`, `entity_remove` (died) and `explode` send
    events.

  The stepped server (M38) flushes in `step` the same way.

*The client side* (`client/state_apply.odin`): the session owns a `game.Receiver`.
`session_net.odin`'s switch loses the 22 cases and gains `State` and `Snapshot`, which
iterate the received entries through one table, `APPLY := [State_Kind]Apply_Proc`, plus
a switch on event kinds. Each apply proc does what the old case did, with the same procs.

*Prediction hooks.* A kind with an `acked` field is predicted. The apply proc is where
prediction meets the record, and the table names three modes (`Prediction :: enum
{None, Inputs, Requests}`) so a new predicted kind says which it is:

- **`Inputs`** (`Own_Player`): `prediction_reconcile` from `acked`, as `Player_Update`
  did. A record older than the newest applied is ignored, judged by snapshot tick,
  which replaces `sequence_before(acked, last_acked)`. A changed `teleports` snaps.
- **`Requests`** (`Inventory`): `inventory_reconcile` from `acked`, then
  `inventory_predict`.
- **`None`**: everything else.

`Block` is not predicted by the record: a pending edit's prediction stays until its
`Edit_Result`, as today.

*The tools.*

- `message_kind_name` names `state` and `snapshot`. Moved kinds' numbers are retired
  (left as gaps in `Server_Kind`, marked so) so kept kinds keep theirs.
- `tools/netdump -summary` splits `state` and `snapshot` bytes by state and event kind.
  It uses `game.scan_state`, a walk that sizes every entry without a replica: masks say
  which fields are present, so no baseline is needed to skip them.
- The F3 traffic panel shows `state` and `snapshot` as two kinds.
- `tools/replay`, `dedicated/bench.odin`'s bots and `collector/upload.odin` decode with a
  `Receiver` where they read moved messages (the bench bots read their `Own_Player`).
- The test clients migrate the same way: the determinism mirror, `latency_test`'s
  `Predicting_Client`, `save_test`'s client and `net_test`'s clients.

*The dissector reads the schema.* `tools/wireshark/voxiverse.lua` gets a generated block
between `-- schema begin` and `-- schema end`: a Lua table of every kind with its id,
key type, lane and fields (name, type, max), written by `game.schema_lua(schema, b)`.

- `build schema` (`tools/build/main.odin`) rewrites the block in place. The file stays
  one file to load into Wireshark.
- `game/protocol_test.odin`'s `test_dissector_schema_current` fails when the block
  differs from `schema_lua(SCHEMA)`, with "tools/wireshark/voxiverse.lua's schema is
  stale: run ./build.sh schema". It sits beside `test_dissector_knows_every_kind`.
- The dissector decodes `State` and `Snapshot` generically from the table: groups,
  heads, masks, keys and fields. Changes show only the fields present: deltas, labelled
  `+n` for integers, since the dissector has no baseline.
- Integers beyond 2^53 show approximately in Lua 5.2 Wireshark builds; none of today's
  fields reach that.
- `check.lua`'s fake API grows what the generic decoder calls. The CI step (a server
  capture through `check.lua` and `tshark`, nothing malformed) is unchanged.

*The bandwidth benchmark* (`server/bandwidth_test.odin`). Exact, not statistical:
stepped sessions are deterministic, so the bytes are too, on every OS. Two scenarios on
M38's stepped server and mirror client, counted by the pipe's `game.Traffic` in both
directions:

- `session`: M38's scripted session for `BANDWIDTH_TICKS :: 6500` ticks (past the
  water at 2500, the farm at 3000, the flight at 4000 and the rocket at 6000).
- `crowd`: the same world with natural sheep off. `/summon sheep 25` four times on ticks
  1-4, then 900 ticks with the player standing still, so 100 sheep wander and graze.

`assets/baselines/net/bandwidth.txt`:

```
bandwidth 1
scenario session ticks=6500 root=<M38 root at the last tick>
server_to_client <bytes>
client_to_server <bytes>
kind <name> <messages> <bytes>     (one line per message kind seen, both directions)
scenario crowd ticks=904 root=<root>
...
```

- It is written by the test when built with `-define:VX_BANDWIDTH_ACCEPT=true`, and
  committed in step 1 with today's protocol, before anything else changes.
- After that the tests compare, and fail with the numbers:
  - `server_to_client` at most the baseline's;
  - `client_to_server` at most the baseline's plus 5 bytes per `Input` (the ack) plus 8
    (the schema hash);
  - the root identical: the protocol does not touch simulated state, so M39 must leave
    M38's hashes exactly as they were.
- The `kind` lines are for reading, not compared: the commit message of the last step
  quotes the before and after totals and the moved kinds' bytes against `state` and
  `snapshot`.

**The order of the steps** (each leaves the suite passing):

1. The bandwidth tests and the baseline file, on today's protocol. Commit.
2. `write/read_varint64` and `svarint64`; `game/schema.odin` with `schema_text`,
   `schema_hash` and `schema_lua`; its tests.
3. `game/replica.odin` (`Replica`, `Snapshot_Ring`, `Receiver`) and the `State` and
   `Snapshot` encoders and decoders, `scan_state`; their tests, with a test schema of the
   test's own (step 2's and 3's tests never touch the game's kinds).
4. `game/state_kinds.odin` with the game's kinds and events; `Server_Kind.State` and
   `Snapshot`, `Hello.schema`, `Input.snapshot`, `PROTOCOL_VERSION` 24; the round-trip
   test of every moved message.
5. The reliable lane end to end: `server/replica.odin`'s puts, events and
   `replica_flush`; the client's `Receiver` and apply table; every reliable kind and
   event moved, its old message deleted, the test clients and tools along.
6. The snapshot lane end to end: `Own_Player`, `Player_Motion`, `Entity_Motion`, the
   ring, acks, priority and parts; `Players`, `Entities` and `Player_Update` deleted.
   Then the bandwidth tests must pass against the baseline.
7. The dissector's generated block, `build schema`, `check.lua`, netdump's split, the
   F3 names.

If the session must split, the remainder is **M39b: step 7**, with
`test_dissector_schema_current` and CI's Wireshark step (both new message kinds decoded
field by field, nothing malformed) as its exit check. M39 itself then still adds `state`
and `snapshot` to the dissector's kind tables (names only), so
`test_dissector_knows_every_kind` passes.

**Left out:**

- Client-to-server messages as state: inputs and requests stay messages.
- Chunks, columns, unloads and bulk edits as records (M46's layers).
- Quantized or compressed positions, interpolation and a jitter buffer (M48). Values
  travel exactly: the mirror's chunks and prediction must equal the server's.
- Budgets and priorities on the reliable lane, per-client bandwidth limits and rate
  limits (M50). Only the snapshot lane has a budget.
- Interest beyond today's: entities within `ENTITY_VIEW`, all players of a world.
- Event subscriptions for scripts (M43; the event kinds are its vocabulary).
- Saves through the schema (M49).
- Compatible schema differences (a client with an older schema joining): a mismatch
  refuses.
- A per-state-kind breakdown in the F3 panel (netdump has it).

**Tests:**

- `game/codec` (in `protocol_test.odin`): 64-bit varints round-trip at the edges
  (0, 2^63, 2^64 - 1, the most negative `i64`); overlong and over-wide encodings fail.
- `game/schema_test.odin`:
  - a test struct with every supported type (bool, `u8`, `u16`, `u32`, `u64`, `i32`,
    `int`, `f32`, `f64`, an enum with gaps, a `bit_set`, `[3]f64`, `[4]Stack`,
    `[Equip_Slot]Stack`, a nested struct, a tagged string, `Maybe(Block_Pos)`) gets the
    leaf list expected, by path;
  - each refused type returns its `Schema_Error` with the path;
  - the hash changes with a field's name, type or order, a kind's version, lane or key,
    and the order of kinds;
  - `schema_text` of the test schema equals a golden text.
- `game/delta_test.odin`:
  - **`test_new_field_needs_no_code`** (the exit check): a test schema with a kind
    `Gauge` (`a: i32, b: f32`) and a second schema where `Gauge` has two more fields
    (`c: [3]f64, mode: Gauge_Mode`). Each round-trips create, change and remove through
    `replica_flush`'s encoder and a `Receiver`, with no code written for `Gauge`. A change
    of `mode` alone costs head, key and one byte. The two schemas' hashes differ.
  - Every field type round-trips as create, as change and inside events; the decoded
    replica equals the sender's copy after 1 000 random changes.
  - Costs: `acked` one on is 1 byte; one moved inventory stack is under 8 bytes; 64
    blocks in one chunk cost at most 4 bytes each plus the group header.
  - Reliable lane: puts coalesce within a tick; an unchanged put sends nothing; keyed
    kinds not put are removed; the order of creates, events and removals.
  - Snapshot lane, over a simulated link (dropped parts chosen by a seeded `base.Rng`):
    - with 20% of parts lost over 300 ticks, the receiver's records equal the server's
      within 2 ticks of the last loss;
    - a snapshot with one part lost is applied in part, not acknowledged, and the next
      deltas still decode against the older baseline;
    - an acknowledgement older than the ring gives a snapshot with no baseline;
    - a baseline the receiver lacks is dropped and counted.
  - Priority: with a budget of one part and 200 changing records, nearer ones go first,
    and every record is sent within 10 ticks (the starved go first).
  - Malformed input fails, every case its own message: every prefix of a `State` and a
    `Snapshot` message; an unknown id; op 3; a mask bit past the kind's fields; a change
    to an unheld key; a create of a held one; a record past `max_records`; a `Block_Pos`
    outside the world; a NaN; an enum gap; an out-of-set bit; an over-long string; a
    failing `check`; trailing bytes. `test_decode_fuzz` covers both messages.
- `game/protocol_test.odin`:
  - **`test_every_moved_message_round_trips`**: for each of the 22 moved messages, the
    values its test block uses today, put through the new mechanism (records or events),
    decode to the same values;
  - the kept messages' tests stay; `Hello.schema` and `Input.snapshot` round-trip;
  - `test_dissector_knows_every_kind` and `test_dissector_schema_current`.
- `server/bandwidth_test.odin`: `test_bandwidth_session` and `test_bandwidth_crowd`
  against the baseline, as above; `test_snapshot_part_fits` (`SNAPSHOT_PART_BYTES <=
  netcode.FRAGMENT_SIZE`).
- `server/net_test.odin`, extended: in `test_players_through_ten_percent_loss`, after the
  loss stops, within 30 ticks each client's `Player_Motion` of the other and its
  `Entity_Motion` of a summoned sheep equal the server's values exactly. A client with
  another schema hash is refused with the message above.
- Unchanged and passing: `server/determinism_test.odin` (its mirror on the `Receiver`),
  `server/latency_test.odin` (prediction and the desync tests through `Own_Player`),
  `netcode/host_test.odin`, and the rest of the suite.

**Exit check:**

- `test_new_field_needs_no_code` passes: a new replicated field needs no protocol code.
- `test_every_moved_message_round_trips` passes, with the kept messages' round trips.
- Both bandwidth tests pass: server-to-client bytes no more than the committed baseline
  for `session` and `crowd`, and M38's root unchanged.
- The UDP tests pass: `netcode/host_test.odin` and `server/net_test.odin`, with the
  extended loss test.
- `build determinism`, `build check` and the whole suite pass.
- The CI run of the commit is green, including the Wireshark step (in M39b if split).

**Check by hand:**

- Host a LAN game and join it from a second client (on one machine: `./build.sh run`
  twice, the second through Multiplayer). Expect:
  - the other player and a dozen summoned sheep move as smoothly as before;
  - moving stacks in the inventory and wearing armour shows on the other client;
  - chat and its deletion, `/time set noon` (the sky changes at once on both), an
    explosion (flash and debris) and water flowing all behave as before;
  - F3's traffic panel shows `snapshot` near zero per second while everything stands
    still.
- Open a capture (`voxiverse-server --capture build/server.pcap`, a session joined) in
  Wireshark with `tools/wireshark/voxiverse.lua`. Expect `State` and `Snapshot` packets
  listing their kinds, keys and fields by name, and no malformed packets.

- **Result** (what differs from the section, and what was found):
  - Bytes, server to client, over the scenarios: `session` 2,392,184 -> 1,410,902 and
    `crowd` 3,504,551 -> 2,124,643; client to server grows by 2 bytes an `Input` (the
    snapshot ack) and 8 on `Hello`. M38's roots are unchanged in both.
  - The `crowd` scenario is five summons of 20 on ticks 1-5 (`/summon` takes at most 20) and
    905 ticks, not four of 25.
  - The section's `Prediction` enum is `Predicted` (`game.Prediction` is the client's
    prediction state); `State_Kind_Info` gained `locate`, the whole-block place of a
    snapshot record, for the priority's distance.
  - A `Block` record costs up to 5 bytes (head, a one- or two-byte key, block, `heard`), not
    4: `test_costs` bounds it by 5.
  - Players: every other player of the world has a `Player` record, `Player_Motion` only the
    ones within `view_radius + 1` chunks (as `Players` did), not all.
  - Singletons persist across travel on both sides (only keyed records and the ring are
    dropped); the server's `Rules` copy and the receiver's are seeded from `Welcome` and
    `World_Changed`. `Rules` and `Inventory` are put every tick and cost nothing while
    unchanged; `Clock` is put at join, travel, `/time` and rule changes, and every tick while
    the local player's pause stops time (`Server.time_stopped`), so a client that derives
    the time from the anchor and the newest tick stands still with it.
  - Strings are refused on the snapshot lane (their copies would need an allocator per
    snapshot): `Schema_Error` says so. An empty snapshot is not sent at all.
  - The snapshot budget is `SNAPSHOT_PARTS * (SNAPSHOT_PART_BYTES - 200)` less the removals,
    so the grouping and rolling over of entries cannot need a ninth part (asserted).
  - `receive_state` and `receive_snapshot` fill a list of `Received` instead of being
    iterators; `State_Message` and `Snapshot_Message` carry the raw bytes in
    `Server_Message`. A client that sees an `Entity` before its `Entity_Motion` (the lanes are
    not ordered together) finds the motion with `receiver_snapshot_get`.
  - A decoded union is zeroed first, so values compare with `==` as they were sent.
  - Test clients send an `Input` to get snapshots (an idle client's `Own_Player` does not
    change), and derive the world time as the real client does.
  - The dissector: Lua doubles are exact to 2^53; records of a fragmented message are
    labelled, not decoded, and only an unfragmented State or Snapshot that does not decode
    is flagged malformed. `tools/schema` (run by `./build.sh schema`) rewrites the generated
    block; `check.lua` finds the server's port from the first `connect` (or `VX_SERVER_PORT`)
    and prints every record's text with `VX_CHECK_VERBOSE=1`. `test_players_over_the_network`
    writes `build/net_players.pcap` from alice's side for it.
  - `collector` and `replay` send `Hello.schema` as 0 / as recorded: a collector is not a game
    server, and a replay is of the same build.
  - The section's `test_decode_fuzz` for both messages is `test_state_decode_fuzz` (the old
    one stays for the old messages).
  - The tshark run and the by-hand checks (a LAN game, Wireshark on a capture) were not done
    here; the lua5.4 `check.lua` on a capture of the loss test's client decodes 136 packets
    with none malformed.

# M40: playtest fixes

From the owner's first playtest (2026-10-26). All small, all decided; one session. Work in
this order (each step is its own commit-sized piece with its tests; the suite runs once at
the end).

1. **Theme overrides at the call site** (first: the colour steps below need its fields).
   - `client/ui/theme.odin`: `Theme` gains `opacity: f32` (0..1, default 1) and the named fields
     the screens' literals move into (below). `ui.theme_scope(ctx, t: Theme) -> Theme`
     pushes the current theme onto a stack in `Context` (`theme_stack: [8]Theme`,
     `theme_depth`; a ninth push is an `errors` count and is ignored) and makes `t` current;
     it is marked `@(deferred_out = theme_unscope)`, and `theme_unscope(ctx, saved)` restores
     exactly. Nested scopes compose: a caller multiplies (`t := ctx.theme; t.opacity *= 0.6`).
   - `client/ui/draw.odin`: `push_quad` is the one place every vertex is made; it multiplies the
     vertex colour's alpha by `ctx.theme.opacity` (rounded, `u8`), so panels, text, icons and
     images (their tint) all fade, and colours' own alpha still apply. `fill_rect`'s
     `color.a == 0` early-out stays (it tests the colour before opacity).
   - The colour literals in `client/` screen code move into the theme. Counted now: 76
     four-number literals in `client/` outside tests, but only 31 are UI colours, in
     `dial.odin` (2), `multiplayer.odin` (4), `worlds.odin` (4), `options.odin` (1),
     `inventory_ui.odin` (7), `screens.odin` (6), `console.odin` (3), `audio_inspector.odin`
     (4). The other 45 are data (avatar and sheep colours in `avatars.odin`, `entities.odin`;
     item icon pixels in `icons.odin`; debug boxes in `camera.odin`; the clear colour in
     `app.odin`) and stay. New `Theme` fields, defaults equal to today's literals:
     `slot_fill {0,0,0,230}` (slots, dial cells, tooltips), `faint_border {255,255,255,60}`,
     `list_fill {0,0,0,140}`, `list_border {255,255,255,50}`, `row_hover {255,255,255,40}`,
     `row_selected {255,255,255,18}`, `text_shadow {0,0,0,255}`, `preview_fill
     {10,12,18,255}`, `warning {220,90,70,255}` (a key bound twice), `crosshair
     {255,255,255,200}`, `hud_fill {0,0,0,235}`, `menu_fill {0,0,0,170}`, `console_fill
     {0,0,0,255}`, `log_warn {255,200,80,255}`, `log_error {255,100,100,255}`,
     `health_full {226,56,66,255}`, `health_empty {70,24,28,255}`, `meter_back
     {40,40,40,255}`, `meter_fill {90,170,220,255}`, `graph_back {20,20,20,255}`,
     `graph_line {230,160,60,255}`. A test greps nothing; review checks that no
     `{n, n, n, n}` literal is left in those eight files.
   - The hotbar (`client/screens.odin`, `hotbar`) draws inside `t := app.ui.theme;
     t.opacity = HOTBAR_OPACITY; ui.theme_scope(&app.ui, t)`, `HOTBAR_OPACITY :: 1` (opaque
     as today; the value is tuned by eye later: a check by hand).
   - Tests (`client/ui/ui_test.odin`): `test_theme_scope_nests` (two nested scopes, then both
     ended: `ctx.theme == DEFAULT_THEME` field for field); `test_opacity_halves_alpha`
     (opacity 0.5: a `panel`'s, a `draw_text`'s and a `draw_icon`'s vertices have half the
     alpha they have at 1, within 1).
2. **Audio tab.** `Options_Tab.Sound` becomes `.Audio` and `tab_name` says "Audio". Nothing
   saved names the tab (the settings file holds the fields only), so nothing migrates.
3. **Words for special values.** `base.Var` gains `special: []Var_Choice`: values a slider
   shows in words. `ceiling_db` gets `{{-1, "Off"}}` (-1 is the limiter's own ceiling, so no
   extra ceiling), `crossfeed` gets `{{0, "Off"}}`, `gui_scale` `{{0, "Auto"}}`. `ui.slider`
   gains `value_text := ""` (drawn instead of `format` when not empty); `var_widget` passes
   the matching `special` label. Saved values are unchanged.
4. **Tooltips.**
   - The text is `Var.help`, which every setting already has: one table beside the options,
     shared with the console's help. Rewrite the help texts of every field in `OPTIONS_TABS`
     and every `BINDING_VARS` entry as one plain sentence a player reads (no "key:" prefix;
     `test_screens_speak_plainly`'s word list applies to them too). The listener options:
     Mono sound "Both ears hear the same mix (for one-sided hearing or one earbud)."; Swap
     ears "Left and right are exchanged."; Night mode "Quiet sounds come up and loud ones go
     down, for playing at low volume."; Headphone cross-feed "Each ear hears a little of the
     other, as with speakers: less tiring on headphones."; Loudest sound "A ceiling no sound
     goes over, in decibels below full scale. Off: only the usual -1 dB limit."
   - `client/ui/widgets.odin`: `tooltip(ctx, r: Rect, text: string)`. `Context` keeps
     `tip_id: Id`, `tip_since: f64`; `Input` gains `time: f64` (seconds, monotonic; the
     client's `ui_input` fills it from `time.tick_now`, tests set it). While the mouse stays
     inside `r` (the id is `get_id(ctx, text)`) for `TOOLTIP_DELAY :: 0.4` s, the text is
     drawn on the `.Tooltip` layer in a `slot_fill` box 12 units below-right of the mouse,
     kept on screen, wrapped at 360 units. Moving to another widget restarts the delay.
   - `var_widget` calls it: for a slider over its label part (the left 40%), for a choice
     button, checkbox or text field over the whole row. The bindings list does the same per
     row. The inventory's own `tooltip` in `client/inventory_ui.odin` is renamed
     `item_tooltip` and draws with `slot_fill`.
5. **Q and E between tabs.**
   - `Bindings` gains `tab_prev` (default `.Q`) and `tab_next` (default `.E`), with
     `BINDING_VARS` entries "Previous tab" and "Next tab"; Options > Controls lists them.
   - Contexts: `Binding_Context :: enum u8 {World, Menu, Both}` and a `@(rodata)
     BINDING_CONTEXT := [len(BINDING_VARS)]Binding_Context` beside `BINDING_VARS`: `tab_prev`,
     `tab_next` are Menu; `screenshot`, `fullscreen` Both; the rest World. The "bound twice"
     outline in `bindings_list` marks two bindings only when their contexts overlap (World
     and Menu do not; Both overlaps either), so Q for drop and for previous tab is fine.
   - `client/controls.odin`: `menu_tab_step(app) -> int` returns -1, +1 or 0 from
     `tab_prev`/`tab_next` in `app.input.pressed`, and 0 while `app.ui.edit.active` (typing
     Q into a name or a search is typing) or while a binding is being listened for.
   - Options: `options_body` applies it (wrapping around the five tabs, resetting scroll and
     listening as a click does) and draws the hint "Q / E" (the keys' `key_label`s) at the
     right end of the tab row in `text_muted`.
   - The inventory overlay: the ring is Inventory, Creative (with `items.catalog`), then
     Statistics. Statistics stays its own overlay (`stats_ui.odin`); stepping to it closes
     the inventory and opens Stats (`stats_open`), and stepping from it closes Stats and opens
     the inventory on the tab next to it. Both overlays draw the same tab row
     (`inventory_tabs` grows a "Statistics" entry; the Stats overlay draws the row too, lit on
     Statistics) with the hint. The Chest tab is not in the ring (Q/E do nothing there).
   - Over a slot in the inventory, the drop key still drops one (Ctrl: all) as today; only a
     press with no slot hovered steps the tab. (Both are Q by default; the slot wins.)
   - (Replaced after the playtest: the inventory key, now Tab, opens the inventory and closes
     it again; Esc still closes it, a chest closing from the server too, and Tab typed in a
     text field (the creative search) does not close it. E is left for stepping tabs next to
     Q; the pad's Y still only opens, B closes. The first rule here was Esc only, with
     `inventory_keys` only opening.) The stats key (K) still toggles its overlay.
   - Tests (`client/menus_test.odin`, `client/inventory_ui_test.odin`):
     `test_options_tabs_by_keys` presses `tab_next` five times from Video and sees Audio,
     Controls, Accessibility, Profile, Video; on each tab every row of `OPTIONS_TABS[tab]`
     (and on Controls every binding row) is hovered with `Input.time` advanced 0.5 s and the
     frame's `ui.texts` holds that variable's `help`; Q typed into the Profile name field
     changes the name, not the tab. `test_inventory_tabs_by_keys`: E steps Inventory ->
     Creative -> Statistics (the Stats overlay open, the inventory closed) and Q steps back;
     E no longer closes the inventory, Esc does; Q over a slot drops (a Drop request is
     sent), Q off the slots steps the tab.
6. **Keep awake for the whole run.** In `app_frame` (`client/app.odin`) the
   `playing := ...; platform.set_keep_awake(w, playing)` pair becomes
   `platform.set_keep_awake(w, true)` from the first frame (off at exit as now, in
   `platform.window_close`). In `client/platform/keep_awake_linux.odin` the success lines (lines
   93-215 today: "keep awake on", "off", "cookie released", "portal request closed") move to
   `log.debug`; a failure to inhibit (libdbus missing, no session bus, neither interface
   answered) stays `log.info`, at most once per run (a file-private `warned` flag, like the
   file's existing state). Windows' and macOS' `native_set_keep_awake` logs follow the same
   rule. Test (`client/menus_test.odin`, `test_keep_awake_on_title`): one title frame through
   the function `app_frame` uses for this (factor it as `keep_awake_update(app)`) leaves
   `app.window.keep_awake == true` with no session.
7. **Loading waits for the ground only.**
   - `client/loading.odin`: `world_near_ready(s) -> bool`. For each of the 5x5 chunk
     columns within 2 of the player's chunk (cx, cz) in the interest area: its
     `Client_Column` is known, and every chunk from `hi = cy + 1` down to `lo = min(cy - 1,
     floor(min(column heights) / 16))`, with `lo` clamped to at least `cy - view_height` and
     to the world's bottom, is present (`world_get != nil`), not `dirty`, not `queued`, not
     `waiting` (meshed or empty). `cy` is the chunk of the player's feet.
   - `loading_update` ends loading when `world_near_ready` holds (logging `session loaded
     near=<chunks> seconds=<s>`), not when the whole area is meshed; `LOADING_LIMIT` (60 s,
     "gave up waiting") stays. `world_settled` is unchanged (benchmarks, the flight, tour,
     blast and audio checks wait for it themselves).
   - `LOADING_SHOW_AFTER :: 0.25` (seconds): `loading_screen` draws only the starfield until
     the session has been loading (or connecting) that long, then the full screen; a world
     ready within 0.25 s just appears.
   - Test (`client/world_test.odin`, `test_near_ready`): a built `World` with the 5x5x4
     chunks and columns present but one chunk queued is not ready; meshed, it is; a chunk 3
     columns away missing does not matter; a column whose ground is 40 blocks below the
     player needs the chunks down to it.
8. **Health off by default.** `RULES_DEFAULTS.damage = false` (`common/game/rules.odin`); help
   text "players take damage (falls, explosions) and can die; off in new worlds".
   `health_bar` returns at once when `!s.rules.damage`. A save written with
   `rules.damage = true` keeps it (the line is in its `world.cfg`); one written before M28
   has no line and starts with damage off, which is the plan's creative first. Tests that
   need damage (`server/health_test.odin`, `server/ledger_test.odin`, the net and save tests
   that hurt players, `client/blast_test.odin`) set `rules.damage = true` explicitly. If
   the bandwidth baseline's root hash moves, re-accept it
   (`-define:VX_BANDWIDTH_ACCEPT=true`) and say so in the commit. The health code stays; it
   comes back as the `survival` preset in M53.
9. **The icon.**
   - Drawing moves into `client/ui/icon.odin` (the game sets its window icon at run time, so the
     code is shared, not in `tools/build`): `app_icon(f: ^font.Font, size: int, allocator)
     -> []u8` (RGBA, straight alpha). A clean cube in oblique three-quarter view on a
     transparent ground, in units of `s = size`: the front face the square (0.10s, 0.28s) to
     (0.72s, 0.90s); the top face the front's top edge and the same edge moved by
     (+0.18s, -0.18s); the right face likewise from the front's right edge. Faces sRGB
     top `#2A2A2E`, front `#1A1A1D`, right `#0E0E10`. Coverage is 4x4 supersampled per pixel
     at each size (anti-aliased, drawn at that size, never scaled from another). A white
     `?` from JetBrains Mono (the font the game embeds) rasterized by `font.rasterize` at a
     pixel size of `0.62 * front height`, centred on the front face by its outline bounds,
     composited over it. No palette quantization.
   - `tools/build/icon.odin`: `ICON_SIZES :: [7]int{16, 24, 32, 48, 64, 128, 256}`;
     `write_icon` loads `assets/fonts/jetbrains_mono_regular.ttf` (`#load`), writes
     `build/voxiverse.ico` (one PNG entry per size, as now) and `build/icon-<size>.png` for
     each size plus `build/icon.png` (256). The old texel picture and `icon_scaled` go.
   - The window: `platform.set_window_icon(w, images: []Icon_Image)` (`Icon_Image ::
     struct {size: int, rgba: []u8}`). X11: `_NET_WM_ICON` (CARDINAL/32: width, height, then
     ARGB per pixel, for 16, 32, 48, 64, 128); Windows: nothing (the executable's resource,
     as now); macOS: nothing until the M1b backend has a window. `app_init` calls it after
     `ui.init` with `ui.app_icon(&app.font, size, context.temp_allocator)`.
   - The Linux package copies `build/icon.png` into its folder as `voxiverse.png`.
   - Test (`tools/build/icon_test.odin`, or `client/ui/icon_test.odin`): every size has transparent
     corners, opaque face pixels of the three face colours at the faces' centres, and at
     least `size * size / 200` white pixels (the `?`) inside the front face; two calls give
     the same bytes.
10. **The lake script.** `tools/lake-sync.sh` goes. `tools/analytics/main.odin` accepts
    `--pull <host:path> [dir]` (dir default `lake`) as its first argument: makes `dir` and
    runs `rsync -a --partial <host:path>/ <dir>/` through `os.process_start`, failing with
    "analytics: --pull needs rsync on the PATH" when it cannot start. So `build analytics
    --pull host:/srv/voxiverse/lake` replaces the script. `docs/telemetry.md` and the usage
    line are updated.

Exit check: the suite green locally (`build test`) and CI green on the three OSes;
`test_options_tabs_by_keys` and `test_inventory_tabs_by_keys` walk every tab with Q and E
and find a tooltip for every option and binding; `test_keep_awake_on_title` passes; the
icon test passes. Check by hand (listed in the report): `build icon`, then look at
`build/icon-16.png` to `build/icon-256.png` (the `?` sharp and legible at 16 and 24); the
hotbar's opacity to tune by eye.

- **What differed from the spec:**
  - `theme_scope` returns a `Theme_Saved{ctx, theme}`, not a `Theme`: a `deferred_out` end
    receives only the results, so the context travels in it; `theme_unscope(saved)`. A ninth
    nested scope is an `errors` count and its end is ignored (`theme_over`). The hotbar
    scopes `ctx.theme` (it has the context, not the app).
  - `world_near_ready(s)` is `world_near_ready_at(world, centre, radius, height)` plus the
    session wrapper, so a test can build a bare `World`. A chunk that is dirty but whose
    neighbours are not all here (it cannot mesh yet: the interest area's edge) counts as
    ready, or a view radius of 2 would wait the full 60 s. `neighbours_present` is no longer
    file-private.
  - The Statistics tab is in the ring without `items.catalog` too (Inventory, Statistics);
    the inventory always shows the tab row (it was a plain title without the catalog). Q/E
    steps around (Inventory from Q goes to Statistics). A `fresh` flag on the inventory view
    and the stats view keeps the press that opened an overlay from stepping it in the same
    frame. `menu_tab_step(app, over_slot)` skips a step whose key is also the drop key while
    a slot is hovered.
  - The tooltip also records its whole text in `ctx.texts` (its wrapped lines are drawn as
    lines), so tests read the help as written. `ui.wrap_words` is its plain wrap.
  - The icon test samples the front face low-left, not at its centre (the question mark is
    there); the top and right at their centres. White means every channel above 160.
  - `gui_scale` has `special` {0, "Auto"} as specified, but it is a choice button, so only
    `ceiling_db` and `crossfeed` show it on a slider.
  - A settings slider's special label is chosen from the value before the frame's drag, so
    it follows one frame late.
  - The bandwidth baseline's kind lines were still M38's (only the root and sizes are
    compared); accepting it rewrote them for the state model as well as the damage change.
  - Windows' keep-awake failure stays a `log.warn`, once per run (the spec's `log.info` is
    the Linux wording).

# M41: input actions and gamepads

One actions layer between platform events and everything that reads controls today, and
gamepads on all three OSes through our own backends. After it, a pad plays the game (move,
look, jump, fly, break, place, the hotbar, the inventory key, chat and stats keys, the game
menu); menus with a pad are M42. One session.

**What exists.** `client/controls.odin`: `Bindings`, a struct of `platform.Key` (keys and
mouse buttons by place), saved as `key.<field> = <key>` through `bindings_table()`;
`client/input.odin`: `Input_State` (held/pressed keys, mouse, text) from `platform.Event`s;
call sites test `app.settings.keys.<x> in app.input.pressed/held` directly (camera.odin
`player_input`, session.odin toggles and the double-tapped jump, session_controls.odin
`edit_controls`, chat.odin `chat_keys`, inventory_ui.odin `inventory_keys` and the over-slot
keys, stats_ui.odin `stats_keys`, dial.odin `dial_keys`, screens.odin `handle_global_keys`,
and M40's two tab keys). `game.Player_Input.move` is already analog (length at most 1,
quantized to 1/127 on the wire and in prediction: no protocol change).

**Platform: gamepads (`platform/`)**

- `client/platform/pad.odin` (all OSes): the shared types and the logic every backend uses.
  - `MAX_PADS :: 4`. A pad has a slot 0..3, stable while it is connected.
  - `Pad_Button :: enum u8 {None, A, B, X, Y, Left_Bumper, Right_Bumper, Left_Trigger,
    Right_Trigger, Back, Start, Left_Stick, Right_Stick, Dpad_Up, Dpad_Down, Dpad_Left,
    Dpad_Right}`, named by place as on an Xbox pad (A is the bottom face button on every pad;
    a Switch pad's bottom button, labelled B, is `A`). `None` is "unbound" in bindings.
    `Left_Trigger`/`Right_Trigger` exist for bindings only: the platform reports triggers as
    axes and the client makes presses of them. No Guide/Home button (the OS and Steam own it).
  - `Pad_Axis :: enum u8 {Left_X, Left_Y, Right_X, Right_Y, Left_Trigger, Right_Trigger}`.
    Sticks -1..1 with y positive up; triggers 0..1. Raw: no dead zone in the platform.
  - `Pad_Family :: enum u8 {Generic, Xbox, PlayStation, Switch, Steam_Deck}`.
  - `Pad_State :: struct {connected: bool, family: Pad_Family, vendor, product: u16,
    buttons: bit_set[Pad_Button], axes: [Pad_Axis]f32}`.
  - Events, added to the `Event` union: `Pad_Connect_Event {pad: u8, connected: bool,
    family: Pad_Family, vendor, product: u16}`, `Pad_Button_Event {pad: u8, button:
    Pad_Button, pressed: bool}`, `Pad_Axis_Event {pad: u8, axis: Pad_Axis, value: f32}`.
  - `Pads :: struct {state, sent: [MAX_PADS]Pad_State, native: Native_Pads}` lives in
    `Window` (`w.pads`). `pads_open(p)`, `pads_poll(p, events: ^[dynamic]Event, deliver:
    bool)`, `pads_close(p)`: each backend implements `native_pads_open/poll/close`, which
    only fill `p.state`; `pads_poll` then diffs `state` against `sent` and appends events
    (`pad_state_diff(old, new, pad, events)`: connect first, then buttons, then axes whose
    value moved more than 1/256; a disconnect sends releases and zeroes first). `window_open`
    calls `pads_open` after `native_open`; `poll_events` and `wait_events` call `pads_poll`
    after `native_poll` with `deliver = w.focused` (unfocused: state kept, nothing sent); on
    focus coming back, `pads_poll` sends every non-rest value again (`sent` is reset to rest
    on focus loss). `window_close` calls `pads_close`.
  - `pad_family(vendor, product: u16, name: string) -> Pad_Family`: Microsoft 0x045e ->
    Xbox; Sony 0x054c -> PlayStation; Nintendo 0x057e with product 0x2009 (Switch Pro) ->
    Switch; Valve 0x28de with product 0x1205 -> Steam_Deck; Valve 0x28de 0x11ff (Steam
    Input's virtual pad) -> Generic; any other whose name contains "X-Box" or "Xbox" (any
    case) -> Xbox; else Generic. Generic is named and drawn as Xbox.
  - `pad_ignored(vendor, product, env_ignore, env_except: string) -> bool`: Steam sets
    `SDL_GAMECONTROLLER_IGNORE_DEVICES` (and `..._EXCEPT`) for games it starts, listing the
    physical pads it already presents as its virtual pad (`0x045E/0x028E,0x054C/0x0CE6`, hex,
    any case, comma separated). We honour both, so a pad is not read twice under Steam.
- Linux, `client/platform/pad_evdev.odin` (pure, all OSes so its tests run everywhere) and
  `client/platform/pad_linux.odin` (syscalls, `core:sys/linux`):
  - Devices: `/dev/input/event*` only (never `js*`), opened `O_RDONLY|O_NONBLOCK|O_CLOEXEC`,
    never grabbed. A device is a pad when its `EV_KEY` bits have `BTN_SOUTH` (0x130) and its
    `EV_ABS` bits have `ABS_X` and `ABS_Y` (`evdev_is_pad(keys: [96]u8, abs: [8]u8)`); this
    rejects keyboards, mice, touchpads and the PlayStation pads' motion and touchpad nodes.
    Not a pad: closed again at once. A fifth pad is ignored with an info line.
  - Permissions as they are: systemd's uaccess rule gives the logged-in seat user an ACL on
    joystick nodes (`ID_INPUT_JOYSTICK`), which covers wired and Bluetooth pads, the Steam
    Deck's own pad and Steam Input's virtual pads; keyboards and mice stay root:input 0660
    and are never needed. A node we cannot open (`EACCES`) is normal: logged once at debug
    level and retried on its next `IN_ATTRIB` (udev sets the ACL a moment after the node
    appears, so the first open usually fails).
  - ioctls (all `_IOC` reads, type 'E'): `EVIOCGBIT(ev, len)` = `(2<<30)|(len<<16)|(0x45<<8)|
    (0x20+ev)` for `EV_KEY` (1, 96 bytes) and `EV_ABS` (3, 8 bytes); `EVIOCGID` 0x80084502
    (bustype, vendor, product, version: u16 each); `EVIOCGNAME(len)` nr 0x06, 64 bytes;
    `EVIOCGKEY(len)` nr 0x18, 96 bytes; `EVIOCGABS(axis)` 0x80184540 + axis (value, minimum,
    maximum, fuzz, flat, resolution: i32 each). `input_event` is 24 bytes (16 of time, u16
    type, u16 code, i32 value); read 64 at a time until `EAGAIN`.
  - Buttons: `BTN_SOUTH` -> A, `BTN_EAST` (0x131) -> B, `BTN_TL`/`BTN_TR` (0x136/0x137) ->
    bumpers, `BTN_SELECT`/`BTN_START`/`BTN_THUMBL`/`BTN_THUMBR` (0x13a/0x13b/0x13d/0x13e) ->
    Back, Start, Left_Stick, Right_Stick, `BTN_DPAD_UP..RIGHT` (0x220..0x223) -> the D-pad.
    0x133 and 0x134 depend on the driver (`Evdev_Layout :: enum {Xpad, Positional}`): xpad
    and xpad-like drivers (Microsoft, Valve, and every vendor not named next) send X as 0x133
    and Y as 0x134; Sony (hid-playstation) and Nintendo (hid-nintendo) follow the kernel's
    positional rule, 0x133 the top button (Y) and 0x134 the left (X).
    `BTN_TL2`/`BTN_TR2` (0x138/0x139, digital triggers: Switch ZL/ZR) set the trigger axes to
    0 or 1.
  - Axes: left stick `ABS_X`/`ABS_Y`; right stick `ABS_RX`/`ABS_RY` (3/4), or, on a device
    without `ABS_RX`, `ABS_Z`/`ABS_RZ` (2/5); triggers `ABS_Z`/`ABS_RZ` when the right stick
    is on RX/RY, else `ABS_BRAKE`/`ABS_GAS` (0x0a left / 0x09 right) when present; D-pad hat
    `ABS_HAT0X`/`ABS_HAT0Y` (0x10/0x11, -1 left/up, +1 right/down) into the D-pad buttons.
    `evdev_axis(value, min, max: i32, flip: bool) -> f32`: sticks `2*(v-min)/(max-min) - 1`,
    clamped, y flipped (evdev's down is positive); triggers `(v-min)/(max-min)` clamped.
  - Frames: values gather into a pending state and become `p.state` on `SYN_REPORT`; after
    `SYN_DROPPED`, everything up to the next `SYN_REPORT` is dropped and the whole state
    re-read with `EVIOCGKEY` and `EVIOCGABS`. Opening reads the whole state the same way, so
    a pad plugged in with a button held reports it. A read error other than `EAGAIN`/`EINTR`
    (`ENODEV` on unplugging) closes the device: disconnected.
  - Hot-plug: `inotify_init1(IN_NONBLOCK|IN_CLOEXEC)` watching `/dev/input` for `IN_CREATE |
    IN_ATTRIB | IN_MOVED_TO | IN_DELETE` (0x100, 0x4, 0x80, 0x200); an `event*` name created,
    changed or moved in is tried if it is not open; deleted, closed. The directory is scanned
    once at open. inotify failing: a warning, the scan still done, no hot-plug.
  - The Steam Deck: in game mode Steam presents its virtual pad (28de:11ff); in desktop mode
    without Steam, recent kernels' hid-steam driver exposes the Deck's own pad (28de:1205,
    xpad layout, named as a Deck). Steam Input on a desktop works the same way (its virtual
    pad, physical pads ignored through the environment above).
- Windows, `client/platform/pad_xinput.odin` (pure, all OSes) and `client/platform/pad_windows.odin`:
  - `xinput1_4.dll` loaded with `core:dynlib` at `pads_open`, else `xinput9_1_0.dll` (both
    ship with Windows); neither: one info line, no pads. Only `XInputGetState` is looked up
    (by name). The `core:sys/windows` xinput procedures (which import `xinput.lib`) are not
    called; its `XINPUT_STATE` type may be used, or our own 16-byte mirror in
    `pad_xinput.odin`, which `xinput_to_state(buttons: u16, lt, rt: u8, lx, ly, rx, ry: i16)
    -> Pad_State` converts (so it is tested on every OS).
  - The four user slots are the pad slots. Connected slots are read every frame; a slot that
    answers `ERROR_DEVICE_NOT_CONNECTED` (1167) is probed again at most every 250 ms, one
    slot per probe (reading an empty slot stalls), so a new pad appears within a second.
  - Buttons by mask: Dpad_Up 0x0001, Down 0x0002, Left 0x0004, Right 0x0008, Start 0x0010,
    Back 0x0020, Left_Stick 0x0040, Right_Stick 0x0080, bumpers 0x0100/0x0200, A 0x1000, B
    0x2000, X 0x4000, Y 0x8000. Sticks `max(v, -32767) / 32767` (XInput's y is already up);
    triggers `/255`. Family Xbox (XInput tells no vendor); a PlayStation pad on Windows is
    read only through Steam Input (it then is an XInput pad).
- macOS, `client/platform/pad_darwin.odin`: the GameController framework through the Objective-C
  runtime (`foreign import "system:GameController.framework"`, and `core:sys/darwin/
  Foundation` for `NS.Array`, `NS.String`, the autorelease pool and the runtime's
  `objc_lookUpClass`; reference `GCControllerDidConnectNotification` once in `pads_open` so
  the framework is linked). Each poll, in an autorelease pool: `[GCController controllers]`;
  controllers are matched to slots by object pointer (retained while in a slot, released on
  leaving); those without `extendedGamepad` are skipped. Read with `intrinsics.objc_send`:
  `buttonA/B/X/Y`, `leftShoulder`, `rightShoulder`, `dpad.up/down/left/right` (`isPressed`),
  `leftTrigger`/`rightTrigger` (`value`), `leftThumbstick`/`rightThumbstick` `xAxis`/`yAxis`
  (`value`, y already up), and when the object `respondsToSelector:` them,
  `leftThumbstickButton`, `rightThumbstickButton`, `buttonMenu` (Start), `buttonOptions`
  (Back). Family from `productCategory`: contains "Xbox" -> Xbox, "DualShock" or "DualSense"
  -> PlayStation, "Switch" or "Pro Controller" or "Joy-Con" -> Switch, else Generic; vendor
  and product 0. The macOS window is not written yet (M1b): this backend is compiled and its
  pure parts tested; running it is a check by hand after M1b. Connection notifications need
  the run loop M1b brings, which is why `controllers` is polled.
- `tools/build/main.odin`: "platform" joins `TEST_PACKAGES`.

**Client: actions (`client/actions.odin`, new)**

- `Action :: enum u8` and its contexts (`Action_Context :: enum u8 {World, Menu}`; World is
  `game_controls(app)` true, Menu anything else: menu screens, overlays that take the
  keyboard or mouse, the loading screen). Keyboard and pad defaults, `-` for none, "fixed"
  for not rebindable:

  | Action | Contexts | Keyboard / mouse | Pad (Xbox names) |
  |---|---|---|---|
  | forward, back, left, right | World | W, S, A, D | left stick (fixed) |
  | look | World | the mouse (fixed) | right stick (fixed) |
  | jump (twice quickly: fly) | World | Space | A |
  | sneak | World | Left Shift | B |
  | sprint | World | Left Control | LS (left stick click) |
  | attack | World | Left Button | RT |
  | use | World | Right Button | LT |
  | pick | World | Middle Button | RS |
  | inventory | World | E | Y |
  | stats (also closes it) | World, Menu | K | View (Back) |
  | drop | World | Q | X |
  | chat | World | T | D-pad Up |
  | command | World | Slash | - (M42: the chat, then `/`) |
  | hotbar_1..5 | World | 1..5 | - (the bumpers cycle) |
  | hotbar_next, hotbar_previous | World | - (the wheel) | RB, LB |
  | pause | World, Menu | Escape (fixed, as now) | Start (fixed) |
  | menu_up, menu_down, menu_left, menu_right | Menu | arrows (fixed) | D-pad and left stick (fixed) |
  | menu_confirm | Menu | Enter, Space (fixed) | A |
  | menu_back | Menu | Escape (fixed) | B |
  | menu_secondary, menu_tertiary | Menu | - | X, Y (used by M42) |
  | tab_previous, tab_next | Menu | Q, E (M40's) | LB, RB |
  | screenshot | World, Menu | F2 | - |
  | fullscreen | World, Menu | F11 | - |

  The keyboard fields keep today's names (`key.forward`, ...: no migration); new ones are
  `key.hotbar_next`, `key.hotbar_previous` (both `unknown`) beside M40's two tab fields
  (named here `tab_previous`/`tab_next`; keep M40's names if they differ). Whatever M40 did
  for dropping over an inventory slot (Q is previous tab in menus now) stays as M40 left it.
- `Action_Info :: struct {contexts: bit_set[Action_Context], label: string, fixed_keys:
  [2]platform.Key, fixed_pad: [2]platform.Pad_Button}` in `@(rodata) ACTION_INFO :=
  [Action]Action_Info`. The rebindable sources are fields: `action_key(b: ^Bindings, a:
  Action) -> ^platform.Key` and `action_pad(p: ^Pad_Bindings, a: Action) ->
  ^platform.Pad_Button`, each one full `switch` (nil: fixed or none), so a new action
  without a decision does not compile.
- `Pad_Bindings` (`client/controls.odin`): one `platform.Pad_Button` field per pad-bindable
  action above (jump, sneak, sprint, attack, use, pick, inventory, stats, drop, chat,
  command, hotbar_next, hotbar_previous, screenshot, menu_confirm, menu_back,
  menu_secondary, menu_tertiary, tab_previous, tab_next), `DEFAULT_PAD_BINDINGS`,
  `PAD_BINDING_VARS` (help "pad: ..."), `pad_bindings_table()` with prefix "pad.";
  `Settings.pad: Pad_Bindings` beside `keys`. Saved as `pad.jump = a` (enum names in lower
  case: `a`, `left_bumper`, `dpad_up`, `none`).
- `Actions :: struct` on `App` (`app.actions`): `context_`, `down`, `pressed`, `released:
  bit_set[Action]`, `latched: bit_set[Action]`, `move: [2]f32` (World, length at most 1),
  `look: [2]f32` (World, pad look in radians per second: yaw, pitch), `nav: bit_set[Action]`
  (menu_up..right this frame, with repeat), `trigger_down: [2]bool`, `device: Device`
  (`enum {Keyboard, Pad}`, the last used), `pad_family: platform.Pad_Family` (of the pad
  used last), and the repeat timers.
- `actions_update(a: ^Actions, input: ^Input_State, settings: ^Settings, ctx:
  Action_Context, typing: bool, dt: f32)`, called in `app_frame` right after
  `input_update`, with `ctx` from `game_controls(app)` and `typing = app.ui.edit.active`:
  - An action is down when any of its sources is held (keys and mouse buttons from
    `input.held`; pad buttons from the merged pad; triggers from `trigger_down`); pressed
    when a source went down this frame (`input.pressed`, the pad's presses, a trigger
    crossing); only actions whose contexts hold `ctx` are down or pressed.
  - Context change: every action whose source is held when the context changes is latched
    and counts as up until all its sources are released (the A that closes a menu does not
    jump; the Y that opens the inventory does not act in it).
  - Typing in a menu (`typing`): keyboard sources of Menu actions other than the fixed ones
    are ignored (q in a search box does not change tabs, k does not close the statistics).
  - The merged pad: buttons of every connected pad together; each stick from the pad whose
    stick is deflected most; triggers the largest. `device` becomes Pad on a pad press or a
    stick or trigger past 0.5, Keyboard on a key or mouse press or the mouse moving more
    than 4 pixels in the frame.
  - Triggers: down at 0.5, up again below 0.4.
  - Sticks: a radial dead zone, `stick_dead_zone` (default 0.15) inside and 0.95 outside
    (`PAD_STICK_OUTER`): magnitude `m` becomes `clamp((m - inner) / (0.95 - inner), 0, 1)`,
    the direction kept (`stick_shape(raw: [2]f32, inner: f32) -> [2]f32`). `stick_swap`
    swaps the two in the world.
  - `move`: the shaped left stick plus the keys' digital vector (W +y, S -y, D +x, A -x),
    then clamped to length 1 (so analog walking is slower, as physics already allows).
  - `look`: the shaped right stick `v`, its magnitude raised to `stick_response` (1, 2 or 3,
    default 2) with the direction kept, then `yaw = -v.x * PAD_YAW_RATE * stick_look_speed`,
    `pitch = v.y * PAD_PITCH_RATE * stick_look_speed`, pitch negated with `stick_invert`.
    `PAD_YAW_RATE :: 4.7` (rad/s, about 270 degrees a second), `PAD_PITCH_RATE :: 3.5` (about
    200). Mouse look is unchanged.
  - `nav` (Menu): arrows give their direction on each press (the OS repeats them); the D-pad
    and the left stick (past 0.5 on its larger axis, released below 0.35) give it once, again
    after 0.4 s held, then every 0.1 s (`NAV_REPEAT_DELAY`, `NAV_REPEAT_INTERVAL`).
- `action_down(a, x)`, `action_pressed(a, x)`, `action_released(a, x)`: the procedures every
  call site uses. `binding_conflicts(keys: ^Bindings, pad: ^Pad_Bindings) -> bit_set[Action]`:
  actions sharing a source (fixed ones included) with another action in a context they
  share, per device.

**Client: Input_State and the call sites**

- `Input_State` gains `pads: [platform.MAX_PADS]platform.Pad_State` (kept from the events),
  `pad_pressed`, `pad_released: bit_set[platform.Pad_Button]` (any pad, this frame) and
  `pad_last: int` (the slot that pressed or moved last); `input_update` handles the three
  pad events (a connect fills family and ids, a disconnect clears the slot; `Focus_Event`
  unfocused clears pads' held state as it clears keys) and logs connects at info
  (`input pad connected slot=0 family=xbox vendor=045e product=028e`).
- `App.injected: [dynamic]platform.Event`: events appended by the `pad` command and the
  pad flight check, put before the frame's platform events in `app_frame` and cleared.
- Every place listed under "What exists" reads actions instead of keys: `player_input(a:
  ^Actions, s: ^Session)` (move from `a.move`, buttons from jump/sneak/sprint down);
  `look_update(v, input, a, settings, dt)` adds `a.look * dt` to yaw and pitch after the
  mouse; `session_update` takes `^Actions` and its sneak/sprint toggles and fly double-tap
  use `action_pressed`; `edit_controls` selects with hotbar_1..5, hotbar_next/previous and
  the wheel, and drop, pick, attack, use as now (drop's held repeat unchanged; "all" stays
  Ctrl with the keyboard); chat, command, inventory, stats and dial keys as now through
  actions; `handle_global_keys`: screenshot and fullscreen through actions; `app.input.escape`
  or `menu_back` pressed -> `escape(app)`; `pause` pressed -> `pause_toggle(app)` (new, in
  overlays.odin: in a world with nothing open, the game menu; with in-game overlays open,
  each closed through its own close path, Options saving if dirty, back to playing;
  elsewhere nothing). M40's tab keys become `tab_previous`/`tab_next` actions in their
  handler, so the bumpers change tabs too.
- While Options listens for a binding, `handle_global_keys` handles only cancelling:
  keyboard Escape or the pad's Start.

**Settings and Options > Controls**

- New settings (Controls; each with its line in M40's tooltip table):
  - `stick_look_speed` f32 0.25..3 step 0.05, default 1, "Stick look speed": "how fast the
    right stick turns the view".
  - `stick_invert` bool Off/On, "Invert stick": "pushing the right stick up looks down".
  - `stick_dead_zone` f32 0.05..0.4 step 0.01, default 0.15, "Stick dead zone": "how far a
    stick moves before it counts; raise it if the view drifts on its own".
  - `stick_response` f32 with choices {1 "Linear", 2 "Curved", 3 "Steep"}, default 2, "Stick
    response": "curved and steep turn slowly near the centre, for fine aiming, and fast at
    the edge".
  - `stick_swap` bool Off/On, "Swap sticks": "move with the right stick, look with the left".
- `settings_load`: lines starting `pad.` go to `pad_bindings_table()` and are reported only
  by it (as `key.` lines are now); `settings_save` writes them after the keys under "#
  Gamepad: buttons by their place, named as on an Xbox pad". An older file has no `pad.`
  or `stick_` lines: defaults, nothing reported. `app_variables` lists the pad table (so
  `set pad.jump x` works in the console).
- Options > Controls: the mouse rows, then the five stick rows, then the bindings as a
  table under headings "In the world", "In menus", "Anywhere": a row per action that has a
  rebindable source, its label, a keyboard button (as now; a fixed key shown as a disabled
  button) and a pad button showing the binding's name for `actions.pad_family`
  (`pad_button_name(family, product, b)`: Xbox and Generic A B X Y LB RB LT RT View Menu LS
  RS; PlayStation Cross Circle Square Triangle L1 R1 L2 R2, Share for the DualShock 4
  (0x05c4, 0x09cc) else Create, Options, L3 R3; Switch B A Y X L R ZL ZR Minus Plus "Left
  Stick" "Right Stick"; Steam Deck A B X Y L1 R1 L2 R2 View Menu L3 R3; D-pad "D-pad Up",
  ...; None "(none)"). Pressing a pad button cell listens for a pad press (any button or a
  trigger crossing, except Start); the dialog says "Press a button for Jump" and "Start or
  Escape: leave it as it is". Conflicts from `binding_conflicts` are framed red on the cell
  of the device in conflict. "Reset Keys" stays (keyboard); "Reset Pad Buttons" beside it.
  `Options_View.listening` becomes `listening: Maybe(Action)` plus `listening_pad: bool`.

**The console and the pad flight check**

- `pad <button> down|up`, `pad <axis> <value>`, `pad connect <family>`, `pad disconnect`
  (dev builds, `base.DEV`): appends the event for slot 0 to `app.injected` (for scripts,
  CI screenshots in M42 and trying without a pad).
- `--check fly_pad` (a row in `CHECKS`: "fly 400 blocks on a synthetic gamepad"): the fly
  check with `Fly_Test.pad = true`. Instead of `s.autopilot` it injects, from `.Lifting`
  on: a `Pad_Connect_Event` (Xbox), then, if not flying, A down and up and down and up on
  four frames in a row (the double tap: two presses two frames apart), then `Left_Y = 1`
  and the left stick button held. While flying it fails if `s.autopilot` is set or, from
  the tenth tick on, the newest predicted input is not `move == {0, 1}` with `.Sprint`
  ("the pad's input did not reach the player"). Everything else (memory, distance, the
  verdict) as the fly check. CI: a step `xvfb-run -a ./build/voxiverse --check fly_pad` in
  the Linux job after the flight step.

**Steps, in order**

1. `client/platform/pad.odin` types, events, `Pads`, the diff and focus rules, `pad_family`,
   `pad_ignored`; stub `native_pads_*` on all three; the `Event` union's new cases handled
   in `input_update`. `platform` in `TEST_PACKAGES`; `client/platform/pad_test.odin`.
2. Linux evdev and inotify; `client/platform/pad_uinput_test.odin` (below); try a real pad if one
   is plugged in (not required).
3. `client/actions.odin`, `Pad_Bindings`, settings and their load/save; move every call site
   to actions; `client/actions_test.odin`. The suite green here before going on.
4. Options > Controls (stick rows, the two-column bindings, pad listening) and its test.
5. XInput (Windows) and GameController (macOS) backends; cross-compile both locally:
   `odin build client -target:windows_amd64 -windows-sdk-root:<any dir> -build-mode:obj`
   and `-target:darwin_arm64 -build-mode:obj`, into an existing directory under build/.
6. The `pad` command, `--check fly_pad`, the CI steps; the whole suite; commit.

If the session runs short, the remainder (M41b) is step 5 and the Options pad column, with
the exit check "both backends build on their OSes in CI; the Options test binds a pad
button"; everything else is M41.

**Tests**

- `client/platform/pad_test.odin`: `pad_family` for each vendor/product row and a name-only Xbox;
  `pad_ignored` with Steam's format (upper and lower case hex, spaces, the EXCEPT list);
  `evdev_is_pad` accepts an xpad, a DualSense and a Switch Pro bit pattern and rejects a
  keyboard, a mouse, a touchpad and a motion-sensor node; the button map for both layouts
  (0x133 is X on 045e, Y on 054c and 057e); `evdev_axis` (min, centre, max, a stick with a
  0..255 range, y flipped, triggers clamped); hats to D-pad presses; `xinput_to_state`
  (each mask bit, -32768 to -1, triggers); `pad_state_diff` (connect before values, small
  axis moves below 1/256 not sent, a disconnect releasing what was held); focus loss sends
  nothing and focus regained resends the held buttons.
- `client/platform/pad_uinput_test.odin` (`#+build linux`): creates a virtual pad through
  `/dev/uinput` (`UI_SET_EVBIT` 0x40045564, `UI_SET_KEYBIT` 0x40045565, `UI_SET_ABSBIT`
  0x40045567, the 1116-byte `uinput_user_dev` with name "Voxiverse Test Pad", vendor
  0x1209 product 0x0001, axes -32768..32767, then `UI_DEV_CREATE` 0x5501, `UI_DEV_DESTROY`
  0x5502), and through a `Pads` of its own (no window) waits, polling every 10 ms for at
  most 2 s each, for the connect, an A press written as `EV_KEY BTN_SOUTH 1` + `SYN_REPORT`,
  `Left_X` near 1 after `ABS_X 32767`, and the disconnect after destroying it. With
  `/dev/uinput` not writable it logs a warning and passes, unless `VX_REQUIRE_UINPUT=1`,
  where it fails. CI's Linux job, before Test: `sudo modprobe uinput; sudo chmod 0666
  /dev/uinput`, a udev rule making that device's node readable (`SUBSYSTEM=="input",
  KERNEL=="event*", ATTRS{id/vendor}=="1209", ATTRS{id/product}=="0001", MODE="0666"` in
  `/etc/udev/rules.d/99-voxiverse-test.rules`, then `sudo udevadm control --reload-rules`),
  and `VX_REQUIRE_UINPUT=1` for the Test step. If the runner's kernel has no uinput, the
  session drops `VX_REQUIRE_UINPUT` from CI, says so in the report, and the hot-plug test
  moves to the checks by hand.
- `client/actions_test.odin`: W held gives `move == {0, 1}`; Q pressed is drop in the world
  and tab_previous in a menu, never both; Space held across Menu -> World does not jump
  until released and pressed again; typing suppresses tab keys but not Escape; stick (0.1,
  0) moves nothing, (0, 0.96) moves at 1, (0.3, 0.4) is in the stick's direction at
  `(0.5 - 0.15) / 0.8`; look at half deflection with response 2 is a quarter of full rate;
  `stick_invert` and `stick_swap`; triggers 0.55 down, 0.45 still down, 0.35 up; W with
  the stick pushed right stays at length 1; synthetic pad events through `input_update`,
  `actions_update` and `player_input` give the quantized move and the Sprint and Jump
  buttons; `device` follows the last key or pad press; every action is reachable on both
  devices (bound, fixed, or named in `PAD_COVERED_BY`/`KEY_COVERED_BY` with its reason:
  hotbar_1..5 by the bumpers, command by chat, screenshot and fullscreen not on pads,
  hotbar_next/previous by the wheel); every field of `Bindings` and `Pad_Bindings` is
  returned by `action_key`/`action_pad` for some action (by reflection);
  `binding_conflicts` marks pad.jump = x (drop's) and not pad.menu_confirm = a (jump's,
  another context); a settings file without `pad.` lines loads with the defaults and no
  problems; `pad.*` and `stick_*` round-trip through save and load.
- `client/menus_test.odin` (Options): the Controls tab shows the stick rows; clicking
  jump's pad cell and injecting an X press binds `pad.jump = x` and marks drop's cell; Start
  while listening leaves it; Reset Pad Buttons restores `DEFAULT_PAD_BINDINGS`; the existing
  keyboard test still passes.

Exit check: the suite green on the three OSes in CI (with the platform package's tests and,
on Linux, the uinput hot-plug test under `VX_REQUIRE_UINPUT=1`); `--check fly_pad` passes
in CI's Linux job; the Windows and macOS backends build in CI on their OSes.

Check by hand (listed in the report): an Xbox pad on Linux wired (xpad) and over Bluetooth;
a DualSense and a Switch Pro on Linux (face buttons by place, triggers, names in Options);
the Steam Deck in game mode and in desktop mode; Steam Input on a desktop (one pad, not two);
plugging and unplugging while playing; an Xbox pad on Windows (and that the executable does
not import any XINPUT DLL at load: `dumpbin /dependents`); macOS after M1b; how look speed,
the curve and the dead zone feel (the defaults are tuned from what the owner reports).

Left out: rumble, gyro, touchpads, the Steam Controller without Steam, remapping per pad
model, more than one local player (all pads drive the one player), raw HID on Windows
(PlayStation and Switch pads there need Steam Input), the old hid-sony mapping on kernels
before hid-playstation, menus with a pad (M42), on-screen text entry (M42).

**What differed from this spec (M41, built):**
- The enum members are `Action.Jump`, `.Tab_Prev` (M40's key field names; the spec's
  `tab_previous` is `Tab_Prev`) with `.None` first; fields stay snake case and
  `action_field(a)` is the lower-cased member name, the same in `Bindings` and `Pad_Bindings`.
  Look is not an action: `Actions.look` is the pad's turning.
- `Pause` has the pad's Start fixed and no fixed key: Escape stays `input.escape` (which opens
  the game menu through `escape`); `pause_toggle` is Start's.
- `binding_conflicts` returns `(key_clash, pad_clash)`; `Binding_Context` and
  `BINDING_CONTEXT` are gone (`ACTION_INFO`'s contexts replace them). `ACTION_INFO` is not
  `@(rodata)` (the compiler refuses the nested bit sets).
- `Options_View.listening` is an `Action` (`.None`: nothing) and `listening_pad` says which
  column, not `Maybe(Action)`. The table's labels come from `ACTION_INFO`.
- The inventory's over-slot keys (a number swaps, the drop key drops) read the keyboard alone
  in any context (`key_action_pressed`, `key_action_down`): the inventory is a Menu context,
  where Drop is not an action.
- A context change latches only what was already held the frame before, so a key pressed in
  the very frame the context flips still counts. Walking is never latched.
- The repeat timer of `nav` restarts at the interval after each repeat (no burst after a hitch).
- `BENCHMARK_SETTINGS` (which checks run with) gained the pad defaults and the stick settings
  (it is a literal, not a copy of the defaults); the `fly_pad` check treats the window as
  focused, as the desktop it runs on may not focus it.
- The `Native_Pads` of Linux needs no `core:sys/linux` ioctl wrapper: `linux.ioctl` with the
  `_IOC` numbers as written. The uinput hot-plug test passes with a warning where the device is
  not writable; I could not run it here (no access to `/dev/uinput`): CI's `modprobe` and udev
  rule are as the spec wrote them and unproven.
- The macOS backend is compiled and its name mapping tested; the framework calls are written
  from the header names and have not run (no macOS window until M1b).

# M42: menus with a controller

The UI moves by navigation events, every menu screen and overlay works with a pad alone,
button prompts follow the device used last, and text is entered on an on-screen keyboard.
This is more than one sitting: it is split here, before it starts, into **M42** (navigation,
prompts, the on-screen keyboard, every menu screen and dialog) and **M42b** (the inventory
overlays and the statistics, which need a slot cursor rather than widget focus). Each has
its own exit check.

**What exists.** `client/ui/ui.odin`: `hot`, `active`, `focused` are separate; `begin_frame` turns
Tab/Shift+Tab and Down/Up into a cyclic `Next`/`Previous` over the top interactive layer's
focusable widgets in drawing order, and Enter/Space into `activate_focus`, unless a text
field is being edited (`ctx.edit.active`); `focus_visible` shows rings once the keyboard is
used; widgets register `Widget{id, rect (clipped), layer, focusable, label}`; `.Modal`
makes lower layers inert. `slider` steps with Left/Right while focused. M41 gives
`app.actions` with `nav` (directions with repeat), `menu_confirm`, `menu_back` (already
wired to `escape`), `menu_secondary`, `menu_tertiary`, `tab_prev`/`tab_next` (wired to
M40's tabs), `pause` (Start: `pause_toggle`), and `device`/`pad_family`/`pad_product`. As M41
built them, the `Action` members are `Menu_Confirm`, `Menu_Back`, `Menu_Secondary`,
`Menu_Tertiary`, `Tab_Prev`, `Tab_Next`, the nav set holds `Menu_Up`..`Menu_Right`, and
`action_pressed(&app.actions, .Menu_Confirm)` is the test; `actions_sync(app)` runs the
update for tests; `key_action_pressed` reads the keyboard alone in any context.

**The navigation model (`ui/`)**

- `ui.Nav :: enum u8 {Up, Down, Left, Right, Confirm, Back, Secondary, Tertiary, Start}`;
  `ui.Input` gains `nav: bit_set[Nav]` (from the pad only: the client fills it from
  `app.actions` in `ui_input`), `nav_scroll: f32` (rows this frame from the right stick in a
  menu: 10 rows a second at full deflection, after the dead zone) and `pad: bool` (the pad
  is the device used last). Keyboard arrows keep arriving as `keys_pressed`; when no text is
  being edited, `begin_frame` adds them to the frame's directions, and Enter/Space to
  Confirm, exactly where today's `Next`/`Previous`/`activate_focus` are made. Tab and
  Shift+Tab keep the cyclic reading order.
- Directional moves (`move_focus` with `Nav` directions): candidates are the focusable
  widgets of the top interactive layer drawn this frame, by their unclipped rects
  (`Widget.full`, new beside the clipped `rect`), so rows of a scrolled panel below its view
  are reachable. For Down, a candidate qualifies when its centre is more than 1 unit below
  the focused one's; its score is the gap from the focused rect's bottom to its top (0 if
  they overlap) plus 2 times the horizontal gap between the two rects (0 if their spans
  overlap) plus 0.05 times the distance between their centres across; the lowest wins, ties
  to the earlier drawn. The same for the other three. No wrapping. `nav_pick(from: Rect,
  candidates: []Rect, dir: Nav) -> int` is that rule alone, exported (the dial grid uses it
  through ordinary widgets; M42b's slot cursor directly).
- Nothing focused on the top layer and a direction or Confirm comes: the first focusable
  widget of that layer is focused (or the one a screen named with `ui.default_focus(ctx)`
  called just before drawing it), and that event does nothing else. With `input.pad` set
  and nothing focused at `end_frame`, the same happens without an event, so a pad user
  always sees a highlighted widget. `focus_visible` turns on with any `nav` and off with a
  mouse press, as now.
- Layers: `ctx.focus_by_layer: [Layer]Id` remembers each layer's focus; when a higher layer
  appears, focus goes to its first widget; when it goes, the lower layer's remembered focus
  comes back if it is still drawn.
- The pointer: after a nav event the mouse is idle (`ctx.pointer_idle`): no `hot`, no hover
  highlight, until the mouse moves more than 2 units or a button is pressed. A stale cursor
  never fights the focus.
- Widgets consume what they use: `ui.consume_nav(ctx, set)` during the frame stops
  `end_frame` moving focus for those directions.
  - `button`: Confirm clicks.
  - `checkbox`: Confirm toggles.
  - `slider`: Left/Right step (from nav or keys) and are consumed while focused; the step
    as now (`step`, or a twentieth of the range).
  - `choice` (new): `ui.choice(ctx, text, index: ^int, names: []string, r) -> bool`, drawn
    "Label: Value" with `<` and `>` marks while focused; a click or Confirm goes to the next
    (wrapping), Left/Right to the previous/next (consumed). `var_widget` uses it for every
    variable with choices (the cycling button today), so Options' choices work by Left and
    Right.
  - `text_input`: pad Confirm (Confirm in `nav`, from the pad) opens the on-screen keyboard
    on it; keyboard typing as now; pad directions move focus away (never consumed by
    editing). Keyboard arrows still edit while it is being edited.
  - `ui.list_nav(ctx, label, area: Rect, count: int, selected: ^int, first: ^int, visible:
    int) -> Interaction` (new): a virtualized list (only its visible rows are drawn) is one
    focusable widget over its area. Focused, Up/Down move `selected` (consumed, except Up
    at row 0 and Down at the last row, which leave the list), `first` follows so the
    selected row is in view, `nav_scroll` and the wheel scroll it, Confirm reports
    `clicked`. The caller draws the rows as now, registering them with `focusable = false`
    for the mouse, and draws the selection; the list draws the focus ring round the
    selected row.
  - `ui.keep_focus_visible(ctx, view: Rect, scroll: ^f32)`: for a panel that draws all its
    rows and clips them (Options' tab body): if the focused widget was drawn inside `view`'s
    clip and its full rect is outside `view`, `scroll` moves by the overflow (seen next
    frame).
- `ui.focused_label(ctx) -> string` (the label of the focused widget; tests navigate by
  it).

**The on-screen keyboard (`client/ui/keyboard.odin`)**

- State in `Context`: `osk: struct {open: bool, target: Id, symbols: bool, shift: bool}`.
  It draws on a new layer `Layer.Keyboard` between `.Modal` and `.Tooltip`; while it was
  drawn last frame every lower layer is inert, as below a modal (`ctx.keyboard_open`
  beside `modal_open`, checked the same way in `interact` and `move_focus`).
- `text_input` whose id is `osk.target` draws it (after itself) and applies its keys to its
  own buffer and `ctx.edit` cursor, whether or not the field has focus (focus is on the
  keys). Above the keys, the text being edited with its cursor, in a panel along the bottom
  of the screen, 10 keys wide, keys 44 units square with the theme's spacing.
- Letters page: `1 2 3 4 5 6 7 8 9 0` / `q w e r t y u i o p` / `a s d f g h j k l -` /
  `z x c v b n m _ . :` / a bottom row Shift, `&123`, Space (four keys wide), Backspace
  (two), Done (two). Symbols page: `! @ # $ % ^ & * ( )` / `- _ = + [ ] { } ; '` /
  `/ \ | ~ < > ? , " #` / `` ` `` then the same bottom row with `abc` for `&123`. Shift
  changes letters to capitals until pressed again. Every character typed is one the font
  has.
- Keys are buttons in the keyboard's id scope, so directional navigation moves between
  them (the bottom row's wide keys too). It opens with the key used last focused (`h` the
  first time). A (Confirm) types the focused key; X (Secondary) is Backspace; Y (Tertiary)
  a space; LB/RB move the text cursor (while `ui.osk_is_open(ctx)`, `menu_actions` sends
  `tab_prev`/`tab_next` to the keyboard as `Nav.Left`/`Nav.Right` with
  `ctx.osk_cursor_move` set, instead of changing tabs); the pad's Left_Stick press is Shift
  while it is open; Start (`Nav.Start`, from `pause` in a menu while it is open) is Done; B
  closes it, the text kept. Done closes it and makes `text_input` return `submitted` (as
  Enter does). Typing on a real keyboard while it is open works (text, Backspace, Enter as
  Done).
- `ui.osk_cancel(ctx) -> bool` closes it (true if it was open); `escape(app)` calls it
  first, after `options_cancel_listening`, so B and Escape close the keyboard before the
  screen.

**Button prompts (`client/prompts.odin`)**

- Glyphs are drawn by code into the UI atlas at start (as item icons are): `Prompt_Shape ::
  enum {Disc, Ring, Cross, Square, Triangle, Bumper_Left, Bumper_Right, Trigger_Left,
  Trigger_Right, Stick, Dpad, Dpad_Up, Dpad_Down, Dpad_Left, Dpad_Right, Menu, View,
  Keycap, Mouse_Left, Mouse_Right, Mouse_Middle}`, each a 64-pixel white shape with
  anti-aliased edges (analytic coverage with 4x4 samples per pixel: discs and rings by
  distance to a centre, the PlayStation symbols as strokes of 5 px, rounded rects for
  bumpers, triggers and keycaps), added with `ui.add_icon` into `App.prompt_icons:
  [Prompt_Shape]ui.Icon` and drawn smoothly with `ui.draw_icon` and the theme's colours as
  tint. Text inside a glyph (A, B, LB, L2, a key's name) is drawn with the font over it.
  Clean, not pixel art (the crunchy rule is for the world).
- `Prompt_Glyph :: struct {shape: Prompt_Shape, text: string}`;
  `prompt_glyph_for(device: Prompt_Device, family: platform.Pad_Family, action: Action,
  settings: ^Settings) -> Prompt_Glyph` from the action's binding (keyboard: a keycap with
  `key_label`, mouse buttons their mouse glyphs; Xbox, Generic and Steam Deck: a disc with
  the letter, LB/RB/LT/RT shapes with their names, LS/RS a stick with L or R, View and Menu
  their shapes, the D-pad its arms; PlayStation: a disc with the cross, circle, square or
  triangle, L1/R1/L2/R2 shapes with their names, Options as Menu's shape, Create/Share as
  View's; Switch: Xbox's shapes with Switch's letters from `pad_button_name`).
- `Prompt_Device :: enum {Keyboard, Xbox, PlayStation}` from the setting `button_prompts`
  (Controls: choices Auto, Keyboard, Xbox, PlayStation; default Auto; tooltip "which
  buttons the hints show: Auto follows whatever you used last"): Auto is Keyboard while
  `actions.device` is Keyboard, else PlayStation for a PlayStation family and Xbox for the
  rest.
- `prompt_bar(app, ctx, items: []Prompt_Item)` (`Prompt_Item :: struct {action: Action,
  text: string}`): glyph and word pairs right-aligned along the bottom edge of the screen,
  20 units high, in the theme's muted text. Every menu screen and overlay listed below calls
  it with its actions (at least Confirm "Select" and Back "Back"; "Tabs" with
  tab_prev/next where there are tabs; the keyboard's extra keys while it is open: X
  "Delete", Y "Space", Start "Done"). M40's Q/E hint beside the tabs becomes the two tab
  glyphs. Each glyph drawn is appended to `app.prompts_shown` (frame-temporary) for tests.

**Every screen (from `client/`), and what it needs beyond the model**

- Title: default focus Singleplayer.
- Singleplayer (`worlds.odin`): the saves list through `list_nav` (focusing it selects the
  row; Confirm on a row plays it, as a double-click does); Play Selected, Create, Edit,
  Delete, Back by direction below it. Create: the name and seed fields (the keyboard),
  Create Save, Cancel. Edit: the name, Open Folder, Save, Cancel. Delete's dialog: default
  focus Cancel.
- Multiplayer (`multiplayer.odin`): the name prompt (keyboard; Done), the servers list
  through `list_nav` (Confirm joins), Join, Direct Connection, Back; Direct Connection: the
  address and password fields, Join, Cancel.
- Options (title and in game): tabs by LB/RB and as focusable buttons; the body by
  direction with `keep_focus_visible` on its scroll; sliders, choices, toggles, text fields
  as above; the bindings table: a row's two cells are buttons side by side (Left/Right
  between them), each listens as M41 made it; Done.
- Characters (`account.odin`): a button per character, the new character's field
  (keyboard), New Character.
- Loading: Cancel focused. Failed: Back focused.
- Game menu (Start opens it, Start or B closes it): Back to Game focused.
- Quit dialog: Cancel focused. Consent dialog: No thanks focused (mashing A never opts in).
- Dial (`dial.odin`): the 40 symbols and Erase and Cancel by direction (they are buttons
  already); X is Erase.
- Chat (`chat.odin`): opened by the pad (chat's D-pad Up), it opens with the keyboard on its
  line; Done sends; B closes the keyboard, B again the chat. The command action on a
  keyboard is unchanged; with a pad, `/` is on the symbols page.
- Not with a pad (developer tools, keyboard and mouse): the console, the F4 tuning panel,
  the F8 audio inspector. M42b: the inventory, creative catalog and chest, and statistics.

**How the UI test drives screens with a pad**

- `client/menus_test.odin` gains a pad harness: `pad_frame(app, events: ..platform.Event)`
  runs the same input path as `app_frame` without GPU or window: `input_update`,
  `actions_update` (context from `game_controls`), `menu_actions(app)` (new, split out of
  `handle_global_keys`: back, pause, tabs, the keyboard's mappings; `app_frame` calls it
  too), `ui_input`, then the screen or overlays as `ui_frame` draws them. Helpers:
  `pad_tap(app, button)` (a press frame and a release frame), `pad_go(app, dir)` (a D-pad
  tap), `pad_focus(t, app, label)` (taps Down, then Up, at most 30 times each, until
  `ui.focused_label` is `label`; fails with what it passed), `pad_type(t, app, text)` (on
  an open keyboard, moves to each key with `nav_pick` over the keys' rects and taps A).
  Every screen test below uses only these: no mouse, no keys, no direct calls to `escape`.
- Pad events come from a connected synthetic pad (a `Pad_Connect_Event` first), family
  Xbox, and once PlayStation for the prompts test.

**Steps, in order**

1. `ui/`: `Nav`, `Widget.full`, directional `move_focus`, default and remembered focus,
   pointer idle, `consume_nav`, `choice`, `list_nav`, `keep_focus_visible`,
   `focused_label`; `client/ui/ui_test.odin` tests. Today's `test_keyboard_focus` changes where it
   relied on Down cycling (Tab still cycles).
2. `client/ui/keyboard.odin` and its tests.
3. `client/`: `ui_input` fills `nav`, `nav_scroll`, `pad`; `menu_actions`; `var_widget` on
   `choice`; each screen's default focus, lists, keep-visible, the chat's keyboard.
4. `client/prompts.odin`, the glyph icons, `button_prompts`, prompt bars on every screen.
5. The pad harness and the screen tests; the CI screenshots below; the suite; commit.

**Tests**

- `client/ui/ui_test.odin`: in a 3x3 grid of buttons, Down/Right/Up/Left land where expected and
  stop at the edges; a column beside a wide button below picks the overlapping one; a
  slider consumes Left/Right and steps, Up still leaves it; a choice cycles both ways; the
  first nav focuses the first widget and does nothing else; `default_focus` wins; a modal
  takes focus and gives it back when closed; pointer idle hides hover until the mouse
  moves; `list_nav` over 50 rows with 8 visible: Down to row 20 scrolls `first` to 13, Up at
  row 0 leaves the list; `keep_focus_visible` scrolls to a row below the view; pad Confirm
  on a text field opens the keyboard, keyboard Enter submits instead.
- `client/ui/keyboard_test.odin`: typing "Pad_1" by nav and A, Backspace by X, Shift, the symbols
  page, Done submits, B closes keeping the text, real typing while open, lower layers inert.
- `client/menus_test.odin`, `test_menus_with_a_pad`: from the title, Singleplayer; the saves
  list (two saves, as the saves test makes them) selected by Down; Create New Save, the name
  typed "Pad" on the keyboard and seen in the field, Cancel; B back to the title;
  Multiplayer: the name typed, Done, Direct Connection, an address "127.0.0.1:1" typed,
  Cancel, B; Options: RB through every tab and LB back, a slider moved by Right, a choice
  changed by Left, the pad cell of jump rebound to X and back; Done; Quit Game, the dialog's
  Cancel by A. With a test session (as the inventory test makes one): Start opens the game
  menu, Options from it and B back, Back to Game; the characters screen chooses a character
  by A and types a new one; the loading screen's Cancel; the failed screen's Back; the
  consent dialog answered No thanks by A; the dial: seven symbols by direction and A, one
  erased by X; the chat opened by D-pad Up, "hi" typed and sent by Start. Each step asserts
  the state the screen tests already assert (screen, mode, settings).
- `test_prompts_follow_device`: on the title, a key press then a frame shows keycap glyphs
  ("Enter", "Esc" in `app.prompts_shown`); a pad press shows the Xbox disc with "A"; a
  PlayStation pad shows the cross; `button_prompts = Keyboard` keeps keycaps after a pad
  press; the glyph icons are all made (none zero-sized).
- CI's Screens step gains one run with the M41 `pad` command: `--exec "pad connect xbox;
  pad dpad_down down; pad dpad_down up; wait 3; screenshot screen_title_pad; screen options
  controls; wait 3; screenshot screen_options_pad; screen worlds create; pad a down; pad a
  up; wait 3; screenshot screen_keyboard; quit"` (screenshots looked at by hand).

Exit check (M42): the suite and CI green; `test_menus_with_a_pad` drives every screen and
dialog listed above with pad events only; `test_prompts_follow_device` switches between
keycap and pad glyphs.

Check by hand: the glyphs' look at GUI scales 1-4 (screenshots); navigating every screen
with a real pad and on the Steam Deck; the keyboard's layout and feel; that the pointer
hides its hover after pad use and comes back with the mouse.

**What differed from this spec (M42, built):**
- The on-screen keyboard's bumper and stick keys are `ui.Input.osk_cursor` (steps) and
  `osk_shift`, filled by `menu_actions` while `ui.osk_is_open`, not `Nav.Left`/`Nav.Right`
  with an `osk_cursor_move` flag (the D-pad's Left and Right stay plain directions between
  the keys). Start is `Nav.Start`, as specced.
- `Actions` gained `nav_pad` (the directions from the pad alone: `nav` also holds the
  keyboard's arrows, which reach the UI as keys) and `pad_acts` (actions pressed by a pad
  button this frame). `menu_actions(app, input)` takes the `ui.Input` and is called from
  `handle_global_keys` (which `app_frame` calls), not beside it.
- `ui`: `Widget.full` and `Widget.clip`; `Layer.Keyboard`; `button(..., id = "")` keeps a
  button's focus as its text changes (the bindings' cells; `choice` does the same by its label);
  `list_nav` takes a `row_h` and reads the wheel over its whole area (the rows over it take
  the mouse's hover); the right stick scrolls without moving the selection; `Nav.Back` is
  produced but nothing reads it (B is `escape`).
- A layer that appears takes focus to its first widget only while the keyboard or a pad is in
  use (a mouse user gets no hidden focus); focus a screen put on the layer itself is kept.
  `keep_focus_visible` acts once for each widget focused and only while the focus is visible,
  so the wheel is not undone.
- `game_controls` is false while the session is Connecting or Choosing: a pad could not
  navigate the characters screen (it was in the World context). The dial's focus goes on to
  the next free symbol when one is taken (a taken symbol's button is disabled, which dropped
  the focus to the first).
- Prompts: `prompt_glyph_for` takes the window first (`key_label` needs it); `Prompt_Item` has
  `also` for the tabs' second glyph; one `prompt_items(app)` decides the bar for whatever is on
  screen and `app_ui` draws it, instead of every screen calling `prompt_bar`; the bar shows
  over the title, Options, saves, multiplayer, failed, characters, loading and over the game
  menu, Options, quit, consent, dial and chat overlays, and while the keyboard is open.
  `prompts_shown` is a fixed array read through `prompts_seen`. The PlayStation face buttons
  are `Cross`/`Ring`/`Square`/`Triangle` drawn over a disc.
- The harness is package-level in `menus_test.odin` (for M42b): `pad_frame` draws the
  overlays only for a playing session (the world needs a GPU), `pad_focus` taps up to 80 times
  each way and a test uses `pad_go` Left/Right where a target is beside the focus (Create
  beside Play Selected), `pad_type` steers by the keys' positions (the same rule `nav_pick`
  gives) and taps the stick press for capitals. The loading screen's Cancel is checked
  focused, not pressed (ending the session needs the GPU). The Start-pressed "Done" on the
  multiplayer name submits it, so there is no separate Done press in the test.
- CI's pad screenshots are in the Linux Screens step (one more run).

Not done: the by-hand checks (the glyphs at GUI scales 1-4, a real pad and the Steam Deck, the
keyboard's feel, the hover hiding after pad use), a Windows or macOS run (CI covers the
build).

# M42b: the inventory and statistics with a controller

- A slot cursor in the inventory overlay (`Inventory_View.cursor: int`, a slot index, or a
  catalog cell as `CURSOR_CATALOG_BASE + item index`), shown and used while
  `actions.device` is Pad, hidden when the mouse moves (mouse play exactly as now).
  Directions move it with `ui.nav_pick` over the rects of every slot drawn (inventory,
  hotbar, equipment, chest) and the visible catalog cells; moving past the catalog's top or
  bottom row scrolls it a row. It opens on the selected hotbar slot.
- On a slot: A is a left click (pick up, put down, swap, merge), X a right click (half, or
  one put down), Y a quick move (shift-click); on a catalog cell A takes a full stack, Y
  opens the keyboard on the search field. The cursor's stack is drawn at the slot cursor
  (offset up and right), the tooltip beside it, the player preview turns toward it. LB/RB
  change tabs (M40); B closes (`inventory_close`, the stack put back). The prompt bar shows
  A Take/Put, X Half/One, Y Move (Search on the catalog), B Close, the tab glyphs.
- The statistics (`stats_ui.odin`): the rows through `ui.list_nav` (A opens or closes a
  group), the search field (keyboard), Previous/Next by direction; View (stats) or B closes.
- Tests: `client/inventory_ui_test.odin`, `test_inventory_with_a_pad`: Y opens it; the
  cursor moved to slot 9 by directions; A picks the stack, directions to 20, A puts it; X
  halves; Y moves to the hotbar; RB to Creative, Y and "dirt" typed, A takes a stack, A
  puts it in a hotbar slot; B closes with the cursor's stack put back; a chest opened by
  the server shows the chest's slots reachable. `test_stats_with_a_pad`: open by View, a
  group opened by A, a search typed, Next page, B closes. Pad events only, through M42's
  harness (package-level in `menus_test.odin`: `rig_make`/`rig_free`, `pad_frame`, `pad_tap`,
  `pad_go`, `pad_focus`, `pad_type`; `pad_frame` draws the overlays of a playing session; M42's
  history entry says how it differs from its spec). `ui.list_nav` takes a `row_h`; the glyph
  pair for the tabs is `Prompt_Item.also`; `prompt_items` in `prompts.odin` decides the bar
  (add the inventory and statistics there).

Exit check (M42b): the suite and CI green; both tests drive their overlays with pad events
only. Check by hand: the inventory with a real pad (reach, how the cursor's stack reads).

Left out (M42 and M42b): dropping from an inventory slot with a pad (drop in the world with
X), drag gestures with a pad (spread, one each, gather), the console, tuning panel and audio
inspector with a pad, haptics, a pad-specific layout of any screen (the layouts stay as they
are; navigation adapts to them), Steam's own keyboard.

What differed: the Y on a catalog cell opens the keyboard after the search field is drawn, so the press is not the keyboard's first key (a space); a pad-mode inventory clears the UI focus each frame (the cursor is the focus: A is not a click on a tab); the statistics' list is one `ui.list_nav` focus (default focus), its scroll now `first`/`selected` ints; `pad_frame` also runs `chest_sync`, `inventory_keys`, `stats_keys`, and `rig_free` frees what the new tests fill. The catalog cursor is the matching list's position, clamped when the search changes.

# M43: the music pipeline (`tools/music`): scores, MIDI, SF2 and the renderer

Split from the old M43 (too big for one sitting): this is the tool and its tests, with a
synthetic soundfont; M43b adds stereo streams to the engine, composes the pieces with the
real piano and commits them. Nothing here is committed besides code and test fixtures.

- **Package and command.** `tools/music/` (package `music_tool`): `score.odin` (parser),
  `notes.odin` (the note list), `midi.odin` (reader and writer), `sf2.odin` (reader),
  `render.odin` (the sampler), `master.odin` (normalize, tails, encode, metadata),
  `main.odin`. `tools/build/main.odin`: `"music"` joins the `run_tool` case and the
  `ensure_miniaudio` list (the tool links `audio/` for the meter, the sinc, the reverb and
  the WAV writer). Usage line: "music  render assets/music/*.score|*.mid to Ogg (--force,
  --wav <dir>, --audition <name>)".
- **The note list** (`notes.odin`), what scores and MIDI both become:
  `Note :: struct {start: u32, length: u32, key: u8, velocity: u8, part: u8}` in ticks at
  `PPQ :: 480` per quarter; `Pedal :: struct {at: u32, part: u8, down: bool}`;
  `Tempo :: struct {at: u32, bpm: f64}`; `Meter :: struct {at: u32, num, den: u8}`;
  `Part :: struct {name: string, bank: u16, program: u8, volume_db: f32, pan: f32}`;
  `Piece :: struct {title: string, parts: [dynamic]Part, notes: [dynamic]Note, pedals,
  tempos, meters, key: string, mode: string, moods: [dynamic]string, place, time, depth,
  worlds: [dynamic]string, loop: bool, seed: u64, humanize_ms: f32, humanize_vel: u8,
  reverb_rt60, reverb_wet: f32, end: u32}`. Notes sorted by (start, part, key).
- **The score format** (`assets/music/<name>.score`, UTF-8, line oriented; `#` starts a
  comment to the end of the line). Grammar:

  ```
  file      = { header-line } { part-block }
  header-line =
      "title" quoted
    | "tempo" number [ "at" position ]          ; quarter notes a minute; first one at 1
    | "meter" int "/" int [ "at" position ]      ; den one of 1 2 4 8 16
    | "key" pitch-class mode                     ; mode: major minor dorian phrygian lydian
                                                 ;       mixolydian aeolian locrian
    | "mood" word { word }                       ; free tags for the director
    | "place" word { word }                      ; biome names or "any"
    | "time" word { word }                       ; day night dawn dusk any
    | "depth" word { word }                      ; surface cave any
    | "worlds" word { word }                     ; home other any
    | "loop" ( "yes" | "no" )                    ; the whole piece loops (no intro)
    | "seed" int
    | "humanize" "timing" number "ms" "velocity" int
    | "reverb" number "s" number                 ; RT60 and wet level 0..1
    | "instrument" word "preset" int ":" int     ; a name for bank:program
  position  = int [ "." int ]                    ; bar, beat (1-based)
  part-block = "part" word word { part-option } NL { music-line }
  part-option = "volume" number "dB" | "pan" number   ; pan -1..1
  music-line = { token } NL
  token     = note | chord | rest | "|" | "|:" | ":|" [ "x" int ]
              | dynamic | "ped" | "unped"
  note      = pitch [ ":" duration ] [ "~" ] [ "!" int ]   ; ~ ties to the next same pitch
  chord     = "[" pitch { pitch } "]" [ ":" duration ] [ "~" ] [ "!" int ]
  rest      = "r" [ ":" duration ]
  pitch     = letter [ "#" | "b" ] octave        ; letter a-g, octave 0-8, c4 = MIDI 60
  duration  = base [ "." ] [ "3" ]               ; base w h q e s t (1/32); "." dotted;
                                                 ; "3" a triplet (two thirds)
  dynamic   = "pp" | "p" | "mp" | "mf" | "f" | "ff"   ; 33 49 64 80 96 112
  ```

  Rules: the second word of `part` is an `instrument` name declared in the header. A
  duration is sticky (a note without one takes the last one in its part; the first
  defaults to `q`); the velocity is the part's dynamic (default `mf`) unless `!n` is given.
  Bar lines are checked: each bar must fill the meter in force exactly, else an error
  `<file>:<line>:<col>: bar 12 has 3.5 beats, the meter 3/4 wants 3`. `|: ... :|` repeats
  its bars once (`:|x3`: three plays in all); repeats do not nest. All parts start at bar 1
  and must have the same length in bars. Errors name file, line and column and stop the
  piece (other pieces still render). Unknown words are errors. Example
  (`tools/music/testdata/phrase.score`, the test fixture):

  ```
  title "Test phrase"
  tempo 80
  meter 3/4
  key d dorian
  mood calm
  place any
  time any
  loop yes
  seed 7
  humanize timing 6 ms velocity 5
  reverb 1.8 s 0.25
  instrument piano preset 0:0

  part right piano pan 0.2
    p | d4:q f4 a4 | [c4 e4 g4]:h. | ped d5:e c5 a4:q~ a4:q unped |
  part left piano volume -3 dB pan -0.2
    p | d3:h. | a2:h. | d3:h r:q |
  ```
- **MIDI** (`midi.odin`): `midi_read(data) -> (Piece, ok)` for format 0 and 1: note on/off
  (velocity 0 is off), set tempo, time signature, key signature (metadata only), program
  change, bank select (CC0), CC7 volume, CC10 pan, CC64 sustain (>= 64 down); other events
  skipped; running status; division in ticks per quarter rescaled to `PPQ` (SMPTE division
  refused). Channel 10 notes are refused with an error (no drum kits in this subset).
  `midi_write(Piece) -> []u8` writes format 1, PPQ 480: track 0 the tempo, meter and key
  map, then a track per part with its bank, program, volume (CC7 from dB), pan (CC10) and
  pedal; unhumanized. `build music --midi <name>` writes `build/music/<name>.mid` so
  MuseScore can open a score.
- **SF2 subset** (`sf2.odin`, SoundFont 2.01): RIFF `sfbk` with `LIST INFO` (`ifil`,
  `INAM` read; the rest skipped), `LIST sdta` (`smpl`, 16-bit; `sm24` ignored), `LIST pdta`
  (`phdr pbag pmod pgen inst ibag imod igen shdr`, every record size checked; the
  terminal records required; every index bounds-checked before use: a damaged file is an
  error, never a crash). Generators read (others ignored): 0-4, 12, 45, 50 (sample address
  offsets and coarse offsets), 8 initialFilterFc, 9 initialFilterQ, 17 pan, 33-38 the
  volume envelope (delay, attack, hold, decay, sustain, release), 39-40
  keynumToVolEnvHold/Decay, 41 instrument, 43 keyRange, 44 velRange, 46 keynum, 47
  velocity, 48 initialAttenuation, 51 coarseTune, 52 fineTune, 53 sampleID, 54
  sampleModes (0 and 2 no loop, 1 loop, 3 loop then release past it), 56 scaleTuning, 57
  exclusiveClass, 58 overridingRootKey. Global zones (first zone without its terminal
  generator) apply to the zones of their preset or instrument; preset generators add to
  instrument ones as the spec says (ranges intersect). Modulators: the `pmod`/`imod`
  lists are skipped; the spec's default velocity-to-attenuation modulator (concave, 960 cB)
  and velocity-to-filter (-2400 cents below velocity 64 linearly, as SF2.01 8.4.2) are
  built in. Units: seconds `= 2^(timecents/1200)`, gain `= 10^(-centibels/200)`, filter Hz
  `= 8.176 * 2^(cents/1200)` (13500 or more: no filter). Stereo samples are two zones
  (left and right links) and render as two mono voices with their pans.
- **The renderer** (`render.odin`): `render(piece, sf, rate = 48000) -> (stereo: []f32)`.
  Per note: find the zones of its part's preset for its key and velocity; per zone a
  voice: the sample read through `audio.sinc_read` at pitch `2^((key - root) * scale/100 +
  coarse + fine/100) / 12) * sample_rate / rate` (cents converted exactly), looping by
  `sampleModes`, a DAHDSR volume envelope (attack linear in amplitude, decay and release
  exponential in dB: -100 dB at the end of release), the zone's low-pass as
  `audio.Svf` (Q from initialFilterQ in cB), pan by constant power, part volume and pan
  applied after. The sustain pedal holds releases until it comes up; an exclusive class cuts
  the other voices of its class (20 ms fade). A note's release ends its voice at -100 dB.
  Humanization: `base.Rng` seeded by `piece.seed`, drawn in note order, moves each note's
  start by uniform ±`humanize_ms` and its velocity by ±`humanize_vel` (clamped 1..127), so
  two renders are identical. The render runs to the last voice's end. Then the engine's
  reverb (`audio.Reverb`, `reverb_set(rt60, 0.3, wet, 0.3)`) is added. All of it is in
  `f64` accumulators where order matters; no threads (determinism).
- **Mastering** (`master.odin`):
  - Loop-aware tail: a piece with `loop yes` is cut at `end` (the last bar's end, in
    frames); everything rendered past it (release and reverb tail) is added onto the
    start, so the file's end flows into its start. A piece with `loop no` keeps its tail
    and is trimmed after the last sample above -70 dBFS, plus 50 ms.
  - Loudness: `audio.Meter` over the stereo render; gain to `MUSIC_LUFS :: -20`
    integrated. If the true peak (`audio.true_peak`) after gain is over -1 dBTP, the gain is
    lowered until it is not and the shortfall is reported (`warning: <name> is 1.4 LU under
    the target to keep its peaks under -1 dBTP`); music is never limited.
  - Encode: `oggenc -Q -q 5 -o <out.ogg> <in.wav>` if `oggenc` is on the PATH, else `ffmpeg
    -v error -y -i <in.wav> -c:a libvorbis -q:a 5 <out.ogg>`; neither: an error naming both.
    The WAV is 24-bit stereo at 48 kHz in `build/music/`.
  - Metadata: `assets/music/<name>.json` beside the Ogg:

    ```json
    {
      "title": "Test phrase",
      "source": "phrase.score",
      "source_sha256": "<hex of the score or MIDI file>",
      "soundfont_sha256": "<hex>",
      "rate": 48000,
      "channels": 2,
      "frames": 172800,
      "seconds": 3.6,
      "loop": true,
      "loop_start": 0,
      "loop_end": 172800,
      "lufs": -20.0,
      "true_peak_db": -3.2,
      "key": "d dorian",
      "tempo": 80,
      "mood": ["calm"],
      "place": ["any"],
      "time": ["any"],
      "depth": ["any"],
      "worlds": ["any"]
    }
    ```

    Written with keys in this order, two-space indents, numbers with at most 3 decimals.
    `frames` is the decoded length the CI test checks.
- **`build music`** renders every `assets/music/*.score` and `*.mid` whose `.json` is
  missing or whose `source_sha256` or `soundfont_sha256` differ (`--force`: all;
  `build music <name>`: one). `--wav <dir>` keeps the float master as WAV. `--audition` is
  M43b's (it needs stereo playback in the engine).
- **The soundfont fetch** (`tools/music/soundfont.odin`), as `tools/build/glslang.odin`
  does it: `SOUNDFONT_URL`, `SOUNDFONT_FILE`, `SOUNDFONT_SHA256` constants, fetched with
  `curl` into `build/tools/soundfont/` once, its archive's SHA-256 checked before use. The
  FreePats Upright Piano KW downloads are `.7z` only
  (`https://freepats.zenvoid.org/Piano/UprightPianoKW/UprightPianoKW-small-SF2-20190703.7z`,
  5.8 MiB; the page says CC0 1.0); GNU tar cannot open 7z, so the tool unpacks with the
  first of `7zz`, `7z`, `7za`, `bsdtar` on the PATH (Windows' and macOS' `tar` are bsdtar)
  and names them when none is found: a dev-tool requirement like `oggenc`. M43 writes the
  code with the URL and leaves `SOUNDFONT_SHA256` to be pinned in M43b after reading the
  license on the page; until it is pinned the fetch refuses ("soundfont hash not pinned").
  `VX_SOUNDFONT=/path/file.sf2` overrides (any SF2).
- **Tests** (`tools/music/music_test.odin`, run by `build test`, which therefore lists
  `tools/music`): a synthetic soundfont written by a test-only `sf2_write` (two
  instruments: a 1-second 440 Hz sine sample looped, and a decaying noise sample; key and
  velocity zones, an envelope, a filter, a stereo pair) so no download is needed.
  - `test_score_parses`: `phrase.score` gives exactly the expected `Note`s (starts,
    lengths in ticks, keys, velocities, the tie merged into one note, the pedal events)
    and the repeat expands; each error case (a short bar, an unknown word, an undeclared
    instrument, nested repeats) gives its message with the right line and column.
  - `test_midi_round_trip`: score -> `midi_write` -> `midi_read` equals the score's note
    list, pedals, tempos and meters exactly; a format-0 file written by hand (bytes in the
    test) reads to its notes; a truncated file and SMPTE division are refused.
  - `test_sf2_reads`: the synthetic font's presets, zones, generators and samples read as
    written; every truncated prefix of it and 1 000 seeded byte flips are refused or read
    without a crash.
  - `test_render_deterministic`: two renders of `phrase.score` are bit-identical; their
    64-bit FNV-1a hash equals `RENDER_GOLDEN :: 0x...` on Linux (the line is checked only
    `when ODIN_OS == .Linux`, as the audio baselines do); on every OS the third-octave
    bands (`audio.third_octaves`) are within 1 dB of `RENDER_BANDS` held in the test.
  - `test_render_pitch_and_envelope`: a single note at the sine sample's root and an octave
    up measure 440 and 880 Hz within 1 cent (zero crossings over 0.5 s); the envelope's
    attack time and the release's -60 dB point are within 2 ms of the generators.
  - `test_master_loops`: a looped render with a long reverb, mastered: the difference
    between the last and first frame is no larger than 1.5 times the largest difference
    between neighbouring frames within 10 ms of either end; integrated loudness -20.0
    within 0.1 LU.
  - `test_json_round_trip`: the metadata writer's output parses with `core:encoding/json`
    to the same values.

Exit check: the suite and CI green (CI runs the tests above; it needs no encoder or
soundfont); locally `build music --wav build/music phrase` with `VX_SOUNDFONT` pointing at
any SF2 writes a WAV and, with an encoder present, an Ogg and its `.json` (not committed);
listening to it is a check by hand.

What differed: `#` starts a comment only where a word would start (inside a word it is a sharp: `f#4`); a chord and a quoted title are one word; a bar line with nothing since the last one (a line's leading `|`) closes nothing; bars are numbered and metered as played (repeats expanded), so `meter ... at <bar>` counts played bars; the velocity-to-attenuation default is `40 log10(127/v)` dB (SF2.01's concave curve, 960 cB at most) and the velocity-to-filter default applies below velocity 64 as written; a left or right sample is hard-panned whatever its pan generator says; the part's pan is a balance (the louder side stays) applied to the zone's constant-power pan; decay and release fall 100 dB in their time (the release passes -60 dB at 0.6 of it, ends at -100 dB, floor 1 ms); the reverb runs 1.7 RT60 past the dry sound; the metadata writes numbers with one to three decimals (the tempo as an integer when whole); the usage line has `--midi` and not `--audition` (M43b's); a MIDI piece has the default header (no tags, `loop no`), MIDI gives no way to set them yet; the example's `frames` and `seconds` were illustrative (the fixture is 3 bars of 3/4 at 80: 6.75 s); the synthetic font's sine sample is 4410 frames at 4410 Hz (440 whole cycles) so the truncation sweep stays quick; `RENDER_BANDS` skips bands both under -60 dB (too faint to hold across OSes); `soundfont_path`, `find_on_path` and the 7z unpack are in `soundfont.odin` and `master.odin`.

# M43b: music in the engine and the first pieces

- **Stereo in the engine** (`audio/`). Music is clean stereo (the locked decisions), and
  streams today average the channels (M32c).
  - `Sound` gains `right: []f32` (nil: mono). `add_sound` accepts it (same length as
    `samples`). `Stream` keeps the file's channels: `channels: u8` (1 or 2), a second ring
    `ring_r` and the mixer's `stage_r`; the decoder de-interleaves into both. A stream with
    one channel behaves exactly as today.
  - `render_voice` reads the right channel through the same interpolation path (same
    position, same step, same kernel choice) when the sound has two, into `buf[2f+1]` with
    `gain[1]`, the left into `buf[2f]` with `gain[0]`; the voice's low-pass gains a second
    `Svf` (`filter_r`). A stereo voice is never panned by `spatial_gain`; music sets
    `gain = {g, g}`.
  - `capture.odin`: `CAPTURE_VERSION :: 4` (the stream header records channels).
  - Tests (`client/audio/stream_test.odin`): `client/audio/testdata/tone.ogg` (440 Hz left, 660 Hz right)
    as a stereo stream gives 440 Hz in the left output and 660 Hz in the right (each other's
    tone at least 60 dB down); a stereo memory sound looped is seamless; the four audio
    baselines' checksums and numbers are unchanged (mono paths untouched); `build bench
    audio` stays under its 5% (its stream becomes stereo).
- **`build music --audition <name>`** opens the default device (`audio.device_open`) with a
  mixer, registers `assets/music/<name>.ogg` as a stereo stream (looping if its `.json`
  says so) and plays it on Music until Enter is pressed; `--from <seconds>` starts later
  (the decoder seeks).
- **The soundfont.** Read the license on
  `https://freepats.zenvoid.org/Piano/acoustic-grand-piano.html` itself (CC0 1.0 for Upright
  Piano KW as of 2026-10-26), pin `SOUNDFONT_SHA256` of the small SF2 archive, and write
  `assets/music/CREDITS.txt`: one block per sound source (`Upright Piano KW, by Gonzalo and
  Roberto, FreePats project, CC0 1.0, https://freepats.zenvoid.org/`, adjusted to the page's
  wording) and one per composer (`Music: Voxiverse, MIT`). Salamander Grand (CC BY 3.0) is
  auditioned only if time is left; it is never committed without its credit line.
- **Compose** (scores in `assets/music/`, written by the assistant: listening is the
  owner's, a check by hand that never blocks, and a first pass is expected to be rewritten
  after it):
  - `title.score`: the title theme, a calm slow piano piece with a gentle arc, about 2
    minutes, `loop yes`, `place any`, `worlds any`, `mood calm`.
  - Four ambient pieces, sparse and modal, 3 to 5 minutes each, `loop no`, each with a
    different mode and register: `meadow.score` (`place plains forest`, `time day dawn`),
    `night.score` (`time night dusk`), `deep.score` (`depth cave`, quieter: `p` and `pp`
    only), `far.score` (`worlds other`, `place any`).
  - Two stingers, `loop no`: `death.score` (5 to 8 s, falling) and `discovery.score` (8 to
    12 s, opening), `mood stinger` (the director never picks a stinger as a track).
  - Rendered by `build music`, committed: each `.ogg`, its `.json` and the score.
- **The credits screen.** The title screen gets a "Credits" button between Options and
  Quit Game; `Screen.Credits` (`client/credits.odin`) shows `assets/music/CREDITS.txt`,
  then the fonts' licence names (JetBrains Mono OFL, Noto Sans Old Turkic OFL), scrolled by
  the wheel, and Back. The text is `#load`ed. `release` packages copy `CREDITS.txt` into
  `licenses/`.
- **The music in the executable.** `client/music_data.odin`: `MUSIC :: [?]Music_File{
  {"title", #load("../assets/music/title.ogg"), #load("../assets/music/title.json",
  string)}, ...}` in a fixed order (title first). Nothing plays it yet (M44).
- **Tests** (`client/music_files_test.odin`, run in CI): every entry of `MUSIC` decodes
  through `audio.add_stream(..., inline = true)` to exactly `frames` frames at `rate`
  (pulling it through a mixer at 48 kHz with `pitch 1`: `alive` ends at `frames`
  ±1 block); its integrated loudness (measured on the decode) is within 1 LU of -20 LUFS;
  a looping one: the jump between its last and first decoded frame is no larger than 1.5
  times the largest neighbour difference within 10 ms of either end; every `.json` parses
  and names a source file that exists; the Oggs together are under `MUSIC_BUDGET :: 24 <<
  20` bytes; every score in `assets/music/` has its Ogg and `.json`.

Exit check: CI green with the committed set; locally `build music --force` from a clean
checkout (with an encoder and 7z or bsdtar) reproduces every `.json` exactly except the
loudness fields within 0.1 LU and `frames` exactly (Vorbis bytes may differ by encoder
version, so the Oggs are not compared byte for byte). Check by hand: listen to every piece
(`build music --audition <name>`) and say what to rewrite.

What differed: the work was not split. `build music` kept its work files in `build/music`, which is the tool's own executable on Linux: they moved to `build/music-out/` (M43's spec and report name the old path). `Capture_Sound` swapped `stream: u32` for `stream: u16` and `channels: u16` (version 4); a stereo memory sound's checksum covers both channels. `add_stream` gained `start` (seconds into the file: the audition's `--from`). `client/audio/testdata/tone.ogg` already was the stereo file. The audio baselines `title_to_world` and `stress` changed (their stream is now stereo, so the Music bus is louder by about 3 LU): re-accepted, and their Darwin and Windows checksums dropped (a missing key is not compared) until CI's logs give the new values. Master loudness: a sparse piano's crest is about 20 dB, so the first renders sat 2 to 4 LU under -20 LUFS with their peaks at -1 dBTP; the scores were rewritten with flat dynamics (`mp`; `deep` `p` and `pp`), a quiet bass an octave higher, a 0.6 reverb wet, arpeggiated pads and denser bells to bring each inside 1 LU (the title's gentle arc is therefore in its melody and chords, not its dynamics). The scores were generated by a throwaway script and committed as scores; the pieces are a first pass. The size: the seven Oggs take 12.4 MB of the 24 MB budget. The soundfont's license was read on its download page: CC0 1.0, the small SF2 build of 2019-07-03, hash pinned. Salamander Grand was not auditioned.

# M44: the music director

- **What exists.** M32 already has the Music and Ambience sliders (`music_volume`,
  `ambience_volume` on Options > Audio, sent by `audio_volumes`), the Music bus, ducks and
  snapshots. M43b put the pieces in `client/music_data.odin`. This milestone adds the
  director, what it needs to know about the place, and the gap option.
- **What the client must know** (two additions to the state model, `common/game/state_kinds.odin`;
  the schema hash changes by itself, `build schema` regenerates the dissector's table, the
  bandwidth baseline is re-accepted):
  - `State_Kind.Place` with `Place :: struct {biome: u8, warmth: i8, wetness: i8}`:
    `biome` is the `worldgen.Biome` ordinal under the player (255: not an Earth world),
    `warmth` and `wetness` the world's `Params.warmth`/`wetness` times 100. The server
    (`server/`, where the player records are put) computes the biome with
    `worldgen.earth_biome` at the player's feet column every 15 ticks and puts the record
    only when it changes. `check_place`: biome < `len(worldgen.Biome)` or 255 (the check
    lives in `game` with a `MAX_BIOMES :: 32` constant and `#assert(len(worldgen.Biome) <=
    game.MAX_BIOMES)` in worldgen), warmth and wetness in -100..100.
  - `Event_Kind.Player_Died` with `Player_Died :: struct {cause: string `net:"max=32"`}`,
    sent to the dying client by `server/health.odin`'s `die` before it lands at the spawn.
    (M53's death screen uses the same event later.)
- **The director** (`client/music.odin`): a pure state machine the app feeds and whose
  actions the app carries out, so tests need no mixer.
  - `Music_Input :: struct {screen: Screen, session: bool, loading: bool, paused: bool,
    playing: bool, biome: u8, time_of_day: f64, depth: f32, world_home: bool, died: bool,
    arrived: bool, explosion: bool}` (`depth`: the column top at the player minus the feet,
    blocks; `arrived`: a gate or travel arrival into a world not seen before this run).
  - `Music_Action :: struct {kind: enum u8 {Play, Fade, Stop}, track: int, voice_slot:
    u8, gain: f32, seconds: f32}`; `director_update(d: ^Music_Director, in: Music_Input,
    dt: f32, out: ^[dynamic]Music_Action)`. The app (`music_apply`) turns them into
    `audio.play` (bus Music, `gain {g, g}`, `fade_in`), `audio.fade_voice`, `audio.stop`;
    `music_alive` tells the director whether its voice still plays (`audio.alive`).
  - State, clock and randomness are the director's own: `clock: f64` (advanced by `dt`, not
    while `paused`), `rng: base.Rng` seeded at app start from the time in the game and from
    a fixed seed in tests.
  - States and their numbers (all in a `Music_Tuning` struct with a variable table, prefix
    `music.`, in the debug variables: tunable from the console in dev builds):
    - **Title** (screen Title, Options, Worlds, Multiplayer, Credits, Failed, no session):
      the title track looped, faded in over `title_fade_in = 2` s, no gaps. Already playing:
      nothing happens on screen changes.
    - **Loading** (a session that is connecting, choosing, or loading): the title fades out
      over `title_fade_out = 3` s; nothing new starts.
    - **World** (playing, loading done): a wait, a track, a wait. The first wait in a
      session is uniform in [`first_min = 30`, `first_max = 90`] s (Constant: 2 s); each
      later one is uniform in the gap option's range: Rare [900, 1800] s, Normal [300, 900] s
      (Minecraft's 5 to 20 minutes, a little shorter), Often [60, 240] s, Constant [2, 10] s.
      A track fades in over `track_fade_in = 4` s and plays to its end (`loop no`); one
      track at a time, never overlapping; the wait starts when the voice is gone.
    - **Picking a track**: candidates are the non-title, non-stinger tracks other than the
      last one played. A track fits a dimension when its list holds `any` or the place's
      value: place = `worldgen.BIOME_NAMES[biome]` (`any` only when biome is 255), time =
      night for time of day in [0, 0.22) or [0.78, 1), dawn [0.22, 0.30), day [0.30, 0.70),
      dusk [0.70, 0.78); depth = cave when `depth >= 8`, else surface; worlds = home or
      other. The score is the number of dimensions fitted by name, not by `any`; tracks that
      fail a dimension are out. The pick is uniform among the highest score; none fits: any
      candidate. Decided when the wait ends, from that moment's place.
    - **In a cave** (depth >= 8 while a track plays): its voice fades to `cave_gain = 0.6`
      over 4 s, and back to 1 when out.
    - **Paused** (`world_paused`): the clock stops (waits do not advance); the music goes
      on under the Paused snapshot (below) and is not restarted on resume.
    - **Stingers**: on `died`, the playing track fades out over 1 s, the death stinger plays
      at gain 1, and the next wait is drawn afresh after it; on `arrived`, the same with the
      discovery stinger. A stinger never interrupts a stinger.
    - **Leaving a world** (back to the title): the track fades out over 2 s, then Title.
  - Layered music (stems that fade by a parameter) is in the API, unused: `Music_Layered ::
    struct {tracks: [4]int, levels: [4]f32}` and `director_set_layers(d, levels)` that
    fades each stem voice to its level over 1 s; one test.
- **Snapshots, composed** (`client/snapshots.odin`): one wanted snapshot per frame from the
  conditions that hold (each a `audio.Snapshot`; gains multiply, cutoffs take the lowest),
  sent with `audio.set_snapshot` only when it changes, over the condition's time:
  `SNAP_PAUSED`: Music 0.5 / 2000 Hz, World 0.3 / 1200 Hz, Player 0.3, Ambience 0.4 /
  1500 Hz, over 0.3 s; `SNAP_LOADING`: World, Player, Ambience 0, over 0.5 s;
  `SNAP_DEATH`: World 0.3 / 800 Hz, Player 0.3, Ambience 0.3, held 4 s after a death, then
  released over 2 s. M56b adds Underwater and Lava to the same function.
- **Ducking**: duck 0 is Effects -> Music, `threshold 0.25` (linear peak, about -12 dBFS),
  `amount 0.6`, `attack 0.02` s, `release 1.0` s, set at `audio_init`. (Duck 1 is left for
  M58; 2 and 3 free.)
- **The gap option.** `Settings.music_gap: i32` (0 Rare, 1 Normal, 2 Often, 3 Constant;
  default 1), a choice in Options > Audio after Ambience, with help "How often music plays
  in a world: Rare, Normal, Often, or Constant (one piece after another)."
- **Baselines.** `client/audio/baseline.odin`'s `baseline_format` keeps another OS's checksum from
  the old file only when this OS's checksum is unchanged (a changed sound drops the other
  OSes' lines; they come back from CI's log as in M32f), so a later accept can never leave
  a stale checksum that fails on another OS. A new scenario `music_session` in
  `Audio_Scenario` (and in `tools/build`'s `--accept` list): 150 s through the real director
  and the committed music: title for 40 s, a click on UI, loading 5 s, a world with Constant
  gap where a track starts, an explosion at 100 s (the duck), a pause from 120 to 130 s.
  Its numbers are stored as the others; the test also asserts Music's integrated loudness
  is no more than `MUSIC_OVER_EFFECTS_LU :: 3` above Effects'.
- **Tests** (`client/music_test.odin`, injected clock and seed):
  - `test_title_loops_then_fades`: the title plays with no gap over 10 minutes of `dt`;
    entering Loading fades it over 3 s; no track starts while loading.
  - `test_world_waits`: over 1 000 draws per gap setting, every wait is within its range
    and the first within [30, 90] s; tracks never overlap (at most one track voice alive at
    any step); no track twice in a row.
  - `test_tracks_fit_the_place`: for each biome, time and depth the pick is among the
    best-fitting tracks of a test track list (names and tags given in the test, not the
    committed set).
  - `test_pause_keeps_position`: paused for 60 s, the wait left is unchanged and the voice
    was neither stopped nor restarted.
  - `test_stingers`: a death fades the track and plays the stinger once; an arrival into a
    seen address does not.
  - `test_duck_under_explosion`: in a mixer, a looping track on Music and a full-scale
    effect on World: Music's level falls to 0.6 within 50 ms and returns within 1.2 s.
  - `test_music_hour_golden`: a scripted hour (title 2 min, then a world: day, a walk into
    a cave at 20 min, night at 35 min, a death at 40 min, a gate arrival at 50 min, back to
    the title at 58 min) gives the decision list (`<seconds> <action> <track> <gain>` per
    line) equal to `assets/baselines/audio/music_hour.decisions`; `build audio --accept
    music_hour` rewrites it.
  - `test_music_gap_option` (`client/menus_test.odin`): Options > Audio cycles the option
    through its four values and the settings text written keeps it.
  - `test_place_record`: the server puts `Place` with the right biome for a player standing
    in a desert of the test seed, and only when it changes; `check_place` refuses 254 and
    warmth 101.

Exit check: the tests and CI green; `build audio --wav build/audio music_session` writes
the session's WAV (checked by hand: how it sounds; listed in the report); the title-screen
screenshot step in CI is unchanged.

What differed: the work was not split. `Music_Input` has a `gap` field (the gap option has to reach the pure director) and `director_set_layers` takes the action list (`out`) like `director_update`. The director reads each track's tags from `Music_Track`, parsed from the committed `.json` into an arena (`music_tracks`). "Home" is the world the session joined in (the client has no universe seed): `Session.home`, set at Welcome; `arrived` is a counted travel into an address not in the run's `seen` list. `explosion` is in `Music_Input` but unused by the director (the mixer's duck answers explosions); a blast near the player ducks the Music bus through duck 0. The duck's release is an exponential time constant of `release`, so the test asks for 85% of the level back 1.2 s after the effect and at most 65% 50 ms into it, not 100% and 60%. `Music_Tuning` is console-reachable (`music.*`) in all builds, not dev builds only. The Music slider's default fell from 1 to 0.25: with the pieces at -20 LUFS and the effects as quiet as they are, `MUSIC_OVER_EFFECTS_LU` (3) holds in `music_session` only at about -12 dB. `build audio` also takes a scenario name alone (`build audio --wav build/audio music_session`) and runs `music_hour` with the baselines. A death or an arrival while a stinger plays is ignored, not queued; the stingers are found by the track's name (`death`, `discovery`).


# M45: the edit journal with provenance

**Why.** The foundation arc's "truth" freedom stands on this: a bad script's changes are
undone from the journal (threat model), M52 enforces capabilities and budgets "at one
point" of this pipeline, M54's revert "restores the world hash", and moderators need
CoreProtect-style rollbacks before strangers share a server. The survey for this section
found:

- Blocks change in 20 places, through two low-level writers: `chunks_set_block`
  (`server/chunks.odin`, called only by `set_block` in `server/changes.odin`) and
  `game.chunk_set` (called by `edit_chunk` in `server/edits.odin`, the bulk path).
  Callers of `set_block`: `apply_edit` (hand break and place, then `.Farmland_Moist` after
  tilling) in `actions.odin`; four in `liquids.odin` (`updates_run`'s flow and dry-up);
  three in `gates.odin` (`gate_blocks`, `set_if`); `graze_eat` in `entities.odin`;
  `plant_check` in `plants.odin`; six in `random_ticks.odin`. Callers of `bulk_edit`:
  `bulk_notice` (`/fill`, `/replace`, `/sphere`, and `/setblock`, which is a one-block
  fill) in `admin.odin`; `structure_paste` in `structures.odin`; `explode` in
  `entities.odin` (rockets, through `entities_tick`'s blasts, and `explode_by` in
  `call.odin`, used by tests). Nothing records who caused any of them: `Changes.blocks`
  keeps a client index only to skip telling the editor again.
- Derived changes happen later and elsewhere: water woken by an edit flows ticks later
  from `w.updates` (an `Update` is `{due, pos}`, deduplicated by position), a plant above
  breaks inside `set_block`, a rocket explodes seconds after `fire`. A rollback of a
  griefer that left the water they poured would not restore the world.
- `regen` remakes unmodified chunks from changed generator parameters: not an edit, but
  it changes what a replay from the generator would produce.
- `s.tick` restarts at 0 every run, so nothing gives a time that survives a restart.
- 47 call sites in tests call `set_block`, `bulk_edit` or `explode` directly.

**Scope.** The journal covers the voxel field: every block a world's state changes,
directly or as a consequence. Entities (M50), container contents (block entities, M48)
and inventories (M31's ledger) are not journaled here; those milestones route their
changes through this pipeline's `admit` and journal when they rewrite those systems.
World rules, the clock and generator parameters get marker records only (below).

**Design.**

*Provenance.* `common/game/journal.odin` (shared, so tools can read journals) holds:

- `Actor_Kind :: enum u8 {World, Character, Script}`. `World` is the world itself
  (liquids from natural water, random ticks, gates, grazing); `Character` a character by
  name; `Script` is reserved for M52 (a `<pack>:<script>` id).
- `System :: enum u8` (append-only, like `Reason`): `Hand` (break, place), `Till` (the
  hoe, and the moist farmland after it), `Command` (`/fill`, `/replace`, `/sphere`,
  `/setblock`), `Structure` (paste), `Explosion`, `Liquid`, `Random_Tick`, `Support` (a
  plant lost its footing), `Gate`, `Graze`, `Rollback`, `Undo`, `Redo`.
- An **action** is one cause: `Action :: struct {id: u32, age: u64, actor: u32, system:
  System, bypass: bool, command: string}` (`command` capped at `MAX_ACTION_COMMAND :: 256`
  bytes, the full command text for `Command`, `Structure`, `Rollback`, `Undo`, `Redo`;
  empty otherwise). `id` counts from 1 per world across restarts (0 is "none"); `actor`
  indexes the world journal's actor table (0: the world); `bypass` is whether the actor
  may edit protected regions, resolved once when the action is made.
- An **entry** is one block changed: `Entry :: struct {pos: game.Block_Pos, old, new:
  game.Block, action: u32, how: System, _: [3]u8, age: u64}`, 32 bytes. `how` is the
  mechanism of this change, which differs from the action's system for consequences
  (water poured by `/setblock` flows as `how = .Liquid` under the `Command` action).
- **Age** is the universe's tick count across runs: `Server.age_base` is read from
  `universe.cfg`'s new `age = N` (0 if absent), `age(s) = s.age_base + s.tick`, and `save`
  writes it. Rollback times are in age ticks (`10m` is 18 000), never the wall clock, so
  they are deterministic. A wall-clock time is kept in the disk records for people only.

*The pipeline* (`server/journal.odin`, `server/changes.odin`, `server/edits.odin`). There is
one way blocks change, and it takes a cause:

- `Act :: struct {action: Action_Id, how: game.System}` (`Action_Id :: distinct u32`).
- `set_block(w, p, b, act: Act, by: ^Client = nil) -> bool` and `bulk_edit(w, e, act) ->
  (changed: int, result: Bulk_Result)` gain the required `act` parameter. Making it
  required is deliberate: every call site fails to compile until it says its cause.
- `action_begin(w, actor: Actor, system, command := "") -> Action_Id` makes an action.
  `Actor :: struct {kind: game.Actor_Kind, name: string, bypass: bool}`;
  `actor_of(s, c) -> Actor` is a client's character with `bypass = allowed(s, c,
  "world.protect.bypass")`.
- `action_world(w, system) -> Action_Id`: the world's own action for that system in this
  tick, made on first use and cached in `w.journal.tick_actions[System]` (cleared each
  tick), so random ticks and flows do not make an action per block.
- Inside both, per block: `admit(w, act, p) -> Admit` (below), then the write, then
  `journal_entry(w, act, p, old, new)`. Nothing else may call `chunks_set_block` or
  `game.chunk_set` on server chunks.

How each mutation path gets its action:

| Path | Action | `how` |
|---|---|---|
| `apply_edit` (break, place) | `action_begin(w, actor_of(s, c), .Hand)` per edit | `Hand` |
| `apply_edit` tilling, then moist farmland | one `action_begin(..., .Till)` | `Till` |
| `bulk_notice` (fill, replace, sphere, setblock) | `action_begin(w, actor_of(s, c), .Command, c.command)` | `Command` |
| `structure_paste` | `action_begin(..., .Structure, c.command)`, passed in | `Structure` |
| `fire` (rocket) | `action_begin(w, actor_of(s, c), .Explosion)` stored in the new `Entity.action` | |
| `explode(w, center, radius, action)` | the rocket's `action`; `explode_by` makes one for the seat's character | `Explosion` |
| `plant_check(w, p, action)` | the action of the change under it | `Support` |
| `wake_water(w, p, action)`, `schedule(..., action)` | stored in the new `Update.action` (an update already queued keeps its own) | |
| `updates_run` flow | `Update.action`, or `action_world(w, .Liquid)` when 0 (woken by a chunk loading) | `Liquid` |
| `random_ticks` | `action_world(w, .Random_Tick)` | `Random_Tick` |
| `gate_blocks`, `set_if` | `action_world(w, .Gate)` | `Gate` |
| `graze_eat` | `action_world(w, .Graze)` | `Graze` |
| rollback, undo, redo | `action_begin(w, actor_of(s, c), .Rollback/.Undo/.Redo, c.command)` | same |

- `Client.command: string` holds the text of the command `admin` is running (set around
  `cmd.run`, "" otherwise), so the command's action records it.
- Consequences inherit their cause: a plant that breaks under a hand edit, the water a
  `/setblock water` releases and everything it floods carry that action. That is what
  makes "roll back what mallory did" restore the water too.
- `Entity.action: u32` and `Update.action: u32` are hashed state (M38's walker picks them
  up), so the Entities and Liquids sections' values change once.
- `chunk loading` (`request_chunk`, `chunks_collect`), generation and `regen` are not
  edits. `set_worldgen` writes a `Params` marker record (below) so a replay refuses to
  cross it.
- **The lint**: `build check` (`tools/build/determinism.odin`, a second rule list) fails on
  `chunks_set_block(` or `game.chunk_set(` in a non-test file of `server/` other than
  `server/chunks.odin`, `server/changes.odin` and `server/edits.odin`:
  `server/x.odin:12: block write outside the edit pipeline: use set_block or bulk_edit with
  an Act (docs/journal.md)`. Tests are exempt (the replay test bypasses it on purpose).

*Admission: the one enforcement point.* `admit(w, act, p) -> Admit` with `Admit :: enum u8
{Yes, Protected}`. It is the only place a block change can be refused for who caused it.
M45 checks region protection (below). M52 adds `Over_Budget` and `No_Capability` here
(a script actor's capability for the region and its per-tick block quota) and nowhere
else; the action carries the actor, so the check needs nothing more. Bulk edits call
`admit_box(w, act, lo, hi)` once, which returns the protections overlapping the box that
the actor may not edit (none: every block is admitted without a per-block check; a world
with no protections returns at once). A refused change:

- a hand edit: `Edit_Result` not accepted (the client rolls back its prediction) and the
  notice `&cThis place is protected (<name>)`, at most once a second per player;
- a bulk edit: the protected blocks are skipped; the notice says `fill: 120 blocks
  changed, 36 protected`;
- a consequence (water, a plant, a blast): left as it is (water stops at the edge).

Count of entries per tick and per action (`action.entries`) is kept for M52's quotas and
for `/history`.

*Region protection.* `World.protections: [dynamic]Protection` (`{name: string, box: Box,
members: [dynamic]string}`), at most `MAX_PROTECTIONS :: 256` per world, names 1-32 of
`[a-z0-9_-]`. A change inside a protection is admitted if the action's actor is `World`,
has `bypass`, or is a member by character name. Saved in `worlds/<address>/protections.cfg`
(`protect <name> <x1> <y1> <z1> <x2> <y2> <z2> [member ...]`, one per line), written
through `write_atomically` when changed and at save. Hashed in the new `Journal` hash
section (sorted by name). Commands (node `world.protect`): `/protect add <name> [x1 y1 z1
x2 y2 z2]` (the selection if no coordinates), `/protect remove <name>`, `/protect list`,
`/protect member add|remove <name> <character>`.

*The journal in memory* (`Journal`, a field of `World`; allocated in the world's arena
except where noted):

- `entries: []Entry`, a ring of `JOURNAL_MEMORY :: 1 << 18` entries (8 MiB) and `head: u64`
  (entries ever appended this session). `Config.journal_memory` overrides it (tests).
- `actions: [dynamic]Action` (heap) holding ids `actions_base ..< next_action`. Every 300
  ticks `actions_base` advances to the smallest action id still referenced by a ring
  entry, a queued update or a live entity (a scan, at most ~1 ms), and the older ones are
  freed. An id below `actions_base` met later resolves to `action_world(w, how)` before it
  is written, so memory and disk always agree.
- `actors: [dynamic]Actor_Record` (heap; index 0 the world) and `actor_of: map[string]u32`
  for lookup. Bounded by the characters and scripts that edited this world this session.
- `undo: map[u32]Undo_Stacks` by actor: the last `UNDO_DEPTH :: 32` action ids with at least
  one entry (`done`), and `redo`. An action is pushed on `done` when its first entry is
  appended; a new action of that actor clears its `redo`.
- `tick_hash: game.Hasher`: on stepped servers every appended entry and every action made
  is folded in at append time; `Hash_Section.Journal` (added last) returns it and resets
  it, together with the protections. So the side-by-side determinism session checks the
  journal too.
- `out: game.Writer` (heap): records encoded at append time, not yet written to disk.

*The journal on disk.* Per world, `worlds/<address>/journal/`, segment files
`00000001.vxj`, `00000002.vxj`, ... (eight decimal digits, the segment's sequence). A
world with no save directory keeps the memory ring only. A segment ends at
`JOURNAL_SEGMENT_BYTES :: 4 << 20` (`Config.journal_segment_bytes` for tests), when the
world closes, and at server start a new one is begun. Format (`common/game/journal.odin`, with
`game.Writer`'s varints):

```
header:  "VXJN"  u32 format (1)  u32 seq  u64 first_age  u8 flags (bit 0: compacted)  u32 crc32(header)
records: u8 type  varint length  payload[length]  u32 crc32(type, length, payload)
  1 Tick     varint64 age  i64 unix_ms            (wall clock: for people, never state)
  2 Actor    varint index  u8 kind  varint len  name (<= 64 bytes)
  3 Action   varint id  varint actor  u8 system  varint64 age  u8 bypass  varint len  command (<= 256)
  4 Changes  svarint cx cy cz  varint count (1..4096)
             count x { varint local index (0..4095)  varint old  varint new  svarint action delta  u8 how }
  5 Save     varint64 age                          (the world was saved here)
  6 Params   varint64 age                          (generator parameters changed)
```

- Within a segment, an actor and an action are declared before their first use (the
  writer tracks the segment each was last declared in), so every segment reads alone.
  Actor indices are per segment.
- A tick's entries are grouped by chunk into `Changes` records, in the order appended.
  The action delta is against the previous change in the record (the first against 0).
- `journal_flush(w)` writes `out` to the open segment (an append) at the end of the tick
  when `out` holds 64 KiB, every `JOURNAL_FLUSH_TICKS :: 30` ticks, on save and on close.
- Readers (`journal_read_segment(data, visit)`) check the header and every record's CRC
  and stop at the first bad or short record (a torn tail), reporting its offset.
- **Consistency with the save.** `world_save` flushes the journal and appends a `Save`
  record, then writes `world.cfg` with `journal.segment = <seq>`, `journal.offset =
  <bytes>`, `journal.next_action = <id>`. When a world starts, segments after the recorded
  one are deleted and the recorded one is truncated to the offset (`os.truncate`; a
  shorter file is truncated at its last good record, logged at warn), so the journal never
  describes edits the loaded regions do not have. (Edits since the last save are lost on
  a crash, as today; M46 makes the save and the journal end atomic together.) A save from
  before M45 has no journal keys and starts an empty journal.

*Compaction and retention* (in `world_save`, at most one segment per save):

- A closed segment whose newest age is older than `JOURNAL_DETAIL :: 108_000` ticks (one
  hour) is rewritten once as compacted: per (position, action), one entry with the first
  `old`, the last `new`, the last age and `how`; entries whose `old == new` dropped; the
  declarations it still needs kept. Written to `<seq>.vxj.tmp`, then renamed over. A
  rollback over compacted history gives the same net result; only the time resolution
  within the segment's span is lost.
- Segments whose newest age is older than `JOURNAL_KEEP :: 7 * 24 * 108_000` ticks, then the
  oldest while the directory is over `JOURNAL_MAX_BYTES :: 256 << 20`, are deleted.

*Rollback* (`server/rollback.odin`).

- Syntax (node `world.rollback`; time is `duration_parse`'s form, `90s`, `10m`, `2h`, `1d`,
  converted to age ticks):
  - `/rollback player <name> <time> [radius <n> | sel | world]` (default `world`);
  - `/rollback system <system> <time> [radius <n> | sel | world]` (system by its lower-case
    name: `liquid`, `explosion`, ...; default `world`);
  - `/rollback area <time> [radius <n> | sel]` (every cause; default `sel`);
  - `/rollback status`, `/rollback cancel`.
  `radius n` (1..256) is a box around the caller's block. A time past what is retained is
  clamped, and said.
- A filter: `{actor: Maybe(string), system: Maybe(System) (matched against how), action:
  Action_Id (undo and redo), since: u64 (age), box: Maybe(Box)}`.
- **What it restores.** For each position, the entries in the window are walked from the
  newest: if the newest matches the filter, the position will be restored to the `old` of
  the oldest entry in the unbroken run of matching entries from the newest; a
  non-matching entry ends the run. So a rollback never overwrites a later change by
  someone else; such positions are counted as `kept`. `expect` is the newest matching
  entry's `new`.
- **A job, over ticks.** One rollback per world at a time (`w.rollback`). At its start the
  journal is flushed and every queued update whose action matches the filter is cancelled
  (the griefer's water stops flowing). Then:
  - **scan**: a world with a save directory reads its segments from the newest back to the
    first whose `first_age` is before `since`, one segment per tick (memory-only worlds scan
    the ring, 131 072 entries a tick). The plan is a `map[Block_Pos]Plan` in a heap
    allocator owned by the job.
  - **catch up**: before each apply tick, entries appended since the scan began are folded
    in oldest-first (a matching entry extends or starts a run, a non-matching one ends it),
    so water that moved meanwhile is not left behind.
  - **apply**: positions sorted by chunk, then by block (deterministic), up to
    `ROLLBACK_APPLY_PER_TICK :: 4096` a tick, each `set_block(w, p, restore, {rollback,
    .Rollback})` if the block is still `expect` (else `kept`). A chunk that is not loaded
    is loaded from the save (`load_region`; it is in `w.saved`, since every journaled chunk
    was edited), at most 16 a tick and only while 64 pool slots are free; once its
    positions are done, a chunk the rollback loaded that nobody wants is kept
    (`keep_edits`) and unloaded. A position whose chunk cannot be found is `missing`
    (logged).
  - progress every 5 s and at the end, to the caller and the log: `Rollback done (action
    812): 12345 restored, 12 kept (changed by others since), 0 missing`.
- What it does not restore: dropped items and spilled chest contents stay where they are
  (a restored chest is empty; breaking one by rollback spills it), so the ledger stays
  balanced with no new reason; entities; inventories.

*Undo and redo* (node `world.edit.undo`; not in the `default` or `mod` roles: undoing a
broken block keeps its drop).

- `/undo [n]` (1..32, default 1) undoes the caller's own last n actions, newest first: each
  is a rollback with the filter `action = id`, over the memory ring, as an `Undo` action.
  Up to 4096 entries it applies in the same tick; more becomes a rollback job.
- `/redo [n]` rolls back the `Undo` action (filter `action = undo id`), as a `Redo` action:
  the restored blocks return to what the undone action made, with the same rule for
  others' later changes.
- An action whose first entry has left the ring (`head - first_entry > len(entries)`) is
  "too old to undo; use /rollback". Undo stacks do not survive a restart.

*History.* `/history <x y z>` (node `world.rollback`; `~` works) lists the last 8 changes
at that block from the ring, newest first: `3m ago mallory hand: planks -> air (action
812)`.

*Replay onto a snapshot* (`server/replay.odin`).

- `journal_replay(w, snapshot_dir: string, since: u64) -> Replay_Result`:
  - flushes the journal and reads the entries with `age > since` (the ring when the world
    has no save directory);
  - for each chunk they touch, starts from the snapshot's block of that chunk: the region
    in `snapshot_dir/worlds/<address>/regions/` (`""`: none), else the generator's
    (`worldgen.generate` with `w.generator`, `w.seed` and `w.params`, a cache of its own);
  - applies every entry in order, checking `old` against what the replay holds;
  - hashes the chunks sorted (`game.hash_chunk`) and compares with the live world's same
    chunks (loaded, or decoded from `w.saved`).
- `Replay_Result {entries, chunks: int, live, replayed: u64, problem: string}`. The first
  `old` that does not match is the problem: `replay: entry 1234 at (12, 64, -3) action 812
  (hand): expected old stone, found dirt`. That is a write that bypassed the pipeline. A
  final difference names the first differing chunk and block. A `Params` record in the
  interval refuses: `generator parameters changed at age N: replay from after it`.
- Consequences are journaled like any change, so replay applies `new` values only: no
  water, plant or column logic runs.

*Cost, and how it is measured.* `Config.journal_timed` (tests only) makes `journal_entry`,
`action_begin` and `journal_flush` add their time (`time.tick_now` around each) to
`w.journal.cost_ns`; off, they cost nothing more. The budget, checked optimized in CI:
the journal is at most 5% of the tick time summed over the cost scenario and at most
0.5 ms in any tick's mean over the run.

**The order of the steps** (each leaves the suite passing):

1. `common/game/journal.odin`: `Actor_Kind`, `System`, the record encoders and the segment reader,
   with their tests.
2. `server/journal.odin`: `Journal`, actions, actors, the ring, `Act` and `action_begin`
   / `action_world`, age, `Hash_Section.Journal`; `set_block` and `bulk_edit` take `Act`
   and every call site in the table (and the 47 in tests) says its cause; `Entity.action`,
   `Update.action`, `Client.command`; `admit` returning `Yes`. The lint. Then the bandwidth
   baselines are written again (`-define:VX_BANDWIDTH_ACCEPT=true`): the root lines change
   because the hashed state did, the byte lines must not grow (the journal sends nothing).
3. The segments: flush, `Save` and `Params` records, `world.cfg`'s journal keys, truncation
   on start, `universe.cfg`'s `age`.
4. Replay and its tests.
5. Rollback (planner, job, command), `/history`, undo and redo.
6. The cost test and its CI step.
7. Protection: `admit`, `protections.cfg`, `/protect`.
8. Compaction and retention.
9. `docs/journal.md`: the pipeline rule, the record format, what rollback restores.

If the session must split, the remainder is **M45b: steps 7 and 8**, with
`test_protection_refuses` and `test_journal_compacts` as its exit check (`admit` stays the
always-`Yes` hook in M45).

**Left out:**

- Journaling entities, container contents and inventories (M48, M50; M52 routes scripts'
  effects).
- Removing a rolled-back break's drops, or a rollback's items through the ledger.
- The journal as a write-ahead log (edits since the last save survive a crash): not
  planned; M46 makes the save atomic instead.
- Rollback previews, inspection by clicking a block, telemetry kinds for rollbacks.
- Undo across restarts; undo for scripts (M52).
- Rolling back rules, the clock or generator parameters.

**Tests:**

- `common/game/journal_test.odin`: every record type round-trips; a segment cut at every byte
  reads up to its last whole record and reports the offset; a flipped bit in a record is
  refused; varint and length caps (a 300-byte command, a 4097-change record) refused.
- `server/journal_test.odin`:
  - **`test_grief_rolled_back`** (the exit check): a stepped server (seed 45, Earth, view
    radius 4, height 2, `rules_still()`, `no_sheep`, a save directory in `build/`), the
    pipe player `mallory` (an owner) standing still. Build phase (ticks 1-1200): `/fill` a
    plank house with a door gap, a pool of water sources walled with stone, a chest filled
    from her inventory, wheat on farmland; then 300 quiet ticks so the water settles.
    `H0` = `hash_chunks` over the 5x3x5 chunks around her. Grief phase (1500-2700): breaks
    six house blocks by hand and places stone, `/fill`s a box of air through the house,
    breaks the pool wall (the water floods out), `/setblock`s water on the roof, tills
    grass, breaks the block under a wheat plant, fires three rockets into the house,
    breaks the chest. Then `/rollback player mallory 45s`, ticks until it reports done,
    and 300 more. Asserted: `hash_chunks` equals `H0`; the report has `kept 0, missing 0`;
    the chest's record is empty and `audit(s)` is balanced; the journal holds entries with
    every `how` the grief used.
  - `test_rollback_keeps_others`: the same build; a test-made action of character `bob`
    (`action_begin` with a `Character` actor) builds a tower elsewhere during the grief and
    places stone where mallory broke a house block. After the rollback the tower stands,
    bob's stone is there, and the report says `kept 1`.
  - `test_rollback_by_system_and_area`: `/rollback system liquid 30s` removes only flowed
    water; `/rollback area 30s sel` touches nothing outside the selection.
  - `test_rollback_reads_disk`: a rollback after a restart (the ring empty) restores from
    the segments and gives the same hash as one before it.
  - `test_undo_redo`: `/fill`, `/undo` (the blocks back), `/redo` (the fill again), a new
    edit clears the redo; an action pushed out of a 1024-entry ring is too old.
  - **`test_journal_replays`** (the exit check): M38's scripted session (`DETERMINISM_TICKS`)
    with a save directory. Replay from the generator (`""`, since 0) at the end equals the
    live world with no problem; a `save` at tick 1000, its directory copied aside, and a
    replay onto that copy since its age equals the live world at the end. Then a block
    written with `chunks_set_block` directly at tick 1500 is reported by the replay with
    its position.
  - `test_journal_matches_disk`: after a session, every entry in the ring equals the
    segments' entries in the same order; an action's declaration precedes its use in every
    segment; truncation at start drops a segment written after the last save.
  - `test_journal_compacts`: segments of 64 KiB aged past an hour compact; a rollback over
    them restores the same blocks as over the detailed ones; retention deletes by age and
    size.
  - `test_protection_refuses`: in a protection, a non-member's hand edit is refused (the
    `Edit_Result` and the notice), a fill skips it and says how many, water poured outside
    does not flow in, a member's and a bypassing owner's edits pass; protections survive
    save and load.
  - **`test_journal_cost`** (the exit check, `-o:speed` in CI on Linux; a debug run of the
    suite allows four times the share): a stepped server with `journal_timed`, M11's flood
    (10 000 flowing blocks), 20 rocket blasts of radius 6 and ten 32x32x32 `/fill`s over 600
    ticks. The journal's share of the summed tick time and its per-tick mean are within
    the budget above; the failure prints both numbers.
- `server/determinism_test.odin` unchanged and passing, now covering the `Journal`
  section (both sides journal identically).
- `tools/build/determinism_test.odin`: the pipeline lint fails on a stray
  `chunks_set_block` with its line and passes the tree.
- Every existing test passes with its call sites given a cause.

**Exit check:**

- `test_grief_rolled_back`: the world hash after the rollback equals the pre-grief hash.
- `test_journal_replays`: replay of the journal onto the generator and onto a saved
  snapshot equals the live world; a bypassing write is caught.
- `test_journal_cost` within budget, optimized, as a CI step on Linux ("Journal cost,
  optimized", beside "Water flood, optimized").
- `build check` (with the pipeline lint), `build determinism` and the whole suite pass; the
  CI run of the commit is green.

**Check by hand:**

- In a singleplayer world, build something, break it, `/rollback player <you> 1m`, and
  `/history` a block: the build is back and the history reads sensibly.

What differed: split once, as the spec allows: steps 7 and 8 (region protection with `admit` refusing, `protections.cfg` and `/protect`; compaction and retention) are M45b (`milestones/M45b.md`, its tests `test_protection_refuses` and `test_journal_compacts`); `admit` stays the always-`Yes` hook. Names: the shared types are `game.Edit_System` (the spec's `System`), `game.Journal_Action`, `game.Journal_Entry`, `game.Journal_Tick|Actor|Changes|Save|Params` and `game.Journal_Record` (`Record`, `Action`, `Entry` were taken in `game`); `age_of(s)` is the spec's `age(s)`; `rules_still()` is in `journal_test.odin`. Beyond the spec: `journal_batch` records a bulk edit's chunk at once; `Update.action` and `Entity.action` are hashed as said, but `Client.command` is set around the whole `admin` run; `journal_note`/`journal_save_point` write the `Save` record; `chunk_load_saved` lets a rollback load an edited chunk from the save. The disk groups a tick's entries by chunk, so a segment's order within a tick is by chunk, not by append (`test_journal_matches_disk` compares sorted). A `Tick` record is written per age, and an entry carries the age it was made at (a command run between two ticks is in the next tick's, with its own age). `kept` also counts a position whose newest entry is the filter's but whose block is not what the run left, and positions where water woken by someone else's change flows (its cause is theirs): `test_rollback_keeps_others` asserts at least 1, not exactly 1. The grief test uses the session's own character (the mirror's) rather than a player called mallory, and times the rollback to start at the grief (seconds computed from the ages), not a fixed 45 s. Undo of an action over 4096 entries runs as a rollback job and stops the undo batch; redo pushes the `Redo` action on the undo stack so `/undo` undoes a redo. The cost is counted in cycles (`intrinsics.read_cycle_counter`; a clock read costs more than a journal call here): 0.5% of the ticks' time and 0.02 ms a tick, optimized. The bandwidth baseline's root lines changed as said; `s:state` grew by 27 bytes in both scenarios, not 0: the join record that lists the commands a player may use (`rollback history undo redo`). `/rollback` and `/history` are in node `world.rollback`, `/undo` and `/redo` in `world.edit.undo`. Added `docs/journal.md` and the `Journal` section in `docs/determinism.md`.

# M45b: region protection and journal compaction

The remainder of M45 (the edit journal, done: `docs/journal.md`, its spec in history.md).
The pipeline already calls `admit(w, act, p)` for every block change; it returns `.Yes`
always. This milestone makes it refuse, and keeps the journal's disk use bounded.

**Admission.** `admit(w, act, p) -> Admit` with `Admit :: enum u8 {Yes, Protected}` is the
only place a block change can be refused for who caused it. M45b checks region protection;
M52 adds `Over_Budget` and `No_Capability` here and nowhere else (the action carries the
actor, so the check needs nothing more). Bulk edits ask once per box: `admit_box(w, act, lo,
hi)` returns the protections overlapping the box that the actor may not edit; none: every
block is admitted without a per-block check (a world with no protections returns at once).
`edit_chunk` uses it instead of calling `admit` per block when the box overlaps none. A
refused change:

- a hand edit: `Edit_Result` not accepted (the client rolls back its prediction) and the
  notice `&cThis place is protected (<name>)`, at most once a second per player;
- a bulk edit: the protected blocks are skipped; the notice says `fill: 120 blocks changed,
  36 protected` (`bulk_edit` returns the count skipped);
- a consequence (water, a plant, a blast): left as it is (water stops at the edge).

The count of entries per tick and per action (`Live_Action.entries`) already exists for
M52's quotas and `/history`.

**Region protection.** `World.protections: [dynamic]Protection` (`{name: string, box: Box,
members: [dynamic]string}`), at most `MAX_PROTECTIONS :: 256` per world, names 1-32 of
`[a-z0-9_-]`. A change inside a protection is admitted if the action's actor is `World`, has
`bypass` (`actor_of` resolves `allowed(s, c, "world.protect.bypass")` once per action), or is
a member by character name. Saved in `worlds/<address>/protections.cfg` (`protect <name> <x1>
<y1> <z1> <x2> <y2> <z2> [member ...]`, one per line), written through `write_atomically`
when changed and at save. Hashed in the `Journal` hash section (sorted by name). Commands
(node `world.protect`): `/protect add <name> [x1 y1 z1 x2 y2 z2]` (the selection if no
coordinates), `/protect remove <name>`, `/protect list`, `/protect member add|remove <name>
<character>`.

**Compaction and retention** (in `world_save`, at most one segment per save):

- A closed segment whose newest age is older than `JOURNAL_DETAIL :: 108_000` ticks (one
  hour) is rewritten once as compacted (header flag `JOURNAL_COMPACTED`): per (position,
  action), one entry with the first `old`, the last `new`, the last age and `how`; entries
  whose `old == new` dropped; the declarations it still needs kept. Written to
  `<seq>.vxj.tmp`, then renamed over. A rollback over compacted history gives the same net
  result; only the time resolution within the segment's span is lost. The segment the
  world.cfg records is not compacted while it is the newest.
- Segments whose newest age is older than `JOURNAL_KEEP :: 7 * 24 * 108_000` ticks, then the
  oldest while the directory is over `JOURNAL_MAX_BYTES :: 256 << 20`, are deleted.
  `Config.journal_*` overrides for tests as needed.

**Tests:**

- `test_protection_refuses`: in a protection, a non-member's hand edit is refused (the
  `Edit_Result` and the notice), a fill skips it and says how many, water poured outside does
  not flow in, a member's and a bypassing owner's edits pass; protections survive save and
  load; `/protect` commands round-trip.
- `test_journal_compacts`: segments of 64 KiB aged past an hour compact; a rollback over them
  restores the same blocks as over the detailed ones; retention deletes by age and size.
- `server/determinism_test.odin` still passes with protections in the `Journal` section.

**Exit check:** `test_protection_refuses` and `test_journal_compacts` pass; `build check`
and the suite pass; the CI run of the commit is green.

**Left out:** capabilities and budgets for scripts (M52, at `admit`); protections by claim
tools or per-block owners; a UI for protections.

What differed: `bulk_edit` returns the skipped count as a third result and `edit_chunk` takes the boxes `admit_box` returned instead of asking per block. Compaction merges a run of changes of a block by one action, not every change by that action: another action's change in between would break the old/new chain that replay checks. A segment's newest age is judged by the next segment's first age (a header read), so compaction and retention never touch the newest and are late, never early, in a quiet world. `Save` records are dropped by compaction; `Params` are kept. The test mirror records the notices it is told (`Mirror.notices`). The retention check is a helper `test_journal_compacts` calls, not a test of its own. The `/protect` command joined the commands list a join record carries: `s:state` grew by 8 bytes in both bandwidth scenarios (baseline accepted).

# M46: persistence v2

**Why.** M47 changes saves to name palettes "through M46's registry", M48 and M49 must
"load old saves unchanged", and the agent service will move universes between machines.
Today's saves cannot carry that. The survey found:

- Files are replaced one at a time by `write_atomically` (`server/save.odin`): written
  to `<path>.tmp`, then renamed, with no `fsync` of the data or the directory. A power cut
  can leave a renamed but empty file. A crash in the middle of `save` leaves a mix: say,
  a character file from this save (with the stack just taken from a chest) and
  `containers.cfg` from the last one (still holding it). That is an item duplication
  M31's ledger cannot see.
- All IO runs on the server thread: an autosave every 60 s writes every changed region,
  character and config file inside one tick.
- A region file with a bad CRC is moved aside whole (`load_region`): every edit in its 256
  chunk columns is lost, though only one chunk may be damaged.
- Versions are scattered: `SAVE_FORMAT :: 4` in `universe.cfg` and each `world.cfg`,
  `REGION_FORMAT :: 1`, `PLAYER_FILE_FORMAT`. Migrations are inline special cases
  (`migrate_world_dir`, `players.<name>.x` in `read_universe_file`, `players/` to
  `characters/`, `critter` to sheep, `biome_blend` and `gates` defaults), none of them
  registered or testable as a chain.
- There are no backups, no export, and no test that kills a save half-way.
- Saves are written by the server only; the client lists, renames and deletes save
  directories (`client/worlds.odin`); no tool reads them.

This milestone is planned as two sessions, **M46** (durability: the disk layer, the save
transaction off the server thread, the format and its migrations, backups, the crash
harness) and **M46b** (the save without a hitch: sliced capture, region compaction,
export and import, the 200-character budget). Each has its own exit check.

#### M46: durable, transactional, versioned saves

**Design.**

*The disk layer* (`base/disk.odin`, with `base/disk_linux.odin`, `base/disk_darwin.odin`,
`base/disk_windows.odin` for the OS calls; nothing above it touches `os.write*`,
`os.rename` or `os.remove` for save files):

- `Disk :: struct {faults: ^Disk_Faults}` (nil in production), one in `Store`.
- `disk_write(d, path, data) -> Disk_Error`: create or truncate, write in 64 KiB pieces,
  sync the file, close.
- `disk_append(d, f, data)`, `disk_sync(d, f)`, `disk_truncate(d, path, size)` for journal
  segments.
- `disk_rename(d, from, to)`, `disk_remove(d, path)`, `disk_mkdir(d, path)`,
  `disk_sync_dir(d, dir)`, `disk_link(d, from, to)` (a hard link, else a copy).
- `disk_replace(d, path, data)`: one file atomically and durably: `disk_write(path +
  ".tmp")`, `disk_rename` over `path`, `disk_sync_dir` of its directory. It replaces
  `write_atomically` for files outside a save (`structure save`, `permissions_changed`).
- **Per OS:**
  - Linux: `fsync` on files; directories opened read-only and `fsync`ed; `rename(2)`.
  - macOS: `fcntl(fd, F_FULLFSYNC)` (command 51, declared by us: `core:sys/posix` lacks
    it), falling back to `fsync` when it fails (some file systems); directories `fsync`ed;
    `rename(2)`.
  - Windows: `FlushFileBuffers`; `MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING |
    MOVEFILE_WRITE_THROUGH)` (atomic on NTFS for a file replacing a file; not
    `ReplaceFileW`, which fails when the target is missing and mixes in ACL and attribute
    copying); no directory sync (write-through covers the entry). A rename refused with
    `ERROR_SHARING_VIOLATION` or `ERROR_ACCESS_DENIED` (an indexer or a virus scanner
    holding the file) is retried 5 times, 20 ms apart. This runs on the save worker,
    never the tick. Hard links with `CreateHardLinkW`; FAT and exFAT have none, so a copy.
- **Faults (tests only).** `Disk_Faults {countdown: int, ops: int, crashed: bool, rng:
  base.Rng, power_loss: bool, unsynced: [dynamic]Unsynced}`. Every operation above, and
  each 64 KiB piece of a write, is one op and counts `ops`. When the count reaches
  `countdown`, that op is torn: a write puts a seeded prefix of its piece (0 to all bytes)
  and stops, and a rename, remove, mkdir or link happens or not by a seeded coin. From then
  on `crashed` is set and every op returns `.Crashed` and does nothing, as a dead process
  would. With `power_loss`, the crash also truncates every file written since its last sync
  to a seeded length (unsynced data is what a power cut loses; metadata loss is not
  modelled).

*The save transaction* (`server/save_tx.odin`). A save writes every file or none:

1. **Prepare.** Each file of the save is written as `<path>.new` with `disk_write` (synced).
   The journal's open segments are synced.
2. **Commit.** `save.tx` is written with `disk_replace`. It is the commit point:
   `"VXTX" u32 format (1)  u64 generation  u64 age  varint count`, then per operation `u8 kind
   (1 rename .new to final, 2 delete)  varint len  path (relative, '/')  u32 crc32 of the
   .new file (renames)`, then `u32 crc32` of all before.
3. **Apply.** Each `.new` is renamed over its final name, deletions done, each touched
   directory synced, and `save.tx` removed (then its directory synced).

`store_recover(dir)` runs first thing in `store_open`, before anything is read:

- a `save.tx` that reads whole: apply is done again; a rename whose `.new` is gone and
  whose final file has the recorded CRC was done already; a missing `.new` with a wrong
  final CRC is disk damage (only possible outside the fault model): the open stops with
  `this save is damaged (worlds/.../r.0.0.vxr): restore a backup (--restore)`;
- no `save.tx` (or only a `save.tx.tmp`): the save had not committed; every `*.new` and
  `*.tmp` under the universe is removed, leaving the previous generation whole.

`universe.cfg` gains `generation = N` (1 for the first save of format 5, counting up).
`world.cfg`'s journal keys (M45) are inside the transaction, so the journal's end and the
regions always agree.

*The save worker.* `save(s)` still encodes every file on the server thread, as today
(M46b slices that), but the files go as one `Save_Batch {generation, age, files:
[]Prepared {path: string, bytes: []u8}, deletes: []string}` (in an allocator the batch
owns) to a `base.Jobs` named `save` with one worker, which prepares, commits, applies and
then makes a backup if one is due. A stepped server's jobs have no worker, so the batch
runs inside `save` (deterministic, which the crash harness relies on). The server thread
polls the result each tick: a failed batch is logged (`server save failed generation=N
problem=<first error>`), the regions and characters it carried are marked changed again,
and the next autosave retries. One batch at a time: an autosave or `/save` due while one
is running waits for it. `stop` waits for the worker before teardown. Files written
outside a save (structures, `permissions_changed`) use `disk_replace` directly.

*The format, version 5.*

- `SAVE_FORMAT :: 5` in `universe.cfg` and every `world.cfg`.
- **Region format 2** (`common/game/save.odin`; today's reader moves to `common/game/save_v1.odin`,
  `region_open_v1`, frozen and used only by the migration):

  ```
  "VXRG"  u32 format (2)  i32 rx  i32 rz  u64 generation  varint chunk count n
  index: n x { i32 x y z   u32 offset   u32 length   u32 crc32(payload) }   (sorted by chunk_pos_less)
  varint top count   tops as format 1
  u32 crc32 of everything above
  payloads: each chunk's blocks (palette + runs, as today)
  ```

  A bad header CRC: the file is moved aside (as today) and the newest backup's copy of
  the region is loaded instead, logged with what is lost (`region r.0.0 damaged: loaded
  from backup g00000012 (its later edits are lost)`). A bad chunk CRC: only that chunk is
  dropped, logged with its position; the rest load.
- Text files (`universe.cfg`, `world.cfg`, `entities.cfg`, `containers.cfg`,
  `protections.cfg`, `permissions.cfg`, `community.cfg`) and character JSON stay text with
  their `format` lines and no checksum: people edit `permissions.cfg` by hand, and the
  transaction already makes them whole.

*The migration registry* (`server/migrate.odin`):

```
Migration :: struct {
	from: int,                         // the format it reads; it leaves from + 1
	name: string,                      // what it does, for the log
	run:  proc(m: ^Migrator) -> bool,  // false: m.why says why
}
Migrator :: struct {
	dir:   string,     // the universe
	disk:  ^base.Disk,
	staged: map[string][]u8,  // writes not committed yet, by relative path
	deletes: [dynamic]string,
	why:   string,
}
mig_read  :: proc(m: ^Migrator, rel: string) -> ([]u8, bool)   // the staged version if any
mig_write :: proc(m: ^Migrator, rel: string, data: []u8)
mig_delete :: proc(m: ^Migrator, rel: string)
mig_list  :: proc(m: ^Migrator, rel_dir, suffix: string) -> []string
@(rodata) MIGRATIONS := [?]Migration {
	{4, "regions get an index and a checksum per chunk (region format 2)", migrate_regions_v2},
}
migrate_universe :: proc(dir: string, disk: ^base.Disk) -> Migrate_Result  // {from, to, backup, ok, why}
```

- `store_open`'s order: `store_recover`; a directory from before universes (a top-level
  `world.cfg`) goes through `migrate_world_dir` as today, which now writes `format = 4`
  (`LEGACY_FORMAT`), not `SAVE_FORMAT`; then the format is read from `universe.cfg`. Newer
  than `SAVE_FORMAT` is refused as today. Older: a backup `backups/pre-migration-<from>/`
  is made (below), every migration from that format on runs in order on one `Migrator`,
  the runner sets every `format =` line to `SAVE_FORMAT`, and everything staged commits as
  one transaction (generation + 1). A failing migration commits nothing; the open fails
  with `server save could not be upgraded from format 4: <why>`, which the client's
  failure screen shows.
- Formats 1-3 are upgraded in memory by the format-4 readers, as today (they predate
  universes, and their tests exist); the registry starts at 4.
- **Rules for migrations, in `docs/saves.md`:** a migration reads only files of its `from`
  format, with readers frozen beside it (never the current reader, which will change);
  it is never edited once released; it is tested from a committed fixture of its `from`
  format. M47's names-palette migration is the next entry.
- `migrate_regions_v2`: every `worlds/*/regions/r.*.vxr` is read with `region_open_v1` and
  written as format 2 (with the new generation), byte-for-byte the same chunks and tops.
- **The fixture.** Before anything changes, step 1 writes `assets/fixtures/save-v4/`: a
  universe saved by today's code from a scripted stepped session (edits in three regions,
  a chest with items, a dropped stack, a sheep, one character with an inventory and
  counters, a protection and a journal from M45), by a test built with
  `-define:VX_FIXTURE_WRITE=true` that also writes `expect.txt` (the home world's
  `hash_chunks` over the edited chunks, the character's inventory, the chest's slots).
  `.gitattributes` gets `assets/fixtures/** -text`, so the bytes are the same on Windows.

*Backups* (`server/backup.odin`):

- A backup is a directory `backups/g<generation, 8 digits>-<UTC yyyymmdd-hhmmss>/` holding
  every file of a committed generation: everything in the universe except `backups/`,
  `telemetry/`, `exports/`, `*.new`, `*.tmp` and `save.tx`. Files are hard links
  (`disk_link`, falling back to a copy), so a backup costs a directory entry per file:
  saves never modify a file in place, they rename new ones over (the old inode stays with
  the backup). Journal segments are appended to after the backup; the backup's own
  `world.cfg` records where each ended, so a restore truncates them as M45's start does.
  The directory is built as `<name>.tmp/` and renamed when complete.
- When: after the first committed save of each run, then after a commit once
  `BACKUP_EVERY :: 54_000` age ticks (30 minutes of play) have passed since the last one;
  and before every migration (`pre-migration-<from>`) and restore (`pre-restore-g<N>`).
- How many: the newest `BACKUP_KEEP :: 5` rolling backups (`Config.backups`, the dedicated
  server's `--backups N`, 0 for none); `pre-*` backups are never removed automatically.
- Restore: `universe_restore(dir, name, disk)` (the dedicated server's `--restore
  <name|latest>`, which restores and exits): a `pre-restore` backup, then one transaction
  that puts the backup's files in place and deletes the files it does not have.

*The check* (`universe_check(dir) -> Check_Report {ok, generation, problems: []string}`):
read-only, after `store_recover`: parses `universe.cfg`, every `world.cfg`,
`entities.cfg`, `containers.cfg`, `protections.cfg`, every region (header and every chunk
CRC), every character file and every journal segment up to its recorded end, with the
loaders' own parse procedures. It is the harness's oracle and `voxiverse-server --check
<universe>` (prints the report, exits 1 on a problem).

*The crash harness* (`server/crash_test.odin`). Fault injection in the disk layer, not
real kills, so every point is reproducible:

- Setup, once: a stepped server on a fresh universe runs a short script and saves
  (generation 1), then changes more (edits in two old regions and one new, a stack moved
  from the chest into the inventory, the character moved, a protection added) and builds
  the second save's `Save_Batch` without running it. The universe directory at generation
  1 is copied to `base/`, the batch kept, and the save run once without faults gives the
  reference digests `D1` and `D2`. A digest is a hash over every file's relative path and
  bytes, excluding `backups/` and `telemetry/`, journal segments read only up to their
  recorded end.
- Counting: the clean run's op count `N`.
- **1000 points** (`CRASH_POINTS :: #config(VX_CRASH_POINTS, 200)`; CI runs 1000): run `i`
  copies `base/`, runs the batch with `Disk_Faults {countdown = 1 + (i * 7919) % N, rng =
  rng_make(i), power_loss = i % 2 == 1}`, then `store_recover` and `universe_check`. Every
  run must check clean, and its digest must be `D1` or `D2` (never a mix). Both must occur.
  Every 100th run also opens the universe with a stepped server and checks that the
  character's inventory and the chest together hold exactly the items of one generation.
- The same harness, over fewer points (all of each one's ops), for a migration of the v4
  fixture (after recovery: still format 4 and migrating cleanly on the next open, or
  format 5), a backup (never affects the save), a restore, and a journal append between
  saves (truncated back to the recorded end on open).

**The order of the steps:**

1. The v4 fixture and `expect.txt`, written with today's code; `.gitattributes`. Commit.
2. `base/disk*.odin` with faults; its tests.
3. `save_tx.odin` (prepare, commit, apply, recover) and the save worker; `save`,
   `world_save` and `players_save` build a batch; `write_atomically` goes, replaced by
   batches and `disk_replace`.
4. Region format 2, `save_v1.odin`, chunk salvage.
5. The migration registry, `migrate_regions_v2`, format 5, the fixture test.
6. Backups, restore, a damaged region loaded from a backup.
7. `universe_check`, the crash harness, the CI step.
8. `docs/saves.md`: the layout, the transaction, the rules for migrations.

If the session must split, the remainder is **M46a: steps 6 and 7's backup, restore and
migration runs**, with `test_backups_rotate`, `test_restore` and the migration's crash runs
as its exit check (M46 itself then ends with the save's 1000 points and the fixture's
migration).

**Left out (M46):** sliced encoding, compaction, export and import, the universe lock (M46b); saving simulation state through M39's codec (the
RNG states, entity brains, the update heap: save and load with the hash intact); real
process kills; metadata loss on power cuts.

**Tests (M46):**

- `base/disk_test.odin`: `disk_replace` leaves the old or the new file at every fault
  point; torn writes and coins are the same for the same seed; a crashed `Disk` refuses
  everything; on Linux the sync calls are made (counted).
- `common/game/save_test.odin`: format 2 round-trips; a flipped bit in a payload drops only that
  chunk; in the header, the file; `region_open_v1` still reads format 1.
- `server/save_tx_test.odin`: recovery with a whole `save.tx` finishes it; without one,
  removes the `.new` files; a second recovery changes nothing; the worker's failure
  re-marks the regions and the next save writes them.
- `server/migrate_test.odin`: the registry is a chain (sorted, contiguous, the last
  `from + 1 == SAVE_FORMAT`); **`test_v4_save_migrates`**: the fixture, copied, opens as
  format 5 with a `pre-migration-4` backup, and matches `expect.txt` (chunks' hash, the
  inventory, the chest); a migration made to fail commits nothing and the save opens
  again afterwards; the legacy tests (`items_test`'s format 2, `save_test`'s format 2)
  still migrate through `migrate_world_dir` and then the registry.
- `server/backup_test.odin`: `test_backups_rotate` (five kept over seven due, `pre-*` kept,
  a backup's files equal the generation's digest); `test_restore` (a restore gives the
  backup's digest and a `pre-restore` backup); a damaged region's header loads from the
  newest backup.
- **`server/crash_test.odin`**: `test_save_survives_crashes` (the points above), and the
  migration, backup, restore and journal runs.
- Existing save tests (`save_test`, `worlds_test`, `containers_test`, `ledger_test`, ...)
  pass unchanged except where they wrote a format-4 file by hand.

**Exit check (M46):**

- `test_save_survives_crashes` with `VX_CRASH_POINTS=1000`, as a CI step on Linux
  ("Save crash points"): every point loads, and each is exactly the old or the new
  generation.
- `test_v4_save_migrates` and the legacy format tests pass.
- `test_backups_rotate` and `test_restore` pass.
- The whole suite, `build check` and `build determinism` pass; CI green on the commit.

**Check by hand (M46):** on Windows, play a singleplayer save for ten minutes with an
autosave, and look in its folder: no `.new` or `.tmp` files, a backup present.

**What differed (M46):** `Config.backups` is a `Maybe(int)` (nil: `BACKUP_KEEP`), not a plain int, so the zero value means the default. A rolling backup is decided at staging (`Save_Batch.backup` = how many to keep) and made by the worker after the apply. `save` was split into `save_collect` and `store_commit` so the crash harness can build a batch without running it. Each crash test has its own directories (tests run side by side). The migration, backup, restore and journal-tail runs are in `crash_test.odin` over every operation (or every n-th past 400) instead of a separate M46a. Rolling backups are the `g*` directories; a damaged region is only restored from those, never from a `pre-migration-*` backup (format 4 files).



# M46b: saves without a hitch, compaction, export and import

The second part of M46: its design, names and files are in [M46.md](M46.md); read it first.

**Design.**

*Capture in one tick, encode in slices.* A save must describe one tick (items move
between inventories, chests and dropped stacks), yet encoding a large universe takes
longer than a tick. So `save` captures at tick T and encodes over the following ticks,
with copy-on-write for what can still change:

- **At T** (`save_begin`): the small item-holding state is encoded at once: `universe.cfg`,
  every loaded world's `world.cfg`, `entities.cfg`, `containers.cfg` and
  `protections.cfg`, `permissions.cfg`, `community.cfg` (about 1 ms for 512 entities and
  100 chests). Each dirty character's `Player_Record` is copied without its counters
  (fixed size). Each changed region is captured: its `w.regions` flag cleared, and the
  encoded bytes of its unloaded chunks (`w.saved`) and its edited tops copied. Its loaded
  chunks are marked `capture = <generation>` (a new `Chunk` field).
- **Copy-on-write in the pipeline.** Before `set_block` or `edit_chunk` changes a chunk
  marked with a running capture, and before `keep_edits` or `chunks_unload` lets one go,
  its blocks are copied into the job (`job.cow[pos]`) and the mark cleared. M45's pipeline
  is the only writer, so this is the only hook needed.
- **Slices.** Each following tick, `save_slice` encodes items (a region: from the copies,
  the COW copies, or the unchanged live chunks; a character: the copied record with the
  counters as they are at that tick, from the client or `st.players`) until
  `SAVE_SLICE_US :: 2000` microseconds of that tick are used, and hands each encoded file
  to the save worker (M46). Counters may be a few seconds newer than the inventory beside
  them; that is the only part of a save not from T.
- A world with a save running does not unload until it commits (`worlds_unload_idle`
  skips it); `stop` runs the capture and every slice at once with no budget, then waits.
- Timing is the wall clock's, so how many ticks a save takes varies, but not what it
  writes, nor any hashed state (the marks and copies are not state).

*Region compaction* (on the save worker, as each region is prepared):

- A chunk that a rollback, an undo or a redo touched since its region was last written
  (`Chunk.revisit`, set in the pipeline for those `how`s) is generated again with the
  world's generator and its own `Column_Cache`, and dropped from the region if it is
  identical: it becomes a natural chunk, and its `modified` flag is cleared on the server
  thread when the batch commits.
- Edited tops equal to the natural top are dropped.
- A region left with no chunks and no tops is deleted in the transaction.

*Export and import* (`server/export.odin`):

- A `.vxu` file is one universe: `"VXUX" u32 format (1)  u32 save_format  u64 generation
  u64 age  varint file count`, then per file `varint len  path  u64 size  u32 crc32  bytes`,
  then `"VXUE" u32 crc32` over every path and file CRC. Files are stored, not compressed
  (regions are already palette + runs). The set is a backup's, plus journal segments up
  to their recorded end (`--no-journal` leaves them out: the journal names characters).
  `packs/` is included when M47 makes it.
- `universe_export(dir, out, disk)` exports a closed universe's committed generation.
  On a running server, `/export` (node `server.export`) saves, and the worker writes
  `exports/g<generation>.vxu` after that commit.
- `universe_import(file, dest, disk)` refuses an existing `dest`, a file over 16 GiB in
  total, over 100 000 files or one over 1 GiB, and any path that is absolute, has `..`,
  `.`, an empty part, `\`, `:`, more than 8 parts, a part over 64 bytes, or a byte outside
  `[A-Za-z0-9._-]`, naming the path. It writes into `<dest>.import/` with `disk_write`,
  checking each CRC as it goes, then renames the directory to `dest`. A newer
  `save_format` is refused (`made by a newer game`); an older one migrates when opened.
- Entry points: the dedicated server's `--export <file>` and `--import <file>` (do it and
  exit); the client's console words `export <save> [file]` (default `<saves>/<save>.vxu`)
  and `import <file> [name]` (a new save directory; numbered if the name is taken).
  No menu buttons yet.

*The 200-character budget* (`server/save_budget_test.odin`, `-o:speed` in CI on Linux):
a stepped server whose store holds 200 dirty characters (a full inventory each and 300
counters), one world with 512 edited chunks of seeded mixed blocks over 16 regions (all
loaded), 100 chests and 400 entities. Measured: the capture tick, the largest slice tick,
the ticks until commit with the worker running, and a full blocking save. Budgets on the
CI runner: capture at most 4 ms, every slice tick at most 3 ms of save work, committed
within 150 ticks, the blocking save at most 1.5 s. Debug runs allow four times each.

*One process per universe* (owner, 2026-10-26). Opening a universe takes a lock file,
`<universe>/lock`, held while it is open: `flock(LOCK_EX | LOCK_NB)` on Linux and macOS,
`CreateFileW` with no sharing on Windows (`base.file_lock`/`file_unlock`, one file per OS).
A second process (a second client, or the dedicated server on a client's save) fails at
open with `the universe is open in another process (<lock path>)`, before anything is
read or written. The lock holds the owner's process id as text, for the message only; a
lock left by a crashed process is free, because the OS releases it with the process. Test:
two opens in one test process (the second sees the first's lock) and a child process that
holds it.

**The order of the steps:** the capture, the COW hook, slices and the unload rule; the
budget test and its CI step; compaction; export and import with their entry points; the
universe lock; `docs/saves.md` updated.

**Left out (M46b):** export and import buttons in Singleplayer, compressed exports,
exporting part of a universe (one world), streaming an export to another server.

**Tests (M46b):**

- `server/save_slice_test.odin`: a save whose chunks, chest and inventories are changed
  between its capture and its last slice writes the capture tick's state (the digest equals
  a blocking save's at T); a chunk unloaded mid-save is saved as at T; a world is not
  unloaded while its save runs; `stop` during a slice writes everything.
- **`test_save_200_characters`**: the budgets above.
- `server/compact_test.odin`: a griefed and rolled-back chunk leaves its region; a region
  emptied by it is deleted; tops equal to natural are dropped; the world hash is unchanged
  by compaction.
- `server/export_test.odin`: **`test_export_import_round_trip`** (export, import elsewhere,
  open: `hash_chunks` of the edited chunks, the characters and the chests equal the
  original's); every refused path and size case; a truncated or altered file refused;
  importing the v4 fixture's export migrates it.

**Exit check (M46b):**

- `test_save_200_characters` within budget, optimized, as a CI step on Linux ("Save
  budget, optimized").
- `test_export_import_round_trip` and the slice tests pass.
- M46's crash test still passes at 1000 points (the slices change what is prepared, not
  how it is committed).
- The whole suite, `build check` and `build determinism` pass; CI green on the commit.

**What differed (M46b):**

- `Chunk.revisit` is `World.revisit` (a set of chunk positions): the flag has to survive the chunk being unloaded, and a chunk in `w.saved` has no `Chunk` to carry it. It is set in `journal_append` for the Rollback, Undo and Redo hows.
- The worker assembles every region file, not only the compacted ones: a slice encodes one chunk at a time to bytes (the unit of the 2 ms budget), the finished list goes to the worker as a `Region_Job`, and `region_encode_bytes` (new, beside `region_encode`, which is now built on it) writes the file. Tops are sorted before they are written, so a region file is the same bytes whenever it is written (map order varied between runs).
- The journal's `fsync` moved from `journal_save_point` on the tick (5 ms on the budget scene's disk) to the worker, which syncs the segment the batch lists (`Save_Batch.syncs`, `disk_sync_path`) before the commit. `write_containers` no longer uses `fmt` (it was a third of the capture tick with 100 chests).
- A character that was not playing at T leaves `Store.players` once it is encoded (not at T), so capture does not clone its counters; a rejoin meanwhile finds the record.
- A file written outside a save (`permissions_changed`) while a save is being sliced also replaces its copy in the running save's batch, or the commit would put the older text back.
- `Store.slice_hold` (tests: the ticks do not encode; `save_finish` does) and `Store.slice_worst_us` exist for the slice and budget tests. `save_collect` stays as the crash tests' way to hold one whole batch.
- The lock is two files, `base/lock_posix.odin` (Linux and macOS: `flock`, opened close-on-exec, or a child process would keep the lock after the server let go: the first version of the child-process test found it) and `base/lock_windows.odin`. Windows cannot read the holder's pid from a file opened with no sharing, so its message has no pid. `lock` is skipped by `walk_files` (not in backups or exports).
- `universe_import` takes `Import_Limits` (default: the spec's), because a file of the real size cannot be made in a test; the 16 GiB total is tested with a small one.
- `/export` is `save_begin(export = true)`: the batch carries `export_to`, which the worker writes after the commit. The dedicated server's flags are `--export`, `--no-journal` and `--import` (the universe given by `--universe`).
- Compaction clears `modified` on a loaded chunk only if its blocks still encode to the captured bytes (the capture marks are gone by then); an unloaded one leaves `w.saved` on the same test.
- Save digests of two runs differ in `community.cfg` (when a player was last seen) and the journal (it stamps the wall clock); the slice test compares everything else, and the characters' inventories.
- M46's spec, which this one says to read first, is in history.md.
