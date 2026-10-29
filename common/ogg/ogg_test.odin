package ogg

import "../../base"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"


MUSIC_DIR :: #directory + "/../../assets/music/"
TESTDATA :: #directory + "/testdata/"

// decode_all: the whole file as interleaved f32 (the channels of its first link).
decode_all :: proc(
	data: []byte,
	allocator := context.temp_allocator,
) -> (
	pcm: []f32,
	inf: Info,
	err: Error,
) {
	d, e := open(data)
	if e != .None {return nil, {}, e}
	defer close(d)
	inf = info(d)
	buf := make([dynamic]f32, allocator)
	block: [4096]f32
	for {
		n, re := read(d, block[:])
		if re != .None {
			err = re
			break
		}
		if n == 0 {break}
		append(&buf, ..block[:n * int(info(d).channels)])
	}
	return buf[:], inf, err
}

// digest: FNV-1a over the little-endian bytes of the samples.
digest :: proc(pcm: []f32) -> u64 {
	h := u64(0xcbf29ce484222325)
	for v in pcm {
		b: [4]byte
		endian.put_u32(b[:], .Little, transmute(u32)v)
		for x in b {h = (h ~ u64(x)) * 0x100000001b3}
	}
	return h
}

MUSIC_FILES :: [7]string{"death", "deep", "discovery", "far", "meadow", "night", "title"}

CLICK :: #load("../game/testdata/click.ogg")
TONE :: #load("../../client/audio/testdata/tone.ogg")

// --- a small Ogg writer and a bit writer, to make the files the tests refuse

Bw :: struct {
	buf: [dynamic]byte,
	n:   u32, // bits in the last byte
}

bw_put :: proc(w: ^Bw, v: u64, bits: u32) {
	for i in 0 ..< bits {
		if w.n == 0 {append(&w.buf, 0)}
		if (v >> i) & 1 != 0 {w.buf[len(w.buf) - 1] |= 1 << w.n}
		w.n = (w.n + 1) & 7
	}
}

// bw_book writes a codebook of `entries` entries, all of length `len` bits.
bw_book :: proc(w: ^Bw, dim, entries, len_bits: int, lookup: u64 = 0) {
	bw_put(w, 0x564342, 24)
	bw_put(w, u64(dim), 16)
	bw_put(w, u64(entries), 24)
	bw_put(w, 0, 1)
	bw_put(w, 0, 1)
	for _ in 0 ..< entries {bw_put(w, u64(len_bits - 1), 5)}
	bw_put(w, lookup, 4)
}

Setup_Opts :: struct {
	books:        int, // codebooks written (each of 2 entries, 1 bit)
	big_books:    int, // codebooks of 65536 entries, 16 bits, dimension 1, lookup 0
	big_lookup:   int, // codebooks of 65536 entries, dimension 16, lookup type 2 (4 MiB each)
	lens:         []u8, // when set, book 0's lengths (entries = len)
	lookup:       u64,
	res_book:     int, // the book residue class 0 names for pass 0, -1 for none
	map_floor:    int,
	map_residue:  int,
	mode_mapping: int,
	mode_window:  u64,
	mode_xform:   u64,
}

setup_bytes :: proc(o: Setup_Opts, allocator := context.temp_allocator) -> []byte {
	w := Bw {
		buf = make([dynamic]byte, allocator),
	}
	for c in ([]byte{5, 'v', 'o', 'r', 'b', 'i', 's'}) {bw_put(&w, u64(c), 8)}
	books := o.books + o.big_books + o.big_lookup
	if books == 0 {books = 1}
	bw_put(&w, u64(books - 1), 8)
	if o.lens != nil {
		bw_put(&w, 0x564342, 24)
		bw_put(&w, 1, 16)
		bw_put(&w, u64(len(o.lens)), 24)
		bw_put(&w, 0, 1)
		bw_put(&w, 0, 1)
		for l in o.lens {bw_put(&w, u64(l - 1), 5)}
		bw_put(&w, o.lookup, 4)
	}
	n := 1 if o.lens != nil else 0
	for _ in 0 ..< o.big_books {bw_book(&w, 1, 65536, 16)}
	for _ in 0 ..< o.big_lookup {
		bw_book(&w, 16, 65536, 16, 2)
		bw_put(&w, 0, 32) // minimum
		bw_put(&w, 0, 32) // delta
		bw_put(&w, 0, 4) // value bits - 1
		bw_put(&w, 0, 1)
		for _ in 0 ..< 65536 * 16 {bw_put(&w, 0, 1)}
	}
	for _ in 0 ..< max(o.books, 1) - n {
		if o.books == 0 && o.big_books + o.big_lookup > 0 {break}
		bw_book(&w, 1, 2, 1, o.lookup if o.lookup == 3 else 1)
		if o.lookup != 3 {
			bw_put(&w, 0, 32)
			bw_put(&w, 0, 32)
			bw_put(&w, 0, 4)
			bw_put(&w, 0, 1)
			bw_put(&w, 0, 2) // two values of one bit
		}
	}
	bw_put(&w, 0, 6) // one time transform
	bw_put(&w, 0, 16)
	bw_put(&w, 0, 6) // one floor
	bw_put(&w, 1, 16)
	bw_put(&w, 0, 5) // no partitions
	bw_put(&w, 0, 2) // multiplier 1
	bw_put(&w, 4, 4) // range bits
	bw_put(&w, 0, 6) // one residue
	bw_put(&w, 1, 16)
	bw_put(&w, 0, 24)
	bw_put(&w, 0, 24)
	bw_put(&w, 15, 24) // partition size 16
	bw_put(&w, 0, 6) // one class
	bw_put(&w, 0, 8) // classbook 0
	bw_put(&w, 1, 3) // cascade: pass 0 only
	bw_put(&w, 0, 1)
	bw_put(&w, u64(max(o.res_book, 0)) if o.res_book >= 0 else 0, 8)
	bw_put(&w, 0, 6) // one mapping
	bw_put(&w, 0, 16)
	bw_put(&w, 0, 1)
	bw_put(&w, 0, 1)
	bw_put(&w, 0, 2)
	bw_put(&w, 0, 8)
	bw_put(&w, u64(o.map_floor), 8)
	bw_put(&w, u64(o.map_residue), 8)
	bw_put(&w, 0, 6) // one mode
	bw_put(&w, 0, 1)
	bw_put(&w, o.mode_window, 16)
	bw_put(&w, o.mode_xform, 16)
	bw_put(&w, u64(o.mode_mapping), 8)
	bw_put(&w, 1, 1)
	return w.buf[:]
}

test_id :: Id_Header{1, 44100, 0, {256, 2048}}

parse_setup :: proc(pkt: []byte) -> Error {
	buf := make([]byte, MAX_DECODER_BYTES)
	defer delete(buf)
	a := Arena {
		buf = buf,
	}
	s: Setup
	return setup_parse(&s, &a, test_id, pkt)
}

// pages_of lists the pages of a file.
pages_of :: proc(data: []byte) -> []Page {
	out := make([dynamic]Page, context.temp_allocator)
	off := 0
	for off < len(data) {
		p, e := page_parse(data, off, false)
		if e != .None {break}
		append(&out, p)
		off += p.len
	}
	return out[:]
}

// header_packets: the three header packets of the first link.
header_packets :: proc(data: []byte) -> (pk: [3][]byte) {
	d, _ := open(data)
	defer close(d)
	// (open read them: re-read through the cursor)
	d.pg, d.seg, d.next_off = {}, 0, d.links[0].first
	for k in 0 ..< 3 {
		n, _, _, _ := next_packet(d)
		pk[k] = make([]byte, n, context.temp_allocator)
		copy(pk[k], d.pkt[:n])
	}
	return
}

// write_pages: packets into pages (at most `per_page` segments each), the
// last page's granule `granule`. The first page has the first-page flag, the
// last the last-page flag when `eos`.
write_pages :: proc(
	packets: [][]byte,
	serial: u32,
	granule: i64,
	eos := true,
	per_page := 255,
	allocator := context.temp_allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	// Segments of every packet.
	Seg :: struct {
		lace: int,
		data: []byte,
		end:  bool,
	}
	segs := make([dynamic]Seg, context.temp_allocator)
	for p in packets {
		at := 0
		for {
			l := min(255, len(p) - at)
			append(&segs, Seg{l, p[at:at + l], false})
			at += l
			if l < 255 {break}
			if at == len(p) {
				append(&segs, Seg{0, nil, false})
				break
			}
		}
		segs[len(segs) - 1].end = true
	}
	i, seq := 0, u32(0)
	for i < len(segs) || seq == 0 {
		n := min(per_page, len(segs) - i)
		page := make([dynamic]byte, context.temp_allocator)
		append(&page, 'O', 'g', 'g', 'S', 0)
		flags: u8
		if seq == 0 {flags |= PAGE_FIRST}
		if i > 0 && !segs[i - 1].end {flags |= PAGE_CONTINUED}
		last := i + n >= len(segs)
		if last && eos {flags |= PAGE_LAST}
		append(&page, flags)
		g: i64 = -1
		// A page whose last segment ends a packet carries a granule (the last page's is given).
		if last {g = granule} else if n > 0 && segs[i + n - 1].end {g = 0}
		for k in 0 ..< 8 {append(&page, u8(u64(g) >> (8 * u32(k))))}
		for k in 0 ..< 4 {append(&page, u8(serial >> (8 * u32(k))))}
		for k in 0 ..< 4 {append(&page, u8(seq >> (8 * u32(k))))}
		append(&page, 0, 0, 0, 0)
		append(&page, u8(n))
		for k in 0 ..< n {append(&page, u8(segs[i + k].lace))}
		for k in 0 ..< n {append(&page, ..segs[i + k].data)}
		c := page_crc(page[:])
		for k in 0 ..< 4 {page[22 + k] = u8(c >> (8 * u32(k)))}
		append(&out, ..page[:])
		i += n
		seq += 1
	}
	return out[:]
}

expect_refused :: proc(
	t: ^testing.T,
	name: string,
	data: []byte,
	want: Error,
	loc := #caller_location,
) {
	track: mem_tracking
	allocator := tracking_make(&track)
	d, err := open(data, allocator)
	testing.expectf(t, err == want, "%s: open gave %v, want %v", name, err, want, loc = loc)
	if d != nil {close(d)}
	testing.expectf(t, track.total <= 1, "%s: %d allocations", name, track.total, loc = loc)
	testing.expectf(t, track.live == 0, "%s: %d blocks left", name, track.live, loc = loc)
	_, _, serr := scan(data)
	testing.expectf(
		t,
		(serr == .None) == (want == .None) ||
		want == .Bad_Header ||
		want == .Bad_Setup ||
		want == .Over_Limit ||
		want == .Bad_Packet,
		"%s: scan gave %v",
		name,
		serr,
		loc = loc,
	)
}

mem_tracking :: struct {
	total: int,
	live:  int,
	bytes: int,
	inner: mem.Allocator,
}

tracking_make :: proc(t: ^mem_tracking) -> mem.Allocator {
	t.inner = context.allocator
	return mem.Allocator {
		data = t,
		procedure = proc(
			data: rawptr,
			mode: mem.Allocator_Mode,
			size, alignment: int,
			old: rawptr,
			old_size: int,
			loc := #caller_location,
		) -> (
			[]byte,
			mem.Allocator_Error,
		) {
			t := (^mem_tracking)(data)
			#partial switch mode {
			case .Alloc, .Alloc_Non_Zeroed:
				t.total += 1
				t.live += 1
				t.bytes += size
			case .Free:
				t.live -= 1
			}
			return t.inner.procedure(t.inner.data, mode, size, alignment, old, old_size, loc)
		},
	}
}

@(test)
test_ogg_scan_and_decode_small :: proc(t: ^testing.T) {
	inf, links, err := scan(CLICK)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, links, 1)
	testing.expect_value(t, inf.rate, u32(16000))
	testing.expect_value(t, inf.channels, u8(1))
	pcm, dinf, derr := decode_all(CLICK)
	testing.expect_value(t, derr, Error.None)
	testing.expect_value(t, u64(len(pcm)), inf.frames)
	testing.expect_value(t, dinf.frames, inf.frames)
	peak: f32
	for v in pcm {peak = max(peak, abs(v))}
	testing.expect(t, peak > 0.01 && peak <= 1.5, "the click is audible")

	inf, links, err = scan(TONE)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, inf.rate, u32(44100))
	testing.expect_value(t, inf.channels, u8(2))
	testing.expect(t, inf.frames >= 44100 * 3 - 4096 && inf.frames <= 44100 * 3, "3 s of tone")
	pcm, _, derr = decode_all(TONE)
	testing.expect_value(t, derr, Error.None)
	testing.expect_value(t, u64(len(pcm)), inf.frames * 2)
}

// chained: two links of different rates and channel counts, three links with
// the same file twice; `read` crosses without a gap, `info` follows the link.
@(test)
test_ogg_chained :: proc(t: ^testing.T) {
	a, _, _ := decode_all(TONE)
	b, _, _ := decode_all(CLICK)
	both := make([]byte, len(TONE) + len(CLICK) + len(TONE), context.temp_allocator)
	copy(both, TONE)
	copy(both[len(TONE):], CLICK)
	copy(both[len(TONE) + len(CLICK):], TONE)
	inf, links, err := scan(both)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, links, 3)
	d, oerr := open(both)
	testing.expect_value(t, oerr, Error.None)
	defer close(d)
	testing.expect_value(t, info(d).frames, u64(len(a) / 2 + len(b) + len(a) / 2))
	seen := [3]int{}
	rates := make([dynamic]u32, context.temp_allocator)
	block: [1024]f32
	got := make([dynamic]f32, context.temp_allocator)
	for {
		n, e := read(d, block[:])
		testing.expect_value(t, e, Error.None)
		if n == 0 {break}
		i := info(d)
		if len(rates) == 0 || rates[len(rates) - 1] != i.rate {append(&rates, i.rate)}
		append(&got, ..block[:n * int(i.channels)])
		_ = seen
	}
	testing.expect_value(t, len(rates), 3)
	testing.expect_value(t, len(got), len(a) + len(b) + len(a))
	same := true
	for v, i in a {same &&= got[i] == v}
	for v, i in b {same &&= got[len(a) + i] == v}
	for v, i in a {same &&= got[len(a) + len(b) + i] == v}
	testing.expect(t, same, "each link decodes as it does alone")
	_ = inf
}

// A link with headers and no audio decodes to nothing; one in the middle is skipped.
@(test)
test_ogg_headers_only :: proc(t: ^testing.T) {
	hp := header_packets(CLICK)
	only := write_pages(hp[:], 7, 0)
	pcm, inf, err := decode_all(only)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(pcm), 0)
	testing.expect_value(t, inf.rate, u32(16000))
	three := make([]byte, 2 * len(CLICK) + len(only), context.temp_allocator)
	copy(three, CLICK)
	copy(three[len(CLICK):], only)
	copy(three[len(CLICK) + len(only):], CLICK)
	one, _, _ := decode_all(CLICK)
	all, _, err2 := decode_all(three)
	testing.expect_value(t, err2, Error.None)
	testing.expect_value(t, len(all), 2 * len(one))
}

// The last page's granule cuts the end: a stream cut mid-block.
@(test)
test_ogg_granule_cuts :: proc(t: ^testing.T) {
	full, _, _ := decode_all(TONE)
	for keep in ([]int{1, 77, 4096, 40000}) {
		data := make([]byte, len(TONE), context.temp_allocator)
		copy(data, TONE)
		pg := pages_of(data)
		last := pg[len(pg) - 1]
		for i in 0 ..< 8 {data[last.off + 6 + i] = u8(u64(keep) >> (8 * u32(i)))}
		// the earlier pages carry the real granules: the cut must still be above them
		repair_crc(data)
		pcm, inf, err := decode_all(data)
		prev := pg[len(pg) - 2].granule
		if i64(keep) < prev {
			// The link is shorter than a page before it said: the frames are cut at `keep`.
			testing.expect_value(t, err, Error.None)
		}
		testing.expect_value(
			t,
			u64(len(pcm)),
			min(u64(keep), inf.frames * 0 + u64(len(full) / 2)) * 2,
		)
		for v, i in pcm {
			if v != full[i] {
				testing.expectf(t, false, "keep %d: sample %d differs", keep, i)
				break
			}
		}
	}
}

@(test)
test_ogg_refuses :: proc(t: ^testing.T) {
	expect_refused(t, "empty", nil, .Truncated)
	expect_refused(t, "3 bytes", []byte{'O', 'g', 'g'}, .Truncated)
	expect_refused(t, "OggS alone", []byte{'O', 'g', 'g', 'S'}, .Truncated)
	expect_refused(
		t,
		"text",
		transmute([]byte)string("this is not an Ogg file at all, not even close"),
		.Bad_Page,
	)

	// A bad CRC in the first, a middle and the last page.
	tone := TONE
	pg := pages_of(tone)
	for idx in ([]int{0, len(pg) / 2, len(pg) - 1}) {
		data := make([]byte, len(TONE), context.temp_allocator)
		copy(data, TONE)
		data[pg[idx].off + pg[idx].len - 1] ~= 0x10
		expect_refused(t, fmt.tprintf("crc of page %d", idx), data, .Bad_Crc)
	}
	// A sequence gap (a page taken out) and a page of another serial.
	gap := make([dynamic]byte, context.temp_allocator)
	for p, i in pg {if i != 2 {append(&gap, ..tone[p.off:p.off + p.len])}}
	expect_refused(t, "sequence gap", gap[:], .Bad_Page)
	other := make([]byte, len(TONE), context.temp_allocator)
	copy(other, TONE)
	other[pg[2].off + 14] ~= 0x55
	repair_crc(other)
	expect_refused(t, "other serial", other, .Bad_Page)
	// A continued packet with nothing before it.
	cont := make([]byte, len(TONE), context.temp_allocator)
	copy(cont, TONE)
	cont[pg[0].off + 5] |= PAGE_CONTINUED
	repair_crc(cont)
	expect_refused(t, "continued first page", cont, .Bad_Page)
	// Not Vorbis.
	heads := [3]string {
		"OpusHead\x01\x02\x38\x01",
		"\x7fFLAC\x00\x01\x00\x00",
		"\x80theora\x03\x02",
	}
	for head in heads {
		pk := [][]byte{transmute([]byte)head}
		expect_refused(t, head[1:5], write_pages(pk, 1, 0), .Not_Vorbis)
	}
	// Two interleaved Vorbis serials.
	hp := header_packets(CLICK)
	a := write_pages(hp[:1], 1, 0, eos = false)
	b := write_pages(hp[:1], 2, 0, eos = false)
	two := make([dynamic]byte, context.temp_allocator)
	append(&two, ..a)
	append(&two, ..b)
	expect_refused(t, "interleaved serials", two[:], .Unsupported)
	// A packet over MAX_PACKET.
	big := make([]byte, MAX_PACKET + 1000, context.temp_allocator)
	pk2 := [][]byte{hp[0], big}
	expect_refused(t, "huge packet", write_pages(pk2, 1, 0), .Over_Limit)
	// Last page granule negative; 65 links; headers cut.
	neg := make([]byte, len(TONE), context.temp_allocator)
	copy(neg, TONE)
	last := pg[len(pg) - 1]
	for i in 0 ..< 8 {neg[last.off + 6 + i] = 0xff}
	repair_crc(neg)
	expect_refused(t, "granule -1 on the last page", neg, .Bad_Page)
	for i in 0 ..< 8 {neg[last.off + 6 + i] = 0xfb}
	repair_crc(neg)
	expect_refused(t, "granule -5", neg, .Bad_Page)
	links := make([dynamic]byte, context.temp_allocator)
	for _ in 0 ..< MAX_LINKS + 1 {append(&links, ..CLICK)}
	expect_refused(t, "65 links", links[:], .Over_Limit)
	// A granule above what the packets could decode.
	huge := make([]byte, len(CLICK), context.temp_allocator)
	copy(huge, CLICK)
	hpg := pages_of(huge)
	for i in 0 ..< 8 {huge[hpg[len(hpg) - 1].off + 6 + i] = u8(u64(1 << 40) >> (8 * u32(i)))}
	repair_crc(huge)
	expect_refused(t, "granule beyond the data", huge, .Bad_Page)

	// Identification headers.
	id_cases := [?]struct {
		name: string,
		edit: proc(id: []byte),
		want: Error,
	} {
		{"0 channels", proc(id: []byte) {id[11] = 0}, .Bad_Header},
		{"0 rate", proc(id: []byte) {id[12], id[13], id[14], id[15] = 0, 0, 0, 0}, .Bad_Header},
		{"blocksize 2^5", proc(id: []byte) {id[28] = 0x85}, .Bad_Header},
		{"blocksize 2^14", proc(id: []byte) {id[28] = 0xe8}, .Bad_Header},
		{"short above long", proc(id: []byte) {id[28] = 0x8b}, .Bad_Header},
		{"no framing bit", proc(id: []byte) {id[29] = 0}, .Bad_Header},
		{"9 channels", proc(id: []byte) {id[11] = 9}, .Over_Limit},
	}
	for c in id_cases {
		idp := make([]byte, len(hp[0]), context.temp_allocator)
		copy(idp, hp[0])
		c.edit(idp)
		pk3 := [][]byte{idp, hp[1], hp[2]}
		expect_refused(t, c.name, write_pages(pk3, 1, 0), c.want)
	}
	// A comment header whose length field points past the packet.
	cm := make([]byte, len(hp[1]), context.temp_allocator)
	copy(cm, hp[1])
	cm[7], cm[8], cm[9], cm[10] = 0xff, 0xff, 0, 0
	expect_refused(t, "comment length", write_pages([][]byte{hp[0], cm, hp[2]}, 1, 0), .Bad_Header)
}

@(test)
test_ogg_refuses_setups :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_setup(setup_bytes({})), Error.None)
	cases := [?]struct {
		name: string,
		o:    Setup_Opts,
		want: Error,
	} {
		{
			"a codebook of 70000 entries",
			{lens = make([]u8, 70000, context.temp_allocator)},
			.Over_Limit,
		},
		{"an over-specified tree", {lens = {1, 1, 1}}, .Bad_Setup},
		{"an under-specified tree", {lens = {2, 2}}, .Bad_Setup},
		{"lookup type 3", {books = 1, lookup = 3}, .Bad_Setup},
		{"lookup tables over 4 MiB", {big_lookup = 2}, .Over_Limit},
		{"a residue naming a book that does not exist", {res_book = 9}, .Bad_Setup},
		{"a mapping naming a floor that does not exist", {map_floor = 3}, .Bad_Setup},
		{"a mapping naming a residue that does not exist", {map_residue = 3}, .Bad_Setup},
		{"a mode naming a mapping that does not exist", {mode_mapping = 4}, .Bad_Setup},
		{"a mode with a window type", {mode_window = 1}, .Bad_Setup},
		{"a mode with a transform type", {mode_xform = 1}, .Bad_Setup},
		{"a setup needing over the decoder's memory", {big_books = 12}, .Over_Limit},
	}
	for &c in cases {
		got := parse_setup(setup_bytes(c.o))
		testing.expectf(t, got == c.want, "%s: %v, want %v", c.name, got, c.want)
	}
	// Cut anywhere, the setup is an error, not a crash.
	good := setup_bytes({})
	for n in 0 ..< len(good) {
		testing.expectf(t, parse_setup(good[:n]) != .None, "setup cut at %d parses", n)
	}
}

@(test)
test_ogg_truncation :: proc(t: ^testing.T) {
	tone := TONE
	full, _, _ := decode_all(tone)
	// Cut inside the headers: an error every time, never a crash.
	for n in 0 ..< 200 {
		_, err := open(tone[:n])
		testing.expectf(t, err != .None, "cut at %d opened", n)
	}
	// Cut at a page boundary: what is whole decodes, then Truncated once.
	pg := pages_of(tone)
	for p, i in pg[:len(pg) - 1] {
		end := p.off + p.len
		d, err := open(tone[:end])
		if err != .None {
			testing.expectf(t, i < 3, "boundary after page %d: %v", i, err)
			continue
		}
		block: [512]f32
		got := make([dynamic]f32, context.temp_allocator)
		final := Error.None
		reads_after := 0
		for {
			n, e := read(d, block[:])
			if e != .None {
				final = e
				n2, e2 := read(d, block[:])
				testing.expect_value(t, n2, 0)
				testing.expect_value(t, e2, Error.None)
				reads_after += 1
				break
			}
			if n == 0 {break}
			append(&got, ..block[:n * 2])
		}
		testing.expectf(t, final == .Truncated, "boundary after page %d: ended with %v", i, final)
		testing.expectf(t, len(got) > 0 || i < 3, "boundary after page %d: nothing decoded", i)
		same := len(got) <= len(full)
		for v, k in got {if k < len(full) {same &&= v == full[k]}}
		testing.expectf(t, same, "boundary after page %d: samples differ from the whole file's", i)
		close(d)
	}
	// Cut anywhere else: an error or a clean prefix.
	for n := 200; n < len(tone); n += 997 {
		d, err := open(tone[:n])
		if err != .None {continue}
		block: [512]f32
		for {
			k, e := read(d, block[:])
			if e != .None || k == 0 {break}
		}
		close(d)
	}
}

@(test)
test_ogg_seek :: proc(t: ^testing.T) {
	chain := make([dynamic]byte, context.temp_allocator)
	append(&chain, ..TONE)
	append(&chain, ..CLICK)
	append(&chain, ..TONE)
	files := make([dynamic][]byte, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	append(&files, TONE, chain[:])
	append(&names, "tone", "chained")
	for name in MUSIC_FILES {
		data, rerr := os.read_entire_file(
			strings.concatenate({MUSIC_DIR, name, ".ogg"}, context.temp_allocator),
			context.temp_allocator,
		)
		if rerr != nil {continue}
		append(&files, data)
		append(&names, name)
	}
	for data, fi in files {
		// The straight decode, link by link.
		d, _ := open(data)
		defer close(d)
		total := info(d).frames
		samples := make([dynamic]f32, context.temp_allocator)
		starts := make([dynamic][3]int, context.temp_allocator) // frame, channels, sample offset
		block: [4096]f32
		frames_done := 0
		last_link := -1
		for {
			n, e := read(d, block[:])
			testing.expect_value(t, e, Error.None)
			if n == 0 {break}
			if d.out_link != last_link {
				last_link = d.out_link
				append(&starts, [3]int{frames_done, int(info(d).channels), len(samples)})
			}
			append(&samples, ..block[:n * int(info(d).channels)])
			frames_done += n
		}
		testing.expect_value(t, u64(frames_done), total)
		rng := base.rng_make(u64(fi) + 1)
		positions := make([dynamic]u64, context.temp_allocator)
		append(&positions, 0, total - 1, total / 2)
		for _ in 0 ..< 100 {append(&positions, base.rng_u64(&rng) % total)}
		for pos in positions {
			testing.expect_value(t, seek(d, pos), Error.None)
			n, e := read(d, block[:])
			testing.expect_value(t, e, Error.None)
			ch := int(info(d).channels)
			// Which link: the last start at or before pos.
			s := starts[0]
			for st in starts {if st[0] <= int(pos) {s = st}}
			at := s[2] + (int(pos) - s[0]) * ch
			testing.expectf(t, n > 0, "%s: seek %d read nothing", names[fi], pos)
			ok := true
			for i in 0 ..< min(n * ch, len(block)) {ok &&= block[i] == samples[at + i]}
			testing.expectf(t, ok, "%s: samples after seek to %d differ", names[fi], pos)
			if !ok {break}
		}
		// Back to the start after reading everything; past the end is an error.
		testing.expect_value(t, seek(d, 0), Error.None)
		n, _ := read(d, block[:])
		testing.expect(
			t,
			n > 0 &&
			block[0] == samples[0] &&
			block[n * int(info(d).channels) - 1] == samples[n * int(info(d).channels) - 1],
			"start again",
		)
		testing.expect_value(t, seek(d, total + 1), Error.Bad_Seek)
		testing.expect_value(t, seek(d, total), Error.None)
		n2, e2 := read(d, block[:])
		testing.expect_value(t, n2, 0)
		testing.expect_value(t, e2, Error.None)
	}
}

@(test)
test_ogg_allocates_once :: proc(t: ^testing.T) {
	for data, i in ([2][]byte{TONE, CLICK}) {
		track: mem_tracking
		d, err := open(data, tracking_make(&track))
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, track.total, 1)
		testing.expectf(t, track.bytes <= MAX_DECODER_BYTES, "%d bytes", track.bytes)
		testing.expectf(t, bytes_used(d) < 1 << 20, "file %d used %d bytes", i, bytes_used(d))
		block: [1024]f32
		for {
			n, _ := read(d, block[:])
			if n == 0 {break}
		}
		_ = seek(d, 100)
		_, _, _ = scan(data)
		_, _ = read(d, block[:])
		testing.expect_value(t, track.total, 1)
		close(d)
		testing.expect_value(t, track.live, 0)
	}
}

@(test)
test_ogg_fuzz :: proc(t: ^testing.T) {
	tone := TONE
	pg := pages_of(tone)
	corpus := make([dynamic][]byte, context.temp_allocator)
	append(&corpus, CLICK, tone[:pg[3].off + pg[3].len])
	two := make([dynamic]byte, context.temp_allocator)
	append(&two, ..CLICK)
	append(&two, ..CLICK)
	append(&corpus, two[:])
	hp := header_packets(CLICK)
	append(&corpus, write_pages(hp[:], 3, 0))
	for name in ([]string{"block_64_128", "stereo_coupled", "six_channels", "floor0_residue0", "chain_mixed", "pages_span3"}) {
		edge, ok := os.read_entire_file(
			fmt.tprintf("%sedge/%s.ogg", TESTDATA, name),
			context.temp_allocator,
		)
		if ok == nil {append(&corpus, edge)}
	}
	// What the fuzzer once broke, replayed first.
	if files, err := os.read_all_directory_by_path(TESTDATA + "regress", context.temp_allocator);
	   err == nil {
		for f in files {
			if data, rerr := os.read_entire_file(
				fmt.tprintf("%sregress/%s", TESTDATA, f.name),
				context.temp_allocator,
			); rerr == nil {
				fuzz_one(data, max_frames = 100_000)
			}
		}
	}
	run_fuzz(t, corpus[:], 1, 20000)
}

run_fuzz :: proc(t: ^testing.T, corpus: [][]byte, seed: u64, iterations: int) {
	rng := base.rng_make(seed)
	for it in 0 ..< iterations {
		src := corpus[int(base.rng_u64(&rng) % u64(len(corpus)))]
		other := corpus[int(base.rng_u64(&rng) % u64(len(corpus)))]
		data := mutate(&rng, src, other, context.temp_allocator)
		if it & 1 == 0 {repair_crc(data)}
		track: mem_tracking
		fuzz_one(data, tracking_make(&track), 100_000)
		if track.total > 1 || track.live != 0 {
			testing.expectf(
				t,
				false,
				"seed %d iteration %d: %d allocations, %d left",
				seed,
				it,
				track.total,
				track.live,
			)
			return
		}
		free_all(context.temp_allocator)
	}
}

// --- golden digests and the reference decoder

// golden: the table's line for a file, "" when there is none.
golden :: proc(path: string) -> (rate: u32, channels: u8, frames: u64, hash: u64, ok: bool) {
	text, err := os.read_entire_file(TESTDATA + "digests.txt", context.temp_allocator)
	if err != nil {return}
	rest := string(text)
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) != 5 || f[0] != path {continue}
		r, _ := strconv.parse_u64(f[1])
		c, _ := strconv.parse_u64(f[2])
		n, _ := strconv.parse_u64(f[3])
		h, _ := strconv.parse_u64(f[4], 16)
		return u32(r), u8(c), n, h, true
	}
	return
}

check_golden :: proc(t: ^testing.T, path: string, data: []byte) -> []f32 {
	pcm, inf, err := decode_all(data)
	testing.expectf(t, err == .None, "%s: %v", path, err)
	rate, channels, frames, hash, ok := golden(path)
	testing.expectf(t, ok, "%s has no line in digests.txt (build ogg digests)", path)
	testing.expectf(
		t,
		inf.rate == rate && inf.channels == channels,
		"%s: %v, want %d Hz %d ch",
		path,
		inf,
		rate,
		channels,
	)
	testing.expectf(t, inf.frames == frames, "%s: %d frames, want %d", path, inf.frames, frames)
	testing.expectf(
		t,
		digest_samples(pcm) == hash,
		"%s: digest %016x, want %016x (a decoder change that is meant: build ogg digests)",
		path,
		digest_samples(pcm),
		hash,
	)
	return pcm
}

// check_reference compares the first, middle and last half second of a music
// file with the reference decoder's, at 16 bits.
check_reference :: proc(t: ^testing.T, name: string, pcm: []f32) {
	frames := len(pcm) / 2
	equal, total, worst := 0, 0, 0
	for place, k in ([3]string{"start", "middle", "end"}) {
		path := fmt.tprintf("%sreference/%s.%s.s16", TESTDATA, name, place)
		ref, err := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, err == nil, "%s missing (build ogg reference)", path)
		at := [3]int{0, frames / 2, frames - WINDOW_FRAMES}[k]
		for i in 0 ..< WINDOW_FRAMES * 2 {
			want, _ := endian.get_i16(ref[2 * i:], .Little)
			got := to_s16(pcm[at * 2 + i])
			dlt := abs(int(got) - int(want))
			worst = max(worst, dlt)
			equal += 1 if dlt == 0 else 0
			total += 1
		}
	}
	fraction := f64(equal) / f64(max(total, 1))
	fmt.printfln(
		"ogg reference %s: %.4f%% of %d samples equal, worst %d step",
		name,
		100 * fraction,
		total,
		worst,
	)
	testing.expectf(
		t,
		fraction >= 0.999,
		"%s: only %.4f%% of samples equal the reference's",
		name,
		100 * fraction,
	)
	testing.expectf(t, worst <= 1, "%s: a sample is %d steps from the reference's", name, worst)
}

WINDOW_FRAMES :: 24000

music_golden :: proc(t: ^testing.T, name: string) {
	path := fmt.tprintf("assets/music/%s.ogg", name)
	data, err := os.read_entire_file(
		fmt.tprintf("%s%s.ogg", MUSIC_DIR, name),
		context.temp_allocator,
	)
	testing.expectf(t, err == nil, "%s: %v", path, err)
	pcm := check_golden(t, path, data)
	check_reference(t, name, pcm)
}

@(test)
test_ogg_golden_death :: proc(t: ^testing.T) {music_golden(t, "death")}
@(test)
test_ogg_golden_deep :: proc(t: ^testing.T) {music_golden(t, "deep")}
@(test)
test_ogg_golden_discovery :: proc(t: ^testing.T) {music_golden(t, "discovery")}
@(test)
test_ogg_golden_far :: proc(t: ^testing.T) {music_golden(t, "far")}
@(test)
test_ogg_golden_meadow :: proc(t: ^testing.T) {music_golden(t, "meadow")}
@(test)
test_ogg_golden_night :: proc(t: ^testing.T) {music_golden(t, "night")}
@(test)
test_ogg_golden_title :: proc(t: ^testing.T) {music_golden(t, "title")}

@(test)
test_ogg_golden_small :: proc(t: ^testing.T) {
	_ = check_golden(t, "client/audio/testdata/tone.ogg", TONE)
	_ = check_golden(t, "common/game/testdata/click.ogg", CLICK)
}

// split_links: a chained file's links as separate files.
split_links :: proc(data: []byte) -> [][]byte {
	out := make([dynamic][]byte, context.temp_allocator)
	start := 0
	for p in pages_of(data) {
		if p.flags & PAGE_FIRST != 0 && p.off > 0 {
			append(&out, data[start:p.off])
			start = p.off
		}
	}
	append(&out, data[start:])
	return out[:]
}

// check_reference_whole compares a whole file with the reference decoder's, at 16 bits.
check_reference_whole :: proc(t: ^testing.T, name: string, pcm: []f32) {
	ref, err := os.read_entire_file(
		fmt.tprintf("%sreference/edge_%s.s16", TESTDATA, name),
		context.temp_allocator,
	)
	testing.expectf(t, err == nil, "%s has no reference (build ogg reference)", name)
	testing.expectf(
		t,
		len(ref) == 2 * len(pcm),
		"%s: %d samples, the reference has %d",
		name,
		len(pcm),
		len(ref) / 2,
	)
	equal, worst := 0, 0
	n := min(len(pcm), len(ref) / 2)
	for i in 0 ..< n {
		want, _ := endian.get_i16(ref[2 * i:], .Little)
		dlt := abs(int(to_s16(pcm[i])) - int(want))
		worst = max(worst, dlt)
		equal += 1 if dlt == 0 else 0
	}
	fraction := f64(equal) / f64(max(n, 1))
	fmt.printfln(
		"ogg reference %s: %.3f%% of %d samples equal, worst %d step",
		name,
		100 * fraction,
		n,
		worst,
	)
	testing.expectf(
		t,
		fraction >= 0.999,
		"%s: only %.4f%% of samples equal the reference's",
		name,
		100 * fraction,
	)
	testing.expectf(t, worst <= 1, "%s: a sample is %d steps from the reference's", name, worst)
}

// Every generated edge-case file (tools/ogg/make.odin): its digest, the reference
// decoder's samples where there is a reference, and a chained file as its links.
@(test)
test_ogg_edge_files :: proc(t: ^testing.T) {
	files, err := os.read_all_directory_by_path(TESTDATA + "edge", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expectf(t, len(files) >= 26, "%d edge files", len(files))
	for f in files {
		if !strings.has_suffix(f.name, ".ogg") {continue}
		name := f.name[:len(f.name) - 4]
		data, rerr := os.read_entire_file(
			fmt.tprintf("%sedge/%s", TESTDATA, f.name),
			context.temp_allocator,
		)
		testing.expectf(t, rerr == nil, "%s: %v", f.name, rerr)
		pcm := check_golden(t, fmt.tprintf("common/ogg/testdata/edge/%s", f.name), data)
		reason := reference_skipped(name)
		if reason == "" {
			check_reference_whole(t, name, pcm)
		} else {
			_, e := os.stat(
				fmt.tprintf("%sreference/edge_%s.s16", TESTDATA, name),
				context.temp_allocator,
			)
			testing.expectf(t, e != nil, "%s has a reference and a reason not to", name)
		}
		// The whole is its links, one after the other.
		parts := split_links(data)
		if len(parts) > 1 {
			joined := make([dynamic]f32, context.temp_allocator)
			for part in parts {
				p, _, pe := decode_all(part)
				testing.expect_value(t, pe, Error.None)
				append(&joined, ..p)
			}
			whole, _, we := decode_all(data)
			testing.expect_value(t, we, Error.None)
			testing.expectf(
				t,
				len(whole) == len(joined),
				"%s: %d samples, its links give %d",
				name,
				len(whole),
				len(joined),
			)
			same := len(whole) == len(joined)
			for i in 0 ..< min(len(whole), len(joined)) {same &&= whole[i] == joined[i]}
			testing.expectf(t, same, "%s: differs from its links decoded alone", name)
		}
	}
}

// A packet that ends mid-residue: the spec's end-of-packet rule zeroes the rest
// of the vector, so the decode goes on, the frame count holds, the samples
// before the packet's own output are those of the whole file, and nothing is
// not-a-number. (No available reference decoder takes such a packet: ffmpeg
// refuses an overread, so this is checked as a property.)
@(test)
test_ogg_cut_packet :: proc(t: ^testing.T) {
	data, rerr := os.read_entire_file(TESTDATA + "edge/stereo_coupled.ogg", context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	d, _ := open(data)
	defer close(d)
	d.pg, d.seg, d.next_off = {}, 0, d.links[0].first
	packets := make([dynamic]Packet, context.temp_allocator)
	for {
		n, granule, eol, e := next_packet(d)
		if eol || e != .None {break}
		body := make([]byte, n, context.temp_allocator)
		copy(body, d.pkt[:n])
		append(&packets, Packet{body, max(granule, 0), true})
	}
	// Granules: each packet's page's (every audio packet has its own page).
	k := len(packets) - 4
	testing.expect(t, k > 3, "enough packets")
	whole := write_stream(packets[:], 1, allocator = context.temp_allocator)
	cut_at := len(packets[k].data) * 6 / 10
	packets[k].data = packets[k].data[:cut_at]
	cut := write_stream(packets[:], 1, allocator = context.temp_allocator)
	a, _, ea := decode_all(whole)
	b, _, eb := decode_all(cut)
	testing.expect_value(t, ea, Error.None)
	testing.expect_value(t, eb, Error.None)
	testing.expect_value(t, len(a), len(b))
	before := int(packets[k - 1].granule) * 2
	same := true
	for i in 0 ..< min(before, len(a)) {same &&= a[i] == b[i]}
	testing.expect(t, same, "the samples before the cut packet's output are the whole file's")
	differs := false
	for i in before ..< min(len(a), len(b)) {differs ||= a[i] != b[i]}
	testing.expect(t, differs, "the cut shows")
	finite := true
	for v in b {finite &&= v == v && abs(v) < 100}
	testing.expect(t, finite, "no NaN or runaway value")
}
