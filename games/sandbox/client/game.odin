package sandbox_client

import "client:engine"
import "client:ui"
import "games:sandbox"

// Sandbox's client part (the game: games/sandbox): the engine's HUD is the game's, and its
// own is the market of a town on a planet world (market.odin): a line while the player
// stands in a town and the market's screen, which its action (MARKET_ACTION) opens there;
// and the ruined site's fight while the player is locked in it (ruin.odin).

GAME :: engine.Game {
	info     = sandbox.INFO,
	kinds    = sandbox.KINDS,
	state    = View,
	actions  = {"Market", "Craft", "Use"}, // (sandbox.MARKET_ACTION, CRAFT_ACTION, USE_ACTION)
	received = received,
	hud      = hud,
	screen   = screen,
}

// View: what the client part keeps: the market the server last put and what its screen
// has chosen, and the ruin's fight.
View :: struct {
	market: Market_Screen,
	ruin:   sandbox.Ruin_Fight,
	craft:  Craft_Screen,
	screen: Screen, // which the game's screen shows while open
}

// Screen: the game's screens.
Screen :: enum u8 {
	Market,
	Craft,
}

// screen: the game's screen (engine.Game.screen): the market or the crafting screen.
screen :: proc(s: ^engine.Session, ctx: ^ui.Context, top: bool) {
	switch view(s).screen {
	case .Market:
		market_screen(s, ctx, top)
	case .Craft:
		craft_screen(s, ctx, top)
	}
}

MARKET_ACTION :: sandbox.MARKET_ACTION // the market's action: its index in GAME.actions

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}
