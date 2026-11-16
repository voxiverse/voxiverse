# Towers

A co-op tower defence on a walled field. Creeps come out of a gate at the west end in
waves and walk the shortest way to the glowing core at the east end; each one that gets
there costs lives (a brute three), and at nought the run is lost. Hold all the waves (10)
and it is won. The results stand for 8 s, then a new run begins on a new field.

| Phase | What happens |
|---|---|
| Build | 20 s before the first wave (the rules may give more), 10 s between waves: build. The field (48 x 32, bedrock border, grass floor, rocks placed from the run's seed) is built new for each run |
| Wave | Creeps come out of the gate one every 0.8 s and walk to the core; build on. Once the last of them is dead or home, the wave is held: every builder gets a bonus (8 coins, 2 more each wave) |
| Results | Won or lost, big; then a new run, the lives and every builder's coins back |

The creeps (the game's pack, `pack/data/entities`: walkers it steers, none of which jumps,
each shaped of boxes whose legs and arms swing as it walks: a red runner all legs and a tail,
a squat green grunt, a purple brute with a crest):

| Creep | Health | Speed | Bounty | Lives at the core |
|---|---|---|---|---|
| Runner | 6 | 3.4 blocks/s | 2 | 1 |
| Grunt | 16 | 2.2 | 4 | 1 |
| Brute | 45 | 1.4 | 10 | 3 |

Each wave sends more runners, grunts from the second and brutes from the fourth, each a
seventh tougher than the last wave's.

What you build, on the floor between the gate's end and the core's (you fly, unharmed; the
hotbar holds one of each and the coins):

| Piece | Price | What it does |
|---|---|---|
| Wall | 2 | Nothing but stand in the way: a creep does not climb, so one block turns it |
| Arrow tower | 12 | Every 0.4 s, 2 damage to the creep in 7.5 blocks nearest the core |
| Cannon tower | 25 | Every 2 s, 6 damage to every creep within 2.5 blocks of where its shot lands (10 blocks' range) |

A piece that would leave the creeps no way to the core (from the gate, or from where one
walks) is refused, and costs nothing; so is one you cannot pay for, or anything else placed
or broken. Breaking a piece pays half its price back. A kill pays its bounty to whoever
made it: a tower's to its builder, a shot's to the shooter (the rifle in the hotbar does a
little). Coins are an item, in the inventory, the hotbar's last slot first.

## Playing it

Alone:

```sh
./build.sh run -- --game towers
```

Together, hosting open to the LAN, or served:

```sh
./build.sh run -- --game towers --exec "singleplayer; wait_world; /open_lan"
./build.sh run -- --exec "join <host>"
./build.sh serve -- --game towers --universe build/towers-universe
```

The HUD shows the wave, the creeps on the field and to come, the lives, your coins and the
time to the next wave; a banner as a wave sets out or is held; a health bar over each hurt
creep; the gate's and the core's names. With a piece in hand, an outline shows where it
would go: green where you may build it and can pay, red where not (whether it would shut
the way is the server's to say). Hold <kbd>P</kbd> for the builders (kills, coins, coins
spent). F3 shows the run, the wave and the field's seed.

Server commands (the console, `~`):

- `/towers`: the run, its phase, wave, lives and seed, and the rules.
- `/towers set coins <0..5000>`: each builder's coins at the start of a run (60).
- `/towers set lives <1..500>`: the lives (20; before the first wave, this run's too).
- `/towers set waves <1..50>`: the waves to hold (10).
- `/towers set build <5..600>`: seconds to build before the first wave (20).
- `/towers wave`: send the next wave now; `/towers restart`: a new run now.

All but `/towers` need the permission `towers.admin` (the host has it). The rules are kept
with the universe (`game.cfg`).

## The code

`rules.odin` (the field, the pieces, the creeps, the waves), `records.odin` (the run, the
builders, a wave and a shot), `pack.odin` (the pack); `server/` runs the runs (`game.odin`),
builds the field (`field.odin`) and judges, charges and fires the pieces (`defence.odin`);
`client/` draws it. What the engine gives it: walkers steered along a shared route
(`core.route_make`, `core.entity_follow`) and the question whether a block would shut it
(`core.route_would_shut`), the harm and death of entities (`core.entity_harm` and the
`entity_died` hook), the block hooks (`editing`, `block_changed`), the inventory as a purse
(`core.item_give`, `core.item_take`) and, on the client, marks in the world
(`engine.entity_bars`, `engine.world_label`, `engine.world_box`).
