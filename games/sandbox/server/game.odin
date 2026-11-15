package sandbox_server

import "common:worldgen"
import "games:sandbox"
import "server:core"

// Sandbox's server part (the game: games/sandbox): it chooses the world the engine runs
// and leaves the rest to the engine. Every system of that world (worlds and gates,
// climate, animals, farming, the market) is the engine's, chosen by the config.

GAME :: core.Game {
	info      = sandbox.INFO,
	configure = configure,
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
