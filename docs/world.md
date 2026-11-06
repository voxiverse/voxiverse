# Worlds, items, liquids, structures and generation

How the server's worlds are addressed and travelled between, what players carry, how water
flows, how structures are placed and how terrain is generated. The commands that act on
these are in [server.md](server.md); the on-disk format is in [saves.md](saves.md);
the design of world data is in [design.md](design.md).

## Worlds

A universe contains worlds, named by addresses. An address consists of a galaxy of eight
Old Turkic symbols and a world of seven, each symbol distinct within its part
(`common/game/address.odin`; 40 symbols). It is written in one of two forms:

- as symbols, `𐰀𐰁𐰄𐰅𐰇𐰉𐰊 𐰋𐰌𐰍𐰎𐰏𐰐𐰒𐰔` (world, then galaxy; seven symbols alone mean the
  current galaxy);
- as a directory name, `0001020304050607-08090a0b0c0d0e` (two hex digits per symbol, galaxy
  first). This form can be typed on any keyboard.

The address alone determines the world's kind (generator parameters, palette, gravity, day
length), so it is the same kind of world in any universe; the universe seed determines its
terrain. The address also says what lives there (`worldgen.world_life`: life, how many peoples,
how old their history; about 1 world in 8 with animals has peoples; the home world, Earth, has
none): the dial shows it for the world a last symbol would reach, the creation screen for the
home world. The home world is Earth. A world loads when someone travels there, and unloads
(saved, its memory freed) after `WORLD_IDLE_SECONDS` (10) empty; the home world remains
loaded.

| Server command | Effect |
|---|---|
| `/travel <address> [character]` | Goes to the world's spawn, carrying the character (`world.travel`; another's: `world.travel.others`). Players use gates. |
| `/address` | Shows this world's address in both forms (`info.address`). |
| `/worlds` | Lists the loaded worlds and who is in each, and how many are saved (`info.worlds`). |

A universe's save is a directory (`universe.cfg`, `characters/`, `worlds/<address>/`, ...);
[saves.md](saves.md) describes the layout and the transaction. `server/core/save_test.odin`
covers save, quit and load, edits surviving unloading, and damaged files.

### Gates

Gates travel between the worlds of a galaxy. They are rare structures, none within
`worldgen.gate_distance` (2000) blocks of a world's middle. `/locate gate` places an admin in
front of the nearest one.

To use a gate, right-click its ring from within 8 blocks and pick seven symbols in the dial
overlay. The chevrons lock one by one (0.4 s each) and the far world's gate, the one nearest
its middle, locks with them; both ends open for 30 s, and walking into the horizon arrives
at the dialed world's gate. Refusals are returned as notices. The server logs `gate dialed`.
The client's chat and console draw the symbols from a fallback font
(`assets/fonts/noto_sans_old_turkic_regular.ttf`).

## Items

Items are data (types in `common/game/items.odin`, definitions in packs' `data/items/`).
Every block players may place has its own item, named after the block. Tools and armour are
items of their own (`rocket_launcher`).

### Inventories

An inventory has 30 slots (the first five are the hotbar, followed by a 5x5 grid), the
equipment slots (head, chest, legs, feet, offhand), the stack on the cursor and, while a
chest is open, the chest's 25 slots. The server owns the inventory and applies requests with
the same code the client predicts with (`common/game/inventory.odin`). It answers each
request with the inventory (the `inventory` record, whose `acked` field states how far it
got); a refused request is rolled back.

- Placing a block uses one from the hand (or the hotbar), unless the player's mode grants the
  `infinite_items` ability.
- Breaking a block drops the block's item where `rules.drops` is set (not with
  `infinite_items`).
- The `catalog` ability lets the inventory take any item.
- A player new to a world receives `world.cfg`'s `kit`.

Dropped stacks are entities. They fall, merge with stacks of the same item, are picked up by
walking over them (after half a second; two seconds for the player who dropped them), and
despawn after five minutes.

### Chests

A chest (`server/core/containers.odin`) is a block with a container block entity of 25 stacks,
kept with its chunk (`server/core/block_entities.odin`) and created when the block is placed.

Right-clicking a chest sends `Use_Block`. The server then places the entity's slots in that
player's `Inventory` (`chest`, `chest_open`), so that ordinary requests may name slots
`CHEST_BASE ..< ALL_SLOTS` and the client predicts them. The record is copied in before each
request and out after it, and other players viewing the chest are notified.

The chest closes on the `Close` request, or automatically when the player moves more than the
reach plus two blocks away or the block is removed. The entity is removed with its block
(broken, blown up, or edited in bulk; one code path, `entity_lifecycle`), and its contents
spill out. `server/core/containers_test.odin` covers this behaviour.

## Liquids

Water levels are block IDs (a source, flow levels 1-7, falling), so saves and the protocol
need nothing special. How a fluid flows is data: `data/sim/*.json` in a pack, with behaviour
`flow` (water's is `assets/packs/voxiverse/data/sim/water.json`: its level blocks, `delay`,
`reach` and whether sources form).

The server runs scheduled block updates (`server/core/sim.odin`, `flow.odin`): a queue ordered
by tick and position, at most one entry per position, of which at most 4096 run per tick
(`UPDATE_BUDGET`; the world slows under load rather than the server), so the same edits
produce the same water on every run. At most 65 536 updates wait at once; more are dropped
and logged. Any block change wakes the cells next to it; seas and lakes are left alone until
something opens them. A source stays; flowing levels live while something feeds them, spread
down first, else sideways one level weaker toward the nearest way down within `reach`
blocks; between two sources over firm ground a new source forms. Changes made by the world
travel as `block` records (not `heard`), sorted by chunk, in the tick's `state` message.
F3's server line shows the updates waiting.

`server/core/liquids_test.odin` contains the dam break test (the same water twice, both players
matching the server) and the flood test (10 000 blocks flowing within the tick budget; CI
also runs it optimized); `flow_test.odin` covers the rules.

## Structures

A template (`common/game/structure.odin`) is a box of cells (at most 64 blocks a side), each
either a block or void (which leaves whatever is present). Its `.vxs` file has a palette of
block names and runs of cells.

The base pack ships `ruin` and `well` as templates (`server/structures/*.vxs` in
`assets/packs/voxiverse/`). They are built in-game, compiled in, and read through the
registry; generation reads no files. Towers, dungeons (rooms and corridors, and a spiral
stair in a shaft up to the surface) and gates are procedural pieces.

In an Earth world, each structure kind has a set of cells at its spacing. Each cell decides by
a hash whether it holds a structure, where, and at what rotation, so any chunk can work out
which pieces reach into it (`common/worldgen/structures.odin`). Surface structures require
flat land and receive cobblestone foundations; trees keep clear of them; the column tops
include them. Where the sets of two kinds overlap, the earlier set's structure stands.

`/locate tower` (or `ruin`, `well`, `dungeon`, `gate`) takes you to the nearest one, and
`build worldmap` marks them.

`worldgen_test.odin`'s `test_structures` checks that every kind is placed, identically each
time, built identically in any chunk order, and under exact tops. `server_test.odin`'s
`test_structures_round_trip` saves, pastes and saves again (also via quarter turns) and checks
for the same file.

## World generation

Generators live in `common/worldgen/`. A world records its own generator (`generator = earth`
in `world.cfg`; older worlds keep `classic`). Generation is a pure function of the seed, the
settings and the position, so `build worldmap -seed:N` draws a world from above without the
game (biomes, water depth, hill shading; `-size:`, `-x:`, `-z:`, `-scale:` and `-out:` choose
the area, and a 4096-block map takes well under a second), and `-bench:64` generates whole
chunk columns and reports the time per chunk.

`common/worldgen/worldgen_test.odin` keeps hashes of two seeds' chunks. CI runs it on Windows,
Linux and macOS, so a platform that rounds differently fails in CI rather than in a player's
world.

The generator's stages appear in the profiler as `worldgen climate`, `worldgen place trees`,
`worldgen terrain` and `worldgen structures`.

### Biome blending

Biome borders blend. Each column samples the climate up to `worldgen.biome_blend` blocks away
(8 by default, in a different direction per column), so where two climates meet, the surfaces
and trees mix over a band twice that wide instead of meeting at a line. Tree density follows
each tree's own position, not its chunk's. A world whose `world.cfg` has no
`worldgen.biome_blend` loads with 0, hard edges, so new chunks meet its saved ones.

### Peoples' history

`planet.history(planet, address, seed, day, interventions)` (`common/planet/history.odin`) is the
peoples of a planet from their beginning to `day` (365 days a year), in steps of 10 years: a
pure function, so the history at any day is computed, never a running state; the same inputs give
the same history on every OS. Interventions are accepted and not applied yet.

- **Where farming begins:** each land cell has a *suitability* from its climate: the cool-season
  annuals' Mediterranean and steppe climates (a long, harsh dry season kills perennials; a
  winter, not a tropical year that only looks dry), the dry edge of the savanna, and hot
  desert along a big river (flow accumulated downhill over the cells' rain). Never rainforest
  or cold. It is multiplied by **biogeography**, which domesticable species the region had: a
  seeded field per world (`farming_suitability`; on Earth the real species would be given), which
  is why a good region may never farm. Each cell's start decade is a hash of (address, seed,
  cell) over its rate; a people arises there unless one began within 1 200 km.
- **Peoples** grow logistically to the land's capacity (rain and warmth, more along rivers) times
  what they know; knowledge grows with their numbers; a crowded cell settles the best free
  neighbouring cell. 6 000 years take about 20 ms optimized (`build bench budgets`, `planet_history`).
- Test: of the 10 likeliest farming regions on Earth's planet model (with Earth's real
  biogeography; a test only, Earth has no peoples in the game) at least 5 lie within 1 200 km of
  real early farming (Fertile Crescent, Anatolia, Nile, Indus, Yellow River, Mesoamerica, Andes,
  Sahel, New Guinea). The model's Köppen errors in Africa (central-African savanna as Csb) are why
  the bar is not higher.
