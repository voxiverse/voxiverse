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
| `hurt(s, c, harm)` | A player was hurt and lives (its health already less): `harm` is a `core.Harm`, the amount, the kind of source (`game.Source_Kind`: a fall, an explosion, a weapon...), `by` the player who did it (the one hurt, for its own rocket; nil for nobody) and the weapon's name for a shot | the server's |
| `died(s, c, harm)` | A player died of `harm`, after the engine's death: the line told, `kills` and `deaths` counted, its things dropped (by its mode and the world's rules) | the server's |
| `respawned(s, c)` | A dead player stands again, after the engine stood it at the world's spawn with full health and its mode's kit: the game may move it (`teleport`) and change what it holds. Also for a dead player who leaves, after `left` | the server's |
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
| `Game`, `Config`, `Server`, `Client`, `World`, `Mode_Result`, `Harm` | The game itself, the config `configure` changes, the session, a player, a world, what hurt a player (its hooks') |
| `game_state(s, T)`, `game_client_state(s, c, T)` | The game's state, for the session and for a seat |
| `game_put(s, c, &value)`, `game_event(s, c, &value)` | Its records and events ([below](#records-and-events)) |
| `notice(s, c, text)`, `announce(s, text)` | Tell one player; tell every player in the chat |
| `client_name(c)`, `allowed(s, c, node)` | A player's name; whether it holds a permission |
| `teleport(s, c, position, look, flying)` | Move a player in its world (standing where it fits once the blocks are there, or flying) |
| `game_mode(s, c, id)` | Put a player in a mode by id (a pack's too: `flood:out`); journalled as the game's |
| `kit_give(s, c)` | Give a player what its mode's kit has that it lacks, weapons full |
| `hotbar_select(s, c, slot)` | Put a hotbar slot (0 ..< `game.HOTBAR_SLOTS`) in a player's hand, as if it chose it; false for a slot out of range |
| `head_in_water(s, c)` | A player's eyes are in water |
| `game_rule(s, w, name, value)` | Change a world's rule (`explosion_size`, as the `rule` command names it; the value as text), journalled as the game's and told to the world's players |
| `world_keep(w, area)`, `world_ready(w, area)`, `world_release(w)` | Keep an area loaded with nobody near; whether all of it is there; let it go |
| `block_at(w, p)` | Read a block (false: not loaded) |
| `game_act(s, w, system)`, `Act` | A cause for the game's block changes, its actor the game: one per cause |
| `set_block(w, p, block, act)`, `bulk_edit(w, edit, act)`, `Bulk_Edit`, `Box`, `Sphere` | Change blocks through the edit journal ([journal.md](journal.md)) |

The fields a game reads: `Server`'s `tick`, `clients`, `home`, `worlds`, `config` and
`registry`; `Client`'s `state`, `world`, `player` (its position, velocity, flying), `mode`
and `inventory`; `World`'s `rules` and `clock`. What it writes of the engine's state is, in
`start`, a world's clock; everything else goes through the list. A world's rules change
through `game_rule` (`core.game_rule(s, w, "explosion_size", "1.75")`), never by assignment:
the `import` lint refuses `w.rules.<name> = ...` in a game's code, as it refuses a name the
list lacks.

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
Quit. The mouse, the keyboard and a pad move through it as through the rest of the menu (the
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
`died`, `respawned`), its record kept with the universe (`save`, `load`), a client part with its state,
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

`build schema` writes the engine's kinds into the Wireshark dissector; a game's kinds are not
in it. `build netdump` decodes with the engine's schema alone: in a trace of a session with a
game, a State message that carries the game's records counts as one that does not decode.
