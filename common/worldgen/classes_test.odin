package worldgen

import "core:fmt"
import "core:testing"

import "common:game"
import "common:starmap"

// class_address: the n-th address (from address_derive) of class c.
@(private = "file")
class_address :: proc(c: World_Class, n: int) -> starmap.Address {
	found := 0
	for i in u64(0) ..< 100_000 {
		a := starmap.address_derive(i)
		if world_class(a) != c {continue}
		if found == n {return a}
		found += 1
	}
	panic("no address of the class")
}

// class_generator: a generator of the n-th world of class c, its terrain from seed.
@(private = "file")
class_generator :: proc(c: World_Class, n: int, seed: i64) -> Generator {
	p, _, _ := class_params(c, class_address(c, n))
	return generator_make(.Earth, seed, test_reg(), p)
}

// The class is the address's alone, Earth's is none, and the classes are well spread:
// each within a point of what CLASS_SHARE and LIFE_SHARE make it, and none rarer than 8
// in 100 or commoner than 16.
@(test)
test_world_class_choice :: proc(t: ^testing.T) {
	testing.expect_value(t, world_class(starmap.earth_address()), World_Class.None)
	N :: 20_000
	counts: [World_Class]int
	for i in 0 ..< N {
		a := starmap.address_derive(u64(i))
		c := world_class(a)
		testing.expect(t, c == world_class(a))
		counts[c] += 1
		// It agrees with what lives there.
		life := world_life(a).life
		testing.expectf(t, CLASS_SHARE[life][c] > 0, "%v world with %v life", c, life)
	}
	testing.expect_value(t, counts[.None], 0)
	for c in World_Class {
		if c == .None {continue}
		want: f64
		for l in Life {want += f64(LIFE_SHARE[l]) * f64(CLASS_SHARE[l][c]) / 10_000}
		share := f64(counts[c]) / N
		testing.expectf(
			t,
			abs(share - want) < 0.01,
			"%v: %v of addresses, want %v",
			c,
			share,
			want,
		)
		testing.expectf(t, share >= 0.08 && share <= 0.16, "%v: %v of addresses", c, share)
	}
	for row in CLASS_SHARE {
		sum := 0
		for s in row {sum += int(s)}
		testing.expect_value(t, sum, 100)
	}
}

// Every block a class names is in the base pack, so no class's world stands in Earth's
// blocks by mistake; Earth's (None) are its own.
@(test)
test_class_blocks :: proc(t: ^testing.T) {
	reg := test_reg()
	none := class_blocks(reg, .None)
	for to, from in none.remap {testing.expect_value(t, to, from)}
	for &d, c in CLASSES {
		if c == .None {continue}
		names := make([dynamic]string, context.temp_allocator)
		for s in d.swaps {append(&names, s.to)}
		for o in d.ores {append(&names, o.block)}
		append(&names, d.liquid, d.unique, d.plant_on)
		append(&names, ..d.plants[:])
		append(&names, ..d.parts[:])
		for n in names {
			if n == "" {continue}
			_, ok := game.registry_block(reg, n)
			testing.expectf(t, ok, "%v names %s, which the base pack has not", c, n)
		}
		testing.expectf(t, d.unique != "", "%v has no rare resource", c)
		b := class_blocks(reg, c)
		testing.expectf(t, b.unique != .Air, "%v's rare resource is not found", c)
		// The rare resource is no other class's.
		for &e, o in CLASSES {
			if o !=
			   c {testing.expectf(t, e.unique != d.unique, "%v and %v share %s", c, o, d.unique)}
		}
	}
}

// A class's world: the same chunk twice is the same, each column's natural top is its
// highest block that shades as generated (terraces, craters, cones, magma, dry basins,
// its trees), and its blocks are its own: its liquid in the sea, none of Earth's grass
// at_gate it has another ground.
@(test)
test_class_generation :: proc(t: ^testing.T) {
	a, b := new(game.Block_Array), new(game.Block_Array)
	defer free(a)
	defer free(b)
	for c in World_Class {
		if c == .None {continue}
		g := class_generator(c, 0, 777)
		for pos in ([]game.Chunk_Pos{{0, 0, 0}, {-3, -1, 7}, {40, 2, -50}}) {
			generate(&g, pos, a)
			generate(&g, pos, b)
			testing.expectf(t, a^ == b^, "%v: chunk %v differs", c, pos)
		}
		seen: map[game.Block]int
		defer delete(seen)
		for n in i32(0) ..< 8 {
			column := [2]i32{(n % 4) * 37 - 60, (n / 4) * 41 - 30}
			tops: Tops
			column_tops(&g, column, &tops)
			lo, hi := max(i32), min(i32)
			for top in tops {lo, hi = min(lo, top), max(hi, top)}
			found: [COLUMN_AREA]i32
			for &f in found {f = game.WORLD_MIN_Y}
			for cy := game.chunk_of({0, hi + 1, 0}).y; cy >= game.chunk_of({0, lo, 0}).y; cy -= 1 {
				uniform, is_uniform := generate(&g, {column.x, cy, column.y}, a)
				for z in i32(0) ..< game.CHUNK_SIZE {
					for x in i32(0) ..< game.CHUNK_SIZE {
						for y := i32(game.CHUNK_SIZE - 1); y >= 0; y -= 1 {
							bl := uniform if is_uniform else a[game.local_index({x, y, z})]
							seen[bl] += 1
							i := x + z * game.CHUNK_SIZE
							if found[i] == game.WORLD_MIN_Y &&
							   game.block_shades(
								   test_blocks(),
								   bl,
							   ) {found[i] = cy * game.CHUNK_SIZE + y}
						}
					}
				}
			}
			for i in 0 ..< COLUMN_AREA {
				if !testing.expectf(
					t,
					found[i] == tops[i],
					"%v column %v+%d: top %d, generated %d",
					c,
					column,
					i,
					tops[i],
					found[i],
				) {return}
			}
		}
		cb := &g.blocks
		if cb.remap[.Grass] != .Grass {
			testing.expectf(t, seen[.Grass] == 0, "%v: Earth's grass on its ground", c)
		}
		if cb.liquid != .Water {
			testing.expectf(t, seen[.Water] == 0, "%v: water in a world without", c)
		}
		testing.expectf(t, seen[cb.stone] > 0, "%v: none of its rock", c)
	}
}

// Each class's rare resource is there to be found near the spawn, and its world is
// recognisably its own at the surface: most of the ground around the spawn is the
// class's own ground.
@(test)
test_class_resources :: proc(t: ^testing.T) {
	a := new(game.Block_Array)
	defer free(a)
	for c in World_Class {
		if c == .None {continue}
		g := class_generator(c, 1, 4242)
		spawn := spawn_point(&g)
		centre := [2]i32{i32(spawn.x) >> game.CHUNK_SHIFT, i32(spawn.z) >> game.CHUNK_SHIFT}
		unique := 0
		R :: 6
		search: for dz in i32(-R) ..= R {
			for dx in i32(-R) ..= R {
				column := centre + {dx, dz}
				tops: Tops
				column_tops(&g, column, &tops)
				hi := min(i32)
				for top in tops {hi = max(hi, top)}
				for cy := game.chunk_of({0, hi + 1, 0}).y; cy >= game.CHUNK_MIN_Y; cy -= 1 {
					uniform, is_uniform := generate(&g, {column.x, cy, column.y}, a)
					if is_uniform {
						if uniform == g.blocks.unique {unique += 1}
						continue
					}
					for bl in a {if bl == g.blocks.unique {unique += 1}}
				}
				if unique > 0 {break search}
			}
		}
		testing.expectf(t, unique > 0, "%v: no %s near the spawn", c, CLASSES[c].unique)
	}
}

// Arrival: in every class, over many worlds, travellers arrive at a gate (one is found)
// standing on sound ground: its opening clear, the platform before it paved and dry,
// the air above it open, no liquid there, and land under the platform's middle.
@(test)
test_class_arrival :: proc(t: ^testing.T) {
	arr := new(game.Block_Array)
	defer free(arr)
	WORLDS :: 16
	for c in World_Class {
		if c == .None {continue}
		for n in 0 ..< WORLDS {
			g := class_generator(c, n, i64(1000 + n * 7919))
			s, ok := arrival_gate(&g)
			if !testing.expectf(t, ok, "%v world %d: no gate to arrive at", c, n) {continue}
			cache: map[game.Chunk_Pos]^game.Block_Array
			defer {
				for _, v in cache {free(v)}
				delete(cache)
			}
			block :: proc(
				g: ^Generator,
				cache: ^map[game.Chunk_Pos]^game.Block_Array,
				p: game.Block_Pos,
			) -> game.Block {
				cp := game.chunk_of(p)
				chunk, has := cache[cp]
				if !has {
					chunk = new(game.Block_Array)
					uniform, is_uniform := generate(g, cp, chunk)
					if is_uniform {for &b in chunk {b = uniform}}
					cache[cp] = chunk
				}
				return chunk[game.local_index(game.local_of(p))]
			}
			at_gate := fmt.tprintf("%v world %d gate at %v", c, n, s.lo)
			inside := make([dynamic]game.Block_Pos, context.temp_allocator)
			gate_inside(s, &inside)
			for p in inside {
				testing.expectf(
					t,
					block(&g, &cache, p) == .Air,
					"%s: its opening is blocked at %v",
					at_gate,
					p,
				)
			}
			lo, hi := gate_apron(s)
			liquid := g.blocks.liquid
			for z in lo.z ..= hi.z {
				for x in lo.x ..= hi.x {
					floor := block(&g, &cache, {x, lo.y, z})
					testing.expectf(
						t,
						floor == .Stone_Bricks,
						"%s: the platform at %v is %v",
						at_gate,
						[2]i32{x, z},
						floor,
					)
					for y in lo.y + 1 ..= hi.y + 2 {
						b := block(&g, &cache, {x, y, z})
						testing.expectf(
							t,
							b == .Air,
							"%s: %v over the platform at %v",
							at_gate,
							b,
							[3]i32{x, y, z},
						)
					}
				}
			}
			front, _ := gate_front(s)
			fx, fz := i32(front.x), i32(front.z)
			under := block(&g, &cache, {fx, i32(front.y) - 1, fz})
			testing.expectf(
				t,
				under == .Stone_Bricks,
				"%s: the arrival stands on %v",
				at_gate,
				under,
			)
			// Under the platform's corners and middle: foundation or land, never
			// liquid or air.
			mid := (lo + hi) / 2
			for at in ([5][2]i32{{lo.x, lo.z}, {hi.x, lo.z}, {lo.x, hi.z}, {hi.x, hi.z}, {mid.x, mid.z}}) {
				y := lo.y - 1
				b := block(&g, &cache, {at.x, y, at.y})
				testing.expectf(
					t,
					b != .Air && (liquid == .Air || b != liquid),
					"%s: %v under the platform at y %d",
					at_gate,
					b,
					y,
				)
			}
		}
	}
}
