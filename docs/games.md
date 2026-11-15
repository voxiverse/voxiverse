# Games

The engine (`client/`, `common/`, `server/`) runs worlds; a **game** is the rules played in
one: a round, a goal, a score. Each game is native Odin in its own folder, `games/<game>/`,
compiled against the engine. The engine never imports a game, and adding a game edits no file
outside its folder ([layout.md](layout.md), rule 6, and the `import` lint).

A game's folder holds its packages as the engine's sides are split: `games/<game>` is its
shared package (`package <game>`: the rules, constants and record types both sides use; only
`common:` and `core:`), `games/<game>/server` its server part (`package <game>_server`).

## The server's side: `core.Game`

A game's server part (`games/<game>/server`) exports one constant `core.Game` value: its id
(the folder's name), the types of its state, and the hooks the server calls (`Game` in
`server/core/server.odin`). Whoever starts the server puts it in `Config.game`; the zero
`Game` is no game, and the server is the engine alone. Every hook may be nil.

| Hook | When | Thread |
|---|---|---|
| `configure(^Config)` | First thing in `start`, before the config is checked: change the world's generator, mode, spawn... | the caller's |
| `start(s) -> bool` | The session is set up (worlds, seats, the game's state), before the first tick; false: `start` fails and frees the session | the caller's |
| `tick(s)` | Every tick, after the entities' (also while the world is frozen) | the server's |
| `joined(s, c)` | A player is playing: welcomed, in its world | the server's |
| `left(s, c)` | A playing player leaves (still seated, its state still there); not called for those still playing when the server stops | the server's |
| `command(s, c, name, args) -> bool` | A `/command` the server has none of (relative coordinates already expanded); the game checks its own arguments and permissions (`core.allowed`); false: unknown | the server's |
| `stop(s)` | After the last tick, before the last save; only after a `start` that succeeded | the caller's |

A game reaches the server through `server/core`'s exported procedures and the fields of
`Server` and `Client`. Most of `server/core` is private to it; what games need is exported as
they need it (`notice` tells a player something, `allowed` checks a permission).

A game's tick runs inside the server's, so the stepped server (and its tests) run it too, and
it follows [determinism.md](determinism.md): no clock, no unseeded randomness.

## The list of games

No file lists the games. The build driver writes one before every `odin` it runs:
`build/generated/games/games.odin`, the package `generated:games` (the collection
`generated` is `build/generated`), whose `SERVER` holds every `games/<game>/server`
package's `GAME`, sorted by folder. An `#assert` there keeps each game's id its folder's
name. Only the executables' main packages import it (the `import` lint), and the dedicated
server runs one with `voxiverse-server --game <id>` (default: none). The client has no games
yet.

Adding a game is a folder `games/<game>/` holding its shared package and a `server` package
that exports `GAME :: core.Game{...}`, with their tests beside them: nothing else.
`games/stopwatch` is the model: the smallest game that uses every hook and both blocks of
state, and tests that run it on a stepped server.

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
- The hashes: `Hello` carries the hash of the engine's kinds, which the server checks as
  before; `Welcome` names the game (`game`, its id, "" for none) and carries the hash of every
  kind (`schema`), which the client checks once it has the same game's kinds. A client and
  server with different records of a game refuse each other as they do for the engine's.
- The harness's mirror client builds its schema with the server's game, so a game's test
  reads what its players were told: `core.mirror_game_record(&sess.mirror, stopwatch.Times)`.

`build schema` writes the engine's kinds into the Wireshark dissector; a game's kinds are not
in it. `build netdump` decodes with the engine's schema alone: in a trace of a session with a
game, a State message that carries the game's records counts as one that does not decode.
