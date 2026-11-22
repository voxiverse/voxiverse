package sandbox_server

import "common:base"
import "common:game"
import "common:worldgen"
import "games:sandbox"
import "server:core"

// Sandbox's server part (the game: games/sandbox): it chooses the world the engine runs,
// keeps its sheep (sheep.odin: their minds, shearing and feeding, their statistics) and the
// economy of a world built on the planet (economy.odin: its towns' markets; trader.odin: the
// player as a trader; interventions.odin: what players did that the world's history carries
// forward). The rest of that world (worlds and gates, climate, farming) is the engine's,
// chosen by the config.

GAME :: core.Game {
	info           = sandbox.INFO,
	kinds          = sandbox.KINDS,
	pack           = sandbox.PACK,
	server_state   = Sandbox,
	entity_data    = Sheep,
	character_data = Trader_Record,
	world_state    = Sandbox_World,
	world_files    = {
		{name = ECONOMY_FILE, check = economy_check},
		{name = INTERVENTIONS_FILE, check = interventions_check},
	},
	stats          = {
		{name = "sheep.sheared", kind = .Count, xp = 5},
		{name = "sheep.fed", kind = .Count, xp = 2},
		{name = "sheep.born", kind = .Count},
	},
	configure      = configure,
	start          = start,
	tick           = economy_tick,
	think          = think,
	spawned        = spawned,
	joined         = trader_joined,
	action         = action,
	request        = request,
	entity_use     = entity_use,
	entity_hurt    = entity_hurt,
	command        = command,
	world_opened   = world_opened,
	world_closed   = world_closed,
	world_save     = world_save,
}

// Sandbox: the session's state: the sheep's randomness and the registry's names they use.
Sandbox :: struct {
	rng:              base.Rng,
	sheep:            game.Kind_Id,
	grass, dirt:      game.Block,
	wheat:            game.Item,
	wool, black_wool: game.Item,
	placed:           int, // sheep the command has set down (each a little further along)
}

state :: proc(s: ^core.Server) -> ^Sandbox {return core.game_state(s, Sandbox)}

// start: the names the sheep use, from the session's registry; their randomness from
// the universe's seed.
start :: proc(s: ^core.Server) -> bool {
	g := state(s)
	reg := s.registry
	g.rng = base.rng_make(u64(s.config.seed) ~ 0x5ee9_5ee9)
	g.sheep = game.registry_kind(reg, sandbox.SHEEP_KIND) or_return
	g.grass = game.registry_block(reg, "grass") or_return
	g.dirt = game.registry_block(reg, "dirt") or_return
	g.wheat = game.registry_item(reg, "wheat") or_return
	g.wool = game.item_of_block(reg, game.registry_block(reg, "wool") or_return)
	g.black_wool = game.item_of_block(reg, game.registry_block(reg, "black_wool") or_return)
	return true
}

// KIT: what a player new to a sandbox universe is given: the rocket launcher alone, in
// hotbar slot 1 (blocks come from creative's catalog; how survival gathers is the
// world's to decide). A universe keeps the kit it was made with (universe.cfg).
KIT :: "rocket_launcher 1"

// configure: a new world is made by the Earth generator (continents, biomes, rivers,
// caves, trees), a new universe's home world has a dead gate in front of its spawn (what
// wakes it is not decided yet: core.gate_wake is the call), and new players are given KIT
// unless the caller names a kit; whether the home world is Earth itself or one made from
// the seed is the caller's (Config.earth), as are the mode, the spawn and whether animals
// appear by themselves. A saved world keeps its own generator, gates and kit.
configure :: proc(config: ^core.Config) {
	config.generator = .Earth
	config.home_gate = true
	if config.kit == "" {config.kit = KIT}
}

#assert(worldgen.Kind.Earth == {}, "the Earth generator is the zero kind (an unset Config's)")

// world_opened: a world's interventions log and economy file are read back.
world_opened :: proc(s: ^core.Server, w: ^core.World) {
	interventions_load(w)
	economy_load(w)
}

// world_closed: what the sandbox made of a world is freed (its economy's build waited for).
world_closed :: proc(s: ^core.Server, w: ^core.World) {
	sw := world_of(w)
	economy_free(sw)
	interventions_destroy(&sw.interventions)
}

// world_save: a world's files, those that changed, in the save's transaction.
world_save :: proc(s: ^core.Server, w: ^core.World) {
	interventions_write(w)
	economy_write(w)
}

// action: the game's one action (its client part's MARKET_ACTION) asks for the market.
action :: proc(s: ^core.Server, c: ^core.Client, index: int) {
	if index == sandbox.MARKET_ACTION {market_ask(s, c)}
}

// request: a trade in the town the player stands in.
request :: proc(s: ^core.Server, c: ^core.Client, r: core.Request) {
	if t, ok := core.request_value(s, r, sandbox.Trade); ok {market_trade(s, c, t^)}
}

// command: `/sheep [lamb] [shorn] [black] [spotted]` sets a sheep of those looks down in
// front of the player (north of it, each further along; the summoning permission);
// `/interventions [radius]` lists the world's interventions (interventions.odin); `/town`
// takes the player to the nearest town with a market (trader.odin); `/showroom <family>`
// sets every material of a family up to look at (showroom.odin).
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name == "interventions" {return interventions_command(s, c, args)}
	if name == "showroom" {return showroom_command(s, c, args)}
	if name == "town" && len(args) == 0 {return town_command(s, c)}
	if name != "sheep" {return false}
	if !core.allowed(s, c, "world.summon") {
		core.notice(s, c, "You may not summon here")
		return true
	}
	g := state(s)
	d := Sheep{}
	for a in args {
		switch a {
		case "lamb":
			d.grows = sandbox.LAMB_TICKS
		case "shorn":
			d.shorn = true
		case "black":
			d.genes += sandbox.WOOL_BLACK
		case "spotted":
			d.genes += sandbox.COAT_SPOTTED
		case:
			core.notice(s, c, "Usage: sheep [lamb] [shorn] [black] [spotted]")
			return true
		}
	}
	at := c.player.position + {f64(g.placed % 5) * 1.5 - 3, 0, -4}
	g.placed += 1
	h := core.entity_spawn(c.world, g.sheep, at, false)
	if h == 0 {
		core.notice(s, c, "The world is full")
		return true
	}
	sheep(s, c.world, h)^ = d
	show(c.world, h, sheep(s, c.world, h))
	return true
}
