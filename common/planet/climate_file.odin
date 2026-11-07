package planet

import "core:encoding/endian"
import "core:mem"

// The climate file: `assets/planet/earth_climate.bin`, Earth's climate grid (`Planet`
// minus its relief) and rivers as `planet_build` and `rivers_build` make them, so the game
// decodes them at start instead of computing them (seconds at -o:minimal). `tools/planet
// climate` writes it; a test fails when it is stale.
//
// Layout: magic `VXCL`, version, the model's code version, the relief's hash (u64), the
// grid's width and height (u32 little-endian), then the payload: every array of the
// model in a fixed order, each split into byte planes, delta coded along the plane, the
// whole run-length coded (a zero byte is followed by the count of zeros, 1 to 255).

CLIMATE_MAGIC :: "VXCL"
CLIMATE_VERSION :: 1
// CLIMATE_MODEL_VERSION: bump it with any change to the climate model's code (everything
// `planet_build` and `rivers_build` run); the file's test then fails until the file is
// rewritten.
CLIMATE_MODEL_VERSION :: 1
CLIMATE_HEADER_SIZE :: 28

// climate_each visits every array of the model in file order, as raw bytes with the
// element size.
@(private = "file")
climate_each :: proc(
	p: ^Planet,
	rv: ^Rivers,
	visit: proc(a: []u8, size: int, ctx: rawptr),
	ctx: rawptr,
) {
	one :: proc(s: []$T, visit: proc(a: []u8, size: int, ctx: rawptr), ctx: rawptr) {
		visit(mem.slice_to_bytes(s), size_of(T), ctx)
	}
	one(p.land.land_fraction, visit, ctx)
	one(p.land.elevation, visit, ctx)
	one(p.land.is_land, visit, ctx)
	one(p.land.large_ocean, visit, ctx)
	one(p.land.continentality, visit, ctx)
	for m in 0 ..< 12 {one(p.temp.month[m], visit, ctx)}
	for m in 0 ..< 12 {one(p.precip.month[m], visit, ctx)}
	for m in 0 ..< 12 {one(p.winds[m], visit, ctx)}
	one(p.koppen, visit, ctx)
	one(rv.filled, visit, ctx)
	one(rv.next, visit, ctx)
	one(rv.flow, visit, ctx)
	one(rv.lake, visit, ctx)
}

@(private = "file")
Packer :: struct {
	out:  [dynamic]u8,
	zero: int,
}

@(private = "file")
pack_byte :: proc(k: ^Packer, b: u8) {
	if b == 0 {
		k.zero += 1
		if k.zero == 255 {
			append(&k.out, 0, 255)
			k.zero = 0
		}
		return
	}
	if k.zero > 0 {
		append(&k.out, 0, u8(k.zero))
		k.zero = 0
	}
	append(&k.out, b)
}

// climate_encode writes the file for a model built from `relief`.
climate_encode :: proc(
	relief: Relief,
	p: Planet,
	rv: Rivers,
	allocator := context.allocator,
) -> []u8 {
	k := Packer {
		out = make([dynamic]u8, allocator),
	}
	append(&k.out, CLIMATE_MAGIC)
	head := [2]u32{CLIMATE_VERSION, CLIMATE_MODEL_VERSION}
	for v in head {append(&k.out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
	hash := relief_hash(relief)
	for i in 0 ..< 8 {append(&k.out, u8(hash >> u32(8 * i)))}
	for v in ([2]u32{u32(p.land.width), u32(p.land.height)}) {
		append(&k.out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
	pp, rr := p, rv
	climate_each(&pp, &rr, proc(a: []u8, size: int, ctx: rawptr) {
			k := (^Packer)(ctx)
			n := len(a) / size
			for b in 0 ..< size {
				prev := u8(0)
				for i in 0 ..< n {
					v := a[i * size + b]
					pack_byte(k, v - prev)
					prev = v
				}
			}
		}, &k)
	if k.zero > 0 {append(&k.out, 0, u8(k.zero))}
	return k.out[:]
}

// climate_decode reads the file for `relief`: ok is false for a file it does not recognise,
// made for another relief, or by another version of the model.
climate_decode :: proc(
	data: []u8,
	relief: Relief,
	allocator := context.allocator,
) -> (
	p: Planet,
	rv: Rivers,
	ok: bool,
) {
	if len(data) < CLIMATE_HEADER_SIZE || string(data[:4]) != CLIMATE_MAGIC {return}
	version, _ := endian.get_u32(data[4:8], .Little)
	model, _ := endian.get_u32(data[8:12], .Little)
	hash, _ := endian.get_u64(data[12:20], .Little)
	w32, _ := endian.get_u32(data[20:24], .Little)
	h32, _ := endian.get_u32(data[24:28], .Little)
	if version != CLIMATE_VERSION || model != CLIMATE_MODEL_VERSION {return}
	if int(w32) != relief.width / CLIMATE_BLOCK ||
	   int(h32) != relief.height / CLIMATE_BLOCK {return}
	if hash != relief_hash(relief) {return}
	w, h := int(w32), int(h32)
	n := w * h

	p.relief = relief
	p.land = Land {
		width          = w,
		height         = h,
		land_fraction  = make([]f32, n, allocator),
		elevation      = make([]f32, n, allocator),
		is_land        = make([]bool, n, allocator),
		large_ocean    = make([]bool, n, allocator),
		continentality = make([]f32, n, allocator),
	}
	for m in 0 ..< 12 {
		p.temp.month[m] = make([]i16, n, allocator)
		p.precip.month[m] = make([]u16, n, allocator)
		p.winds[m] = make([]Wind, n, allocator)
	}
	p.koppen = make([]Koppen, n, allocator)
	rv = Rivers {
		width  = w,
		height = h,
		filled = make([]f32, n, allocator),
		next   = make([]i32, n, allocator),
		flow   = make([]f32, n, allocator),
		lake   = make([]bool, n, allocator),
	}

	Unpack :: struct {
		data: []u8,
		at:   int,
		zero: int,
		ok:   bool,
	}
	u := Unpack {
		data = data[CLIMATE_HEADER_SIZE:],
		ok   = true,
	}
	climate_each(&p, &rv, proc(a: []u8, size: int, ctx: rawptr) {
			u := (^Unpack)(ctx)
			n := len(a) / size
			for b in 0 ..< size {
				prev := u8(0)
				for i in 0 ..< n {
					v: u8
					if u.zero > 0 {
						u.zero -= 1
					} else if u.at >= len(u.data) {
						u.ok = false
						return
					} else if u.data[u.at] == 0 {
						if u.at + 1 >= len(u.data) || u.data[u.at + 1] == 0 {
							u.ok = false
							return
						}
						u.zero = int(u.data[u.at + 1]) - 1
						u.at += 2
					} else {
						v = u.data[u.at]
						u.at += 1
					}
					prev += v
					a[i * size + b] = prev
				}
			}
		}, &u)
	if !u.ok || u.at != len(u.data) || u.zero != 0 {
		planet_destroy(&p)
		rivers_destroy(&rv)
		p, rv = {}, {}
		return
	}
	return p, rv, true
}
