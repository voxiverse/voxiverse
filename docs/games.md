# Games

The engine (`client/`, `common/`, `server/`) runs worlds; a **game** is the rules played in
one: a round, a goal, a score. Each game is native Odin in its own folder, `games/<game>/`,
compiled against the engine. The engine never imports a game, and adding a game edits no file
outside its folder ([layout.md](layout.md), rule 6, and the `import` lint).

A game's folder holds its packages as the engine's sides are split: `games/<game>` is its
shared package (`package <game>`: the rules, constants and record types both sides use; only
`common:` and `core:`), `games/<game>/server` its server part (`package <game>_server`) and
`games/<game>/client` its client part (`package <game>_client`).

What names a game is declared once, in its shared package, and both parts take it: a
`game.Game_Info` holding its id (the folder's name), the name players read and a line saying
what it is (plain English for now: the launcher lists the games by them, and a game has no
translation table yet). The description is one line in the launcher's small text, at most the
title's column wide (`screen.TITLE_WIDTH`; a `client/main` test measures every game's). `core.Game` and `engine.Game` hold it by `using`, so `g.id` reads as
before:

```odin
// games/flood/rules.odin (package flood)
INFO :: game.Game_Info {
	id          = "flood",
	name        = "Flood",
	description = "Climb to the glowing platform before the rising water gets you.",
}
```

## The server's side: `core.Game`

A game's server part (`games/<game>/server`) exports one constant `core.Game` value: its
`info` (its shared package's `INFO`), the types of its state, its pack (below), and the hooks
the server calls (`Game` in `server/core/server.odin`). Whoever starts the server puts it in
`Config.game`. Every session plays exactly one game: `start` refuses a config whose game has no
valid id. When nobody names one, the executables play `game.DEFAULT_GAME`, `sandbox`
(`games/sandbox`: the engine's open world, its configure choosing the Earth generator); the
engine's own tests play `core.HARNESS_GAME`, which the harness gives a config that names none
(a game with no hooks, so the tests run the engine as it is; a session that joins one has its
client part, `engine.HARNESS_GAMES`). Every hook may be nil.

| Hook | When | Thread |
|---|---|---|
| `configure(^Config)` | First thing in `start`, before the config is checked: change the world's generator, mode, spawn... | the caller's |
| `start(s) -> bool` | The session is set up (worlds, seats, the game's state), before the first tick; false: `start` fails and frees the session | the caller's |
| `tick(s)` | Every tick, after the entities' (also while the world is frozen) | the server's |
| `joined(s, c)` | A player is playing: welcomed, in its world | the server's |
| `left(s, c)` | A playing player leaves (still seated, its state still there); not called for those still playing when the server stops | the server's |
| `command(s, c, name, args) -> bool` | A `/command` the server has none of (relative coordinates already expanded); the game checks its own arguments and permissions (`core.allowed`); false: unknown | the server's |
| `hurt(s, c, harm)` | A player was hurt and lives (its health already less): `harm` is a `core.Harm`, the amount, the kind of source (`game.Source_Kind`: a fall, an explosion, a weapon...), `by` the player who did it (the one hurt, for its own rocket; nil for nobody), `creature` the entity that did it (its id; 0 for none) and the weapon's name for a shot | the server's |
| `died(s, c, harm)` | A player died of `harm`, after the engine's death: the line told, `kills` and `deaths` counted, its things dropped (by its mode and the world's rules) | the server's |
| `respawned(s, c)` | A dead player stands again, after the engine stood it at the world's spawn with full health and its mode's kit: the game may move it (`teleport`) and change what it holds. Also for a dead player who leaves, after `left` | the server's |
| `editing(s, c, at, old, new) -> string` | A player would change the block at `at` from `old` to `new` (`.Air` for a break) and the engine's rules allow it (reach, what it holds, protection still to come): `""` lets it, anything else refuses it, the block stays and the player is told that text | the server's |
| `block_changed(s, w, change)` | Blocks of world `w` changed since the game's last tick, each told once, in order, before its next one: `change` is a `core.Block_Change`, one block (what it was and is) or a bulk edit's box (`bulk`), and `by` the player whose edit it was (nil: the world, a command, the game; one who has left by then is nil). At most `MAX_NOTED_CHANGES` a tick (more are dropped, and logged) | the server's |
| `entity_hurt(s, w, h, harm)` | An entity of world `w` was hurt and lives (its health already less): `harm` is a `core.Entity_Harm`, the amount, the kind of source (a blast, a player's shot or blow, `.Game` for the game's own `entity_harm`), `by` the player who did it (nil: nobody, or the game), `creature` the entity that did it (its id; 0: none) and the weapon's name for a shot | the server's |
| `picking(s, c, stack) -> Pickup` | A player walks over a dropped stack it may pick up: `.Take` (into its inventory, as far as there is room), `.Leave` (it stays: not this player's, not now) or `.Taken` (the game took it its own way, a purse, a potion drunk: it is gone) | the server's |
| `action(s, c, index)` | A player pressed one of the game's own actions (`index` into the client part's `actions`, below; a `Game_Action` message, after its last input): an ability, a potion. Not while dead | the server's |
| `request(s, c, r)` | A player's client part sent one of the game's requests ([below](#requests)), decoded and checked: `core.request_value(s, r, T)` reads it as its type. Whether the player may (`allowed`), can afford it and where it goes is the hook's to judge | the server's |
| `harming(s, h)` | Any harm is about to be done, to a player or an entity, whoever does it (a player's blow or shot, a creature's, a blast, a fall, the game's own `entity_harm`): `h` is a `core.Harming`, the amount, its kind, who does it (`by` a player, `creature` an entity), what the player holds (`stack`, its data too) and who takes it (`to` a player, `entity` an entity); the hook may change `h.amount` (stats, armour, a critical blow), 0 or less and nothing is done. An entity's health is whole: the amount is rounded after the hook | the server's |
| `entity_died(s, w, dead, harm)` | An entity of `w` died of `harm`: everyone who knew it was shown it die, and it is gone (`dead`, a `core.Dead_Entity`, says its id, kind and where it was) | the server's |
| `stop(s)` | After the last tick, before the last save; only after a `start` that succeeded | the caller's |
| `save(s, out)` | A save captures this tick (an autosave, `/save`, the last one): the game writes what it keeps to the `strings.Builder` as text, saved with the universe as `game.cfg` in the same transaction ([saves.md](saves.md)) | the server's (the last save: the caller's) |
| `load(s, text) -> bool` | Right after `start`, in a universe that has a `game.cfg`: its text; false: the game does not understand it, and the universe is refused (`stop` is called, `start` fails) | the caller's |

A game reaches the server through the procedures and types listed below and the fields of
`Server`, `Client` and `World`. Much of `server/core` is visible to Odin code outside it; a game
names only what the list holds, which the `import` lint checks.

A game's tick runs inside the server's, so the stepped server (and its tests) run it too, and
it follows [determinism.md](determinism.md): no clock, no unseeded randomness.

## What a game may call

A game's code (not its tests, which drive the harness: `session_start`, `harness_*`,
`mirror_*`...) names of `server:core` only these; the `import` lint reads this table and
refuses any other `core.<name>` in a game. A name joins the list with the engine commit that
makes it for games, documented where it is declared.

| Name | What it is for |
|---|---|
| `Game`, `Config`, `Server`, `Client`, `World`, `Mode_Result`, `Harm`, `Entity_Harm`, `Harming`, `Dead_Entity`, `Block_Change` | The game itself, the config `configure` changes, the session, a player, a world, what hurt a player or an entity, an entity that died, blocks that changed (its hooks') |
| `game_state(s, T)`, `game_client_state(s, c, T)` | The game's state, for the session and for a seat |
| `game_put(s, c, &value)`, `game_event(s, c, &value)` | Its records and events ([below](#records-and-events)) |
| `notice(s, c, text)`, `announce(s, text)` | Tell one player; tell every player in the chat |
| `client_name(c)`, `allowed(s, c, node)` | A player's name; whether it holds a permission |
| `player_id(s, c)` | A player's id (its seat): the key of a record of the game's about it (`game.key_player`), the same on every side |
| `player_ref(s, c)`, `player_of(s, ref)`, `Player_Ref` | A player held past the moment (who built a tower, whose kill a shot is): its seat and the seat's generation; `player_of` gives the player still playing in it, or nil once it left, whoever sits there now |
| `teleport(s, c, position, look, flying)` | Move a player in its world (standing where it fits once the blocks are there, or flying) |
| `game_mode(s, c, id)` | Put a player in a mode by id (a pack's too: `flood:out`); journalled as the game's |
| `kit_give(s, c)` | Give a player what its mode's kit has that it lacks, weapons full |
| `item_drop(s, w, position, stack)`, `Pickup` | Drop a stack into the world (loot, a chest's spill) with its game data: `game.Stack.data`, a `u32` of the game's own (a rolled damage, a rarity), kept with the stack in the inventory, sent to its player and saved with it, and only stacks with the same data stack together; the first player to walk over it picks it up, as the `picking` hook decides |
| `item_count(c, item)`, `item_give(s, c, item, count)`, `item_take(s, c, item, count)`, `item_clear(s, c, item)` | A player's slots as a game's store: how many of an item it carries, give some (what fits: the number given), take some (the number taken), take all; booked in the item ledger as the game's |
| `hotbar_select(s, c, slot)` | Put a hotbar slot (0 ..< `game.HOTBAR_SLOTS`) in a player's hand, as if it chose it; false for a slot out of range |
| `head_in_water(s, c)` | A player's eyes are in water |
| `player_health_bonus(s, c, bonus)`, `heal_player(c, amount)` | Add to a player's most health (a level's; it stays with the seat until changed, and a respawn fills it); heal a living player up to its most (a potion) |
| `game_rule(s, w, name, value)` | Change a world's rule (`explosion_size`, as the `rule` command names it; the value as text), journalled as the game's and told to the world's players |
| `world_keep(w, area)`, `world_ready(w, area)`, `world_release(w)` | Keep an area loaded with nobody near; whether all of it is there; let it go |
| `block_at(w, p)` | Read a block (false: not loaded) |
| `game_act(s, w, system)`, `Act` | A cause for the game's block changes, its actor the game: one per cause |
| `set_block(w, p, block, act)`, `bulk_edit(w, edit, act)`, `Bulk_Edit`, `Box`, `Sphere` | Change blocks through the edit journal ([journal.md](journal.md)) |
| `entity_spawn(w, kind, position, natural)`, `entity_gone(w, h)` | An entity of a kind (the game's pack's, `<game>:<name>`) at a place, its handle (0: the world is full); gone again, with no death to show |
| `entity_find(w, id)`, `entity_listed(w, h)`, `entities_of(w, kind, center, radius)`, `entities_each(w)`, `entities_next(&it)`, `Entity_Iter` | An entity by its id; whether a handle is one still there; the entities of a kind near a point, nearest first; every entity, lowest id first |
| `entity_known(c, id)` | Whether a player has been told of an entity (it is near it): put a record of the game's keyed by the entity (`game.key_entity(id)`: its name, its rank) to the players who know it, and it goes with it |
| `entity_id(w, h)`, `entity_kind(w, h)`, `entity_pos(w, h)`, `entity_health_of(w, h)`, `entity_max_health(w, h)`, `entity_set_max_health(w, h, health)` | What an entity is, where it stands, its health; its most health set (and its health with it) |
| `entity_harm(w, h, harm)` | Hurt an entity (a tower's shot: `kind = .Game`, `by` the player it is credited to), told to the entity hooks as any harm is; true: it died |
| `entity_go(w, h, target)`, `entity_follow(w, h, route)`, `entity_stand(w, h)`, `entity_arrived(w, h)`, `entity_set_speed(w, h, speed)` | Steer a walker whose kind is `"brain": "steered"`: to a point by its own path, along a route, or still; whether it is there ([walkers](#walkers)) |
| `route_make(w, area, start, goal, kind)`, `route_free(w, r)`, `Route_Handle`, `route_cost(w, r, p)`, `route_reaches(w, r, p)`, `route_would_shut(w, r, p, block)` | A way to one goal over an area that every walker following it shares; what it costs from a block, whether there is one, whether a block placed there would shut it |
| `entity_glide(w, h, points)` | Send a steered walker along points (the blocks it stands in, at most `path.MAX_PATH`) in straight legs, with no physics, at a fraction of a walker's cost: for the many walkers of a game that knows its ground is walkable (a town's citizens on its roads). Its players are told where it is every `GLIDE_SEND_TICKS`; `entity_arrived` at the last point ([walkers](#walkers)) |
| `Request`, `request_value(s, r, T)` | One of the game's requests in its `request` hook, and its value as its type ([requests](#requests)) |
| `Structure_Fit`, `structure_fit(w, t, at, rotation, max_step)`, `structure_place(w, t, at, rotation, act)`, `structure_remove(w, t, at, rotation, act)` | A building as itself: whether a template (`game.Template`, built in code with `game.template_build` or a pack's) fits at a place turned a number of quarter turns (every cell it builds air or giving way, the ground under each column at most `max_step` below its floor), and it placed or taken down (its blocks still as it made them) in one bulk edit through the journal |
| `sim_speed_set(s, speed)`, `MAX_SIM_SPEED` | The world's life (its time, block updates, random ticks, entities) steps `speed` times a tick (0: paused; at most `MAX_SIM_SPEED`); the game steps its own simulation `s.sim_steps` times in its tick, which still comes once a tick. Players are not sped (each moves by its inputs, one a tick), so prediction holds, and the server stays deterministic |
| `entity_keep(w, h, target, near, far)`, `entity_sees(w, h, p)` | Steer a walker to keep within a band of distances from a point, facing it (chase: `0, reach`; keep distance; flee: `radius, radius + 1`); whether nothing solid lies between its eyes and a point |
| `entity_strike(w, h, target)`, `entity_shoot(w, h, p)`, `entity_striking(w, h)`, `Target`, `Strike` | A creature's attack, its kind's `attack` data: a blow at a player or an entity within its reach, or its shot at a point, each when its cooldown allows, credited to it (`Harm.creature`, `Entity_Harm.creature`); whether it just attacked |

The fields a game reads: `Server`'s `tick`, `clients`, `home`, `worlds`, `config`,
`registry`, `sim_speed`, `sim_steps` (the world's steps this tick: its speed, 0 while paused or frozen) and `listening` (others can join: opened to the LAN, or a dedicated server); `Client`'s `state`, `world`, `player` (its position, velocity, flying), `mode`
and `inventory`; `World`'s `rules` and `clock`. What it writes of the engine's state is, in
`start`, a world's clock; everything else goes through the list. A world's rules change
through `game_rule` (`core.game_rule(s, w, "explosion_size", "1.75")`), never by assignment:
the `import` lint refuses `w.rules.<name> = ...` in a game's code, as it refuses a name the
list lacks.

### Walkers

A game's creatures are entities of kinds its pack declares as data
(`games/<game>/pack/data/entities`, [packs.md](packs.md)): a box, health, a walker's speed
and jump, a model. One with `"brain": "steered"` has no mind of its own
(`server/core/walkers.odin`): it stands until the game sends it with `entity_go` (to a point,
by an A* path of its own, planned again when a block changes on it or it is stuck) or
`entity_follow` (along a route). A route (`route_make`) is a field over an area the game
names: the cost of the way to its goal from every block of it (`server/path`), searched once
for every walker that follows it, and again before its next use after a block in its area
changes. Its body is its kind's: as wide and tall as its box, climbing a step only if it
jumps a block high. `route_would_shut` asks, before a block is placed, whether it would
leave the route's start or a walker following it with no way: a maze a player builds stays
a maze, not a wall.

A player's weapons are items with their numbers as data in the game's pack
(`data/items`): a hitscan weapon's `weapon` (its `damage` hurts players and creatures alike, a
creature's rounded to whole health), and a melee weapon's `melee`, `{"damage": n, "reach":
blocks, "arc": degrees, "cooldown": seconds}`: with one in hand the attack button swings it
(no block breaks), and the server strikes every hittable entity and player whose box is
within reach of the eyes and inside the arc about where the player faces, in sight, each for
the damage (players as the `pvp` rule allows). Every one of those harms, and every other,
passes the game's `harming` hook first.

A walker that fights is the same steered walker with an `attack` in its kind
([packs.md](packs.md)). `entity_keep` holds it within a band of distances from a point the
game gives each tick (a player's feet): it walks straight at the point when it sees it on
its own level, by its own path when it does not (planned again when the point moves off its
end), backs straight away when too near, and stands facing it inside the band. What it
attacks and when is the game's: `entity_strike` lands a blow when the target's box is within
its reach and its cooldown has run, `entity_shoot` sends its kind's shot at a point; the
damage is its kind's, the harm is credited to the creature (a player killed by one reads
"was beaten by <kind>"). Walkers that overlap each other or a player are pushed apart as
they steer, so a pack does not stand in one place (players are not pushed: their clients
move them). `games/delve` is the model.

## The client's side: `engine.Game`

A game's client part (`games/<game>/client`) exports one constant `engine.Game` value
(`client/engine/game.odin`): its `info` (the same `INFO` as the server part's), its kinds (the same `KINDS` of its shared package as the
server part's), the type of its state, its console commands and the hooks the client calls.
A `Session` holds the game it plays and its state (ground rule 1: the session's arena, freed
with it; the App only holds the list of games, constant data). Every hook may be nil; all run
on the main thread, in the frame.

| Hook or field | When |
|---|---|
| `started(s)` | The session plays the game: welcomed, its state zero |
| `ended(s)` | The session ends (only after `started`; its state still there) |
| `received(s, r)` | A record of the game's kinds came, changed or went, or one of its events came, in the order sent |
| `hud(s, ctx)` | Every frame in the world, after the engine's HUD (`client/hud`'s `hud_draw`; F1 hides both), with the `ui.Context`; while F3 is open, its `ctx.screen` is the screen below the overlay (`App.debug_bottom`), so a bar at its top moves down rather than under the overlay |
| `debug(s) -> string` | Every frame with F3 open: one line of the overlay, shown as `game <id>: <line>` ("": none) |
| `scoreboard(s, board)` | Every frame the player list's key (<kbd>P</kbd>, `Player_List`) is held: the game fills `board` (an `engine.Scoreboard`: a title, `scoreboard_columns(board, "Frags", ...)`, at most `SCOREBOARD_COLUMNS`, and `scoreboard_row(board, name, cells..., you = mine)` per player, in the order to show), which the list shows in place of the engine's names, kills, deaths and pings |
| `commands` | Console commands (`engine.Command_Spec`), there while a world plays the game: `help` lists them and Tab completes them |
| `actions` | The names of the game's own actions, at most `game.MAX_GAME_ACTIONS` (`{"Use ability", "Drink potion"}`): the keys of `Game_1`.. (Z, X, B by default, rebindable) press them, and the server part's `action` hook hears them. The controls list shows them by the game's names while it plays |
| `camera(s) -> Game_Camera` | Every frame: the camera the game wants (`.Player`: the player's own, <kbd>F5</kbd>; `.First`, `.Third`; `.Top_Down`: over the head, `distance` blocks away, looking `angle` degrees down along `heading`, the world cut `cut` blocks above the feet so a roof does not hide the avatar). Under a top-down camera the mouse is free: the pointer aims (`s.aim`, `s.aim_entity`, and the point under it, `s.pointer`), the avatar faces it, and the movement keys move across the screen; the input sent is an ordinary one, so the server stays the judge and prediction holds |
| `camera(s) -> Game_Camera` (`.Free`) | A camera with no avatar, for a game whose players have no body in the world (`game.Ability.Bodiless` in their mode: they move freely, are not drawn, hit, pushed or in the way, and pick nothing up). It looks at the player's focus (its feet) from `distance` at first, zoomed by the wheel between `near` and `far`, `angle` degrees down, turned by F5 (a quarter) and Shift with the wheel; the movement keys, the pointer at a window's edge and the middle button dragged pan it, as the player's ordinary input along the camera's heading at the world's fly speed, so the server, which streams the world round the focus, stays the judge. The pointer and its buttons are the game's: `pointer_tool(s)` says what it is over (the ground's top block, an entity, the UI) and each button's press, drag and release with the block it went down on (a press over the UI is the UI's and starts none). The engine's own clicks (breaking, placing) and the hotbar are off |

Under a free pointer, the HUD a game draws is clickable: a click goes to the UI when the
pointer was over a widget or a panel (`ui.panel`, a framed backing, or `ui.block_pointer`)
when the UI was last drawn (`ui.pointer_over`), and to the world (the
game's `pointer_tool`) otherwise.

A game marks the ground from its `hud` hook (`client/engine/free_camera.odin`):
`ground_fill(s, lo, hi, color)` lays a translucent cover over the top of each column of a
rectangle (its highest solid block between `lo.y` and `hi.y`; a zone, a heat map),
`ground_outline(s, lo, hi, color)` draws the rectangle's edge on the ground, and
`structure_ghost(s, t, at, rotation, color)` a template's blocks, tinted (what a placement
would build: green where it may go, red where not). They are drawn by the debug pass, the
covers as translucent triangles, `MAX_FILL_VERTICES` of them and `MAX_WORLD_LINES` line ends a
frame: a whole map's overlay is one frame's work, not 64 outlines.

A game draws in the world from its `hud` hook (`client/engine/marks.odin`), through the
view the frame is drawn with: `world_point(s, ctx, p)` is where a point of the world is on
the screen (false behind the eyes or past `MARK_DISTANCE`), `world_label` puts text on a
plate there and `world_bar` a bar, `entity_bars(s, ctx, kind)` a health bar over every
entity of a kind that is hurt (an entity's health and its most come with it,
`Entity_Record`), and `world_box(s, lo, hi, color)` outlines blocks in the world this frame
(a placement's ghost, a footprint). `entity_place(s, id)` is where the session shows an
entity now, `entity_top(s, id)` the point just over it, and `entity_label(s, ctx, id, text,
rows)` and `entity_bar(s, ctx, id)` a plate of text (a name the game keeps in a record keyed
by the entity) and a health bar there.

The accessors are typed as the server's are: `engine.game_state(s, T)` checks `T` is the
declared state type; `engine.game_value(s, r, T)` is `r`'s value as `^T` when `r` is of the
game's kind whose value type is `T` (nil for a removal), so a hook reads a record with no
kind number and no cast:

```odin
received :: proc(s: ^engine.Session, r: game.Received) {
	if times, ok := engine.game_value(s, r, stopwatch.Times); ok && times != nil {
		view(s).times = times^
	}
}
```

## Which game a session plays

The server names its game in the handshake: `Welcome.game` (its id; never empty: a Welcome
without one does not decode). The client
looks for the client part of that id among the games it has (`App.games`); with it, the
session's schema gains the game's kinds, its state is made and `Welcome.schema` must match
(else the session fails: "the server runs a different version (its state schema is not
ours)"). A client without that game fails the session before playing with "the server plays
<id>, a game this version does not have", which the player reads on the screen a failed
session shows; nothing is half-applied. The server is told nothing: the client leaves.

A world of our own plays the game `voxiverse --game <id>` names (default: `sandbox`), but a
saved universe plays the game it records (`universe.cfg`'s `game`, [saves.md](saves.md)): the
universes screen and the `universe` command open it with that game, its card names it, and a
universe of a game this build lacks is not opened ("This universe plays <id>, a game this
version does not have"). The client starts its embedded server with that game's server part
(`App.server_games`), whose Welcome then names it like any server's. The id must be a game
with both parts; any other is refused at startup with the list of those there are.

### The launcher

The title screen lists the games the client was built with (`App.games`, the driver's
`CLIENT` list), the default first and the rest by folder: each its name on a button, its
description under it, before Singleplayer (the saved universes), Multiplayer, Options and
Quit. When the games do not all fit the screen, the launcher shows as many as fit, a page at
a time, with Previous games and More games under them (`launcher_page`, `App.launcher_page`). The mouse, the keyboard and a pad move through it as through the rest of the menu (the
default game is lit at once). Picking a game sets `App.launch`; once the frame's UI is drawn,
`play_game` starts a scratch world (nothing saved) playing it with the embedded server, the
same path as `--game <id>` and `singleplayer`. `--game <id>` with no `--exec`, `--scene`,
`--check` or `--benchmark` skips the title and goes straight into that world. Saved universes
open with the game they record (above); a new universe, made from Singleplayer, plays the
command line's game.

## The lists of games

No file lists the games. The build driver writes two before every `odin` it runs, from the
folders in `games/` (the collection `generated` is `build/generated`):

- `build/generated/games/games.odin`, the package `generated:games`, whose `SERVER` holds
  every `games/<game>/server` package's `GAME`;
- `build/generated/games/client/games.odin`, the package `generated:games/client`, whose
  `CLIENT` holds every `games/<game>/client` package's `GAME`.

Both are sorted by folder, and an `#assert` keeps each game's id its folder's name. Only the
executables' main packages import them (the `import` lint), the client's list `client/main`
alone, so the dedicated server links no client code. The dedicated server runs one with
`voxiverse-server --game <id>` (default: `sandbox`); the client gives both lists to the App.

Adding a game is a folder `games/<game>/` holding its shared package, a `server` package
that exports `GAME :: core.Game{...}` and a `client` package that exports `GAME ::
engine.Game{...}`, with their tests beside them: nothing else. `games/stopwatch` is the
model: the smallest game that uses every hook of the server's but those of harm (`hurt`,
`died`, `respawned`: `games/arena`, a deathmatch, is the model of those and of a game for
several players, its tests joining a second with `core.harness_player_join`), its record kept
with the universe (`save`, `load`), a client part with its state,
records, HUD, F3 line and command, and a record and an event of its own. Its server part's
tests run it on a stepped server with the harness's mirror client; its client part's tests
play it whole, a session joining the server part over the harness's network and drawing its
HUD, the one place a part imports another (the `import` lint lets a client part's tests
import its server part). `voxiverse --game stopwatch` plays it in a world of our own.

## The game's pack

A game may bring content as data, a pack of its own ([packs.md](packs.md)) in
`games/<game>/pack/`, named for the game (`pack.json`'s namespace and the `Pack_Source`'s,
though its folder is `pack`: its ids read `<game>:<name>`), laid out as any pack
([layout.md](layout.md), rule 6). `./build.sh packs` checks a pack folder named for its
namespace, so a copy of it named `<game>`. Its shared package
names the files in a constant `game.Pack_Source`, each `#load`ed (the executable carries it, as
it carries the base pack), and its server part puts it in `core.Game.pack`:

```odin
// games/flood/pack.odin (package flood)
PACK :: game.Pack_Source {
	namespace = "flood",
	files = {
		{"pack.json", #load("pack/pack.json")},
		{"data/game_modes/modes.json", #load("pack/data/game_modes/modes.json")},
	},
}
```

The server loads it after the universe's packs only in a session that plays the game
(`core.game_packs`); a pack not named for its game is refused at start. It is hashed into the
registry and sent to joining players as any pack is, so a client without the game still builds
the same content; a client hosting the game builds it in from the same constant.

## The game's state

A game declares two types and the server owns their memory (ground rule 1: the session's
arena, freed by `stop`; no globals, ground rule 4):

- `server_state`: one per session, zero when `start` is called: `core.game_state(s, T)`.
- `client_state`: one per seat, zero for each player who joins (the seat's block is zeroed
  when it is freed): `core.game_client_state(s, c, T)`.

The accessors are typed: they check that `T` is the type the game declared and return `^T`,
so game code holds no casts. A game names them once:

```odin
state :: proc(s: ^core.Server) -> ^Round {return core.game_state(s, Round)}
```

Anything a game keeps beyond these blocks it frees in its own hooks. Both live as long as the
session: what a game keeps across sessions (a record, a ladder, its admin's settings) it
writes with its `save` hook, as text of its own choosing, and reads back with `load` after
`start` (`game.cfg` in the universe, [saves.md](saves.md)). A scratch world (no universe
directory) saves nothing.

## Records and events

What a game tells its players beyond the engine's records (a score, a round, a timer) it
replicates as the engine does ([design.md](design.md), State replication): **records** of
typed state kinds and one-off **events**, by the same codec. It declares its kinds as data in
its shared package, a `game.Game_Kinds` of `game.State_Kind_Info` and `game.Event_Kind_Info`
(name, value type, key, lane, check...), and puts the value in `core.Game.kinds`:

```odin
// games/stopwatch/records.odin (package stopwatch)
Times :: struct {
	time:   u32,
	record: u32,
}

Record_Broken :: struct {
	name:    string `net:"max=16"`,
	seconds: u32,
}

KINDS :: game.Game_Kinds {
	states = {{name = "stopwatch.times", value = Times}},
	events = {{name = "stopwatch.record_broken", value = Record_Broken}},
}
```

- A kind's name is `<id>.<name>` (`game_schema` asserts it), and each of a game's kinds has a
  value type of its own (`schema_make` refuses two alike): the type names the kind, so game
  code holds no kind number and no cast.
- The schema is a run-time value (`game.game_schema(id, kinds)`): the engine's kinds, then the
  game's, the engine's keeping their ids whatever the game. No engine table (`State_Kind`,
  `STATE_KINDS`, `Event_Kind`) knows a game; in a session without the game its kinds do not
  exist, and a message that names one is malformed.
- The server puts a record with `core.game_put(s, c, &times)` (a keyed kind: `key =
  game.key_player(id)`), the counterpart of the engine's `state_put`, and sends an event with
  `core.game_event(s, c, &broken)`. Puts coalesce, keyed kinds are views and singletons
  persist, as for the engine's kinds.
- The client hands each of them to the client part's `received` hook, which reads it with
  `engine.game_value(s, r, stopwatch.Times)`; the engine applies none of them itself.
- The hashes: `Hello` carries the hash of the engine's kinds, which the server checks as
  before; `Welcome` names the game (`game`, its id) and carries the hash of every
  kind (`schema`), which the client checks once it has the same game's kinds. A client and
  server with different records of a game refuse each other as they do for the engine's.
- The harness's mirror client builds its schema with the server's game, so a game's test
  reads what its players were told: `core.mirror_game_record(&sess.mirror, stopwatch.Times)`.
  A test of a game for several players joins more beside the mirror, on a server that
  listens: `core.harness_player_join(&sess.h, &guest, "guest")`, a client over the
  harness's network that takes the packs, plays and stands still (the test moves it on the
  server's side), told its records and notices as any player (`harness_player_record`).

## Requests

What a game's client part asks of its server part beyond its actions (build this here, lay
a road along that, demolish the other) it sends as **requests**: values of types of its own
with a small payload (a position, a rectangle, an id; at most `game.MAX_GAME_REQUEST`
bytes), declared as data beside its records (`Game_Kinds.requests`, `Event_Kind_Info`s
named `<id>.<name>`) and encoded by the same codec. They are in the schema, so a client and
a server with different requests refuse each other at the handshake. The client part
sends one with `engine.game_request(s, &value)` (a `Game_Request` message after its last
input); the server decodes it only into a kind that is a request, checks it (the kind's
`check`, every enum in range, every string within its limit; one that does not decode
gets its client refused, as any malformed message does) and calls the game's `request`
hook, where `core.request_value(s, r, T)` reads it. A test sends one through the same
encoding and checks with `core.harness_request(s, c, &value)`. `games/hamlet` is the model.

`build schema` writes the engine's kinds into the Wireshark dissector; a game's kinds are not
in it. `build netdump` decodes with the engine's schema alone: in a trace of a session with a
game, a State message that carries the game's records counts as one that does not decode.
