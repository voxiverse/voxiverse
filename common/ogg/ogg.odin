package ogg

import "core:mem"

// Ogg Vorbis from a file in memory: the page layer (this file), the packet
// decoder (vorbis.odin and the rest). Everything is bounds-checked; a file
// that is not valid is an Error, never a crash. `open` makes one allocation
// and nothing after it allocates.

Error :: enum {
	None,
	Bad_Page,
	Bad_Crc,
	Not_Vorbis,
	Bad_Header,
	Bad_Setup,
	Unsupported,
	Over_Limit,
	Bad_Packet,
	Truncated,
	Bad_Seek,
}

Info :: struct {
	rate:     u32,
	channels: u8,
	frames:   u64, // of the whole file, 0 when unknown
	bitrate:  u32,
}

MAX_LINKS :: 64
MAX_INDEX :: 4096

@(private)
Link :: struct {
	first, end: int, // byte range of the link's pages
	rate:       u32,
	bitrate:    u32,
	channels:   int,
	block:      [2]int,
	serial:     u32,
	packets:    int,
	frames:     u64,
	start:      u64, // frames of the links before this one
	ended:      bool, // an end-of-stream page closes it
}

// A page that starts a packet and ends one, so decoding can begin there.
@(private)
Seek_Entry :: struct {
	off:     int,
	link:    int,
	granule: i64,
}

@(private)
Page :: struct {
	off, len: int,
	hdr:      int,
	flags:    u8,
	granule:  i64,
	serial:   u32,
	seq:      u32,
	nseg:     int,
	last_end: int, // the last segment that ends a packet, -1 when none
}

PAGE_CONTINUED :: 1
PAGE_FIRST :: 2
PAGE_LAST :: 4

@(private)
crc_table: [256]u32

@(init, private)
crc_init :: proc "contextless" () {
	for i in 0 ..< 256 {
		r := u32(i) << 24
		for _ in 0 ..< 8 {
			r = (r << 1) ~ 0x04C11DB7 if r & 0x80000000 != 0 else r << 1
		}
		crc_table[i] = r
	}
}

@(private)
get_u32 :: proc "contextless" (b: []byte) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private)
get_i64 :: proc "contextless" (b: []byte) -> i64 {
	return i64(get_u32(b)) | i64(get_u32(b[4:])) << 32
}

@(private)
page_crc :: proc "contextless" (data: []byte) -> u32 {
	c: u32
	for b, i in data {
		x := b
		if i >= 22 && i < 26 {x = 0}
		c = (c << 8) ~ crc_table[u8(c >> 24) ~ x]
	}
	return c
}

// page_parse reads the page at off. The CRC is checked once, when the file is
// opened.
@(private)
page_parse :: proc "contextless" (data: []byte, off: int, crc: bool) -> (p: Page, err: Error) {
	if off < 0 || off > len(data) || len(data) - off < 27 {return {}, .Truncated}
	h := data[off:]
	if string(h[:4]) != "OggS" {return {}, .Bad_Page}
	if h[4] != 0 {return {}, .Bad_Page}
	nseg := int(h[26])
	hdr := 27 + nseg
	if len(h) < hdr {return {}, .Truncated}
	body := 0
	last := -1
	for i in 0 ..< nseg {
		body += int(h[27 + i])
		if h[27 + i] < 255 {last = i}
	}
	if len(h) < hdr + body {return {}, .Truncated}
	p = Page {
		off      = off,
		len      = hdr + body,
		hdr      = hdr,
		flags    = h[5],
		granule  = get_i64(h[6:]),
		serial   = get_u32(h[14:]),
		seq      = get_u32(h[18:]),
		nseg     = nseg,
		last_end = last,
	}
	if crc && page_crc(h[:p.len]) != get_u32(h[22:]) {return {}, .Bad_Crc}
	return p, .None
}

// walk reads every page header of the file (and every CRC), builds the list
// of links and, when index is not empty, the seek index. No packet is decoded.
@(private)
walk :: proc "contextless" (
	data: []byte,
	links: []Link,
	index: []Seek_Entry,
) -> (
	nlinks: int,
	nindex: int,
	err: Error,
) {
	off := 0
	cur: ^Link
	partial := 0 // bytes of a packet continued past the last page
	seq: u32
	stride, count := 1, 0
	for off < len(data) {
		pg, e := page_parse(data, off, true)
		if e == .Truncated {
			if cur == nil {return 0, 0, .Truncated}
			break
		}
		if e != .None {return 0, 0, e}
		body := data[off + pg.hdr:off + pg.len]
		if pg.flags & PAGE_FIRST != 0 {
			if cur != nil && !cur.ended {return 0, 0, .Unsupported}
			if pg.flags & PAGE_CONTINUED != 0 {return 0, 0, .Bad_Page}
			if nlinks >= len(links) {return 0, 0, .Over_Limit}
			if len(body) < 7 || string(body[:7]) != "\x01vorbis" {return 0, 0, .Not_Vorbis}
			id, ie := parse_id(body)
			if ie != .None {return 0, 0, ie}
			links[nlinks] = Link {
				first    = off,
				rate     = id.rate,
				bitrate  = id.bitrate,
				channels = id.channels,
				block    = id.block,
				serial   = pg.serial,
			}
			if nlinks > 0 {
				p := links[nlinks - 1]
				links[nlinks].start = p.start + p.frames
			}
			cur = &links[nlinks]
			nlinks += 1
			partial, seq = 0, pg.seq
		} else {
			if cur == nil {return 0, 0, .Not_Vorbis}
			if cur.ended || pg.serial != cur.serial || pg.seq != seq + 1 {return 0, 0, .Bad_Page}
			if (pg.flags & PAGE_CONTINUED != 0) != (partial > 0) {return 0, 0, .Bad_Page}
			seq = pg.seq
		}
		if pg.granule < -1 {return 0, 0, .Bad_Page}
		at := 27
		for i in 0 ..< pg.nseg {
			l := int(data[off + at + i])
			partial += l
			if l < 255 {
				cur.packets += 1
				partial = 0
			}
			if partial > MAX_PACKET {return 0, 0, .Over_Limit}
		}
		if pg.granule >= 0 {
			cur.frames = u64(pg.granule)
			if len(index) > 0 && pg.flags & (PAGE_CONTINUED | PAGE_FIRST) == 0 && pg.granule > 0 {
				if count % stride == 0 {
					if nindex == len(index) {
						for i in 0 ..< nindex / 2 {index[i] = index[2 * i]}
						nindex /= 2
						stride *= 2
					}
					if count % stride == 0 {
						index[nindex] = {off, nlinks - 1, pg.granule}
						nindex += 1
					}
				}
				count += 1
			}
		}
		if pg.flags & PAGE_LAST != 0 {
			if pg.granule < 0 {return 0, 0, .Bad_Page}
			cur.ended = true
			cur.end = off + pg.len
		}
		off += pg.len
		cur.end = off
	}
	if nlinks == 0 {return 0, 0, .Truncated}
	for i in 0 ..< nlinks {
		l := &links[i]
		if l.packets < 3 {return 0, 0, .Truncated}
		// More frames than the packets could decode is a lie.
		if l.frames > u64(l.packets) * u64(l.block[1] / 2) {return 0, 0, .Bad_Page}
		if i + 1 < nlinks {links[i + 1].start = l.start + l.frames}
	}
	return nlinks, nindex, .None
}

@(private)
total_frames :: proc "contextless" (links: []Link) -> u64 {
	if len(links) == 0 {return 0}
	l := links[len(links) - 1]
	return l.start + l.frames
}

// scan validates a file without decoding it: every page's CRC and structure,
// each link's identification header, the packet and granule bookkeeping. It
// allocates nothing; the setup header is parsed when a link is opened.
scan :: proc "contextless" (data: []byte) -> (info: Info, nlinks: int, err: Error) {
	links: [MAX_LINKS]Link
	n, _, e := walk(data, links[:], nil)
	if e != .None {return {}, 0, e}
	first := links[0]
	return Info {
			rate = first.rate,
			channels = u8(first.channels),
			frames = total_frames(links[:n]),
			bitrate = first.bitrate,
		},
		n,
		.None
}

Decoder :: struct {
	data:      []byte,
	block:     []byte,
	allocator: mem.Allocator,
	arena:     Arena,
	fixed:     int, // arena bytes in use before the first setup
	links:     []Link,
	index:     []Seek_Entry,
	total:     u64,
	pkt:       []byte,
	// The packet cursor
	cur:       int, // link being read
	next_off:  int,
	pg:        Page,
	seg:       int,
	body_at:   int,
	after:     int, // offset of the page the setup ended on
	// Decoding
	s:         Setup,
	have_prev: bool,
	prev_n:    int,
	left:      int, // bits of the last packet the decode did not read (under 8: padding)
	pos:       i64, // frame, in the link, of the next packet's first output
	pos_known: bool,
	target:    i64,
	avail:     int,
	at:        int,
	link_done: bool,
	done:      bool,
	err:       Error, // reported once, after the frames before it
	out_link:  int,
}

open :: proc(data: []byte, allocator := context.allocator) -> (d: ^Decoder, err: Error) {
	block, aerr := mem.alloc_bytes_non_zeroed(MAX_DECODER_BYTES, 16, allocator)
	if aerr != nil {return nil, .Over_Limit}
	a := Arena {
		buf = block,
	}
	ds, _ := arena_make(&a, Decoder, 1)
	d = &ds[0]
	d.block, d.allocator, d.data = block, allocator, data
	links, _ := arena_make(&a, Link, MAX_LINKS)
	idx, _ := arena_make(&a, Seek_Entry, MAX_INDEX)
	n, nidx, e := walk(data, links, idx)
	if e != .None {
		mem.free(raw_data(block), allocator)
		return nil, e
	}
	d.links, d.index = links[:n], idx[:nidx]
	d.total = total_frames(d.links)
	d.pkt, _ = arena_make(&a, byte, MAX_PACKET)
	d.arena = a
	d.fixed = a.used
	d.cur = -1
	if ae := activate(d, 0); ae != .None {
		mem.free(raw_data(block), allocator)
		return nil, ae
	}
	d.out_link = 0
	return d, .None
}

close :: proc(d: ^Decoder) {
	if d == nil {return}
	mem.free(raw_data(d.block), d.allocator)
}

info :: proc "contextless" (d: ^Decoder) -> Info {
	l := &d.links[d.out_link]
	return Info{rate = l.rate, channels = u8(l.channels), frames = d.total, bitrate = l.bitrate}
}

// bytes_used: the decoder's memory in use, of the one block.
bytes_used :: proc "contextless" (d: ^Decoder) -> int {return d.arena.used}

// next_packet reads the next packet of the current link into d.pkt. eol: the
// link has no more packets. granule is the page's when the packet is the last
// to end on it, else -1.
@(private)
next_packet :: proc "contextless" (d: ^Decoder) -> (n: int, granule: i64, eol: bool, err: Error) {
	link := &d.links[d.cur]
	granule = -1
	started := false
	for {
		if d.seg >= d.pg.nseg {
			if d.next_off >= link.end {
				if started {return 0, -1, false, .Truncated}
				return 0, -1, true, .None
			}
			pg, e := page_parse(d.data, d.next_off, false)
			if e != .None {return 0, -1, false, .Bad_Page if e != .Truncated else .Truncated}
			// A continued page needs an open packet, and an open packet a continued page.
			if started != (pg.flags & PAGE_CONTINUED != 0) {return 0, -1, false, .Bad_Page}
			d.pg, d.seg = pg, 0
			d.body_at = pg.off + pg.hdr
			d.next_off = pg.off + pg.len
			continue
		}
		lace := int(d.data[d.pg.off + 27 + d.seg])
		if n + lace > len(d.pkt) {return 0, -1, false, .Over_Limit}
		copy(d.pkt[n:], d.data[d.body_at:d.body_at + lace])
		n += lace
		d.body_at += lace
		started = true
		if lace < 255 {
			if d.seg == d.pg.last_end {granule = d.pg.granule}
			d.seg += 1
			return n, granule, false, .None
		}
		d.seg += 1
	}
}

// activate positions the packet cursor at the first audio of a link and
// parses its headers.
@(private)
activate :: proc "contextless" (d: ^Decoder, li: int) -> Error {
	d.cur = li
	l := &d.links[li]
	d.arena.used = d.fixed
	d.pg = {}
	d.seg = 0
	d.next_off = l.first
	d.have_prev, d.prev_n = false, 0
	d.pos, d.pos_known, d.target = 0, true, 0
	d.avail, d.at = 0, 0
	d.link_done = false
	id: Id_Header
	for k in 0 ..< 3 {
		n, _, eol, e := next_packet(d)
		if e != .None {return e}
		if eol {return .Truncated}
		pkt := d.pkt[:n]
		switch k {
		case 0:
			id, e = parse_id(pkt)
			if e != .None {return e}
			if id.channels != l.channels || id.rate != l.rate {return .Bad_Header}
		case 1:
			if ce := check_comment(pkt); ce != .None {return ce}
		case 2:
			if se := setup_parse(&d.s, &d.arena, id, pkt); se != .None {return se}
		}
	}
	d.after = d.pg.off
	return .None
}

@(private)
audio_start_ok :: proc "contextless" (d: ^Decoder, off: int) -> bool {
	return off > d.after
}

// fill decodes packets until some output is pending or the stream ends.
@(private)
fill :: proc "contextless" (d: ^Decoder, allow_switch: bool) -> Error {
	for d.avail == 0 && !d.done {
		l := &d.links[d.cur]
		if !d.link_done && d.pos_known && d.pos >= i64(l.frames) {d.link_done = true}
		if d.link_done {
			if !allow_switch {return .None}
			if d.cur + 1 >= len(d.links) {
				d.done = true
				if l.ended {return .None}
				return .Truncated
			}
			if e := activate(d, d.cur + 1); e != .None {
				d.done = true
				return e
			}
			continue
		}
		n, granule, eol, e := next_packet(d)
		if e != .None {
			d.done = true
			return e
		}
		if eol {
			d.link_done = true
			continue
		}
		frames: int
		frames, e = decode_packet(d, d.pkt[:n])
		if e != .None {
			d.done = true
			return e
		}
		if !d.pos_known {
			// After a seek: the first page end says where we are.
			if granule >= 0 {
				d.pos, d.pos_known = granule, true
			}
			continue
		}
		at := 0
		if d.pos < d.target {
			at = int(min(i64(frames), d.target - d.pos))
		}
		count := frames
		if d.pos + i64(count) > i64(l.frames) {count = int(max(0, i64(l.frames) - d.pos))}
		d.pos += i64(frames)
		if at < count {
			d.avail, d.at = count - at, at
		}
	}
	return .None
}

// read decodes up to len(out)/channels frames, interleaved. A call never
// crosses into another link; `info` after a read describes the frames it
// returned. 0 frames with .None is the end.
read :: proc "contextless" (
	d: ^Decoder,
	out: []f32,
	max_frames := max(int),
) -> (
	frames: int,
	err: Error,
) {
	if d.err != .None {
		e := d.err
		d.err = .None
		return 0, e
	}
	for {
		if d.avail == 0 {
			e := fill(d, frames == 0)
			if e != .None {
				if frames > 0 {
					d.err = e
					return frames, .None
				}
				return 0, e
			}
			if d.avail == 0 {return frames, .None}
			if frames == 0 {d.out_link = d.cur}
		}
		ch := d.links[d.out_link].channels
		want := min(len(out) / ch, max_frames) - frames
		if want <= 0 {return frames, .None}
		k := min(want, d.avail)
		for c in 0 ..< ch {
			src := d.s.pcm[c][d.at:d.at + k]
			for i in 0 ..< k {out[(frames + i) * ch + c] = src[i]}
		}
		frames += k
		d.at += k
		d.avail -= k
		if frames * ch + ch > len(out) || frames >= max_frames {return frames, .None}
	}
}

// seek positions the next read at a frame counted from the start of the file.
seek :: proc "contextless" (d: ^Decoder, frame: u64) -> Error {
	if frame > d.total {return .Bad_Seek}
	d.done = false
	d.err = .None
	li := 0
	for i in 0 ..< len(d.links) {
		l := &d.links[i]
		if frame >= l.start && (frame < l.start + l.frames || i == len(d.links) - 1) {
			li = i
			break
		}
	}
	if e := activate(d, li); e != .None {return e}
	local := i64(frame - d.links[li].start)
	best := -1
	for e, i in d.index {
		if e.link == li && audio_start_ok(d, e.off) && e.granule <= local {best = i}
	}
	if best >= 0 {
		d.next_off = d.index[best].off
		d.pg, d.seg = {}, 0
		d.pos_known = false
		d.have_prev = false
	}
	d.target = local
	d.out_link = li
	return .None
}
