package game

import "core:math"
import "core:slice"
import "core:testing"

import "common:base"

// The spatial query service against brute force over all entries.

@(private = "file")
Ref :: struct {
	e:      Spatial_Entry,
	handle: Spatial_Handle,
	live:   bool,
}

@(private = "file")
random_entry :: proc(rng: ^base.Rng, id: Entity_Id, field: f64) -> Spatial_Entry {
	lo := [3]f64{base.rng_f64(rng) * field, base.rng_f64(rng) * 64 - 8, base.rng_f64(rng) * field}
	size := [3]f64 {
		0.1 + base.rng_f64(rng) * 3.9,
		0.1 + base.rng_f64(rng) * 3.9,
		0.1 + base.rng_f64(rng) * 3.9,
	}
	flags := transmute(Spatial_Flags)(u16(base.rng_u32(rng)) & 0b11_1111)
	return {id = id, lo = lo, hi = lo + size, kind = u16(base.rng_int_max(rng, 4)), flags = flags}
}

@(private = "file")
random_filter :: proc(rng: ^base.Rng) -> Spatial_Filter {
	f: Spatial_Filter
	if base.rng_int_max(rng, 2) == 0 {f.kind = u16(1 + base.rng_int_max(rng, 3))}
	if base.rng_int_max(rng, 3) == 0 {
		f.all = transmute(Spatial_Flags)(u16(1) << u16(base.rng_int_max(rng, 6)))
	}
	if base.rng_int_max(rng, 3) == 0 {
		f.none = transmute(Spatial_Flags)(u16(1) << u16(base.rng_int_max(rng, 6)))
	}
	if base.rng_int_max(rng, 4) == 0 {f.exclude = Entity_Id(1 + base.rng_int_max(rng, 2000))}
	return f
}

@(private = "file")
ref_ok :: proc(e: ^Spatial_Entry, f: Spatial_Filter) -> bool {
	return passes(e, f)
}

@(private = "file")
check_queries :: proc(
	t: ^testing.T,
	sp: ^Spatial,
	refs: []Ref,
	rng: ^base.Rng,
	n: int,
	field: f64,
) {
	out, want: [dynamic]Entity_Id
	defer delete(out)
	defer delete(want)
	for _ in 0 ..< n {
		center := [3]f64 {
			base.rng_f64(rng) * field,
			base.rng_f64(rng) * 64 - 8,
			base.rng_f64(rng) * field,
		}
		radius := 1 + base.rng_f64(rng) * 40
		f := random_filter(rng)
		clear(&out)
		clear(&want)
		switch base.rng_int_max(rng, 6) {
		case 0:
			spatial_sphere(sp, center, radius, f, &out)
			for &r in refs {
				if !r.live || !ref_ok(&r.e, f) {continue}
				d := bottom_centre(&r.e) - center
				if d.x * d.x + d.y * d.y + d.z * d.z <= radius * radius {append(&want, r.e.id)}
			}
		case 1:
			hh := base.rng_f64(rng) * 20
			spatial_cylinder(sp, center, radius, hh, f, &out)
			for &r in refs {
				if !r.live || !ref_ok(&r.e, f) {continue}
				d := bottom_centre(&r.e) - center
				if d.x * d.x + d.z * d.z <= radius * radius && abs(d.y) <= hh {
					append(&want, r.e.id)
				}
			}
		case 2:
			size := [3]f64{radius, radius / 2, radius}
			spatial_box(sp, center, center + size, f, &out)
			for &r in refs {
				if !r.live || !ref_ok(&r.e, f) {continue}
				e := r.e
				if e.lo.x < center.x + size.x &&
				   center.x < e.hi.x &&
				   e.lo.y < center.y + size.y &&
				   center.y < e.hi.y &&
				   e.lo.z < center.z + size.z &&
				   center.z < e.hi.z {
					append(&want, e.id)
				}
			}
		case 3:
			id, dist, found := spatial_nearest(sp, center, radius, f)
			best: Entity_Id
			bd := 0.0
			any := false
			for &r in refs {
				if !r.live || !ref_ok(&r.e, f) {continue}
				d := bottom_centre(&r.e) - center
				d2 := d.x * d.x + d.y * d.y + d.z * d.z
				if d2 > radius * radius {continue}
				if !any ||
				   d2 < bd ||
				   (d2 == bd && r.e.id < best) {best, bd, any = r.e.id, d2, true}
			}
			testing.expect(t, found == any)
			if any {
				testing.expect_value(t, id, best)
				testing.expect(t, dist * dist == bd || abs(dist * dist - bd) < 1e-9)
			}
			cnt := spatial_count(sp, center, radius, f)
			spatial_sphere(sp, center, radius, f, &out)
			testing.expect_value(t, cnt, len(out))
			continue
		case 4:
			dir := [3]f64 {
				base.rng_f64(rng) - 0.5,
				base.rng_f64(rng) - 0.5,
				base.rng_f64(rng) - 0.5,
			}
			l := math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
			if l < 1e-3 {continue}
			dir /= l
			half := base.rng_f64(rng) * 0.5
			maxd := 1 + base.rng_f64(rng) * 60
			id, dist, found := spatial_cast(sp, center, dir, maxd, half, f)
			best: Entity_Id
			bd := 0.0
			any := false
			hv := [3]f64{half, half, half}
			for &r in refs {
				if !r.live || !ref_ok(&r.e, f) {continue}
				d, hit := ray_box(center, dir, r.e.lo - hv, r.e.hi + hv, maxd)
				if !hit {continue}
				if !any || d < bd || (d == bd && r.e.id < best) {best, bd, any = r.e.id, d, true}
			}
			testing.expect(t, found == any)
			if any {
				testing.expect_value(t, id, best)
				testing.expect_value(t, dist, bd)
			}
			continue
		case:
			pos := Chunk_Pos{i32(center.x / 16), i32(center.y / 16), i32(center.z / 16)}
			spatial_chunk(sp, pos, &out)
			for &r in refs {
				if r.live && cell_of(r.e.lo, r.e.hi) == pos && .Large not_in r.e.flags {
					append(&want, r.e.id)
				}
			}
			slice.sort(want[:])
		}
		testing.expect(t, slice.is_sorted(out[:]))
		testing.expect(t, slice.equal(out[:], want[:]))
	}
}

@(test)
test_spatial_brute_force :: proc(t: ^testing.T) {
	sp: Spatial
	spatial_init(&sp)
	defer spatial_destroy(&sp)
	rng := base.rng_make(50)
	field := 128.0
	refs := make([]Ref, 2000)
	defer delete(refs)
	for i in 0 ..< len(refs) {
		e := random_entry(&rng, Entity_Id(i + 1), field)
		h, ok := spatial_insert(&sp, e)
		testing.expect(t, ok)
		refs[i] = {e, h, true}
	}
	check_queries(t, &sp, refs, &rng, 10_000, field)
	for _ in 0 ..< 10_000 {
		r := &refs[base.rng_int_max(&rng, len(refs))]
		switch base.rng_int_max(&rng, 5) {
		case 0:
			if r.live {
				spatial_remove(&sp, r.handle)
				r.live = false
			} else {
				e := random_entry(&rng, r.e.id, field)
				r.e = e
				r.handle, _ = spatial_insert(&sp, e)
				r.live = true
			}
		case:
			if !r.live {continue}
			size := r.e.hi - r.e.lo
			// a jump across cells now and then, mostly short steps
			by := [3]f64 {
				base.rng_f64(&rng) - 0.5,
				base.rng_f64(&rng) - 0.5,
				base.rng_f64(&rng) - 0.5,
			}
			if base.rng_int_max(&rng, 5) == 0 {by *= 40} else {by *= 4}
			r.e.lo += by
			r.e.hi = r.e.lo + size
			testing.expect(t, spatial_move(&sp, r.handle, r.e.lo, r.e.hi))
		}
	}
	check_queries(t, &sp, refs, &rng, 10_000, field)
	live := 0
	for r in refs {if r.live {live += 1}}
	testing.expect_value(t, sp.count, live)
}

@(test)
test_spatial_insert_order :: proc(t: ^testing.T) {
	rng := base.rng_make(51)
	entries: [300]Spatial_Entry
	for &e, i in entries {e = random_entry(&rng, Entity_Id(i + 1), 64)}
	results: [3][dynamic]Entity_Id
	defer for &r in results {delete(r)}
	for order in 0 ..< 3 {
		sp: Spatial
		spatial_init(&sp)
		defer spatial_destroy(&sp)
		for k in 0 ..< len(entries) {
			i := k
			switch order {
			case 1:
				i = len(entries) - 1 - k
			case 2:
				i = (k * 7) % len(entries)
			}
			spatial_insert(&sp, entries[i])
		}
		q := base.rng_make(52)
		for _ in 0 ..< 200 {
			c := [3]f64{base.rng_f64(&q) * 64, base.rng_f64(&q) * 40, base.rng_f64(&q) * 64}
			spatial_sphere(&sp, c, 12, {}, &results[order])
			spatial_box(&sp, c, c + 9, {}, &results[order])
			id, _, _ := spatial_nearest(&sp, c, 20, {})
			append(&results[order], id)
		}
	}
	testing.expect(t, slice.equal(results[0][:], results[1][:]))
	testing.expect(t, slice.equal(results[0][:], results[2][:]))
}

@(test)
test_spatial_nearest_ties :: proc(t: ^testing.T) {
	sp: Spatial
	spatial_init(&sp)
	defer spatial_destroy(&sp)
	for id in ([]Entity_Id{9, 3, 7}) {
		x := id == 3 ? 1.0 : id == 7 ? 9.0 : 5.0
		z := id == 9 ? 4.0 : 0
		spatial_insert(&sp, {id = id, lo = {x - 0.1, 0, z - 0.1}, hi = {x + 0.1, 1, z + 0.1}})
	}
	id, dist, ok := spatial_nearest(&sp, {5, 0, 0}, 10, {})
	testing.expect(t, ok)
	testing.expect_value(t, id, Entity_Id(3)) // 3, 7 and 9 are all 4 away
	testing.expect(t, abs(dist - 4) < 1e-9)
	id, _, ok = spatial_nearest(&sp, {5, 0, 0}, 10, {exclude = 3})
	testing.expect_value(t, id, Entity_Id(7))
}

@(test)
test_spatial_large :: proc(t: ^testing.T) {
	sp: Spatial
	spatial_init(&sp)
	defer spatial_destroy(&sp)
	_, ok := spatial_insert(&sp, {id = 1, lo = 0, hi = 5})
	testing.expect(t, !ok, "a box over 4 blocks without Large is refused")
	_, ok = spatial_insert(&sp, {id = 2, lo = {0, 0, 0}, hi = {32, 1, 32}, flags = {.Large}})
	testing.expect(t, ok)
	out: [dynamic]Entity_Id
	defer delete(out)
	spatial_box(&sp, {30, 0, 30}, {31, 1, 31}, {}, &out)
	testing.expect(t, slice.equal(out[:], []Entity_Id{2}))
	id, d, hit := spatial_cast(&sp, {31, 5, 31}, {0, -1, 0}, 10, 0, {})
	testing.expect(t, hit && id == 2)
	testing.expect_value(t, d, 4.0)
}

@(test)
test_spatial_flat :: proc(t: ^testing.T) {
	sp: Spatial
	spatial_init(&sp)
	defer spatial_destroy(&sp)
	rng := base.rng_make(53)
	round2 := 0
	hs: [2000]Spatial_Handle
	for round in 1 ..= 20 {
		for i in 0 ..< len(hs) {
			e := random_entry(&rng, Entity_Id(i + 1), 128)
			hs[i], _ = spatial_insert(&sp, e)
		}
		for h in hs {spatial_remove(&sp, h)}
		if round == 2 {round2 = spatial_committed_bytes(&sp)}
	}
	testing.expect_value(t, sp.count, 0)
	testing.expect_value(t, len(sp.cells), 0)
	testing.expect_value(t, spatial_committed_bytes(&sp), round2)
}
