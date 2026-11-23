# Sandbox

The engine's open world as a game, the one game players are offered (the title's
Singleplayer lists its universes), and the game a session plays when nobody names another
(`game.DEFAULT_GAME`). Players know it by the product's name, Voxiverse (its `INFO.name`);
the folder, the id and what saves and the wire carry stay `sandbox`. A universe of planets,
the home world Earth or one made from the seed, with its climate, sheep, farming, peoples and
their markets, and gates between worlds: build, explore, survive or create. There is no round
and no score. A new player is given the rocket launcher.

## Playing it

```sh
./build.sh run                                # the title: Singleplayer lists its universes
./build.sh run -- --game sandbox              # straight into a scratch Sandbox world
./build.sh serve -- --universe build/universe # the dedicated server plays it by default
```

The title's Singleplayer opens the saved universes; a new one made there (its planet, seed and
mode) plays the sandbox. The other games are met inside it as encounters (Horde's waves at
the ruined site, below) and run on their own only as dedicated servers.

## Its sheep

The sandbox's animals are its own: the sheep (`sandbox:sheep`, its pack's creature, whose mind
is the game's). A sheep stands and looks about, watches a player who comes within 6 blocks,
wanders up to 8 blocks, grazes (a shorn one eats the grass in front of it, which turns to dirt,
and its wool grows back) and runs from what hurt it. They come by themselves by day on grass,
in groups of one to three, at most six near a player (the pack's spawn rule), with wild genes.

Using one (the right button) with wheat feeds it: a lamb grows up a tenth sooner, an adult
becomes ready to breed for 30 seconds. Two ready sheep within 8 blocks walk together and have a
lamb of both, which grows up in ten minutes; then each waits five. Using an adult with anything
else shears it: one to three wool fall, black for a black sheep, and it is shorn until it
grazes. Their genetics are real and tiny (`genetics.odin`): two genes, wool (white or black)
and coat (plain or spotted), each with a rare recessive form; a lamb takes a copy of each from
each parent, and one copy in a thousand flips. What a player sees of one (shorn, a lamb, black,
spotted, in love: hearts rise) is its looks, shown by the server part and drawn from the
pack's model.

`/sheep [lamb] [shorn] [black] [spotted]` sets a sheep of those looks down in front of you
(the summoning permission, `world.summon`).

The statistics it keeps of a player: `sheep.sheared` (5 experience each) and `sheep.fed` (2),
and of a world `sheep.born`, shown with the engine's.

## Its nights

From dusk to dawn (a fifth of the day either side of midnight) the base pack's hostile
creatures come out in every world of the sandbox: shamblers in ones and twos, now and then a
pack of two or three skitters, on open ground (grass, dirt, sand) under the sky, 24 to 40
blocks from a player, never within 48 blocks of the world's spawn point, at most three of each
kind near one player. The rules are the sandbox pack's data (`pack/data/entities/hostile.json`,
overriding only the creatures' `spawn`) and the engine's spawner runs them, so they come from
each world's seed and tick like everything else, within its entity budget; a natural one goes
when nobody is near. Each goes for the nearest player within 16 blocks who can be hurt and
strikes it (`play.hunt_tick`, `server/danger.odin`); one in creative mode, or watching, is left
alone. They drop nothing (a kind has no drops as data). The spitters, hulks and the matriarch
come only in Horde's waves, which are fought at the ruined site (below) too.

## Its ruined site

Every home world has a ruin, a few minutes' walk from the spawn: on ten rings round it from
240 to 456 blocks out, sixteen spots on each starting in a direction of the world's seed, the
first whose ground is dry and level (no sea, beach, river, lake, mountain, ice or overhang
under it or its apron, the land within 5 blocks of even); when none is, the dry spot whose
land is the least uneven. Its floor is the middle height of the land there (never under the
sea's top), and the ground is levelled as it is built: everything over the floor cleared over
the ruin and a 4-block apron round it, the hollows and the water under them filled with
stone, the apron's top grass, so it is never buried or perched and every gate opens on ground
(over 60 seeds, 35 sites were level, one touched water, and the land under the walls was at
most 11 blocks uneven before levelling). It is a square of broken walls 27 blocks wide with a gate in the
middle of each side, a tower in one corner whose lamps show it from afar, four stumps of
pillars, cracked ground in the other corners and a dais in the middle with the altar
(`sandbox:ruin_altar`) on it. It is built when a player first comes within 160 blocks of it in
a session (its ground is kept loaded while one is near, or while it is awake), whole, over
what stood there, so what a blast or a crash left is gone; its blocks are not the players' to
change.

Using the altar (the right button) wakes it, for everyone inside its walls who can be hurt
(not in creative, not watching; one who has things set aside already cannot wake it). Each of
them is locked in to fight: its own things are set aside (kept with its character, untouched
by death, saved with it) and the mode it was in remembered; it is put in the encounter's mode
(`sandbox:encounter`: health, nothing dropped at death, a pistol, a rifle, a shotgun and 90
rounds), and a ward of crystal (`sandbox:ruin_ward`) rises round the walls. Five waves come out
of the four lairs, Horde's waves (`common:wave`'s plan and `server:play`'s crowd: shamblers
from the first, skitters from the second, spitters from the third, hulks from the fourth, the
matriarch with the fifth, each wave an eighth tougher), three seconds after it wakes and ten
seconds after each wave is held; between waves each fighter gets 30 rounds and 10 health. While
it is awake nobody gets out and nobody gets in: a fighter outside the walls is put back by the
altar, anyone else inside is put out by the south gate, and a creature that gets out is gone and
comes out of a lair again. The night's creatures (danger, above) leave the fight's alone.

The guns are tuned as Horde tunes them (loading the ruin's rounds, `sandbox:round`; a reload
takes them from the pockets, and with none the gun stays empty), but only for the players in
the encounter's mode: the tuning is the mode's `weapons` (`pack/data/game_modes/encounter.json`,
the engine's `game.weapon_of`), not an `"override"` of the items, so every other player's guns
stay the base pack's. Nothing of the kit leaves the fight: a fighter cannot throw anything
away while it fights (the `dropping` hook refuses it), and the ruin's rounds vanish when
anyone not fighting walks over one.

The fight ends when the fifth wave is dead: every fighter standing has its own things back (in
place of the encounter's) and its own mode, and the altar drops each a sniper, jump boots and
a feather charm. A fighter who dies is out of it: it stands again at the world's spawn as any
death in the sandbox does, with its own things and mode given back as it stands, so it loses
nothing it brought. When no fighter is left the fight is lost. A fighter who leaves the server
is out too; its things stay set aside with its character and come back when it next joins (also
after a server that stopped during a fight), and it is put out of the ruin if it joins inside.
Then the ward falls and the ruin sleeps until its altar is used again. A fight does not outlive
the session.

What it tells its fighters: `sandbox.ruin` (the fight's phase, wave, creatures left and
seconds of a countdown or break; drawn as a bar across the top), and a notice as the ruin
wakes, each wave sets out and is held, and a fighter falls.

## Its remains

A new universe's home world has the remains of whoever stood its gate there, so its first
minutes have things to see and walk to; nothing says what they were (`server/remains.odin`
places them, `server/remains_build.odin` draws them). All of it comes from the world's seed:

- **The court.** The dead home gate stands a step down in a worn platform of slate tiles (21
  by 11 blocks round the gate's box, its floor a layer over the gate's platform), with gravel,
  moss and grass through it, a broken parapet open in front of the gate and toward the road,
  up to three rings of steps down (or up) to the land round it, copper conduits in its floor
  behind the gate, four pylons of dark steel on plinths (two flanking the gate, two behind it;
  one or two stand whole with grating and a copper cap, the others are broken low, their pieces
  lying on the floor) and up to eleven standing stones 18 to 20 blocks from the gate, some
  gone, some fallen, none on the spawn's side. The spawn, 8 blocks in front of the frame,
  looks at it.
- **The old road.** Stretches of paving (8 to 16 blocks, 12 to 36 apart) with kerbs and posts,
  from out of the court toward the ruin (below) to short of its apron, broken off where the
  water or a cliff took it.
- **Scattered remains**, 60 to 380 blocks from the gate, one of each kind and four or five more,
  at least 40 blocks apart: a fallen pylon beside its stump, its copper head at the far end; a
  wall half buried, rising and falling along its length, with a doorway and sometimes a corner;
  a round tower fallen in on one side, its rubble spilled, a chest inside one in two; a grassed
  mound over a sealed chamber of riveted iron whose dark steel door shows in a cut, with a chest
  inside (one digs in); a ring of standing stones round a dead plinth. Each is drawn from its
  own seed (its size, its way, its breaks, what grows on it) and follows the land, sunk a block
  into it. The chests hold a few of seeds, wheat, lamps, a hoe, a cap, boots or a grappling hook.

Every site stands on dry ground not too uneven for its kind, clear of the court, the ruin's
apron, the generator's structures and each other. Over 60 seeds of the Earth generator: 4 to
10 scattered sites a world (8.9 on average), every kind in 58 to 60 of the 60 worlds, the road in
53 (in the others the way to the ruin is water or cliffs), at most 1% of a site on wet ground.
A site is built in one paste when a player comes within 192 blocks of it and its ground is
loaded (the court as the first player arrives), and is then the world's like any block: dig
it, take what the chests hold. The world's `sandbox.remains.txt` remembers which are built; a
world saved before there were remains gets none, so nothing is built over what its players
made.

## Its peoples and markets

On a world built on the planet (the home world when it is Earth), the sandbox keeps the
towns' markets (`economy.odin`, `market.odin`, `trade.odin`: docs/world.md describes the
model), on the peoples' history and settlements of `common/planet` (which stay there: the
benchmark tool, which may not import a game, times them). The history is a function of
the planet, the world's address and seed and the day; the towns it implies near the players
have markets in detail, stepped a market month (30 world days) at a time, with news and
caravans between them; the rest are priced lazily from the history, so a town left and come
back to does not jump. What the history does not give back (the detailed stocks, what the
lazy towns remember) is kept with the world, `sandbox.economy.vxe`.

Each character is a trader (its record, kept in its character file): silver (20 to start),
cargo of each good, and the prices it saw where it stood. Standing in a town (within 15 km of
it) the HUD says `Market of <town>` and the key that opens it; the game's action (`Market`,
Z by default) opens the market's screen there and pressed again closes it: each good's
price, stock (units of a person's month of the good: a fresh market holds one month of the
town's need of each, so every stock reads the same until trade and droughts move them), what
you carry and how old the news behind the price is; pick a good and a quantity, buy or sell.
Walking out of the town closes it. The
server judges every trade (where you stand, your silver, your cargo, the stock). `/town` takes you to the nearest
town with a market, set down from above on the dry land nearest its place within its market's
radius (a town's place is its climate cell's centre, which may be sea), so you arrive in its
market (the teleport permission, `teleport.tp`). Only Earth has towns: a world not built
on the planet (a scratch world, `--game sandbox` or `singleplayer`, or a universe made
elsewhere than Earth) has none, and `/town` says so; on Earth they are worked out on a thread
in the seconds after arriving, and `/town` before then says to try again.

A world's interventions log (`sandbox.interventions.vxi`: what players did that its history
carries forward; a settlement founded is a town of the history from then on) is listed by
`/interventions [radius]` (the `world.interventions` permission).

What it tells its players: `sandbox.market` (the market of the town a player stands in, or
none), the events `sandbox.trade_refused` (why) and `sandbox.market_open`; what they ask:
`sandbox.trade`.

## Its materials

The sandbox has a block of every material of the kit (`sandbox:basalt_bricks`, ...: its pack's
`data/blocks/kit.json`, one line each; [docs/packs.md](../../docs/packs.md#materials)), so a
builder has them all. `/showroom <stone|wood|metal|built|domestic|natural|fantasy> [x y z]`
(the bulk edit permission, `world.edit.bulk`; `showroom.odin`) sets every material of a
family up to look at, at the player's feet or at x y z: each a wall three blocks square, eight
to a row, the rows one above another, on a floor of concrete slabs with a walkway in front.
The kit's pictures in the world are taken from it:

```sh
./build.sh shot materials --game sandbox -- "wait_world; /time set noon; key f1 down; wait 2; key f1 up; /showroom metal 56 10 40; ticks 20; camera at 72 17 64 0 -10; wait_world; screenshot materials_metal; quit"
```

## Its files

What the sandbox keeps of a world beside the engine's files ([docs/saves.md](../../docs/saves.md)),
staged in the same save transaction when it changed, and checked by `voxiverse-server --check`:

- `sandbox.economy.vxe`: what the server computed of a planet world's markets that the
  history does not give back: `"VXEC"`, `u32 version` (1), `u64` key of the placement it was
  made for, `f64` market month, `u32` market count, `u32` memory count, then per detailed town
  its climate cell (`u32`) and each good's stock and inbound goods (`f32`, in the order of
  `sandbox.Good`), per lazy memory its cell, each good's relative gap to the lazy price (`f32`)
  and the month it was left (`f64`), and last the CRC-32 of everything before it (all
  little-endian). Normal prices, the kernel and the settlements are not stored: they come from
  the history. A file made for another placement (the history changed) is read and ignored, so
  the markets are recomputed; one that is cut, has a bad CRC or a number that is negative or
  not finite is moved aside (`.bad`) and the markets are recomputed. News and caravans in
  flight are not saved.
- `sandbox.interventions.vxi`: the interventions log, in time order: `"VXIV"`, `u32 version`
  (1), `u32 count`, then per intervention its day (`f64`), place (3 x `i32`), kind (`u8`,
  append-only: `Founded_Settlement`, `Built`, `Destroyed`, `Taught`, `Traded`), the actor's
  name (`u8` length, bytes) and 16 data bytes, and last the CRC-32 of everything before it (all
  little-endian). A file that is cut, has a bad CRC, an unknown kind or records out of order is
  refused whole: the world moves it aside and starts with an empty log.

- `sandbox.remains.txt`: the home world's remains built, as text: `before` alone (a world
  saved before there were remains: none is built in it), or a line `built <x> <z>` for each
  site built, naming its middle column. A line it does not know moves the file aside, and
  nothing more is built.

A character's trader is the sandbox's record on it, in its file's `game` member: `cash`,
`cargo.<i>` (by the order of `sandbox.Good`), `seen.<i>.cell`, `.price`, `.month` (the month the
price was true) and `.good`, `count` (at most 192 prices, the oldest forgotten first) and
`given` (the starting purse was given), and `ruin_mode.<i>` (the bytes of the mode the
character was in before it fought at the ruin, zero-padded: given back with its things; none
when it fights nothing). Universes from before (save format 8) had these as the
engine's files and the character's `trader`: the save migration made them the sandbox's.

## The code

`rules.odin` (its name and description), `genetics.odin` (the sheep's genes), `pack.odin`
(its pack: `pack/data/entities/sheep.json`, the sheep's body, looks, model and spawn rule;
`pack/data/entities/hostile.json`, the nights' spawn rules; `pack/data/blocks/kit.json`, a
block of every material),
the markets' model (above), `records.odin` (what it replicates) and `text.odin`
(what its HUD and screen say); `server/` chooses the world (`configure`: the Earth generator
and the starter kit), keeps the sheep (`sheep.odin`: their minds, `think`; their shearing and
feeding, `entity_use`; their wild genes, `spawned`; their flight, `entity_hurt`), each sheep's
record (`Sheep`) kept on its entity, and runs the markets (`economy.odin`, each world's
economy, its `world_state` and file; `trader.odin`, the character's `Trader_Record` and the
market on the wire; `interventions.odin`), lets the night's creatures hunt
(`danger.odin`) and keeps the ruined site and its fight (`ruin.odin`: the site from the seed,
its template, the altar's use, the lock, the waves, the reward and the giving back), builds
the remains round the home gate (`remains.odin`, `remains_build.odin`) on what the ruin and they
share (`site.odin`: the land under a site, its levelling); `client/`
draws the market's line and screen (`market.odin`) and the fight's bar (`ruin.odin`). The pack's
`pack/data/blocks/ruin.json`, `items/ruin.json`, `models/ruin.json` and
`game_modes/encounter.json` are the ruin's altar and ward, its rounds and the fighters' mode.
Everything else the sandbox does (worlds and gates, climate, farming) is the engine's, chosen
through the server's `Config`.
