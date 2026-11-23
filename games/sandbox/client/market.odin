package sandbox_client

import "core:fmt"

import "client:engine"
import "client:menu"
import "client:ui"
import "common:protocol"
import "games:sandbox"

// The market of the town the player stands in, as the server last put it (sandbox.Town_Market;
// the server is the authority, this only shows and asks). While the player stands in a
// town the HUD says so (`Market of <town>`); the game's action opens the market's screen
// there, as the server's answer (sandbox.Market_Open), and pressed again closes it. Each good has its price, the stock
// and what the player carries, and how old the news behind the price is; the player picks a
// good and a quantity and buys or sells (a sandbox.Trade request). Walking out of the town
// closes it. The screen is the inventory's style (client/menu: panes, the theme's gain and
// loss colours).

MARKET_WIDTH :: 760
MARKET_TITLE :: 60 // the title's height
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
		if m.town_len == 0 && view(s).screen == .Market {engine.game_screen_close(s)} 	// (left the town)
	}
	if v, ok := engine.game_value(s, r, sandbox.Trade_Refused); ok && v != nil {
		m.refusal, m.ask = v.reason, false
	}
	if v, ok := engine.game_value(s, r, sandbox.Market_Open); ok && v != nil {
		view(s).screen = .Market
		engine.game_screen_open(s)
	}
	if v, ok := engine.game_value(s, r, sandbox.Survival);
	   ok && v != nil {view(s).craft.shown = v^}
	if v, ok := engine.game_value(s, r, sandbox.Made); ok && v != nil {craft_made(s, v^)}
	if v, ok := engine.game_value(s, r, sandbox.Ruin_Fight); ok && v != nil {ruin_received(s, v)}
}

// hud: the ruin's fight while the player is in one (ruin.odin); `Market of <town>` and the
// key that opens it, near the top, while in a town and the screen is closed.
hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	ruin_hud(s, ctx)
	craft_hud(s, ctx)
	m := &view(s).market
	if m.town_len == 0 || engine.game_screen_shown(s) {return}
	t := &ctx.theme
	r := ui.Rect{ctx.screen.x, ctx.screen.y + 2 * t.spacing, ctx.screen.w, t.row_height}
	key := engine.game_action_key(s, MARKET_ACTION)
	ui.label(ctx, sandbox.tr(.Market_Hud, market_town(m), key), r, .Center, t.text)
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

// market_screen: the game's screen (engine.Game.screen), the market of the town in two
// panes as every trader's window is: on the left what the market sells (each good's price,
// the price red where the chosen quantity costs more silver than the player has, its stock,
// the age of its news), on the right what the player carries (the cargo of each, what it
// would sell for here); under them the chosen good with the quantity, what it comes to,
// and Buy (only what the player can afford and the market holds), Sell (only what they
// carry) and Close.
market_screen :: proc(s: ^engine.Session, ctx: ^ui.Context, top: bool) {
	m := &view(s).market
	if top && engine.game_action_pressed(s, MARKET_ACTION) { 	// (the key that opened it)
		engine.game_screen_close(s)
		return
	}
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	// As tall as what it holds (the title, silver, the panes' heads and a row a good, the
	// chosen good, the quantity, the refusal's line and the buttons), so it fits 720 high.
	rows := f32(len(sandbox.Good))
	gap := t.spacing / 2
	panes := menu.pane_size(t, 0, t.row_height + rows * (t.row_height + gap)).y
	height := 4 * t.padding + MARKET_TITLE + 4 * t.row_height + 4 * t.spacing + panes
	box := ui.rect_center(ctx.screen, MARKET_WIDTH, min(height, ctx.screen.h))
	ui.panel(ctx, box)
	area := ui.rect_shrink(box, 2 * t.padding)
	ui.title(ctx, sandbox.tr(.Market_Title, market_town(m)), ui.cut_top(&area, MARKET_TITLE))
	ui.label(ctx, sandbox.tr(.Market_Cash, number(m.cash, 2)), ui.cut_top(&area, t.row_height))
	ui.cut_top(&area, t.spacing)

	row_of :: proc(area: ^ui.Rect, t: ^ui.Theme, gap: f32) -> ui.Rect {
		row := ui.cut_top(area, t.row_height)
		ui.cut_top(area, gap)
		return row
	}
	cells :: proc(
		ctx: ^ui.Context,
		row: ui.Rect,
		widths: []f32,
		texts: []string,
		inks: []ui.Color,
	) {
		r := row
		for w, i in widths {
			cell := ui.cut_left(&r, w * row.w)
			ui.label(ctx, texts[i], cell, .Left if i == 0 else .Right, inks[i])
		}
	}
	both := ui.cut_top(&area, panes)
	ui.cut_top(&area, t.spacing)
	half := (both.w - t.spacing) / 2
	market := menu.pane(ctx, ui.cut_left(&both, half), sandbox.tr(.Market_Market))
	ui.cut_left(&both, t.spacing)
	carried := menu.pane(ctx, both, sandbox.tr(.Market_Carried))

	// The market: name (a button: it selects), price, stock, the news's age.
	left := [4]f32{0.3, 0.2, 0.2, 0.3}
	right := [3]f32{0.4, 0.3, 0.3}
	muted := t.text_muted
	cells(
		ctx,
		row_of(&market, t, gap),
		left[:],
		{sandbox.tr(.Market_Good), sandbox.tr(.Market_Price), sandbox.tr(.Market_Stock), ""},
		{muted, muted, muted, muted},
	)
	cells(
		ctx,
		row_of(&carried, t, gap),
		right[:],
		{sandbox.tr(.Market_Good), sandbox.tr(.Market_Cargo), sandbox.tr(.Market_Value)},
		{muted, muted, muted},
	)
	for good in sandbox.Good {
		g := m.goods[good]
		row := row_of(&market, t, gap)
		mine := row_of(&carried, t, gap)
		if good == m.good {
			ui.fill_rect(ctx, row, t.row_selected)
			ui.fill_rect(ctx, mine, t.row_selected)
		}
		name := ui.cut_left(&row, left[0] * row.w)
		ui.push_id_int(ctx, int(good))
		if good == m.good {ui.default_focus(ctx)}
		if ui.button(ctx, fmt.tprint(good), name) {m.good = good}
		ui.pop_id(ctx)
		if !g.deals {
			ui.label(ctx, sandbox.tr(.Market_Not_Traded), row, .Right, muted)
		} else {
			price_ink := t.text if f64(g.price * m.quantity) <= m.cash else t.loss
			rest := [3]f32 {
				left[1] / (1 - left[0]),
				left[2] / (1 - left[0]),
				left[3] / (1 - left[0]),
			}
			cells(
				ctx,
				row,
				rest[:],
				{number(g.price, 2), number(g.stock, 1), news_line(g.age)},
				{price_ink, t.text, muted},
			)
		}
		value := number(g.price * g.cargo, 2) if g.deals else "-"
		cells(
			ctx,
			mine,
			right[:],
			{fmt.tprint(good), number(g.cargo, 1), value},
			{t.text if g.cargo > 0 else muted, t.text if g.cargo > 0 else muted, muted},
		)
	}

	// The chosen good: the quantity, what it comes to, and the deal.
	g := m.goods[m.good]
	cost := f64(g.price * m.quantity)
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
	if g.deals {
		ink := t.text if cost <= m.cash else t.loss
		ui.label(
			ctx,
			sandbox.tr(.Market_Total, fmt.tprint(m.good), number(cost, 2)),
			line,
			.Right,
			ink,
		)
	}
	ui.label(ctx, refusal_line(m.refusal), ui.cut_top(&area, t.row_height), .Left, muted)
	buttons := ui.cut_bottom(&area, t.row_height)
	deals := g.deals && !m.ask
	third := (buttons.w - 2 * t.spacing) / 3
	b := ui.cut_left(&buttons, third)
	ui.cut_left(&buttons, t.spacing)
	can_buy := deals && cost <= m.cash && g.stock >= m.quantity
	if ui.button(ctx, sandbox.tr(.Market_Buy), b, disabled = !can_buy) {market_trade(s, m, false)}
	b = ui.cut_left(&buttons, third)
	ui.cut_left(&buttons, t.spacing)
	can_sell := deals && g.cargo >= m.quantity
	if ui.button(ctx, sandbox.tr(.Market_Sell), b, disabled = !can_sell) {market_trade(s, m, true)}
	if ui.button(ctx, sandbox.tr(.Market_Close), buttons) {engine.game_screen_close(s)}
}
