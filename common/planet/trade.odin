package planet

// The economy, part 3 (docs/world.md, the economy): news at the speed of travellers, caravans
// on the ways between towns, and a player who trades. Nothing here is random.
//
// Every town of an island keeps `Knowledge`: for each other town and good, the price it last
// heard and the month that price was *true* (so the news has an age). A caravan leaves a town
// with a copy of what that town knew, refreshed with its own current prices, and when it
// arrives the destination keeps the newer of each entry. A `Trader` (the player) holds the
// same kind of knowledge: what they saw at the towns they were in, and what they were told.
// Towns are indexed as in the island's `Market` (`Market.town`).

CARAVAN_KM_PER_MONTH :: 600.0 // a caravan covers about 20 km a day
DETOUR :: 1.3 // a way is this much longer than the line between its towns
CARAVAN_EVERY :: 1 // months between a way's departures (staggered by the way)
SPREAD :: 0.05 // a town buys at this much under its price and sells at this much over
IMPACT_STEP :: 0.01 // months of need: a trade moves the price in steps of this much stock
TRADED_SHARE :: 0.25 // a trade of this share of a town's monthly need matters to the history

// Report is what one place knows of one town's price of one good.
Report :: struct {
	price: f32,
	month: f64, // when the price was true
	known: bool,
}

// Knowledge is what one observer knows: a report per town (of the island) and good.
Knowledge :: struct {
	at: [][Good]Report,
}

knowledge_make :: proc(towns: int, allocator := context.allocator) -> Knowledge {
	return Knowledge{at = make([][Good]Report, towns, allocator)}
}

knowledge_destroy :: proc(k: ^Knowledge) {
	delete(k.at)
	k^ = {}
}

knowledge_copy :: proc(k: Knowledge, allocator := context.allocator) -> Knowledge {
	c := knowledge_make(len(k.at), allocator)
	copy(c.at, k.at)
	return c
}

// knowledge_see records a price as of a month, unless something newer is already known.
knowledge_see :: proc(k: ^Knowledge, town: int, g: Good, price: f32, month: f64) {
	r := &k.at[town][g]
	if r.known && r.month >= month {return}
	r^ = Report{price, month, true}
}

// knowledge_see_town records every good's current price in a town (being there).
knowledge_see_town :: proc(k: ^Knowledge, e: Economy, m: Market, town: int) {
	for g in Good {
		if e.towns[m.town[town]].market[g] {
			knowledge_see(k, town, g, market_price(e, m, town, g), m.month)
		}
	}
}

// knowledge_merge takes from `from` every report newer than what `into` holds.
knowledge_merge :: proc(into: ^Knowledge, from: Knowledge) {
	for town in 0 ..< len(into.at) {
		for g in Good {
			r := from.at[town][g]
			if r.known {knowledge_see(into, town, g, r.price, r.month)}
		}
	}
}

// knowledge_age is how old a report is at a month, in months; -1 where nothing is known.
knowledge_age :: proc(k: Knowledge, town: int, g: Good, month: f64) -> f64 {
	r := k.at[town][g]
	return month - r.month if r.known else -1
}

// News is what each town of an island knows (indexed as in the island's market).
News :: struct {
	town: []Knowledge,
}

news_make :: proc(e: Economy, m: Market, allocator := context.allocator) -> News {
	n := News {
		town = make([]Knowledge, len(m.town), allocator),
	}
	for &k, i in n.town {
		k = knowledge_make(len(m.town), allocator)
		knowledge_see_town(&k, e, m, i)
	}
	return n
}

news_destroy :: proc(n: ^News) {
	for &k in n.town {knowledge_destroy(&k)}
	delete(n.town)
	n^ = {}
}

// Caravan is on a way from one town to another, with what its origin knew when it left.
Caravan :: struct {
	from, to: int, // town indices in the market
	depart:   f64, // month
	arrive:   f64,
	news:     Knowledge,
}

Convoy :: struct {
	caravans: [dynamic]Caravan,
}

convoy_destroy :: proc(c: ^Convoy) {
	for &v in c.caravans {knowledge_destroy(&v.news)}
	delete(c.caravans)
	c^ = {}
}

// travel_months is how long a caravan (or a traveller) takes between two towns of the economy.
travel_months :: proc(e: Economy, a, b: int) -> f64 {
	ta, tb := e.towns[a], e.towns[b]
	return km_between(ta.lat, ta.lon, tb.lat, tb.lon) * DETOUR / CARAVAN_KM_PER_MONTH
}

// convoy_step runs the island a month with its news: the market ticks, caravans that have
// reached their destination hand over what they carry, and each way's turn sends a new one
// out with the origin's knowledge, refreshed with its prices of the month. Caravans carry
// news and the merchants' goods the market already moves (`market_step`).
convoy_step :: proc(e: Economy, m: ^Market, n: News, c: ^Convoy, ds: []Drought) {
	for i in 0 ..< len(n.town) {knowledge_see_town(&n.town[i], e, m^, i)}
	for i in 0 ..< len(m.town) {
		for l, k in e.links[e.link_first[m.town[i]]:e.link_first[m.town[i] + 1]] {
			j := m.local[l.to]
			if j < 0 || (int(m.month) + k + i) % CARAVAN_EVERY != 0 {continue}
			v := Caravan {
				from   = i,
				to     = j,
				depart = m.month,
				arrive = m.month + travel_months(e, m.town[i], l.to),
				news   = knowledge_copy(n.town[i]),
			}
			append(&c.caravans, v)
		}
	}
	market_step(e, m, ds)
	convoy_arrive(n, c, m.month)
}

// convoy_arrive hands over the news of every caravan that has arrived by a month.
convoy_arrive :: proc(n: News, c: ^Convoy, month: f64) {
	for i := 0; i < len(c.caravans); {
		v := &c.caravans[i]
		if v.arrive > month {i += 1; continue}
		knowledge_merge(&n.town[v.to], v.news)
		knowledge_destroy(&v.news)
		unordered_remove(&c.caravans, i)
	}
}

// Trader is a player who trades: what they carry, what it cost, where they are and what
// they know of the prices of the island's towns.
Trader :: struct {
	cash:  f64,
	cargo: [Good]f32, // units: one is a person's month of the good
	at:    int, // town index in the market
	know:  Knowledge,
}

trader_make :: proc(m: Market, cash: f64, at: int) -> Trader {
	return Trader{cash = cash, at = at, know = knowledge_make(len(m.town))}
}

trader_destroy :: proc(t: ^Trader) {
	knowledge_destroy(&t.know)
	t^ = {}
}

// trader_arrive puts the trader in a town: they see its prices as they are and are told what
// the town knows of the others.
trader_arrive :: proc(t: ^Trader, e: Economy, m: Market, n: News, town: int) {
	t.at = town
	knowledge_merge(&t.know, n.town[town])
	knowledge_see_town(&t.know, e, m, town)
}

// trader_buy buys up to `units` of a good where the trader is, at the town's price over the
// stock as it falls, paying `SPREAD` over it. Returns the units bought.
trader_buy :: proc(t: ^Trader, e: Economy, m: ^Market, g: Good, units: f32) -> f32 {
	i := t.at
	size := e.towns[m.town[i]].size
	if !e.towns[m.town[i]].market[g] {return 0}
	got := f32(0)
	for got < units {
		step := min(f32(IMPACT_STEP) * size, units - got)
		if m.stock[i][g] - step / size <= RESERVE {break}
		cost := f64(market_price(e, m^, i, g)) * (1 + SPREAD) * f64(step)
		if cost > t.cash {break}
		t.cash -= cost
		m.stock[i][g] -= step / size
		got += step
	}
	t.cargo[g] += got
	knowledge_see(&t.know, i, g, market_price(e, m^, i, g), m.month)
	return got
}

// trader_sell sells up to `units` of a good carried where the trader is, at the town's price
// as the stock rises, receiving `SPREAD` under it. Returns the units sold.
trader_sell :: proc(t: ^Trader, e: Economy, m: ^Market, g: Good, units: f32) -> f32 {
	i := t.at
	size := e.towns[m.town[i]].size
	if !e.towns[m.town[i]].market[g] {return 0}
	sold := f32(0)
	want := min(units, t.cargo[g])
	for sold < want {
		step := min(f32(IMPACT_STEP) * size, want - sold)
		t.cash += f64(market_price(e, m^, i, g)) * (1 - SPREAD) * f64(step)
		m.stock[i][g] = min(m.stock[i][g] + step / size, STOCK_MAX)
		sold += step
	}
	t.cargo[g] -= sold
	knowledge_see(&t.know, i, g, market_price(e, m^, i, g), m.month)
	return sold
}

// trade_matters says whether a trade of `units` in a town is large enough to be an
// intervention in the history (a `Traded`, #131).
trade_matters :: proc(units: f32, t: Town) -> bool {
	return units >= TRADED_SHARE * t.size
}
