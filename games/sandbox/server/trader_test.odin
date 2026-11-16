package sandbox_server

import "core:os"
import "core:strings"
import "core:testing"

import "common:worldgen"
import "games:sandbox"
import "server:core"
import "server:playtest"

// The player as a trader: buys where it is cheap and sells where it is dear, is refused what
// the market, its purse or its cargo cannot give, keeps what it carries with its character,
// and trades over the wire: in a town its market comes by itself, a trade is answered with
// the market after it, walking out says it is in no town, and a trade from there is refused.

// stand_at puts a client on the block column of a place on the planet.
stand_at :: proc(c: ^core.Client, lat, lon: f32) {
	c.player.position.x = f64(lon) / 180 * (worldgen.PLANET_CIRCUMFERENCE / 2)
	c.player.position.z = -f64(lat) / 90 * (worldgen.PLANET_CIRCUMFERENCE / 4)
}

@(test)
test_trader_buys_here_and_sells_there_for_a_profit :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	r, ok := economy_rig(t, rig)
	if !ok {return}
	we := world_of(r.w).economy
	economy_sync(r.s, r.w, {r.observer})
	if !testing.expect(t, we.resident) {return}
	// The pair of towns and the good with the widest gap in price.
	a, b, good, ratio := -1, -1, sandbox.Good.Grain, f32(0)
	for ia in we.market.town {
		for ib in we.market.town {
			for g in sandbox.Good {
				if !we.economy.towns[ia].market[g] || !we.economy.towns[ib].market[g] {continue}
				pa, pb := economy_price(r.w, ia, g), economy_price(r.w, ib, g)
				if pa > 0 && pb / pa > ratio {a, b, good, ratio = ia, ib, g, pb / pa}
			}
		}
	}
	if !testing.expect(t, ratio > 1.2, "no pair of towns with a margin") {return}
	c := playtest.host(rig)
	rec := trader(r.s, c)
	purse := f64(1e7) // (a town's month of grain costs more than a new player's silver)
	rec.cash = purse
	ta, tb := we.economy.towns[a], we.economy.towns[b]
	stand_at(c, ta.lat, ta.lon)
	units := f32(0.01) * ta.size
	res, got := trade(r.s, r.w, c, a, good, units, .Buy)
	testing.expect_value(t, res, sandbox.Refusal.None)
	testing.expect(t, got > 0 && rec.cargo[good] == got, "nothing bought")
	testing.expect(t, rec.cash < purse, "the goods were free")
	after_buy := rec.cash
	stand_at(c, tb.lat, tb.lon)
	sold: f32
	res, sold = trade(r.s, r.w, c, b, good, got, .Sell)
	testing.expect_value(t, res, sandbox.Refusal.None)
	testing.expect_value(t, rec.cargo[good], 0)
	testing.expect(t, rec.cash > purse, "no profit")
	testing.expect(t, sold == got && rec.cash > after_buy)
	// They saw both towns' prices where they stood.
	_, seen_a := trader_known(rec, u32(ta.cell), good)
	_, seen_b := trader_known(rec, u32(tb.cell), good)
	testing.expect(t, seen_a && seen_b, "the prices seen were not remembered")
}

@(test)
test_trader_is_refused :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	r, ok := economy_rig(t, rig)
	if !ok {return}
	we := world_of(r.w).economy
	economy_sync(r.s, r.w, {r.observer})
	tw := we.economy.towns[r.town]
	c := playtest.host(rig)
	rec := trader(r.s, c)
	testing.expect_value(t, rec.cash, STARTING_PURSE) // (given when it joined)
	// Away from the town (a degree of latitude is 111 km).
	stand_at(c, tw.lat + 1, tw.lon)
	res, _ := trade(r.s, r.w, c, r.town, .Grain, 0.001 * tw.size, .Buy)
	testing.expect_value(t, res, sandbox.Refusal.Away)
	testing.expect_value(t, rec.cash, STARTING_PURSE)
	stand_at(c, tw.lat, tw.lon)
	// Without cargo.
	res, _ = trade(r.s, r.w, c, r.town, .Grain, 1, .Sell)
	testing.expect_value(t, res, sandbox.Refusal.No_Cargo)
	// Without cash.
	rec.cash = 0
	res, _ = trade(r.s, r.w, c, r.town, .Grain, 0.001 * tw.size, .Buy)
	testing.expect_value(t, res, sandbox.Refusal.No_Cash)
	testing.expect_value(t, rec.cargo[sandbox.Good.Grain], 0)
	// More than the market holds.
	rec.cash = 1e12
	got: f32
	res, got = trade(r.s, r.w, c, r.town, .Grain, 100 * tw.size, .Buy)
	testing.expect(t, got < 100 * tw.size, "bought more than there was")
	res, _ = trade(r.s, r.w, c, r.town, .Grain, 100 * tw.size, .Buy)
	testing.expect_value(t, res, sandbox.Refusal.No_Stock)
	res, _ = trade(r.s, r.w, c, r.town, .Grain, -1, .Buy)
	testing.expect_value(t, res, sandbox.Refusal.Bad_Quantity)
}

// What a trader carries is its character's: saved with it and given back when it joins again.
@(test)
test_trader_is_kept_with_the_character :: proc(t: ^testing.T) {
	dir :: "build/tmp/sandbox_trader_kept"
	os.remove_all(dir)
	defer os.remove_all(dir)
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
	rec := trader(playtest.srv(rig), playtest.host(rig))
	rec.cash = 33.5
	rec.cargo[sandbox.Good.Salt] = 2.5
	seen_put(rec, Seen{7, 1.25, 12, .Fish})
	seen_put(rec, Seen{7, 9, 3, .Fish}) // older: not kept
	seen_put(rec, Seen{9, 0.5, 14, .Ore})
	playtest.stop(rig)

	rig2 := new(playtest.Rig)
	defer free(rig2)
	if !playtest.start(t, rig2, GAME, {save_dir = dir}) {return}
	defer playtest.stop(rig2)
	back := trader(playtest.srv(rig2), playtest.host(rig2))
	testing.expect_value(t, back.cash, 33.5)
	testing.expect_value(t, back.cargo[sandbox.Good.Salt], 2.5)
	testing.expect_value(t, back.count, 2)
	s, known := trader_known(back, 7, .Fish)
	testing.expect(t, known && s.price == 1.25 && s.month == 12)
}

// The exit check of the market on the wire.
@(test)
test_market_and_trade_over_the_wire :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {guests = 1}) {return}
	defer playtest.stop(rig)
	r, ok := economy_rig(t, rig)
	if !ok {return}
	tw := world_of(r.w).economy.economy.towns[r.town]
	near, far := playtest.host(rig), playtest.guest(rig)
	stand_at(near, tw.lat, tw.lon)
	stand_at(far, tw.lat + 1, tw.lon) // (a degree of latitude is 111 km)
	trader(r.s, near).cash = 1e7

	// Arriving: the market comes by itself.
	playtest.step(rig, playtest.ticks(2))
	v := playtest.host_record(rig, sandbox.Town_Market)
	if !testing.expect(t, v != nil && strings.has_prefix(v.town, "Town "), "no market in a town") {
		return
	}
	g := v.goods[.Grain]
	testing.expect(t, g.deals && g.price > 0 && g.stock > 0, "grain is not on sale")
	testing.expect_value(t, g.age, 0)
	testing.expect_value(t, v.cash, 1e7)
	stock := g.stock

	// Trading: the answer is the market after it.
	buy := sandbox.Trade{.Grain, false, 0.01 * tw.size}
	core.harness_request(r.s, near, &buy)
	playtest.step(rig, 2)
	bought := playtest.host_record(rig, sandbox.Town_Market)^
	testing.expect(t, bought.goods[.Grain].cargo > 0, "nothing bought")
	testing.expect(t, bought.cash < 1e7, "the grain was free")
	testing.expect(t, bought.goods[.Grain].stock < stock, "the stock did not fall")

	// Selling what they carry gives silver back.
	sell := sandbox.Trade{.Grain, true, bought.goods[.Grain].cargo}
	core.harness_request(r.s, near, &sell)
	playtest.step(rig, 2)
	sold := playtest.host_record(rig, sandbox.Town_Market)
	testing.expect_value(t, sold.goods[.Grain].cargo, 0)
	testing.expect(t, sold.cash > bought.cash, "no silver for the sale")

	// Walking out of the town: in no town.
	stand_at(near, tw.lat + 1, tw.lon)
	playtest.step(rig, playtest.ticks(2))
	testing.expect_value(t, playtest.host_record(rig, sandbox.Town_Market).town, "")

	// Away from every town: no market, and a forged trade is refused, nothing moved.
	far_view := playtest.guest_record(rig, sandbox.Town_Market)
	testing.expect(t, far_view == nil || far_view.town == "", "a market away from towns")
	forged := sandbox.Trade{.Grain, false, 1}
	core.harness_request(r.s, far, &forged)
	huge := sandbox.Trade{.Grain, false, 2 * sandbox.MAX_TRADE_QUANTITY}
	core.harness_request(r.s, near, &huge)
	playtest.step(rig, 2)
	testing.expect_value(t, trader(r.s, far).cash, STARTING_PURSE)
	testing.expect_value(t, trader(r.s, far).cargo[sandbox.Good.Grain], 0)
}

// /town takes a player to the nearest town with a market.
@(test)
test_town_takes_a_player_to_a_market :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	r, ok := economy_rig(t, rig)
	if !ok {return}
	tw := world_of(r.w).economy.economy.towns[r.town]
	c := playtest.host(rig)
	stand_at(c, tw.lat + 0.3, tw.lon) // (33 km off)
	testing.expect(t, command(r.s, c, "town", nil))
	playtest.step(rig, playtest.ticks(3)) // (set down, and the market there in detail)
	testing.expect(t, playtest.told(rig, "To Town "), "not told where")
	_, there := trader_where(r.w, c)
	testing.expect(t, there, "not in a town")
}
