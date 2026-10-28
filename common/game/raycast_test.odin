package game

import "core:math"
import "core:math/rand"
import "core:testing"

@(private = "file")
Solids :: struct {
	set:      map[Block_Pos]bool,
	unloaded: map[Block_Pos]bool,
}

@(private = "file")
query :: proc(s: ^Solids) -> Block_Query {
	return {s, proc(data: rawptr, p: Block_Pos) -> (Block, bool) {
			s := (^Solids)(data)
			if p in s.unloaded {return .Air, false}
			return .Stone if p in s.set else .Air, true
		}, test_blocks()}
}

@(test)
test_raycast_basics :: proc(t: ^testing.T) {
	s: Solids
	defer delete(s.set)
	defer delete(s.unloaded)
	s.set[{0, 0, 0}] = true
	s.set[{5, 3, 0}] = true

	// Straight down onto the top face.
	hit, ok := raycast(query(&s), {0.5, 3.2, 0.5}, {0, -1, 0}, 10)
	testing.expect(t, ok && hit.block == {0, 0, 0} && hit.normal == {0, 1, 0})
	testing.expect(t, abs(hit.distance - 2.2) < 1e-9)
	// Out of reach.
	_, ok = raycast(query(&s), {0.5, 3.2, 0.5}, {0, -1, 0}, 2)
	testing.expect(t, !ok)
	// Along +x into the side of (5, 3, 0): entered through its -x face.
	hit, ok = raycast(query(&s), {0.5, 3.5, 0.5}, {1, 0, 0}, 10)
	testing.expect(t, ok && hit.block == {5, 3, 0} && hit.normal == {-1, 0, 0})
	testing.expect(t, abs(hit.distance - 4.5) < 1e-9)
	// Missing everything.
	_, ok = raycast(query(&s), {0.5, 3.5, 0.5}, {0, 1, 0}, 50)
	testing.expect(t, !ok)
	// Starting inside a block: hit at once, no face.
	hit, ok = raycast(query(&s), {0.5, 0.5, 0.5}, {1, 1, 1}, 10)
	testing.expect(t, ok && hit.block == {0, 0, 0} && hit.normal == {} && hit.distance == 0)
	// Negative coordinates, diagonal, onto the +z face of (-3, -1, -3).
	s.set[{-3, -1, -3}] = true
	hit, ok = raycast(query(&s), {-2.5, -0.5, 0.5}, {-0.15, 0, -1}, 10)
	testing.expect(t, ok && hit.block == {-3, -1, -3} && hit.normal == {0, 0, 1})
	// Unloaded chunks stop the ray without a hit.
	s.unloaded[{2, 3, 0}] = true
	_, ok = raycast(query(&s), {0.5, 3.5, 0.5}, {1, 0, 0}, 10)
	testing.expect(t, !ok)
}

// The walk agrees with brute force: intersect the ray exactly with every
// solid block (slab method) and take the nearest entry (random rays through
// random blocks). Exact, so even a ray clipping a corner for a hair counts;
// a reference that marched in steps would miss those.
@(test)
test_raycast_matches_brute_force :: proc(t: ^testing.T) {
	s: Solids
	defer delete(s.set)
	defer delete(s.unloaded)
	for _ in 0 ..< 300 {
		s.set[{i32(rand.int_max(16)) - 8, i32(rand.int_max(16)) - 8, i32(rand.int_max(16)) - 8}] =
			true
	}
	MAX :: 12.0
	for _ in 0 ..< 500 {
		origin := [3]f64 {
			rand.float64_range(-6, 6),
			rand.float64_range(-6, 6),
			rand.float64_range(-6, 6),
		}
		start := Block_Pos {
			i32(math.floor(origin.x)),
			i32(math.floor(origin.y)),
			i32(math.floor(origin.z)),
		}
		if start in s.set {continue}
		dir := [3]f64 {
			rand.float64_range(-1, 1),
			rand.float64_range(-1, 1),
			rand.float64_range(-1, 1),
		}
		l := math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
		if l < 0.1 {continue}
		dir /= l
		hit, ok := raycast(query(&s), origin, dir, MAX)

		nearest := math.INF_F64
		for b in s.set {
			if d, through := ray_box_entry(origin, dir, b);
			   through && d <= MAX {nearest = min(nearest, d)}
		}
		found := nearest <= MAX
		// Rays that only touch a block's edge, or end on max_distance, are
		// a matter of rounding either way.
		if found != ok &&
		   (found && abs(nearest - MAX) < 1e-9 || ok && abs(hit.distance - MAX) < 1e-9) {continue}
		testing.expectf(
			t,
			found == ok,
			"ray %v dir %v: walk hit %v, brute force %v",
			origin,
			dir,
			ok,
			found,
		)
		if !found || !ok {continue}
		// The same distance (blocks touching the ray at once may tie).
		testing.expectf(
			t,
			abs(hit.distance - nearest) < 1e-9,
			"ray %v dir %v: walk %v at %v, nearest entry at %v",
			origin,
			dir,
			hit.block,
			hit.distance,
			nearest,
		)
		d, through := ray_box_entry(origin, dir, hit.block)
		testing.expectf(
			t,
			through && abs(d - hit.distance) < 1e-9,
			"walk's block %v is not where it says",
			hit.block,
		)
	}
}

// ray_box_entry: where the ray enters block b, if it passes through it
// (for a non-empty stretch; a ray only touching an edge or corner does not).
@(private = "file")
ray_box_entry :: proc(origin, dir: [3]f64, b: Block_Pos) -> (f64, bool) {
	enter, leave := 0.0, math.INF_F64
	for i in 0 ..< 3 {
		lo, hi := f64(b[i]), f64(b[i]) + 1
		if dir[i] == 0 {
			if origin[i] < lo || origin[i] >= hi {return 0, false}
			continue
		}
		a, c := (lo - origin[i]) / dir[i], (hi - origin[i]) / dir[i]
		enter, leave = max(enter, min(a, c)), min(leave, max(a, c))
	}
	return enter, enter < leave
}
