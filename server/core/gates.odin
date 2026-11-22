package core

import "core:fmt"
import "core:log"
import "core:math"

import "common:game"
import "common:protocol"
import "common:starmap"
import "common:worldgen"

// Gates (common/worldgen/gates.odin has their shape and places): a player dials
// one (Dial: seven symbols, a world of this galaxy); its chevrons lock one
// by one, and the far world's arrival gate (the nearest its middle) with
// it; both open for a while; walking into the dialing gate's horizon
// travels to the far gate's front. Each gate's blocks follow its state
// every tick wherever they are loaded (the far gate catches up when its
// world's chunks arrive), and go back when it closes.
//
// A gate may be dead instead: its chevrons dark, it cannot be dialled and
// nobody arrives through it, until gate_wake (the game's, whatever wakes
// it; the `gate wake` command for admins). A new world's home gate starts
// dead (gates_begin). Dead gates are saved with their world (world.cfg:
// `gate.dead`); a world saved before them has none, so its gates live.

GATE_LOCK_TICKS :: game.TICK_RATE * 2 / 5 // a chevron locks every 0.4 s
GATE_OPEN_TICKS :: game.TICK_RATE * 30 // then the gate stays open 30 s
GATE_REACH :: 8 // blocks: how far from a gate one may dial it
GATE_LOOK_PITCH :: -1.0 // radians: from gate_front, at the ring's foot

Gate_Phase :: enum u8 {
	Dialing,
	Open,
	Dead, // dark until woken (gate_wake): never dialled, never arrived at
}

Gate :: struct {
	structure: worldgen.Structure,
	phase:     Gate_Phase, // (Dead: the rest is zero)
	locked:    int, // chevrons lit
	next_at:   u64, // tick of the next lock, or of closing
	outgoing:  bool, // dialed here (travelling in goes to `to`); else the far end
	to:        starmap.Address, // the far end's world
	far:       worldgen.Structure, // the far end's gate (outgoing only)
}

// gate_find: the gate of w that s is (dialing, open or dead), if any.
@(private = "file")
gate_find :: proc(w: ^World, s: worldgen.Structure) -> ^Gate {
	for &g in w.gates {if g.structure.lo == s.lo {return &g}}
	return nil
}

// gate_dial: c dials the gate a block of which is at pos; "" or why not.
gate_dial :: proc(s: ^Server, c: ^Client, d: protocol.Dial) -> string {
	w := c.world
	gs, is_gate := worldgen.gate_containing(&w.chunks.gen, d.gate)
	if !is_gate {return "that is not a gate"}
	here := gate_find(w, gs)
	if here != nil && here.phase == .Dead {return "the gate is dark"}
	if !starmap.address_valid(d.address) {return "that is not an address"}
	centre := worldgen.gate_at(gs, 5, 5)
	dx := c.player.position - {f64(centre.x), f64(centre.y), f64(centre.z)}
	if dx.x * dx.x + dx.y * dx.y + dx.z * dx.z >
	   GATE_REACH * GATE_REACH {return "the gate is too far"}
	if here != nil {return "the gate is busy"}
	if d.address.galaxy != w.address.galaxy {return "this gate reaches only its own galaxy"}
	if d.address == w.address {return "a gate cannot dial its own world"}
	to := world_load(s, d.address)
	if to == nil {return "nothing answers at that address"}
	far, has_far := worldgen.arrival_gate(&to.chunks.gen)
	if !has_far {return "nothing answers at that address"}
	if there := gate_find(to, far); there != nil {
		if there.phase == .Dead {return "nothing answers at that address"}
		return "the gate there is busy"
	}
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
		starmap.address_dir(w.address),
		starmap.address_dir(d.address),
	)
	record(s, c, .Gate_Dial, "opened")
	return ""
}

@(private = "file")
gate_open_ticks :: proc(s: ^Server) -> u64 {
	return u64(s.config.gate_open * game.TICK_RATE) if s.config.gate_open > 0 else GATE_OPEN_TICKS
}

// gates_tick moves w's gates on (locking, opening, closing), sets their
// blocks, and sends whoever walks into an open outgoing gate through. A
// dead gate stays as it is.
gates_tick :: proc(w: ^World) {
	s := w.server
	for i := len(w.gates) - 1; i >= 0; i -= 1 {
		g := &w.gates[i]
		if g.phase == .Dead {continue}
		if s.tick >= g.next_at {
			switch g.phase {
			case .Dialing:
				g.locked += 1
				g.next_at = s.tick + GATE_LOCK_TICKS
				if g.locked == starmap.WORLD_LENGTH {
					g.phase = .Open
					g.next_at = s.tick + gate_open_ticks(s)
				}
			case .Open:
				gate_blocks(w, g, closed = true)
				unordered_remove(&w.gates, i)
				continue
			case .Dead:
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

// gates_active: w has a gate dialing or open (it stays loaded meanwhile).
gates_active :: proc(w: ^World) -> bool {
	for g in w.gates {if g.phase != .Dead {return true}}
	return false
}

// gate_wake brings the dead gate a block of which is at p (its ring, a
// chevron, its platform) to life: from now on it is dialled and arrived at
// as any gate. False if no gate is there or it is not dead.
gate_wake :: proc(w: ^World, p: game.Block_Pos) -> bool {
	gs, is_gate := worldgen.gate_containing(&w.chunks.gen, p)
	if !is_gate {return false}
	for g, i in w.gates {
		if g.structure.lo == gs.lo && g.phase == .Dead {
			ordered_remove(&w.gates, i)
			log.infof("server gate woken at=%v world=%s", gs.lo, starmap.address_dir(w.address))
			return true
		}
	}
	return false
}

// gate_kill makes the gate a block of which is at p dead (gate_wake's
// reverse). False if no gate is there, or it is dead, dialing or open.
gate_kill :: proc(w: ^World, p: game.Block_Pos) -> bool {
	gs, is_gate := worldgen.gate_containing(&w.chunks.gen, p)
	if !is_gate || gate_find(w, gs) != nil {return false}
	append(&w.gates, Gate{structure = gs, phase = .Dead})
	log.infof("server gate killed at=%v world=%s", gs.lo, starmap.address_dir(w.address))
	return true
}

// gates_begin: a new world's home gate (worldgen.Params.home_gate) stands
// dead. (Run once, when the world is made; a saved world keeps its own.)
@(private)
gates_begin :: proc(w: ^World) {
	if home, has_home := w.chunks.gen.home.?; has_home {gate_kill(w, home.lo)}
}

// admin_gate: `gate wake|kill`: the gate nearest the player (within
// GATE_ADMIN_REACH) comes to life, or dies.
@(private)
admin_gate :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	if args[0] != "wake" && args[0] != "kill" {return false}
	w := c.world
	p := c.player.position
	gs, found := worldgen.locate_structure(
		&w.chunks.gen,
		.Gate,
		i32(math.floor(p.x)),
		i32(math.floor(p.z)),
		GATE_ADMIN_REACH,
	)
	if !found {
		notice(s, c, fmt.tprintf("No gate within %d blocks", GATE_ADMIN_REACH))
		return true
	}
	done := gate_wake(w, gs.lo) if args[0] == "wake" else gate_kill(w, gs.lo)
	switch {
	case done && args[0] == "wake":
		notice(s, c, fmt.tprintf("The gate at %d %d %d is alive", gs.lo.x, gs.lo.y, gs.lo.z))
	case done:
		notice(s, c, fmt.tprintf("The gate at %d %d %d is dead", gs.lo.x, gs.lo.y, gs.lo.z))
	case args[0] == "wake":
		notice(s, c, fmt.tprintf("The gate at %d %d %d is not dead", gs.lo.x, gs.lo.y, gs.lo.z))
	case:
		notice(
			s,
			c,
			fmt.tprintf("The gate at %d %d %d is dead or in use", gs.lo.x, gs.lo.y, gs.lo.z),
		)
	}
	return true
}

// GATE_ADMIN_REACH: blocks: how far `gate wake|kill` looks for a gate.
GATE_ADMIN_REACH :: 256

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
