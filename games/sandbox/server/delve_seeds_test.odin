package sandbox_server

import "core:log"
import "core:math"
import "core:testing"

import "common:worldgen"
import "server:core"
import "server:playtest"

// The delves across seeds (delve_sites): two or three a world, each DELVE_NEAR to DELVE_FAR
// blocks from the spawn, its stair head on dry, even land and the land over it dry and never
// under its first depth's roof, clear of the ruin, the remains, the camps, the generator's
// structures and each other; the same sites every time for a seed.

@(test)
test_delve_sites_over_seeds :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := new(core.World)
	defer free(w)
	rm := new(Remains)
	defer free(rm)
	fewest, most, total := max(int), 0, 0
	worst_spread: i32
	for n in i64(1) ..= SEEDS {
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
		ss := new(Settlements, context.temp_allocator)
		settlements_plan(ss, &land, &gen, seed, w.spawn.position, ruin, rm)
		camps: [MAX_SETTLEMENTS]Footprint
		for st, i in ss.list[:ss.plan_count] {camps[i] = settlement_footprint(st.middle)}
		sites, again: [MAX_DELVES]Delve_Site
		count := delve_sites(
			&sites,
			&land,
			&gen,
			seed,
			w.spawn.position,
			ruin,
			rm,
			camps[:ss.plan_count],
		)
		testing.expectf(
			t,
			delve_sites(
				&again,
				&land,
				&gen,
				seed,
				w.spawn.position,
				ruin,
				rm,
				camps[:ss.plan_count],
			) ==
				count &&
			sites == again,
			"seed %d: two plans differ",
			seed,
		)
		fewest, most, total = min(fewest, count), max(most, count), total + count
		for site, i in sites[:count] {
			at := delve_footprint(site.middle, delve_plan(site.seed).entry)
			d := [2]f64 {
				f64(site.middle.x) - w.spawn.position.x,
				f64(site.middle.y) - w.spawn.position.z,
			}
			far := math.sqrt(d.x * d.x + d.y * d.y)
			testing.expectf(
				t,
				far >= DELVE_NEAR - 1 && far <= DELVE_FAR + 1,
				"seed %d: a delve %.0f blocks out",
				seed,
				far,
			)
			testing.expectf(
				t,
				!footprint_meets(at, ruin, DELVE_CLEAR - 1),
				"seed %d: a delve meets the ruin",
				seed,
			)
			for r in rm.sites[:rm.count] {
				testing.expectf(
					t,
					!footprint_meets(at, r.at, DELVE_CLEAR - 1),
					"seed %d: a delve meets a %v",
					seed,
					r.kind,
				)
			}
			for camp in camps[:ss.plan_count] {
				testing.expectf(
					t,
					!footprint_meets(at, camp, DELVE_CLEAR - 1),
					"seed %d: a delve meets a camp",
					seed,
				)
			}
			for o in sites[:i] {
				ot := delve_footprint(o.middle, delve_plan(o.seed).entry)
				testing.expectf(
					t,
					!footprint_meets(at, ot, DELVE_APART - 1),
					"seed %d: two delves meet",
					seed,
				)
			}
			found := make([dynamic]worldgen.Structure, context.temp_allocator)
			worldgen.structures_near(&gen, at.lo, at.hi, &found)
			testing.expectf(t, len(found) == 0, "seed %d: a delve meets a structure", seed)
			lo, hi := max(i32), min(i32)
			R :: DELVE_LEVELLED
			for z in site.middle.y - R ..= site.middle.y + R {
				for x in site.middle.x - R ..= site.middle.x + R {
					top, _ := land_at(&land, x, z)
					lo, hi = min(lo, top), max(hi, top)
				}
			}
			worst_spread = max(worst_spread, hi - lo)
		}
	}
	log.infof(
		"delves over %d seeds: %d to %d a world (%.2f on average), the land round a stair head at most %d uneven",
		SEEDS,
		fewest,
		most,
		f64(total) / SEEDS,
		worst_spread,
	)
	testing.expectf(t, fewest >= DELVE_FEWEST - 1, "a world with %d delves", fewest)
	testing.expectf(t, total >= SEEDS * 2, "only %.2f delves a world", f64(total) / SEEDS)
}
