# Horde

Co-op wave survival, first-person. The survivors stand in a walled yard built from a seed:
crates and pillars for cover, gravel paths from a lair in each corner to the shop's counter
in the middle. Waves of creatures come out of the lairs and go for the nearest survivor
standing. Kills pay coins; between waves the shop is open. A survivor who goes down watches
until the wave is held, then stands again. When every survivor is down at once the run is
over; the best wave held is kept with the universe, and a new run begins in a new yard.

| Phase | What happens |
|---|---|
| Countdown | The yard is built and counted down (5 s); the shop is open |
| Wave | The creatures come out of the lairs, one every 0.5 s, a lair after another. Once the last is dead, the wave is held |
| Break | The shop is open (15 s, the settings may give more); those down stand again with the starting kit |
| Over | Everyone was down at once: the waves held and the best, big; a new run in 8 s |

The creatures (the game's pack, `pack/data/entities`: walkers the game steers, each a shape
of boxes whose legs and arms swing):

| Creature | Health | Speed | Attack | Bounty | From wave |
|---|---|---|---|---|---|
| Shambler | 10 | 2.7 | a blow, 2 | 3 | 1 (3 + the wave's number) |
| Skitter | 3 | 5.0 | a bite, 1 | 1 | 2, in swarms |
| Spitter | 7 | 2.4 | spit, 2, from 5 to 8 blocks away | 4 | 3 |
| Hulk | 32 | 1.7 | a blow, 6 | 10 | 4 |
| Matriarch | 120 | 2.1 | spit from afar, a blow close | 50 | every fifth wave |

Each wave's creatures are an eighth tougher than the last's.

Every survivor starts a run with a pistol, 36 rounds and 10 coins. The guns (the base pack's
models and sounds, numbers of Horde's own) load rounds: a reload takes them from the
pockets, and with none the gun stays empty. The shop, at the counter, between waves (the
game's actions):

| Key | Buys | Price |
|---|---|---|
| Z | 30 rounds | 8 |
| X | a medkit: 10 health back | 12 |
| B | the next gun: an automatic rifle, then a shotgun | 40, then 60 |

## Playing it

```sh
./build.sh run -- --game horde
./build.sh run -- --game horde --exec "wait_world; /open_lan"
./build.sh serve -- --game horde --universe build/horde-universe
```

The HUD's line: the wave, the creatures in the yard and still to come, the survivors
standing, your coins and rounds, the best. A banner as a wave sets out (red for the
matriarch's) or is held; the shop's prices while it is open; over the counter its name,
over a hurt creature its health. Hold P for the survivors (kills, coins, times down). F3
shows the run's seed and counts.

Server commands: `/horde` (the run and its settings), and with the permission `horde.admin`
(the host has it): `/horde set <setting> <value>` (`coins` a survivor's at a run's start,
`break_for` the shop's seconds, the prices `rounds`, `medkit` and `gun`), `/horde wave` (the
next wave now), `/horde restart`, `/horde shop` (stand at the counter), `/horde purse <n>`
(coins for you). The best wave and the settings are kept with the universe (`game.cfg`).

## The code

`rules.odin` (the yard's numbers, the creatures, the waves' plans, the shop's wares, the
settings), `records.odin` (the run, the survivors, a wave's news), `pack.odin`; `server/`
builds the yard (`yard.odin`), runs the creatures (`foes.odin`), the waves, the downs and
the shop (`game.odin`); `client/` draws it. What the engine gives it: `server:play`'s phase,
walled arena, watchers and settings; creatures that fight (`core.entity_keep`,
`core.entity_strike`, `core.entity_shoot`); a weapon's ammo as item data (`"ammo"`); the
game's actions; the HUD's bar, banners and flash.
