package sandbox_server

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

import "common:worldgen"
import "games:sandbox"
import "server:core"

// The player as a trader (docs/world.md, the economy). Each character carries silver, cargo
// and the prices it has seen (Trader_Record: the game's record on the character, kept in its
// file); the server is the authority: `trade` checks where they stand, what they hold and
// what the market holds, and moves goods and silver through the same `sandbox.trader_buy` and
// `trader_sell` that move the market's price as a caravan does. What a player knows of a
// town's prices is what they saw standing in it (or were told there), kept by the town's
// climate cell (stable between saves) with the month the price was true.
//
// On the wire: a player standing within a town's radius is put its `sandbox.Town_Market` (the
// town's name, each good's price and stock, the age of the news behind each price, their
// silver and cargo), looked at once a second (`economy_tick`) and sent when it changed, and
// as the answer to their `sandbox.Trade`, which names no town: the server knows where they
// stand. Away from every town the record names none, and a trade from there is refused.

STARTING_PURSE :: 20.0 // silver of a new character (and of one from before the trader)
TRADE_RADIUS_KM :: 15.0 // a player this near a town may trade in it
MAX_SEEN :: 192 // prices a player remembers: the oldest are forgotten first

Seen :: struct {
	cell:  u32,
	price: f32,
	month: f32, // (whole months: exact)
	good:  sandbox.Good,
}

// Trader_Record is what a character carries as a trader (core.Game.character_data).
Trader_Record :: struct {
	cash:  f64,
	cargo: [len(sandbox.Good)]f32, // by sandbox.Good
	seen:  [MAX_SEEN]Seen,
	count: int,
	given: bool, // the starting purse was given (a new character's record is zero)
}

Trade_Side :: enum {
	Buy,
	Sell,
}

trader :: proc(s: ^core.Server, c: ^core.Client) -> ^Trader_Record {
	return core.character_data(s, c, Trader_Record)
}

// trader_joined: a character new to the trade is given its purse.
trader_joined :: proc(s: ^core.Server, c: ^core.Client) {
	t := trader(s, c)
	if !t.given {t.cash, t.given = STARTING_PURSE, true}
}

// seen_put remembers a price unless a newer one of that town and good is kept.
seen_put :: proc(t: ^Trader_Record, s: Seen) {
	oldest := 0
	for i in 0 ..< t.count {
		e := &t.seen[i]
		if e.cell == s.cell && e.good == s.good {
			if s.month >= e.month {e^ = s}
			return
		}
		if e.month < t.seen[oldest].month {oldest = i}
	}
	if t.count < MAX_SEEN {
		t.seen[t.count] = s
		t.count += 1
	} else if s.month >= t.seen[oldest].month {
		t.seen[oldest] = s
	}
}

// trader_known: what a trader remembers of a town's price of a good.
trader_known :: proc(t: ^Trader_Record, cell: u32, g: sandbox.Good) -> (Seen, bool) {
	for i in 0 ..< t.count {
		if t.seen[i].cell == cell && t.seen[i].good == g {return t.seen[i], true}
	}
	return {}, false
}

// trader_where: the town (an index in the economy) the player stands within the radius of,
// the nearest one in detail.
trader_where :: proc(w: ^core.World, c: ^core.Client) -> (town: int, ok: bool) {
	if w.params.planet == 0 {return}
	we := world_of(w).economy
	if we == nil || !we.built || !we.resident {return}
	o := economy_observer(c)
	best := f64(TRADE_RADIUS_KM)
	for i in we.market.town {
		tw := we.economy.towns[i]
		if d := sandbox.km_between(tw.lat, tw.lon, f32(o.x), f32(o.y)); d < best {
			best, town, ok = d, i, true
		}
	}
	return
}

// trader_open makes the model's trader of a player's, standing in market town `local` with
// what they know of the towns in detail, and what the town tells.
@(private = "file")
trader_open :: proc(we: ^World_Economy, rec: ^Trader_Record, local: int) -> sandbox.Trader {
	t := sandbox.trader_make(we.market, rec.cash, local)
	for g in sandbox.Good {t.cargo[g] = rec.cargo[int(g)]}
	for j in 0 ..< len(we.market.town) {
		cell := u32(we.economy.towns[we.market.town[j]].cell)
		for g in sandbox.Good {
			if s, ok := trader_known(rec, cell, g); ok {
				sandbox.knowledge_see(&t.know, j, g, s.price, f64(s.month))
			}
		}
	}
	sandbox.trader_arrive(&t, we.economy, we.market, we.news, local)
	return t
}

// trader_close takes a model trader's cash, cargo and knowledge back into the record.
@(private = "file")
trader_close :: proc(we: ^World_Economy, rec: ^Trader_Record, t: ^sandbox.Trader) {
	rec.cash = t.cash
	for g in sandbox.Good {rec.cargo[int(g)] = t.cargo[g]}
	// Only what they saw where they stand is theirs to keep (what the town told is not).
	cell := u32(we.economy.towns[we.market.town[t.at]].cell)
	for g in sandbox.Good {
		if r := t.know.at[t.at][g]; r.known {
			seen_put(rec, Seen{cell, r.price, f32(r.month), g})
		}
	}
	sandbox.trader_destroy(t)
}

// trader_visit: a player standing in a town sees its prices and is told what it knows.
trader_visit :: proc(s: ^core.Server, w: ^core.World, c: ^core.Client) {
	town, ok := trader_where(w, c)
	if !ok {return}
	we := world_of(w).economy
	t := trader_open(we, trader(s, c), we.market.local[town])
	trader_close(we, trader(s, c), &t)
}

// trade: the player buys or sells `quantity` units (a person's month of the good) in a town
// (an index in the economy). A buy may be filled in part when the stock or the silver runs out;
// a sell is of the whole quantity or refused. Returns what was done and the units moved.
trade :: proc(
	s: ^core.Server,
	w: ^core.World,
	c: ^core.Client,
	town: int,
	g: sandbox.Good,
	quantity: f32,
	side: Trade_Side,
) -> (
	sandbox.Refusal,
	f32,
) {
	we := world_of(w).economy
	if we == nil || !we.built || !we.resident || town < 0 || town >= len(we.economy.towns) {
		return .No_Economy, 0
	}
	local := we.market.local[town]
	if local < 0 {return .No_Economy, 0}
	if !(quantity > 0) || math.is_inf(quantity) {return .Bad_Quantity, 0}
	tw := we.economy.towns[town]
	o := economy_observer(c)
	if sandbox.km_between(tw.lat, tw.lon, f32(o.x), f32(o.y)) >= TRADE_RADIUS_KM {return .Away, 0}
	if !tw.market[g] {return .No_Market, 0}
	rec := trader(s, c)
	if side == .Sell && rec.cargo[int(g)] < quantity {return .No_Cargo, 0}

	t := trader_open(we, rec, local)
	moved: f32
	result := sandbox.Refusal.None
	switch side {
	case .Buy:
		moved = sandbox.trader_buy(&t, we.economy, &we.market, g, quantity)
		if moved <= 0 {
			step := f32(sandbox.IMPACT_STEP) * tw.size
			if we.market.stock[local][g] - step / tw.size <= sandbox.RESERVE {
				result = .No_Stock
			} else {
				result = .No_Cash
			}
		}
	case .Sell:
		moved = sandbox.trader_sell(&t, we.economy, &we.market, g, quantity)
	}
	trader_close(we, rec, &t)
	if moved > 0 {we.dirty = true}
	return result, moved
}

// ---- the market on the wire ----

#assert(len(sandbox.Good) == len(sandbox.Town_Market{}.goods))

// market_view builds what a player in a town sees. `town` is an index in the economy.
@(private = "file")
market_view :: proc(
	s: ^core.Server,
	w: ^core.World,
	c: ^core.Client,
	town: int,
) -> sandbox.Town_Market {
	we := world_of(w).economy
	local := we.market.local[town]
	tw := we.economy.towns[town]
	rec := trader(s, c)
	v := sandbox.Town_Market {
		town = market_town_name(tw),
		cash = rec.cash,
	}
	for g in sandbox.Good {
		e := &v.goods[g]
		e.age = -1
		if !tw.market[g] {continue}
		e.deals = true
		e.price = sandbox.market_price(we.economy, we.market, local, g)
		e.stock = we.market.stock[local][g] * tw.size
		e.cargo = rec.cargo[int(g)]
		if seen, ok := trader_known(rec, u32(tw.cell), g); ok {
			e.age = f32((we.market.month - f64(seen.month)) * MONTH_DAYS)
		}
	}
	return v
}

// market_town_name: what the town is called (its climate cell numbers it; the peoples' names
// are not kept with the economy).
@(private = "file")
market_town_name :: proc(t: sandbox.Town) -> string {
	buf: [20]u8
	return strings.concatenate(
		{"Town ", strconv.write_int(buf[:], i64(t.cell), 10)},
		context.temp_allocator,
	)
}

// market_update (once a second, for a playing client): the market of the town it stands in,
// or none; a record put again unchanged sends nothing.
market_update :: proc(s: ^core.Server, c: ^core.Client) {
	v: sandbox.Town_Market
	if town, ok := trader_where(c.world, c); ok {v = market_view(s, c.world, c, town)}
	core.game_put(s, c, &v)
}

// market_trade answers a trade: the market as it is after it, or why it was refused.
market_trade :: proc(s: ^core.Server, c: ^core.Client, m: sandbox.Trade) {
	w := c.world
	town, ok := trader_where(w, c)
	if !ok {
		refused := sandbox.Trade_Refused{.Away}
		we := world_of(w).economy
		if w.params.planet == 0 ||
		   we == nil ||
		   !we.built ||
		   !we.resident {refused.reason = .No_Economy}
		core.game_event(s, c, &refused)
		return
	}
	result := sandbox.Refusal.Bad_Quantity // (more than a trade may move: a forged request)
	if m.quantity <= sandbox.MAX_TRADE_QUANTITY {
		result, _ = trade(s, w, c, town, m.good, m.quantity, .Sell if m.sell else .Buy)
	}
	if result != .None {
		refused := sandbox.Trade_Refused{result}
		core.game_event(s, c, &refused)
		return
	}
	v := market_view(s, w, c, town)
	core.game_put(s, c, &v)
}

// market_ask: the player's market action. In a town its client part is told to open the
// market's screen; elsewhere nothing happens (its HUD says when there is a market).
market_ask :: proc(s: ^core.Server, c: ^core.Client) {
	town, ok := trader_where(c.world, c)
	if !ok {return}
	v := market_view(s, c.world, c, town)
	core.game_put(s, c, &v)
	open := sandbox.Market_Open{v.town}
	core.game_event(s, c, &open)
}

// TOWN_DROP: the height a player taken to a town is set down from (it lands on the ground).
TOWN_DROP :: 200
// LANDING_STEP: blocks between the columns a town's landing tries, ring by ring.
LANDING_STEP :: 3

// town_landing: where a player taken to a town is set down: the dry land nearest the town's
// place (its climate cell's centre, which may be sea, a lake or a river) within its trade
// radius, so they arrive in its market. False: the town has none (a town on an islet).
town_landing :: proc(w: ^core.World, tw: sandbox.Town) -> (x, z: i32, ok: bool) {
	cx, cz := worldgen.planet_block_of(f64(tw.lat), f64(tw.lon))
	best := i32(max(i32))
	for ring: i32 = 0;; ring += LANDING_STEP {
		on_ring := false
		for dz := -ring; dz <= ring; dz += LANDING_STEP {
			for dx := -ring; dx <= ring; dx += LANDING_STEP {
				if max(abs(dx), abs(dz)) != ring {continue}
				lat, lon := worldgen.planet_lat_lon(cx + dx, cz + dz)
				if sandbox.km_between(tw.lat, tw.lon, f32(lat), f32(lon)) >= TRADE_RADIUS_KM - 1 {
					continue
				}
				on_ring = true
				if d := dx * dx + dz * dz; d < best && dry_land(w, cx + dx, cz + dz) {
					best, x, z, ok = d, cx + dx, cz + dz, true
				}
			}
		}
		if ok || !on_ring {return} 	// (the nearest ring with land, or past the radius)
	}
}

// dry_land: block column (x, z) of a planet world is ground above the water: no sea, lake or
// river covers it.
dry_land :: proc(w: ^core.World, x, z: i32) -> bool {
	params := w.params
	c := worldgen.column_at(&params, w.seed, x, z)
	#partial switch c.biome {
	case .Ocean, .Frozen_Ocean, .River:
		return false
	}
	lake, _ := worldgen.planet_lake_at(x, z)
	return c.height >= f32(params.sea_level) + 1 && c.river < 0.5 && lake < 0.5
}

// town_command: `/town` takes the player to the nearest town with a market and dry land in
// its radius, set down from above that land (the teleport permission; a planet world whose
// towns are known).
town_command :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	if !core.allowed(s, c, "teleport.tp") {
		core.notice(s, c, "You may not teleport here")
		return true
	}
	w := c.world
	we := world_of(w).economy
	if w.params.planet == 0 || we == nil || !we.built {
		core.notice(
			s,
			c,
			"No towns are known here (a world on the planet knows them soon after you arrive)",
		)
		return true
	}
	o := economy_observer(c)
	Near :: struct {
		town: int,
		km:   f64,
	}
	near := make([dynamic]Near, context.temp_allocator)
	for tw, i in we.economy.towns {
		if tw.market == {} {continue}
		append(&near, Near{i, sandbox.km_between(tw.lat, tw.lon, f32(o.x), f32(o.y))})
	}
	slice.sort_by(near[:], proc(a, b: Near) -> bool {return a.km < b.km})
	for n in near {
		tw := we.economy.towns[n.town]
		x, z := town_landing(w, tw) or_continue
		core.teleport(s, c, {f64(x) + 0.5, TOWN_DROP, f64(z) + 0.5}, {0, 0})
		core.notice(s, c, fmt.tprintf("To %s, %.0f km away", market_town_name(tw), n.km))
		return true
	}
	core.notice(s, c, "No town here has a market on dry land")
	return true
}
