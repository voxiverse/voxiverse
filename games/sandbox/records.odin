package sandbox

import "common:protocol"

// What the sandbox tells its players besides the engine's kinds (docs/games.md), and what
// they ask of it: the market of the town a player stands in, a trade there, why a trade
// was refused, and the market's screen opened by the player's action.

MAX_TOWN_NAME :: 32

// Town_Market: the market of the town the player stands in, as the server holds it (one per
// player; `town` empty: in no town). Put when the player arrives, again when what it shows
// changes (looked at once a second) and as the answer to a trade.
Town_Market :: struct {
	town:  string `net:"max=32"`,
	cash:  f64, // the player's silver
	goods: [Good]Town_Good,
}

// Town_Good: one good in the town: its price in silver per unit, the units in stock, the
// player's cargo of it, and the age in days of the news behind the price (-1: none).
Town_Good :: struct {
	deals: bool, // the town trades in it
	price: f32,
	stock: f32,
	cargo: f32,
	age:   f32,
}

// Trade (a request): buy or sell `quantity` units (a person's month of the good) of a good
// in the town the player stands in; the server knows which, and answers with the market,
// or a Trade_Refused.
Trade :: struct {
	good:     Good,
	sell:     bool,
	quantity: f32,
}

// Refusal: why a trade was refused.
Refusal :: enum u8 {
	None,
	No_Economy, // the world has no detailed market there
	Bad_Quantity,
	Away, // not within the town's radius
	No_Market, // the town does not trade in the good
	No_Cash,
	No_Cargo,
	No_Stock, // the market has too little to sell
}

// Trade_Refused (an event): the player's last trade was refused, and why.
Trade_Refused :: struct {
	reason: Refusal,
}

// Market_Open (an event): the player asked for the market (its action) standing in a town.
Market_Open :: struct {
	town: string `net:"max=32"`,
}

// Ruin_Phase: where the ruined site's fight is (games/sandbox/server/ruin.odin).
Ruin_Phase :: enum u8 {
	Asleep, // nobody fights: its altar wakes it
	Countdown, // woken, the ward up, the first wave on its way
	Wave, // the creatures come
	Break, // between waves
}

// Ruin_Fight: the fight a player is locked in at the ruined site (one per player; phase
// Asleep: it fights none).
Ruin_Fight :: struct {
	phase:   Ruin_Phase,
	wave:    u8, // on now, or the last held
	waves:   u8, // the fight's
	alive:   u16, // creatures out
	to_come: u16, // ... still to come out of the lairs
	left:    u16, // seconds left of the countdown or the break
}

KINDS :: protocol.Game_Kinds {
	states   = {
		{name = "sandbox.market", value = Town_Market},
		{name = "sandbox.ruin", value = Ruin_Fight},
	},
	events   = {
		{name = "sandbox.trade_refused", value = Trade_Refused},
		{name = "sandbox.market_open", value = Market_Open},
	},
	requests = {{name = "sandbox.trade", value = Trade}},
}

// MAX_TRADE_QUANTITY: the most units one trade may move.
MAX_TRADE_QUANTITY :: 1e6

// MARKET_ACTION: the game's action that opens the market (its client part's actions).
MARKET_ACTION :: 0
