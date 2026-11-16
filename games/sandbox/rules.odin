package sandbox

import "common:game"

// Sandbox: the engine's open world as a game. A universe of planets, the home world
// Earth or one made from the seed, its climate, animals and peoples; build, fly between
// worlds through gates, survive or create. It has no round and no score: what the
// engine's world does is the game.
//
// This is its shared package: what both of its sides use (its pack, the sheep's genetics,
// the peoples' history and the markets' model, its records and its text). The server part
// (games/sandbox/server) chooses the world (its configure), keeps the sheep and runs the
// markets; the client part (games/sandbox/client) shows a town's market.

// INFO: the game's id, name and description, for both of its parts (the launcher
// lists it by them).
INFO :: game.Game_Info {
	id          = "sandbox",
	name        = "Sandbox",
	description = "An open world of planets: build, explore, survive or create.",
}

// SHEEP_KIND: the sheep, its pack's creature (games/sandbox/server/sheep.odin).
SHEEP_KIND :: "sandbox:sheep"
