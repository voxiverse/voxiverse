package sandbox_client

import "client:engine"
import "games:sandbox"

// Sandbox's client part (the game: games/sandbox): the engine's HUD is the game's, and its
// own is the market of a town on a planet world (market.odin): a line while the player
// stands in a town and the market's screen, which its action (MARKET_ACTION) opens there.

GAME :: engine.Game {
	info     = sandbox.INFO,
	kinds    = sandbox.KINDS,
	state    = View,
	actions  = {"Market"}, // (MARKET_ACTION)
	received = received,
	hud      = hud,
	screen   = market_screen,
}

// View: what the client part keeps: the market the server last put and what its screen
// has chosen.
View :: struct {
	market: Market_Screen,
}

MARKET_ACTION :: 0 // the market's action: its index in GAME.actions

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}
