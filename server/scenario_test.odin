package server

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"

import "../common/game"
import "../common/netcode"

// T3: scenarios with invariants. A scenario is data: steps (a tick, a player, an
// operation) played on the harness (harness.odin) by one runner. Player 0 is the
// mirror (determinism_test.odin): it predicts, so it is the one that can desync,
// and it walks, jumps and flies; players 1.. are bots on the simulated network
// (net_test.odin), told what the server says. After every scenario the runner
// checks, whatever the scenario did:
//
//   - no desync: the server judged the mirror's Prediction_Checks and found none
//     different, and the mirror's prediction ends where the server says it is;
//   - item conservation: `audit` (the M31 ledger) is balanced every second;
//   - agreement: every chunk a player holds is the server's, block for block, and
//     what each bot was told of its own position and health is the server's;
//   - replay: the scenario is played twice and the state hash of every tick is the
//     same, as is the number of datagrams the network delivered;
//   - no error lines and no leaks: the test runner fails a test that logs at error
//     (nothing here silences it); the runner counts leaks and bad frees itself with a
//     tracking allocator around each run, since the test runner only warns of them.
//
// A scenario may add a check of its own (`done`) for what it was about.

SC_BOTS :: 3
SC_SETTLE :: 180 // ticks of everyone standing still at the end, for what is in flight to land

Op :: enum {
	Join, // a bot connects (player 1..)
	Leave, // a bot disconnects
	Walk, // v = {right, forward, yaw}
	Stand,
	Jump, // the mirror only
	Fly, // the mirror only: toggle
	Place, // `block` at the feet block + off
	Break,
	Use, // the block at the feet block + off (a chest opens)
	Click, // an inventory request: kind, slot, arg
	Command, // text
	Shoot, // the weapon in hand, aimed at player `target` (where the server has them)
	Respawn,
	Reload, // the weapon in hand
}

Step :: struct {
	at:     int,
	who:    int,
	op:     Op,
	v:      [3]f64,
	off:    [3]i32,
	block:  game.Block,
	text:   string,
	kind:   game.Inventory_Action_Kind,
	slot:   int,
	arg:    int,
	target: int,
}

Scenario :: struct {
	name:       string,
	conditions: netcode.Conditions,
	ticks:      int,
	steps:      []Step, // in order of `at`
	done:       proc(r: ^Run) -> string, // a check of its own; "" passes
}

@(private = "file")
Bot :: struct {
	c:             Net_Client,
	inv_seq:       u32,
	edit_id:       u32,
	deaths_before: int,
}

Run :: struct {
	t:         ^testing.T,
	sc:        ^Scenario,
	sess:      Session,
	bots:      [SC_BOTS]^Bot, // player 1..
	next:      int, // the next step
	tick:      int,
	oneshot:   bit_set[game.Button;u8], // pressed for the tick just sent
	queue:     [dynamic]Step, // the mirror's, sent with its next input
	roots:     [dynamic]u64,
	bad:       [dynamic]string,
	desynced:  bool,
	delivered: int,
	standing:  bool, // the settle: nobody moves
}

SC_NAMES := [SC_BOTS + 1]string{"determinism", "p1", "p2", "p3"}

@(private = "file")
fail :: proc(r: ^Run, format: string, args: ..any) {
	append(&r.bad, fmt.aprintf("tick %d: %s", r.tick, fmt.tprintf(format, ..args)))
}

@(private = "file")
feet_of :: proc(p: [3]f64) -> game.Block_Pos {
	return {i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
}

@(private = "file")
server_client :: proc(r: ^Run, who: int) -> ^Client {
	return client_by_name(&r.sess.h.srv, SC_NAMES[who])
}

@(private = "file")
aim_at :: proc(from, to: [3]f64) -> (yaw, pitch: f32) {
	d := to - from
	return f32(math.atan2(-d.x, -d.z)), f32(math.atan2(d.y, math.sqrt(d.x * d.x + d.z * d.z)))
}

// bot_of: the bot of player `who`, or a failure.
@(private = "file")
bot_of :: proc(r: ^Run, who: int, s: Step) -> ^Bot {
	if who < 1 || who > SC_BOTS || r.bots[who - 1] == nil {
		fail(r, "step %v: player %d is not a connected bot", s.op, who)
		return nil
	}
	return r.bots[who - 1]
}

// mirror_op: the mirror's steps that need the input they follow (its sequence).
@(private = "file")
mirror_op :: proc(data: rawptr, msg: game.Input, in_: game.Player_Input) {
	r := (^Run)(data)
	m := &r.sess.mirror
	for s in r.queue {
		switch s.op {
		case .Place, .Break:
			m.edit_id += 1
			b := s.block if s.op == .Place else .Air
			e := game.edit_plain(
				m.edit_id,
				msg.sequence,
				feet_of(m.prediction.state.position) + s.off,
				b,
			)
			mirror_set_block(m, e.pos, e.block) // predicted
			mirror_send(m, e)
		case .Use:
			mirror_send(
				m,
				game.Use_Block{feet_of(m.prediction.state.position) + s.off, msg.sequence},
			)
		case .Click:
			inventory(m, s.kind, s.slot, s.arg)
		case .Command:
			command(m, s.text)
		case .Shoot:
			me, to := server_client(r, 0), server_client(r, s.target)
			if me == nil || to == nil {
				fail(r, "shoot: player %d or %d is not on the server", 0, s.target)
				continue
			}
			yaw, pitch := aim_at(game.player_eye(me.player), to.player.position + {0, 1.6, 0})
			mirror_send(m, game.Shoot{msg.sequence, 0, true, yaw, clamp(pitch, -1.5, 1.5)})
		case .Respawn:
			mirror_send(m, game.Respawn{})
		case .Reload:
			mirror_send(m, game.Reload{})
		case .Join, .Leave, .Walk, .Stand, .Jump, .Fly:
		}
	}
	clear(&r.queue)
}

@(private = "file")
mirror_set_block :: proc(m: ^Mirror, p: game.Block_Pos, b: game.Block) {
	if blocks, ok := &m.chunks[game.chunk_of(p)]; ok {
		game.chunk_set(blocks, &m.arrays, game.local_of(p), b)
	}
}

// bot_op: a bot's step, sent now.
@(private = "file")
bot_op :: proc(r: ^Run, b: ^Bot, who: int, s: Step) {
	c := &b.c
	switch s.op {
	case .Place, .Break:
		b.edit_id += 1
		blk := s.block if s.op == .Place else .Air
		net_send(
			c,
			game.edit_plain(b.edit_id, c.seq, feet_of(c.update.state.position) + s.off, blk),
		)
	case .Use:
		net_send(c, game.Use_Block{feet_of(c.update.state.position) + s.off, c.seq})
	case .Click:
		b.inv_seq += 1
		net_send(c, game.Inventory_Request{b.inv_seq, {s.kind, s.slot, s.arg}})
	case .Command:
		net_send(c, game.Command{s.text})
	case .Shoot:
		me, to := server_client(r, who), server_client(r, s.target)
		if me == nil || to == nil {
			fail(r, "shoot: player %d or %d is not on the server", who, s.target)
			return
		}
		yaw, pitch := aim_at(game.player_eye(me.player), to.player.position + {0, 1.6, 0})
		net_send(c, game.Shoot{c.seq, 0, true, yaw, clamp(pitch, -1.5, 1.5)})
	case .Respawn:
		net_send(c, game.Respawn{})
	case .Reload:
		net_send(c, game.Reload{})
	case .Walk:
		c.move, c.look = {f32(s.v.x), f32(s.v.y)}, {f32(s.v.z), 0}
	case .Stand:
		c.move = {}
	case .Jump, .Fly:
		fail(r, "step %v: only the mirror jumps and flies", s.op)
	case .Join, .Leave:
	}
}

@(private = "file")
play_step :: proc(r: ^Run, s: Step) {
	switch s.op {
	case .Join:
		if s.who < 1 || s.who > SC_BOTS || r.bots[s.who - 1] != nil {
			fail(r, "join: player %d is not free", s.who)
			return
		}
		b := new(Bot)
		net_connect(&b.c, r.sess.h.srv.host.socket.port, SC_NAMES[s.who], sim = &r.sess.h.net)
		r.bots[s.who - 1] = b
	case .Leave:
		if b := bot_of(r, s.who, s); b != nil {
			net_close(&b.c)
			free(b)
			r.bots[s.who - 1] = nil
		}
	case .Walk,
	     .Stand,
	     .Jump,
	     .Fly,
	     .Place,
	     .Break,
	     .Use,
	     .Click,
	     .Command,
	     .Shoot,
	     .Respawn,
	     .Reload:
		if s.who == 0 {
			#partial switch s.op {
			case .Walk:
				r.sess.input.move = {f32(s.v.x), f32(s.v.y)}
				r.sess.input.yaw = f32(s.v.z)
			case .Stand:
				r.sess.input.move = {}
			case .Jump:
				r.oneshot += {.Jump}
			case .Fly:
				r.oneshot += {.Toggle_Fly}
			case:
				append(&r.queue, s)
			}
		} else if b := bot_of(r, s.who, s); b != nil {
			bot_op(r, b, s.who, s)
		}
	}
}

// run_party: the runner's turn in a tick, after the mirror's and before the server's.
@(private = "file")
run_party :: proc(data: rawptr) {
	r := (^Run)(data)
	r.sess.input.buttons -= r.oneshot // (the mirror sent them this tick)
	r.oneshot = {}
	r.tick = int(r.sess.h.srv.tick) + 1
	for r.next < len(r.sc.steps) && r.sc.steps[r.next].at <= r.tick {
		play_step(r, r.sc.steps[r.next])
		r.next += 1
	}
	if r.standing {
		r.sess.input.move = {}
		for b in r.bots {if b != nil {b.c.move = {}}}
	}
	for b in r.bots {if b != nil {net_pump(r.t, &b.c)}}
	// A tick's input and the buttons: set after the pump, sent next tick.
	r.sess.input.buttons += r.oneshot
}

// bot_chunks_wrong: the blocks `held` has that the server's world does not.
@(private = "file")
chunks_wrong :: proc(
	r: ^Run,
	held: map[game.Chunk_Pos]game.Chunk_Blocks,
) -> (
	wrong, checked: int,
) {
	w := r.sess.h.srv.worlds[0]
	for pos, &blocks in held {
		c := chunks_get(&w.chunks, pos)
		if c == nil || c.state != .Ready {continue}
		checked += 1
		for k in 0 ..< game.CHUNK_VOLUME {
			l := game.local_from_index(k)
			if game.chunk_get(&blocks, l) != game.chunk_get(&c.blocks, l) {wrong += 1}
		}
	}
	return
}

// after_tick: the invariants that hold at every tick.
@(private = "file")
after_tick :: proc(r: ^Run) {
	srv := &r.sess.h.srv
	append(&r.roots, r.sess.h.last.root)
	if srv.desyncs > 0 && !r.desynced {
		r.desynced = true
		fail(
			r,
			"the server found %d prediction checks different (fields %v)",
			srv.desyncs,
			srv.desync_fields,
		)
	}
	if srv.tick % game.TICK_RATE == 0 {
		for l in audit(srv) {
			fail(
				r,
				"item conservation: %s held %d, the ledger says %d",
				game.item_name(srv.registry, l.item),
				l.held,
				l.expected,
			)
		}
	}
	for &c in srv.clients {
		if c.state == .Playing &&
		   (c.health < 0 || c.health > c.max_health || math.is_nan(c.health)) {
			fail(r, "%s has health %v of %v", client_name(&c), c.health, c.max_health)
		}
	}
}

// at_end: what must agree once everyone has stood still for SC_SETTLE ticks.
@(private = "file")
at_end :: proc(r: ^Run) {
	srv := &r.sess.h.srv
	m := &r.sess.mirror
	for f in r.sess.failures {append(&r.bad, fmt.aprintf("%s", f))}
	if !chunks_agree(&r.sess) {fail(r, "the mirror's chunks differ from the server's")}
	if wrong, checked := chunks_wrong(r, m.chunks); wrong > 0 || checked == 0 {
		fail(r, "the mirror holds %d wrong blocks in %d chunks it could compare", wrong, checked)
	}
	if m.prediction.state != m.last_update.state {
		fail(
			r,
			"the mirror predicts %v, the server said %v",
			m.prediction.state.position,
			m.last_update.state.position,
		)
	}
	for b, i in r.bots {
		if b == nil {continue}
		who := i + 1
		wrong, checked := chunks_wrong(r, b.c.chunks)
		if wrong > 0 || checked == 0 {
			fail(
				r,
				"%s holds %d wrong blocks in %d chunks it could compare",
				SC_NAMES[who],
				wrong,
				checked,
			)
		}
		c := server_client(r, who)
		if c == nil {
			fail(r, "%s is not on the server", SC_NAMES[who])
			continue
		}
		if b.c.update.state.position != c.player.position {
			fail(
				r,
				"%s was told %v, the server has %v",
				SC_NAMES[who],
				b.c.update.state.position,
				c.player.position,
			)
		}
		if abs(b.c.health.health - c.health) > 0.1 || b.c.health.dead != c.dead {
			fail(
				r,
				"%s was told health %v dead=%v, the server has %v dead=%v",
				SC_NAMES[who],
				b.c.health.health,
				b.c.health.dead,
				c.health,
				c.dead,
			)
		}
	}
	for l in audit(srv) {
		fail(
			r,
			"item conservation at the end: %s held %d, ledger %d",
			game.item_name(srv.registry, l.item),
			l.held,
			l.expected,
		)
	}
	if r.sc.done != nil {
		if why := r.sc.done(r); why != "" {fail(r, "%s", why)}
	}
}

// play: one run of the scenario. ok is false when it could not start.
@(private = "file")
play :: proc(t: ^testing.T, sc: ^Scenario, r: ^Run) -> bool {
	r.t, r.sc = t, sc
	config := harness_world()
	config.listen = true
	config.rules.pvp = true
	if !testing.expect(
		t,
		session_start(&r.sess, {}, false, with = config, conditions = sc.conditions),
	) {return false}
	r.sess.check = true
	r.sess.hook, r.sess.hook_data = mirror_op, r
	harness_add(&r.sess.h, run_party, r)
	_, landed := harness_step_until(&r.sess.h, proc(data: rawptr) -> bool {
			m := &(^Run)(data).sess.mirror
			st := m.last_update.state
			return(
				st.on_ground &&
				m.last_update.acked > 0 &&
				len(m.chunks) >= HARNESS_SC_INTEREST &&
				m.prediction.state == st \
			)
		}, r, 900)
	if !testing.expect(t, landed, "the mirror never landed") {return false}
	// The scenario's ticks count from the landing.
	base := int(r.sess.h.srv.tick)
	for &s in sc.steps {s.at += base}
	defer for &s in sc.steps {s.at -= base}
	r.tick = base
	end := base + sc.ticks
	for int(r.sess.h.srv.tick) < end + SC_SETTLE {
		if int(r.sess.h.srv.tick) == end {r.standing = true}
		harness_step(&r.sess.h)
		after_tick(r)
	}
	r.delivered = r.sess.h.net.delivered
	at_end(r)
	return true
}

run_free :: proc(r: ^Run) {
	for &b in r.bots {
		if b != nil {
			net_close(&b.c)
			free(b)
		}
	}
	delete(r.queue)
	delete(r.roots)
	for s in r.bad {delete(s)}
	delete(r.bad)
	session_stop(&r.sess)
}

// leak_check: what the run left allocated or freed twice (the test runner only
// warns about both, so the runner counts them itself).
@(private = "file")
leak_check :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, which: string) {
	for _, e in track.allocation_map {
		testing.expectf(
			t,
			false,
			"%s run leaked %d bytes allocated at %v",
			which,
			e.size,
			e.location,
		)
	}
	for b in track.bad_free_array {
		testing.expectf(t, false, "%s run freed a bad pointer at %v", which, b.location)
	}
}

// scenario: plays sc twice and checks the invariants of both (and that neither
// leaked) and that the two played alike.
scenario :: proc(t: ^testing.T, sc: Scenario) {
	sc := sc
	roots: [2][dynamic]u64
	delivered: [2]int
	defer {delete(roots[0]); delete(roots[1])}
	outer := context.allocator
	for i in 0 ..< 2 {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, outer)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.allocator = mem.tracking_allocator(&track)
			r: Run
			ok := play(t, &sc, &r)
			if ok {
				for s in r.bad {testing.expect(t, false, s)}
				roots[i] = slice.clone_to_dynamic(r.roots[:], outer)
				delivered[i] = r.delivered
			}
			run_free(&r)
			if !ok {return}
		}
		leak_check(t, &track, "first" if i == 0 else "second")
	}
	testing.expect_value(t, len(roots[0]), len(roots[1]))
	for i in 0 ..< min(len(roots[0]), len(roots[1])) {
		if roots[0][i] != roots[1][i] {
			testing.expectf(t, false, "the second run diverged at tick %d of %d", i, len(roots[0]))
			break
		}
	}
	testing.expect_value(t, delivered[0], delivered[1])
}

// ---- the scenarios

// A bot's chunks are the flat world's wherever nothing was built (the runner
// compares the rest with the server's).
@(private = "file")
held_whole :: proc(c: ^Net_Client) -> bool {
	return c.welcomed && len(c.chunks) >= HARNESS_SC_INTEREST
}

HARNESS_SC_INTEREST :: 39

@(test)
test_scenario_joining_and_moving :: proc(t: ^testing.T) {
	scenario(t, {
		name = "joining and moving",
		ticks = 480,
		steps = {
			{at = 1, who = 1, op = .Join},
			{at = 40, who = 2, op = .Join},
			{at = 60, who = 0, op = .Walk, v = {0, 1, 1.0}},
			{at = 90, who = 0, op = .Jump},
			{at = 120, who = 0, op = .Jump},
			{at = 100, who = 1, op = .Walk, v = {1, 1, 0.5}},
			{at = 140, who = 2, op = .Walk, v = {0, 1, 3.0}},
			{at = 200, who = 0, op = .Fly},
			{at = 240, who = 0, op = .Walk, v = {0.5, 1, 2.0}},
			{at = 260, who = 2, op = .Leave},
			{at = 320, who = 0, op = .Fly},
			{at = 330, who = 2, op = .Join},
			{at = 360, who = 2, op = .Walk, v = {1, 0, 0}},
			{at = 420, who = 0, op = .Stand},
		},
		done = proc(r: ^Run) -> string {
			srv := &r.sess.h.srv
			if srv.checks_judged == 0 {return "the server judged no prediction check"}
			for b in r.bots {
				if b != nil && !held_whole(&b.c) {return "a bot ended without its world"}
			}
			return ""
		},
	})
}

@(test)
test_scenario_building :: proc(t: ^testing.T) {
	scenario(
		t,
		{
			name = "building",
			ticks = 360,
			steps = {
				{at = 1, who = 1, op = .Join},
				{at = 120, who = 0, op = .Place, off = {2, 0, 0}, block = .Stone},
				{at = 124, who = 0, op = .Place, off = {2, 1, 0}, block = .Stone},
				{at = 130, who = 1, op = .Place, off = {0, 0, 2}, block = .Dirt},
				{at = 140, who = 1, op = .Break, off = {1, -1, 0}},
				{at = 150, who = 0, op = .Break, off = {2, 1, 0}},
				{at = 160, who = 0, op = .Place, off = {-2, 0, 0}, block = .Cobblestone},
				{at = 170, who = 1, op = .Break, off = {0, 0, 2}},
				// the same block placed by both in the same tick: one wins, all agree
				{at = 200, who = 0, op = .Place, off = {3, 0, 3}, block = .Stone},
				{at = 200, who = 1, op = .Place, off = {3, 0, 3}, block = .Dirt},
			},
			done = proc(r: ^Run) -> string {
				w := r.sess.h.srv.worlds[0]
				if block_at(w, {2, 0, 0}) != .Stone {return "the first stone is not there"}
				if block_at(w, {2, 1, 0}) != .Air {return "the second stone was not broken"}
				if block_at(w, {-2, 0, 0}) != .Cobblestone {return "the cobblestone is not there"}
				return ""
			},
		},
	)
}

@(private = "file")
block_at :: proc(w: ^World, p: game.Block_Pos) -> game.Block {
	if c := chunks_get(&w.chunks, game.chunk_of(p)); c != nil {
		return game.chunk_get(&c.blocks, game.local_of(p))
	}
	return .Air
}

@(test)
test_scenario_containers :: proc(t: ^testing.T) {
	scenario(t, {
		name = "containers",
		ticks = 240,
		steps = {
			{at = 1, who = 1, op = .Join},
			{at = 60, who = 0, op = .Command, text = "setblock 2 0 0 chest"},
			{at = 70, who = 0, op = .Use, off = {2, 0, 0}},
			{at = 74, who = 1, op = .Use, off = {2, 0, 0}},
			{at = 100, who = 1, op = .Click, kind = .Quick_Move, slot = 0},
			{at = 130, who = 0, op = .Click, kind = .Click_Right, slot = game.CHEST_BASE},
			{at = 134, who = 0, op = .Click, kind = .Click, slot = 29},
			{at = 180, who = 1, op = .Click, kind = .Close},
			{at = 184, who = 0, op = .Click, kind = .Close},
		},
		done = proc(r: ^Run) -> string {
			w := r.sess.h.srv.worlds[0]
			e := block_entity_at(w, {2, 0, 0})
			if e == nil {return "the chest has no record"}
			moved := e.slots[0].count
			if moved == 0 ||
			   moved >= 64 {return fmt.tprintf("the chest holds %d of the stone", moved)}
			return ""
		},
	})
}

@(test)
test_scenario_combat :: proc(t: ^testing.T) {
	shots: [dynamic]Step
	defer delete(shots)
	append(&shots, Step{at = 1, who = 1, op = .Join})
	append(&shots, Step{at = 1, who = 2, op = .Join})
	for who in 0 ..= 2 {
		append(&shots, Step{at = 10, who = who, op = .Command, text = "gamemode survival"})
		append(&shots, Step{at = 14, who = who, op = .Command, text = "give @s pistol"})
		append(
			&shots,
			Step{at = 20, who = who, op = .Click, kind = .Swap_Hotbar, slot = 9, arg = 0},
		)
		append(&shots, Step{at = 24, who = who, op = .Reload})
	}
	append(&shots, Step{at = 40, who = 1, op = .Command, text = "tp 0.5 0 0.5"})
	append(&shots, Step{at = 40, who = 2, op = .Command, text = "tp 6.5 0 0.5"})
	for k in 0 ..< 10 {
		append(&shots, Step{at = 80 + 30 * k, who = 1, op = .Shoot, target = 2})
		append(&shots, Step{at = 95 + 30 * k, who = 2, op = .Shoot, target = 1})
	}
	scenario(t, {
		name = "combat",
		ticks = 440,
		conditions = {loss = 0.05, duplicate = 0.05, latency_ms = 60, jitter_ms = 30, seed = 66},
		steps = shots[:],
		done = proc(r: ^Run) -> string {
			hurt := 0
			for who in 1 ..= 2 {
				c := server_client(r, who)
				if c != nil &&
				   (c.health < c.max_health || (c.stats["deaths"] or_else 0) > 0) {hurt += 1}
			}
			if hurt == 0 {return "nobody was hurt by the shots"}
			return ""
		},
	})
}

@(test)
test_scenario_death_and_respawn :: proc(t: ^testing.T) {
	scenario(
		t,
		{
			name = "death and respawn",
			ticks = 360,
			steps = {
				{at = 1, who = 1, op = .Join},
				{at = 2, who = 2, op = .Join},
				{at = 10, who = 0, op = .Command, text = "gamemode survival"},
				{at = 10, who = 1, op = .Command, text = "gamemode survival"},
				{at = 10, who = 2, op = .Command, text = "gamemode survival"},
				{at = 80, who = 0, op = .Command, text = "give p1 stone 10"},
				{at = 100, who = 0, op = .Command, text = "damage p1 1000"},
				{at = 130, who = 1, op = .Respawn},
				{at = 160, who = 0, op = .Command, text = "damage determinism 1000"},
				{at = 200, who = 0, op = .Respawn},
				{at = 220, who = 2, op = .Command, text = "damage p2 1000"},
				// (p2 stays at the death screen to the end: dead is a state too)
			},
			done = proc(r: ^Run) -> string {
				p1, p0, p2 := server_client(r, 1), server_client(r, 0), server_client(r, 2)
				if p1 == nil || p0 == nil || p2 == nil {return "a player is gone"}
				if p1.dead || p0.dead {return "a respawn did not take"}
				if !p2.dead {return "p2 is not at the death screen"}
				if (p1.stats["deaths"] or_else 0) != 1 {return "p1 did not die once"}
				return ""
			},
		},
	)
}

@(test)
test_scenario_chunk_streaming_under_loss :: proc(t: ^testing.T) {
	scenario(t, {
		name = "chunk streaming under loss",
		ticks = 450,
		conditions = {loss = 0.1, duplicate = 0.1, latency_ms = 50, jitter_ms = 30, seed = 66},
		steps = {
			{at = 1, who = 1, op = .Join},
			{at = 1, who = 2, op = .Join},
			{at = 20, who = 0, op = .Walk, v = {0, 1, 1.5708}},
			{at = 20, who = 1, op = .Walk, v = {0, 1, 0}},
			{at = 20, who = 2, op = .Walk, v = {0, 1, 3.1416}},
			{at = 250, who = 1, op = .Walk, v = {0, 1, 3.1416}},
			{at = 250, who = 2, op = .Walk, v = {0, 1, 0}},
		},
		done = proc(r: ^Run) -> string {
			for b in r.bots {
				if b != nil &&
				   len(b.c.chunks) < HARNESS_SC_INTEREST {return "a bot holds too few chunks"}
			}
			if len(r.sess.mirror.chunks) <
			   HARNESS_SC_INTEREST {return "the mirror holds too few chunks"}
			return ""
		},
	})
}
