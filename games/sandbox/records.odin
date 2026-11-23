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
// Asleep: it fights none), and where the site is once it has been found (built: a player
// came near it) in the world the player is in (the journal's place: found false, none).
Ruin_Fight :: struct {
	phase:   Ruin_Phase,
	wave:    u8, // on now, or the last held
	waves:   u8, // the fight's
	alive:   u16, // creatures out
	to_come: u16, // ... still to come out of the lairs
	left:    u16, // seconds left of the countdown or the break
	found:   bool,
	site:    [3]i32, // the altar's block
}

// Outpost_Line: an outpost as a player is shown it: where its beacon stands, whether the
// player placed it and whether it stands there again after a death there (its respawn).
Outpost_Line :: struct {
	at:   [3]i32,
	mine: bool,
	home: bool,
}

// Survival: what a player is shown of its crafting and its world's outposts (one per
// player): whether a fabricator is within reach, what it is making and how far along, and
// the outposts of the world it is in. Put when it changes (looked at four times a second).
Survival :: struct {
	near_fabricator: bool,
	making:          u16, // the recipe being made: its index in the registry's recipes + 1 (0: none)
	progress:        u8, // percent
	count:           u8, // outposts
	outposts:        [MAX_OUTPOSTS]Outpost_Line,
}

// Made (an event): the player's recipe was made and given: what and how many.
Made :: struct {
	item:  u16, // a game.Item
	count: u16,
}

// Craft (a request): make the recipe of this index in the registry's recipes, one of the
// sandbox's; the server judges where the player stands and what it carries.
Craft :: struct {
	recipe: u16,
}

KINDS :: protocol.Game_Kinds {
	states   = {
		{name = "sandbox.market", value = Town_Market},
		{name = "sandbox.ruin", value = Ruin_Fight},
		{name = "sandbox.survival", value = Survival},
	},
	events   = {
		{name = "sandbox.trade_refused", value = Trade_Refused},
		{name = "sandbox.market_open", value = Market_Open},
		{name = "sandbox.made", value = Made},
	},
	requests = {{name = "sandbox.trade", value = Trade}, {name = "sandbox.craft", value = Craft}},
}

// MAX_TRADE_QUANTITY: the most units one trade may move.
MAX_TRADE_QUANTITY :: 1e6

// The game's actions (its client part's `actions`, in this order): the market's, the
// crafting screen's (the client part opens it) and the Use action, which uses up what is
// in the hand or works the gadget there.
MARKET_ACTION :: 0
CRAFT_ACTION :: 1
USE_ACTION :: 2
