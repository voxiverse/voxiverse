package planet

import "core:fmt"
import "core:testing"

@(private = "file")
DAY :: i64(6000 * DAYS_PER_YEAR)

@(test)
test_settlements_consistent :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)

	cache: Settlement_Cache
	defer settlement_cache_destroy(&cache)
	got := 0
	standing, ruined := 0, 0
	for seed in u64(1) ..= 4 {
		list := settlements_at(&cache, p, 9, seed, DAY, nil)
		hist := cache.history
		got += len(list)
		for s in list {
			testing.expect(t, s.cell >= 0 && p.land.is_land[s.cell])
			testing.expect(t, s.people >= 0 && s.people < len(hist.peoples))
			if s.ruined < 0 {
				standing += 1
				// On a cell its people hold, sized by the people living there.
				testing.expect_value(t, int(hist.owner[s.cell]), s.people + 1)
				testing.expect_value(t, s.size, hist.pop[s.cell])
				testing.expect_value(t, s.era, hist.peoples[s.people].era)
				testing.expect(t, s.founded <= hist.years)
			} else {
				ruined += 1
				testing.expect_value(t, hist.owner[s.cell], 0)
				found := false
				for e in hist.events {
					if e.kind == .Collapse && e.people == s.people && e.year == s.ruined {
						found = true
					}
				}
				testing.expectf(t, found, "ruin at %d has no chronicle event", s.cell)
				testing.expect(t, s.founded <= s.ruined)
			}
		}
		for road in roads_at(&cache, p, 9, seed, DAY, nil) {
			testing.expect(t, len(road.cells) >= 2)
			for k in road.cells {testing.expect(t, p.land.is_land[k])}
		}
		// Asked twice, the same answer (the cache; and a fresh one).
		again := settlements_at(&cache, p, 9, seed, DAY, nil)
		testing.expect(t, raw_data(again) == raw_data(list))
		fresh: Settlement_Cache
		defer settlement_cache_destroy(&fresh)
		other := settlements_at(&fresh, p, 9, seed, DAY, nil)
		testing.expect(t, len(other) == len(list))
		for s, i in list {testing.expect(t, s == other[i])}
	}
	fmt.printfln("%d settlements (%d standing, %d ruined) over 4 worlds", got, standing, ruined)
	testing.expect(t, standing > 0 && ruined > 0)
}

@(test)
test_settlements_follow_history :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)

	cache: Settlement_Cache
	defer settlement_cache_destroy(&cache)
	settlements_at(&cache, p, 7, 3, DAY, nil)
	first := cache.key
	// The same decade: cached. An intervention: recomputed.
	settlements_at(&cache, p, 7, 3, DAY + 100, nil)
	testing.expect_value(t, cache.key, first)
	iv := Intervention {
		day  = 3000 * DAYS_PER_YEAR,
		lat  = 30,
		lon  = 30,
		kind = INTERVENTION_SETTLEMENT,
	}
	settlements_at(&cache, p, 7, 3, DAY, {iv})
	testing.expect(t, cache.key != first)
}
