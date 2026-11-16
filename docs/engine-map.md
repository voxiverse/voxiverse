# Engine map

What the engine offers a game, written from the source by `./build.sh engine-map`: do not
edit it (`check` fails while it is stale). The names are those [games.md](games.md) lists a
game may call, each with its signature and its doc comment's first sentence; games.md says
how they fit together. A game's code names nothing else of `server:core` (the `import`
lint); the `common:` packages (`game`, `base`, `worldgen`...) and `client:ui` it calls directly.

## `core.Game`

a game the server runs (docs/games.md): its id, the types of its state, and the hooks the server calls.

| Hook or field | Type | What it is |
|---|---|---|
| `info` | `game.Game_Info` | its id (its folder's name in games/: the dedicated server's --game), name and description (its shared package's) |
| `kinds` | `protocol.Game_Kinds` | what it replicates besides the engine (its shared package's; game_put, game_event) |
| `server_state` | `typeid` | its state for the session (game_state): zero at start; nil: none |
| `client_state` | `typeid` | ... |
| `entity_data` | `typeid` | its record on each entity of its pack's kinds (entity_data): zero at spawn, saved with the world; nil: none |
| `stats` | `[]Game_Stat` | the statistics it keeps of its players (stat_count, stat_world): with the character, shown with the engine's |
| `character_data` | `typeid` | its record on each character (character_data): zero for a new one, kept with the character and saved in its file; nil: none |
| `world_state` | `typeid` | its state for each world (world_state): zero when the world opens, freed with it; nil: none |
| `world_files` | `[]World_File` | the files it keeps in each world's directory (world_file_read, world_file_write) |
| `configure` | `proc(config: ^Config)` | before anything else: may change the config |
| `start` | `proc(s: ^Server) -> bool` | the session is set up, no tick has run (false: start fails) |
| `stop` | `proc(s: ^Server)` | after the last tick, before the last save |
| `tick` | `proc(s: ^Server)` | every tick, after the entities' (also while frozen) |
| `spawned` | `proc(s: ^Server, w: ^World, h: game.Entity_Handle) -> (keep: bool)` | a creature of a kind with a spawn rule appeared by itself (natural): the game makes it what it is (its record, its looks) or refuses it (false: it goes) |
| `think` | `proc(s: ^Server, w: ^World, kind: game.Kind_Id, entities: []game.Entity_Handle)` | each tick, the creatures of each of its kinds whose brain is "game" (their ground loaded, lowest id first), before they are steered |
| `joined` | `proc(s: ^Server, c: ^Client)` | c is playing (welcomed, in its world) |
| `left` | `proc(s: ^Server, c: ^Client)` | c is leaving (still seated, its state still there) |
| `command` | `proc(s: ^Server, c: ^Client, name: string, args: []string) -> (known: bool)` | a command the server has none of; known false: "Unknown server command" |
| `hurt` | `proc(s: ^Server, c: ^Client, harm: Harm)` | c was hurt and lives (its health already less) |
| `died` | `proc(s: ^Server, c: ^Client, harm: Harm)` | c died of harm (already told, counted and its things dropped) |
| `respawned` | `proc(s: ^Server, c: ^Client)` | c stands again: at the world's spawn, full health, the mode's kit (the game may move it, change what it holds) |
| `editing` | `proc(s: ^Server, c: ^Client, at: game.Block_Pos, old, new: game.Block) -> (refusal: string)` | c would change the block at `at` (its rules and reach allow it): "" lets it, else the edit is refused and c is told why |
| `entity_use` | `proc(s: ^Server, c: ^Client, h: game.Entity_Handle, stack: game.Stack) -> (refusal: string)` | c uses (right-clicks) the entity h within its reach, holding stack: the game does what the use does for its kinds and says "", or refuses (nothing happens, c is told why); then the engine's own use of the kind, if any |
| `block_changed` | `proc(s: ^Server, w: ^World, change: Block_Change)` | blocks of w changed (by a player, the world, a command, the game): told once a tick, before the game's tick |
| `entity_hurt` | `proc(s: ^Server, w: ^World, h: game.Entity_Handle, harm: Entity_Harm)` | an entity of w was hurt and lives (its health already less: entity_harm) |
| `entity_died` | `proc(s: ^Server, w: ^World, dead: Dead_Entity, harm: Entity_Harm)` | an entity of w died of harm (gone already: dead says what and where it was) |
| `action` | `proc(s: ^Server, c: ^Client, index: int)` | c pressed the game's action `index` (0 ..< game.MAX_GAME_ACTIONS; the client part's Game.actions names them); not while dead |
| `request` | `proc(s: ^Server, c: ^Client, r: Request)` | c's client part sent one of the game's requests (Game_Kinds.requests), decoded and checked (request_value) |
| `picking` | `proc(s: ^Server, c: ^Client, stack: game.Stack) -> Pickup` | c walks over a dropped stack it may pick up: take it, leave it, or the game took it its own way |
| `harming` | `proc(s: ^Server, h: ^Harming)` | any harm about to be done, to a player or an entity: may change h.amount (0 or less: none) |
| `save` | `proc(s: ^Server, out: ^strings.Builder)` | what it keeps with the universe, as text (game.cfg), at each save's tick |
| `load` | `proc(s: ^Server, text: string) -> (ok: bool)` | its game.cfg, after start, before the first tick (a universe that has one); false: start fails |
| `world_opened` | `proc(s: ^Server, w: ^World)` | w is open (started, its entities loaded; the home world after start and load): the game makes what it keeps of it (world_state, its files read) |
| `world_closed` | `proc(s: ^Server, w: ^World)` | w closes (unloaded, or the session stops), after its last save: the game frees what it made of it |
| `world_save` | `proc(s: ^Server, w: ^World)` | a save captures w at this tick (with the universe, or w alone as it unloads): the game stages its files (world_file_write) |
| `machine_data` | `typeid` | its record on each machine of its pack's blocks (machine_data): zero when built, saved with the chunk; nil: none |
| `machine_shown` | `typeid` | what players are shown of each machine (machine_show; engine.machine_shown): at most game.MAX_MACHINE_SHOWN bytes; nil: nothing |
| `machines` | `proc(s: ^Server, w: ^World, kind: game.Block_Type, at: []game.Block_Pos)` | the machines of w whose time has come (machine_wake), a call per block type, lowest position first |
| `machine_use` | `proc(s: ^Server, c: ^Client, at: game.Block_Pos) -> (refusal: string)` | c uses (right-clicks) the machine at `at` within its reach: the game opens its panel, or refuses (c is told why) |
| `pack` | `game.Pack_Source` | its own pack (games/<game>/pack, named for the game; its shared package's): loaded only where it is played (game_packs) |

## `engine.Game`

a game's client part (docs/games.md): what the client does for the game its session plays.

| Hook or field | Type | What it is |
|---|---|---|
| `info` | `game.Game_Info` | its id (its folder's name in games/: what the server's Welcome names), name and description (its shared package's, as the server part's) |
| `kinds` | `protocol.Game_Kinds` | what its server part replicates (its shared package's) |
| `state` | `typeid` | its state for the session (game_state): zero when the game begins; nil: none |
| `started` | `proc(s: ^Session)` | the session plays the game: welcomed, its state zero |
| `ended` | `proc(s: ^Session)` | the session ends (its state still there) |
| `received` | `proc(s: ^Session, r: protocol.Received)` | a record of the game's kinds came, changed or went, or an event (game_value) |
| `hud` | `proc(s: ^Session, ctx: ^ui.Context)` | draw its HUD, after the engine's (F1 hides both) |
| `debug` | `proc(s: ^Session) -> string` | its line of the F3 overlay ("": none; temporary memory) |
| `scoreboard` | `proc(s: ^Session, board: ^Scoreboard)` | fill board: what the player list shows while its key is held, in place of the engine's |
| `commands` | `[]Command_Spec` | its console commands, there while a world plays it |
| `camera` | `proc(s: ^Session) -> Game_Camera` | the camera it wants, every frame (nil: the player's own, F5) |
| `actions` | `[]string` | its own actions' names (at most game.MAX_GAME_ACTIONS): keys Game_1.. |
| `screen` | `proc(s: ^Session, ctx: ^ui.Context, top: bool)` | its screen, every frame while it is open (game_screen_open): a panel over the world drawn with the UI kit; top: it has the focus |
| `keys` | `[]Game_Key` | its client part's own keys (at most MAX_GAME_KEYS): a command panel's hotkeys, control groups; read with game_key_pressed and game_key_down, never sent |
| `no_hotbar` | `bool` | its players hold no hotbar: in its world the hotbar's keys and the wheel pick no slot, and the controls do not list them |
| `machine_shown` | `typeid` | what its machines show (its server part's Game.machine_shown): machine_shown reads it |

## `server/core` (`core.`): What a game may call

- `Game :: struct {...}`: a game the server runs (docs/games.md): its id, the types of its state, and the hooks the server calls.
- `Config :: struct {...}`: what a server session is started with (start): the universe, its worlds' defaults, the game it plays; a game's configure hook may change it.
- `Server :: struct {...}`: a session of the universe: its config, worlds, clients and tick, what every hook of a game is given.
- `Client :: struct {...}`: one connection to the server, and once it is playing, a player: its seat, its world, its player and inventory.
- `World :: struct {...}`: one voxel space of the universe, loaded (docs/glossary.md): its address, rules, clock, chunks and entities.
- `Harm :: struct {...}`: what hurt a player, as a game's hurt and died hooks are told it.
- `Entity_Harm :: struct {...}`: what hurt an entity, as a game's entity_hurt and entity_died hooks are told it.
- `Harming :: struct {...}`: a harm about to be done, as a game's harming hook is shown it before it is: the hook may change the amount (a player's stats, armour, a critical blow, a rolled weapon); 0 or less and nothing is done.
- `Dead_Entity :: struct {...}`: an entity that died, as the entity_died hook is told it (it is gone from the world by then: its handle finds nothing).
- `Block_Change :: struct {...}`: blocks a world changed, as a game's block_changed hook is told them: one block (old and new say what it was and is), or a bulk edit's box (bulk: read the blocks).
- `Pickup :: enum u8 {Take, Leave, Taken}`: what a game's picking hook makes of a stack a player walks over.
- `Request :: struct {...}`: one of the game's requests from a player's client part (Game.request): its kind and its value, valid for the hook's call; request_value reads it as its type.
- `game_state :: proc(s: ^Server, $T: typeid) -> ^T`: the game's state for the session, as the type it declared (Game.server_state).
- `game_client_state :: proc(s: ^Server, c: ^Client, $T: typeid) -> ^T`: the game's state for c's seat, as the type it declared (Game.client_state).
- `world_state :: proc(w: ^World, $T: typeid) -> ^T`: the game's state for w, as the type it declared (Game.world_state).
- `character_data :: proc(s: ^Server, c: ^Client, $T: typeid) -> ^T`: the game's record on c's character, as the type it declared (Game.character_data).
- `entity_data :: proc(w: ^World, h: game.Entity_Handle, $T: typeid) -> ^T`: the game's record on an entity of its kinds (Game.entity_data, as the type it declared): zero when the entity came to be, saved and loaded with the world (entities.cfg, field by field), told to no one unless the game puts it in a record of its own keyed by the entity (protocol.key_entity).
- `World_File :: struct {...}`: a file a game keeps in each world's directory.
- `world_file_read :: proc(w: ^World, name: string) -> ([]u8, bool)`: the game's file `name` of w as saved (temporary memory); false when there is none (a new world, a world not saved, a file never written).
- `world_file_write :: proc(w: ^World, name: string, data: []u8) -> bool`: the game's file `name` of w is data, from the save being made (its world_save hook: in the save's transaction); outside a save it is replaced at once.
- `world_file_aside :: proc(w: ^World, name: string)`: the game's file `name` of w is damaged: it is moved aside (`.bad`, as a damaged region is) and logged, and the game goes on without it.
- `game_put :: proc(s: ^Server, c: ^Client, value: ^$T, key := protocol.Key{})`: game_put sets c's record of the game's kind whose value type is T (Game.kinds) for this tick, under key for a keyed kind: state_put for a game.
- `game_event :: proc(s: ^Server, c: ^Client, value: ^$T)`: game_event queues a one-off event of the game's kind whose value type is T for c: event_send for a game.
- `request_value :: proc(s: ^Server, r: Request, $T: typeid) -> (value: ^T, ok: bool)`: r's value as ^T when r is of the game's request kind whose value type is T: a game's code holds no kind number and no cast.
- `notice :: proc(s: ^Server, c: ^Client, text: string)`: notice tells one player something (cut to game.MAX_NOTICE_TEXT, at a whole letter).
- `announce :: proc(s: ^Server, text: string)`: a line in every playing player's chat, from the server (no one's): what a game says to everyone (a round begins, who is out).
- `Game_Stat :: struct {...}`: a statistic a game keeps of its players (Game.stats): counted with the character and the world as the engine's are, and shown wherever they are (the statistics).
- `Stat_Kind :: enum u8 {Count, Distance, Time}`: what a game's statistic measures: a count, a distance or a time.
- `stat_count :: proc(s: ^Server, c: ^Client, name: string, amount := 1)`: player c adds amount to one of the game's statistics (Game.stats): kept with its character and its world, shown with the engine's.
- `stat_world :: proc(s: ^Server, w: ^World, name: string, amount := 1)`: amount added to one of the game's statistics for world w, with no player to credit (a lamb born).
- `client_name :: proc(c: ^Client) -> string`: the name c plays as.
- `allowed :: proc(s: ^Server, c: ^Client, node: string) -> bool`: c may do node.
- `player_id :: proc(s: ^Server, c: ^Client) -> u16`: c's id, its seat: what its players' records are keyed by (game.key_player).
- `player_ref :: proc(s: ^Server, c: ^Client) -> Player_Ref`: c as a Player_Ref.
- `player_of :: proc(s: ^Server, ref: Player_Ref) -> ^Client`: the playing player ref names; nil when it left (its seat empty or another's) or is not playing.
- `Player_Ref :: struct {...}`: a player held past the moment (a rocket's shooter): its seat and the seat's generation, which counts up each time a player takes the seat.
- `teleport :: proc(s: ^Server, c: ^Client, position: [3]f64, look: [2]f32, flying := false)`: teleport moves c's player to position in its world, looking look (yaw, pitch), flying if flying (and its mode lets it fly) and else standing where it fits there once the blocks are loaded (land, Exact).
- `game_mode :: proc(s: ^Server, c: ^Client, id: string) -> Mode_Result`: the game the server runs puts c in the mode called id ("survival", a pack's "flood:out"); journalled with the game as who changed it.
- `kit_give :: proc(s: ^Server, c: ^Client)`: what the character's mode's kit has that they lack (so a kept inventory is not doubled); full magazines are the weapons' (weapons.odin).
- `item_count :: proc(c: ^Client, item: game.Item) -> int`: how much of item c carries in its slots (not in its hand's cursor, not worn).
- `item_give :: proc(s: ^Server, c: ^Client, item: game.Item, count: int) -> (given: int)`: count of item into c's slots, as stacks fit (the hotbar first); how many went in (the rest found no room and is not given).
- `item_take :: proc(s: ^Server, c: ^Client, item: game.Item, count: int) -> (taken: int)`: up to count of item out of c's slots; how many it took.
- `item_clear :: proc(s: ^Server, c: ^Client, item: game.Item) -> int`: all of item out of c's slots; how many there were.
- `item_spend :: proc(s: ^Server, c: ^Client, item: game.Item, count := 1) -> bool`: c spends count of an item it carries on a use (fed to a creature): taken and booked as used, unless its mode gives without end (it keeps them).
- `hotbar_select :: proc(s: ^Server, c: ^Client, slot: int) -> bool`: c holds hotbar slot `slot` (0 ..< game.HOTBAR_SLOTS), as if it had chosen it (the Select its client sends).
- `item_drop :: proc(s: ^Server, w: ^World, position: [3]f64, stack: game.Stack) -> game.Entity_Handle`: the game drops a stack into the world at position (loot, a chest's spill), with its game data (Stack.data: a rolled stat, a rarity); it hops up a little, lies there for its kind's life, and the first player to walk over it picks it up (the game's picking hook may decide).
- `head_in_water :: proc(s: ^Server, c: ^Client) -> bool`: c's eyes are in water (where a game drowns a player: the engine does not).
- `player_health_bonus :: proc(s: ^Server, c: ^Client, bonus: f32)`: the game adds bonus health points to c's most (a level's, a blessing's; 0: none): from the next tick its health tops out there, a lower most cuts what it has.
- `heal_player :: proc(c: ^Client, amount: f32)`: c recovers amount health points (not past its most; not a dead one).
- `game_rule :: proc(s: ^Server, w: ^World, name, value: string) -> base.Var_Error`: the game the server runs sets w's rule called name (as the rule command names it: explosion_size) to value, as text: rule_change, with the game (by its id) as who asked.
- `sim_speed_set :: proc(s: ^Server, speed: int) -> bool`: the world's life (its time, its block updates and random ticks, its entities) steps speed times a tick from the next one: 0 pauses it, 2 and 4 run it fast; false (and nothing changes) past MAX_SIM_SPEED.
- `MAX_SIM_SPEED :: 4`: the most steps a tick a game may run its world at.
- `world_keep :: proc(w: ^World, area: Box)`: the chunks that hold the blocks of area stay loaded in w whoever is near (and so simulated, as every loaded chunk is), until world_release; those not loaded are asked for at once and every tick until they are (keep_request).
- `world_ready :: proc(w: ^World, area: Box) -> bool`: every chunk that holds the blocks of area is loaded and generated, so a bulk_edit of area changes all of it.
- `world_release :: proc(w: ^World)`: w no longer keeps any area; its chunks go as no player wants them.
- `under_sky :: proc(w: ^World, p: game.Block_Pos) -> bool`: nothing stands above the block p (the sky's light reaches it).
- `block_at :: proc(w: ^World, p: game.Block_Pos) -> (game.Block, bool)`: the block at p in w; false while its chunk is not loaded (or still generating), and the block is then .Air.
- `game_act :: proc(s: ^Server, w: ^World, system: game.Edit_System) -> Act`: a cause for the game the server runs (Config.game) to change blocks by through system: a new action whose actor is the game (Actor_Kind.Game, by its id).
- `Act :: struct {...}`: the cause a block change is made with.
- `set_block :: proc(w: ^World, p: game.Block_Pos, block: game.Block, act: Act, by: ^Client = nil) -> bool`: set_block changes one block, by act (its cause: journal.odin), told to everyone but the player it came from (by; nil: the world itself); false if its chunk is not loaded or the change is refused (admit).
- `bulk_edit :: proc(w: ^World, e: Bulk_Edit, act: Act) -> (changed: int, result: Bulk_Result, protected: int)`: bulk_edit applies e, by act; changed: how many blocks it changed, protected: how many more it skipped for being in a protected region.
- `Bulk_Edit :: struct {...}`: an operation on every block of a shape (bulk_edit).
- `Box :: struct {...}`: lo..hi inclusive.
- `Sphere :: struct {...}`: the blocks whose centres lie within radius of center.
- `structure_fit :: proc(w: ^World, t: ^game.Template, at: game.Block_Pos, rotation: u8, max_step: i32 = 0) -> Structure_Fit`: whether template t, turned rotation quarter turns with its lowest corner at `at`, fits: every cell it builds (not void) is air or gives way, and under each column of its footprint the ground (the highest solid block) is right below its floor (at.y - 1) or at most max_step lower.
- `structure_place :: proc(w: ^World, t: ^game.Template, at: game.Block_Pos, rotation: u8, act: Act) -> (changed: int, result: Bulk_Result)`: structure_place builds template t with its lowest corner at `at`, turned rotation quarter turns, in one bulk edit by act (its void cells leave what is there).
- `structure_remove :: proc(w: ^World, t: ^game.Template, at: game.Block_Pos, rotation: u8, act: Act) -> (changed: int, result: Bulk_Result)`: structure_remove takes down what structure_place built there: each of its blocks still as the template made it becomes air (what was changed since stays), in one bulk edit by act.
- `entity_spawn :: proc(w: ^World, kind: game.Kind_Id, position: [3]f64, natural: bool) -> game.Entity_Handle`: entity_spawn adds an entity at position (bottom centre); nil if full.
- `entity_gone :: proc(w: ^World, h: game.Entity_Handle)`: as entity_died, without a death to show (a stack picked up).
- `entity_find :: proc(w: ^World, id: u32) -> (game.Entity_Handle, bool)`: the entity with this id (a player is no entity here).
- `entities_of :: proc(w: ^World, kind: game.Kind_Id, center: [3]f64, radius: f64) -> []game.Entity_Handle`: the entities of a kind (0: any) within radius of center, nearest first (ties: lowest id), in the temp allocator: what a tower's aim, an ogre's nose or a city's census asks.
- `entities_each :: proc(w: ^World, after: u32 = 0) -> Entity_Iter`: entities_each starts a walk: `it := entities_each(w); for e, i in entities_next(&it)`, over the entities that stand now (those with an id above `after`).
- `entities_next :: proc(it: ^Entity_Iter) -> (h: game.Entity_Handle, index: int, ok: bool)`: the walk's next entity that still stands (ok false: the walk is over).
- `entity_yaw :: proc(w: ^World, h: game.Entity_Handle) -> f32`: which way the entity faces, radians turning left from -z (0: gone).
- `entity_pitch :: proc(w: ^World, h: game.Entity_Handle) -> f32`: how far the entity looks up, radians (down below 0; 0: gone).
- `entity_set_look :: proc(w: ^World, h: game.Entity_Handle, yaw, pitch: f32)`: the entity turns to face yaw and look up pitch (radians, as entity_yaw and entity_pitch give them).
- `entity_id :: proc(w: ^World, h: game.Entity_Handle) -> u32`: the id of the entity (0 for a stale handle).
- `entity_kind :: proc(w: ^World, h: game.Entity_Handle) -> game.Kind_Id`: the kind of the entity (0 for a stale handle).
- `entity_pos :: proc(w: ^World, h: game.Entity_Handle) -> [3]f64`: where ent is (its Transform; zero if it has none).
- `entity_health_of :: proc(w: ^World, h: game.Entity_Handle) -> int`: the entity's health points (0: it has no health, or is gone).
- `entity_max_health :: proc(w: ^World, h: game.Entity_Handle) -> int`: the most health the entity has (its kind's, unless a game set it).
- `entity_set_max_health :: proc(w: ^World, h: game.Entity_Handle, health: int)`: the entity's most health, and its health now, both `health` (a game's wave makes its creeps tougher).
- `entity_heal :: proc(w: ^World, h: game.Entity_Handle, amount: int)`: the entity's health raised by amount, up to its most (a building put up a little more, a creature's wound closing); nothing for one that has no health.
- `entity_show :: proc(w: ^World, h: game.Entity_Handle, look: string, on: bool) -> bool`: a look of the entity's kind (its pack's "looks", by name) shown or not: told to the players who know it, drawn as the kind's model says (a part shown or hidden, a colour, a size).
- `entity_known :: proc(c: ^Client, id: u32) -> bool`: c has been told about entity id (it is in its view).
- `entity_harm :: proc(w: ^World, h: game.Entity_Handle, harm: Entity_Harm) -> (died: bool)`: entity_harm takes harm.amount from an entity's health.
- `entity_go :: proc(w: ^World, h: game.Entity_Handle, target: [3]f64) -> bool`: the walker heads for target (the bottom centre of its box there) by a path of its own; false for an entity that is not a steered walker.
- `entity_follow :: proc(w: ^World, h: game.Entity_Handle, route: Route_Handle) -> bool`: the walker follows the route to its goal; false for an entity that is not a steered walker, or a route that is gone.
- `entity_stand :: proc(w: ^World, h: game.Entity_Handle)`: the walker stops where it is.
- `entity_arrived :: proc(w: ^World, h: game.Entity_Handle) -> bool`: the walker reached its point, or its route's goal.
- `entity_set_speed :: proc(w: ^World, h: game.Entity_Handle, speed: f32)`: how fast the walker goes, blocks a second (0: its kind's walk_speed).
- `entity_keep :: proc(w: ^World, h: game.Entity_Handle, target: [3]f64, near, far: f32) -> bool`: the walker keeps within near..far blocks (horizontally) of target, facing it: it walks closer when further (straight on when it sees the point, else by its own path) and backs away when nearer.
- `entity_sees :: proc(w: ^World, h: game.Entity_Handle, p: [3]f64) -> bool`: nothing solid lies between the entity's eyes (near the top of its box) and p.
- `entity_strike :: proc(w: ^World, h: game.Entity_Handle, target: Target) -> Strike`: the creature strikes at target with its kind's attack, if the attack is ready and the target within its reach (box to box): the damage its kind says (a game's harming hook may change it), credited to the creature; then it waits its cooldown, and shows the Striking look.
- `entity_shoot :: proc(w: ^World, h: game.Entity_Handle, p: [3]f64) -> bool`: the creature shoots its kind's shot at p, if its attack is ready (the game judges range and sight: entity_sees): the projectile flies from its chest straight at p and hurts what it hits by the attack's damage, credited to the creature.
- `entity_glide :: proc(w: ^World, h: game.Entity_Handle, points: []game.Block_Pos) -> bool`: the walker goes along points (the blocks it stands in, in order; at most path.MAX_PATH of them, the rest dropped) in straight legs at its speed, with no physics: no gravity, no collision, no push from others, nothing it can trip on.
- `MAX_TEAMS :: protocol.MAX_TEAMS`: the most sides a world's players and entities may be on (teams 1 to it; 0 is none).
- `client_set_team :: proc(c: ^Client, team: u8)`: the player's team (0: none).
- `client_team :: proc(c: ^Client) -> u8`: the player's team (0: none).
- `entity_set_team :: proc(w: ^World, h: game.Entity_Handle, team: u8)`: the entity's team (0: none), its `team<n>` look shown if its kind has one (and those of the other teams hidden).
- `entity_team :: proc(w: ^World, h: game.Entity_Handle) -> u8`: the entity's team (0: none, or gone).
- `entity_set_vision :: proc(w: ^World, h: game.Entity_Handle, vision: int)`: how far (blocks, horizontally, at most 255) the entity sees for its team in a world with fog.
- `entity_vision :: proc(w: ^World, h: game.Entity_Handle) -> int`: how far the entity sees (0: not at all).
- `world_fog :: proc(w: ^World, on: bool)`: whether the world's players on a team are told only of what their team sees.
- `team_sees :: proc(w: ^World, team: u8, p: [3]f64) -> bool`: a team sees a point: one of its entities sees it (in a world with fog).
- `Machines :: struct {...}`: the world's queue of machines waiting to think.
- `machine_data :: proc(w: ^World, p: game.Block_Pos, $T: typeid) -> ^T`: the game's record on the machine at p, as the type it declared (Game.machine_data): zero when the machine is built, saved with its chunk.
- `machine_slots :: proc(w: ^World, p: game.Block_Pos) -> []game.Stack`: the machine's inventory (its type's slots; nil: no machine there).
- `machine_kind :: proc(w: ^World, p: game.Block_Pos) -> (game.Block_Type, bool)`: the block type of the machine at p (false: no machine there).
- `machine_wake :: proc(w: ^World, p: game.Block_Pos, ticks: int)`: the machine at p thinks in `ticks` ticks (at least one), unless it is already to think sooner.
- `machine_sleep :: proc(w: ^World, p: game.Block_Pos)`: the machine at p thinks no more until woken.
- `machine_show :: proc(w: ^World, p: game.Block_Pos, value: ^$T)`: what players are shown of the machine at p (the game's Game.machine_shown type: what it makes, its progress, why it stands): sent, when it changes, to every player who has its chunk, and with the chunk to those who get it later (engine.machine_shown).
- `items_made :: proc(s: ^Server, w: ^World, item: game.Item, count: int)`: the game's machines made count of item (a furnace's bar): booked in the item ledger as the game's.
- `items_used :: proc(s: ^Server, w: ^World, item: game.Item, count: int)`: the game's machines used up count of item (the ore a furnace took): booked in the item ledger as the game's.
- `belt_put :: proc(w: ^World, p: game.Block_Pos, item: game.Item) -> bool`: item comes on the belt at p, at its start (false: no belt there, or no room).
- `belt_take :: proc(w: ^World, p: game.Block_Pos) -> (game.Item, bool)`: the front item leaves the belt at p (false: no belt there, or it is empty).
- `belt_peek :: proc(w: ^World, p: game.Block_Pos) -> []game.Lane_Item`: what the belt at p carries, front first (nil: no belt there).
- `grid_open :: proc(w: ^World, kinds: []grid.Kind) -> int`: a grid of the kinds given in w, made of the blocks of those kinds already loaded; its number (grid_parts, grid_part_at).
- `grid_parts :: proc(w: ^World, g: int) -> []^grid.Part`: the parts of w's grid g, by number (temp).
- `grid_part_at :: proc(w: ^World, g: int, p: game.Block_Pos) -> (u32, bool)`: the number of the part of w's grid g the block at p is in (false: none).
- `grid_node :: proc(w: ^World, g: int, p: game.Block_Pos) -> bool`: the block at p is a node of grid g (a machine), not a conductor.
- `route_make :: proc(w: ^World, area: Box, start, goal: game.Block_Pos, kind: game.Kind_Id) -> (Route_Handle, bool)`: a route over area (blocks; at most path.MAX_FIELD_BLOCKS of them) to goal (the block a walker stands in at the end), for walkers of kind, which set out from start.
- `route_free :: proc(w: ^World, h: Route_Handle)`: the route goes; its followers stand.
- `Route_Handle :: distinct u32`: a route of a world's (route_make), shared by every walker that follows it.
- `route_cost :: proc(w: ^World, h: Route_Handle, p: game.Block_Pos) -> (f32, bool)`: what the way to the route's goal costs from p (blocks walked, a climb or a drop a little more); false when there is no way from there.
- `route_reaches :: proc(w: ^World, h: Route_Handle, p: game.Block_Pos) -> bool`: there is a way from p to the route's goal.
- `route_would_shut :: proc(w: ^World, h: Route_Handle, p: game.Block_Pos, block: game.Block) -> bool`: block placed at p would leave the route's start, or a walker following it, with no way to its goal (asked before the block is placed; the route's own field is left as it was).

The types these name:

- `Bulk_Result :: enum u8 {Done, Too_Big, Not_Loaded}`
- `Entity_Iter :: struct {...}`: Entity_Iter walks a snapshot of the entities, lowest id first.
- `Mode_Result :: enum u8 {Ok, Unknown_Mode, Same}`
- `Strike :: enum u8 {Not_Ready, Too_Far, Refused, Hit, Killed}`: what an attack came to.
- `Structure_Fit :: enum u8 {Fits, Not_Loaded, Blocked, Uneven, Out_Of_World}`: whether a structure may stand somewhere (structure_fit).
- `Target :: union {...}`: what a creature attacks: a player, or another entity.
- `base.Var_Error :: enum u8 {None, Unknown_Name, Bad_Value, Out_Of_Range}`
- `game.Block :: enum u16 {...}`
- `game.Block_Pos :: [3]i32`
- `game.Block_Type :: distinct u16`: one block definition (a number per definition, in load order); a Block is a state id, and a type owns a run of them (Type_Def).
- `game.Edit_System :: enum u8 {...}`: the mechanism of a change.
- `game.Entity_Handle :: distinct u32`: Entity_Handle is a generation-checked handle into the store's slots.
- `game.Game_Info :: struct {...}`: what names a game (docs/games.md), declared once in its shared package and taken by both of its parts (core.Game and engine.Game hold it by `using`): its id (its folder's name in games/, what Welcome names), the name players read and a line saying what it is, both in plain English (the launcher's list of games).
- `game.Item :: distinct u16`
- `game.Kind_Id :: distinct u16`: an entity kind, the registry index + 1; 0 is none (and "any" in a filter).
- `game.Lane_Item :: struct {...}`
- `game.Pack_Source :: struct {...}`
- `game.Stack :: struct {...}`: some of one item (count 0: empty, item NO_ITEM).
- `game.Template :: struct {...}`
- `grid.Kind :: struct {...}`
- `grid.Part :: struct {...}`
- `protocol.Game_Kinds :: struct {...}`: the state and event kinds a game replicates besides the engine's (docs/games.md), declared as data in its shared package.
- `protocol.Key :: struct {...}`: an id in a, or a Block_Pos in a, b, c (and a channel id in d for a Cell).

## `server/play` (`play.`): What the games share: `server:play`

- `Phase :: struct($P: typeid) {...}`: where a game's round, match or run is (P: the game's own enum: Waiting, Playing, Results...) and since when, so its clock is one field: phase_seconds and phase_left take a ^Phase as its Clock.
- `Clock :: struct {...}`: the server tick a phase began.
- `phase_set :: proc(s: ^core.Server, p: ^Phase($P), to: P)`: the phase is now `to`, its clock from this tick (again, when it already was: a phase can start over).
- `phase_seconds :: proc(s: ^core.Server, c: ^Clock) -> f64`: seconds since the phase began.
- `phase_left :: proc(s: ^core.Server, c: ^Clock, seconds: f64) -> u16`: whole seconds left of a phase that lasts `seconds` (rounded up, never less than 0): what a countdown on a player's screen shows.
- `configure_flat :: proc(config: ^core.Config, spawn: [3]f64, mode: string)`: a game played on ground of its own: a flat world with nothing wandering into it, arriving at spawn, in mode unless the universe asks for another (the game's configure hook calls it, then changes what it wants otherwise).
- `world_still :: proc(s: ^core.Server, w: ^core.World, clock := 0.5)`: a world a game stages its rounds in, from its start hook: the time stands at clock (0.5: noon), nothing grows or changes by itself and nothing broken drops (no pillaring up with what a blast throws).
- `world_rule :: proc(s: ^core.Server, w: ^core.World, name: string, value: any)`: a world's rule set to a value of any type, as text (core.game_rule).
- `here :: proc(s: ^core.Server, c: ^core.Client) -> bool`: c is playing in the session's home world, where a game stages its rounds.
- `present :: proc(s: ^core.Server) -> (n: int)`: the players here.
- `Arena :: struct {...}`: a walled ground a game builds its rounds on, whole again from a template each round (a seed's layout: game.template_make, game.template_fill), so a round begins as it was laid out whatever the last one's blasts carved.
- `arena_area :: proc(a: Arena) -> core.Box`: the arena's whole box, walls and what is under it: what the game keeps loaded (core.world_keep) and builds in.
- `arena_inside :: proc(a: Arena) -> core.Box`: the inside, floor to sky.
- `arena_build :: proc(s: ^core.Server, w: ^core.World, a: Arena, t: ^game.Template, force: bool) -> (built, loaded: bool)`: the walls, what is under the floor and the template's blocks pasted over the inside, through the edit journal as the game's; false (nothing built) while the area is not all loaded, unless force (the game waited long enough: what is there is built).
- `arena_holds :: proc(a: Arena, p: [3]f64, above := 0.0, below := 0.0) -> bool`: p (a player's feet) is inside the arena's walls, at most `above` blocks over their top and `below` blocks under its floor.
- `watch :: proc(s: ^core.Server, c: ^core.Client, mode: string, at, look: [3]f64, spacing := 2.0)`: c watches what the game is doing rather than playing it (out of a round, come in during one, between matches): in mode (one that flies and is not hurt: the game's pack's), flying at `at`, looking at `look` (a point), its seat's place along x `spacing` blocks from its neighbours', so watchers do not float inside each other.
- `look_at :: proc(from, to: [3]f64) -> [2]f32`: the look (yaw, pitch) of eyes at `from` turned to `to`, as core.teleport takes it.
- `hold :: proc(s: ^core.Server, c: ^core.Client, item: string) -> bool`: c holds the item (by its id, "voxiverse:rocket_launcher") from its hotbar, as if it chose that slot; false when it has none there.
- `settings_command :: proc(s: ^core.Server, c: ^core.Client, table: base.Var_Table, settings: rawptr, node: string, args: []string) -> (handled, changed: bool)`: `/<game> set <name> <value>` sets a setting when c holds the permission node and the value is in its bounds, and says so; `/<game> set` alone tells the settings and how to set them.
- `settings_usage :: proc(table: base.Var_Table) -> string`: every setting as its command takes it, "set frags <1..200> | set time <30..3600>".
- `settings_text :: proc(table: base.Var_Table, settings: rawptr) -> string`: every setting and its value, "frags 15, time 300".
- `settings_save :: proc(table: base.Var_Table, settings: rawptr, out: ^strings.Builder)`: the settings as the universe keeps them (the game's save hook): "name = value" lines, each under its help as a comment.
- `settings_read :: proc(table: base.Var_Table, settings: rawptr, text: string) -> (own: []Saved_Line, ok: bool)`: what the universe kept (the game's load hook), its settings and the game's own lines together: the lines that name a setting are read into settings, and the rest are the game's (own, temp memory), in order.
- `Routes :: struct {...}`: a world's cache of routes to goals over one area (the game's map).
- `routes_get :: proc(s: ^core.Server, w: ^core.World, rs: ^Routes, goal: game.Block_Pos, kind: game.Kind_Id) -> (core.Route_Handle, bool)`: the route to goal for walkers of kind, shared with whoever asked for the same goal before; made when there is none, the least recently used one let go when the cache or the world is full.
- `routes_free :: proc(w: ^core.World, rs: ^Routes)`: routes_free lets every route of the cache go (a match's end).
- `SQUAD_ROUTES :: 12`: routes a cache keeps at most (the world holds core.MAX_ROUTES)
- `formation :: proc(s: ^core.Server, w: ^core.World, goal: game.Block_Pos, n: int, spacing: i32 = 1) -> []game.Block_Pos`: n places around goal (the block a walker stands in), `spacing` blocks apart on a square spiral out from it, each on ground a walker stands on, nearest first (in the temp allocator; fewer when the ground runs out within a reach of n * spacing).
- `formation_assign :: proc(w: ^core.World, units: []game.Entity_Handle, places: []game.Block_Pos)`: which place each walker takes (places[i] is units[i]'s, in place): the walkers sorted by their distance to the goal, the nearest given the nearest place, so the front of a column fills the middle and nobody crosses the whole crowd.
- `march :: proc(w: ^core.World, h: game.Entity_Handle, place: game.Block_Pos, route: core.Route_Handle) -> bool`: one tick of a walker making for its place: along the route while further than MARCH_NEAR (and the route reaches it), by its own path for the rest; true once there (it stands).
- `place_point :: proc(p: game.Block_Pos) -> [3]f64`: where a walker stands in block p (the bottom centre).
- `standable :: proc(s: ^core.Server, w: ^core.World, p: game.Block_Pos) -> bool`: a walker one block wide and two high stands in block p: solid under it, nothing in it or over it (blocks not loaded are not).
- `ground_at :: proc(s: ^core.Server, w: ^core.World, x, y, z: i32, depth: i32 = 4) -> (game.Block_Pos, bool)`: the block a walker stands in at column (x, z), searching from y down to y - depth and up to y + depth for the nearest that is standable.
- `foe_nearest :: proc(w: ^core.World, h: game.Entity_Handle, radius: f64) -> game.Entity_Handle`: the nearest living entity within radius of h that is on a team other than its own (and on one: no team is nobody's foe), 0 for none.
- `fight :: proc(w: ^core.World, h, foe: game.Entity_Handle, reach: f32) -> (struck, killed: bool)`: one tick of a fighter at a foe: it keeps within its reach of it (closing in by its own path) and strikes when its attack is ready (core.entity_strike, its kind's damage and cooldown; whether it struck, and whether the foe died of it).
- `By_Name :: struct($T: typeid, $N: int) {...}`: what a game keeps of each player across sessions, by the player's name (a racer's best, a hero's level, a commander's wins): at most N rows of the game's T, found or made by name, written to the universe's game.cfg as `<key> = <T's numbers> <name>` lines (the game says how T is written and read: its numbers, in order) and read back from the lines settings_read handed the game.
- `Named :: struct($T: typeid) {...}`: one row of a By_Name: a player's name and the game's T for it (its fields are the row's own, by `using`).
- `by_name :: proc(t: ^By_Name($T, $N), name: string, make_it := false) -> ^Named(T)`: the row of a name (made zero when make_it and there is room; nil otherwise).
- `by_name_rows :: proc(t: ^By_Name($T, $N)) -> []Named(T)`: the rows kept, in the order they were first made.
- `named_name :: proc(r: ^Named($T)) -> string`: whose a row is.
- `by_name_save :: proc(t: ^By_Name($T, $N), key: string, out: ^strings.Builder, write: proc(b: ^strings.Builder, v: ^T) -> bool)`: a line a row, `<key> = <numbers> <name>`; write gives a row's numbers (space-separated) and may skip it (false: nothing worth keeping).
- `by_name_read :: proc(t: ^By_Name($T, $N), key: string, line: Saved_Line, read: proc(fields: []string, v: ^T) -> bool) -> bool`: one saved line of the key read into its name's row: its fields but the last (the name) given to read, which judges them (out of bounds: false).
- `Saved_Line :: struct {...}`: a line of what a game keeps with the universe (game.cfg): its key, the first word (or what stands before an `=`), and the rest, trimmed: "best = 12" and "hero 3 140 7 ana" are {"best", "12"} and {"hero", "3 140 7 ana"}.
- `saved_lines :: proc(text: string) -> []Saved_Line`: the text's lines as keys and values (temp memory), blank lines and `#` comments left out.

The types these name:

- `base.Var_Table :: struct {...}`
- `core.Box :: struct {...}`: lo..hi inclusive.
- `core.Client :: struct {...}`: one connection to the server, and once it is playing, a player: its seat, its world, its player and inventory.
- `core.Config :: struct {...}`: what a server session is started with (start): the universe, its worlds' defaults, the game it plays; a game's configure hook may change it.
- `core.Route_Handle :: distinct u32`: a route of a world's (route_make), shared by every walker that follows it.
- `core.Server :: struct {...}`: a session of the universe: its config, worlds, clients and tick, what every hook of a game is given.
- `core.World :: struct {...}`: one voxel space of the universe, loaded (docs/glossary.md): its address, rules, clock, chunks and entities.
- `game.Block_Pos :: [3]i32`
- `game.Entity_Handle :: distinct u32`: Entity_Handle is a generation-checked handle into the store's slots.
- `game.Kind_Id :: distinct u16`: an entity kind, the registry index + 1; 0 is none (and "any" in a filter).
- `game.Template :: struct {...}`

## `client/engine` (`engine.`): What a game's client part calls

- `Session :: struct {...}`: the client playing on one server, its own or another's: the connection, the world as it was told it, the player, and the game's client part and its state.
- `game_state :: proc(s: ^Session, $T: typeid) -> ^T`: the session's state of its game, as the type the game declared (Game.state).
- `game_value :: proc(s: ^Session, r: protocol.Received, $T: typeid) -> (value: ^T, ok: bool)`: r's value as T, when r is of the game's kind whose value type is T (ok); nil for a removal (r.op == .Remove, r.key says which).
- `game_screen_open :: proc(s: ^Session)`: game_screen_open opens the game's screen (a game without a screen hook has none).
- `game_screen_close :: proc(s: ^Session)`: game_screen_close closes the game's screen (closed: nothing to do).
- `game_screen_shown :: proc(s: ^Session) -> bool`: the game's screen is open.
- `game_action_key :: proc(s: ^Session, index: int) -> string`: the name of the key the player has bound to the game's action `index` (into Game.actions), as their keyboard prints it ("Z"; "(none)" when unbound), for a HUD to say which key does what.
- `game_action_pressed :: proc(s: ^Session, index: int) -> bool`: the key of the game's action `index` was pressed this frame, wherever the keyboard is (over the world or the game's own screen: the key that opened a screen may close it).
- `game_key_pressed :: proc(s: ^Session, index: int) -> bool`: the game's own key `index` (into Game.keys) went down this frame, while the world has the keyboard.
- `game_key_down :: proc(s: ^Session, index: int) -> bool`: the game's own key `index` is held, while the world has the keyboard.
- `game_key_label :: proc(s: ^Session, index: int) -> string`: the name of the game's own key `index` as the player's keyboard prints it ("" for a key the game has not).
- `Game_Key :: struct {...}`: one of a game's own keys: what it does (shown in the controls under the game's name and in the controls' words of the game's HUD) and the key that does it until the player binds another.
- `MAX_GAME_KEYS :: 32`: the keys a game's client part may declare (Game.keys).
- `Command_Spec :: struct {...}`: what console_register is given (the rest apart).
- `Game_Camera :: struct {...}`: the camera a game wants this frame.
- `Game_Camera_Kind :: enum u8 {Player, First, Third, Top_Down, Free}`: which camera a game's client part chooses (Game.camera).
- `pointer_tool :: proc(s: ^Session) -> ^Pointer_Tool`: what the free pointer is over and its buttons this frame (all zero with any other camera).
- `Pointer_Tool :: struct {...}`: what the free pointer is over and does (pointer_tool).
- `Pointer_Press :: struct {...}`: one button of the pointer this frame.
- `Scoreboard :: struct {...}`: a game's table of its players, shown by the player list while its key is held (client/hud): a title, the headings of its columns after the name's, and a row for each player, in the order the game gives (the game sorts).
- `SCOREBOARD_COLUMNS :: 4`: the most columns a game's scoreboard has besides the name.
- `scoreboard_columns :: proc(board: ^Scoreboard, headings: ..string)`: the board's headings after the name's (at most SCOREBOARD_COLUMNS).
- `scoreboard_row :: proc(board: ^Scoreboard, name: string, cells: ..string, you := false)`: a row, after those there are: a name and its cells, in the columns' order; you: the player's own.

The types these name:

- `protocol.Received :: struct {...}`

## `client/engine` (`engine.`): What a game's HUD is made of

- `top_bar :: proc(ctx: ^ui.Context, rest: ^ui.Rect, text: string)`: a line of text centred across the top of rest, on the HUD's backing, cut from rest (what is under it is left for the rest of the HUD).
- `banner :: proc(ctx: ^ui.Context, at: f32, text: string, scale: f32, color: ui.Color)`: a line of big text across the screen, its middle `at` pixels from the screen's (negative: above it), `scale` times the title's size, with a shadow.
- `Flash :: struct {...}`: a banner shown for a while, kept in the game's view (it outlives the frame its news came in).
- `flash :: proc(f: ^Flash, s: ^Session, text: string, tone := Tone.Plain, seconds := FLASH_SECONDS)`: show text as a banner from now for seconds (it replaces the one shown).
- `flash_draw :: proc(ctx: ^ui.Context, f: ^Flash, s: ^Session, at: f32 = -160, scale: f32 = 1)`: the flash, while it stands, as a banner at `at` (banner's).
- `Tone :: enum u8 {Plain, Good, Warn, Bad}`: what a flash's news is, which colours it.
- `world_point :: proc(s: ^Session, ctx: ^ui.Context, p: [3]f64) -> (at: [2]f32, ok: bool)`: where p in the world is on the screen this frame (UI units); false behind the eyes, farther than MARK_DISTANCE, or with no view yet.
- `world_label :: proc(s: ^Session, ctx: ^ui.Context, p: [3]f64, text: string) -> bool`: text on a dark plate over p, as players' names are.
- `world_bar :: proc(s: ^Session, ctx: ^ui.Context, p: [3]f64, fraction: f32) -> bool`: a bar over p, full to `fraction` (0..1), in the theme's health colours.
- `entity_place :: proc(s: ^Session, id: u32) -> (at: [3]f64, ok: bool)`: where the session shows an entity now (false: not known, or not yet placed).
- `entity_top :: proc(s: ^Session, id: u32) -> (at: [3]f64, ok: bool)`: the point just over an entity the session shows (its box's top, lifted by ENTITY_MARK_LIFT), where its marks go; false: not known, or not yet placed.
- `entity_label :: proc(s: ^Session, ctx: ^ui.Context, id: u32, text: string, rows: f32 = 0) -> bool`: text on a plate over an entity (a name kept in a game's record keyed by the entity: game.key_entity), `rows` plates higher (0: just over it; a bar's height is a third of a row); false when it is not shown.
- `entity_bar :: proc(s: ^Session, ctx: ^ui.Context, id: u32) -> bool`: an entity's health bar over it, hurt or not (entity_bars puts one over every hurt one of a kind); false when it is not shown or has no health.
- `entity_bars :: proc(s: ^Session, ctx: ^ui.Context, kind: game.Kind_Id = 0, always := false)`: a health bar over every entity the session knows of a kind (0: any) whose health is below its most (all of them with `always`), just over its box.
- `world_box :: proc(s: ^Session, lo, hi: game.Block_Pos, color: [4]u8)`: an outline of the blocks lo..hi drawn in the world this frame (at most MAX_WORLD_BOXES; more are not drawn).
- `ground_fill :: proc(s: ^Session, lo, hi: game.Block_Pos, color: [4]u8)`: a translucent cover over the ground of the blocks lo..hi (x and z; each column's cover lies on its highest solid block between lo.y and hi.y): a zone, a road's reach, a heat map.
- `ground_outline :: proc(s: ^Session, lo, hi: game.Block_Pos, color: [4]u8)`: the edge of the rectangle lo..hi drawn on the ground (each side's segments at their columns' tops), in lines.
- `structure_ghost :: proc(s: ^Session, t: ^game.Template, at: game.Block_Pos, rotation: u8, color: [4]u8)`: a template's blocks (not its void or air) placed with its lowest corner at `at`, turned rotation quarter turns, drawn as translucent blocks: what a placement would build, tinted (green for allowed, red for not: the game's colour).
- `ground_top :: proc(s: ^Session, x, z, lo, hi: i32) -> (block: game.Block, top: i32, ok: bool)`: the highest solid block of column (x, z) from hi down to lo, as the session holds the world: what it is and the y of its top; false when there is none there, or the column is not loaded (a minimap's colour, a fog's height).
- `ground_quad :: proc(s: ^Session, a, b, c, d: [3]f64, color: [4]u8) -> bool`: a translucent quad of the world's (its corners in order), drawn this frame with the ground marks (a fog's cell over its ground, a minimap's view): false when the frame has MAX_FILL_VERTICES already.
- `block_colour :: proc(s: ^Session, b: game.Block) -> [4]u8`: b's look in one colour (the average of its side): a minimap's ground.
- `machine_shown :: proc(s: ^Session, p: game.Block_Pos, $T: typeid) -> ^T`: what the game's machine at p shows, as the game's type (Game.machine_shown), as its server part last said; nil where the session holds no machine (none there, its chunk not here, or it never showed anything).
- `puff_add :: proc(s: ^Session, p: Puff)`: puff_add adds p, unless there are MAX_PUFFS already (then it is dropped: effects are not worth growing memory for).
- `game_request :: proc(s: ^Session, value: ^$T)`: game_request sends the game's server part one of its requests (Game_Kinds.requests: value of the request kind's type), after the last input sent; the server checks it and its request hook judges it.
- `Seats :: struct($T: typeid) {...}`: what a game's client part keeps of each player from a record of its kind T keyed by the player (protocol.key_player), by seat: the last value told and its name (T's `name`, copied out of the message it came in, so the value's name stays good), forgotten when the server stops putting it.
- `seats_received :: proc(s: ^Session, seats: ^Seats($T), r: protocol.Received) -> bool`: r kept in seats when it is a record of T (its key a player's seat); true when it was one.
- `seat_mine :: proc(s: ^Session, seats: ^Seats($T)) -> ^T`: the session's own player's value (zero until told).
- `seats_ranked :: proc(seats: ^Seats($T), before: proc(a, b: ^T) -> bool) -> []int`: the seats told of, ordered by before (ties by name), as player ids (temp memory): a scoreboard's rows.

The types these name:

- `Puff :: struct {...}`: a particle, a piece of something (a dying entity, debris, smoke, flame) flying out and falling, or drifting and slowing.
- `Session :: struct {...}`: the client playing on one server, its own or another's: the connection, the world as it was told it, the player, and the game's client part and its state.
- `game.Block :: enum u16 {...}`
- `game.Block_Pos :: [3]i32`
- `game.Kind_Id :: distinct u16`: an entity kind, the registry index + 1; 0 is none (and "any" in a filter).
- `game.Template :: struct {...}`
- `protocol.Received :: struct {...}`
- `ui.Color :: [4]u8`
- `ui.Context :: struct {...}`
- `ui.Rect :: struct {...}`

## `client/overview` (`overview.`): Commanding from above: `client:overview`

- `Selection :: struct {...}`: the entities of its side a player has picked, its control groups, and the click or drag in progress.
- `selection_update :: proc(sel: ^Selection, s: ^engine.Session, ctx: ^ui.Context, team: u8) -> bool`: the free pointer's primary button picks this frame (the game's HUD calls it each frame, after drawing what takes clicks first: its panels): a click, a double click, a box.
- `selection_draw :: proc(sel: ^Selection, ctx: ^ui.Context)`: the box being dragged, outlined on the HUD.
- `selected :: proc(sel: ^Selection) -> []u32`: the ids picked, in the order they were.
- `is_selected :: proc(sel: ^Selection, id: u32) -> bool`: whether id is picked.
- `selection_add :: proc(sel: ^Selection, id: u32)`: id picked (nothing when it is already, or the set is full).
- `selection_remove :: proc(sel: ^Selection, id: u32)`: id no longer picked.
- `selection_clear :: proc(sel: ^Selection)`: nothing picked (the groups are kept).
- `selection_prune :: proc(sel: ^Selection, s: ^engine.Session, team: u8)`: the entities the session no longer knows, or no longer of the side, fall out of the set and of every group.
- `group_keep :: proc(sel: ^Selection, n: int)`: the picked set kept as group n.
- `group_pick :: proc(sel: ^Selection, n: int) -> bool`: group n picked again (false: it is empty).
- `MAX_GROUPS :: 10`: control groups (0 to 9)
- `small_marks :: proc(s: ^engine.Session, ctx: ^ui.Context, min_pixels: f32, colors: [][4]u8)`: a square of its team's colour (colors, by team) over every entity the session knows whose body is drawn shorter than min_pixels on the screen (a soldier at the overview's height), so the far ones read as units, not specks.
- `rings_draw :: proc(sel: ^Selection, s: ^engine.Session, radius: f64, color: [4]u8)`: a ring on the ground under each picked entity (radius: blocks), coloured.
- `ring_draw :: proc(s: ^engine.Session, id: u32, radius: f64, color: [4]u8)`: one entity's ring.
- `Fog :: struct {...}`: the fog of war over a game's map as one side sees it (fog_init, fog_update, fog_draw).
- `fog_init :: proc(f: ^Fog, lo, hi: [2]i32, y_lo, y_hi: i32, allocator := context.allocator, loc := #caller_location) -> mem.Allocator_Error`: a fog over the map lo..hi (x, z) whose ground lies between y_lo and y_hi, its cells allocated (the session's arena, with the game's state).
- `fog_update :: proc(f: ^Fog, s: ^engine.Session, team: u8)`: what the side sees this frame, from every entity of its team the session knows and its vision; what it sees is explored for good.
- `fog_draw :: proc(f: ^Fog, s: ^engine.Session, unseen, unexplored: [4]u8)`: the ground the side does not see darkened (`unseen`), and the ground it never saw more so (`unexplored`): a quad a cell, on its ground.
- `fog_sees :: proc(f: ^Fog, x, z: f64) -> bool`: the side sees the point now (on the map).
- `fog_explored :: proc(f: ^Fog, x, z: f64) -> bool`: the side has seen the point (on the map).
- `Minimap :: struct {...}`: a game's map from above in a corner of the HUD, its ground read from the world a few rows a frame (minimap_init, minimap_ground, minimap_draw).
- `Mark :: struct {...}`: a dot of the game's on the minimap.
- `minimap_init :: proc(m: ^Minimap, lo, hi: [2]i32, y_lo, y_hi: i32, cell: i32 = 2, allocator := context.allocator, loc := #caller_location) -> bool`: a minimap of the map lo..hi (x, z), its ground between y_lo and y_hi, in cells of `cell` blocks (the session's arena, with the game's state).
- `minimap_ground :: proc(m: ^Minimap, s: ^engine.Session)`: a few rows of the ground's colours read from the world again.
- `minimap_draw :: proc(m: ^Minimap, s: ^engine.Session, ctx: ^ui.Context, r: ui.Rect, fog: ^Fog, marks: []Mark, unseen, unexplored: [4]u8) -> (at: [2]f64, pointed: bool)`: the minimap in r: its ground, the fog of the side (nil: none), the game's marks, and the camera's focus framed.
- `minimap_jump :: proc(s: ^engine.Session, at: [2]f64, height: f64)`: the camera's focus moved to a point of the map (the player's own place, asked of the server as any move is; height: the y to stand it at).

The types these name:

- `engine.Session :: struct {...}`: the client playing on one server, its own or another's: the connection, the world as it was told it, the player, and the game's client part and its state.
- `ui.Context :: struct {...}`
- `ui.Rect :: struct {...}`
