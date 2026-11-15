# Sandbox

The engine's open world as a game. A universe of planets, the home world Earth or one made
from the seed, with its climate, animals, farming, towns and gates between worlds: build,
explore, survive or create. There is no round and no score.

## Playing it

```sh
./build.sh run -- --game sandbox --exec singleplayer   # a scratch Sandbox world
./build.sh serve -- --game sandbox --universe build/universe
```

## The code

`rules.odin` (its name and description); `server/` chooses the world (`configure`: the Earth
generator); `client/` adds nothing to the engine's HUD and is there so a client can play it.
Everything else the sandbox does (worlds and gates, climate, animals, farming, the market) is
the engine's, chosen through the server's `Config`.
