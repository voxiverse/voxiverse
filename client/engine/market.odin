package engine

import "common:game"

// The market as the client knows it (the server is the authority: docs/world.md, the economy).
// A Market_View from the server says the player stands in a town; one with a reason says they
// do not (Away) or why a trade was refused. The client keeps the last good view and shows it.

// Market_State: the last view and what the market screen has chosen.
Market_State :: struct {
	here:     bool, // standing in a town: a view is held
	town:     [game.MAX_MARKET_NAME]u8,
	town_len: int,
	cash:     f64,
	goods:    [game.MARKET_GOODS]game.Market_Good,
	refusal:  game.Market_Reason, // why the last trade was refused (.None: it was not)
	views:    int, // views taken (a test counts them)
	good:     int, // the good selected on the screen
	quantity: f32, // the units a buy or sell asks for
	ask:      bool, // a trade was sent and its answer has not come
}

MARKET_QUANTITY_STEP :: 0.5 // units a click adds or takes off the quantity (a person's month of the good)
MARKET_QUANTITY_MIN :: 0.5
MARKET_QUANTITY_MAX :: 1000

// market_town: the name of the town of the held view.
market_town :: proc(m: ^Market_State) -> string {return string(m.town[:m.town_len])}

// market_take keeps a Market_View: a view replaces what is held; Away leaves the town; any
// other reason is a refusal of the last trade and changes nothing else.
market_take :: proc(m: ^Market_State, v: game.Market_View) {
	m.views += 1
	m.ask = false
	switch v.reason {
	case .None:
		m.here = true
		m.town_len = copy(m.town[:], v.town)
		m.cash, m.goods = v.cash, v.goods
		m.refusal = .None
	case .Away, .No_Economy:
		m.here, m.refusal = false, v.reason
	case .Bad_Quantity, .No_Market, .No_Cash, .No_Cargo, .No_Stock:
		m.refusal = v.reason
	}
	if m.quantity < MARKET_QUANTITY_MIN {m.quantity = 1}
}

// market_trade asks the server to buy or sell the chosen quantity of good (a Market_Trade).
market_trade :: proc(s: ^Session, m: ^Market_State, good: int, sell: bool) {
	if !m.here || good < 0 || good >= game.MARKET_GOODS {return}
	m.ask = true
	send_message(s, game.Market_Trade{good = u8(good), sell = sell, quantity = m.quantity})
}
