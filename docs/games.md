# Games

The engine (`client/`, `common/`, `server/`) runs worlds; a **game** is the rules played in
one: a round, a goal, a score. Each game is native Odin in its own folder, `games/<game>/`,
compiled against the engine. The engine never imports a game, and adding a game edits no file
outside its folder ([layout.md](layout.md), rule 6, and the `import` lint). This is the
reference for writing one: its shape, a walk-through, every hook and call by task, how to
test it and take its pictures, and the rules.

## The shape of a game

```
games/<game>/
  README.md        what it is, how it plays, its commands; how to start it
  rules.odin       package <game>: INFO, its constants and rules (both sides')
  records.odin     package <game>: what the server tells the players (KINDS)
  pack.odin        package <game>: PACK, its pack's files #load'ed (if it has a pack)
  text.odin        package <game>: Text, TEXT_EN and tr: what its HUD says, by key
  pack/            its pack: entities, items, blocks, modes as data (packs.md)
  server/          package <game>_server: GAME :: core.Game{...}, its hooks; *_test.odin
  client/          package <game>_client: GAME :: engine.Game{...}, its hooks; *_test.odin
```

Three packages, as the engine's sides are split: the shared package (`package <game>`:
only `common:` and `core:`), the server part (`package <game>_server`: no `client:`) and
the client part (`package <game>_client`). A part imports no other part of its game but the
shared package, but for the client part's tests, which play the game against its server
part. A game imports no other game: what two share belongs in the engine. A proc of the
game's must not take the name of a package it imports (`play`, `hud`, `engine`): the
`import` lint refuses one, naming both (the compiler's own error names neither).

From `common:` a game takes the rules both sides share from `common:game` (blocks, items,
templates, `Game_Info`, a name's longest) and what it replicates from `common:protocol`
(`Game_Kinds`, `Received`, `Key`, `key_player`, `key_entity`): the protocol sits above the
rules, so the records and requests a game declares are the protocol's types.

What names a game is declared once, in its shared package, and both parts take it: a
`game.Game_Info` holding its id (the folder's name), the name players read and a line saying
what it is. The launcher lists the games by them; the description is one line in the
launcher's small text, at most the title's column wide (`screen.TITLE_WIDTH`; a
`client/main` test measures every game's). `core.Game` and `engine.Game` hold it by
`using`, so `g.id` reads as a field of either.

No file lists the games. The build driver writes two before every `odin` it runs, from the
folders in `games/` (the collection `generated` is `build/generated`): `generated:games`,
whose `SERVER` holds every server part's `GAME`, and `generated:games/client`, whose
`CLIENT` holds every client part's. Both are sorted by folder, an `#assert` keeps each
game's id its folder's name, and only the executables' main packages import them
(`client/main` the client's list alone, so the dedicated server links no client code), and
the trace tools the server's.

## A walk-through

A small game, from nothing: every player in a walled arena, a round counted down, played,
and shown. (`games/flood` is this game grown; `games/stopwatch` is the smallest that uses
every server hook but harm's.)

```odin
// games/tag/rules.odin
package tag

import "common:game"

INFO :: game.Game_Info{id = "tag", name = "Tag", description = "One is it; touch another."}
Phase :: enum u8 {Waiting, Countdown, Playing, Over}
COUNTDOWN :: 4.0
ROUND :: 120.0
```

```odin
// games/tag/records.odin
package tag

import "common:protocol"

Round :: struct {phase: Phase, left: u16, it: string `net:"max=16"`}
KINDS :: protocol.Game_Kinds{states = {{name = "tag.round", value = Round}}}
```

```odin
// games/tag/server/game.odin
package tag_server

import "common:game"
import "games:tag"
import "server:core"
import "server:play"

GAME :: core.Game {
	info = tag.INFO, kinds = tag.KINDS, server_state = Tag,
	configure = configure, start = start, tick = tick,
}

Tag :: struct {phase: play.Phase(tag.Phase), built: bool}
state :: proc(s: ^core.Server) -> ^Tag {return core.game_state(s, Tag)}

GROUND :: play.Arena{size = {24, 8, 24}, wall_top = 15, depth = 2}

configure :: proc(config: ^core.Config) {play.configure_flat(config, {12, 1, 12}, "survival")}

start :: proc(s: ^core.Server) -> bool {
	play.world_still(s, s.home)
	core.world_keep(s.home, play.arena_area(GROUND))
	return true
}

tick :: proc(s: ^core.Server) {
	g := state(s)
	switch g.phase.now {
	case .Waiting:
		if play.present(s) > 0 {play.phase_set(s, &g.phase, .Countdown)}
	case .Countdown:
		if !g.built {
			t := game.template_make(GROUND.size, context.temp_allocator)
			game.template_fill(&t, {0, 0, 0}, {23, 0, 23}, .Stone) // the floor
			g.built, _ = play.arena_build(s, s.home, GROUND, &t, force = false)
		} else if play.phase_seconds(s, &g.phase) >= tag.COUNTDOWN {
			play.phase_set(s, &g.phase, .Playing)
		}
	case .Playing, .Over:
	}
	round := tag.Round{g.phase.now, play.phase_left(s, &g.phase, tag.ROUND), ""}
	for &c in s.clients {if play.here(s, &c) {core.game_put(s, &c, &round)}}
}
```

```odin
// games/tag/client/game.odin
package tag_client

import "core:fmt"

import "client:engine"
import "client:ui"
import "common:protocol"
import "games:tag"

GAME :: engine.Game {
	info = tag.INFO, kinds = tag.KINDS, state = View, received = received, hud = hud,
}

View :: struct {round: tag.Round}
view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	if round, ok := engine.game_value(s, r, tag.Round); ok && round != nil {view(s).round = round^}
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	rest := ctx.screen
	engine.top_bar(ctx, &rest, fmt.tprintf("TAG  %d s left", view(s).round.left))
	if view(s).round.phase == .Countdown {engine.banner(ctx, -140, "GET READY", 1.5, ctx.theme.text)}
}
```

Then the tests beside each part ([Testing a game](#testing-a-game)), a README, and
`./build.sh run -- --game tag`. Nothing else: the driver finds the folder.

## The server's side: `core.Game`

A game's server part exports one constant `core.Game` value: its `info`, its `kinds`, its
pack, the types of its state and the hooks the server calls (`Game` in
`server/core/server.odin`). Whoever starts the server puts it in `Config.game`. Every
session plays exactly one game: `start` refuses a config whose game has no valid id. When
nobody names one, the executables play `game.DEFAULT_GAME`, `sandbox` (the engine's open
world, its configure choosing the Earth generator); the engine's own tests play
`core.HARNESS_GAME`, which has no hooks. Every hook may be nil.

| Hook | When | Thread |
|---|---|---|
| `configure(^Config)` | First thing in `start`, before the config is checked: change the world's generator, mode, spawn... | the caller's |
| `start(s) -> bool` | The session is set up (worlds, seats, the game's state), before the first tick; false: `start` fails and frees the session | the caller's |
| `tick(s)` | Every tick, after the entities' (also while the world is frozen) | the server's |
| `spawned(s, w, h) -> bool` | A creature of a kind with a spawn rule (its pack's `spawn`) appeared by itself near a player (natural): the game makes it what it is (its record, its looks) or refuses it (false: it goes again). Every natural spawn is told, the base pack's kinds' too | the server's |
| `think(s, w, kind, entities)` | Every tick, for each of its kinds whose `brain` is `game`, with all of that kind's creatures in `w` whose ground is loaded (lowest id first), before they are steered: their minds, in one call for a crowd ([walkers](#walkers)) | the server's |
| `joined(s, c)` | A player is playing: welcomed, in its world | the server's |
| `left(s, c)` | A playing player leaves (still seated, its state still there); not called for those still playing when the server stops | the server's |
| `command(s, c, name, args) -> bool` | A `/command` the server has none of (relative coordinates already expanded); the game checks its own arguments and permissions (`core.allowed`); false: unknown | the server's |
| `hurt(s, c, harm)` | A player was hurt and lives (its health already less): `harm` is a `core.Harm`, the amount, the kind of source (`game.Source_Kind`: a fall, an explosion, a weapon...), `by` the player who did it (the one hurt, for its own rocket; nil for nobody), `creature` the entity that did it (its id; 0 for none) and the weapon's name for a shot | the server's |
| `died(s, c, harm)` | A player died of `harm`, after the engine's death: the line told, `kills` and `deaths` counted, its things dropped (by its mode and the world's rules) | the server's |
| `respawned(s, c)` | A dead player stands again, after the engine stood it at the world's spawn with full health and its mode's kit: the game may move it (`teleport`) and change what it holds. Also for a dead player who leaves, after `left` | the server's |
| `editing(s, c, at, old, new) -> string` | A player would change the block at `at` from `old` to `new` (`.Air` for a break) and the engine's rules allow it: `""` lets it, anything else refuses it, the block stays and the player is told that text | the server's |
| `entity_use(s, c, h, stack) -> string` | A player uses (right-clicks) entity `h` within its reach, holding `stack`: as `editing` for a block, `""` lets it (the game does what the use does for its kinds: shears, feeds, trades), anything else refuses it, nothing happens and the player is told that text; the engine's own use of the kind, if it has one, follows a use let through | the server's |
| `block_changed(s, w, change)` | Blocks of world `w` changed since the game's last tick, each told once, in order, before its next one: one block (what it was and is) or a bulk edit's box (`bulk`), and `by` the player whose edit it was (nil: the world, a command, the game). At most `MAX_NOTED_CHANGES` a tick (more are dropped, and logged) | the server's |
| `entity_hurt(s, w, h, harm)` | An entity of world `w` was hurt and lives (its health already less): `harm` is a `core.Entity_Harm`, the amount, the kind of source (a blast, a player's shot or blow, `.Game` for the game's own `entity_harm`), `by` the player who did it, `creature` the entity that did it, the weapon's name for a shot and `from`, where it came from (the striker, the shooter, a blast's centre: where a creature flees from) | the server's |
| `entity_died(s, w, dead, harm)` | An entity of `w` died of `harm`: everyone who knew it was shown it die, and it is gone (`dead`, a `core.Dead_Entity`, says its id, kind and where it was) | the server's |
| `harming(s, h)` | Any harm is about to be done, to a player or an entity, whoever does it: `h` is a `core.Harming`, the amount, its kind, who does it, what the player holds (`stack`, its data too) and who takes it; the hook may change `h.amount` (stats, armour, a critical blow), 0 or less and nothing is done. An entity's health is whole: the amount is rounded after the hook | the server's |
| `picking(s, c, stack) -> Pickup` | A player walks over a dropped stack it may pick up: `.Take` (into its inventory, as far as there is room), `.Leave` (it stays) or `.Taken` (the game took it its own way, a purse, a potion drunk: it is gone) | the server's |
| `action(s, c, index)` | A player pressed one of the game's own actions (`index` into the client part's `actions`): an ability, a potion. Not while dead | the server's |
| `request(s, c, r)` | A player's client part sent one of the game's requests ([below](#requests)), decoded and checked: `core.request_value(s, r, T)` reads it. Whether the player may, can afford it and where it goes is the hook's to judge | the server's |
| `stop(s)` | After the last tick, before the last save; only after a `start` that succeeded | the caller's |
| `save(s, out)` | A save captures this tick (an autosave, `/save`, the last one): the game writes what it keeps to the `strings.Builder` as text, saved with the universe as `game.cfg` in the same transaction ([saves.md](saves.md)) | the server's (the last save: the caller's) |
| `load(s, text) -> bool` | Right after `start`, in a universe that has a `game.cfg`: its text; false: the game does not understand it, and the universe is refused | the caller's |

A game's tick runs inside the server's, so the stepped server (and its tests) run it too, and
it follows [determinism.md](determinism.md): no clock, no unseeded randomness
(`base.rng_make` from the universe's seed, `s.config.seed`).

## What a game may call

A game's code (not its tests, which drive the harness) names of `server:core` only these;
the `import` lint reads this table and refuses any other `core.<name>` in a game, and fails
when the table names something `server/core` does not declare. A name joins the list with
the engine commit that makes it for games, documented where it is declared.

| Name | What it is for |
|---|---|
| `Game`, `Config`, `Server`, `Client`, `World`, `Harm`, `Entity_Harm`, `Harming`, `Dead_Entity`, `Block_Change`, `Pickup`, `Request` | The game itself, the config `configure` changes, the session, a player, a world, and what its hooks are told |
| `game_state(s, T)`, `game_client_state(s, c, T)`, `entity_data(w, h, T)` | The game's state, for the session and for a seat; its record on an entity of its kinds ([below](#the-games-state)) |
| `game_put(s, c, &value)`, `game_event(s, c, &value)` | Its records and events ([below](#records-and-events)) |
| `request_value(s, r, T)` | One of its requests, in its `request` hook, as its type ([below](#requests)) |
| `notice(s, c, text)`, `announce(s, text)` | Tell one player; tell every player in the chat |
| `Game_Stat`, `Stat_Kind`, `stat_count(s, c, name, amount)`, `stat_world(s, w, name, amount)` | The game's own statistics (`Game.stats`: each a name, whether it counts or measures a distance in centimetres or a time in seconds, and the experience a player earns for each one counted): a player's (with its character and its world) or the world's alone, kept and shown with the engine's ([below](#the-games-state)) |
| `client_name(c)`, `allowed(s, c, node)`, `player_id(s, c)` | A player's name; whether it holds a permission; its id (its seat): the key of a record about it (`protocol.key_player`), the same on every side |
| `player_ref(s, c)`, `player_of(s, ref)`, `Player_Ref` | A player held past the moment (who built a tower, whose kill a shot is): `player_of` gives the player still playing in that seat, or nil once it left |
| `teleport(s, c, position, look, flying)` | Move a player in its world (standing where it fits once the blocks are there, or flying) |
| `game_mode(s, c, id)`, `kit_give(s, c)` | Put a player in a mode by id (a pack's too: `flood:out`), journalled as the game's; give it what its mode's kit has that it lacks, weapons full |
| `item_count(c, item)`, `item_give(s, c, item, count)`, `item_take(s, c, item, count)`, `item_clear(s, c, item)`, `item_spend(s, c, item, count)`, `hotbar_select(s, c, slot)` | A player's slots as the game's store: how many of an item it carries, give (what fits), take, take all, booked in the item ledger as the game's; spend on a use (fed to a creature: booked as used, kept by a mode that gives without end; false when it carries fewer); a hotbar slot put in its hand |
| `item_drop(s, w, position, stack)` | Drop a stack into the world with its game data (`game.Stack.data`, a `u32` of the game's own: a rolled damage, a rarity, kept with the stack); the first player to walk over it picks it up, as the `picking` hook decides |
| `head_in_water(s, c)`, `player_health_bonus(s, c, bonus)`, `heal_player(c, amount)` | A player's eyes are in water; add to its most health (it stays with the seat until changed, a respawn fills it); heal a living player up to its most |
| `game_rule(s, w, name, value)` | Change a world's rule (as the `rule` command names it; the value as text), journalled as the game's and told to the world's players |
| `sim_speed_set(s, speed)`, `MAX_SIM_SPEED` | The world's life steps `speed` times a tick (0: paused); the game steps its own simulation `s.sim_steps` times in its tick. Players are not sped, so prediction holds |
| `world_keep(w, area)`, `world_ready(w, area)`, `world_release(w)` | Keep an area loaded with nobody near; whether all of it is there; let it go |
| `under_sky(w, p)` | Nothing stands above a block (the sky's light reaches it); with `block_at` and the time of day (`game.time_of_day(w.clock)`) what a spawn or a brain asks of the place |
| `block_at(w, p)`, `game_act(s, w, system)`, `Act`, `set_block(w, p, block, act)`, `bulk_edit(w, edit, act)`, `Bulk_Edit`, `Box`, `Sphere` | Read a block (false: not loaded); a cause for the game's block changes (one per cause), and changes through the edit journal ([journal.md](journal.md)): one block, or a box or sphere set, replaced or pasted from a template |
| `structure_fit(w, t, at, rotation, max_step)`, `structure_place(w, t, at, rotation, act)`, `structure_remove(w, t, at, rotation, act)` | A building as itself: whether a template fits at a place turned a number of quarter turns (every cell air or giving way, the ground at most `max_step` under its floor), placed or taken down in one bulk edit |
| `entity_spawn(w, kind, position, natural)`, `entity_gone(w, h)` | An entity of a kind (the game's pack's, `<game>:<name>`) at a place, its handle (0: the world is full); gone again, with no death to show |
| `entity_find(w, id)`, `entities_of(w, kind, center, radius)`, `entities_each(w)`, `entities_next(&it)` | An entity by its id; the entities of a kind near a point, nearest first; every entity, lowest id first |
| `entity_yaw(w, h)`, `entity_pitch(w, h)`, `entity_set_look(w, h, yaw, pitch)` | Which way an entity faces, and turning it (a head that looks up at a player or down at the grass: the client draws a part that swings by `pitch` with it); a walker moving is turned by its steering as it goes |
| `entity_id(w, h)`, `entity_kind(w, h)`, `entity_pos(w, h)`, `entity_health_of(w, h)`, `entity_max_health(w, h)`, `entity_set_max_health(w, h, health)` | What an entity is, where it stands, its health; its most health set (and its health with it) |
| `entity_show(w, h, look, on)` | Show or hide a look of the entity's kind (its pack's `looks`, by name: shorn, young, a colour): told to the players who know it and drawn as the kind's model says ([packs.md](packs.md)), kept with the entity; false for a look the kind has not |
| `entity_known(c, id)` | Whether a player has been told of an entity (it is near it): a record of the game's keyed by the entity (`protocol.key_entity(id)`) goes to the players who know it |
| `entity_harm(w, h, harm)` | Hurt an entity (a tower's shot: `kind = .Game`, `by` the player it is credited to), told to the hooks as any harm is; true: it died |
| `entity_go(w, h, target)`, `entity_follow(w, h, route)`, `entity_stand(w, h)`, `entity_arrived(w, h)`, `entity_set_speed(w, h, speed)` | Steer a walker whose kind is `"brain": "steered"`: to a point by its own path, along a route, or still; whether it is there ([walkers](#walkers)) |
| `entity_keep(w, h, target, near, far)`, `entity_sees(w, h, p)` | Keep a walker within a band of distances from a point, facing it (chase: `0, reach`; keep distance; flee); whether nothing solid lies between its eyes and a point |
| `entity_strike(w, h, target)`, `entity_shoot(w, h, p)` | A creature's attack, its kind's `attack` data: a blow at a player or entity within its reach, or its shot at a point, each when its cooldown allows, credited to it |
| `entity_glide(w, h, points)` | Send a steered walker along points in straight legs, with no physics, at a fraction of a walker's cost (a town's citizens on its roads); `entity_arrived` at the last |
| `route_make(w, area, start, goal, kind)`, `route_free(w, r)`, `Route_Handle`, `route_cost(w, r, p)`, `route_reaches(w, r, p)`, `route_would_shut(w, r, p, block)` | A way to one goal over an area that every walker following it shares; what it costs from a block, whether there is one, whether a block placed there would shut it |

The fields a game reads: `Server`'s `tick`, `clients`, `home`, `worlds`, `config`,
`registry`, `sim_speed`, `sim_steps` and `listening` (others can join: opened to the LAN, or
a dedicated server); `Client`'s `state`, `world`, `player` (its position, velocity, flying),
`dead`, `mode` and `inventory`; `World`'s `rules` and `clock`. What it writes of the engine's
state is, in `start`, a world's clock; everything else goes through the list. A world's rules
change through `game_rule`, never by assignment: the lint refuses `w.rules.<name> = ...` in a
game's code. Types a call returns (`Mode_Result`, `Strike`, `Structure_Fit`,
`Entity_Iter`...) are used without being named.

## What the games share: `server:play`

What the server parts of several games did alike is `server/play`, built on the list
above alone (the lint holds it to the list as it holds a game). A game reaches for it first;
it is where the next shared piece goes.

| Name | What it is for |
|---|---|
| `Phase(P)`, `Clock`, `phase_set(s, &p, to)`, `phase_seconds(s, &p)`, `phase_left(s, &p, seconds)` | The game's phase (its own enum: Waiting, Playing, Results...) and the tick it began: seconds into it, whole seconds left of a phase that lasts so long (a countdown on the screen) |
| `configure_flat(config, spawn, mode)` | A flat world of the game's own with nothing wandering in, arriving at spawn, in mode unless the universe asks for another |
| `world_still(s, w, clock)`, `world_rule(s, w, name, value)` | The time standing (noon), nothing growing or dropping; a rule set to a value of any type |
| `here(s, c)`, `present(s)` | A player playing in the home world, where a game stages its rounds; how many are |
| `Arena`, `arena_area(a)`, `arena_inside(a)`, `arena_build(s, w, a, template, force)`, `arena_holds(a, p, above, below)` | A walled ground built whole from a template each round (stone under it, walls round it, so blasts find stone), or with `open` the template alone (a course in the sky); the box to keep loaded; its inside; whether a point is within its walls |
| `watch(s, c, mode, at, look)`, `look_at(from, to)`, `hold(s, c, item)` | A player watching rather than playing (out, arrived during a round, between matches): flying in a mode at its seat's place along a line, facing a point; the look from one point to another; an item from the hotbar in hand |
| `settings_command(s, c, table, &settings, node, args)`, `settings_usage(table)`, `settings_text(table, &settings)`, `settings_save`, `settings_read` | The admin's settings: a struct of the game's described by a `base.Var_Table` (each field's help and bounds), set by `/<game> set <name> <value>` under a permission (out of bounds: refused, with the usage; `set` alone tells them), so a game's own subcommand may share a setting's name; shown, kept with the universe and read back |
| `Saved_Line`, `saved_lines(text)`, `settings_read(table, &settings, text) -> (own, ok)` | What a game keeps with the universe (`game.cfg`) read as lines of a key and the rest (`best = 12`, `hero 3 140 7 ana`); `settings_read` reads the settings' lines and hands the game the others, in order |

A seeded layout is a template made in code: `game.template_make(size)`, then
`game.template_fill(&t, lo, hi, block)` for each box (clipped to the template), pasted by
`arena_build` (or `bulk_edit`'s `.Paste`).

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
leave the route's start or a walker following it with no way.

A creature with a mind of its own has `"brain": "game"`: the game's `think` hook is given
every creature of the kind each tick, in one call (a herd of hundreds costs one call and
what the game reads once for all of them), and steers them with the same calls, which the
engine then carries out; an engine brain (`grazer`) is only the default for a kind that
names it. What it decides from is the game's record on each (`entity_data`) and what it
asks the world.

A walker that fights is the same steered walker with an `attack` in its kind. `entity_keep`
holds it within a band of distances from a point the game gives each tick (a player's
feet): it walks straight at the point when it sees it on its own level, by its own path
when it does not, backs straight away when too near, and stands facing it inside the band.
What it attacks and when is the game's: `entity_strike` lands a blow when the target's box is
within its reach and its cooldown has run, `entity_shoot` sends its kind's shot at a point;
the damage is its kind's, credited to the creature (a player killed by one reads "was
beaten by <kind>"). Walkers that overlap each other or a player are pushed apart as they
steer (players are not pushed: their clients move them). `games/delve` is the model.

A player's weapons are items with their numbers as data in a pack (`data/items`): a hitscan
weapon's `weapon` (its `damage` hurts players and creatures alike; with `"ammo": "<item id>"`
a reload loads what the player carries of that item, taking it, and none carried is no
reload: without it a reload is free), and a melee weapon's
`melee`, `{"damage": n, "reach": blocks, "arc": degrees, "cooldown": seconds}`: the attack
button swings it, striking every hittable entity and player within reach and inside the
arc, each for the damage (players as the `pvp` rule allows). The base pack's rifle, rocket
launcher and grappling hook are any game's. Every harm passes the game's `harming` hook.

## The client's side: `engine.Game`

A game's client part exports one constant `engine.Game` value (`client/engine/game.odin`):
its `info` and `kinds` (the same as the server part's), the type of its state, its console
commands and the hooks the client calls. A `Session` holds the game it plays and its state
(the session's arena, freed with it). Every hook may be nil; all run on the main thread, in
the frame.

| Hook or field | When |
|---|---|
| `started(s)` | The session plays the game: welcomed, its state zero (look up the pack's names in `s.reg` here) |
| `ended(s)` | The session ends (only after `started`; its state still there) |
| `received(s, r)` | A record of the game's kinds came, changed or went, or one of its events came, in the order sent: `engine.game_value(s, r, T)` is its value as `^T` when it is of the kind whose type is `T` (nil for a removal) |
| `hud(s, ctx)` | Every frame in the world, after the engine's HUD (F1 hides both), with the `ui.Context`; while F3 is open, `ctx.screen` is the screen below the overlay |
| `debug(s) -> string` | Every frame with F3 open: one line of the overlay, shown as `game <id>: <line>` ("": none) |
| `scoreboard(s, board)` | Every frame the player list's key (<kbd>P</kbd>) is held: the game fills `board` (`scoreboard_columns(board, "Frags", ...)`, at most `SCOREBOARD_COLUMNS`, and `scoreboard_row(board, name, cells..., you = mine)` per player, in order), shown in place of the engine's |
| `commands` | Console commands (`engine.Command_Spec`), there while a world plays the game: `help` lists them and Tab completes them |
| `actions` | The names of the game's own actions, at most `game.MAX_GAME_ACTIONS`: the keys of `Game_1`.. (Z, X, B by default, rebindable) press them, the server part's `action` hook hears them, the controls list shows them by these names |
| `camera(s) -> Game_Camera` | Every frame: the camera the game wants. `.Player` (the player's own, <kbd>F5</kbd>), `.First`, `.Third`; `.Top_Down` (over the head, `distance` away, `angle` degrees down along `heading`, the world cut `cut` blocks above the feet): the pointer aims (`s.aim`, `s.aim_entity`, `s.pointer`), the avatar faces it, the movement keys move across the screen; `.Free` (no avatar, for a mode with `game.Ability.Bodiless`): looks at the player's focus from `distance`, zoomed between `near` and `far`, panned by the movement keys, the screen's edge and the middle button; `pointer_tool(s)` says what the pointer is over and each button's press, drag and release |

The accessors are typed as the server's are: `engine.game_state(s, T)` checks `T` is the
declared state type, `engine.game_value(s, r, T)` checks the kind, so a hook holds no kind
number and no cast.

### What a game's HUD is made of

| Name | What it is for |
|---|---|
| `top_bar(ctx, &rest, text)` | A line of status across the top of the screen, on the HUD's backing, cut from `rest` |
| `banner(ctx, at, text, scale, color)` | Big text across the screen with a shadow, its middle `at` pixels from the screen's (laid out for 720 high and shrunk with a smaller screen, as under F3), `scale` times the title's size |
| `Flash`, `flash(&f, s, text, tone, seconds)`, `flash_draw(ctx, &f, s, at, scale)`, `Tone` | A banner that stands a few seconds after the news that brought it (a wave set out, a level gained), kept in the game's view, coloured by its tone (`.Good`, `.Warn`, `.Bad`) |
| `world_point(s, ctx, p)`, `world_label(s, ctx, p, text)`, `world_bar(s, ctx, p, fraction)` | Where a point of the world is on the screen (false behind the eyes or past `MARK_DISTANCE`); a plate of text there; a bar |
| `entity_place(s, id)`, `entity_top(s, id)`, `entity_label(s, ctx, id, text, rows)`, `entity_bar(s, ctx, id)`, `entity_bars(s, ctx, kind)` | Where the session shows an entity, the point over it, a plate of text there (a name the game keeps in a record keyed by the entity), its health bar; a bar over every hurt entity of a kind |
| `world_box(s, lo, hi, color)` | An outline of blocks in the world this frame (a placement's ghost, a footprint) |
| `ground_fill(s, lo, hi, color)`, `ground_outline(s, lo, hi, color)`, `structure_ghost(s, t, at, rotation, color)` | A translucent cover over the tops of a rectangle's columns (a zone, a heat map), its edge on the ground, a template's blocks tinted (what a placement would build), `MAX_FILL_VERTICES` and `MAX_WORLD_LINES` a frame |
| `puff_add(s, puff)` | A speck that drifts and fades (a tower's tracer, a blast's smoke) |
| `game_request(s, &value)` | Send the server part one of the game's requests ([below](#requests)) |
| `Seats(T)`, `seats_received(s, &seats, r)`, `seat_mine(s, &seats)`, `seats_ranked(&seats, before)` | What the game keeps of each player from a record of its keyed by the player (`key_player`, with a `name`): the last value by seat, its name copied out of the message, forgotten when the server stops putting it; the player's own; the seats told of in order (ties by name), a scoreboard's rows |

Under a free pointer (a top-down or free camera) the HUD a game draws is clickable: a click
goes to the UI when the pointer was over a widget or a panel (`ui.panel`,
`ui.block_pointer`) when the UI was last drawn, and to the world (`pointer_tool`) otherwise.

### What a game's HUD says

What a game's HUD and banners say is the game's own text, not the engine's table
(`client/engine/text.odin`), so adding a game edits no shared file. The game declares it in
its shared package (`text.odin`), as the engine does its own: an enum of keys, the English
table, and a `tr` that formats one with `base.text_format` (`{0}`, `{1}`: the arguments by
position):

```odin
// games/flood/text.odin (package flood)
Text :: enum u8 {Status_Waiting, Round_Title, Made_It, ...}
TEXT_EN := [Text]string{.Status_Waiting = "FLOOD  waiting for players", .Round_Title = "ROUND {0}", .Made_It = "{0} of {1} made it", ...}
tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}
```

A test holds every key to its text (`base.text_missing(TEXT_EN)`); a translation is another
table of the same keys beside it. `games/flood` is the model; the other games still write
their HUDs' English in place, and the server's notices and announcements are English.

## Which game a session plays

The server names its game in the handshake: `Welcome.game` (its id; never empty). The client
looks for the client part of that id among the games it has (`App.games`); with it, the
session's schema gains the game's kinds, its state is made and `Welcome.schema` must match
(else the session fails: "the server runs a different version (its state schema is not
ours)"). A client without that game fails the session before playing with "the server plays
<id>, a game this version does not have"; nothing is half-applied.

A world of our own plays the game `voxiverse --game <id>` names (default: `sandbox`), but a
saved universe plays the game it records (`universe.cfg`'s `game`, [saves.md](saves.md)): the
universes screen and the `universe` command open it with that game, and a universe of a game
this build lacks is not opened. The client starts its embedded server with that game's
server part (`App.server_games`). The dedicated server runs one with `voxiverse-server --game
<id>`.

### The launcher

The title screen lists the games the client was built with, the default first and the rest
by folder: each its name on a button, its description under it, before Singleplayer,
Multiplayer, Options and Quit. When they do not all fit the screen, the launcher shows as
many as fit, a page at a time, with Previous games and More games under them
(`launcher_page`, `App.launcher_page`). Picking a game starts a scratch world (nothing saved)
playing it with the embedded server, the same path as `--game <id>`. `--game <id>` with no
`--exec`, `--scene`, `--check` or `--benchmark` skips the title and goes straight into that
world. The title's image baselines show the launcher's pages: a new game changes them, and
its commit re-accepts them.

## The game's pack

A game may bring content as data, a pack of its own ([packs.md](packs.md)) in
`games/<game>/pack/`, named for the game (`pack.json`'s namespace: its ids read
`<game>:<name>`), laid out as any pack. Its shared package names the files in a constant
`game.Pack_Source`, each `#load`ed (the executable carries it, as it carries the base pack),
and its server part puts it in `core.Game.pack`:

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

The server loads it after the universe's packs only in a session that plays the game; a pack
not named for its game is refused at start. It is hashed into the registry and sent to
joining players as any pack is. `./build.sh packs games/<game>/pack` checks it where it is
(a folder `pack` under a game's takes the game's name as its namespace). A game's modes are where its rules for players
live: a mode that flies and takes no harm for those watching, one with the kit for those
playing.

## The game's state

A game declares two types and the server owns their memory (the session's arena, freed by
`stop`; no globals):

- `server_state`: one per session, zero when `start` is called: `core.game_state(s, T)`.
- `client_state`: one per seat, zero for each player who joins (the seat's block is zeroed
  when it is freed): `core.game_client_state(s, c, T)`.

- `entity_data`: a record on each entity of the game's own kinds (its pack's,
  `<game>:<name>`): `core.entity_data(w, h, T)`, nil for an entity of another kind. Zero
  when the entity comes to be, at most `game.MAX_ENTITY_DATA` (64) bytes of numbers,
  booleans, enums, bit sets and fixed arrays and structs of them (`start` refuses a type
  with a pointer, slice, string or map). It is saved and loaded with the world with the
  entity itself, field by field by name (`entities.cfg`, [saves.md](saves.md)): a field
  added later loads as zero. It goes to no client unless the game puts it, or what it
  shows of it, in a record of its own keyed by the entity (`protocol.key_entity(id)`, to
  the players who know it: `entity_known`).

- `stats`: the statistics the game keeps of its players, `[]core.Game_Stat{{"sheep.sheared",
  .Count}, ...}`. `core.stat_count(s, c, name, amount)` counts one for a player (and its
  world), `core.stat_world(s, w, name, amount)` for a world alone; they are kept with the
  character and the world as the engine's counters are and shown with them in the
  statistics, by their dotted names (a distance under `distance.<name>`, a time under
  `time.<name>`, so it shows its unit). `start` refuses a name that is not dotted `a-z`,
  `0-9` and `_`, one named twice, or a count whose first part is one of the engine's
  (`blocks`, `items`, `xp`...).

A game's creature whose kind is `"saved": true` outlives a restart whole: its kind, place,
health and most health, its record, and where it was steered (`entity_go`'s point,
`entity_keep`'s band, `entity_glide`'s points left, its speed; a route it followed is the
game's to give it again, `entity_follow`). The game finds its creatures again by walking
them (`entities_each`, `entities_of`) and reading their records, rather than making them
again.

A game names them once (`state :: proc(s: ^core.Server) -> ^Round {return
core.game_state(s, Round)}`). Anything it keeps beyond these blocks it frees in its own
hooks. Both live as long as the session: what a game keeps across sessions (a record, a
ladder, its admin's settings) it writes with its `save` hook as text of its own choosing and
reads back with `load` (`game.cfg` in the universe, [saves.md](saves.md)); a scratch world
saves nothing.

## Records and events

What a game tells its players beyond the engine's records (a score, a round, a timer) it
replicates as the engine does ([design.md](design.md), State replication): **records** of
typed state kinds and one-off **events**, by the same codec. It declares its kinds as data in
its shared package, a `protocol.Game_Kinds`, and puts it in `core.Game.kinds` and
`engine.Game.kinds`:

```odin
// games/stopwatch/records.odin (package stopwatch, importing common:protocol)
Times :: struct {
	time:   u32,
	record: u32,
}

Record_Broken :: struct {
	name:    string `net:"max=16"`,
	seconds: u32,
}

KINDS :: protocol.Game_Kinds {
	states = {{name = "stopwatch.times", value = Times}},
	events = {{name = "stopwatch.record_broken", value = Record_Broken}},
}
```

- A kind's name is `<id>.<name>`, and each of a game's kinds has a value type of its own: the
  type names the kind, so game code holds no kind number and no cast.
- A keyed kind (`key = .Player`, `.Entity`, with its `max_records`) is a view: rebuilt every
  tick, what the server does not put is removed. A singleton persists. Puts coalesce: put
  every tick, and only changes are sent.
- The server puts a record with `core.game_put(s, c, &value)` (a keyed kind: `key =
  protocol.key_player(id)` or `protocol.key_entity(id)`) and sends an event with
  `core.game_event(s, c, &value)`.
- The schema (the engine's kinds, then the game's) is checked when a client joins: a client
  and server with different records of a game refuse each other.

`build schema` writes the engine's kinds into the Wireshark dissector; a game's kinds are not
in it. A trace knows its game (its Welcome names it, `game.trace_game`): `build netdump` reads
it with that game's kinds and `build replay` replays it with that game's rules, both finding
the game among the server parts' list (`generated:games`); a game this build lacks is read
with the engine's kinds alone (its records do not decode) and replayed as the default game.
Both still decode blocks and items by the base pack's registry, not the session's, so a
game's pack content in a trace reads as numbers.

## Requests

What a game's client part asks of its server part beyond its actions (build this here, lay
a road along that) it sends as **requests**: values of types of its own with a small payload
(at most `protocol.MAX_GAME_REQUEST` bytes), declared beside its records
(`Game_Kinds.requests`, named `<id>.<name>`). The client part sends one with
`engine.game_request(s, &value)`; the server decodes it only into a kind that is a request,
checks it (every enum in range, every string within its limit; one that does not decode gets
its client refused) and calls the game's `request` hook, where `core.request_value(s, r, T)`
reads it. `games/hamlet` is the model.

## Testing a game

Each part has its tests beside it, and `./build.sh test games/<game>/server
games/<game>/client` runs them (`./build.sh test` runs every game's with the rest).

**The server part** plays on a stepped server, tick by tick, with the rig of
`server/playtest` (only tests import it):

```odin
@(test)
test_a_round :: proc(t: ^testing.T) {
	rig := new(playtest.Rig) // (the heap: a test thread's stack is small)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {guests = 1}) {return}
	defer playtest.stop(rig)
	testing.expect(t, playtest.until_phase(rig, &state(playtest.srv(rig)).phase, .Playing))
	playtest.kill(rig, playtest.guest(rig), playtest.host(rig))
	playtest.say(rig, "tag restart")
	testing.expect(t, playtest.told(rig, "Tag: a new round"))
	round := playtest.guest_record(rig, tag.Round)
}
```

`start` puts the game in the harness's small flat world (its `configure` changes it as any)
with the host (the harness's mirror client, on the local pipe) welcomed, and `guests` more
players over the harness's network, each playing (`Options`: `listen`, `save_dir` for a
universe kept on disk, `kit`, `seed`, `plain` for guests without the host's role). The
players hold what the game gives (its modes' kits, its configure's) and nothing else; `kit`
names another (the engine's own tests' blocks are `core.HARNESS_KIT`). `step`,
`until`, `until_phase` and `until_seconds` move time; `say` is the host's command (it steps
for it to be done), `told` and `guest_told` what a player was told (a notice reaches a player
a step after the tick that sent it: they step for one still on its way, at most a second), `host_record` and `guest_record` the game's records
as each player holds them, `kill` a player killed through the engine's damage pipeline, and
`srv`, `host`, `guest` reach the server's side to move a player or set what a test needs.
`core.harness_request(s, c, &value)` sends a request as a client would.

**The client part** plays whole with the rig of `client/playtest`: the server part on a
stepped server, a session joining it over the harness's network with the client part
(fetching the game's pack as any pack), a frame each tick, and an App that draws the HUD at
1280x720:

```odin
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, tag_server.GAME, GAME, {name = "runner"}) {return}
	defer playtest.stop(rig)
	playtest.until(rig, proc(rig: ^playtest.Rig) -> bool {return view(rig.s).round.phase == .Playing})
	testing.expect(t, playtest.drawn(rig, "TAG  "))                     // the HUD drew it
	testing.expect(t, playtest.drawn(rig, "Tag: round", scores = true)) // the scoreboard
	testing.expect(t, playtest.drawn_within(rig, 336))                  // kept below F3
```

Its `Options` are the player's `name`, `seed`, `view_radius`, `everyone_cheats`, `ui` and
`kit`, as the server rig's. `rig.input` and `rig.actions` are the keys and pointer a test presses (a game action:
`rig.actions.pressed += {.Game_1}`); `guest_join` brings a second player; `client` is the
session's player on the server; `Options.ui` draws the HUD every frame for a game whose HUD
is clicked. The game's own debug line is `engine.game_debug_line(s)`, its scoreboard
`engine.game_scoreboard(s)`.

## Screenshots

`./build.sh shot <name> [--game <id>] -- <script>` plays a console script headless on
lavapipe under `xvfb-run` at 1280x720 ([debugging.md](debugging.md)): the script is what
`--exec` takes, its lines separated by `;` (with `--game` the run goes straight into a
scratch world of that game, as without a script, and the script runs there; without it the
title shows, where `singleplayer` starts a world), with `wait_world` (the world is there),
`wait <frames>`, `sleep <seconds>`, any console command (`/tp x y z yaw pitch`, `/<game>
...` for the game's own, `hold <item>`, `key <key> down|up`, `pointer <x> <y>`, `set
<variable> <value>`) and `screenshot <file>`, which writes `build/screenshots/<file>.png`; it
ends with `quit`. A game's screenshot, with the round where it should be:

```sh
./build.sh shot flood_water --game flood -- "wait_world; /flood rule baseline; sleep 20; screenshot flood_water; quit"
./build.sh shot horde_shop --game horde -- "wait_world; sleep 4; /horde restart; sleep 2; /horde purse 60; /tp 15 1 18.5 -90 -12; key z down; wait 2; key z up; sleep 0.8; screenshot horde_shop; quit"
./build.sh shot launcher -- "wait 60; screenshot launcher; quit"
```

A UI button is clicked as the mouse would: `pointer <x> <y>` over it, then `key mouse_left
down; wait 2; key mouse_left up` (a mouse key is the mouse's own button where the pointer is:
in the world, the attack). Look at
each picture before saying what it shows.

## The rules

- A game's folder is its whole: nothing outside `games/<game>/` changes for it, and its
  commits touch only its folder. What it needs of the engine is an engine commit of its own,
  first, with its docs.
- It calls only what the list above holds (and `server:play`, `client:engine`, `client:ui`,
  `common:`), never writes a world's rules but through `game_rule`, keeps no globals, uses no
  clock or unseeded randomness in its server part.
- Its rules, commands and records are documented in its README; its server part's rules are
  tested on the stepped harness (with a second player where it is for several), its client
  part's HUD by the client rig.
- Its ideas may come from anywhere; its code is its own. A game is original, never a
  recreation of an existing title.
