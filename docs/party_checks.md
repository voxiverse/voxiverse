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

## Hands and held items (M48k)

13. In first person, hold each of pistol, rifle, sniper and rocket launcher, then a dirt
    block, a stair, and a hoe: your right arm comes up from the lower right with the item
    in its hand (the weapons as small voxel models, a block as its real shape and
    textures, the hoe as a thick icon). Look at a wall up close: nothing clips into it.
    Change the FOV slider: the hand does not stretch.
14. Swing at the air with a hoe or a block, place a block, shoot (the weapon kicks back
    and settles), reload (it dips and returns after its reload time). Walk: the hand
    bobs and sways a little. Turn off Options > View bobbing, or turn on Reduce motion:
    the bob and the sway stop, the swing, place, kick and dip still play.
15. Hold the sniper and the use button: the model hides and a round scope view fades in;
    release: the rifle is back. `F1` hides the arm and the scope with the HUD.
16. `F5` (and a friend's avatar): the same models in the right hand, the arm held out level
    for a weapon and raised for anything else.

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
- **Weapon models** (`assets/packs/voxiverse/data/models/weapons.json`): a side view
  drawn in characters (`.` empty, `1`-`4` the palette), up to 16 voxels a side; `grip` is
  the voxel the hand holds. Hot reload applies a saved change at once. The screenshots
  `held_<item>_first` and `held_<item>_third` of CI's "Held items" step show them all.
- **The survival kit** is `assets/packs/voxiverse/data/game_modes/survival.json` (`kit`).
