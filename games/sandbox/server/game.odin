package sandbox_server

import "common:base"
import "common:game"
import "common:worldgen"
import "games:sandbox"
import "server:core"

// Sandbox's server part (the game: games/sandbox): it chooses the world the engine runs
// and keeps its sheep (sheep.odin: their minds, shearing and feeding, their statistics).
// Every other system of that world (worlds and gates, climate, farming, the market) is
// the engine's, chosen by the config.

GAME :: core.Game {
	info         = sandbox.INFO,
	pack         = sandbox.PACK,
	server_state = Sandbox,
	entity_data  = Sheep,
	stats        = {
		{name = "sheep.sheared", kind = .Count, xp = 5},
		{name = "sheep.fed", kind = .Count, xp = 2},
		{name = "sheep.born", kind = .Count},
	},
	configure    = configure,
	start        = start,
	think        = think,
	spawned      = spawned,
	entity_use   = entity_use,
	entity_hurt  = entity_hurt,
}

// Sandbox: the session's state: the sheep's randomness and the registry's names they use.
Sandbox :: struct {
	rng:              base.Rng,
	sheep:            game.Kind_Id,
	grass, dirt:      game.Block,
	wheat:            game.Item,
	wool, black_wool: game.Item,
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
// caves, trees) and new players are given KIT unless the caller names a kit; whether the
// home world is Earth itself or one made from the seed is the caller's (Config.earth),
// as are the mode, the spawn and whether animals appear by themselves. A saved world
// keeps its own generator and kit.
configure :: proc(config: ^core.Config) {
	config.generator = .Earth
	if config.kit == "" {config.kit = KIT}
}

#assert(worldgen.Kind.Earth == {}, "the Earth generator is the zero kind (an unset Config's)")
