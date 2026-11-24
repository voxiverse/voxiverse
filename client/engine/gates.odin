package engine

import "client:font"
import "common:game"
import "common:protocol"
import "common:starmap"

// Gates on the client: the address being written on one (its overlay is
// overlay/gate.odin), what the server says of the world at an address, the
// addresses' symbols drawn for the UI, and a gate's void gathering as it opens.

// Gate_Entry: the address being written on a gate (overlay/gate.odin).
Gate_Entry :: struct {
	gate:    game.Block_Pos, // the block of the gate used
	symbols: [starmap.WORLD_LENGTH]u8,
	count:   int,
	last:    int, // the symbol pressed last: where a pad's focus goes on
}

// DESTINATIONS_KEPT: the server's answers a session keeps (the latest).
DESTINATIONS_KEPT :: 16

// Destinations: what the server said of the worlds at the addresses the gate's screen asked
// about (protocol.Destination), the latest last, and the address asked of last.
Destinations :: struct {
	known: [DESTINATIONS_KEPT]protocol.Destination,
	count: int,
	asked: Maybe(starmap.Address),
}

// destination_of: what the server said of the world at a; false while it has not (asked
// for once: destination_take keeps the answer).
destination_of :: proc(s: ^Session, a: starmap.Address) -> (protocol.Destination, bool) {
	d := &s.destinations
	for k in d.known[:d.count] {if k.address == a {return k, true}}
	if asked, has := d.asked.?; !has || asked != a {
		d.asked = a
		send_message(s, protocol.Destination_Ask{a})
	}
	return {}, false
}

// destination_take keeps an answer of the server's (the oldest forgotten past
// DESTINATIONS_KEPT).
destination_take :: proc(s: ^Session, v: protocol.Destination) {
	d := &s.destinations
	for &k in d.known[:d.count] {
		if k.address == v.address {
			k = v
			return
		}
	}
	if d.count == DESTINATIONS_KEPT {
		copy(d.known[:], d.known[1:])
		d.count -= 1
	}
	d.known[d.count] = v
	d.count += 1
}

// symbol_glyph: a gate address's symbol, drawn for the UI from its strokes
// (starmap.symbol_strokes): the UI's ui.Drawn_Glyphs.
symbol_glyph :: proc(r: rune) -> (glyph: font.Drawn, ok: bool) {
	symbol := starmap.symbol_of_rune(r) or_return
	strokes := make([dynamic][2][2]f32, context.temp_allocator)
	starmap.symbol_strokes(symbol, &strokes)
	return {strokes[:], starmap.SYMBOL_WEIGHT, starmap.SYMBOL_ADVANCE}, true
}

// A gate opening in sight: when the void appears in a gate's opening (the
// server sets Gate_Horizon there; not a chunk arriving with the gate already
// open), it gathers from the middle of the opening over GATE_GATHER_SECONDS,
// the rim brightening with it, and the gate sounds once. The scene carries
// the nearest gathering gate to the portal shader (gate_gather_scene).

GATE_GATHER_SECONDS :: 1.0
GATE_GATHER_NEAR :: 8 // blocks: void appearing this near a gathering one is the same gate's
GATE_OPENING_CELLS :: 32 // at most this many cells of void make one opening

Gate_Gather :: struct {
	cell: game.Block_Pos, // the first cell of its void seen
	at:   f64, // Session.frame_seconds then
	set:  bool,
}

// gate_void_appeared: the void has just appeared at p, where there was none.
gate_void_appeared :: proc(s: ^Session, p: game.Block_Pos) {
	slot := 0 // a free one, else the one begun longest ago
	for g, i in s.gate_gathers {
		if g.set && s.frame_seconds - g.at < GATE_GATHER_SECONDS {
			d := g.cell - p
			if max(abs(d.x), abs(d.y), abs(d.z)) <= GATE_GATHER_NEAR {return}
		}
		if !g.set || (s.gate_gathers[slot].set && g.at < s.gate_gathers[slot].at) {slot = i}
	}
	s.gate_gathers[slot] = {p, s.frame_seconds, true}
	centre := [3]f64{f64(p.x), f64(p.y), f64(p.z)} + 0.5
	append(&s.sounds, Sound_Event{kind = .Gate_Open, position = centre, volume = 1})
}

// gate_opening_middle: the middle of the void connected to cell (the
// opening's box), in blocks; false if none is there any more.
gate_opening_middle :: proc(s: ^Session, cell: game.Block_Pos) -> ([3]f64, bool) {
	cells: [GATE_OPENING_CELLS]game.Block_Pos
	n := 0
	if b, known := world_block(&s.world, cell); !known || b != .Gate_Horizon {return {}, false}
	cells[0], n = cell, 1
	lo, hi := cell, cell
	for i := 0; i < n; i += 1 {
		for d in game.FACE_AXES {
			q := cells[i] + d.normal
			if n == GATE_OPENING_CELLS {break}
			b, known := world_block(&s.world, q)
			if !known || b != .Gate_Horizon {continue}
			seen := false
			for c in cells[:n] {if c == q {seen = true}}
			if seen {continue}
			cells[n] = q
			n += 1
			lo = {min(lo.x, q.x), min(lo.y, q.y), min(lo.z, q.z)}
			hi = {max(hi.x, q.x), max(hi.y, q.y), max(hi.z, q.z)}
		}
	}
	return {f64(lo.x + hi.x + 1), f64(lo.y + hi.y + 1), f64(lo.z + hi.z + 1)} / 2, true
}

// gate_gather_scene: the scene's gate (render.Scene.gate): the middle of
// the nearest gathering gate's opening from the camera chunk's origin, and
// the seconds since it began; w < 0 with none.
gate_gather_scene :: proc(s: ^Session, camera_chunk: [3]i32, eye: [3]f64) -> [4]f32 {
	best := [4]f32{0, 0, 0, -1}
	nearest := max(f64)
	for g in s.gate_gathers {
		age := s.frame_seconds - g.at
		if !g.set || age >= GATE_GATHER_SECONDS {continue}
		middle, open := gate_opening_middle(s, g.cell)
		if !open {continue}
		d := middle - eye
		if far := d.x * d.x + d.y * d.y + d.z * d.z; far < nearest {
			nearest = far
			origin :=
				[3]f64{f64(camera_chunk.x), f64(camera_chunk.y), f64(camera_chunk.z)} *
				game.CHUNK_SIZE
			m := middle - origin
			best = {f32(m.x), f32(m.y), f32(m.z), f32(age)}
		}
	}
	return best
}
