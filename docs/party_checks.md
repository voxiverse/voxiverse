# LAN party: the hand checks, in the order of a playtest

M48f-M48i's "Check by hand" lists in one run-through, then what to tune on the night.
Each step says what to do and what to expect. Two or more machines on one network; the
host runs the game, the others join by the address the dialog shows.

## Before anyone joins (host, alone)

1. New Universe, mode Survival, Ignite. Press `F3`: coordinates are hidden unless the rule
   `show_coordinates` is on. You hold the four weapons' slots (pistol, rifle, sniper, launcher
   as the start kit and the mode's kit give them) and a health bar.
2. `/gamemode creative`: you fly and the creative tab shows. `/gamemode survival`: you stop
   flying and the tab goes.
3. Jump from a tall tower: health drops. Stand still for five seconds: it climbs a point a
   second. `/damage <your name> 100`: the screen says "You died", the chat says "<name>
   died", Escape does nothing, Respawn (click or Enter) puts you at the spawn at full health
   with the four weapons.
4. Hold `P`: the player list shows you with Kills 0, Deaths 1.

## Open the party (host)

5. Game menu, Open to LAN: pick the guests' mode (Survival) and Allow commands off; Open.
   The dialog then shows the address and the port (read it off; it cannot be copied).
6. Each guest joins that address. Everyone lands at the spawn in survival with the weapons.
   A guest without "Allow commands" is told "You may not change your own game mode." for
   `/gamemode creative`.

## Shooting (two or more players)

7. Shoot a moving friend with each weapon: pistol (one press, one shot), rifle (hold to keep
   firing), sniper (hold the use button to zoom; turning is slower while zoomed). Expect a
   hit marker at the crosshair for you, a red arc toward the shooter for them, and the
   shot's sound for everyone near.
8. Empty a magazine, then `R` (or the pad's X): the weapon reloads after its time and the
   counter refills; switching weapon cancels the reload.
9. Kill a friend: the chat says "<friend> was shot by <you> (<weapon>)", their screen shows
   how they died, and the `P` list moves a Kill to you and a Death to them (sorted by kills,
   then deaths, then name).
10. A friend walks and runs and sneaks: you see their legs and arms swing with their speed,
    short strides when sneaking, the arm raised while they hold something. `F5` pulls in
    at walls.
11. With `/rule pvp false` (operator) shots no longer hurt players; falls and explosions
    still do. `/rule pvp true` turns it back on.
12. The operator's `Close LAN` in the game menu: guests are sent away, the port shuts.

## What to tune at the party

- **Weapons** (`assets/packs/voxiverse/data/items/weapons.json`): per weapon `damage`,
  `fire_rate` (shots a second), `magazine`, `reload_time`, `automatic`, `range`, `spread`,
  `headshot` (multiplier), `zoom`. Hot reload applies a saved change at once.
- **Rules** (`/rule` lists them; `/rule <name> <value>` sets one, saved with the world):
  `pvp`, `keep_inventory` (off: a dead player drops their things where they fell),
  `natural_regeneration`, `regen_delay` (seconds), `regen_rate` (points a second),
  `default_game_mode` (what a newcomer starts as), `guest_role` (`mod` or `default`).
- **Commands** (operator): `/gamemode [mode] [player]`, `/rule [name] [value]`,
  `/damage <player> <amount>`, `/give <player> <item> [count]`, `/open_lan`, `/close_lan`.
- **The survival kit** is `assets/packs/voxiverse/data/game_modes/survival.json` (`kit`).
