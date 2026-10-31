package ogg_tool

import "core:fmt"
import "core:os"

import "common:base"
import "common:ogg"

// `build ogg make-test-files`: the edge-case Oggs (common/ogg/testdata/edge/),
// made once and committed. Each is a *valid* Vorbis stream of seeded random
// packets over one fixed set of codebooks: the floor (type 1 or 0), residue
// (type 0, 1 or 2), coupling, submaps and block sizes are chosen per file and
// the packets are written to mirror exactly what the specification says a
// decoder reads. Nothing is encoded from a signal: the files exist to give
// the decoder every structure the format has, and the reference decoder
// (`build ogg reference`) says what each decodes to.

Config :: struct {
	name:     string,
	rate:     u32,
	channels: int,
	block:    [2]int, // short, long
	pattern:  []u8, // block flag of each audio packet
	floor:    int, // 1 or 0
	residue:  int, // 0, 1 or 2
	coupling: bool,
	submaps:  int,
	cut:      i64, // the last granule is this many frames below the whole (0: none)
	per_page: int, // segments per page (0: 255)
	padding:  int, // bytes of comment padding
	serial:   u32,
	seed:     u64,
}

LONG_SHORT := []u8{0, 1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0}
BIG_PATTERN := []u8{0, 1, 0, 1, 1, 0, 0, 1}
STEPS_STEREO := [][2]int{{0, 1}}
STEPS_SIX := [][2]int{{0, 2}, {1, 2}, {4, 5}}

log2 :: proc(n: int) -> u32 {
	r := u32(0)
	for v := n; v > 1; v >>= 1 {r += 1}
	return r
}

// float32_pack: mant * 2^exp as the codebook header stores it.
float32_pack :: proc(neg: bool, mant: u32, exp: int) -> u64 {
	return u64(0x80000000) * u64(1 if neg else 0) | u64(exp + 788) << 21 | u64(mant)
}

id_packet :: proc(c: Config) -> []byte {
	w: ogg.Bit_Writer
	for ch in ([]byte{1, 'v', 'o', 'r', 'b', 'i', 's'}) {ogg.bit_put(&w, u64(ch), 8)}
	ogg.bit_put(&w, 0, 32)
	ogg.bit_put(&w, u64(c.channels), 8)
	ogg.bit_put(&w, u64(c.rate), 32)
	ogg.bit_put(&w, 0, 32)
	ogg.bit_put(&w, 64000, 32)
	ogg.bit_put(&w, 0, 32)
	ogg.bit_put(&w, u64(log2(c.block[0])), 4)
	ogg.bit_put(&w, u64(log2(c.block[1])), 4)
	ogg.bit_put(&w, 1, 1)
	return w.buf[:]
}

comment_packet :: proc(c: Config) -> []byte {
	w: ogg.Bit_Writer
	for ch in ([]byte{3, 'v', 'o', 'r', 'b', 'i', 's'}) {ogg.bit_put(&w, u64(ch), 8)}
	vendor := "voxiverse test"
	ogg.bit_put(&w, u64(len(vendor) + c.padding), 32)
	for ch in transmute([]byte)vendor {ogg.bit_put(&w, u64(ch), 8)}
	for _ in 0 ..< c.padding {ogg.bit_put(&w, 'x', 8)}
	ogg.bit_put(&w, 0, 32)
	ogg.bit_put(&w, 1, 1)
	return w.buf[:]
}

// The codebooks: 0 is the floor 1 value book (128 entries of 7 bits), 1 the
// residue classbook (4 entries of 2 bits), 2 the vector book (16 entries of 4
// bits, dimension 2, values -0.75 -0.5 -0.25 0), 3 the same with positive
// values, for floor 0's coefficients.
book :: proc(w: ^ogg.Bit_Writer, dim, entries, len_bits: int, lookup: bool, positive := false) {
	ogg.bit_put(w, 0x564342, 24)
	ogg.bit_put(w, u64(dim), 16)
	ogg.bit_put(w, u64(entries), 24)
	ogg.bit_put(w, 0, 1)
	ogg.bit_put(w, 0, 1)
	for _ in 0 ..< entries {ogg.bit_put(w, u64(len_bits - 1), 5)}
	if !lookup {
		ogg.bit_put(w, 0, 4)
		return
	}
	ogg.bit_put(w, 1, 4)
	if positive {
		ogg.bit_put(w, float32_pack(false, 1, -2), 32) // 0.25, 0.5, 0.75, 1
		ogg.bit_put(w, float32_pack(false, 1, -2), 32)
	} else {
		ogg.bit_put(w, float32_pack(true, 3, -2), 32)
		ogg.bit_put(w, float32_pack(false, 1, -2), 32)
	}
	ogg.bit_put(w, 1, 4) // value bits - 1
	ogg.bit_put(w, 0, 1)
	for v in 0 ..< 4 {ogg.bit_put(w, u64(v), 2)}
}

Floor_Def :: struct {
	xs: [4]u64,
}

FLOORS :: [2]Floor_Def{{{24, 80, 160, 40}}, {{10, 50, 200, 100}}}
RES_PSIZE :: 8

setup_packet :: proc(c: Config) -> []byte {
	w: ogg.Bit_Writer
	for ch in ([]byte{5, 'v', 'o', 'r', 'b', 'i', 's'}) {ogg.bit_put(&w, u64(ch), 8)}
	ogg.bit_put(&w, 3, 8) // four books
	book(&w, 1, 128, 7, false)
	book(&w, 2, 4, 2, false)
	book(&w, 2, 16, 4, true)
	book(&w, 2, 16, 4, true, true)
	ogg.bit_put(&w, 0, 6) // one time transform
	ogg.bit_put(&w, 0, 16)
	nfloors := 2 * c.submaps // one for each submap of each of the two mappings
	ogg.bit_put(&w, u64(nfloors - 1), 6)
	floors := FLOORS
	for i in 0 ..< nfloors {
		if c.floor == 1 {
			ogg.bit_put(&w, 1, 16)
			ogg.bit_put(&w, 2, 5) // two partitions, both of class 0
			ogg.bit_put(&w, 0, 4)
			ogg.bit_put(&w, 0, 4)
			ogg.bit_put(&w, 1, 3) // dimension 2
			ogg.bit_put(&w, 0, 2) // subclass 0
			ogg.bit_put(&w, 1, 8) // its book: 0 + 1
			ogg.bit_put(&w, 1, 2) // multiplier 2
			rb := log2(c.block[i / c.submaps] / 2) // the floors of mapping 0 serve the short blocks, mapping 1's the long
			ogg.bit_put(&w, u64(rb), 4) // range bits: the block's half
			for x in floors[i % 2].xs {ogg.bit_put(&w, max(x >> (8 - min(rb, 8)) if rb <= 8 else x << (rb - 8), 1), rb)}
		} else {
			ogg.bit_put(&w, 0, 16)
			ogg.bit_put(&w, 6, 8) // order
			ogg.bit_put(&w, 44100, 16)
			ogg.bit_put(&w, 32 + u64(i) * 8, 16) // bark map size
			ogg.bit_put(&w, 6, 6) // amplitude bits
			ogg.bit_put(&w, 20, 8) // amplitude offset
			ogg.bit_put(&w, 0, 4) // one book
			ogg.bit_put(&w, 3, 8)
		}
	}
	nres := 2 * c.submaps
	ogg.bit_put(&w, u64(nres - 1), 6)
	for i in 0 ..< nres {
		ogg.bit_put(&w, u64((c.residue + i) % 3), 16)
		ogg.bit_put(&w, 0, 24)
		ogg.bit_put(&w, u64(c.block[i / c.submaps] / 2), 24)
		ogg.bit_put(&w, RES_PSIZE - 1, 24)
		ogg.bit_put(&w, 1, 6) // two classes
		ogg.bit_put(&w, 1, 8) // classbook 1
		ogg.bit_put(&w, 0, 3) // class 0: no books
		ogg.bit_put(&w, 0, 1)
		ogg.bit_put(&w, 1, 3) // class 1: pass 0
		ogg.bit_put(&w, 0, 1)
		ogg.bit_put(&w, 2, 8) // ... with book 2
	}
	ogg.bit_put(&w, 1, 6) // two mappings, the same: a mode names its own
	for m in 0 ..< 2 {
		ogg.bit_put(&w, 0, 16)
		if c.submaps > 1 {
			ogg.bit_put(&w, 1, 1)
			ogg.bit_put(&w, u64(c.submaps - 1), 4)
		} else {
			ogg.bit_put(&w, 0, 1)
		}
		steps := coupling_steps(c)
		if len(steps) > 0 {
			ogg.bit_put(&w, 1, 1)
			ogg.bit_put(&w, u64(len(steps) - 1), 8)
			bits := u32(ilog(c.channels - 1))
			for s in steps {
				ogg.bit_put(&w, u64(s[0]), bits)
				ogg.bit_put(&w, u64(s[1]), bits)
			}
		} else {
			ogg.bit_put(&w, 0, 1)
		}
		ogg.bit_put(&w, 0, 2)
		if c.submaps > 1 {
			for ch in 0 ..< c.channels {ogg.bit_put(&w, u64(ch % c.submaps), 4)}
		}
		for i in 0 ..< c.submaps {
			ogg.bit_put(&w, 0, 8)
			ogg.bit_put(&w, u64(m * c.submaps + i), 8)
			ogg.bit_put(&w, u64(m * c.submaps + i), 8)
		}
	}
	ogg.bit_put(&w, 1, 6) // two modes: short, long
	for flag in 0 ..< 2 {
		ogg.bit_put(&w, u64(flag), 1)
		ogg.bit_put(&w, 0, 16)
		ogg.bit_put(&w, 0, 16)
		ogg.bit_put(&w, u64(flag), 8)
	}
	ogg.bit_put(&w, 1, 1)
	return w.buf[:]
}

ilog :: proc(x: int) -> int {
	n := 0
	for v := x; v > 0; v >>= 1 {n += 1}
	return n
}

coupling_steps :: proc(c: Config) -> [][2]int {
	if !c.coupling {return nil}
	if c.channels == 2 {return STEPS_STEREO}
	if c.channels == 6 {return STEPS_SIX}
	return nil
}

Gen :: struct {
	rng: base.Rng,
	cfg: Config,
}

pick :: proc(g: ^Gen, n: int) -> int {return int(base.rng_u64(&g.rng) % u64(n))}

audio_packet :: proc(g: ^Gen, flag, prev, next: u8) -> []byte {
	c := g.cfg
	w: ogg.Bit_Writer
	ogg.bit_put(&w, 0, 1)
	ogg.bit_put(&w, u64(flag), 1)
	if flag == 1 {
		ogg.bit_put(&w, u64(prev), 1)
		ogg.bit_put(&w, u64(next), 1)
	}
	n := c.block[flag]
	half := n / 2
	for ch in 0 ..< c.channels {
		if c.floor == 1 {
			ogg.bit_put(&w, 1, 1)
			ogg.bit_put(&w, u64(60 + pick(g, 40)), 7)
			ogg.bit_put(&w, u64(60 + pick(g, 40)), 7)
			for _ in 0 ..< 4 {
				v := 0 if pick(g, 3) != 0 else pick(g, 7)
				ogg.bit_put_code(&w, u64(v), 7)
			}
		} else {
			ogg.bit_put(&w, u64(1 + pick(g, 3)), 6)
			ogg.bit_put(&w, 0, 1) // the book: ilog(1) = 1 bit
			for _ in 0 ..< 3 {ogg.bit_put_code(&w, u64(pick(g, 16)), 4)}
		}
		_ = ch
	}
	for sm in 0 ..< c.submaps {
		chs := 0
		for ch in 0 ..< c.channels {if ch % c.submaps == sm {chs += 1}}
		kind := (c.residue + int(flag) * c.submaps + sm) % 3
		vectors := chs
		length := half
		if kind == 2 {
			vectors, length = 1, chs * half
		}
		nparts := min(c.block[flag] / 2, length) / RES_PSIZE
		classes := make([][]int, vectors, context.temp_allocator)
		for v in 0 ..< vectors {
			classes[v] = make([]int, nparts + 2, context.temp_allocator)
			for p in 0 ..< nparts {classes[v][p] = 1 if pick(g, 10) < 7 else 0}
		}
		p := 0
		for p < nparts {
			for v in 0 ..< vectors {
				ogg.bit_put_code(&w, u64(classes[v][p] * 2 + classes[v][p + 1]), 2)
			}
			for _ in 0 ..< 2 {
				if p >= nparts {break}
				for v in 0 ..< vectors {
					if classes[v][p] == 1 {
						for _ in 0 ..< RES_PSIZE / 2 {ogg.bit_put_code(&w, u64(pick(g, 16)), 4)}
					}
				}
				p += 1
			}
		}
	}
	return w.buf[:]
}

// make_stream: the packets of one link, as bytes.
make_stream :: proc(c: Config) -> []byte {
	g := Gen {
		rng = base.rng_make(c.seed),
		cfg = c,
	}
	packets := make([dynamic]ogg.Packet)
	append(&packets, ogg.Packet{id_packet(c), 0, true})
	append(&packets, ogg.Packet{comment_packet(c), 0, false})
	append(&packets, ogg.Packet{setup_packet(c), 0, true})
	total: i64
	prev_n := 0
	for flag, i in c.pattern {
		next: u8 = c.pattern[i + 1] if i + 1 < len(c.pattern) else 1
		prev: u8 = c.pattern[i - 1] if i > 0 else 1
		n := c.block[flag]
		if i > 0 {total += i64(prev_n / 4 + n / 4)}
		prev_n = n
		append(&packets, ogg.Packet{audio_packet(&g, flag, prev, next), total, true})
	}
	if len(c.pattern) > 0 {packets[len(packets) - 1].granule = total - c.cut}
	per_page := c.per_page if c.per_page > 0 else 255
	return ogg.write_stream(packets[:], c.serial, true, per_page)
}

pattern_for :: proc(block: [2]int) -> []u8 {
	if block[1] >= 4096 {return BIG_PATTERN}
	return LONG_SHORT
}

make_test_files :: proc() -> bool {
	dir := TESTDATA + "edge/"
	os.make_directory_all(dir)
	base_cfg := Config {
		rate     = 44100,
		channels = 1,
		block    = {256, 2048},
		floor    = 1,
		residue  = 1,
		submaps  = 1,
		serial   = 1,
	}
	files := make([dynamic]struct {
			name: string,
			data: []byte,
		})
	add :: proc(files: ^[dynamic]struct {
			name: string,
			data: []byte,
		}, c: Config) {
		append(files, struct {
			name: string,
			data: []byte,
		}{c.name, make_stream(c)})
	}
	sizes := [?][2]int {
		{64, 64},
		{64, 128},
		{128, 512},
		{256, 2048},
		{512, 1024},
		{1024, 1024},
		{2048, 4096},
		{4096, 8192},
		{8192, 8192},
		{64, 8192},
	}
	for s, i in sizes {
		c := base_cfg
		c.name = fmt.aprintf("block_%d_%d", s[0], s[1])
		c.block = s
		c.pattern = pattern_for(s)
		c.seed = u64(i + 1)
		add(&files, c)
	}
	// Tiny files.
	t := base_cfg
	t.pattern = LONG_SHORT
	one := []u8{1}
	two := []u8{1, 1}
	t.name, t.seed, t.pattern = "tiny_one_packet", 20, one
	add(&files, t)
	t.name, t.pattern = "tiny_headers_only", nil
	add(&files, t)
	// Two blocks of 256 give 128 frames; a last granule of 1 cuts all but one.
	t.name, t.pattern, t.block, t.cut = "tiny_one_sample", two, {256, 256}, 127
	add(&files, t)
	t = base_cfg
	t.name, t.seed, t.pattern, t.cut = "tiny_cut_mid_block", 22, LONG_SHORT, 37
	add(&files, t)
	// Channels.
	m := base_cfg
	m.name, m.seed, m.pattern = "mono", 30, LONG_SHORT
	add(&files, m)
	st := base_cfg
	st.name, st.seed, st.pattern, st.channels, st.coupling =
		"stereo_coupled", 31, LONG_SHORT, 2, true
	add(&files, st)
	six := base_cfg
	six.name, six.seed, six.pattern, six.channels, six.coupling, six.submaps =
		"six_channels", 32, LONG_SHORT[:8], 6, true, 2
	add(&files, six)
	// Floor 0, residue types.
	f0 := base_cfg
	f0.name, f0.seed, f0.pattern, f0.floor, f0.residue = "floor0_residue0", 40, LONG_SHORT, 0, 0
	add(&files, f0)
	r2 := base_cfg
	r2.name, r2.seed, r2.pattern, r2.channels, r2.coupling, r2.residue =
		"stereo_residue2", 41, LONG_SHORT, 2, true, 2
	add(&files, r2)
	r0 := base_cfg
	r0.name, r0.seed, r0.pattern, r0.channels, r0.residue = "stereo_residue0", 42, LONG_SHORT, 2, 0
	add(&files, r0)
	// Pages.
	p := base_cfg
	p.name, p.seed, p.pattern, p.per_page = "pages_split", 50, LONG_SHORT, 3
	add(&files, p)
	p.name, p.per_page, p.seed = "pages_span3", 2, 51
	add(&files, p)
	p.name, p.per_page, p.padding, p.seed = "pages_255x255", 255, 65280, 52
	add(&files, p)
	// Chained.
	a := base_cfg
	a.name, a.seed, a.pattern = "chain_a", 60, LONG_SHORT[:6]
	b := base_cfg
	b.name, b.seed, b.pattern, b.serial = "chain_b", 61, LONG_SHORT[:6], 2
	b.rate, b.channels, b.coupling = 22050, 2, true
	empty := base_cfg
	empty.name, empty.seed, empty.pattern, empty.serial = "chain_c", 62, nil, 3
	cat :: proc(parts: ..[]byte) -> []byte {
		out := make([dynamic]byte)
		for part in parts {append(&out, ..part)}
		return out[:]
	}
	sa, sb, sc := make_stream(a), make_stream(b), make_stream(empty)
	a2 := a
	a2.serial, a2.seed = 4, 63
	append(&files, struct {
		name: string,
		data: []byte,
	}{"chain_same_rate", cat(sa, make_stream(a2))})
	append(&files, struct {
		name: string,
		data: []byte,
	}{"chain_mixed", cat(sa, sb)})
	append(&files, struct {
		name: string,
		data: []byte,
	}{"chain_three_empty_middle", cat(sa, sc, sb)})
	// A sound over the five seconds a pack's sound may last, for the pack tests.
	long := base_cfg
	long.name, long.seed, long.block = "long_sound", 70, {8192, 8192}
	long.pattern = make([]u8, 56)
	for &flag in long.pattern {flag = 1}
	if err := os.write_entire_file("common/game/testdata/long_sound.ogg", make_stream(long));
	   err != nil {
		fmt.eprintfln("ogg: long_sound: %v", err)
		return false
	}
	for f in files {
		if err := os.write_entire_file(fmt.aprintf("%s%s.ogg", dir, f.name), f.data); err != nil {
			fmt.eprintfln("ogg: %s: %v", f.name, err)
			return false
		}
		fmt.printfln("%s: %d bytes", f.name, len(f.data))
	}
	return true
}
