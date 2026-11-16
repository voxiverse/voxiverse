package sandbox_client

import "core:fmt"
import "core:testing"

import "client:ui"

import "client:engine"
import "client:playtest"
import "games:sandbox"
import sandbox_server "games:sandbox/server"

// The market played whole: standing in a town the HUD says so; the game's action opens the
// market's screen there, with the goods, the age of their news and the player's silver; a
// buy is answered with the cargo bought; walking out of the town closes it.
@(test)
test_market_in_a_town :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "trader"}) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := s.home
	w.params.planet = 1 // (the harness's flat world told it is the planet's: it has its towns)
	sandbox_server.economy_sync(s, w, nil)
	we := sandbox_server.world_of(w).economy
	if !testing.expect(t, we != nil && we.built, "no economy") {return}
	town := -1
	for tw, i in we.economy.towns {
		if tw.market[.Grain] && tw.production[.Grain] > 0 {town = i; break}
	}
	if !testing.expect(t, town >= 0, "no town sells grain") {return}
	tw := we.economy.towns[town]
	c := playtest.client(rig)
	sandbox_server.stand_at(c, tw.lat + 1, tw.lon)
	sandbox_server.trader(s, c).cash = 1e7

	// Away from it, nothing; in it, the HUD's line.
	playtest.step(rig, 40)
	testing.expect(t, !playtest.drawn(rig, "Market of "), "a market away from towns")
	sandbox_server.stand_at(c, tw.lat, tw.lon)
	in_town :: proc(rig: ^playtest.Rig) -> bool {return view(rig.s).market.town_len > 0}
	if !testing.expect(t, playtest.until(rig, in_town, 5), "no market in the town") {return}
	testing.expect(t, playtest.drawn(rig, "Market of Town "), "no HUD line in a town")
	line := fmt.tprintf("Market of %s   Z: trade", market_town(&view(rig.s).market))
	testing.expect(t, playtest.drawn(rig, line), "the HUD does not say the market's key")

	// The action opens the screen.
	rig.actions.pressed += {.Game_1}
	open :: proc(rig: ^playtest.Rig) -> bool {return engine.game_screen_shown(rig.s)}
	if !testing.expect(t, playtest.until(rig, open, 5), "the action opened no market") {return}
	testing.expect(t, playtest.drawn(rig, "Silver: 10000000.00"), "no silver")
	testing.expect(t, playtest.drawn(rig, "Grain"), "no grain")
	testing.expect(t, playtest.drawn(rig, "news 0 days old"), "no news's age")
	testing.expect(t, market_fits(rig), "the market's panel does not fit 720 high")

	// A buy: the cargo comes back with the market.
	m := &view(rig.s).market
	m.good, m.quantity = .Grain, 1
	market_trade(rig.s, m, false)
	bought :: proc(rig: ^playtest.Rig) -> bool {return view(rig.s).market.goods[.Grain].cargo > 0}
	testing.expect(t, playtest.until(rig, bought, 5), "nothing bought")
	testing.expect(t, playtest.drawn(rig, "Silver: 99"), "the silver did not fall")

	// A refusal says why: selling more than is carried.
	m.quantity = 1000
	market_trade(rig.s, m, true)
	refused :: proc(rig: ^playtest.Rig) -> bool {return view(rig.s).market.refusal != .None}
	testing.expect(t, playtest.until(rig, refused, 5), "no refusal")
	testing.expect_value(t, m.refusal, sandbox.Refusal.No_Cargo)
	testing.expect(
		t,
		playtest.drawn(rig, "You do not carry that much."),
		"the refusal is not said",
	)

	// The action's key pressed again (the screen has the keyboard) closes it; over the
	// world again it opens it.
	rig.actions.pressed -= {.Game_1}
	rig.app.actions.key_pressed += {.Game_1}
	playtest.draw(rig)
	ui.end_frame(&rig.app.ui)
	rig.app.actions.key_pressed -= {.Game_1}
	testing.expect(t, !engine.game_screen_shown(rig.s), "the action did not close the market")
	rig.actions.pressed += {.Game_1}
	testing.expect(t, playtest.until(rig, open, 5), "the action did not open it again")
	rig.actions.pressed -= {.Game_1}
	closed :: proc(rig: ^playtest.Rig) -> bool {return !engine.game_screen_shown(rig.s)}

	// Walking out of the town closes it.
	sandbox_server.stand_at(c, tw.lat + 1, tw.lon)
	testing.expect(t, playtest.until(rig, closed, 5), "the market stayed open away from the town")
	testing.expect(t, !playtest.drawn(rig, "Market of "), "the HUD line stayed")
}

// market_fits: the market's screen drawn at 1280x720 keeps a margin above and below (all
// but the backdrop over the whole screen, its first quad).
@(private = "file")
market_fits :: proc(rig: ^playtest.Rig) -> bool {
	playtest.draw(rig)
	defer ui.end_frame(&rig.app.ui)
	low, high: f32 = 1e9, -1e9
	for v in rig.app.ui.output.layers[.Modal].vertices[4:] {
		low, high = min(low, v.pos.y), max(high, v.pos.y)
	}
	return low >= 8 && high <= playtest.HEIGHT - 8
}
