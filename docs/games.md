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
