package core

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"

import "common:base"
import "common:game"
import "common:protocol"
import "common:starmap"
import "common:worldgen"
import "server:store"

// Gates (common/worldgen/gates.odin has their shape and places): a player
// writes an address on one (Open_Gate: a world of this galaxy), and it
// opens at once, with the far world's arrival gate: both stay open for a
// while, and walking into the opening of the gate opened here travels to
// the far gate's front. An open gate's opening is filled with the void
// (Gate_Horizon blocks; the client draws it gathering as it appears). Each
// gate's opening follows its state every tick wherever its blocks are
// loaded (the far gate catches up when its world's chunks arrive), and
// empties when it closes.
//
// A gate may be dead instead: its opening empty, it cannot be opened and
// nobody arrives through it, until gate_wake (the game's, whatever wakes
// it; the `gate wake` command for admins). A new world's home gate starts
// dead (gates_begin). Dead gates are saved with their world (world.cfg:
// `gate.dead`); a world saved before them has none, so its gates live.

GATE_OPEN_TICKS :: game.TICK_RATE * 30 // a gate stays open 30 s
GATE_REACH :: 8 // blocks: how far from a gate one may open it
GATE_LOOK_PITCH :: -1.0 // radians: from gate_front, at the opening's foot

Gate_Phase :: enum u8 {
	Open,
	Dead, // dark until woken (gate_wake): never opened, never arrived at
}

Gate :: struct {
	structure: worldgen.Structure,
	phase:     Gate_Phase, // (Dead: the rest is zero)
	close_at:  u64, // tick it closes
	outgoing:  bool, // opened here (travelling in goes to `to`); else the far end
	to:        starmap.Address, // the far end's world
	far:       worldgen.Structure, // the far end's gate (outgoing only)
}

// gate_find: the gate of w that s is (open or dead), if any.
@(private = "file")
gate_find :: proc(w: ^World, s: worldgen.Structure) -> ^Gate {
	for &g in w.gates {if g.structure.lo == s.lo {return &g}}
	return nil
}

// gate_open: c opens the gate a block of which is at pos onto an address;
// "" or why not.
gate_open :: proc(s: ^Server, c: ^Client, d: protocol.Open_Gate) -> string {
	w := c.world
	gs, is_gate := worldgen.gate_containing(&w.chunks.gen, d.gate)
	if !is_gate {return "that is not a gate"}
	here := gate_find(w, gs)
	if !starmap.address_valid(d.address) {return "that is not an address"}
	centre := worldgen.gate_at(gs, 5, 5)
	dx := c.player.position - {f64(centre.x), f64(centre.y), f64(centre.z)}
	if dx.x * dx.x + dx.y * dx.y + dx.z * dx.z >
	   GATE_REACH * GATE_REACH {return "the gate is too far"}
	quest_note(s, c, {goal = .Address, count = 1}) // (an address written on it, whatever answers)
	if here != nil && here.phase == .Dead {return "the gate is dark"}
	if here != nil {return "the gate is busy"}
	if d.address.galaxy != w.address.galaxy {return "this gate reaches only its own galaxy"}
	if d.address == w.address {return "a gate cannot open onto its own world"}
	to := world_load(s, d.address)
	if to == nil {return "nothing answers at that address"}
	far, has_far := worldgen.arrival_gate(&to.chunks.gen)
	if !has_far {return "nothing answers at that address"}
	if there := gate_find(to, far); there != nil {
		if there.phase == .Dead {return "nothing answers at that address"}
		return "the gate there is busy"
	}
	close := s.tick + gate_open_ticks(s)
	append(
		&w.gates,
		Gate{structure = gs, outgoing = true, to = d.address, far = far, close_at = close},
	)
	append(&to.gates, Gate{structure = far, to = w.address, close_at = close})
	to.idle_since = close // (kept loaded while it may be travelled to)
	log.infof(
		"server gate opened by=%s from=%s to=%s",
		client_name(c),
		starmap.address_dir(w.address),
		starmap.address_dir(d.address),
	)
	record(s, c, .Gate_Dial, "opened")
	logbook_place(s, c, .Gate, {centre.x, centre.y, centre.z})
	return ""
}

// destination_answer: what the world at an address is, for the gate's address screen
// (a Destination_Ask): the home world as it was made, a world loaded or saved as it was
// made (its world.cfg), and one never made as it would be (world_kind, the game's claim
// too). An address that is none is not answered.
@(private)
destination_answer :: proc(s: ^Server, c: ^Client, d: protocol.Destination_Ask) {
	if !starmap.address_valid(d.address) {return}
	generator, params := destination_kind(s, d.address)
	send_message(
		s,
		c,
		protocol.Destination {
			address = d.address,
			home = d.address == s.home.address,
			generator = u8(generator),
			class = u8(worldgen.world_class_of(&params)),
		},
	)
}

// destination_kind: the generator and parameters the world at address a is made by.
@(private)
destination_kind :: proc(s: ^Server, a: starmap.Address) -> (worldgen.Kind, worldgen.Params) {
	if w := world_find(s, a); w != nil {return w.generator, w.params}
	if s.store.dir != "" {
		path, _ := filepath.join(
			{s.store.dir, store.WORLDS_DIR, starmap.address_dir(a), store.WORLD_FILE},
			context.temp_allocator,
		)
		if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
			// A world saved: its generator, and its class (none in one from before classes).
			generator := worldgen.Kind.Classic // (one from before generators were named)
			params := worldgen.PARAMS_DEFAULTS
			params.class = 0
			for l in base.config_lines(string(data)) {
				switch l.key {
				case "generator":
					if k, known := worldgen.kind_by_name(l.value); known {generator = k}
				case "worldgen.class":
					if v, ok := strconv.parse_f32(l.value); ok {params.class = v}
				}
			}
			return generator, params
		}
	}
	w := new(World, context.temp_allocator) // (a world's kind alone: nothing of it is opened)
	w.server, w.address = s, a
	world_kind(w)
	return w.generator, w.params
}

@(private = "file")
gate_open_ticks :: proc(s: ^Server) -> u64 {
	return u64(s.config.gate_open * game.TICK_RATE) if s.config.gate_open > 0 else GATE_OPEN_TICKS
}

// gates_tick closes w's gates whose time is up, sets their blocks, and
// sends whoever walks into an open outgoing gate through. A dead gate stays
// as it is.
gates_tick :: proc(w: ^World) {
	s := w.server
	for i := len(w.gates) - 1; i >= 0; i -= 1 {
		g := &w.gates[i]
		if g.phase == .Dead {continue}
		if s.tick >= g.close_at {
			gate_blocks(w, g, closed = true)
			unordered_remove(&w.gates, i)
			continue
		}
		gate_blocks(w, g)
		if !g.outgoing {continue}
		for &c in s.clients {
			if c.state != .Playing || c.world != w || !in_opening(g, c.player.position) {continue}
			front, yaw := worldgen.gate_front(g.far)
			why := travel(s, &c, g.to, Place{g.to, front, {yaw, 0}})
			notice_if(s, &c, why)
			record(s, &c, .Teleport, "gate")
			if why == "" { 	// (the gate arrived at, in its world's place of the logbook)
				centre := worldgen.gate_at(g.far, 5, 5)
				logbook_place(s, &c, .Gate, {centre.x, centre.y, centre.z})
			}
		}
	}
}

// gates_active: w has a gate open (it stays loaded meanwhile).
gates_active :: proc(w: ^World) -> bool {
	for g in w.gates {if g.phase != .Dead {return true}}
	return false
}

// gate_wake brings the dead gate a block of which is at p (its frame, its
// platform) to life: from now on it is opened and arrived at as any gate. False if no gate is there or it is not dead.
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
// reverse). False if no gate is there, or it is dead or open.
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

// gate_blocks fills g's opening with the void (Gate_Horizon) or empties it
// (closed), where loaded: no other cell of its plane is the void (nor one a
// gate of the older, wider shape left in a world saved open).
@(private = "file")
gate_blocks :: proc(w: ^World, g: ^Gate, closed := false) {
	open := !closed && g.phase == .Open
	for v in i32(1) ..< worldgen.GATE_SIZE.y {
		for u in i32(0) ..< worldgen.GATE_SIZE.x {
			p := worldgen.gate_at(g.structure, u, v)
			current, loaded := chunks_block(&w.chunks, p)
			if !loaded {continue}
			void := open && worldgen.gate_cell(u, v) == .Inside
			if void &&
			   current != .Gate_Horizon {set_block(w, p, .Gate_Horizon, world_act(w, .Gate))}
			if !void && current == .Gate_Horizon {set_block(w, p, .Air, world_act(w, .Gate))}
		}
	}
}

// in_opening: a player at feet stands in g's opening (its plane, inside).
@(private = "file")
in_opening :: proc(g: ^Gate, feet: [3]f64) -> bool {
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
