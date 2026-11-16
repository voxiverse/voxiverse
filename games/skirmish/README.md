# Skirmish

A small real-time strategy for one to four sides, seen from a free camera with no body on
the field. Each side starts at a corner of a seeded map with a headquarters and four
workers. Workers gather ore (from crystal outcrops) and wood (from groves) and put up
buildings; buildings train units within the side's supply; armies are picked with the
pointer and ordered about, and fight by themselves what they meet. A side whose
headquarters and every building that trains are destroyed has lost; the last side standing
wins, the results stand ten seconds, and a new match is laid out. Sides no player takes are
played by the computer.

`./build.sh run -- --game skirmish`

## The field

112 blocks a side, walled round. A plateau three blocks high stands over the middle, climbed
by a ramp of steps on each side (each turned the same way round, so every corner has one).
Two ridges of rock too high to climb run from it to the walls, north to south and east to
west, each with a gap four blocks wide in each half: the corners meet only through these
chokes and over the plateau. Each corner is a base with three outcrops and three groves
round it; two outcrops lie on the plateau and a grove by each choke; boulders break up the
low ground. Where the ridges' gaps and the boulders fall is drawn from the universe's seed
and the match's number.

## Units and buildings

| Unit | Cost | Supply | Trained at | What it does |
|---|---|---|---|---|
| Worker | 50 ore | 1 | Headquarters | Gathers (5 a trip), puts up buildings |
| Soldier | 60 ore | 1 | Barracks | Fights at close quarters |
| Archer | 45 ore, 30 wood | 1 | Barracks | Fights from 6 blocks |
| Ram | 90 ore, 80 wood | 3 | Workshop | Slow; its blows count six times on buildings |

| Building | Cost | What it does |
|---|---|---|
| Headquarters | (each side's first) | Trains workers, takes loads, 10 supply |
| Barracks | 150 wood | Trains soldiers and archers |
| Workshop | 120 ore, 120 wood | Trains rams |
| Tower | 60 ore, 60 wood | Shoots the nearest foe within 9 blocks |
| Depot | 80 wood | Takes loads, 8 supply (60 at most in all) |

A building is paid for when it is placed and stands at a tenth of its health, growing as
its workers put it up. Soldiers' and archers' blows count half on buildings. A unit
standing, or attack-moving, fights the nearest foe within its sight by itself; one moving
fights only once it is there.

## Playing

- Left button: pick a unit or a building of yours (Shift: add or take away); a double click
  picks every one of that kind on the screen; a drag picks every one in the box.
- Right button: on the ground, the picked units go there (each to its own place round the
  point); on a foe, they attack it; on an outcrop or a grove, the workers gather it; with a
  building picked, its rally point.
- The command panel, along the bottom, with its keys Z, X, V, B, N: for workers, the four
  buildings (the ghost follows the pointer, green where it is affordable; left button to
  place, right to cancel) and Stop; for an army, Attack (the next left click attack-moves, or
  attacks the foe clicked) and Stop; for a building, what it trains.
- Ctrl and a digit keeps what is picked as a group; the digit picks it again. A commander
  holds no hotbar, so the digits are the groups' alone; every key here is rebindable under
  Skirmish in Options > Controls, kept for this game.
- The minimap, bottom left: the field, your units and buildings, the foes you see; press it
  to move the camera there.
- The fog: ground none of your side sees is darkened, ground none has ever seen more so;
  the server tells you of no enemy your side does not see.
- Pan with the movement keys, the window's edges or the middle button; zoom with the wheel.

## The computer

A simple, honest script for each side no player takes: every two seconds it looks at its own
side alone and gives its orders through the same checks a player's requests go through. It
keeps its workers gathering the resource it has less of, trains workers up to eight, puts up
a depot, a barracks, a tower, a depot, a workshop, a barracks and a depot in that order by its
headquarters, trains soldiers and archers by turns (and rams), and when its army reaches the
wave's size it sends all of it to attack-move on the nearest corner a side started at, each
wave three larger than the last. A player who joins during a match takes a side the computer
plays.

## Commands and settings

`/skirmish` shows the match and the settings; `/skirmish set <name> <value>` sets one from
the next match (`skirmish.admin`): `sides` (2 to 4: the players present take them in turn,
the computer the rest), `wave` (the computer's first wave), `ore`, `wood`, `workers` (each
side's at the start). `/skirmish restart` lays out a new match; `/skirmish give <ore> <wood>`
fills your side's stock and `/skirmish clash <n>` sets n soldiers and archers of each of the
first two sides at each other by your camera (for trying, and for pictures). The settings and every player's wins are kept with
the universe (`game.cfg`: the settings' lines and `wins = <n> <name>`); a match is not.

## Records and requests

`skirmish.match` (the phase, the match, its clock, the winner), `skirmish.economy` (your
side's stock and supply, to you alone), `skirmish.side` (every side, keyed by its team, for
the scoreboard: P), `skirmish.building`, `skirmish.unit` and `skirmish.node` (keyed by the
entity, to the players who know it: what a building trains, a worker carries, a node holds),
the event `skirmish.shot` (an archer's or a tower's streak). Requests: `skirmish.order` (up
to 48 units and what they do), `skirmish.train`, `skirmish.rally`.
