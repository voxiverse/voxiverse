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
		}}
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

// The walk agrees with brute force: march in tiny steps and take the first
// solid block (random rays through random blocks).
@(test)
test_raycast_matches_marching :: proc(t: ^testing.T) {
	s: Solids
	defer delete(s.set)
	defer delete(s.unloaded)
	for _ in 0 ..< 300 {
		s.set[{i32(rand.int_max(16)) - 8, i32(rand.int_max(16)) - 8, i32(rand.int_max(16)) - 8}] =
			true
	}
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
		hit, ok := raycast(query(&s), origin, dir, 12)
		// March.
		want: Maybe(Block_Pos)
		march_distance: f64
		for d := 0.0; d <= 12; d += 0.0005 {
			p := origin + dir * d
			b := Block_Pos{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
			if b in s.set {
				want, march_distance = b, d
				break
			}
		}
		w, found := want.?
		if found == ok && (!ok || w == hit.block) {continue}
		// Marching can clip a block's corner within one step that the exact
		// walk passes by (or the reverse), or end just past max_distance.
		if found && ok && abs(march_distance - hit.distance) < 0.002 {continue}
		if found != ok &&
		   (found && march_distance > 11.99 || ok && hit.distance > 11.99) {continue}
		testing.expectf(
			t,
			false,
			"ray %v dir %v: walk %v (%v) vs march %v (%v)",
			origin,
			dir,
			hit.block,
			ok,
			w,
			found,
		)
	}
}
