package sandbox_client

import "client:engine"
import "games:sandbox"

// Sandbox's client part (the game: games/sandbox): the engine's HUD is the game's, so
// it adds nothing; it is there so a client can play the sandbox (a session plays the
// game its server names only if it has that game's client part).

GAME :: engine.Game {
	info = sandbox.INFO,
}
