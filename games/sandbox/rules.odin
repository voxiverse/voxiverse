package sandbox

import "common:game"

// Sandbox: the engine's open world as a game. A universe of planets, the home world
// Earth or one made from the seed, its climate, animals and peoples; build, fly between
// worlds through gates, survive or create. It has no round and no score: what the
// engine's world does is the game.
//
// This is its shared package: what both of its sides use. The server part
// (games/sandbox/server) chooses the world (its configure); the client part
// (games/sandbox/client) is there so a session can play it.

// INFO: the game's id, name and description, for both of its parts (the launcher
// lists it by them).
INFO :: game.Game_Info {
	id          = "sandbox",
	name        = "Sandbox",
	description = "An open world of planets: build, explore, survive or create.",
}
