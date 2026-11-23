package sandbox

import "common:game"

// Sandbox: the engine's open world as a game, and the one game players are offered: the
// title's Singleplayer plays its universes, and players know it by the product's name,
// Voxiverse (INFO.name; the id, the folder and what saves and the wire say stay
// "sandbox"). A universe of planets, the home world Earth or one made from the seed, its
// climate, animals and peoples; build, fly between worlds through gates, survive or
// create, and come upon the other games as encounters in the world (the ruin's waves are
// Horde's). It has no round and no score: what the engine's world does is the game.
//
// This is its shared package: what both of its sides use (its pack, the sheep's genetics,
// the markets' model on the peoples' history of common/planet, its records and its text). The server part
// (games/sandbox/server) chooses the world (its configure), keeps the sheep and runs the
// markets; the client part (games/sandbox/client) shows a town's market.

// INFO: the game's id, name and description, for both of its parts (its name heads the
// loading screen and the game menu, and names a server's game in Multiplayer).
INFO :: game.Game_Info {
	id          = "sandbox",
	name        = "Voxiverse",
	description = "An open world of planets: build, explore, survive or create.",
}

// SHEEP_KIND: the sheep, its pack's creature (games/sandbox/server/sheep.odin).
SHEEP_KIND :: "sandbox:sheep"
