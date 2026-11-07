package main

import "core:testing"

import "client:engine"
import "client:font"
import "client:screen"
import "client:testkit"
import "client:ui"
import "common:game"
import "common:planet"

// The market screen: the HUD line near a town and not away from one, the goods with the age of
// their news, and a buy that sends the trade (the server's market_view then changes cash and cargo).

@(private = "file")
Market_Fixture :: struct {
	app:  ^engine.App,
	s:    ^engine.Session,
	pipe: game.Pipe,
}

@(private = "file")
market_fixture :: proc(t: ^testing.T, f: ^Market_Fixture) {
	f.app = new(engine.App)
	f.app.settings = engine.SETTINGS_DEFAULTS
	ok: bool
	f.app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&f.app.ui, &f.app.font))
	f.s = new(engine.Session)
	game.pipe_init(&f.pipe)
	f.s.endpoint = {&f.pipe, .Client}
	game.writer_init(&f.s.writer)
	f.s.state = .Playing
	f.s.reg = testkit.test_reg()
	f.app.session = f.s
	f.app.screen = .Game
}

@(private = "file")
market_fixture_destroy :: proc(f: ^Market_Fixture) {
	f.app.session = nil
	game.writer_destroy(&f.s.writer)
	game.pipe_destroy(&f.pipe)
	free(f.s)
	ui.destroy(&f.app.ui)
	free(f.app)
}

@(private = "file")
market_view :: proc(cash: f64) -> game.Market_View {
	v := game.Market_View {
		town = "Town 7",
		cash = cash,
	}
	g := &v.goods[int(planet.Good.Grain)]
	g^ = {
		deals = true,
		price = 2.5,
		stock = 120,
		cargo = 0,
		age   = 3,
	}
	v.goods[int(planet.Good.Salt)] = {
		deals = true,
		price = 9,
		stock = 4,
		age   = -1,
	}
	return v
}

// market_drawn: whether the last frame drew exactly `text`.
@(private = "file")
market_drawn :: proc(ctx: ^ui.Context, text: string) -> bool {
	for x in ctx.texts {if x == text {return true}}
	return false
}

// frame: one frame of the HUD line and the screen.
@(private = "file")
market_frame :: proc(app: ^engine.App, in_: ui.Input = {}) {
	ui.begin_frame(&app.ui, in_, {1280, 720}, 1)
	screen.market_hud_line(app, &app.ui)
	if engine.overlay_is_open(&app.overlays, .Market) {screen.market_ui(app, &app.ui, true)}
	ui.end_frame(&app.ui)
}

@(test)
test_market_hud_line_only_in_a_town :: proc(t: ^testing.T) {
	f: Market_Fixture
	market_fixture(t, &f)
	defer market_fixture_destroy(&f)
	testing.expect(t, !screen.market_near(f.app), "near a town with no view")
	screen.market_keys(f.app)
	testing.expect(t, !engine.overlay_is_open(&f.app.overlays, .Market))

	engine.market_take(&f.s.market, market_view(10))
	testing.expect(t, screen.market_near(f.app), "not near with a view")
	testing.expect_value(t, engine.market_town(&f.s.market), "Town 7")
	market_frame(f.app)
	testing.expect(t, market_drawn(&f.app.ui, "Market of Town 7 (M)"), "no HUD line in a town")

	// Walking out: the server says Away; the line goes.
	engine.market_take(&f.s.market, game.Market_View{reason = .Away})
	testing.expect(t, !screen.market_near(f.app))
	market_frame(f.app)
	testing.expect(t, !market_drawn(&f.app.ui, "Market of Town 7 (M)"), "the line stayed")
}

@(test)
test_market_screen_lists_goods_and_buys :: proc(t: ^testing.T) {
	f: Market_Fixture
	market_fixture(t, &f)
	defer market_fixture_destroy(&f)
	app := f.app
	engine.market_take(&f.s.market, market_view(10))
	screen.market_open(app)
	testing.expect(t, engine.overlay_is_open(&app.overlays, .Market))
	market_frame(app)
	testing.expect(t, !market_drawn(&app.ui, "Market of Town 7 (M)"), "HUD line over the screen")
	testing.expect(t, market_drawn(&app.ui, "Market of Town 7"), "no title")
	testing.expect(t, market_drawn(&app.ui, "Grain"), "no grain")
	testing.expect(t, market_drawn(&app.ui, "news 3 days old"), "no news age")
	testing.expect(t, market_drawn(&app.ui, "no news"), "no unknown news")
	testing.expect(t, market_drawn(&app.ui, "Silver: 10.00"), "no cash")

	// Buy: the click sends a Market_Trade for the chosen good and quantity.
	engine.market_trade(f.s, &f.s.market, int(planet.Good.Grain), false)
	m, decoded := game.decode_client(f.s.writer.buf[:], testkit.test_reg())
	trade, is_trade := m.(game.Market_Trade)
	testing.expect(t, decoded && is_trade, "no Market_Trade sent")
	testing.expect_value(t, trade.good, u8(planet.Good.Grain))
	testing.expect_value(t, trade.sell, false)
	testing.expect(t, trade.quantity > 0)

	// The server's answer changes cash and cargo on the screen.
	v := market_view(7.5)
	v.goods[int(planet.Good.Grain)].cargo = 1
	engine.market_take(&f.s.market, v)
	market_frame(app)
	testing.expect_value(t, f.s.market.cash, 7.5)
	testing.expect_value(t, f.s.market.goods[int(planet.Good.Grain)].cargo, 1)
	testing.expect(t, market_drawn(&app.ui, "Silver: 7.50"), "cash not updated")

	// A refusal keeps the market_view and says why.
	engine.market_take(&f.s.market, game.Market_View{reason = .No_Cash})
	testing.expect(t, screen.market_near(app))
	market_frame(app)
	testing.expect(t, market_drawn(&app.ui, "Not enough silver."), "no refusal line")

	// M closes it; Away closes it too.
	engine.market_take(&f.s.market, game.Market_View{reason = .Away})
	screen.market_keys(app)
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Market), "open away from town")
}
