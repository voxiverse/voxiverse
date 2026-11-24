# Packs and the trust boundary

A pack is a directory of JSON and asset files that adds content (blocks, items, textures,
sounds, recipes, models, game modes, channels, simulation rules, quests, dialogues, structures) without
code. The
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
                   channels, simulation rules, quests, skills, a level curve, dialogues
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
| Channel, Sim rule, Entity, Quest | `data/channels`, `data/sim`, `data/entities`, `data/quests` |
| Skill, Level curve | `data/skills`, `data/levels` |
| Dialogue | `data/dialogues` |
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
- **stone and masonry** (33): `stone`, `cobblestone`, `stone_bricks`, `stone_tiles`, `polished_stone`, `basalt`, `basalt_cobble`, `basalt_bricks`, `basalt_tiles`, `polished_basalt`, `sandstone`, `sandstone_cobble`, `sandstone_bricks`, `sandstone_tiles`, `polished_sandstone`, `limestone`, `limestone_cobble`, `limestone_bricks`, `limestone_tiles`, `polished_limestone`, `slate`, `slate_cobble`, `slate_bricks`, `slate_tiles`, `polished_slate`, `red_rock`, `amber_ore`, `opal_ore`, `cryolite_ore`, `sulfur_ore`, `ilmenite_ore`, `jade_ore`, `nacre`
- **wood** (15): `birch_log`, `birch_planks`, `birch_panel`, `oak_log`, `oak_planks`, `oak_panel`, `spruce_log`, `spruce_planks`, `spruce_panel`, `redwood_log`, `redwood_planks`, `redwood_panel`, `weathered_log`, `weathered_planks`, `weathered_panel`
- **metal** (10): `iron_plate`, `riveted_iron`, `iron_grating`, `rusted_iron`, `dark_steel`, `copper`, `verdigris_copper`, `brass`, `hazard_stripes`, `pipes`
- **built and industrial** (15): `concrete`, `stained_concrete`, `concrete_tiles`, `asphalt`, `red_bricks`, `painted_red`, `painted_blue`, `painted_yellow`, `painted_white`, `glass`, `tinted_glass`, `lamp`, `screen`, `vent`, `conveyor`
- **soft and domestic** (14): `thatch`, `white_plaster`, `cream_plaster`, `ochre_plaster`, `clay_roof`, `slate_roof`, `white_wool`, `black_wool`, `red_wool`, `blue_wool`, `green_wool`, `yellow_wool`, `carpet`, `bookshelf`
- **natural** (25): `dirt`, `mud`, `dry_earth`, `grass`, `dry_grass`, `snowy_grass`, `sand`, `red_sand`, `gravel`, `clay`, `moss`, `oak_leaves`, `birch_leaves`, `autumn_leaves`, `spruce_leaves`, `snow`, `ice`, `packed_ice`, `ash`, `regolith`, `mycelium`, `fungus_stem`, `fungus_cap`, `glow_cap`, `spore_sprout`
- **fantasy and dungeon** (7): `dark_bricks`, `mossy_bricks`, `rune_stone`, `bone`, `crystal`, `magma`, `obsidian`
<!-- end of materials -->

## Items

An item is a `data/items/*.json` entry (`read_item` in `common/game/registry_resolve.odin`);
a block players may place has its item made for it. Every field is optional:

- `stack` (1..999, 64), `places` (the block it puts down), `description` (its tooltip's
  line), `model` (the voxel model it is drawn and held as), `rarity` (`common`,
  `uncommon`, `rare`, `epic`, `legendary`; `common`: the colour its tooltip names it in).
- `equip` (`head`, `chest`, `legs`, `feet`, `offhand`) and `modifiers`, at most two
  `{"stat": ..., "amount": n}` that count while it is worn there (`derive_mods`, the server
  and the client's prediction alike): `speed` and `jump` (fractions added), `air_jumps`,
  `max_health` (points), `defence` (a fraction of every harm taken off; all that is worn
  together, and a consumable's, take off at most `MAX_DEFENCE`, 0.8) and `fall_guard` (a
  fraction of a fall's harm taken off after that; 1: none).
- `weapon`, `melee`, `grapple` (a gun, a blade, a hook: [games.md](games.md#walkers)).
- `gather`: `{"tier": 0..3, "yield": 0..4, "speed": 1..20, "kind": "pick"|"blade"|"any"}`
  (`tier` required): held in the hand, it breaks the blocks of its tier and below (a
  block's `tier`, 0..3; 0, every block that names none, hands break), each block of tier 1
  or above it breaks leaves `yield` more of its drop, and where breaking takes time (below)
  it breaks `speed` times as fast as hands a block its `kind` is quick on (half that, at
  least hands', on a block of `any`; hands' on the rest). A player whose mode has
  `instant_break` breaks every tier; one that does not is told what tier a block needs and
  keeps it (`can_gather`, asked by the server).
- `consume`: `{"heal": n, "regen": n, "defence": f, "seconds": s}`: what one does used up
  (its game calls `core.item_consume` when its player uses the stack in its hand): `heal`
  health at once, then for `seconds` `regen` health a second and `defence` taken off every
  harm, in place of what one used before still did; a death ends it, and it is not saved.

### Breaking time

A block's `hardness` (0..60) is the seconds bare hands take to break it and its `tool`
(`pick`, `blade`, `any`) the kind of tool quick on it; a block that names neither takes its
material's: stone and masonry 2.5 s for a pick, wood 2 s for a blade, metal 4 s, built and
industrial 2 s and fantasy 3 s for a pick, soft and domestic 0.8 s for a blade, natural 0.6 s
for any (leaves 0.3 s for a blade); a block of no material, a crossed plant at once, any
other half a second. What a world's breaking takes is its rule `break_time` times that over
the tool's speed (`game.break_ticks`, rounded up to whole ticks); the rule is 0, at once, unless a
game sets it (the sandbox: 1), and a mode with `instant_break` (creative) breaks at once
anyway. Holding the attack button on a block, the client tells the server it began (an
`Edit` of id 0 and face `EDIT_FACE_BREAK_BEGIN`, after its last input), counts its own
inputs to the block's ticks while drawing the crack spreading on its faces
(`client/engine/camera.odin`, `break_cracks`), and sends the break; the server counts the
same inputs between the begin and the break and refuses one sent sooner (inputs are one a
tick and capped, so a client cannot count faster than the server ticks). Let go, or aim at
another block, and it starts again.

### Harm on touch

A block's `harm` (0..100, health a second; none by default) is what it takes from a player
touching it: standing on it or in it, at any corner of the player's box
(`game.touch_harm`). The server takes half of it twice a second (`health_tick`), through the
damage pipeline as a `contact` harm ("You were burned"), so armour, effects, modes and
spawn protection count as for any harm. The base pack's magma has 4 (a volcanic world's
sea, common/worldgen/classes.odin).

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
- `threat` (0..99, default 0): how dangerous one is, what a kill's experience counts by and
  the target frame shows ([below](#levels-and-skills)); 0 works it out from its health and
  its blow (`game.kind_threat`: a tenth of its health and four for each point of its
  `attack`'s damage, rounded up, 1 at least).
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

## Quests

A quest is a `data/quests/*.json` entry (`common/game/quest.odin`, read by
`registry_quests.odin`): a `title`, a line or two of `text` (why, in the world's voice), its
`steps` in order (1 to 8), a `reward` (at most 4 `{"item", "count"}`, given when its last step
is done), `xp`, the experience it gives then (0 when none: [below](#levels-and-skills)), and
`after`, the quests (by id, at most 4) done before it opens. A registry holds at
most 32 (`MAX_QUESTS`); the base pack has none, a game's pack brings them (the sandbox's first
hour: `games/sandbox/pack/data/quests`).

```json
"edge_and_point": {"title": "Edge and Point", "text": "A blade for the brush, a point for the rock.",
                   "after": ["sandbox:waking"],
                   "steps": [{"text": "Make a flint pick", "goal": "make", "item": "sandbox:flint_pick"}],
                   "reward": [{"item": "sandbox:field_dressing", "count": 1}]}
```

A step is its `text`, its `goal` and what the goal names, a `count` (1 when none) and maybe a
`way`, `{"place": <kind>, "name": <its name>}`: while it is the step, the compass and the map
point at the nearest place of that kind (and name) in the player's logbook in the world it is
in, and at nothing while the logbook has none (a way reveals nothing; a `find` step points at
the place it asks for). Each goal is a condition over what the server already knows of the
player, and counts only while it is the step:

| Goal | Names | Done when |
|---|---|---|
| `have` | `item` | the player carries `count` of it at once (slots, what it wears, the cursor) |
| `make` | `item` | it made `count` of it: the game tells (`core.quest_note`; the sandbox's crafting) |
| `place`, `break` | `block` | it placed or broke `count` blocks of the type |
| `find` | `place` (`gate`, `ruin`, `town`, `outpost`, `beacon`, `remains`, `settlement`), maybe `name` | its logbook has such a place (in any world) |
| `kill` | `creature` | it killed `count` creatures of the kind (its blow, shot or blast) |
| `use` | `item` | it used up `count` of the consumable |
| `win` | `name` | it won the game's encounter of that name (`core.quest_note`; the sandbox's ruin is `sandbox:ruin`) |
| `address` | | it wrote an address on a gate within reach, whatever answered |
| `talk` | `name` | it said something of that name to someone: the game tells (`core.quest_note`; the sandbox's conversations note a dialogue's id as one begins and a reply's `talk`) |

Quests are read after every other kind, so each id a step or reward names is checked
(`"sandbox:nothing" is not an item`), and a quest that comes after itself by any way round is
refused, as is a field its goal does not take or a `count` on a step that counts once (`find`,
`win`, `address`, `talk`). Where it is played, the server keeps each character's progress (`quests` in its
file, [saves.md](saves.md)) and sends it to its player (the `quests` record), and nothing
counts for a player who cannot be hurt (creative, a watcher); the journal (J) lists the quests
under way and done, and the HUD's tracker shows the step of the one followed.

## Levels and skills

What a character grows by (`common/game/skill.odin`, read by `registry_skills.odin`): a level
curve, `data/levels/*.json` (one entry in a registry at most), and a skill sheet,
`data/skills/*.json` (at most 32 skills, `MAX_SKILLS`, in at most 4 branches; skills need a
curve). The base pack has neither; a game's pack brings them (the sandbox's:
`games/sandbox/pack/data/levels`, `data/skills`).

```json
"survivor": {"levels": [100, 250, 450], "points": 1,
             "xp": {"kill": 3, "meet": 5, "make": 10, "win": 150},
             "find": {"ruin": 100, "remains": 30},
             "respec": "sandbox:outpost_beacon", "respec_reach": 6}
```

`levels` is the total experience each level from 2 takes, rising (so the highest level is
one more than their count, at most 100); `points` the skill points each level gives (1 when
none). `xp` is what each deed earns: `kill` for each point of the creature's `threat`,
`meet` a creature met for the first time (into the logbook), `make` an item made for the
first time (a game's crafting, `core.quest_note`), `win` an encounter won; `find` what a
logbook place of each kind found earns (a kind it does not name: none); a quest's own `xp`
comes with it. `respec` is the block a player stands within `respec_reach` blocks of (5 when
none) to unlearn every skill for nothing (none: anywhere).

```json
"quick_hands": {"title": "Quick Hands", "text": "Blocks give way a tenth sooner a rank.",
                "branch": "Survival", "effect": "break_speed", "amount": 0.1,
                "ranks": 3, "cost": 1, "needs": 0}
```

A skill is a plain number over one rule the engine already has: its `effect`, `amount` what
each of its `ranks` (1..5, 1 when none) adds, `cost` the points a rank costs (1..5, 1 when
none), `needs` the points its `branch` must have had spent in it before it opens (0 when
none). The branches are the skills' `branch` names in the order they first come. An effect
adds its amounts to the rule, or (a factor) multiplies it by one plus them, never under a
tenth (`SKILL_EFFECTS`):

| Effect | Rule | How |
|---|---|---|
| `break_speed` | how fast a block breaks (a factor on the tool's speed) | factor |
| `yield_chance` | the chance a block of tier 1 or above leaves one more of its drop | added |
| `drop_chance` | added to the chance of each of a killed creature's drops | added |
| `max_health` | health points on the most | added |
| `defence` | a fraction of every harm taken off, beside what is worn (at most 0.8 together) | added |
| `fall_guard` | a fraction of a fall's harm taken off, beside what is worn | added |
| `regen` | health coming back by itself | factor |
| `consume_strength` | what a consumable heals, at once and over time | factor |
| `melee_damage` | a swung weapon's damage | factor |
| `reload_time` | a reload's time (negative: quicker) | factor |
| `spread` | a shot's cone (negative: tighter) | factor |
| `craft_time` | a recipe's time (a game's crafting) | factor |
| `craft_yield` | the chance a recipe made gives one more of what it makes (a game's crafting) | added |

Every rule reads the ranks through one pure function, `game.skill_value(reg, ranks,
effect, base)`; with no ranks it is `base`. Where it is played, the server reads it where it
reads each rule (`server/core`: a break's ticks, a block's drop, a creature's drops, the
most health, defence and fall guard, regeneration, a consumable, a swing, a gun's reload and
cone; a game's own rules through `core.skill_value`), and the client, where it predicts a
rule (a break's ticks, a reload, a shot's rays), from the ranks the server sends it (the
`progress` record), so both count alike. Experience is earned only by a survivor (not in
creative, not watching) and kept as the character's counter `xp`, its level as `level`;
the skills learnt are kept in its file ([saves.md](saves.md)). A player learns a rank with
`/skill <id or name>`, sees its points with `/skill`, and unlearns them all with `/skill
reset` within the curve's `respec_reach` of its `respec` block; `/xp <player> <amount>` (the
`player.xp` permission) gives experience.
## Dialogues

A dialogue is a `data/dialogues/*.json` entry (`common/game/dialogue.odin`, read by
`registry_dialogues.odin`): what a person says and what a player may answer, as a small graph.
Its `title` (who speaks, as a player reads it where the game gives no name of its own), its
`start` (the openings in order, each an `if` and the node it goes to; the last has no `if`, so
a conversation always opens) and its `nodes` by name, each a line (`text`, at most 320 bytes)
and 1 to 4 `replies`. A reply is its `text` (at most 80 bytes), maybe an `if` (conditions, all
of which must hold for it to be offered), a `do` (effects, done in order) and a `go` (the node
it goes on to; none: the conversation ends). Every node has one reply always offered (no `if`,
nothing taken, nothing costed), so a player can always answer. A registry holds at most 32
dialogues of at most 32 nodes; the base pack has none (the sandbox's folk:
`games/sandbox/pack/data/dialogues`).

```json
"medic": {"title": "Medic",
          "start": [{"if": [{"quest": "sandbox:hides_for_the_healer", "step": 3}], "go": "hides"}, {"go": "hello"}],
          "nodes": {"hello": {"text": "Sit down. Where does it hurt?", "replies": [
              {"text": "Patch me up (3 silver)", "if": [{"hurt": true}], "do": [{"cost": 3}, {"game": "heal"}], "go": "hello"},
              {"text": "Goodbye"}]}}}
```

| Condition | Holds when |
|---|---|
| `{"quest": <id>}`, with `"step": n` | the quest is under way (open, not done); on its step n (1 its first) |
| `{"done": <id>}` | the quest is done |
| `{"have": <item>, "count": n}` | the player carries n of it (1 when no count) |
| `{"found": <place kind>, "name": <name>}` | its logbook has such a place (of the name, when one is given) |
| `{"hurt": true}` | its health is below its most |
| `{"level": n}` | its level is n or more (`game.level_of` its experience; the levels: [above](#levels-and-skills)) |

| Effect | Does |
|---|---|
| `{"give": <item>, "count": n}`, `{"take": ...}` | n of the item into the player's slots, or out of them (a reply that takes is offered only while it carries them) |
| `{"cost": n}`, `{"pay": n}` | n of the game's money from the player (offered only while it has it), or to it |
| `{"talk": <name>}` | the player said it: a quest's `talk` step of that name counts it |
| `{"game": <name>}` | the game's own action of that name (the sandbox's: open the market, heal, mark a place) |

Dialogues are read after the quests, so every id they name is checked; a node a `go` names
that the dialogue lacks, a field a condition or an effect does not take, or a node no reply
of which is always offered is refused with where and why. What a dialogue offers and what a
reply does are pure functions of it and of what the server knows of the player
(`dialogue_opening`, `dialogue_offered`, `dialogue_answer`): the server is the authority, and
a reply a client sends that it is not offered is refused before anything is done; the client
only shows the lines (its registry holds the same dialogues). What the money is and what a
`game` effect does are the game's.

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
