# Glossary

One word per thing, in code, docs and UI alike. Where today's code still says otherwise,
the milestone that changes it is named.

**Where things are**

| Term | Is | In code |
|---|---|---|
| Universe | One game instance: a running server and everything it keeps. A dedicated server is one universe; singleplayer runs one inside the client. Its save directory holds `universe.cfg` (name, seed, the worlds it has, the default world), accounts, characters, permissions, community data, and `worlds/` | `core.Server` and its save directory (M17: today's save is one world) |
| Save | What players see for a universe they play alone: the Singleplayer screen lists saves. The code says universe |
| World | One voxel space in a universe: an id, a seed, a generator with its parameters, rules, sky, chunks, entities, liquids, a spawn, and `worlds/<id>/`. There is no "planet" in code; content may present worlds as planets | today `server.World` is the chunk store; M17 makes a world own all of the above |
| Loaded / unloaded world | Loaded: in memory and ticking (someone is in it, or was a moment ago). Unloaded: only on disk, or only an id (never visited: derived from the universe seed when first needed) | M17 |
| Universe seed, world seed | The universe's seed; a world's own, derived from the universe seed and its id unless set | M17 |
| Chunk, column, region | 16x16x16 blocks; a chunk column (x, z) with its column tops; a region file of 16x16 chunk columns | `game.Chunk_Pos`, `game.Column`, `game.Region_Pos` |
| Block, block position | A cell's content (`game.Block`); its integer position in a world | `game.Block`, `game.Block_Pos` |
| Symbol | One of the 40 letters addresses are written in: Old Turkic (Orkhon) characters, real Unicode (U+10C00–U+10C48), so addresses copy into chat and outside the game | M17 (`common/game/address.odin`) |
| Address | A world's name in a universe: a galaxy (eight different symbols, in order) and a world in it (seven different symbols, in order). Written world first; the galaxy left out means the gate's own. The address alone decides what kind of world it is (generator, palette, climate, sky, astronomy); the universe seed adds the exact terrain. Shareable: the same address is the same kind of world in any universe. Sized after the observable universe: see "Addresses: how many worlds" | M17 |
| Galaxy | The first part of an address: worlds sharing it are in the same galaxy, which everyday dialing stays within | M17 |
| Gate | A structure that dials addresses and carries characters to the gate of the world dialed. "Stargate" is not a name we use | M18 |
| Spawn | Where a world receives arrivals with no place of their own; the universe's default world's spawn receives new characters | `World_Spawn` |
| Landing | The step every arrival goes through: held still until the blocks are loaded, then stood where it fits | `land`, `game.landing_spot` |

**Who is there**

| Term | Is | In code |
|---|---|---|
| Account | An identity. Offline (singleplayer, LAN, an offline server) it is a keypair made by the client, the public key being the account. When online, an account of the auth service of a *remote* (`voxiverse.net` by default) is the source of truth for identity and ownership (skins, owned things); the keypair stays as a **device key** that the account vouches for. Not tied to a universe | M16 (today: the offline keypair; the auth client is in "The next tier") |
| Character | A persona of an account in one universe: a name (unique in the universe), their inventory, statistics, where they are. Kept by the universe, so it goes with them across its worlds; it does not leave the universe | M16 (today: the per-world player file, `players/<name>.json`) |
| Player | A character being played right now by a connected client | `core.Client`, `engine.Session` |
| Owner | An account with every permission in a universe: the host in singleplayer, `--cheats` on a dedicated server | `is_owner` |
| Host | A player whose client runs the universe (singleplayer, LAN) | `session_hosting` |
| Entity | Anything in a world besides blocks and players: sheep, rockets, dropped stacks | `game.Entity_Kind` |

**What happens**

| Term | Is |
|---|---|
| Join / leave | A client connects to a universe as a character, or disconnects |
| Arrive / depart | A character enters or leaves a world: on joining, on leaving, and travelling |
| Travel | Moving a character from one world to another in the same universe: through a gate (M18), or `travel` (M17); never between universes |
| Dial | Entering an address on a gate, symbol by symbol, in order |
| Teleport | Moving within one world (tp, home, warp, spawn, back) |
| Tick, frame | The server's fixed step (30 per second); the client's drawn frame |

**What is set**

| Term | Is | In code |
|---|---|---|
| Rules | Per world, shared by server and client physics (`rules.*`) | `game.Rules` |
| Generator parameters | Per world (`worldgen.*`) | `worldgen.Params` |
| Settings | The player's own preferences on their machine | `engine.Settings` |
| Config | A server process's start-up flags and limits | `core.Config` |
| Variables | The mechanism all of the above are read, set and saved through | `base.Var` |
| Permissions | Nodes, roles and grants, per universe | `Permissions` |

**Glossary** (names only; code, docs and UI use them): Title screen, Universes screen, Universe creation, Multiplayer screen, Options, Game menu, Player menu, Section (a page of the player menu: Map, Journal, Inventory, Character, Atlas, Statistics), Container view, HUD, Overlay, Toast, Dev panels. The Singleplayer screen of the Save row is the universes screen; the code follows in M48d-M48e.

**Renames these imply:** M16 turns player files into characters
(`characters/<account>/<character>.json`). M17 renames the client's Worlds screen and
`world <name>` command to universes (the singleplayer list is a list of universes), moves
`world.cfg`'s universe-wide parts to `universe.cfg`, and gives each world its own
`worlds/<id>/world.cfg`, regions and entities. `server.World` (the chunk store) becomes
part of a per-world struct.
