# Packs and the trust boundary

A pack is a directory of JSON and asset files that adds content (blocks, items, textures,
sounds, recipes, models, game modes, channels, simulation rules, structures) without code. The
base game is itself a pack (`assets/packs/voxiverse`, namespace `voxiverse`). This page says how
packs are laid out, loaded and sent, what a pack's rule language can do, and what the engine
treats as untrusted. The script language is in [script.md](script.md); the journal that records
every change in [journal.md](journal.md).

## Layout

```
<namespace>/
  pack.json        format, namespace, version, title, description, requires, renamed
  assets/          client-only: textures (PNG), sounds (Ogg)
  data/            both sides: blocks, items, tags, recipes, shapes, models, game modes,
                   channels, simulation rules
  server/          server-only: structures (.vxs)
```

The server sends `pack.json`, `assets/` and `data/` and nothing else; `server/` never leaves it.
A client building a registry from a pack refuses a `server/` file. The content check covers
everything both sides build from `data/`. A custom item's definition lives in `data/` (the client
must show it); anything the client must not see lives in `server/`. The directory name is the
pack's namespace; ids read `namespace:name`.

Each registry kind has one directory and one JSON object of named definitions per file
(`KIND_DIRS` in `common/game/registry_load.odin`):

| Kind | Directory |
|---|---|
| Texture, Sound | `assets/textures`, `assets/sounds` (each with a `blocks.json` naming the files or generators) |
| Block, Item, Block tag, Item tag, Recipe | `data/blocks`, `data/items`, `data/block_tags`, `data/item_tags`, `data/recipes` |
| Shape, Model, Game mode | `data/shapes`, `data/models`, `data/game_modes` |
| Channel, Sim rule, Entity | `data/channels`, `data/sim`, `data/entities` |
| Structure | `server/structures` |

A file elsewhere in a pack is refused with the layout above in the message. Pack JSON is RFC 8259
plus `//` and `/* */` comments and trailing commas; objects keep source order and every value keeps
its line and column, so every error is a `Pack_Error` of the form
`<pack>/<file>:<line>:<column>: <what is wrong>; <the fix>`. A registry has one id space per kind,
assigned in load order; packs load in the order the universe lists them.

`./build.sh packs [<dir>...]` loads the base pack plus the given pack directories the way a
universe does, prints every error and a summary with the registry hash (`tools/packcheck`). A directory's name is its pack's namespace, but for a game's own pack, `games/<game>/pack`,
which takes the game's ([games.md](games.md#the-games-pack)).

## Renamed ids

An id a pack no longer has, because its thing moved to another pack or took another name,
stays found: `pack.json`'s `renamed` maps each old name of the pack's own to the id that took
its place (`"renamed": {"pistol": "voxiverse:pistol"}`; a bare name is the pack's). A lookup by
id that misses (`registry_block`, `registry_item`, `registry_kind`: what a region's item table,
a character file, a dropped stack, a chest, `entities.cfg` and a command read) asks the packs'
renames, so a save that names the old id loads the new. The registry refuses a rename of
another pack's id, of an id still defined, or to an id no pack defines. Horde's pack keeps the
names of the creatures it gave the base pack and of the guns it now tunes (`games/horde/pack/pack.json`).

## Materials

A block is made of a material: `{"wall": {"material": "basalt_bricks"}}` is a whole block.
The material (`MATERIALS` in `common/game/materials.odin`) gives it what follows from what it
is made of: its textures (side, top and bottom: planks all round, a log's bark and its cut
ends), its sound set (one of the base pack's: `stone`, `wood`, `metal`, ...), the light it
gives (a lamp, a screen, a crystal) and whether it is seen through (glass culls its own kind;
a grating has holes; tinted glass is translucent). Its dust and its colour on a map follow
from its textures. Whatever the block says itself wins: `"light": 6` dims a lamp, `"sound"`
changes how it sounds, and `"textures"` with only `"top"` replaces only its top.

A shape says what a block of that shape is unless the block says otherwise (its `block`:
the states, how it is placed, that it is not opaque and shades, its collision), so a block
of a shape in a material is one line too:

```json
{
	"basalt_stairs": {"shape": "voxiverse:stairs", "material": "basalt"},
	"basalt_slab": {"shape": "voxiverse:slab", "material": "basalt"},
	"oak_fence": {"shape": "voxiverse:fence", "material": "oak_planks"}
}
```

The materials ship with the client: their textures are the client's generators, each the base
pack's texture of its name (`voxiverse:basalt_bricks`, made by the registry when the base pack
has none), so any pack, one from a server too, can make a block of any material without the
base pack defining one. A pack that names a material this client does not have is refused
where it names it, with the nearest name (`./build.sh packs` says so too). `./build.sh sheet`
draws them all, by family, with their names (`build/sheets/materials.png`). The materials, by
family:

<!-- materials: written from common/game/materials.odin (materials_doc) -->
- **stone and masonry** (25): `stone`, `cobblestone`, `stone_bricks`, `stone_tiles`, `polished_stone`, `basalt`, `basalt_cobble`, `basalt_bricks`, `basalt_tiles`, `polished_basalt`, `sandstone`, `sandstone_cobble`, `sandstone_bricks`, `sandstone_tiles`, `polished_sandstone`, `limestone`, `limestone_cobble`, `limestone_bricks`, `limestone_tiles`, `polished_limestone`, `slate`, `slate_cobble`, `slate_bricks`, `slate_tiles`, `polished_slate`
- **wood** (15): `birch_log`, `birch_planks`, `birch_panel`, `oak_log`, `oak_planks`, `oak_panel`, `spruce_log`, `spruce_planks`, `spruce_panel`, `redwood_log`, `redwood_planks`, `redwood_panel`, `weathered_log`, `weathered_planks`, `weathered_panel`
- **metal** (10): `iron_plate`, `riveted_iron`, `iron_grating`, `rusted_iron`, `dark_steel`, `copper`, `verdigris_copper`, `brass`, `hazard_stripes`, `pipes`
- **built and industrial** (15): `concrete`, `stained_concrete`, `concrete_tiles`, `asphalt`, `red_bricks`, `painted_red`, `painted_blue`, `painted_yellow`, `painted_white`, `glass`, `tinted_glass`, `lamp`, `screen`, `vent`, `conveyor`
- **soft and domestic** (14): `thatch`, `white_plaster`, `cream_plaster`, `ochre_plaster`, `clay_roof`, `slate_roof`, `white_wool`, `black_wool`, `red_wool`, `blue_wool`, `green_wool`, `yellow_wool`, `carpet`, `bookshelf`
- **natural** (18): `dirt`, `mud`, `dry_earth`, `grass`, `dry_grass`, `snowy_grass`, `sand`, `red_sand`, `gravel`, `clay`, `moss`, `oak_leaves`, `birch_leaves`, `autumn_leaves`, `spruce_leaves`, `snow`, `ice`, `packed_ice`
- **fantasy and dungeon** (7): `dark_bricks`, `mossy_bricks`, `rune_stone`, `bone`, `crystal`, `magma`, `obsidian`
<!-- end of materials -->

## Entity kinds

Entity kinds are `data/entities/*.json` entries (`common/game/registry_entities.odin`); the base
pack's are `engine.json`'s (`rocket`, `item`, `player`, and `dummy`, a creature that stands
where it is put: a target to hit, what the engine's tests walk, hurt and save) and
`hostile.json`'s, the creatures any game may set loose (`shambler`, `skitter`, `spitter`,
`hulk`, `matriarch`, and the `spit` the spitter and the matriarch shoot: Horde's waves, the
sandbox's nights); a
creature only one game has is its own pack's (the sandbox's sheep: `games/sandbox/pack`). A kind is a `Kind_Id` (its registry index + 1; 0 is none)
and its `Kind_Info` is `reg.kinds[id - 1]`. Fields, each checked when the registry is built
(a `Pack_Error` at the value, saying the fix):

- `box` `[width, height]`, each 0.1..4; `health` (default 1); `saved`, `summonable`, `hittable`.
- `physics` (`none`, `walker`, `item`, `projectile`) with its block of numbers (`walker`, `item`
  or `projectile`), required with it and refused without it.
- `brain` (`none`, `steered`, `game`; each but `none` needs `walker`): `steered`, the walker
  stands or goes where its game sends it ([games.md](games.md#walkers)); `game`, its game's
  mind, the game's `think` hook each tick, then steered as `steered` is. The engine has no
  creature's mind of its own.
- `voice` (`bleat`, `none`, `growl`, `squeak`, `groan`, `croak`, `grunt`, `chirp`, `chitter`,
  `whir`, `bellow`; default `bleat`): how
  one cries when it is hurt and when it dies, made by the client's synthesis (`client/sfx`:
  `creature_sound`); `none` is silent (a chest, a shot).
- `looks` (at most 16 names of `a-z`, `0-9` (not first) and `_`: bit i of what a client is
  told of how one looks is its i-th; its game shows them, `core.entity_show`, and the engine
  shows `striking` while its attack does, a blow or a shot a moment ago, and `team1` to
  `team8` for the team it is on: [games.md](games.md#sides)).
- `attack` (a `steered` or `game` walker's): `{"damage": n, "reach": blocks, "cooldown": seconds}` and,
  for a shooter, `"shot"`: a projectile kind's id. The game says when and at whom
  (`entity_strike`, `entity_shoot`: [games.md](games.md#walkers)); a blow lands within `reach`
  of the target's box, a shot flies straight at its point and, with `explode` 0, hurts what it
  hits by the damage instead of going off. How it hunts (`server/play`'s `hunt`, the same in
  every game), each optional: `keep` `[near, far]`, the blocks it keeps from its prey (`[0,
  reach]`); a shooter's `shoot` `[from, to]`, the blocks between which it shoots when it sees
  its prey (nearer, it strikes; `[0, 16]`); `notice`, the blocks within which it notices a
  player in an open world (`hunt_tick`; 16).
- `fields`: at most 8 saved numbers, `{"name": {"type": "u8"|"u16", "min": n, "max": n}}`.
- `drops`: what one leaves where it dies, at most 4 of `{"item": "<item id>", "count":
  [least, most], "chance": 0..1}` (`count` `[1, 1]` and `chance` 1 unless it says): of each,
  on a draw of its chance, a count between its least and most, drawn from the world's
  entities' randomness (`entity_drops` in `server/core/entities.odin`, booked in the item
  ledger as `drop_mob`). Only a death leaves them: one that goes (despawned, a command's
  kill, `entity_gone`) leaves nothing.
- `model`: `rocket`, `item`, `player`, `{"box": [r, g, b]}` (one box, the kind's size)
  or `{"parts": [...]}`, a shape of at most 16 boxes in the creature's own space (blocks from
  the middle of its feet, `-z` its front): each `{"box": [x0, y0, z0, x1, y1, z1], "color":
  [r, g, b]}` with an optional `skin` (`body`, `legs`, `head`: the entity pass's shading; a
  head has eyes), `swing` (`none`; `walk` and `walk_back`, to and fro with the stride, the
  other leg the other way; `strike`, forward while the kind shows `striking`, else as `walk`;
  `pitch`, up and down as the server's pitch says: a grazing head; `flap`, up and down across
  the body with the stride, a part left of the middle mirroring one right of it: a wing whose
  hinge is at the shoulder), `hinge` (`[x, y, z]`, what
  it turns about; the middle of its top, a hip or a shoulder, by default), `shown` (looks
  that must all show for it to be drawn), `hidden` (looks any of which hides it) and `colors`
  (`{"<look>": [r, g, b]}`, at most 2: its colour while that look shows). Beside `parts`,
  `scale` (`{"<look>": factor}`: the whole model sized about its feet while the look shows,
  a lamb at half) and `puffs` (`{"<look>": {"color": [r, g, b], "chance": 0..1, "height":
  blocks}}`: specks rising from it each frame by the chance while the look shows). The client
  draws it (`shaped` in `client/engine/entities.odin`) from this alone, knowing no creature;
  nothing about it is sent but the looks' bits.
- `spawn`: natural spawning (`on` a block matcher, `day` fractions from midnight, from and to (from
  above to: a night, across midnight), `every` ticks, `chance`, `cap` of the kind within `within`
  blocks of a player, `distance` from it, `group`), all required, and optional `sky` (only under
  the open sky), `despawn` (blocks from every player of its world at which a natural one goes;
  80), `safe` (blocks round its world's spawn point where none appears; 0) and `place`, where
  in its column it is looked for (`surface`, the default: on the column's top, out of water;
  `water`: in water over the column's bed, which is `on`, two blocks deep at least, the
  water's surface being the column's top; `cave`: on the floor of the first hollow going down
  from 4 to 48 blocks under the column's top, the floor being `on`). The engine's spawner (`spawn_natural`) is the same for every
  kind; its game's `spawned` hook makes each one what it is or refuses it
  ([games.md](games.md)).

What a kind does each tick follows from these fields, not from its name: the server's entity
systems (`entities_tick` in `server/core/entities.odin`) each run over the entities whose kind
has their data, in this fixed order:

1. age: every entity gets a tick older; a natural one with no player of its world within its
   kind's `despawn` distance goes (in a world with no player in it, none goes).
2. brains: each kind's brain over its creatures, once a tick for the whole kind (the kinds in
   id order, the creatures lowest id first; one born during it gets its turn in the same tick).
   `brain: game`: its game's `think` hook. Then `brain: steered` and
   `game`: the way its game or its brain sent it (a point, a route, a band of distances from
   a point), its attack's cooldown, and a push out of any walker or player it overlaps.
3. walkers' physics: `physics: walker`. Each takes its step with the wish its brain made (none
   without a brain); one whose ground is not loaded waits.
4. items: `physics: item`. Expiry, falling, merging, pickup.
5. rockets: `physics: projectile`. Flight and hits; the explosions wait for the end (a
   projectile with `explode` 0 hurts what it hit and is gone).
6. explosions: the blasts the rockets made go off.

A kind in a pack that is a walker with no brain falls and stands still; nothing in the code names it.

## Simulation rules

Simulation rules are `data/sim/*.json` entries. Their behaviour runs on the server only
(`server/core/sim_interp.odin`), and every write goes through `set_block` and `set_channel` like
any change, so the journal, the wakes and the clients' updates are the engine's.

- `"behaviour": "flow"` is a fluid (levels, falling block, delay, reach, whether sources form).
- `"list"` is an ordered block list; a flow rule is a list of its blocks, so no fact is written
  twice.
- A statement rule has `blocks`, a `trigger` (`scheduled` or `random`), `wake` conditions
  (`placed`, `neighbour`, `load`) and a `do` array. Each statement, condition and expression is a
  short string in a bounded language lexed by `common/game/sim_lexer.odin` (at most
  `MAX_RULE_TOKENS` = 64 tokens, no escapes, so a token's column is exact); the envelope (the
  statement tree with `if`/`then` and `repeat` objects) is JSON. `assets/packs/voxiverse/data/sim`
  has working examples (`growth.json`, `water.json`).
- Everything that bounds a rule is checked when the registry is built, each refusal one
  `Pack_Error` at the token at fault: reach `RULE_REACH` = 8 cells, cost `RULE_MAX_COST` = 4096,
  `RULE_MAX_STATEMENTS` = 64, nesting `RULE_MAX_DEPTH` = 4, `RULE_MAX_PICKS` = 4, `RULE_MAX_BOX` =
  9, `RULE_MAX_BLOCKS` = 16 per rule, `RULE_MAX_LIST` = 64, `RULE_MAX_ERRORS` = 20 reported.
  The compiled program is a flat, index-linked `Rule_Program` that points into nothing but the
  registry's arena. The interpreter has no recursion and no loop but `repeat`, and allocates
  nothing.
- Data rules are deterministic ([determinism.md](determinism.md)); they draw randomness only from
  the tick's stream.

Rules are pack JSON, not a file format of their own, so they reuse the registry, the pack hash,
hot reload, packs over the wire and the pack fuzz targets.

## Packs on the wire

A universe's packs are fixed while it runs: `universe.cfg`'s `packs` line lists their namespaces
(the base pack is always first and never listed), each in `<universe>/packs/<namespace>/`, and the
registry is built once at start. It never grows, and no pack is sent in the middle of a session.
A server that runs a game ([games.md](games.md)) loads the game's own pack after the universe's
(`Game.pack`, named for the game; `game_packs` in `server/core/universe_packs.odin`), and only
then: it is one more pack of the session, hashed into the registry and sent to joining players
like the others, and a client hosting the game builds it in from its own copy.

- **Archive.** `pack_archive_make` writes one pack as one canonical file: `VXPK`, a version,
  a file count, then per file in byte order of path the path, the size and the bytes, so the
  same files always give the same bytes. The pack's hash is the SHA-256 of that archive.
- **Join.** After the `Proof` the server sends `Packs`: every pack in the universe (up to
  `MAX_PACKS` = 32) with its size and hash, in load order, and the registry hash they make. The
  client takes what it has in its cache (`<cache>/<sha256>.vxpack`, least recently used dropped
  past 256 MiB), asks for the rest with `Pack_Want`, and receives `Pack_Part`s (1100 bytes each,
  at most 32 KiB per tick per client). It checks each pack's size and hash as its last part
  arrives and builds the registry; the registry hash must equal the server's. A client spends at
  most 120 s in this phase. Every pack is sent whether or not the player visits the worlds that
  use it.
- **Limits.** An archive lists at most `MAX_PACK_FILES` = 1024 files of at most `MAX_PACK_PATH`
  = 128 bytes of path, a file is at most `JSON_MAX_FILE` = 1 MiB, a pack at most `MAX_PACK_BYTES`
  = 16 MiB. `pack_archive_read` refuses every way an archive can be wrong with a message: it came
  over the network.
- **Hot reload** (development builds, `Config.pack_watch`; the owner's `pack reload` reloads at
  once). The server watches the base pack's source directory and the universe's `packs/`; a reload
  that would change the number of any block, item, texture or sound set is refused (the registry
  never grows), the old registry stays on any error, and the swap waits until no chunk job and no
  save is reading it. `Packs_Changed` carries the new registry hash to a client on the same
  machine, which builds the same registry from the same files; no pack file is sent.

## Assets

A pack's PNGs and Oggs come over the network, so they are read by bounds-checked Odin only and
checked when the registry is built (`common/game/pack_assets.odin`):

- A block texture is exactly 16 x 16 pixels, at most `MAX_PNG_BYTES` = 64 KiB. The header is read
  before the decoder (a PNG of a huge size packs into a few bytes); the file's chunks and its
  zlib stream are checked first (`png_ok` in `common/game/png_check.odin`, CRC'd chunks and a
  complete deflate structure, at most 4 KiB of output); `core:image/png` decodes only what
  passed into RGBA8.
- A texture that names a generator is a layer of the atlas the build made (`client/texture`,
  run by `tools/atlas` into `build/textures/`, carried in the executable: nothing is drawn when
  the client starts). A PNG is one more layer after the atlas's, its mips made by the client
  the way the build made the atlas's (`texture.mip_chain`). So a pack a server sends can name
  only the generators every client has, or bring PNGs. `./build.sh sheet` draws every pack's
  textures to look at (`build/sheets/<pack>.png`, `tools/sheet`): its own large and named, by
  family (`texture.Family`), then each one its blocks show tiled 3 x 3 as in the world, where
  seams and repetition show, with the blocks that show it.
- A sound is an Ogg of at most `MAX_OGG_BYTES` = 1 MiB and `MAX_SOUND_SECONDS` = 5 s, scanned for
  its length and decoded once by `common/ogg`, so the client only plays a file that passed.
  File-based sound sets total at most `MAX_PACK_SOUND_FILES` = 128 files over all packs.
- `common/ogg` returns an `Error` for anything malformed, with every size a constant and one
  allocation. Both decoders are fuzzed ([fuzzing.md](fuzzing.md)).
- A pack directory read from disk (`server/packs`) refuses symlinks, so a pack reads only what is
  inside its directory, and skips files past the limits without reading them.

## What is untrusted

The engine is a replicated, deterministic simulation of a voxel field and its entities, in which
every change has a cause and a history. Four things are untrusted: scripts and packs (buggy or
hostile), player input, generated text and names, and the pack transport.

| Surface | What holds |
|---|---|
| Pack transport | The archive limits and hash check above; JSON limits (`JSON_MAX_DEPTH` 32, `JSON_MAX_STRING` 4096, `JSON_MAX_ENTRIES` 4096, `JSON_MAX_FILE` 1 MiB); rule bounds checked at load. |
| Decoders | Odin only: pack PNGs by `core:image/png` after the checked zlib walk (`png_ok`), pack Oggs by `common/ogg`. No C parses a hostile file; a pack's only code is a rule program the registry compiles. |
| Network messages | Validated at the edge (ground rule 6 in [design.md](design.md)): ranges, length caps, a schema hash at join, fuzz targets for every decoder. |
| Script VM | Memory-safe by construction, deterministic (no ambient clock, random, hash order or I/O), metered in instructions, memory and call depth, state serializable ([script.md](script.md)). Scripts are never transpiled or compiled to native code. |
| Script authority | A script has no ambient authority. `server/core/script_api.odin` holds the typed natives for the party systems, each behind a named capability (`players.read`, `players.mode`, `rules.read`, `rules.set`, `players.damage`, `players.respawn`); a native records its cause as `script:<pack>` in the journal. The VM runs in `build script`, the benchmarks and the fuzz targets; the server does not run scripts. |
| Items | Every item entering or leaving what the server holds is one `ledger` call with a reason (a faucet counts positive, a sink negative); an audit sums everything held against the entries and reports a mismatch without fixing it. |
| Damage from bad changes | Every block change carries an actor, a system and a mechanism in the journal; a bad actor's changes are undone from it ([journal.md](journal.md)). |
| Telemetry | Aggregate behaviour only: no names, chat text or addresses ([telemetry.md](telemetry.md)); the consent question is off by default (`telemetry.ask` = 0) and nothing is sent while it is unanswered. |

## Workshop packs

With Steam on (docs/platforms.md, "Steam"), the packs a player subscribed to on the Steam
Workshop are one more pack source beside the local ones; with Steam off the source does not
exist (`client/steam/workshop.odin`).

- **Layout.** An item's folder (Steam names it by the item's id) holds the pack as a sub-folder
  named by its namespace, in the layout above. An item with no pack folder is refused.
- **Trust.** Nothing from the Workshop is trusted more than a local pack: its folder is read by
  `server/packs` (symlinks and files past the limits refused) and the result goes through the
  same `registry_build`, so a malformed item fails with the errors a local pack gets.
- **Where a listed pack is found.** `universe.cfg` lists packs by name as always; there is no
  format change. A listed pack is looked for in the universe's `packs/<namespace>/`, then in the
  local packs folder (`<user data>/voxiverse/local_packs/<namespace>/`), then in the subscribed
  Workshop items. The client reads the last two once per session and gives them to the server
  (`Config.available_packs`) and to `registry_for_dir` alike, so both build the same registry. A
  subscribed item no universe lists is never loaded.
- **A bad item** is treated like a bad local pack: a universe that lists it does not open, and
  the `Pack_Error` (or the read problem, with "Workshop item <id>") names it. It is never skipped,
  because a world built on a pack must not open without it. An item with no pack folder names no
  pack, so nobody can list it: that is logged, not refused. Exporting a universe still takes only
  the packs in its own `packs/` folder.
- **Publishing.** The console command `workshop_publish <namespace>` publishes a pack of the local
  packs folder. `workshop_publish_info` takes the title and description from its `pack.json` and
  the preview from a `preview.png` of at most 1 MiB in its folder; `workshop_publish` hands them to
  Steam. The real Steam does not publish yet; the fake records the call. A menu entry waits for a
  pack screen.
