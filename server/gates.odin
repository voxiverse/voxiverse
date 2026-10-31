package server

import "core:log"
import "core:math"

import "common:game"
import "common:worldgen"

// Gates (common/worldgen/gates.odin has their shape and places): a player dials
// one (Dial: seven symbols, a world of this galaxy); its chevrons lock one
// by one, and the far world's arrival gate (the nearest its middle) with
// it; both open for a while; walking into the dialing gate's horizon
// travels to the far gate's front. Each gate's blocks follow its state
// every tick wherever they are loaded (the far gate catches up when its
// world's chunks arrive), and go back when it closes.

GATE_LOCK_TICKS :: game.TICK_RATE * 2 / 5 // a chevron locks every 0.4 s
GATE_OPEN_TICKS :: game.TICK_RATE * 30 // then the gate stays open 30 s
GATE_REACH :: 8 // blocks: how far from a gate one may dial it
GATE_LOOK_PITCH :: -1.0 // radians: from gate_front, at the ring's foot

Gate_Phase :: enum u8 {
	Dialing,
	Open,
}

Gate :: struct {
	structure: worldgen.Structure,
	phase:     Gate_Phase,
	locked:    int, // chevrons lit
	next_at:   u64, // tick of the next lock, or of closing
	outgoing:  bool, // dialed here (travelling in goes to `to`); else the far end
	to:        game.Address, // the far end's world
	far:       worldgen.Structure, // the far end's gate (outgoing only)
}

// gate_find: the active gate of w that s is, if any.
@(private = "file")
gate_find :: proc(w: ^World, s: worldgen.Structure) -> ^Gate {
	for &g in w.gates {if g.structure.lo == s.lo {return &g}}
	return nil
}

// gate_dial: c dials the gate a block of which is at pos; "" or why not.
gate_dial :: proc(s: ^Server, c: ^Client, d: game.Dial) -> string {
	w := c.world
	gs, is_gate := worldgen.gate_containing(&w.chunks.gen, d.gate)
	if !is_gate {return "that is not a gate"}
	if !game.address_valid(d.address) {return "that is not an address"}
	centre := worldgen.gate_at(gs, 5, 5)
	dx := c.player.position - {f64(centre.x), f64(centre.y), f64(centre.z)}
	if dx.x * dx.x + dx.y * dx.y + dx.z * dx.z >
	   GATE_REACH * GATE_REACH {return "the gate is too far"}
	if gate_find(w, gs) != nil {return "the gate is busy"}
	if d.address.galaxy != w.address.galaxy {return "this gate reaches only its own galaxy"}
	if d.address == w.address {return "a gate cannot dial its own world"}
	to := world_load(s, d.address)
	if to == nil {return "nothing answers at that address"}
	far, has_far := worldgen.arrival_gate(&to.chunks.gen)
	if !has_far {return "nothing answers at that address"}
	if gate_find(to, far) != nil {return "the gate there is busy"}
	next := s.tick + GATE_LOCK_TICKS
	append(
		&w.gates,
		Gate{structure = gs, outgoing = true, to = d.address, far = far, next_at = next},
	)
	append(&to.gates, Gate{structure = far, to = w.address, next_at = next})
	to.idle_since = s.tick + gate_open_ticks(s) // (kept loaded while it may be travelled to)
	log.infof(
		"server gate dialed by=%s from=%s to=%s",
		client_name(c),
		game.address_dir(w.address),
		game.address_dir(d.address),
	)
	record(s, c, .Gate_Dial, "opened")
	return ""
}

@(private = "file")
gate_open_ticks :: proc(s: ^Server) -> u64 {
	return u64(s.config.gate_open * game.TICK_RATE) if s.config.gate_open > 0 else GATE_OPEN_TICKS
}

// gates_tick moves w's gates on (locking, opening, closing), sets their
// blocks, and sends whoever walks into an open outgoing gate through.
gates_tick :: proc(w: ^World) {
	s := w.server
	for i := len(w.gates) - 1; i >= 0; i -= 1 {
		g := &w.gates[i]
		if s.tick >= g.next_at {
			switch g.phase {
			case .Dialing:
				g.locked += 1
				g.next_at = s.tick + GATE_LOCK_TICKS
				if g.locked == game.WORLD_LENGTH {
					g.phase = .Open
					g.next_at = s.tick + gate_open_ticks(s)
				}
			case .Open:
				gate_blocks(w, g, closed = true)
				unordered_remove(&w.gates, i)
				continue
			}
		}
		gate_blocks(w, g)
		if g.phase != .Open || !g.outgoing {continue}
		for &c in s.clients {
			if c.state != .Playing || c.world != w || !in_horizon(g, c.player.position) {continue}
			front, yaw := worldgen.gate_front(g.far)
			notice_if(s, &c, travel(s, &c, g.to, Place{g.to, front, {yaw, 0}}))
			record(s, &c, .Teleport, "gate")
		}
	}
}

// gate_blocks sets g's blocks to its state (or back, closed) where loaded.
@(private = "file")
gate_blocks :: proc(w: ^World, g: ^Gate, closed := false) {
	for p, k in worldgen.gate_chevrons(g.structure) {
		want: game.Block = .Gate_Chevron_Lit if !closed && k < g.locked else .Gate_Chevron
		set_if(w, p, want)
	}
	inside := make([dynamic]game.Block_Pos, context.temp_allocator)
	worldgen.gate_inside(g.structure, &inside)
	open := !closed && g.phase == .Open
	for p in inside {
		current, loaded := chunks_block(&w.chunks, p)
		if !loaded {continue}
		if open && current != .Gate_Horizon {set_block(w, p, .Gate_Horizon, world_act(w, .Gate))}
		if !open && current == .Gate_Horizon {set_block(w, p, .Air, world_act(w, .Gate))}
	}
}

@(private = "file")
set_if :: proc(w: ^World, p: game.Block_Pos, b: game.Block) {
	if current, loaded := chunks_block(&w.chunks, p);
	   loaded && current != b {set_block(w, p, b, world_act(w, .Gate))}
}

// in_horizon: a player at feet stands in g's ring (its plane, inside).
@(private = "file")
in_horizon :: proc(g: ^Gate, feet: [3]f64) -> bool {
	inside := make([dynamic]game.Block_Pos, context.temp_allocator)
	worldgen.gate_inside(g.structure, &inside)
	for dy in ([]f64{0.2, 1.2}) {
		p := game.Block_Pos {
			i32(math.floor(feet.x)),
			i32(math.floor(feet.y + dy)),
			i32(math.floor(feet.z)),
		}
		for q in inside {if q == p {return true}}
	}
	return false
}
