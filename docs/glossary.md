# Glossary

One word per thing, in code, docs and UI alike. Where the code uses another word, the entry says so.

**Where things are**

| Term | Is | In code |
|---|---|---|
| Universe | One game instance: a running server and everything it keeps. A dedicated server is one universe; singleplayer runs one inside the client. Its save directory holds `universe.cfg` (format, seed, home world, default game mode, kit, packs, age), `characters/`, `permissions.cfg`, `community.cfg` and `worlds/`. Its name is the directory's name | `core.Server`, `core.Store` and the save directory (`server/core/save.odin`) |
| Save | What players call a universe they play alone: the Singleplayer screen lists saves. The code says universe, except the list entry | `engine.Save_Entry` (`client/engine/universes.odin`) |
| World | One voxel space in a universe: an address, a seed, a generator with its parameters, rules, clock, chunks, entities, liquids, a spawn, gates, a journal, and `worlds/<address>/`. There is no "planet" in code; content may present worlds as planets | `core.World` (`server/core/worlds.odin`) |
| Home world | The universe's default world, always loaded; its spawn receives new characters. Its address is derived from the universe seed | `Server.home`, `game.address_derive` |
| Loaded / unloaded world | Loaded: in memory and ticking (someone is in it or in an open gate, or was `WORLD_IDLE_SECONDS` ago). Unloaded: only on disk, or only an address (never visited: its kind follows from the address when first needed) | `world_load`, `WORLD_IDLE_SECONDS` |
| Universe seed, world seed | The universe's seed; a world's own: the universe seed for the home world, for any other the universe seed mixed with the address's hash | `Config.seed`, `world_kind` |
| Chunk, column, region | 16x16x16 blocks; a chunk column (x, z) with its column tops; a region file of 16x16 chunk columns | `game.Chunk_Pos`, `game.Column`, `game.Region_Pos` |
| Block, block position | A cell's content; its integer position in a world | `game.Block`, `game.Block_Pos` |
| Symbol | One of the 40 letters addresses are written in: Old Turkic (Orkhon) characters, real Unicode (block U+10C00-U+10C48), so addresses copy into chat and outside the game | `game.SYMBOL_RUNES` (`common/game/address.odin`) |
| Address | A world's name in a universe: a galaxy (eight different symbols, in order) and a world in it (seven different symbols, in order). Written world first; the galaxy left out means the gate's own. The address alone decides what kind of world it is (generator parameters, rules); the universe seed adds the exact terrain. The same address is the same kind of world in any universe | `game.Address`, `world_kind` |
| Galaxy | The first part of an address: worlds sharing it are in the same galaxy | `Address.galaxy` |
| Gate | A structure that dials addresses and carries characters to the gate of the world dialed. "Stargate" is not a name we use | `server/core/gates.odin`, `common/worldgen/gates.odin` |
| Spawn | Where a world receives arrivals with no place of their own | `core.World_Spawn` |
| Landing | The step every arrival goes through: held still until the blocks are loaded, then stood where it fits | `core.land`, `game.landing_spot` |

**Who is there**

| Term | Is | In code |
|---|---|---|
| Account | An identity: an Ed25519 key pair the client makes and keeps; the public key is the account. Joining proves it by signing the server's nonce. Not tied to a universe | `game.Account`, `game.Account_Key` (`common/game/account.odin`) |
| Character | A persona of an account in one universe: a name (unique in the universe), their inventory, statistics, where they are. Kept by the universe, so it goes with them across its worlds; it does not leave the universe | `server/core/player_data.odin`: `characters/<account>/<name>.json` |
| Player | A character being played right now by a connected client | `core.Client`, `engine.Session` |
| Owner | A player with every permission: the local player of a world played here (singleplayer, with cheats allowed), or everyone when the server runs with `--cheats` | `core.is_owner` |
| Host | A player whose client runs the universe (singleplayer, LAN) | `engine.session_hosting` |
| Entity | Anything in a world besides blocks and players: sheep, rockets, dropped stacks | `game.Entity_Kind` |
| Archetype store | Entities grouped by their set of components, one column table per set, structural changes deferred and applied in issue order. Not used by the game yet (entities v2, part one) | `game.Entity_Store` (`common/game/archetype.odin`) |
| Spatial query service | A grid of chunk-sized cells holding entity boxes; sphere, cylinder, box, nearest, count and cast queries return ids ascending. Not used by the game yet (entities v2, part one) | `game.Spatial` (`common/game/spatial.odin`) |

**What happens**

| Term | Is |
|---|---|
| Join / leave | A client connects to a universe as a character, or disconnects |
| Arrive / depart | A character enters or leaves a world: on joining, on leaving, and travelling |
| Travel | Moving a character from one world to another in the same universe: through a gate, or the `travel` command; never between universes |
| Dial | Entering an address on a gate, symbol by symbol, in order |
| Teleport | Moving within one world (tp, home, warp, spawn, back) |
| Tick, frame | The server's fixed step (30 per second, `game.TICK_RATE`); the client's drawn frame |

**What is set**

| Term | Is | In code |
|---|---|---|
| Rules | Per world, shared by server and client physics (`rules.*`) | `game.Rules` |
| Generator parameters | Per world (`worldgen.*`) | `worldgen.Params` |
| Settings | The player's own preferences on their machine | `engine.Settings` |
| Config | A server process's start-up flags and limits | `core.Config` |
| Variables | The mechanism all of the above are read, set and saved through | `base.Var` |
| Permissions | Nodes, roles and grants, per universe | `core.Permissions` |

**Interface names** (code, docs and UI use them): Title screen, Universes screen, Universe creation, Multiplayer screen, Options, Game menu, Player menu, Section (a page of the player menu: Inventory and Statistics are shown; Map, Journal, Character and Atlas are declared and hidden), Container view (the chest beside the inventory), HUD, Overlay, Toast, Dev panels. The Singleplayer screen is the universes screen (`client/screen/universes.odin`).
