package sandbox_server

import "core:log"
import "core:testing"

import "common:game"
import "common:worldgen"
import "server:core"
import "server:play"
import "server:playtest"

// The ruin across seeds (ruin_site, ruin_build): placed on dry ground, never far from
// level, a walk from the spawn; built on any of them, its floor rests on ground all over and
// every gate opens on ground a player stands on.

// footprint_spread: the most minus the least height of the land (as the generator makes it)
// under a site's walls, and whether any of it is under the sea's top.
@(private = "file")
footprint_spread :: proc(w: ^core.World, site: Site) -> (spread: f32, wet: bool) {
	params := w.params
	lo, hi := max(f32), min(f32)
	for dz in i32(0) ..< RUIN_SIDE {
		for dx in i32(0) ..< RUIN_SIDE {
			c := worldgen.column_at(&params, w.seed, site.origin.x + dx, site.origin.z + dz)
			lo, hi = min(lo, c.height), max(hi, c.height)
			wet ||= c.height < f32(params.sea_level) + 1
		}
	}
	return hi - lo, wet
}

// Over 60 seeds of the Earth generator (a universe's own home world): how many sites are
// level and how uneven the land under each is. (Before the search was widened, 35 of 60
// were level and the rest fell back to the first candidate: 20 were on water, five of them
// at the sea's floor, and one stood on land 65 blocks uneven.)
@(test)
test_ruin_sites_over_seeds :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := new(core.World)
	defer free(w)
	w.generator = .Earth
	w.params = worldgen.PARAMS_DEFAULTS
	level, wet := 0, 0
	worst: f32
	for n in i64(1) ..= 60 {
		w.seed = n * 7919
		gen := worldgen.generator_make(.Earth, w.seed, s.registry)
		w.spawn.position = worldgen.spawn_point(&gen)
		site := ruin_site(w)
		spread, under_sea := footprint_spread(w, site)
		if site.level {level += 1}
		if under_sea {wet += 1}
		worst = max(worst, spread)
		d := ruin_middle(site) - w.spawn.position
		far := d.x * d.x + d.z * d.z
		testing.expectf(
			t,
			far >= 230 * 230 && far <= 470 * 470,
			"seed %d: %v from the spawn",
			w.seed,
			d,
		)
		testing.expectf(
			t,
			site.floor > w.params.sea_level,
			"seed %d: the floor at %d",
			w.seed,
			site.floor,
		)
	}
	log.infof(
		"ruin sites over 60 seeds: %d level, %d touching water, the land at most %.1f uneven",
		level,
		wet,
		worst,
	)
	testing.expectf(t, level >= 30, "only %d of 60 sites level", level)
	testing.expectf(t, wet <= 3, "%d of 60 sites touch water", wet)
	testing.expectf(t, worst <= 16, "a site's land is %.1f blocks uneven", worst)
}

// Built on several seeds' sites, level or not: under every block of its floor there is
// ground, nothing stands over its middle, and each gate opens on ground a player stands on
// from its apron through to the inside.
@(test)
test_ruin_built_on_ground :: proc(t: ^testing.T) {
	for seed in ([]i64{7919, 31676, 245489, 340517}) {
		rig := new(Rig)
		defer free(rig)
		if !playtest.start(t, rig, GAME, {seed = seed}) {continue}
		defer playtest.stop(rig)
		s := playtest.srv(rig)
		r := ruin_of(s)
		w := s.home
		playtest.step(rig)
		h := playtest.host(rig)
		core.game_mode(s, h, "creative")
		core.teleport(s, h, ruin_middle(r.site) + {0, 40, 0}, {0, 0}, flying = true)
		built :: proc(data: rawptr) -> bool {return ruin_of((^core.Server)(data)).built}
		if !testing.expectf(t, playtest.until(rig, built, s, 60), "seed %d: never built", seed) {
			continue
		}
		o := r.site.origin
		for dz in i32(0) ..< RUIN_SIDE {
			for dx in i32(0) ..< RUIN_SIDE {
				under, _ := core.block_at(w, {o.x + dx, o.y - 1, o.z + dz})
				if under == .Air || under == .Water {
					testing.expectf(
						t,
						false,
						"seed %d: %v under the foundation at %d %d",
						seed,
						under,
						dx,
						dz,
					)
				}
			}
		}
		testing.expectf(
			t,
			core.under_sky(w, ruin_altar(r.site) + {0, 1, 0}),
			"seed %d: something stands over the altar",
			seed,
		)
		M :: RUIN_MID
		S :: RUIN_SIDE
		gates := [4][3][2]i32 {
			{{M, -2}, {M, 0}, {M, 1}},
			{{M, S + 1}, {M, S - 1}, {M, S - 2}},
			{{-2, M}, {0, M}, {1, M}},
			{{S + 1, M}, {S - 1, M}, {S - 2, M}},
		}
		for g, i in gates {
			for l in g {
				p := game.Block_Pos{o.x + l.x, r.site.floor + 1, o.z + l.y}
				testing.expectf(
					t,
					play.standable(s, w, p),
					"seed %d: gate %d is shut at %v",
					seed,
					i,
					l,
				)
			}
		}
		log.infof(
			"ruin seed=%d level=%v floor=%d land %d..%d",
			seed,
			r.site.level,
			r.site.floor,
			r.site.lo,
			r.site.hi,
		)
	}
}
