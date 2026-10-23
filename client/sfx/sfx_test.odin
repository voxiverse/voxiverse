package sfx

import "core:math"
import "core:slice"
import "core:testing"

// Every sound: audible, within -1..1, crushed to BITS bits, ending in
// silence, under a second; the same each time it is made.
@(test)
test_every_sound_is_well_formed :: proc(t: ^testing.T) {
	levels := f32(int(1) << (BITS - 1) - 1)
	check :: proc(t: ^testing.T, name: string, s: []f32, levels: f32) {
		peak: f32
		for x in s {
			peak = max(peak, abs(x))
			if math.round(x * levels) / levels != x {
				testing.expectf(t, false, "%s: %v is not a %d-bit level", name, x, BITS)
				return
			}
		}
		testing.expectf(t, peak > 0.3 && peak <= 1, "%s: peak %v", name, peak)
		testing.expectf(t, len(s) > RATE / 50 && len(s) < RATE, "%s: %d samples", name, len(s))
		testing.expectf(t, s[len(s) - 1] == 0, "%s: ends in a click", name)
	}
	for m in Material {
		for a in Action {
			for v in 0 ..< VARIANTS {
				s := block_sound(m, a, v, context.temp_allocator)
				check(t, "block sound", s, levels)
				again := block_sound(m, a, v, context.temp_allocator)
				testing.expectf(t, slice.equal(s, again), "%v %v %d: not deterministic", m, a, v)
			}
		}
	}
	for p in Player_Sound {
		for v in 0 ..< VARIANTS {check(t, "player sound", player_sound(p, v, context.temp_allocator), levels)}
	}
}

// Variants differ; breaking is bigger than placing, which is bigger than a
// step; and materials sound different: sand is brighter (more sign
// changes per second) than dirt.
@(test)
test_sounds_differ :: proc(t: ^testing.T) {
	for m in Material {
		a := block_sound(m, .Break, 0, context.temp_allocator)
		b := block_sound(m, .Break, 1, context.temp_allocator)
		testing.expectf(t, !slice.equal(a, b), "%v: variants are the same", m)
		energy :: proc(s: []f32) -> f32 {
			e: f32
			for x in s {e += x * x}
			return e
		}
		brk := energy(a)
		place := energy(block_sound(m, .Place, 0, context.temp_allocator))
		step := energy(block_sound(m, .Step, 0, context.temp_allocator))
		testing.expectf(
			t,
			brk > place && place > step,
			"%v: break %v, place %v, step %v",
			m,
			brk,
			place,
			step,
		)
	}
	crossings :: proc(s: []f32) -> f32 {
		n := 0
		for i in 1 ..< len(s) {if (s[i] < 0) != (s[i - 1] < 0) {n += 1}}
		return f32(n) / f32(len(s)) * RATE
	}
	sand := crossings(block_sound(.Sand, .Break, 0, context.temp_allocator))
	dirt := crossings(block_sound(.Dirt, .Break, 0, context.temp_allocator))
	testing.expectf(t, sand > 2 * dirt, "sand %v vs dirt %v crossings/s", sand, dirt)
}
