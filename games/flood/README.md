# Flood

Water rises in a walled arena; climb to the glowing lamp platform at the top before it reaches
you. A head under water for 2 s (or a player outside the walls) is out and watches the rest of
the round, flying. The round is won when everyone still in stands on the platform. Each round
runs under a hidden rule, told only when it ends:

| Rule | What happens |
|---|---|
| `baseline` | The water rises a layer every 2.4 s |
| `tide` | It surges and falls back, rising overall |
| `rot` | What it wets crumbles a few seconds later |
| `heavy` | Explosions are 1.75 times as large and throw twice as hard (the world's `explosion_size` and `explosion_throw` rules) |

Every round gives the kit (rocket launcher, grappling hook, rifles, jump boots) and nothing
hurts but the water: a runner is in `flood:runner`, a mode with no health, and an out player in
`flood:out`, which flies and only watches (`spectate`). Both come from the game's own pack,
`pack/`, loaded only where Flood is played. The arena is new each round, from its seed.

## Playing it

Host a Flood world open to the LAN, straight from the command line:

```sh
./build.sh run -- --game flood --exec "singleplayer; wait_world; /open_lan"
```

or serve it: `./build.sh serve -- --game flood --universe build/flood-universe`. A friend joins
with `./build.sh run -- --exec "join <host>"` (no `--game`: the server names the game, and its
pack comes with the join). Someone who joins during a round watches until the next.

Server commands (the console, `~`):

- `/flood`: the round, its rule, seed and water level.
- `/flood restart`: a new round (a new seed, a rule of its own).
- `/flood rule baseline|tide|rot|heavy`: a new round under that rule; `random` lets it choose.
- `/flood goal`: stand on the goal (to try it).

All but `/flood` need the permission `flood.round` (the host has it). F3 shows the round with
its rule.

## The code

`rules.odin` (the rules and their numbers), `records.odin` (the round each player is told),
`pack.odin` (the pack); `server/` runs the rounds (`game.odin`) and builds and floods the arena
(`arena.odin`); `client/` draws the HUD and the F3 line. To check the pack alone, copy `pack/`
to a folder named `flood` and run `./build.sh packs <that folder>`.
