# Arena

A free-for-all deathmatch in a walled courtyard. Everyone fights with the same kit (rocket
launcher, rifle, shotgun, grappling hook); a kill is a frag, and a death by your own rocket
or a fall costs one. The first to the frag limit wins the match, or the most frags when the
clock runs out (fewer deaths break a tie). The results stand for 8 s, then the next match
begins in a new courtyard.

| Phase | What happens |
|---|---|
| Warm-up | Fight freely, nothing counted, until enough players are in: one in a world hosted alone, two once others can join (opened to the LAN, or a dedicated server) |
| Countdown | The courtyard is built from the match's seed (whatever rockets carved last match is whole again) while everyone floats above it, watching; 5 s |
| Match | Fight. The dead come back by themselves after the respawn delay (2 s), at the spawn point farthest from everyone else, with the kit and 1.5 s in which nothing hurts them. Death drops nothing |
| Results | The winner, big; everyone watches again |

The courtyard (40 x 40 inside, bedrock walls): a floor with an inlaid ring, a stepped keep in
the middle, four towers with stairs joined in pairs by bridges with a gap to jump or hook
across, posts to hook onto, low walls for cover, and eight spawn points along the walls. Its
materials, sizes and the places of the posts and walls come from the seed. A fighter who
leaves it (over the walls, or through the floor) is put back at a spawn point.

The kit and the two modes, `arena:fighter` (health, no regeneration) and `arena:watching`
(flying, unharmed, only watching), come from the game's own pack, `pack/`, loaded only where
Arena is played.

## Playing it

Alone, to try it (a match starts at once):

```sh
./build.sh run -- --game arena
```

Host it open to the LAN, straight from the command line, and a friend joins:

```sh
./build.sh run -- --game arena --exec "wait_world; /open_lan"
./build.sh run -- --exec "join <host>"
```

or serve it: `./build.sh serve -- --game arena --universe build/arena-universe`. The friend
needs no `--game`: the server names the game, and its pack comes with the join. Someone who
joins during a match fights in it from nought.

Hold <kbd>P</kbd> for the scoreboard (frags and deaths, the leader first). The HUD shows the
time left, your frags and the leader; kills scroll down the right. F3 shows the match, its
phase and the courtyard's seed.

Server commands (the console, `~`):

- `/arena`: the match, its phase, seed and rules.
- `/arena set frags <1..200>`: the frag limit (15).
- `/arena set time <30..3600>`: the time limit in seconds (300).
- `/arena set respawn <0..30>`: seconds from a death to coming back (2).
- `/arena start`: end the warm-up now; `/arena restart`: a new match now.

All but `/arena` need the permission `arena.admin` (the host has it). The rules are kept with
the universe (`game.cfg`), so a served arena keeps them across restarts.

## The code

`rules.odin` (the rules, their numbers and the farthest spawn point), `records.odin` (the
match, the scores and the kill feed), `pack.odin` (the pack); `server/` runs the matches
(`game.odin`) and builds the courtyard (`courtyard.odin`); `client/` draws the HUD, the feed,
the banners, the scoreboard and the F3 line. The engine does the fighting: its damage
pipeline tells the game who killed whom (the `died` hook), the world's respawn rules bring the
dead back, and the `respawned` hook puts them at a spawn point.
