# Sandbox

The engine's open world as a game, and the game a session plays when nobody names another
(`game.DEFAULT_GAME`). A universe of planets, the home world Earth or one made from the seed,
with its climate, sheep, farming, towns and gates between worlds: build, explore, survive or
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

The statistics it keeps of a player: `sheep.sheared` (5 experience each) and `sheep.fed` (2),
and of a world `sheep.born`, shown with the engine's.

## The code

`rules.odin` (its name and description), `genetics.odin` (the sheep's genes) and `pack.odin`
(its pack: `pack/data/entities/sheep.json`, the sheep's body, looks, model and spawn rule);
`server/` chooses the world (`configure`: the Earth generator and the starter kit) and keeps
the sheep (`sheep.odin`: their minds, `think`; their shearing and feeding, `entity_use`; their
wild genes, `spawned`; their flight, `entity_hurt`), each sheep's record (`Sheep`) kept on its
entity; `client/` adds nothing to the engine's HUD and is there so a client can play it.
Everything else the sandbox does (worlds and gates, climate, farming, the market) is the
engine's, chosen through the server's `Config`.
