# Sandbox

The engine's open world as a game, and the game a session plays when nobody names another
(`game.DEFAULT_GAME`). A universe of planets, the home world Earth or one made from the seed,
with its climate, sheep, farming, peoples and their markets, and gates between worlds: build, explore, survive or
create. There is no round and no score. A new player is given the rocket launcher.

## Playing it

```sh
./build.sh run                                # the title: Sandbox is first in the list of games
./build.sh run -- --game sandbox              # straight into a scratch Sandbox world
./build.sh serve -- --universe build/universe # the dedicated server plays it by default
```

The title's Singleplayer opens the saved universes; a new one made there (its planet, seed and
mode) plays the sandbox.

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
market (the teleport permission, `teleport.tp`).

A world's interventions log (`sandbox.interventions.vxi`: what players did that its history
carries forward; a settlement founded is a town of the history from then on) is listed by
`/interventions [radius]` (the `world.interventions` permission).

What it tells its players: `sandbox.market` (the market of the town a player stands in, or
none), the events `sandbox.trade_refused` (why) and `sandbox.market_open`; what they ask:
`sandbox.trade`.

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

A character's trader is the sandbox's record on it, in its file's `game` member: `cash`,
`cargo.<i>` (by the order of `sandbox.Good`), `seen.<i>.cell`, `.price`, `.month` (the month the
price was true) and `.good`, `count` (at most 192 prices, the oldest forgotten first) and
`given` (the starting purse was given). Universes from before (save format 8) had these as the
engine's files and the character's `trader`: the save migration made them the sandbox's.

## The code

`rules.odin` (its name and description), `genetics.odin` (the sheep's genes), `pack.odin`
(its pack: `pack/data/entities/sheep.json`, the sheep's body, looks, model and spawn rule),
the markets' model (above), `records.odin` (what it replicates) and `text.odin`
(what its HUD and screen say); `server/` chooses the world (`configure`: the Earth generator
and the starter kit), keeps the sheep (`sheep.odin`: their minds, `think`; their shearing and
feeding, `entity_use`; their wild genes, `spawned`; their flight, `entity_hurt`), each sheep's
record (`Sheep`) kept on its entity, and runs the markets (`economy.odin`, each world's
economy, its `world_state` and file; `trader.odin`, the character's `Trader_Record` and the
market on the wire; `interventions.odin`); `client/` draws the market's line and screen
(`market.odin`). Everything else the sandbox does (worlds and gates, climate, farming) is the
engine's, chosen through the server's `Config`.
