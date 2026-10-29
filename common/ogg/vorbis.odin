package ogg

import "base:intrinsics"

// Vorbis I: bit reader, the arena the decoder's memory is carved from, the
// identification, comment and setup headers.

MAX_PACKET :: 64 << 10
MAX_CHANNELS :: 8
MAX_DECODER_BYTES :: 8 << 20
MAX_FLOORS :: 64
MAX_RESIDUES :: 64
MAX_MAPPINGS :: 64
MAX_MODES :: 64
MAX_FLOOR1_POINTS :: 65
MAX_FLOOR0_ORDER :: 64
MAX_RES_CLASSES :: 64
MAX_COUPLING :: 256
MIN_BLOCK :: 64
MAX_BLOCK :: 8192

// Bits reads a packet least significant bit first. Reading past the end sets
// eop and returns zeros: the spec's end-of-packet.
Bits :: struct {
	data: []byte,
	at:   int,
	acc:  u64,
	n:    u32,
	eop:  bool,
}

bits_init :: proc "contextless" (data: []byte) -> Bits {
	return Bits{data = data}
}

bits_refill :: #force_inline proc "contextless" (b: ^Bits) {
	for b.n <= 56 && b.at < len(b.data) {
		b.acc |= u64(b.data[b.at]) << b.n
		b.at += 1
		b.n += 8
	}
}

bits_read :: proc "contextless" (b: ^Bits, n: u32) -> u32 {
	if n == 0 {return 0}
	if b.n < n {
		bits_refill(b)
		if b.n < n {
			b.eop = true
			b.acc, b.n = 0, 0
			return 0
		}
	}
	v := u32(b.acc & (u64(1) << n - 1))
	b.acc >>= n
	b.n -= n
	return v
}

// bits_left: bits not yet consumed.
bits_left :: proc "contextless" (b: ^Bits) -> int {
	return (len(b.data) - b.at) * 8 + int(b.n)
}

ilog :: proc "contextless" (x: int) -> int {
	n := 0
	v := x
	for v > 0 {
		n += 1
		v >>= 1
	}
	return n
}

// Arena carves one block into slices; nothing is freed but all at once.
Arena :: struct {
	buf:  []byte,
	used: int,
}

arena_make :: proc "contextless" (a: ^Arena, $T: typeid, n: int) -> (s: []T, ok: bool) {
	if n < 0 || n > len(a.buf) {return nil, false}
	size := n * size_of(T)
	at := (a.used + 15) &~ 15
	if at > len(a.buf) || size > len(a.buf) - at {return nil, false}
	a.used = at + size
	if n == 0 {return nil, true}
	p := raw_data(a.buf[at:])
	intrinsics.mem_zero(p, size)
	return ([^]T)(p)[:n], true
}

Floor1_Class :: struct {
	dim:        u8,
	subclass:   u8,
	masterbook: u8,
	subbooks:   [8]i16,
}

Floor :: struct {
	kind:        int, // 0 or 1
	// floor 1
	part_class:  [31]u8,
	partitions:  int,
	classes:     [16]Floor1_Class,
	multiplier:  int,
	npoints:     int,
	xs:          [MAX_FLOOR1_POINTS]u16,
	order:       [MAX_FLOOR1_POINTS]u8, // point indices by ascending x
	lo, hi:      [MAX_FLOOR1_POINTS]u8, // neighbours
	// floor 0
	f0_order:    int,
	f0_rate:     int,
	f0_map_size: int,
	f0_amp_bits: u32,
	f0_amp_off:  int,
	f0_nbooks:   int,
	f0_books:    [16]u8,
	f0_map:      [2][]i32, // by block flag: bark map, length n+1
}

Residue :: struct {
	kind:       int,
	begin, end: int,
	psize:      int,
	nclass:     int,
	classbook:  int,
	books:      [MAX_RES_CLASSES][8]i16,
}

Coupling :: struct {
	mag, ang: u8,
}

Mapping :: struct {
	nsub:      int,
	ncoupling: int,
	coupling:  [MAX_COUPLING]Coupling,
	mux:       [MAX_CHANNELS]u8,
	floor:     [16]u8,
	residue:   [16]u8,
}

Mode :: struct {
	blockflag: bool,
	mapping:   u8,
}

// Setup is everything the identification and setup headers define, for the
// link being read.
Setup :: struct {
	channels:  int,
	rate:      int,
	block:     [2]int, // short, long
	books:     []Codebook,
	floors:    []Floor,
	residues:  []Residue,
	mappings:  []Mapping,
	modes:     []Mode,
	mode_bits: u32,
	// Work memory
	slope:     [2][]f32, // rising window slope of each block size, length block/2
	mdct:      [2]Mdct,
	spec:      [][]f32, // per channel, block[1]/2
	blk:       [][]f32, // per channel, block[1]
	ovl:       [][]f32, // per channel overlap, block[1]/2
	pcm:       [][]f32, // per channel output of one packet
	f_y:       [][]i32, // per channel floor 1 values
	f_flag:    [][]bool,
	f_used:    []bool,
	f_amp:     []f32, // floor 0 amplitude per channel
	f_coef:    [][]f32,
	res_tmp:   []f32, // residue 2 vector, channels * n
	res_skip:  []bool,
	res_class: []u8, // classification table, channels * partitions
	fft:       []f32,
	dct:       []f32,
	floor1_db: []f32, // 256
}

Id_Header :: struct {
	channels: int,
	rate:     u32,
	bitrate:  u32,
	block:    [2]int,
}

// parse_id reads the identification packet.
parse_id :: proc "contextless" (pkt: []byte) -> (h: Id_Header, err: Error) {
	if len(pkt) < 30 {return {}, .Bad_Header}
	if pkt[0] != 1 || string(pkt[1:7]) != "vorbis" {return {}, .Not_Vorbis}
	r := bits_init(pkt[7:])
	if bits_read(&r, 32) != 0 {return {}, .Bad_Header}
	ch := int(bits_read(&r, 8))
	rate := bits_read(&r, 32)
	_ = bits_read(&r, 32)
	nominal := bits_read(&r, 32)
	_ = bits_read(&r, 32)
	b0 := bits_read(&r, 4)
	b1 := bits_read(&r, 4)
	framing := bits_read(&r, 1)
	if r.eop || framing != 1 {return {}, .Bad_Header}
	if ch == 0 || rate == 0 {return {}, .Bad_Header}
	if b0 < 6 || b0 > 13 || b1 < 6 || b1 > 13 || b0 > b1 {return {}, .Bad_Header}
	if ch > MAX_CHANNELS {return {}, .Over_Limit}
	return Id_Header{ch, rate, nominal, {1 << b0, 1 << b1}}, .None
}

// check_comment validates the comment packet's lengths.
check_comment :: proc "contextless" (pkt: []byte) -> Error {
	if len(pkt) < 7 || pkt[0] != 3 || string(pkt[1:7]) != "vorbis" {return .Bad_Header}
	r := bits_init(pkt[7:])
	vendor := int(bits_read(&r, 32))
	if r.eop || vendor > bits_left(&r) / 8 {return .Bad_Header}
	// The strings are skipped, only their lengths are checked.
	for _ in 0 ..< vendor {_ = bits_read(&r, 8)}
	count := int(bits_read(&r, 32))
	if r.eop {return .Bad_Header}
	for _ in 0 ..< count {
		l := int(bits_read(&r, 32))
		if r.eop || l > bits_left(&r) / 8 {return .Bad_Header}
		for _ in 0 ..< l {_ = bits_read(&r, 8)}
	}
	if bits_read(&r, 1) != 1 || r.eop {return .Bad_Header}
	return .None
}

// setup_parse reads the setup packet into the arena and allocates the work
// memory the id header's block sizes and channel count call for.
setup_parse :: proc "contextless" (s: ^Setup, a: ^Arena, id: Id_Header, pkt: []byte) -> Error {
	s^ = {}
	s.channels, s.rate, s.block = id.channels, int(id.rate), id.block
	if len(pkt) < 7 || pkt[0] != 5 || string(pkt[1:7]) != "vorbis" {return .Bad_Setup}
	r := bits_init(pkt[7:])
	ok: bool

	nbooks := int(bits_read(&r, 8)) + 1
	s.books, ok = arena_make(a, Codebook, nbooks)
	if !ok {return .Over_Limit}
	lookup_left := MAX_LOOKUP_BYTES
	for i in 0 ..< nbooks {
		if e := codebook_parse(&r, a, &s.books[i], &lookup_left); e != .None {return e}
	}

	ntime := int(bits_read(&r, 6)) + 1
	for _ in 0 ..< ntime {
		if bits_read(&r, 16) != 0 {return .Bad_Setup}
	}

	nfloors := int(bits_read(&r, 6)) + 1
	s.floors, ok = arena_make(a, Floor, nfloors)
	if !ok {return .Over_Limit}
	for i in 0 ..< nfloors {
		if e := floor_parse(&r, a, s, &s.floors[i]); e != .None {return e}
	}

	nres := int(bits_read(&r, 6)) + 1
	s.residues, ok = arena_make(a, Residue, nres)
	if !ok {return .Over_Limit}
	for i in 0 ..< nres {
		if e := residue_parse(&r, s, &s.residues[i]); e != .None {return e}
	}

	nmaps := int(bits_read(&r, 6)) + 1
	s.mappings, ok = arena_make(a, Mapping, nmaps)
	if !ok {return .Over_Limit}
	for i in 0 ..< nmaps {
		m := &s.mappings[i]
		if bits_read(&r, 16) != 0 {return .Bad_Setup}
		m.nsub = 1
		if bits_read(&r, 1) != 0 {m.nsub = int(bits_read(&r, 4)) + 1}
		if bits_read(&r, 1) != 0 {
			m.ncoupling = int(bits_read(&r, 8)) + 1
			cb := u32(ilog(s.channels - 1))
			for c in 0 ..< m.ncoupling {
				mag := int(bits_read(&r, cb))
				ang := int(bits_read(&r, cb))
				if mag == ang || mag >= s.channels || ang >= s.channels {return .Bad_Setup}
				m.coupling[c] = {u8(mag), u8(ang)}
			}
		}
		if bits_read(&r, 2) != 0 {return .Bad_Setup}
		if m.nsub > 1 {
			for c in 0 ..< s.channels {
				m.mux[c] = u8(bits_read(&r, 4))
				if int(m.mux[c]) >= m.nsub {return .Bad_Setup}
			}
		}
		for j in 0 ..< m.nsub {
			_ = bits_read(&r, 8)
			f := int(bits_read(&r, 8))
			rs := int(bits_read(&r, 8))
			if f >= nfloors || rs >= nres {return .Bad_Setup}
			m.floor[j], m.residue[j] = u8(f), u8(rs)
		}
		if r.eop {return .Bad_Setup}
	}

	nmodes := int(bits_read(&r, 6)) + 1
	s.modes, ok = arena_make(a, Mode, nmodes)
	if !ok {return .Over_Limit}
	for i in 0 ..< nmodes {
		flag := bits_read(&r, 1)
		if bits_read(&r, 16) != 0 || bits_read(&r, 16) != 0 {return .Bad_Setup}
		mp := int(bits_read(&r, 8))
		if mp >= nmaps {return .Bad_Setup}
		s.modes[i] = {flag != 0, u8(mp)}
	}
	s.mode_bits = u32(ilog(nmodes - 1))
	if bits_read(&r, 1) != 1 || r.eop {return .Bad_Setup}

	return setup_work(s, a)
}

// setup_work allocates the buffers one decode needs and builds the tables
// that depend on the block sizes. Every number is from base.sin, base.cos
// and base.exp.
setup_work :: proc "contextless" (s: ^Setup, a: ^Arena) -> Error {
	ch := s.channels
	half := s.block[1] / 2
	ok: bool
	for k in 0 ..< 2 {
		s.slope[k], ok = arena_make(a, f32, s.block[k] / 2)
		if !ok {return .Over_Limit}
		window_slope(s.slope[k])
		if e := mdct_init(&s.mdct[k], a, s.block[k]); e != .None {return e}
	}
	s.spec, ok = arena_make(a, []f32, ch)
	if !ok {return .Over_Limit}
	s.blk, ok = arena_make(a, []f32, ch)
	if !ok {return .Over_Limit}
	s.ovl, ok = arena_make(a, []f32, ch)
	if !ok {return .Over_Limit}
	s.pcm, ok = arena_make(a, []f32, ch)
	if !ok {return .Over_Limit}
	s.f_y, ok = arena_make(a, []i32, ch)
	if !ok {return .Over_Limit}
	s.f_flag, ok = arena_make(a, []bool, ch)
	if !ok {return .Over_Limit}
	s.f_coef, ok = arena_make(a, []f32, ch)
	if !ok {return .Over_Limit}
	for c in 0 ..< ch {
		s.spec[c], ok = arena_make(a, f32, half)
		if !ok {return .Over_Limit}
		s.blk[c], ok = arena_make(a, f32, s.block[1])
		if !ok {return .Over_Limit}
		s.ovl[c], ok = arena_make(a, f32, half)
		if !ok {return .Over_Limit}
		s.pcm[c], ok = arena_make(a, f32, half)
		if !ok {return .Over_Limit}
		s.f_y[c], ok = arena_make(a, i32, MAX_FLOOR1_POINTS)
		if !ok {return .Over_Limit}
		s.f_flag[c], ok = arena_make(a, bool, MAX_FLOOR1_POINTS)
		if !ok {return .Over_Limit}
		s.f_coef[c], ok = arena_make(a, f32, MAX_FLOOR0_ORDER)
		if !ok {return .Over_Limit}
	}
	s.f_used, ok = arena_make(a, bool, ch)
	if !ok {return .Over_Limit}
	s.f_amp, ok = arena_make(a, f32, ch)
	if !ok {return .Over_Limit}
	s.res_skip, ok = arena_make(a, bool, ch)
	if !ok {return .Over_Limit}
	s.res_tmp, ok = arena_make(a, f32, ch * half)
	if !ok {return .Over_Limit}
	s.res_class, ok = arena_make(a, u8, ch * half) // partitions never exceed the half block
	if !ok {return .Over_Limit}
	s.dct, ok = arena_make(a, f32, half)
	if !ok {return .Over_Limit}
	s.fft, ok = arena_make(a, f32, half)
	if !ok {return .Over_Limit}
	s.floor1_db, ok = arena_make(a, f32, 256)
	if !ok {return .Over_Limit}
	floor1_db_table(s.floor1_db)
	for &f in s.floors {
		if f.kind == 0 {
			for k in 0 ..< 2 {
				f.f0_map[k], ok = arena_make(a, i32, s.block[k] / 2 + 1)
				if !ok {return .Over_Limit}
				floor0_map(&f, f.f0_map[k], s.block[k] / 2)
			}
		}
	}
	return .None
}
