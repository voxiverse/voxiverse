package music_tool

import "core:math"
import "core:slice"

// MIDI: format 0 and 1 in, format 1 out. The subset is in docs/history.md (M43).

@(private = "file")
Reader :: struct {
	data: []u8,
	at:   int,
}

@(private = "file")
rd_u8 :: proc(r: ^Reader) -> (v: u8, ok: bool) {
	if r.at >= len(r.data) {return}
	v = r.data[r.at]
	r.at += 1
	return v, true
}

@(private = "file")
rd_be :: proc(r: ^Reader, n: int) -> (v: u32, ok: bool) {
	if r.at + n > len(r.data) {return}
	for i in 0 ..< n {v = v << 8 | u32(r.data[r.at + i])}
	r.at += n
	return v, true
}

@(private = "file")
rd_vlq :: proc(r: ^Reader) -> (v: u32, ok: bool) {
	for _ in 0 ..< 4 {
		b := rd_u8(r) or_return
		v = v << 7 | u32(b & 0x7f)
		if b & 0x80 == 0 {return v, true}
	}
	return
}

@(private = "file")
Chan_State :: struct {
	part:  int, // -1 until seen
	pedal: bool,
	open:  [128][dynamic]struct {
		start: u32,
		vel:   u8,
	},
}

// midi_read reads a Standard MIDI File into a Piece. err says why not.
midi_read :: proc(data: []u8) -> (p: Piece, err: string, ok: bool) {
	r := Reader{data, 0}
	bad :: proc(msg: string) -> (Piece, string, bool) {return {}, msg, false}
	if len(data) < 14 || string(data[:4]) != "MThd" {return bad("not a MIDI file")}
	r.at = 4
	hlen, _ := rd_be(&r, 4)
	format, _ := rd_be(&r, 2)
	ntracks, _ := rd_be(&r, 2)
	division, _ := rd_be(&r, 2)
	if hlen < 6 || format > 1 {return bad("only MIDI formats 0 and 1 are read")}
	if division & 0x8000 != 0 {return bad("SMPTE time division is not supported")}
	if division == 0 {return bad("MIDI division is 0")}
	r.at = 8 + int(hlen)
	p = piece_defaults()
	chans: [16]Chan_State
	for &c in chans {c.part = -1}
	scale :: proc(t: u32, division: u32) -> u32 {
		return u32((u64(t) * PPQ + u64(division) / 2) / u64(division))
	}
	part_of :: proc(p: ^Piece, chans: ^[16]Chan_State, ch: int) -> int {
		if chans[ch].part < 0 {
			chans[ch].part = len(p.parts)
			append(&p.parts, Part{})
		}
		return chans[ch].part
	}
	last_end: u32
	for _ in 0 ..< ntracks {
		if r.at + 8 > len(data) ||
		   string(data[r.at:r.at + 4]) != "MTrk" {return bad("a track is missing or truncated")}
		r.at += 4
		tlen, _ := rd_be(&r, 4)
		if r.at + int(tlen) > len(data) {return bad("a track is truncated")}
		tr := Reader{data[:r.at + int(tlen)], r.at}
		r.at += int(tlen)
		tick: u32
		status: u8
		ended := false
		for !ended {
			delta, dok := rd_vlq(&tr)
			if !dok {return bad("a track is truncated")}
			tick += delta
			b, bok := rd_u8(&tr)
			if !bok {return bad("a track is truncated")}
			if b & 0x80 != 0 {
				status = b
			} else {
				if status == 0 {return bad("running status without a status")}
				tr.at -= 1
			}
			t := scale(tick, u32(division))
			if status == 0xff {
				kind, kok := rd_u8(&tr)
				n, nok := rd_vlq(&tr)
				if !kok ||
				   !nok ||
				   tr.at + int(n) > len(tr.data) {return bad("a track is truncated")}
				body := tr.data[tr.at:tr.at + int(n)]
				tr.at += int(n)
				status = 0
				switch kind {
				case 0x2f:
					ended = true
				case 0x51:
					if n == 3 {
						us := u32(body[0]) << 16 | u32(body[1]) << 8 | u32(body[2])
						if us > 0 {append(&p.tempos, Tempo{t, 6e7 / f64(us)})}
					}
				case 0x58:
					if n >= 2 &&
					   body[1] < 6 {append(&p.meters, Meter{t, body[0], u8(1) << body[1]})}
				case 0x59:
					if n == 2 && p.key == "" {
						p.key, p.mode = key_signature(int(i8(body[0])), body[1] == 1)
					}
				}
				continue
			}
			if status == 0xf0 || status == 0xf7 {
				n, nok := rd_vlq(&tr)
				if !nok || tr.at + int(n) > len(tr.data) {return bad("a track is truncated")}
				tr.at += int(n)
				status = 0
				continue
			}
			ch := int(status & 0x0f)
			hi := status & 0xf0
			two := hi != 0xc0 && hi != 0xd0
			d1, ok1 := rd_u8(&tr)
			d2: u8
			ok2 := true
			if two {d2, ok2 = rd_u8(&tr)}
			if !ok1 || !ok2 {return bad("a track is truncated")}
			switch hi {
			case 0x80, 0x90:
				if ch == 9 {return bad("channel 10 (drums) is not supported")}
				pi := part_of(&p, &chans, ch)
				key := d1 & 0x7f
				if hi == 0x90 && d2 > 0 {
					append(&chans[ch].open[key], struct {
						start: u32,
						vel:   u8,
					}{t, d2})
				} else if len(chans[ch].open[key]) > 0 {
					o := chans[ch].open[key][0]
					ordered_remove(&chans[ch].open[key], 0)
					append(&p.notes, Note{o.start, t - o.start, key, o.vel, u8(pi)})
					last_end = max(last_end, t)
				}
			case 0xb0:
				if ch == 9 {continue}
				pi := part_of(&p, &chans, ch)
				switch d1 {
				case 0:
					p.parts[pi].bank = u16(d2)
				case 7:
					p.parts[pi].volume_db = f32(20 * math.log10(max(f64(d2), 1) / 127))
				case 10:
					p.parts[pi].pan = clamp((f32(d2) - 64) / 63, -1, 1)
				case 64:
					down := d2 >= 64
					if down != chans[ch].pedal {
						chans[ch].pedal = down
						append(&p.pedals, Pedal{t, u8(pi), down})
					}
				}
			case 0xc0:
				if ch == 9 {continue}
				pi := part_of(&p, &chans, ch)
				p.parts[pi].program = d1 & 0x7f
			}
		}
	}
	for c in chans {
		for k in 0 ..< 128 {
			if len(c.open[k]) > 0 {return bad("a note is never switched off")}
		}
	}
	if len(p.notes) == 0 {return bad("the file has no notes")}
	piece_finish(&p)
	bar := meter_bar_ticks(p.meters[len(p.meters) - 1])
	start := p.meters[len(p.meters) - 1].at
	p.end = start + max((last_end - min(last_end, start) + bar - 1) / bar, 1) * bar
	for i in 0 ..< len(p.parts) {p.parts[i].name = "part"}
	return p, "", true
}

@(private = "file")
KEY_TONICS_MAJOR := [15]string {
	"cb",
	"gb",
	"db",
	"ab",
	"eb",
	"bb",
	"f",
	"c",
	"g",
	"d",
	"a",
	"e",
	"b",
	"f#",
	"c#",
}
@(private = "file")
KEY_TONICS_MINOR := [15]string {
	"ab",
	"eb",
	"bb",
	"f",
	"c",
	"g",
	"d",
	"a",
	"e",
	"b",
	"f#",
	"c#",
	"g#",
	"d#",
	"a#",
}

@(private = "file")
key_signature :: proc(sharps: int, minor: bool) -> (key, mode: string) {
	i := sharps + 7
	if i < 0 || i > 14 {return "", ""}
	if minor {return KEY_TONICS_MINOR[i], "minor"}
	return KEY_TONICS_MAJOR[i], "major"
}

@(private = "file")
Event :: struct {
	at:    u32,
	order: u8, // at one tick: note offs, then the rest, then note ons
	bytes: [3]u8,
	n:     u8,
}

@(private = "file")
put_be :: proc(out: ^[dynamic]u8, v: u32, n: int) {
	for i in 0 ..< n {append(out, u8(v >> u32(8 * (n - 1 - i))))}
}

@(private = "file")
put_vlq :: proc(out: ^[dynamic]u8, v: u32) {
	buf: [5]u8
	n := 0
	x := v
	buf[0] = u8(x & 0x7f)
	n = 1
	x >>= 7
	for x > 0 {
		buf[n] = u8(x & 0x7f) | 0x80
		n += 1
		x >>= 7
	}
	for i := n - 1; i >= 0; i -= 1 {append(out, buf[i])}
}

@(private = "file")
track :: proc(out: ^[dynamic]u8, body: []u8) {
	append(out, "MTrk")
	put_be(out, u32(len(body)), 4)
	append(out, ..body)
}

// midi_write writes the piece as a format 1 file, PPQ per quarter: track 0
// the tempo, meter and key map, then a track per part.
midi_write :: proc(p: ^Piece) -> []u8 {
	out: [dynamic]u8
	append(&out, "MThd")
	put_be(&out, 6, 4)
	put_be(&out, 1, 2)
	put_be(&out, u32(1 + len(p.parts)), 2)
	put_be(&out, PPQ, 2)

	{
		evs: [dynamic]Event
		for t in p.tempos {
			us := u32(math.round(6e7 / t.bpm))
			append(&evs, Event{t.at, 1, {u8(us >> 16), u8(us >> 8), u8(us)}, 0xf1})
		}
		for m in p.meters {
			power: u8
			for d := m.den; d > 1; d >>= 1 {power += 1}
			append(&evs, Event{m.at, 1, {m.num, power, 0}, 0xf2})
		}
		slice.stable_sort_by(evs[:], proc(a, b: Event) -> bool {return a.at < b.at})
		body: [dynamic]u8
		if p.title != "" {
			append(&body, 0, 0xff, 0x03, u8(len(p.title)))
			append(&body, p.title)
		}
		last: u32
		for e in evs {
			put_vlq(&body, e.at - last)
			last = e.at
			if e.n == 0xf1 {
				append(&body, 0xff, 0x51, 3, e.bytes[0], e.bytes[1], e.bytes[2])
			} else {
				append(&body, 0xff, 0x58, 4, e.bytes[0], e.bytes[1], 24, 8)
			}
		}
		append(&body, 0, 0xff, 0x2f, 0)
		track(&out, body[:])
	}
	for part, pi in p.parts {
		ch := u8(pi) if pi < 9 else u8(pi + 1) // skip channel 10
		evs: [dynamic]Event
		vol := u8(clamp(math.round(127 * math.pow(10, f64(part.volume_db) / 20)), 0, 127))
		pan := u8(clamp(math.round(f64(part.pan) * 63 + 64), 0, 127))
		append(&evs, Event{0, 0, {0xb0 | ch, 0, u8(part.bank & 0x7f)}, 3})
		append(&evs, Event{0, 0, {0xc0 | ch, part.program, 0}, 2})
		append(&evs, Event{0, 0, {0xb0 | ch, 7, vol}, 3})
		append(&evs, Event{0, 0, {0xb0 | ch, 10, pan}, 3})
		for n in p.notes {
			if int(n.part) != pi {continue}
			append(&evs, Event{n.start, 2, {0x90 | ch, n.key, n.velocity}, 3})
			append(&evs, Event{n.start + n.length, 0, {0x80 | ch, n.key, 0}, 3})
		}
		for e in p.pedals {
			if int(e.part) != pi {continue}
			append(&evs, Event{e.at, 1, {0xb0 | ch, 64, 127 if e.down else 0}, 3})
		}
		slice.stable_sort_by(evs[:], proc(a, b: Event) -> bool {
			if a.at != b.at {return a.at < b.at}
			return a.order < b.order
		})
		body: [dynamic]u8
		append(&body, 0, 0xff, 0x03, u8(len(part.name)))
		append(&body, part.name)
		last: u32
		for e in evs {
			put_vlq(&body, e.at - last)
			last = e.at
			bytes := e.bytes
			append(&body, ..bytes[:e.n])
		}
		append(&body, 0, 0xff, 0x2f, 0)
		track(&out, body[:])
	}
	return out[:]
}
