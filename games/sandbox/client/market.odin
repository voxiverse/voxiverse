package sandbox_client

import "core:fmt"

import "client:engine"
import "client:ui"
import "common:protocol"
import "games:sandbox"

// The market of the town the player stands in, as the server last put it (sandbox.Town_Market;
// the server is the authority, this only shows and asks). While the player stands in a
// town the HUD says so (`Market of <town>`); the game's action opens the market's screen
// there, as the server's answer (sandbox.Market_Open). Each good has its price, the stock
// and what the player carries, and how old the news behind the price is; the player picks a
// good and a quantity and buys or sells (a sandbox.Trade request). Walking out of the town
// closes it.

MARKET_WIDTH :: 760
QUANTITY_STEP :: 0.5 // units a click adds or takes off the quantity (a person's month of the good)
QUANTITY_MIN :: 0.5
QUANTITY_MAX :: 1000

// Market_Screen: the last market put and what the screen has chosen.
Market_Screen :: struct {
	town:     [sandbox.MAX_TOWN_NAME]u8,
	town_len: int, // 0: in no town
	cash:     f64,
	goods:    [sandbox.Good]sandbox.Town_Good,
	refusal:  sandbox.Refusal, // why the last trade was refused (.None: it was not)
	good:     sandbox.Good, // the good selected on the screen
	quantity: f32, // the units a buy or sell asks for
	ask:      bool, // a trade was sent and its answer has not come
}

// market_town: the town the player stands in ("": none).
market_town :: proc(m: ^Market_Screen) -> string {return string(m.town[:m.town_len])}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	m := &view(s).market
	if v, ok := engine.game_value(s, r, sandbox.Town_Market); ok && v != nil {
		m.town_len = copy(m.town[:], v.town)
		m.cash, m.goods = v.cash, v.goods
		m.refusal, m.ask = .None, false
		if m.quantity < QUANTITY_MIN {m.quantity = 1}
		if m.town_len == 0 {engine.game_screen_close(s)} 	// (left the town)
	}
	if v, ok := engine.game_value(s, r, sandbox.Trade_Refused); ok && v != nil {
		m.refusal, m.ask = v.reason, false
	}
	if v, ok := engine.game_value(s, r, sandbox.Market_Open); ok && v != nil {
		engine.game_screen_open(s)
	}
}

// hud: `Market of <town>`, near the top, while in a town and the screen is closed.
hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	m := &view(s).market
	if m.town_len == 0 || engine.game_screen_shown(s) {return}
	t := &ctx.theme
	r := ui.Rect{ctx.screen.x, ctx.screen.y + 2 * t.spacing, ctx.screen.w, t.row_height}
	ui.label(ctx, sandbox.tr(.Market_Hud, market_town(m)), r, .Center, t.text)
}

// market_trade asks the server to buy or sell the chosen quantity of the chosen good.
market_trade :: proc(s: ^engine.Session, m: ^Market_Screen, sell: bool) {
	if m.town_len == 0 {return}
	trade := sandbox.Trade{m.good, sell, m.quantity}
	engine.game_request(s, &trade)
	m.ask = true
}

// number: a quantity or price with `places` decimals.
number :: proc(x: $T, places: int) -> string {
	return fmt.tprintf("%.*f", places, x)
}

// refusal_line: why the last trade was refused ("" when it was not).
refusal_line :: proc(r: sandbox.Refusal) -> string {
	switch r {
	case .None:
		return ""
	case .Bad_Quantity:
		return sandbox.tr(.Market_Refused_Bad_Quantity)
	case .No_Market:
		return sandbox.tr(.Market_Refused_No_Market)
	case .No_Cash:
		return sandbox.tr(.Market_Refused_No_Cash)
	case .No_Cargo:
		return sandbox.tr(.Market_Refused_No_Cargo)
	case .No_Stock:
		return sandbox.tr(.Market_Refused_No_Stock)
	case .Away, .No_Economy:
		return sandbox.tr(.Market_Refused_Away)
	}
	return ""
}

// news_line: how old the news behind a price is, as a line.
news_line :: proc(age: f32) -> string {
	if age < 0 {return sandbox.tr(.Market_News_Unknown)}
	return sandbox.tr(.Market_News, int(age))
}

// market_screen: the game's screen (engine.Game.screen), the market of the town.
market_screen :: proc(s: ^engine.Session, ctx: ^ui.Context, top: bool) {
	m := &view(s).market
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	rows := f32(len(sandbox.Good))
	height := (rows + 6) * (t.row_height + t.spacing) + 80
	box := ui.rect_center(ctx.screen, MARKET_WIDTH, height)
	ui.panel(ctx, box)
	area := ui.rect_shrink(box, 2 * t.padding)
	ui.title(ctx, sandbox.tr(.Market_Title, market_town(m)), ui.cut_top(&area, 60))
	ui.label(ctx, sandbox.tr(.Market_Cash, number(m.cash, 2)), ui.cut_top(&area, t.row_height))
	ui.cut_top(&area, t.spacing)

	// The goods: name (a button: it selects), price, stock, cargo, the news's age.
	col := [5]f32{0.2, 0.15, 0.17, 0.15, 0.33}
	head := ui.cut_top(&area, t.row_height)
	heads := [4]sandbox.Text{.Market_Good, .Market_Price, .Market_Stock, .Market_Cargo}
	for h, i in heads {
		cell := ui.cut_left(&head, col[i] * area.w)
		ui.label(ctx, sandbox.tr(h), cell, .Left if i == 0 else .Right, t.text_muted)
	}
	for good in sandbox.Good {
		g := m.goods[good]
		row := ui.cut_top(&area, t.row_height)
		ui.cut_top(&area, t.spacing)
		name := ui.cut_left(&row, col[0] * area.w)
		ui.push_id_int(ctx, int(good))
		if good == m.good {
			ui.default_focus(ctx)
			ui.fill_rect(ctx, row, t.slot_fill)
		}
		if ui.button(ctx, fmt.tprint(good), name) {m.good = good}
		ui.pop_id(ctx)
		if !g.deals {
			ui.label(ctx, sandbox.tr(.Market_Not_Traded), row, .Left, t.text_muted)
			continue
		}
		cell := ui.cut_left(&row, col[1] * area.w)
		ui.label(ctx, number(g.price, 2), cell, .Right)
		cell = ui.cut_left(&row, col[2] * area.w)
		ui.label(ctx, number(g.stock, 1), cell, .Right)
		cell = ui.cut_left(&row, col[3] * area.w)
		ui.label(ctx, number(g.cargo, 1), cell, .Right)
		ui.label(ctx, news_line(g.age), ui.rect_shrink(row, t.padding), .Right, t.text_muted)
	}
	ui.cut_top(&area, t.spacing)

	// The quantity and the deal.
	line := ui.cut_top(&area, t.row_height)
	ui.cut_top(&area, t.spacing)
	less := ui.cut_left(&line, t.row_height)
	ui.cut_left(&line, t.spacing)
	more := ui.cut_left(&line, t.row_height)
	ui.cut_left(&line, 2 * t.spacing)
	if ui.button(ctx, sandbox.tr(.Market_Less), less, disabled = m.quantity <= QUANTITY_MIN) {
		m.quantity = max(m.quantity - QUANTITY_STEP, QUANTITY_MIN)
	}
	if ui.button(ctx, sandbox.tr(.Market_More), more, disabled = m.quantity >= QUANTITY_MAX) {
		m.quantity = min(m.quantity + QUANTITY_STEP, QUANTITY_MAX)
	}
	ui.label(ctx, sandbox.tr(.Market_Quantity, number(m.quantity, 1)), line)
	ui.label(ctx, refusal_line(m.refusal), ui.cut_top(&area, t.row_height), .Left, t.text_muted)
	buttons := ui.cut_bottom(&area, t.row_height)
	deals := m.goods[m.good].deals && !m.ask
	third := (buttons.w - 2 * t.spacing) / 3
	b := ui.cut_left(&buttons, third)
	ui.cut_left(&buttons, t.spacing)
	if ui.button(ctx, sandbox.tr(.Market_Buy), b, disabled = !deals) {market_trade(s, m, false)}
	b = ui.cut_left(&buttons, third)
	ui.cut_left(&buttons, t.spacing)
	if ui.button(ctx, sandbox.tr(.Market_Sell), b, disabled = !deals) {market_trade(s, m, true)}
	if ui.button(ctx, sandbox.tr(.Market_Close), buttons) {engine.game_screen_close(s)}
}
