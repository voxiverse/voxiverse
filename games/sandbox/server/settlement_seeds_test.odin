package sandbox_server

import "core:log"
import "core:math"
import "core:testing"

import "common:worldgen"
import "server:core"
import "server:playtest"

// The camps across seeds (settlements_plan): always SETTLEMENTS of them, a journey from the
// spawn, apart from each other, clear of the ruin, the remains and the generator's
// structures, on dry land, level for nearly all and never far from it, no two of a layout alike, the same
// plan every time for a seed; and what planning costs (the land's columns sampled).

CAMP_SEEDS :: 40

@(test)
test_settlements_over_seeds :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := new(core.World)
	defer free(w)
	rm := new(Remains)
	defer free(rm)
	ss, again := new(Settlements), new(Settlements)
	defer free(ss)
	defer free(again)
	level, total, most_samples, samples, dry := 0, 0, 0, 0, 0
	spreads: [32]int
	nearest_far, farthest := max(f64), 0.0
	for n in i64(1) ..= CAMP_SEEDS {
		seed := n * 7919
		w.generator = .Earth
		w.params = worldgen.PARAMS_DEFAULTS
		w.params.home_gate = 1
		w.seed = seed
		gen := worldgen.generator_make(.Earth, seed, s.registry, w.params)
		w.spawn.position = worldgen.spawn_point(&gen)
		land := land_of(w)
		ruin := ruin_footprint(ruin_site(w))
		rm^ = {}
		remains_plan(rm, &land, &gen, seed, ruin)
		land.samples = 0
		ss^, again^ = {}, {}
		settlements_plan(ss, &land, &gen, seed, w.spawn.position, ruin, rm)
		samples += land.samples
		most_samples = max(most_samples, land.samples)
		settlements_plan(again, &land, &gen, seed, w.spawn.position, ruin, rm)
		testing.expectf(t, ss^ == again^, "seed %d: two plans differ", seed)
		if !testing.expectf(
			t,
			ss.count == SETTLEMENTS && ss.plan_count == ss.count,
			"seed %d: %d camps",
			seed,
			ss.count,
		) {
			continue
		}
		layouts: bit_set[Layout]
		for i in 0 ..< ss.count {
			st := &ss.list[i]
			total += 1
			if st.site.level {level += 1}
			_, _, _, here := site_ground(
				&land,
				st.middle.x,
				st.middle.y,
				SETTLEMENT_MID + SETTLEMENT_APRON,
			)
			if here {dry += 1}
			spreads[min(st.site.hi - st.site.lo, 31)] += 1
			layouts += {st.layout}
			testing.expect(t, settlement_name(st) != "")
			testing.expectf(
				t,
				int(st.roles) == i,
				"seed %d: camp %d has the people of %d",
				seed,
				i,
				st.roles,
			)
			at := settlement_footprint(st.middle)
			d := settlement_middle(st) - w.spawn.position
			far := math.sqrt(d.x * d.x + d.z * d.z)
			testing.expectf(
				t,
				far >= SETTLEMENT_NEAR - 1,
				"seed %d: a camp %.0f blocks from the spawn",
				seed,
				far,
			)
			if i == 0 {nearest_far = min(nearest_far, far)}
			farthest = max(farthest, far)
			testing.expectf(
				t,
				!footprint_meets(at, ruin, SETTLEMENT_CLEAR),
				"seed %d: camp %d by the ruin",
				seed,
				i,
			)
			for site in rm.sites[:rm.count] {
				testing.expectf(
					t,
					site.kind == .Road || !footprint_meets(at, site.at, SETTLEMENT_CLEAR),
					"seed %d: camp %d by a %v",
					seed,
					i,
					site.kind,
				)
			}
			found := make([dynamic]worldgen.Structure, context.temp_allocator)
			worldgen.structures_near(&gen, at.lo, at.hi, &found)
			testing.expectf(t, len(found) == 0, "seed %d: camp %d on a structure", seed, i)
			for j in 0 ..< i {
				o := ss.list[j].middle - st.middle
				testing.expectf(
					t,
					o.x * o.x + o.y * o.y >= SETTLEMENT_APART * SETTLEMENT_APART,
					"seed %d: camps %d and %d too near",
					seed,
					j,
					i,
				)
			}
			if i > 0 {
				p := settlement_middle(&ss.list[i - 1]) - w.spawn.position
				testing.expectf(
					t,
					p.x * p.x + p.z * p.z <= d.x * d.x + d.z * d.z,
					"seed %d: not nearest first",
					seed,
				)
			}
		}
		testing.expectf(t, card(layouts) == SETTLEMENTS, "seed %d: two camps of a layout", seed)
	}
	log.infof(
		"settlements over %d seeds: %d of %d on dry level land, the nearest at least %.0f blocks out, the farthest %.0f; planning sampled the land %.0f times a world on average, %d at most",
		CAMP_SEEDS,
		level,
		total,
		nearest_far,
		farthest,
		f64(samples) / CAMP_SEEDS,
		most_samples,
	)
	log.infof("settlements: %d dry; spread histogram %v", dry, spreads)
	worst := 0
	for n, spread in spreads {if n > 0 {worst = spread}}
	testing.expectf(t, dry == total, "only %d of %d camps on dry land", dry, total)
	testing.expectf(
		t,
		level * 100 >= total * 85,
		"only %d of %d camps on level land",
		level,
		total,
	)
	testing.expectf(t, worst <= 2 * SETTLEMENT_LEVEL, "a camp on land %d uneven", worst)
}
