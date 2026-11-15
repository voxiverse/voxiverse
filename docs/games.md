# Games

The engine (`client/`, `common/`, `server/`) runs worlds; a **game** is the rules played in
one: a round, a goal, a score. Each game is native Odin in its own folder, `games/<game>/`,
compiled against the engine. The engine never imports a game, and adding a game edits no file
outside its folder ([layout.md](layout.md), rule 6, and the `import` lint).

A game's folder holds its packages as the engine's sides are split: `games/<game>` is its
shared package (`package <game>`: the rules, constants and record types both sides use; only
`common:` and `core:`), `games/<game>/server` its server part (`package <game>_server`) and
`games/<game>/client` its client part (`package <game>_client`).

## The server's side: `core.Game`

A game's server part (`games/<game>/server`) exports one constant `core.Game` value: its id
(the folder's name), the types of its state, its pack (below), and the hooks the server calls
(`Game` in `server/core/server.odin`). Whoever starts the server puts it in `Config.game`; the
zero `Game` is no game, and the server is the engine alone. Every hook may be nil.

| Hook | When | Thread |
|---|---|---|
| `configure(^Config)` | First thing in `start`, before the config is checked: change the world's generator, mode, spawn... | the caller's |
| `start(s) -> bool` | The session is set up (worlds, seats, the game's state), before the first tick; false: `start` fails and frees the session | the caller's |
| `tick(s)` | Every tick, after the entities' (also while the world is frozen) | the server's |
| `joined(s, c)` | A player is playing: welcomed, in its world | the server's |
| `left(s, c)` | A playing player leaves (still seated, its state still there); not called for those still playing when the server stops | the server's |
| `command(s, c, name, args) -> bool` | A `/command` the server has none of (relative coordinates already expanded); the game checks its own arguments and permissions (`core.allowed`); false: unknown | the server's |
| `stop(s)` | After the last tick, before the last save; only after a `start` that succeeded | the caller's |

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
| `Game`, `Config`, `Server`, `Client`, `World`, `Mode_Result` | The game itself, the config `configure` changes, the session, a player, a world |
| `game_state(s, T)`, `game_client_state(s, c, T)` | The game's state, for the session and for a seat |
| `game_put(s, c, &value)`, `game_event(s, c, &value)` | Its records and events ([below](#records-and-events)) |
| `notice(s, c, text)`, `announce(s, text)` | Tell one player; tell every player in the chat |
| `client_name(c)`, `allowed(s, c, node)` | A player's name; whether it holds a permission |
| `teleport(s, c, position, look, flying)` | Move a player in its world (standing where it fits once the blocks are there, or flying) |
| `game_mode(s, c, id)` | Put a player in a mode by id (a pack's too: `flood:out`); journalled as the game's |
| `kit_give(s, c)` | Give a player what its mode's kit has that it lacks, weapons full |
| `head_in_water(s, c)` | A player's eyes are in water |
| `world_keep(w, area)`, `world_ready(w, area)`, `world_release(w)` | Keep an area loaded with nobody near; whether all of it is there; let it go |
| `block_at(w, p)` | Read a block (false: not loaded) |
| `game_act(s, w, system)`, `Act` | A cause for the game's block changes, its actor the game: one per cause |
| `set_block(w, p, block, act)`, `bulk_edit(w, edit, act)`, `Bulk_Edit`, `Box`, `Sphere` | Change blocks through the edit journal ([journal.md](journal.md)) |

The fields a game reads: `Server`'s `tick`, `clients`, `home`, `worlds`, `config` and
`registry`; `Client`'s `state`, `world`, `player` (its position, velocity, flying), `mode`
and `inventory`; `World`'s `rules` and `clock`. What it writes of the engine's state is a
world's rules (`w.rules.explosion_size = 1.75`; the Rules record carries them to the players
at the end of the tick) and, in `start`, its clock; everything else goes through the list.

## The client's side: `engine.Game`

A game's client part (`games/<game>/client`) exports one constant `engine.Game` value
(`client/engine/game.odin`): its id, its kinds (the same `KINDS` of its shared package as the
server part's), the type of its state, its console commands and the hooks the client calls.
A `Session` holds the game it plays and its state (ground rule 1: the session's arena, freed
with it; the App only holds the list of games, constant data). Every hook may be nil; all run
on the main thread, in the frame.

| Hook or field | When |
|---|---|
| `started(s)` | The session plays the game: welcomed, its state zero |
| `ended(s)` | The session ends (only after `started`; its state still there) |
| `received(s, r)` | A record of the game's kinds came, changed or went, or one of its events came, in the order sent |
| `hud(s, ctx)` | Every frame in the world, after the engine's HUD (`client/hud`'s `hud_draw`; F1 hides both), with the `ui.Context` |
| `debug(s) -> string` | Every frame with F3 open: one line of the overlay, shown as `game <id>: <line>` ("": none) |
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

The server names its game in the handshake: `Welcome.game` (its id; "" for none). The client
looks for the client part of that id among the games it has (`App.games`); with it, the
session's schema gains the game's kinds, its state is made and `Welcome.schema` must match
(else the session fails: "the server runs a different version (its state schema is not
ours)"). A client without that game fails the session before playing with "the server plays
<id>, a game this version does not have", which the player reads on the screen a failed
session shows; nothing is half-applied. The server is told nothing: the client leaves.

A world of our own plays the game `voxiverse --game <id>` names (default: none, exactly the
engine alone): the client starts its embedded server with that game's server part
(`App.server_games`), whose Welcome then names it like any server's. The id must be a game
with both parts; any other is refused at startup with the list of those there are.

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
`voxiverse-server --game <id>` (default: none); the client gives both lists to the App.

Adding a game is a folder `games/<game>/` holding its shared package, a `server` package
that exports `GAME :: core.Game{...}` and a `client` package that exports `GAME ::
engine.Game{...}`, with their tests beside them: nothing else. `games/stopwatch` is the
model: the smallest game that uses every hook of the server's, a client part with its state,
records, HUD, F3 line and command, and a record and an event of its own. Its server part's
tests run it on a stepped server with the harness's mirror client; its client part's tests
play it whole, a session joining the server part over the harness's network and drawing its
HUD, the one place a part imports another (the `import` lint lets a client part's tests
import its server part). `voxiverse --game stopwatch` plays it in a world of our own.

## The game's pack

A game may bring content as data, a pack of its own ([packs.md](packs.md)) in
`games/<game>/pack/`, named for the game (`pack.json`'s namespace and the folder: its ids read
`<game>:<name>`), laid out as any pack ([layout.md](layout.md), rule 6). Its shared package
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

Anything a game keeps beyond these blocks it frees in its own hooks.

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
  before; `Welcome` names the game (`game`, its id, "" for none) and carries the hash of every
  kind (`schema`), which the client checks once it has the same game's kinds. A client and
  server with different records of a game refuse each other as they do for the engine's.
- The harness's mirror client builds its schema with the server's game, so a game's test
  reads what its players were told: `core.mirror_game_record(&sess.mirror, stopwatch.Times)`.

`build schema` writes the engine's kinds into the Wireshark dissector; a game's kinds are not
in it. `build netdump` decodes with the engine's schema alone: in a trace of a session with a
game, a State message that carries the game's records counts as one that does not decode.
