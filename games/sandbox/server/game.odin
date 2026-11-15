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

// configure: a new world is made by the Earth generator (continents, biomes, rivers,
// caves, trees); whether the home world is Earth itself or one made from the seed is the
// caller's (Config.earth), as are the mode, the spawn and whether animals appear by
// themselves. A saved world keeps its own generator.
configure :: proc(config: ^core.Config) {
	config.generator = .Earth
}

#assert(worldgen.Kind.Earth == {}, "the Earth generator is the zero kind (an unset Config's)")
