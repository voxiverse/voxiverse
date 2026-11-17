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
what it is. Singleplayer lists the games by them ([Singleplayer](#singleplayer)); the
description is one line in its small text, at most `screen.TITLE_WIDTH` wide (a
`client/main` test measures every game's). `core.Game` and `engine.Game` hold it by
`using`, so `g.id` reads as a field of either.

No file lists the games. The build driver writes two before every `odin` it runs, from the
folders in `games/` (the collection `generated` is `build/generated`): `generated:games`,
whose `SERVER` holds every server part's `GAME`, and `generated:games/client`, whose
`CLIENT` holds every client part's. Both are sorted by folder, an `#assert` keeps each
game's id its folder's name, and only the executables' main packages import them
(`client/main` the client's list alone, so the dedicated server links no client code), and
the trace tools the server's.

## Starting one

`./build.sh new-game <id>` stamps out the smallest working game in `games/<id>/`, the shape
above with one rule: its shared package (`INFO`, a record `Points`, a text table), its
server part (a `start` hook, and `block_changed` scoring a point for each block a player
breaks), its client part (a line of HUD with the points, a `LOOK` whose fields are all
commented out: the sandbox's look, [below](#a-games-look), and a commented `seen` hook
using the [feel](#feel) kit), a test beside each and a README;
the name players read is the id's words capitalised (`ice_race`: "Ice Race"). Its files
are known to git (`git add --intent-to-add`), so right after it `./build.sh check` and
`./build.sh test games/<id> games/<id>/server games/<id>/client` pass and `./build.sh run --
--game <id>` plays it. It refuses an id that is not a game's (singular snake_case, at most
`game.MAX_GAME_ID`), one that is an Odin keyword or a package its parts import (`game`,
`core`, `engine`...), and one whose folder is there. The files are
`tools/build/game_template/`'s. Then make the rule the game's own, and its README.

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
| `machines(s, w, kind, at)` | Every tick, the game's machines of world `w` whose time has come (`machine_wake`), one call per block type (`kind`), lowest position first ([machines](#machines)) | the server's |
| `machine_use(s, c, at) -> string` | A player uses (right-clicks) one of the game's machines within its reach: the game opens its panel (an event to the player's client part) and says `""`, or refuses (the player is told the text) | the server's |
| `stop(s)` | After the last tick, before the last save; only after a `start` that succeeded | the caller's |
| `world_opened(s, w)` | A world is open: the home world right after `start` (and `load`), any other as it loads (a player travels there), its entities loaded. The game makes what it keeps of it: its `world_state`, its files read back (`world_file_read`) | the caller's for the home world, else the server's |
| `world_save(s, w)` | A save captures world `w` at this tick (with the universe, or `w` alone as it unloads): the game stages its files (`world_file_write`), in the same transaction | as `save` |
| `world_closed(s, w)` | A world closes (unloaded when nobody has been in it for a while, or the session stopping), after its last save: the game frees what it made of it | the server's, or the caller's at `stop` |
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

Each name's signature and doc, from this table and the kits' below, is in
[engine-map.md](engine-map.md), which the driver writes from them and the source
(`./build.sh engine-map`); `check` fails while it is stale or a name it lists has no doc
comment. Read it first; this file says how the names fit together.

| Name | What it is for |
|---|---|
| `Game`, `Config`, `Server`, `Client`, `World`, `Harm`, `Entity_Harm`, `Harming`, `Dead_Entity`, `Block_Change`, `Pickup`, `Request` | The game itself, the config `configure` changes, the session, a player, a world, and what its hooks are told |
| `game_state(s, T)`, `game_client_state(s, c, T)`, `world_state(w, T)`, `character_data(s, c, T)`, `entity_data(w, h, T)` | The game's state, for the session, for a seat and for a world; its record on a player's character and on an entity of its kinds ([below](#the-games-state)) |
| `World_File`, `world_file_read(w, name)`, `world_file_write(w, name, data)`, `world_file_aside(w, name)` | The files it keeps with each world (`Game.world_files`): read one back as saved (false: none), stage one in the save being made (its `world_save` hook), move a damaged one aside ([below](#the-games-state)) |
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
| `entity_id(w, h)`, `entity_kind(w, h)`, `entity_pos(w, h)`, `entity_health_of(w, h)`, `entity_max_health(w, h)`, `entity_set_max_health(w, h, health)`, `entity_heal(w, h, amount)` | What an entity is, where it stands, its health; its most health set (and its health with it); its health raised, up to its most (a building put up, a wound closing) |
| `entity_show(w, h, look, on)` | Show or hide a look of the entity's kind (its pack's `looks`, by name: shorn, young, a colour): told to the players who know it and drawn as the kind's model says ([packs.md](packs.md)), kept with the entity; false for a look the kind has not |
| `entity_known(c, id)` | Whether a player has been told of an entity (it is near it): a record of the game's keyed by the entity (`protocol.key_entity(id)`) goes to the players who know it |
| `entity_harm(w, h, harm)` | Hurt an entity (a tower's shot: `kind = .Game`, `by` the player it is credited to), told to the hooks as any harm is; true: it died |
| `entity_go(w, h, target)`, `entity_follow(w, h, route)`, `entity_stand(w, h)`, `entity_arrived(w, h)`, `entity_set_speed(w, h, speed)` | Steer a walker whose kind is `"brain": "steered"`: to a point by its own path, along a route, or still; whether it is there ([walkers](#walkers)) |
| `entity_keep(w, h, target, near, far)`, `entity_sees(w, h, p)` | Keep a walker within a band of distances from a point, facing it (chase: `0, reach`; keep distance; flee); whether nothing solid lies between its eyes and a point |
| `entity_strike(w, h, target)`, `entity_shoot(w, h, p)` | A creature's attack, its kind's `attack` data: a blow at a player or entity within its reach, or its shot at a point, each when its cooldown allows, credited to it |
| `entity_glide(w, h, points)` | Send a steered walker along points in straight legs, with no physics, at a fraction of a walker's cost (a town's citizens on its roads); `entity_arrived` at the last |
| `MAX_TEAMS`, `client_set_team(c, team)`, `client_team(c)`, `entity_set_team(w, h, team)`, `entity_team(w, h)`, `entity_set_vision(w, h, blocks)`, `entity_vision(w, h)`, `world_fog(w, on)`, `team_sees(w, team, p)` | Sides ([below](#sides)): a player's and an entity's team (0: none; no harm passes between two of a team, and a kind's `team<n>` look shows its team's colour), how far an entity sees for its team, and a world whose players on a team are told only of the entities their team sees |
| `Machines`, `machine_data(w, p, T)`, `machine_slots(w, p)`, `machine_kind(w, p)`, `machine_wake(w, p, ticks)`, `machine_sleep(w, p)`, `machine_show(w, p, &value)`, `items_made(s, w, item, count)`, `items_used(s, w, item, count)` | Machines ([below](#machines)): the game's record on one, its inventory, its block type, when it thinks next, what players are shown of it; what its machines make and use up, booked in the item ledger |
| `belt_put(w, p, item)`, `belt_take(w, p)`, `belt_peek(w, p)` | Belts ([below](#belts)): an item onto a belt's start (false: no room), the front item off it, what it carries |
| `grid_open(w, kinds)`, `grid_parts(w, g)`, `grid_part_at(w, g, p)`, `grid_node(w, g, p)` | Networks over blocks ([below](#grids)): a grid of the kinds given (`grid.Kind`s of `server:grid`), its parts, which part a block is in, whether it is a machine of it |
| `route_make(w, area, start, goal, kind)`, `route_free(w, r)`, `Route_Handle`, `route_cost(w, r, p)`, `route_reaches(w, r, p)`, `route_would_shut(w, r, p, block)` | A way to one goal over an area that every walker following it shares; what it costs from a block, whether there is one, whether a block placed there would shut it |

The fields a game reads: `Server`'s `tick`, `clients`, `home`, `worlds`, `config`,
`registry`, `sim_speed`, `sim_steps` and `listening` (others can join: opened to the LAN, or
a dedicated server); `Client`'s `state`, `world`, `player` (its position, velocity, flying),
`dead`, `mode` and `inventory`; `World`'s `rules`, `clock`, `address` (which world it is, a
`starmap.Address`: Earth's is the same in every universe), `seed` (its terrain's, from the
universe's) and `params` (its generator's parameters: `params.planet` is 1 for a world built on
the planet model). What a game knows of the planet beyond them is `common:`'s, called
directly: where a block is on it (`worldgen.planet_lat_lon(x, z)`), the model with its
relief and climate (`worldgen.planet_model()`, sampled by `planet.planet_climate_at`; the
Köppen class of a column, `worldgen.planet_climate(x, z)`). What it writes of the engine's
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
| `Routes`, `routes_get(s, w, &routes, goal, kind)`, `routes_free(w, &routes)`, `SQUAD_ROUTES` | Routes to goals over the game's map, one per goal shared by every order to it (one search for a whole army), the least recently used let go when the cache or the world (`core.MAX_ROUTES`) is full |
| `formation(s, w, goal, n, spacing)`, `formation_assign(w, units, places)`, `march(w, h, place, route)`, `place_point(p)`, `standable(s, w, p)`, `ground_at(s, w, x, y, z)` | A group ordered to one point: a place each around it on ground a walker stands on, the nearest walker given the nearest place, and each tick's step there (the shared route while far, its own short path for the last `MARCH_NEAR` blocks): a hundred arrive around the point, not on it |
| `foe_nearest(w, h, radius)`, `fight(w, h, foe, reach)` | A fighter's mind: the nearest living entity of another team within its sight ([sides](#sides)), kept within reach of and struck as its kind's attack allows; acquiring, attack-moving and holding are when the game calls them (`./build.sh bench budgets`: 300 soldiers fighting under fog, `battle_tick`) |
| `By_Name(T, N)`, `Named(T)`, `by_name(&t, name, make_it)`, `by_name_rows`, `named_name`, `by_name_save(&t, key, out, write)`, `by_name_read(&t, key, line, read)` | What a game keeps of each player by name across sessions (a racer's best, a hero's level, a commander's wins): rows of the game's own record found or made by name, kept as `<key> = <numbers> <name>` lines in `game.cfg` and read back from the lines `settings_read` hands it, the game saying how its numbers are written and judged |
| `Saved_Line`, `saved_lines(text)`, `settings_read(table, &settings, text) -> (own, ok)` | What a game keeps with the universe (`game.cfg`) read as lines of a key and the rest (`best = 12`, `hero 3 140 7 ana`); `settings_read` reads the settings' lines and hands the game the others, in order |

A seeded layout is a template made in code: `game.template_make(size)`, then
`game.template_fill(&t, lo, hi, block)` for each box (clipped to the template), pasted by
`arena_build` (or `bulk_edit`'s `.Paste`).

### Sides

A real-time strategy's armies, a team match's players: sides are the engine's
(`server/core/sides.odin`). A player and an entity are on a team, 1 to `MAX_TEAMS`, or on
none (0) until the game says (`client_set_team`, `entity_set_team`; not saved: a game whose
sides outlive a restart sets them again from its records). Where the engine decides alone
it keeps them apart: no blow, shot or blast passes between two of a team (before the game's
`harming` hook is asked), and an entity whose kind has a look named `team1`..`team8` shows
its team's and hides the others', so an army's colours are its kinds' data. In a world with
fog (`world_fog(w, true)`), a player on a team is told of its own side's entities wherever
they stand and of any other entity only while one of its own sees it (`entity_set_vision`:
blocks around it, horizontally; `team_sees` asks the same of a point), and of another
side's player (its place, its swings, its shots) by the same rule. A player on no team in a
world with fog is on no side and sees for none: it is told only of what is on no team near
it (neutral creatures, dropped stacks, players on no team), so a watcher between matches
learns nothing a side has. Nothing its side does not see reaches its client, so the fog is
the server's, not a picture drawn over what was sent. (Blocks are not fogged: a chunk goes
to whoever is near it.) Its client knows each entity's team and vision from its record
(`engine.Other_Entity`'s `team` and `vision`), from which it draws its own fog.

### Machines

A block of the game's pack declared `"entity": {"kind": "machine", "slots": n}` is a
machine (`server/core/machines.odin`): a furnace, a conveyor's motor, a tower that fires. It
keeps, with its chunk and through every save, the game's record on it (`Game.machine_data`, a
plain type of at most `game.MAX_MACHINE_DATA` bytes, `machine_data(w, p, T)`; zero when it is
built), what players are shown of it (`Game.machine_shown`, at most `game.MAX_MACHINE_SHOWN`
bytes, set by `machine_show`: sent when it changes to every player who has its chunk, and with
the chunk to those who get it later; the client part reads it with `engine.machine_shown(s,
p, T)`), its first `n` slots (`machine_slots`: its inventory, in the item ledger as a chest's,
spilled when it is broken) and when it thinks next. Building and breaking one is a block edit
like any (the journal keeps a broken one's value for undo).

**Away from players.** A factory works wherever its players are: a chunk holding a machine
or a belt (a working chunk) stays loaded, and so simulated, with nobody near, and the world
remembers which chunks they are (`world.cfg`), so after a restart they load and work again
before anyone comes. The budget is `core.MAX_WORKING_CHUNKS` (512) a world, the lowest by
position; a working chunk past it works only while a player is near and pauses when none is
(its machines think on, as due, when it loads again: nothing is caught up). That is the
honest minimum: the same rules run, so nothing differs between a factory watched and one
left, at the cost of keeping its chunks in memory; catching up on load from elapsed time
would need every game to model its production twice. (A world other than the home world
still closes when nobody has been in it for a while, its factory with it.)

A machine sleeps until woken: `machine_wake(w, p, ticks)` has it think once, that many ticks
on (the earlier of two wakes stands), and each tick the game's `machines` hook is given every
machine whose time has come, one call per block type, lowest position first, so tens of
thousands of machines cost what the due ones cost, not a scan of all. The time is the server's
age (its persistent tick), so a machine thinks on after a restart where it left off. What a
machine makes or uses up is booked with `items_made` and `items_used`.

What a machine makes is pack data both parts read, a recipe of `"type": "process"`
(`data/recipes`): its `inputs` (items or `#tags` with counts, at most
`game.MAX_PROCESS_INPUTS` in all), its `output`, the `time` it takes in seconds and the
`machine` that makes it, a name of the game's own (`"foundry:furnace"`; the engine reads
nothing into it). `game.recipe_by_id`, `game.recipe_needs` (the inputs as one stack an item)
and the registry's `recipes` (both sides' `s.registry` / `s.reg`) are what a game's machines
and its panels read; the crafting grid never matches a process.

### Belts

A block declared `"entity": {"kind": "belt", "speed": 1.5}` (blocks a second, at most 7.5,
with a `facing` property; `"place": "facing"` turns it the way its builder looks) is a
conveyor (`common/game/belt.odin`, `server/core/belts.odin`): it carries up to four items
the way it faces, each a quarter of a block behind the one in front, in the order they came,
and hands its front item to the belt it faces when that one has room at its start (a corner
is a belt facing another way); with no belt in front, or none with room, the item waits at
its end. The game puts items on (`belt_put`: a mine's output, an arm's drop) and takes them
off (`belt_take`: an arm feeding a furnace); `belt_peek` reads what one carries. Items in
transit are no entities: only the belts on which something moves are stepped, and players
are told a belt's items with its chunk and when one is put on or taken off, never as they
only move: the client steps its copy of the belts with the same code, and draws each item as
a cube of its colour riding the belt (at half a block: a belt is a slab). What belts carry is
in the item ledger and spills when one is broken. (`./build.sh bench budgets`: 20 000 items
on 8 560 belts with 5 000 machines, `the factory`.)

### Grids

A power line or a pipe is a grid (`server/grid`, `server/core/grids.odin`): the game opens one
in a world (`grid_open(w, kinds)`, in its `world_opened`) naming the block types it is made of,
each a `grid.Kind`: a conductor that joins what touches its faces (`reach` 0: a cable) or what
lies within `reach` blocks each way (at most `grid.MAX_REACH`: a pole), or a `node` (a machine)
that joins any conductor reaching it and never another node. The server keeps its connected
parts as blocks change, a block at a time (one added joins the parts it touches; one removed
splits its part only where it held it together), and as saved chunks come and go; the game
reads the parts (`grid_parts`: each a number, kept while a part only grows, and its members)
to balance what its generators give against what its machines ask. Grids are not saved: they
are found again from the blocks.

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
engine then carries out (the engine has no creature's mind of its own: `games/sandbox`'s
sheep are the model). What it decides from is the game's record on each (`entity_data`)
and what it asks the world.

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
| `actions` | The names of the game's own actions, at most `game.MAX_GAME_ACTIONS`: the keys of `Game_1`.. (Z, X, B until the player binds others) press them, the server part's `action` hook hears them; `game_action_key(s, i)` names the key the player bound to one ("Z") for the HUD to say, and `game_action_pressed(s, i)` says it was pressed this frame, over the world or the game's own screen (the key that opened a screen may close it) |
| `keys` | The client part's own keys beyond its actions, at most `MAX_GAME_KEYS` (`engine.Game_Key`: a name and its default key): a command panel's hotkeys, control groups on the number keys. Never sent: `game_key_pressed(s, i)` and `game_key_down(s, i)` read them while the world has the keyboard, `game_key_label(s, i)` names the key bound, and the modifiers held are the UI's (`ctx.input.modifiers`) |
| `no_hotbar` | Its players hold no hotbar (a commander, a city's planner): in its world the hotbar's keys and the wheel pick no slot, and the controls do not list them |
| `camera(s) -> Game_Camera` | Every frame: the camera the game wants. `.Player` (the player's own, <kbd>F5</kbd>), `.First`, `.Third`; `.Top_Down` (over the head, `distance` away, `angle` degrees down along `heading`, the world cut `cut` blocks above the feet): the pointer aims (`s.aim`, `s.aim_entity`, `s.pointer`), the avatar faces it, the movement keys move across the screen; `.Free` (no avatar, for a mode with `game.Ability.Bodiless`): looks at the player's focus from `distance`, zoomed between `near` and `far`, panned by the movement keys, the screen's edge and the middle button; `pointer_tool(s)` says what the pointer is over and each button's press, drag and release |
| `look` | Its atmosphere, as data: the sky, the fog, the light and the picture's colour its world is drawn in ([below](#a-games-look)); zero: the engine's own |
| `screen(s, ctx, top)` | Every frame while the game's screen is open: a panel of its own over the world (a town's market, a shop) drawn with the UI kit (`top`: it has the focus). The game opens it with `game_screen_open(s)` (from a record, an event, its action's answer) and closes it with `game_screen_close(s)`; the player closes it as any screen over the world, Escape or the pad's Back, and it closes with the world. While open it takes the keyboard, the pointer and the pad's navigation (the world runs on); `game_screen_shown(s)` says whether it is open |
| `seen(s, e)` | The engine showed something worth feeling, as the server told it: an entity hurt (`Seen_Hurt`: its id, kind, the middle of its box and the health it lost) or dead (`Seen_Death`: what it had left), the player hurt (`Seen_Harm`) or healed (`Seen_Heal`: not a respawn), its shot hitting another player (`Seen_Hit`), a blast (`Seen_Blast`: `blast_shake` says how hard it shakes a view at a distance). The game gives it its own feedback ([feel](#feel)); what the engine shows of each already (a red flash, a puff, the hit marker, the damage arc) it shows anyway |

**Its keys.** While a game plays, the controls (Options > Controls) list its actions and its
keys under its name, each rebindable as the engine's are; what the player binds is kept for
that game alone (`engine.Game_Binds`: `keys/<game>.cfg` beside the settings file, a
`<name> = <key>` line each), so two games may put different things on Z. A key goes to one
consumer: in the world a key bound to one of the game's actions or keys is the game's alone,
and an engine action bound to the same key (a hotbar slot on a digit, the drop key) does not
fire there (`game_owns_key`); the controls frame such a key. Menus are not the world: there
the engine's keys work as ever.

The accessors are typed as the server's are: `engine.game_state(s, T)` checks `T` is the
declared state type, `engine.game_value(s, r, T)` checks the kind, so a hook holds no kind
number and no cast.

### What a game's client part calls

| Name | What it is for |
|---|---|
| `Session`, `game_state(s, T)`, `game_value(s, r, T)` | The session its hooks are given; its state, as its type; a record or event its `received` hook was given, as the type of its kind |
| `game_screen_open(s)`, `game_screen_close(s)`, `game_screen_shown(s)` | Its screen over the world (the `screen` hook): open it, close it, whether it is open |
| `game_action_key(s, i)`, `game_action_pressed(s, i)`, `game_key_pressed(s, i)`, `game_key_down(s, i)`, `game_key_label(s, i)` | Its actions and its own keys: the key bound to an action (for the HUD to say), an action or a key pressed this frame, a key held, the key bound to a key |
| `Game_Key`, `MAX_GAME_KEYS`, `Command_Spec` | What its `keys` and `commands` fields hold |
| `Look`, `Grade` | What its `look` field holds: its atmosphere ([below](#a-games-look)) |
| `Game_Camera`, `Game_Camera_Kind`, `pointer_tool(s)`, `Pointer_Tool`, `Pointer_Press` | The camera its `camera` hook asks for; under a top-down or free camera, what the pointer is over and what each button did |
| `Scoreboard`, `SCOREBOARD_COLUMNS`, `scoreboard_columns(board, ...)`, `scoreboard_row(board, name, ...)` | Filling the player list (the `scoreboard` hook) |

### What a game's HUD is made of

| Name | What it is for |
|---|---|
| `top_bar(ctx, &rest, text)` | A line of status across the top of the screen, on the HUD's backing, cut from `rest` |
| `banner(ctx, at, text, scale, color)` | Big text across the screen with a shadow, its middle `at` pixels from the screen's (laid out for 720 high and shrunk with a smaller screen, as under F3), `scale` times the title's size |
| `Flash`, `flash(&f, s, text, tone, seconds)`, `flash_draw(ctx, &f, s, at, scale)`, `Tone` | A banner that stands a few seconds after the news that brought it (a wave set out, a level gained), kept in the game's view, coloured by its tone (`.Good`, `.Warn`, `.Bad`); it pops in and fades out on the feel clock ([feel](#feel)) |
| `world_point(s, ctx, p)`, `world_label(s, ctx, p, text)`, `world_bar(s, ctx, p, fraction)` | Where a point of the world is on the screen (false behind the eyes or past `MARK_DISTANCE`); a plate of text there; a bar |
| `entity_place(s, id)`, `entity_top(s, id)`, `entity_label(s, ctx, id, text, rows)`, `entity_bar(s, ctx, id)`, `entity_bars(s, ctx, kind)` | Where the session shows an entity, the point over it, a plate of text there (a name the game keeps in a record keyed by the entity), its health bar; a bar over every hurt entity of a kind (in a crowd the most hurt first, a bar that would overlap one drawn left out: what reads is the worst wounds) |
| `world_box(s, lo, hi, color)` | An outline of blocks in the world this frame (a placement's ghost, a footprint) |
| `ground_fill(s, lo, hi, color)`, `ground_outline(s, lo, hi, color)`, `structure_ghost(s, t, at, rotation, color)` | A translucent cover over the tops of a rectangle's columns (a zone, a heat map), its edge on the ground, a template's blocks tinted (what a placement would build), `MAX_FILL_VERTICES` and `MAX_WORLD_LINES` a frame |
| `ground_top(s, x, z, lo, hi)`, `ground_quad(s, a, b, c, d, color)`, `block_colour(s, block)` | The highest solid block of a column as the session holds the world (false: none, or not loaded), a translucent quad of the game's drawn with the ground marks, a block's look in one colour: what a fog over the ground and a minimap are made of |
| `machine_shown(s, p, T)` | What the game's machine at `p` shows, as its type (`Game.machine_shown`, the server part's): nil where the session holds none ([machines](#machines)) |
| `puff_add(s, puff)` | A speck that drifts and fades (a tower's tracer, a blast's smoke), aged on the feel clock ([feel](#feel)) |
| `burst(s, at, kind, color, scale)`, `Burst`, `MAX_BURST_PUFFS` | A handful of puffs flung out of a point as a preset looks (`.Impact`, `.Sparks`, `.Smoke`, `.Sparkle`, `.Death`, `.Splash`), in a colour (zero: the preset's; a material's: `block_colour`), at most `MAX_BURST_PUFFS` alive from every burst ([feel](#feel)) |
| `shake(s, amount, seconds)`, `kick(s, degrees)`, `blast_shake(at, eyes, radius)` | The view shaken (`amount` 0 ..= 1, dying away over `seconds`; shakes add up to a whole one at most) or jolted up by degrees (down below 0) and settling; scaled by the player's Screen shake, none under Reduce motion ([feel](#feel)) |
| `float_text(s, at, text, color, scale)` | A few words over a point of the world (a hit's damage, "+5") that pop, rise a block and fade in under a second, `MAX_FLOATS` at once, the oldest giving way ([feel](#feel)) |
| `pulse(s, color)` | The screen's edges glowing a moment in a colour, its alpha how strong: red for harm taken, green for a heal ([feel](#feel)) |
| `Tween`, `tween_start(&t, s)`, `tween_value(&t, s, seconds, curve)` | A HUD element's moment of easing in, started by its news and read each frame as 0 .. 1 along a `ui.Ease` curve (`ui.ease(curve, fraction)`): a score that pops, a line that slides in; done at once under Reduce motion ([feel](#feel)) |
| `entity_flash(s, id, color)`, `HURT` | An entity drawn in one colour for a moment: `HURT` red as every creature is when hurt, white for a critical blow ([feel](#feel)) |
| `game_request(s, &value)` | Send the server part one of the game's requests ([below](#requests)) |
| `Seats(T)`, `seats_received(s, &seats, r)`, `seat_mine(s, &seats)`, `seats_ranked(&seats, before)` | What the game keeps of each player from a record of its keyed by the player (`key_player`, with a `name`): the last value by seat, its name copied out of the message, forgotten when the server stops putting it; the player's own; the seats told of in order (ties by name), a scoreboard's rows |

### Feel

What happens in a game lands with a little feedback of the client part's: a burst where a
blow lands, a flash on the creature it hit. These are the feel kit's calls
(`client/engine/feel.odin`), each one line from the game's `received` or `hud`, each
presentation alone: nothing is sent, saved or simulated.

What to feel comes from what the client part is told: its records and events (a wave's news,
a purse that grew, a hit's damage a game sends), and the engine's own, which its `seen` hook
hears without the server part repeating them (an entity hurt or dead, with the health it
lost; the player hurt or healed; its shot hitting; a blast).

- `engine.burst(s, at, .Impact, engine.block_colour(s, block))`: chips where a blow lands, in
  a material's colour; `.Sparks`, `.Smoke`, `.Sparkle`, `.Death`, `.Splash` the others.
- `engine.entity_flash(s, id, {255, 255, 255, 255})`: a creature lit white for a moment (a
  critical blow); the engine flashes every hurt one `engine.HURT` itself.
- `engine.shake(s, 0.15, 0.25)`: the view trembles and dies away (0.15 a blow taken, 0.4 a
  blast near); `engine.kick(s, -1.5)`: it dips a degree and a half and settles (a landing,
  a collision; up for a recoil). The player's Options > Accessibility > Screen shake (Off,
  Low, Full) scales both, and Reduce motion stills them: a game never needs to ask.
- `engine.float_text(s, at, "-12", t.log_error)`: a number rising from a creature and
  fading; `engine.pulse(s, {220, 40, 36, 100})`: the screen's edges flushing red a moment
  (green for a heal). The engine draws both over the world, under the game's HUD.
- `engine.tween_start(&v.coins_pop, s)` when the news comes, then in the HUD
  `k := engine.tween_value(&v.coins_pop, s, 0.25, .Out_Back)` and draw it at
  `scale * (0.7 + 0.3 * k)`: it pops instead of appearing. An `engine.Flash` already pops in
  and fades out.

**Restraint.** An effect is short (under a second) and small (a fraction of a block, a few
pieces), and it never hides what the player must see: enemies, pickups, the path. Bursts
share a budget (`MAX_BURST_PUFFS` alive of the `MAX_PUFFS` every effect has) and a burst past
it makes fewer pieces or none, so a game calls them freely and the frame does not pay. The
effects sit inside the game's look ([below](#a-games-look)): a dark game's sparks are not a
noon's, and a calm game's are few.

Every effect is timed by the **feel clock** (`Feel.clock`), which runs with the frames but
follows the server's ticks as they are heard (never more than `FEEL_LEAD` ahead of the newest,
nor `FEEL_LAG` behind): a paused world holds its effects, and a screenshot's `ticks <n>`
finds an effect as far through as the ticks put it, to within a tick or two, however long
lavapipe's frames took ([screenshots](#screenshots)).

### Commanding from above: `client:overview`

What a strategy game's client part (a city builder's, a tower defence's) needs to see and
command its side from above is `client/overview`, built on the calls above:

| Name | What it is for |
|---|---|
| `Selection`, `selection_update(&sel, s, ctx, team)`, `selection_draw(&sel, ctx)`, `selected(&sel)`, `is_selected`, `selection_add`, `selection_remove`, `selection_clear`, `selection_prune` | The entities of the player's side it has picked with the free pointer: a click picks one (Shift adds or takes away), a click on nothing clears, a double click picks every one of that kind on the screen, a drag picks every one in the box drawn; those the session no longer knows (dead, out of sight) fall out. Kept in the game's state, sent to its server part only as the ids of its orders (requests of a fixed array of ids and a count, several when there are more than one request holds) |
| `group_keep(&sel, n)`, `group_pick(&sel, n)`, `MAX_GROUPS` | Control groups: the picked set kept under a number (the game's keys, Ctrl and a digit) and picked again by it |
| `small_marks(s, ctx, min_pixels, colors)` | A square of its team's colour over every unit drawn shorter than `min_pixels` (a soldier at the overview's height), so far units read as units, not specks |
| `rings_draw(&sel, s, radius, color)`, `ring_draw(s, id, radius, color)` | A ring on the ground under each picked entity, eight lines each |
| `Fog`, `fog_init(&f, lo, hi, y_lo, y_hi)`, `fog_update(&f, s, team)`, `fog_draw(&f, s, unseen, unexplored)`, `fog_sees`, `fog_explored` | The fog of war as the side sees it ([sides](#sides)): from its entities' vision, the map's cells it sees now and has ever seen; the rest darkened on the ground, a quad a cell |
| `Minimap`, `Mark`, `minimap_init`, `minimap_ground(&m, s)`, `minimap_draw(&m, s, ctx, r, &fog, marks, unseen, unexplored) -> (at, pointed)`, `minimap_jump(s, at, height)` | The map from above in a corner: its ground in its blocks' colours (read a few rows a frame), the fog over it, the game's marks, the camera's focus framed; pressed, the point of the map the pointer is on (the game jumps its camera there, or sends its units) |

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
table of the same keys beside it. `games/flood` is the model; every game's HUD speaks from its
table, while the server's notices and announcements are still English in place.

## A game's look

Each game has an air of its own: Delve's dungeon dark and close, Rally's midday bright and
far, Horde's night cold, Flood's sky overcast. The sandbox declares none. A game's
client part declares it once, as data, in `engine.Game.look` (an `engine.Look`, which is
`render.Look`), beside its camera and its HUD:

```odin
// games/horde/client/game.odin: a moonlit night that never ends
LOOK :: engine.Look {
	time         = 0.02, // just past midnight, always
	zenith       = {0.008, 0.012, 0.03},
	horizon      = {0.03, 0.045, 0.085}, // the fog's colour too
	sun_light    = {0.32, 0.38, 0.58}, // a moon bright enough to aim by
	figure_light = {0.42, 0.44, 0.52}, // the creatures read in the dark
	fog          = 64,
	fog_near     = 0.15,
	grade        = {tint = {0.88, 0.95, 1.10}, saturation = -0.3, contrast = 0.08, vignette = 0.35},
}
GAME :: engine.Game{info = horde.INFO, ..., look = LOOK}
```

Every field's zero is the engine's own, so a game names only what it changes, and a game
that declares nothing is drawn as the sandbox is. A look moves colour and atmosphere, never
the art: the textures, the materials, the UI and the lighting model are every game's.

| Field | What it sets (zero: the engine's) |
|---|---|
| `time` | A time of day that stands, `0 < time <= 1` (0.25 sunrise, 0.5 noon, 0.75 sunset, 1 midnight): the sun, the moon, the stars and the light follow it. The server's clock still runs (its spawns, its growth); only the picture stands. Zero: the world's clock |
| `zenith`, `horizon` | The sky overhead and at the horizon (linear rgb), at every hour. The fog fades into the sky, so `horizon` is the fog's colour too |
| `sun_light` | What full sky light looks like on blocks and figures (white at noon, blue at night) |
| `lamp_light` | What full block light looks like: lamps, magma, a glowing stone (`render.LAMP_LIGHT`, warm) |
| `ambient` | Light added everywhere, the dark included: a cave's cold air |
| `figure_light` | The least light creatures, players and items are drawn in (`render.FIGURE_LIGHT`): figures take no block light, so a dark look raises it to keep them seen |
| `fog`, `fog_near` | The distance (horizontal, in blocks) at which the fog is whole, at most the view's edge, and where it begins, a fraction of it (`render.FOG_NEAR`, 0.6). Blocks, figures and water all fade into the sky's colour by it |
| `no_clouds`, `no_sun` | No clouds (whatever the player's setting); no sun, moon or stars drawn |
| `grade` | The finished picture's colour (`engine.Grade`): `tint` (multiplies; zero: white), `saturation` and `contrast` (-1 .. 0 as it is .. 1) and a `vignette` (0 .. 1, the corners darker). The world, its figures, the hand and the sky are graded as each is drawn; the HUD never is |

Readability comes first: enemies, pickups, paths and the player must stay easy to see in a
look. Take the game's screenshot at 1280x720 ([below](#screenshots)) before and after, and
when a figure sinks into the dark or the fog, raise `figure_light` or push the fog back
before darkening further. A look is the client's presentation of the game the server names:
it is not sent, saved or part of the schema, so changing one changes no protocol.

## Which game a session plays

The server names its game in the handshake: `Welcome.game` (its id; never empty). The client
looks for the client part of that id among the games it has (`App.games`); with it, the
session's schema gains the game's kinds, its state is made and `Welcome.schema` must match
(else the session fails: "the server runs a different version (its state schema is not
ours)"). A client without that game fails the session before playing with "the server plays
<id>, a game this version does not have"; nothing is half-applied.

A world of our own plays the game `voxiverse --game <id>` names (default: `sandbox`), but a
saved universe plays the game it records (`universe.cfg`'s `game`, [saves.md](saves.md)): the
game's page and the `universe` command open it with that game, and a universe of a game
this build lacks is not opened. The client starts its embedded server with that game's
server part (`App.server_games`). The dedicated server runs one with `voxiverse-server --game
<id>`.

### Singleplayer

The title has no games of its own: its Singleplayer lists the games the client was built
with (`screen.singleplayer_games`: the default first, the rest by folder), each its name,
its description and how many saves it has, in a list that scrolls (`ui.list_begin`). Each
game is self-contained: choosing one opens its page (`client/screen/universes.odin`), its
name and description over its saves and no other game's. New is at the top: sandbox's opens
the universe creation screen, another game's asks a name and makes a save of it on the
scratch world's seed (`screen.save_create`, the world the game is made on). A game whose
server part keeps nothing between runs (`engine.game_keeps`: no `save`, `world_save`,
`character_data` or `machine_data`; Flood) has Play instead, which starts a scratch world
playing it (`App.launch`, `engine.play_game`), the same path as `--game <id>`. `--game <id>`
with no `--exec`, `--scene`, `--check` or `--benchmark` skips the title and goes straight
into that world. A new game appears in the list with nothing more to do. The title's splash
may carry a game's flavour: `assets/splashes.txt`'s `[game <id>]` section, whose lines join
the everyday ones; `check` refuses a section naming a game with no folder in `games/`.

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

- `character_data`: a record on each player's character, zero for a character new to the
  universe: `core.character_data(s, c, T)`. A plain record as `entity_data` is (numbers,
  booleans, enums, bit sets, fixed arrays and structs of them; at most
  `game.MAX_CHARACTER_DATA`, 4096 bytes: a trader's purse and the prices it remembers). It
  stays with the character when it leaves (`client_state` does not: that is the seat's) and is
  saved in its file, field by field by name (`"game": {"cash": 20, "seen.0.cell": 82623}`,
  only those not zero: [saves.md](saves.md)), so a field added later reads as zero and one
  dropped is skipped and logged. What it reads from the file is what was written: the game
  judges the values it relies on.
- `world_state`: one per world, zero when the world opens (before `world_opened`), in the
  world's memory and freed with it: `core.world_state(w, T)`. What the game makes of a world
  beyond it (a model it builds, a thread it starts) it makes in `world_opened` and frees in
  `world_closed`.
- `world_files`: the files it keeps in each world's directory, `[]core.World_File{{name =
  "economy.vxe"}}`, saved as `<game>.<name>` (`sandbox.economy.vxe`) beside the world's own
  ([saves.md](saves.md)). Its `world_save` hook stages them (`core.world_file_write(w, name,
  bytes)`, in the save's transaction: written whole with the rest or not at all), its
  `world_opened` reads them back (`core.world_file_read(w, name)`); one it cannot read it moves
  aside (`core.world_file_aside`: `<file>.bad`, logged) and goes on without it. A world not
  saved (a scratch world) keeps none. A file's `check` (`proc(data) -> bool`, optional) says
whether it reads as the game would read it: `voxiverse-server --check` asks it of each world's
file when the universe plays the game ([saves.md](saves.md)). `start` refuses a name that is not 1 to 32 bytes of
  `a-z`, `0-9`, `_` and `.`, or one named twice.

- `machine_data`, `machine_shown`: its record on each of its machines and what they show
  ([machines](#machines)): plain types, as `entity_data`'s, saved with the chunk as bytes (a
  game that changes its record's layout reads its old records as the new type: it keeps the
  layout, or a version field of its own).

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
Both decode blocks and items by the base pack and the game's pack (`trace_registry`), so a
game's blocks and items in a trace read by their names (a game this build lacks: the base
pack's alone; a pack the session took from its universe is not in the trace).

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
`engine.game_scoreboard(s)`. `drawn` draws the game's screen too while it is open, over the
HUD, as the client does.

## Screenshots

`./build.sh shot <name> [--game <id>] -- <script>` plays a console script headless on
lavapipe under `xvfb-run` at 1280x720 ([debugging.md](debugging.md)): the script is what
`--exec` takes, its lines separated by `;` (with `--game` the run goes straight into a
scratch world of that game, as without a script, and the script runs there; without it the
title shows, where `singleplayer` starts a world), with `wait_world` (the world is there and
meshed), `ticks <n>` (the server runs n ticks, as fast as it can, and the session hears
them: the game played on to where the picture is, its effects as far through as the ticks
put them), `wait <frames>`, `sleep <seconds>` (the clock's time, for a fade; play is
`ticks`), any console command (`camera at x y z yaw pitch` for the camera, `/tp x y z yaw
pitch` for the player, `/<game> ...` for the game's own, `hold <item>`, `key <key>
down|up`, `pointer <x> <y>`, `type <text>` into the field that has the focus, `set
<variable> <value>`, `universe --earth <name>` for a
universe on Earth, kept with the run's state, not the player's saves) and `screenshot
<file>`, which writes `build/screenshots/<file>.png`; it ends with `quit`.

Time a script by ticks, not seconds: at `game.TICK_RATE` (30) a second of play is 30 ticks,
and `ticks` waits for exactly those, however slow lavapipe draws, so a run takes what its
ticks cost to simulate rather than a guess of the clock. Put the camera where the picture is
with `camera at` (a development build's, as a shot is): it stands there whatever the
game's camera (top-down, free) and whatever the player may do (one who cannot fly needs no
pillar), and the player stays where it is. The world drawn is the session's, the chunks
within the view radius (12 chunks in a shot) of the player: for a place farther off, `/tp`
the player nearer first. The pointer is the window's middle until `pointer` moves it, so a
top-down or free camera neither aims at a corner nor pans at an edge. A game's screenshot,
with the game where it should be:

```sh
# Foundry's demo line, twenty seconds after it is built, from above and south of it.
./build.sh shot foundry_line --game foundry -- "wait_world; /foundry demo; ticks 600; camera at 56.5 5 50 0 -30; wait_world; screenshot foundry_line; quit"
./build.sh shot horde_shop --game horde -- "wait_world; ticks 80; /horde restart; ticks 40; /horde purse 60; /tp 15 1 18.5 -90 -12; key z down; wait 2; key z up; sleep 0.8; screenshot horde_shop; quit"
./build.sh shot launcher -- "wait 60; screenshot launcher; quit"
```

The first takes about 10 seconds when the client is already built (`fresh` in its output:
nothing it is built from changed since), most of it the client starting on lavapipe; the
`wait_world` after `ticks` lets the chunks the ticks changed mesh before the picture.

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
