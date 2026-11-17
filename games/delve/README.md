# Delve

A co-op dungeon crawl seen from above, for one player or several. Each dungeon is laid out
from a seed: a grid of rooms joined by corridors, a start room in a corner and the warden's
room the most corridors away. Creatures wait in the rooms; the warden's death opens the way
down, and stepping on it takes every delver to the next dungeon, deeper, bigger and harder.

The dungeon is dark and close: dark bricks with moss on some walls, a glowing rune stone in
the middle of each room's side walls, a brazier of magma in each corner of its floor, bones
about, and a cold dark beyond a few rooms (its look, `LOOK` in `client/game.odin`).

The camera hangs over your head and looks down; nothing of the world above the walls' height
is drawn, so a roof would never hide you. The mouse is free: you face the pointer, the left button strikes
or shoots where it points, and W A S D move you up, left, down and right on the screen.

| Key | What it does |
|---|---|
| Left button | Swing the sword or axe in hand (everything in its arc), or shoot the bow at the pointer |
| 1 to 5, the wheel | Pick a weapon from the hotbar (loot goes there) |
| <kbd>Z</kbd> | Whirl: strike every creature within 3.5 blocks (every 8 s) |
| <kbd>X</kbd> | Drink a potion: 8 health |
| <kbd>P</kbd>, held | The delvers: level, kills, deaths, deepest dungeon |

Both actions are the game's own (rebindable in Options, Controls, where they show by these
names while Delve is played).

## The creatures

They stand until a delver comes within their notice and in their sight, or hurts them; then
they hunt it, and give up if it gets 30 blocks away. Deeper dungeons make them tougher (35%
more health and damage a depth). An elite has a name over it, 2.5 times the health, 1.5 times
the damage, and better loot.

| Creature | Health | Speed | Blow | How it fights |
|---|---|---|---|---|
| Biter | 4 | 4.6 | 1 | In packs of three, fast |
| Husk | 12 | 2.9 | 3 | Walks up and strikes |
| Spitter | 9 | 2.6 | 2 (spit) | Keeps 5 to 8 blocks away and spits from there |
| Brute | 36 | 1.8 | 7 | Slow, hard to kill, hits hard |
| The Warden | 140 | 2.2 | 6, or spit | Strikes near, spits from further, calls two biters every 12 s |

## You

A sword (4 a swing, 110 degrees, 0.45 s), a bow (3 a shot, 30 shots then 1.5 s to restring)
and three potions to start; health comes back slowly, out of a fight (the world's natural
regeneration). A kill gives experience to its
killer and to every delver within 24 blocks; a level adds 2 health and 10% damage. One blow
in ten is a critical hit, doubled. Dying, you wake in the start room: your level stays, the
experience towards the next is lost, and half your coins.

Creatures drop coins, sometimes a potion and sometimes a weapon; a chest, broken open with a
blow, more. A weapon is rolled: plain, fine (+15%), rare (+35%) or fabled (+60%), plus a few
percent and more deeper, shown over it as it lies ("rare axe +41%") and under the HUD's line
when held. The axe is slower and heavier (7 a swing, 150 degrees, 0.9 s). Walk over loot to
pick it up.

## Playing it

```sh
./build.sh run -- --game delve
./build.sh run -- --game delve --exec "wait_world; /open_lan"
./build.sh serve -- --game delve --universe build/delve-universe
```

The HUD's line: the depth, the creatures left (or that the way down is open), your level,
potions, coins and the whirl's wait; the experience bar under it. Over each creature its
health, over an elite or the warden its name, and each hit's damage floats up (yellow and
bigger for a critical hit, red when it is yours). F3 shows the dungeon's seed, the counts and
where the pointer is.

Server commands: `/delve` (the dungeon), and with the permission `delve.admin` (the host has
it) `/delve down` (the next dungeon now), `/delve depth <1..99>`, `/delve goto <start|boss>`,
`/delve spawn <biter|husk|spitter|brute|warden> [elite]` (awake, beside you) and `/delve loot`
(a roll of loot at your feet). Each delver's level,
experience and deepest dungeon are kept with the universe by name (`game.cfg`); its weapons
and coins are its character's.

## The code

`rules.odin` (the creatures, the loot rolls, the levels), `dungeon.odin` (the layout from a
seed), `records.odin` (the dungeon, the delvers, the creatures' tags, the events), `pack.odin`;
`server/` builds the dungeons (`dungeon.odin`), runs the creatures (`foes.odin`) and the
delvers' blows, levels, actions and loot (`delvers.odin`), the hooks in `game.odin`;
`client/` draws it. What the engine gives it: a top-down camera with a pointer that aims and a
cut over the head (`engine.Game.camera`), the game's own actions (`engine.Game.actions`, the
`action` hook), creatures shaped of parts (`"model": {"parts": ...}`) that fight
(`"attack"`, `core.entity_keep`, `core.entity_strike`, `core.entity_shoot`,
`core.entity_sees`), melee weapons as item data (`"melee"`), the `harming` hook every harm
passes, loot with a game's data (`core.item_drop`, `game.Stack.data`, the `picking` hook), a
game's health bonus (`core.player_health_bonus`), records keyed by entity
(`core.entity_known`, `engine.entity_label`, `engine.entity_bar`).
