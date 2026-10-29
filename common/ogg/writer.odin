package ogg

// A writer for the files the tests and the test-file generator make: bits
// least significant first as Vorbis packs them, and Ogg pages around packets.
// Not a codec: the decoder never uses it.

Bit_Writer :: struct {
	buf: [dynamic]byte,
	n:   u32, // bits used in the last byte
}

bit_put :: proc(w: ^Bit_Writer, v: u64, bits: u32) {
	for i in 0 ..< bits {
		if w.n == 0 {append(&w.buf, 0)}
		if (v >> i) & 1 != 0 {w.buf[len(w.buf) - 1] |= 1 << w.n}
		w.n = (w.n + 1) & 7
	}
}

// bit_put_code writes a Huffman codeword: its most significant bit first.
bit_put_code :: proc(w: ^Bit_Writer, code: u64, bits: u32) {
	for i := i32(bits) - 1; i >= 0; i -= 1 {bit_put(w, (code >> u32(i)) & 1, 1)}
}

Packet :: struct {
	data:    []byte,
	granule: i64, // the granule position at the end of this packet
	flush:   bool, // a page ends after this packet
}

// write_stream puts the packets into pages: at most `per_page` segments each
// (a longer packet continues on the next page), a page ending where `flush`
// says. The first page has the first-page flag, the last the last-page flag
// when `eos`; a page's granule is that of the last packet to end on it.
write_stream :: proc(
	packets: []Packet,
	serial: u32,
	eos := true,
	per_page := 255,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	Seg :: struct {
		lace:    int,
		data:    []byte,
		end:     bool,
		granule: i64,
		flush:   bool,
	}
	segs := make([dynamic]Seg, context.temp_allocator)
	for p in packets {
		at := 0
		for {
			l := min(255, len(p.data) - at)
			append(&segs, Seg{l, p.data[at:at + l], false, 0, false})
			at += l
			if l < 255 {break}
			if at == len(p.data) {
				append(&segs, Seg{0, nil, false, 0, false})
				break
			}
		}
		segs[len(segs) - 1].end = true
		segs[len(segs) - 1].granule = p.granule
		segs[len(segs) - 1].flush = p.flush
	}
	i, seq := 0, u32(0)
	for i < len(segs) || seq == 0 {
		n := 0
		for i + n < len(segs) && n < per_page {
			n += 1
			if segs[i + n - 1].flush {break}
		}
		page := make([dynamic]byte, context.temp_allocator)
		append(&page, 'O', 'g', 'g', 'S', 0)
		flags: u8
		if seq == 0 {flags |= PAGE_FIRST}
		if i > 0 && !segs[i - 1].end {flags |= PAGE_CONTINUED}
		last := i + n >= len(segs)
		if last && eos {flags |= PAGE_LAST}
		append(&page, flags)
		g: i64 = -1
		for k in 0 ..< n {if segs[i + k].end {g = segs[i + k].granule}}
		for k in 0 ..< u32(8) {append(&page, u8(u64(g) >> (8 * k)))}
		for k in 0 ..< u32(4) {append(&page, u8(serial >> (8 * k)))}
		for k in 0 ..< u32(4) {append(&page, u8(seq >> (8 * k)))}
		append(&page, 0, 0, 0, 0)
		append(&page, u8(n))
		for k in 0 ..< n {append(&page, u8(segs[i + k].lace))}
		for k in 0 ..< n {append(&page, ..segs[i + k].data)}
		c := page_crc(page[:])
		for k in 0 ..< u32(4) {page[22 + k] = u8(c >> (8 * k))}
		append(&out, ..page[:])
		i += n
		seq += 1
	}
	return out[:]
}
