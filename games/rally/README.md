# Rally

A race through a course of platforms in the sky, from the lit start pad through six gates
in order; the sixth is the finish. Gaps to jump (a running jump crosses four blocks), steps
up and down, sidesteps, red hazard strips across some platforms, and two gaps six or seven
blocks wide with a beam of logs over them for the grappling hook (a rocket's push or the
boots' double jump cross them too). Falling below the course or touching a hazard puts you
back at your last gate, standing still. The course is laid out from the universe's seed, so
every race on it is the same course and the times compare.

| Phase | What happens |
|---|---|
| Countdown | Everyone here on the start pad (3 s alone, 5 s while others are here to race; stepping off puts you back) |
| Racing | The clock runs from the off; each gate passed in order is a split, told against your best run's split there; the last is your finish. Until everyone racing has finished (or 240 s) |
| Results | The finishers in order, 6 s; then the next race |

A racer has no health to lose: the hook (in hand on the start), the rocket launcher and the
jump boots. One who joins during a race watches it from over the start and races the next.
Every racer's best time (with its splits) and the course record are kept with the universe.

## Playing it

```sh
./build.sh run -- --game rally
./build.sh run -- --game rally --exec "singleplayer; wait_world; /open_lan"
./build.sh serve -- --game rally --universe build/rally-universe
```

The HUD's line: the race, the gate to make for, the race's clock, your best and the course
record (and whose). Over each gate its name, the next one outlined in green; at each gate
your split against your best (green when ahead, yellow when behind); at the finish a
banner for a personal best or a course record. Hold P for the racers (gate, time, best,
times sent back). F3 shows the course's seed and counts.

Server commands: `/rally` (the race, the record, your best), `/rally reset` (back to your
last gate: anyone), and with the permission `rally.admin` (the host has it) `/rally restart`
(a new race now) and `/rally gate <0..6>` (stand at a gate, to try the course). The bests
and the record are kept with the universe (`game.cfg`).

## The code

`rules.odin` (the course's plan from a seed, which both parts lay out: the server builds it,
the client marks its gates; the clock), `records.odin` (the race, the racers, a split, a
finish), `pack.odin`; `server/` builds the course (`course.odin`) and times the races
(`game.odin`); `client/` draws it. What the engine gives it: `server:play`'s phase and
watchers, the edit journal's paste of a template, the base pack's hook, launcher and boots,
the game's records and events, world labels and outlines, the HUD's bar, banners and flashes.
