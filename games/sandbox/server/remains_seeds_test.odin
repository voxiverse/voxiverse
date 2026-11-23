package sandbox_server

import "core:log"
import "core:math"
import "core:testing"

import "common:worldgen"
import "server:core"
import "server:playtest"

// The remains across seeds (remains_plan): the court round the home gate; every site within
// its range, on dry land as even as its kind asks, clear of the others, the ruin and the
// generator's structures; the same plan every time for a seed.

SEEDS :: 60

// plan_for: the remains of the home world a seed makes (the Earth generator, its home gate
// and spawn as a new sandbox universe's), the generator they were planned with.
@(private = "file")
plan_for :: proc(s: ^core.Server, w: ^core.World, seed: i64, rm: ^Remains) -> worldgen.Generator {
	w.generator = .Earth
	w.params = worldgen.PARAMS_DEFAULTS
	w.params.home_gate = 1
	w.seed = seed
	gen := worldgen.generator_make(.Earth, seed, s.registry, w.params)
	w.spawn.position = worldgen.spawn_point(&gen)
	land := land_of(w)
	rm^ = {}
	remains_plan(rm, &land, &gen, seed, ruin_footprint(ruin_site(w)))
	return gen
}

// footprint_land: the most minus the least height of the land under a footprint (every
// column), and the share of its columns that are not dry ground.
@(private = "file")
footprint_land :: proc(w: ^core.World, at: Footprint) -> (spread: i32, wet: f64) {
	land := land_of(w)
	lo, hi := max(i32), min(i32)
	n, wet_n := 0, 0
	for z in at.lo.y ..= at.hi.y {
		for x in at.lo.x ..= at.hi.x {
			top, dry := land_at(&land, x, z)
			lo, hi = min(lo, top), max(hi, top)
			n += 1
			if !dry {wet_n += 1}
		}
	}
	return hi - lo, f64(wet_n) / f64(n)
}

@(test)
test_remains_over_seeds :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := new(core.World)
	defer free(w)
	rm, again := new(Remains), new(Remains)
	defer free(rm)
	defer free(again)
	placed: [Remain_Kind]int
	worlds_with: [Remain_Kind]int
	fewest, most, total := max(int), 0, 0
	chests := 0
	worst_spread: [Remain_Kind]i32
	worst_wet: f64
	for n in i64(1) ..= SEEDS {
		seed := n * 7919
		gen := plan_for(s, w, seed, rm)
		plan_for(s, w, seed, again)
		testing.expectf(t, rm^ == again^, "seed %d: two plans differ", seed)
		gate, has_gate := gen.home.?
		if !testing.expectf(t, has_gate && rm.count > 0, "seed %d: no home gate, no court", seed) {
			continue
		}
		court := rm.sites[0]
		testing.expectf(
			t,
			court.kind == .Court && court.floor == gate.lo.y + 1,
			"seed %d: the court %v",
			seed,
			court,
		)
		ruin := ruin_footprint(ruin_site(w))
		scattered := 0
		seen: bit_set[Remain_Kind]
		for site, i in rm.sites[:rm.count] {
			placed[site.kind] += 1
			seen += {site.kind}
			testing.expectf(
				t,
				!footprint_meets(site.at, ruin, 0),
				"seed %d: %v meets the ruin",
				seed,
				site.kind,
			)
			for o in rm.sites[:i] {
				margin: i32 = 0
				if site.kind != .Road &&
				   site.kind != .Court &&
				   o.kind != .Road &&
				   o.kind != .Court {
					margin = REMAINS_APART
				}
				testing.expectf(
					t,
					!footprint_meets(site.at, o.at, margin),
					"seed %d: %v at %v meets %v at %v",
					seed,
					site.kind,
					site.middle,
					o.kind,
					o.middle,
				)
			}
			if site.kind == .Court {continue}
			found := make([dynamic]worldgen.Structure, context.temp_allocator)
			worldgen.structures_near(&gen, site.at.lo, site.at.hi, &found)
			for f in found {
				testing.expectf(t, f == gate, "seed %d: %v meets a %v", seed, site.kind, f.kind)
			}
			spread, wet := footprint_land(w, site.at if site.kind == .Road else remain_stand(site))
			worst_spread[site.kind] = max(worst_spread[site.kind], spread)
			if site.kind == .Road {continue}
			scattered += 1
			worst_wet = max(worst_wet, wet)
			if site.kind == .Vault {chests += 1}
			d := [2]f64{f64(site.middle.x - court.middle.x), f64(site.middle.y - court.middle.y)}
			far := math.sqrt(d.x * d.x + d.y * d.y)
			testing.expectf(
				t,
				far >= REMAINS_NEAR - 1 && far <= REMAINS_FAR + 1,
				"seed %d: a %v %.0f blocks from the gate",
				seed,
				site.kind,
				far,
			)
			testing.expectf(
				t,
				wet <= 0.2,
				"seed %d: a %v %.0f%% on wet ground",
				seed,
				site.kind,
				wet * 100,
			)
			testing.expectf(
				t,
				spread <= REMAIN_SHAPES[site.kind].spread + 6,
				"seed %d: a %v on land %d uneven",
				seed,
				site.kind,
				spread,
			)
		}
		for k in seen {worlds_with[k] += 1}
		if scattered <
		   5 {log.infof("seed %d: %d scattered sites, the gate at %v", seed, scattered, court.middle)}
		fewest, most, total = min(fewest, scattered), max(most, scattered), total + scattered
	}
	log.infof(
		"remains over %d seeds: scattered sites %d to %d a world (%.1f on average), road stretches %d, %d vaults",
		SEEDS,
		fewest,
		most,
		f64(total) / SEEDS,
		placed[.Road],
		chests,
	)
	for k in Remain_Kind {
		log.infof(
			"remains %v: %d placed, in %d of %d worlds, land at most %d uneven",
			k,
			placed[k],
			worlds_with[k],
			SEEDS,
			worst_spread[k],
		)
	}
	log.infof("remains: at most %.0f%% of a scattered site on wet ground", worst_wet * 100)
	for k in Remain_Kind {
		if k == .Court {continue}
		testing.expectf(
			t,
			worlds_with[k] >= SEEDS * 3 / 4,
			"%v in only %d of %d worlds",
			k,
			worlds_with[k],
			SEEDS,
		)
	}
	testing.expectf(t, fewest >= 3, "a world with only %d scattered sites", fewest)
	testing.expectf(t, total >= SEEDS * 7, "only %.1f scattered sites a world", f64(total) / SEEDS)
}
