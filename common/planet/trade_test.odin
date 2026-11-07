package planet

import "core:testing"

@(private = "file")
fixture :: proc(p: Planet, limit: int) -> [dynamic]Settlement {
	list := make([dynamic]Settlement)
	w, h := p.land.width, p.land.height
	land := 0
	for k in 0 ..< w * h {if p.land.is_land[k] {land += 1}}
	stride := max(land / limit, 1)
	seen := 0
	for k in 0 ..< w * h {
		if !p.land.is_land[k] {continue}
		seen += 1
		if seen % stride == 0 {append(&list, town_at(p, k, 1 + k % 2, f32(500 + k % 7 * 500)))}
	}
	return list
}

@(private = "file")
island :: proc(e: Economy) -> []int {
	all := make([]int, len(e.towns))
	for i in 0 ..< len(all) {all[i] = i}
	return all
}

@(test)
test_caravan_arrival_updates_knowledge_of_origin :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)
	list := fixture(p, 150)
	defer delete(list)
	e := economy_build(p, list[:], nil)
	defer economy_destroy(&e)
	all := island(e)
	defer delete(all)
	m := market_make(e, all, 0)
	defer market_destroy(&m)
	n := news_make(e, m)
	defer news_destroy(&n)
	c: Convoy
	defer convoy_destroy(&c)

	// A town with a way and a good both ends trade.
	a, b, g := -1, -1, Good.Grain
	for i in 0 ..< len(e.towns) {
		for l in e.links[e.link_first[i]:e.link_first[i + 1]] {
			if e.towns[i].market[g] && e.towns[l.to].market[g] && a < 0 {a, b = i, l.to}
		}
	}
	testing.expect(t, a >= 0)
	testing.expect(t, !n.town[b].at[a][g].known, "a town knows another's prices before any news")
	months := 0
	for months < 12 && !n.town[b].at[a][g].known {
		convoy_step(e, &m, n, &c, nil)
		months += 1
	}
	rep := n.town[b].at[a][g]
	testing.expect(t, rep.known, "no caravan from the origin arrived in a year")
	age := knowledge_age(n.town[b], a, g, m.month)
	testing.expectf(t, age >= 0 && age <= 3, "the news is %v months old", age)
	testing.expect(t, rep.month < m.month, "the news is as new as the town's own")
	testing.expect(t, rep.price > 0)
}

@(test)
test_trader_buys_and_sells :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)
	list := fixture(p, 150)
	defer delete(list)
	e := economy_build(p, list[:], nil)
	defer economy_destroy(&e)
	all := island(e)
	defer delete(all)
	m := market_make(e, all, 0)
	defer market_destroy(&m)

	i := 0
	for !e.towns[i].market[.Grain] {i += 1}
	tr := trader_make(m, 1e6, i)
	defer trader_destroy(&tr)
	before := market_price(e, m, i, .Grain)
	bought := trader_buy(&tr, e, &m, .Grain, 100)
	testing.expect(t, bought > 0 && abs(tr.cargo[.Grain] - bought) < 1e-3)
	testing.expect(t, tr.cash < 1e6, "buying cost nothing")
	testing.expect(t, market_price(e, m, i, .Grain) > before, "buying did not raise the price")
	spent := 1e6 - tr.cash
	sold := trader_sell(&tr, e, &m, .Grain, bought)
	testing.expect(t, abs(sold - bought) < 1e-3 && tr.cargo[.Grain] < 1e-3)
	testing.expect(t, 1e6 - tr.cash > 0 && tr.cash < 1e6, "a round trip in one town paid")
	testing.expect(t, spent > 0)
	testing.expect(
		t,
		tr.know.at[i][.Grain].known,
		"the trader does not know the price they traded at",
	)
	testing.expect(t, trade_matters(e.towns[i].size, e.towns[i]))
	testing.expect(t, !trade_matters(1, e.towns[i]))
	// Nothing to sell, nothing sold; no money, nothing bought.
	testing.expect(t, trader_sell(&tr, e, &m, .Grain, 5) == 0)
	broke := trader_make(m, 0, i)
	defer trader_destroy(&broke)
	testing.expect(t, trader_buy(&broke, e, &m, .Grain, 5) == 0)
}
