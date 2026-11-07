package screen

import "core:fmt"

import "client:engine"
import "client:ui"
import "common:game"
import "common:planet"

// The market screen: the market of the town the player stands in, as the server last sent it
// (engine.Market_State; the server is the authority, this only shows and asks). Each good has its
// price in silver, the stock, the player's cargo and how old the news behind the price is;
// the player picks a good and a quantity and buys or sells (a Market_Trade). M opens it in a
// town (the HUD says so: `Market of <town> (M)`) and closes it; walking out of the town closes
// it. A town's market stall in the voxels opens the same screen later (market_open).

MARKET_WIDTH :: 760

// market_near: the player stands in a town (a view is held).
market_near :: proc(app: ^engine.App) -> bool {
	s := app.session
	return s != nil && s.state == .Playing && s.market.here
}

// market_open shows the screen (in a town).
market_open :: proc(app: ^engine.App) {
	if market_near(app) {engine.overlay_open(&app.overlays, .Market)}
}

// market_keys: M opens the screen in a town and closes it; the screen closes when the player
// is no longer in the town.
market_keys :: proc(app: ^engine.App) {
	open := engine.overlay_is_open(&app.overlays, .Market)
	if open && !market_near(app) {
		engine.overlay_close(&app.overlays, .Market)
		return
	}
	if !engine.action_pressed(&app.actions, .Market) {return}
	if open {
		engine.overlay_close(&app.overlays, .Market)
	} else if engine.game_controls(app) {
		market_open(app)
	}
}

// market_hud_line: `Market of <town> (M)`, near the top, while in a town and the screen is closed.
market_hud_line :: proc(app: ^engine.App, ctx: ^ui.Context) {
	if !market_near(app) || engine.overlay_is_open(&app.overlays, .Market) {return}
	t := &ctx.theme
	text := engine.tr(
		.Market_Hud,
		engine.market_town(&app.session.market),
		engine.action_label(app, .Market),
	)
	r := ui.Rect{ctx.screen.x, ctx.screen.y + 2 * t.spacing, ctx.screen.w, t.row_height}
	ui.label(ctx, text, r, .Center, t.text)
}

// number: a quantity or price with `places` decimals.
number :: proc(x: $T, places: int) -> string {
	return fmt.tprintf("%.*f", places, x)
}

// good_name: what a good is called.
good_name :: proc(i: int) -> string {
	return fmt.tprint(planet.Good(i))
}

// market_refusal: the line that says why the last trade was refused ("" when it was not).
market_refusal :: proc(r: game.Market_Reason) -> string {
	#partial switch r {
	case .Bad_Quantity:
		return engine.tr(.Market_Refused_Bad_Quantity)
	case .No_Market:
		return engine.tr(.Market_Refused_No_Market)
	case .No_Cash:
		return engine.tr(.Market_Refused_No_Cash)
	case .No_Cargo:
		return engine.tr(.Market_Refused_No_Cargo)
	case .No_Stock:
		return engine.tr(.Market_Refused_No_Stock)
	case .Away, .No_Economy:
		return engine.tr(.Market_Refused_Away)
	}
	return ""
}

// market_news: how old the news behind a price is, as a line.
market_news :: proc(age: f32) -> string {
	if age < 0 {return engine.tr(.Market_News_Unknown)}
	return engine.tr(.Market_News, int(age))
}

market_ui :: proc(app: ^engine.App, ctx: ^ui.Context, top: bool) {
	s := app.session
	if s == nil {return}
	m := &s.market
	ui.push_id(ctx, "market")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	rows := f32(game.MARKET_GOODS)
	height := (rows + 6) * (t.row_height + t.spacing) + 80
	box := ui.rect_center(ctx.screen, MARKET_WIDTH, height)
	ui.panel(ctx, box)
	area := ui.rect_shrink(box, 2 * t.padding)
	ui.title(ctx, engine.tr(.Market_Title, engine.market_town(m)), ui.cut_top(&area, 60))
	ui.label(ctx, engine.tr(.Market_Cash, number(m.cash, 2)), ui.cut_top(&area, t.row_height))
	ui.cut_top(&area, t.spacing)

	// The goods: name (a button: it selects), price, stock, cargo, the news's age.
	col := [5]f32{0.2, 0.15, 0.17, 0.15, 0.33}
	head := ui.cut_top(&area, t.row_height)
	heads := [4]engine.Text{.Market_Good, .Market_Price, .Market_Stock, .Market_Cargo}
	for h, i in heads {
		cell := ui.cut_left(&head, col[i] * area.w)
		ui.label(ctx, engine.tr(h), cell, .Left if i == 0 else .Right, t.text_muted)
	}
	if m.good < 0 || m.good >= game.MARKET_GOODS {m.good = 0}
	for i in 0 ..< game.MARKET_GOODS {
		g := m.goods[i]
		row := ui.cut_top(&area, t.row_height)
		ui.cut_top(&area, t.spacing)
		name := ui.cut_left(&row, col[0] * area.w)
		ui.push_id_int(ctx, i)
		if i == m.good {
			ui.default_focus(ctx)
			ui.fill_rect(ctx, row, t.slot_fill)
		}
		if ui.button(ctx, good_name(i), name) {m.good = i}
		ui.pop_id(ctx)
		if !g.deals {
			ui.label(ctx, engine.tr(.Market_Not_Traded), row, .Left, t.text_muted)
			continue
		}
		cell := ui.cut_left(&row, col[1] * area.w)
		ui.label(ctx, number(g.price, 2), cell, .Right)
		cell = ui.cut_left(&row, col[2] * area.w)
		ui.label(ctx, number(g.stock, 1), cell, .Right)
		cell = ui.cut_left(&row, col[3] * area.w)
		ui.label(ctx, number(g.cargo, 1), cell, .Right)
		ui.label(ctx, market_news(g.age), ui.rect_shrink(row, t.padding), .Right, t.text_muted)
	}
	ui.cut_top(&area, t.spacing)

	// The quantity and the deal.
	line := ui.cut_top(&area, t.row_height)
	ui.cut_top(&area, t.spacing)
	less := ui.cut_left(&line, t.row_height)
	ui.cut_left(&line, t.spacing)
	more := ui.cut_left(&line, t.row_height)
	ui.cut_left(&line, 2 * t.spacing)
	if ui.button(
		ctx,
		engine.tr(.Market_Less),
		less,
		disabled = m.quantity <= engine.MARKET_QUANTITY_MIN,
	) {
		m.quantity = max(m.quantity - engine.MARKET_QUANTITY_STEP, engine.MARKET_QUANTITY_MIN)
	}
	if ui.button(
		ctx,
		engine.tr(.Market_More),
		more,
		disabled = m.quantity >= engine.MARKET_QUANTITY_MAX,
	) {
		m.quantity = min(m.quantity + engine.MARKET_QUANTITY_STEP, engine.MARKET_QUANTITY_MAX)
	}
	ui.label(ctx, engine.tr(.Market_Quantity, number(m.quantity, 1)), line)
	ui.label(ctx, market_refusal(m.refusal), ui.cut_top(&area, t.row_height), .Left, t.text_muted)
	buttons := ui.cut_bottom(&area, t.row_height)
	deals := m.goods[m.good].deals && !m.ask
	third := (buttons.w - 2 * t.spacing) / 3
	b := ui.cut_left(&buttons, third)
	ui.cut_left(&buttons, t.spacing)
	if ui.button(ctx, engine.tr(.Market_Buy), b, disabled = !deals) {
		engine.market_trade(s, m, m.good, false)
	}
	b = ui.cut_left(&buttons, third)
	ui.cut_left(&buttons, t.spacing)
	if ui.button(ctx, engine.tr(.Market_Sell), b, disabled = !deals) {
		engine.market_trade(s, m, m.good, true)
	}
	if ui.button(ctx, engine.tr(.Market_Close), buttons) {
		engine.overlay_close(&app.overlays, .Market)
	}
}
