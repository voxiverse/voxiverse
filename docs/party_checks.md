# LAN playtest checks

This document is the manual check procedure for a LAN playtest of the multiplayer and
survival features. It combines the "Check by hand" lists of M48f-M48i, the additions of
issues #65 and #67, and the M48k held-item checks into a single run-through, in the order of
a playtest. It ends with the evidence to collect and the values that can be tuned during the
session.

Each step states what to do and what to expect.

## Setup

- Two or more machines on one network.
- The host runs the game; the other players join by the address the Open to LAN dialog shows.

## Host checks

Perform these steps on the host, before anyone joins.

1. Choose New Universe, mode Survival, then Ignite. Press `F3`: coordinates are hidden unless
   the rule `show_coordinates` is on. The hotbar holds the rifle, shotgun, sniper, rocket
   launcher and grappling hook (slots 1-5), the pistol is in the pockets (`E`), the jump
   boots are on your feet, and a health bar is shown.
2. Enter `/gamemode creative`: you fly and the creative tab is shown. Enter
   `/gamemode survival`: you stop flying and the tab is removed.
3. Jump from a tall tower: health drops. Stand still for five seconds: health climbs by one
   point per second. Enter `/damage <your name> 100`: the screen shows "You died", the chat
   shows "<name> died", and Escape does nothing. Respawn (click or Enter) places you at the
   spawn at full health with the same kit.
4. Hold `P`: the player list shows you with Kills 0, Deaths 1.

## Opening the world

5. Open the game menu and choose Open to LAN. Set the guests' mode to Survival and Allow
   commands to off, then choose Open. The dialog shows the address and the port. Read them
   off the screen; they cannot be copied.
6. Each guest joins that address. Every player arrives at the spawn in survival with the
   weapons. A guest without "Allow commands" who enters `/gamemode creative` is told "You may
   not change your own game mode."

## Shooting

These steps require two or more players.

7. Shoot a moving player with each weapon:
   - pistol: one press fires one shot;
   - rifle: hold to keep firing;
   - sniper: hold the use button to zoom; turning is slower while zoomed.

   Expected: the shooter sees a hit marker at the crosshair, the target sees a red arc
   pointing toward the shooter, and every player nearby hears the shot.
8. Empty a magazine, then press `R` (or the gamepad's X): the weapon reloads after its reload
   time and the counter refills. Switching weapon cancels the reload.
9. Kill another player: the chat shows "<friend> was shot by <you> (<weapon>)", the victim's
   screen shows how they died, and the `P` list moves a Kill to you and a Death to them. The
   list is sorted by kills, then deaths, then name.
10. Another player walks, runs and sneaks: their legs and arms swing in proportion to their
    speed, strides are short when sneaking, and the arm is raised while they hold something.
    In the third-person view (`F5`) the camera pulls in at walls.
11. As an operator, enter `/rule pvp false`: shots no longer hurt players, while falls and
    explosions still do. `/rule pvp true` restores it.

## Hands and held items (M48k)

12. In first person, hold each of the pistol, rifle, sniper and rocket launcher, then a dirt
    block, a stair, and a hoe. Your right arm comes up from the lower right with the item in
    its hand: the weapons as small voxel models, a block as its real shape and textures, the
    hoe as a thick icon. Look at a wall up close: nothing clips into it. Change the FOV
    slider: the hand does not stretch.
13. Swing at the air with a hoe or a block, place a block, shoot (the weapon kicks back and
    settles), and reload (the weapon dips and returns after its reload time). Walk: the hand
    bobs and sways slightly. Turn off Options > View bobbing, or turn on Reduce motion: the
    bob and the sway stop, while the swing, place, kick and dip animations still play.
14. Hold the sniper and the use button: the model is hidden and a round scope view fades in.
    Release: the rifle returns. `F1` hides the arm and the scope together with the HUD.
15. In the third-person view (`F5`), and on another player's avatar, the same models appear in
    the right hand, with the arm held out level for a weapon and raised for anything else.

## Shotgun, jump boots and grappling hook (issue #65)

16. **Shotgun** (slot 2). One press fires eight pellets in a spread. At ten blocks a target
    takes a few of them (2 health each, doubled for the head); at three blocks, most of them.
    There is a pump delay of about 0.9 s between shots. The magazine holds six shells, and
    `R` reloads. Its sound is currently the sniper's. A kill reads
    "<friend> was shot by <you> (shotgun)".
17. **Jump boots** (worn from the start). Jump, then jump again in the air: one extra jump is
    allowed, and no more until you land. You also walk a fifth faster. Take the boots off in
    the inventory: the double jump is no longer available.
18. **Grappling hook** (slot 5). Look at a wall or the ground within 30 blocks and hold the use
    button: a rope runs from your hand to the block and you fly toward it at about 20 blocks
    per second. Release the button and you keep your speed through the air; it carries you
    until you land or the 2 second cooldown ends. Holding it toward the sky does nothing.
    Aimed at another player, the line passes through them to the block behind. The pull does
    not snap back for a guest on a slow link (the tests check it at 50 ms). Other players do
    not see your rope.

## Closing the world

19. The operator chooses Close LAN in the game menu: guests are disconnected and the port is
    closed.

## Analytics (issue #65)

20. Every server writes `<universe>/analytics/session-<time>.jsonl` while it runs; for Open to
    LAN, this is in the host's universe folder. Afterwards, run:

    ```sh
    ./build.sh analytics --session <that file>
    ```

    The report shows the weapon balance, each player's hardware and frame times, the network
    quality (ping, bandwidth) and the warnings. Nothing is uploaded. A session marked "no
    clean stop" in the report means the game or the server crashed.
21. Frame time with eight avatars holding models requires a window, so CI cannot measure it.
    The clients' own `client_frames` lines in the session file report it (median, p95 and
    worst per minute). A median above about 16 ms per frame is worth noting.

## Collecting evidence (issue #67)

Nothing is uploaded. Evidence not collected from each machine before the session ends is
lost.

### During play

When anything unexpected happens (a stutter, a graphical glitch, a wrong death, rubber
banding), type it in the chat as `bug: <what happened>`. Every client's log records each chat
line with its time, and the host's session file records every player's position every 10 s.
The time therefore identifies the place, and what the frame and tick numbers were doing at
that moment. `F2` takes a screenshot (saved to a `screenshots/` folder beside the game).

### After play, from every machine

- The game folder's `voxiverse.log`, and `voxiverse.log.1` ... `.5` (the five runs before it,
  so a crash's log survives the restart).
- The `screenshots/` folder.

A log's first line gives the game's version and its start time in UTC.

### From the host

- The same files as every other machine.
- `<universe>/analytics/session-*.jsonl` (one file for each time the world was opened).

`./build.sh analytics --session <file>` ends with a timeline, in UTC: joins and leaves, every
minute in which a player's frame or the server's tick took over 50 ms, resends, warnings and
errors.

### Version check

Every player must run the same version. Compare the first line of each log
(`Voxiverse 0.1.2+N (commit)`).

## Tuning

The following values can be adjusted during the session.

### Shotgun, hook and boots

| File | Entry | Values |
|---|---|---|
| `weapons.json` | Shotgun | `pellets` 8, `damage` 2 per pellet, `spread` 0.10472 radians (6 degrees), `fire_rate` 1.1111 (0.9 s) |
| `tools.json` | `grapple` | `range` 30 blocks, `speed` 20 blocks per second, `cooldown` 2 seconds |
| `armor.json` | `jump_boots` | `air_jumps` 1, `speed` 0.2 |

### Weapons

`assets/packs/voxiverse/data/items/weapons.json` defines, per weapon: `damage`, `fire_rate`
(shots per second), `magazine`, `reload_time`, `automatic`, `range`, `spread`, `headshot`
(multiplier) and `zoom`. Hot reload applies a saved change immediately.

### Rules

`/rule` lists the rules, and `/rule <name> <value>` sets one; rules are saved with the world.

| Rule | Meaning |
|---|---|
| `pvp` | Whether players can hurt each other. |
| `keep_inventory` | When off, a dead player drops their items where they fell. |
| `natural_regeneration` | Whether health regenerates. |
| `regen_delay` | Seconds before regeneration starts. |
| `regen_rate` | Points regenerated per second. |
| `default_game_mode` | The mode a new player starts in. |
| `guest_role` | `mod` or `default`. |

### Operator commands

`/gamemode [mode] [player]`, `/rule [name] [value]`, `/damage <player> <amount>`,
`/give <player> <item> [count]`, `/open_lan`, `/close_lan`.

### Weapon models

`assets/packs/voxiverse/data/models/weapons.json` defines each model as a side view drawn in
characters (`.` is empty, `1`-`4` index the palette), up to 16 voxels per side. `grip` is the
voxel the hand holds. Hot reload applies a saved change immediately. The screenshots
`held_<item>_first` and `held_<item>_third` from CI's "Held items" step show every model.

### Survival kit

The survival kit is the `kit` entry in
`assets/packs/voxiverse/data/game_modes/survival.json`.
