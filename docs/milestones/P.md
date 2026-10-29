# P1-P3: the LAN party toys, analytics recording and stability (issue #65, the owner's priority)

Stability first, then the toys, then analytics; everything is good before Friday 11:30, no
live tuning at the party. These rows are **first among the open rows**, ahead of M49; M49,
M49b, M50 and M50b are held until after the party (no core system rewrites before Friday).
After them, until the freeze, only flakes and fixes from the owner's playtest. The toys are
Odin with their numbers as data (like M48h's weapons) and move onto the script VM later.

## Decisions (made here; the issue left them open)

- **Pellet pattern.** `pellets` is a new optional weapon number (default 1, 1..16). The
  pattern is one shared procedure, `game.pellet_dirs(seed, yaw, pitch, weapon)`, a uniform
  disc of half-angle `spread` radians around the aim (the shotgun's 6 degrees are
  0.10472). The seed is `game.shot_seed(player id, Shoot.after, slot)`: both sides know all
  three, so the client draws the server's pellets as tracers without a number travelling.
  A client that picks `after` can only choose among seeds, never aim outside the cone. The
  rifle's spread (0.01) was a square of +-0.01 and is now a disc of 0.01.
- **Pellet damage is summed per target:** one `damage` call per body a shot hits (so one
  death message, one hit confirm, one `Damage_Hit`), headshots counted per pellet. A
  creature takes one hit from a shot, as with any weapon.
- **Boots are armour data:** `jump_boots`, equip `feet`, `air_jumps` 1 and `speed` 0.2. M28's
  clamp (`air_jumps` 0..3) is unchanged; `boots` stays as it was.
- **The grapple is in the shared movement code.** `Button.Grapple` is what the client sends
  while the use button is held and a grappling hook is in the hand; `Player_State` gains
  `hooked` (the block it is anchored to, `Block_Pos`), `anchor` (the point the line hit) and
  `hook_cooldown` (ticks). `Mods.grapple` is the `grapple` object of the held item
  (`range`, `speed`, `cooldown`, derived with the equipment's mods from the selected slot, so
  prediction and the server agree). On the tick the button is first down, with no cooldown, the
  line is a block raycast from the eye along the input's yaw and pitch, up to `range`; it
  attaches to a block and never to a body (a body is not in the ray), a miss does nothing and
  costs nothing. While the button stays down and the anchor block is still solid, the
  velocity eases to `speed` toward the anchor (a pull, not a teleport: gravity is off while
  hooked); within 1.5 blocks of the anchor the player hangs. Release (or the item leaving the
  hand, or the anchor block breaking) keeps the velocity and starts the cooldown (2 s).
- **The kit places its stacks:** `kit` entries take an optional `slot`: `hotbar`, `pockets`,
  or an equipment slot (`head`, `chest`, `legs`, `feet`, `offhand`); without it the stack goes
  to the first free slot as before. The survival kit: hotbar rifle, shotgun, sniper, rocket
  launcher, grappling hook (slots 1-5 by order); pockets pistol; feet jump boots; full
  magazines (`refill_weapons`).
- **Recording** (P2): a per-session file `<universe>/analytics/session-<unix time>.vxa` of
  the existing telemetry events and counters (M26, M27), one line of text per record, never
  uploaded; the server writes it when it runs (dedicated or Open to LAN). Details below.

## P1: shotgun, jump boots, grappling hook, the survival kit

Items as data: `assets/packs/voxiverse/data/items/weapons.json` (shotgun), `armor.json` (jump
boots), `tools.json` (grappling hook, a `grapple` object), voxel models in
`data/models/weapons.json`, the kit in `data/game_modes/survival.json`.

Tests: the shotgun's pellet pattern is identical on client and server for a seed (the shared
procedure, and the server's tracers equal the client's); eight pellets, 2 damage, headshots
2x per pellet, magazine 6, about 0.9 s between shots; the boots give exactly one extra jump
and +0.2 speed; the grapple's pull is predicted with no correction at 50 ms latency, refuses a
player and an entity in the line, respects range and cooldown, releases with momentum; the
kit's slots are as above on join and on respawn; a pack that gives a kit entry another slot
loads, a bad slot name is a load error.

## P2: analytics recording and `build analytics --session`

Written by the server into the session file, from its own knowledge plus what clients send:

- per player: ping over time (a sample every 10 s); kills and deaths by weapon and cause;
  shots fired and hits per weapon; damage dealt and taken per weapon; time-to-kill per kill
  (the first damage to that victim by that killer, to the death, in seconds); grapple uses;
  jumps and double jumps;
- per client, once on joining: OS, GPU name, driver version, resolution (a `Client_Info`
  message the client sends after Welcome), then frame-time statistics (median, p95, worst)
  every minute (a `Frame_Stats` message);
- the server: tick time statistics (median, p95, worst a minute), the desync counter,
  bandwidth per client, crashes and error lines (the log's warnings and errors).

`./build.sh analytics --session <file>` prints the summary: weapon balance (kills, accuracy,
time-to-kill per weapon), each player's frame times and hardware, network quality, errors.
Tested on a recorded bot session (`build bench party` writes one).

## P3: stability

Rerun M48j's 6 and 8 client tests with the new items in the kit (bots use the shotgun and the
grapple) and fix what they find. The client frame time with 8 avatars holding models needs a
window: listed under "Check by hand" unless a windowed CI run exists.

**Exit check:** the tests above, the whole suite, `build check`, `build determinism`, CI green.
