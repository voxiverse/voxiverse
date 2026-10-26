package server

import "core:math"
import "core:testing"
import "core:time"

import "../game"

// M4's exit check: a scripted player (walking, turning, jumping, breaking
// and placing) gives the same results with 200 ms of latency each way (and
// jitter) as with none, and the client's prediction ends exactly where the
// server is.

@(private = "file")
Run_Result :: struct {
	server_state: game.Player_State, // the last Player_Update
	predicted:    game.Player_State,
	edits:        [3]game.Edit_Result,
	corrections:  int,
	desyncs:      int, // checks the server found different
	judged:       int,
	skipped:      int,
	velocity:     int, // ... of them in the velocity
}

@(private = "file")
Predicting_Client :: struct {
	key:         game.Account_Key,
	endpoint:    game.Endpoint,
	scratch:     ^game.Block_Array,
	arrays:      game.Block_Arrays,
	chunks:      map[game.Chunk_Pos]game.Chunk_Blocks,
	prediction:  game.Prediction,
	rules:       game.Rules,
	welcome:     game.Welcome,
	welcomed:    bool,
	last_update: game.Player_Update,
	results:     map[u32]game.Edit_Result,
}

@(private = "file")
client_block :: proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
	c := (^Predicting_Client)(data)
	blocks, ok := &c.chunks[game.chunk_of(p)]
	if !ok {return .Air, false}
	return game.chunk_get(blocks, game.local_of(p)), true
}

@(private = "file")
query :: proc(c: ^Predicting_Client) -> game.Block_Query {
	return {c, client_block}
}

@(private = "file")
pump :: proc(t: ^testing.T, c: ^Predicting_Client) {
	packets := make([dynamic]game.Packet, context.temp_allocator)
	game.receive(c.endpoint, &packets)
	for p in packets {
		defer game.packet_free(c.endpoint, p)
		m, ok := game.decode_server(p, c.scratch)
		if !testing.expect(t, ok) {continue}
		#partial switch v in m {
		case game.Challenge:
			send(c, game.Proof{game.account_sign(&c.key, v.nonce)})
		case game.Welcome:
			c.welcome, c.welcomed, c.rules = v, true, v.rules
			game.prediction_init(&c.prediction, {position = v.spawn})
		case game.Chunk_Message:
			blocks := game.Chunk_Blocks {
				uniform = v.uniform,
			}
			if !v.is_uniform {
				blocks.array, _ = game.block_arrays_take(&c.arrays)
				blocks.array^ = c.scratch^
			}
			if old, had := &c.chunks[v.pos]; had {game.chunk_release(old, &c.arrays)}
			c.chunks[v.pos] = blocks
		case game.Unload_Chunk:
			if old, had := &c.chunks[v.pos]; had {
				game.chunk_release(old, &c.arrays)
				delete_key(&c.chunks, v.pos)
			}
		case game.Player_Update:
			c.last_update = v
			game.prediction_reconcile(&c.prediction, v, &c.rules, query(c))
		case game.Edit_Result:
			c.results[v.id] = v
			set_block(c, v.pos, v.block)
		case game.Rules_Changed:
			c.rules = v.rules
		}
	}
}

@(private = "file")
set_block :: proc(c: ^Predicting_Client, p: game.Block_Pos, b: game.Block) {
	if blocks, ok := &c.chunks[game.chunk_of(p)]; ok {
		game.chunk_set(blocks, &c.arrays, game.local_of(p), b)
	}
}

@(private = "file")
send :: proc(c: ^Predicting_Client, m: game.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.encode_client(&w, m)
	game.send(c.endpoint, w.buf[:])
}

// check sends the Prediction_Check a client sends every DESYNC_CHECK_INPUTS inputs.
@(private = "file")
check :: proc(c: ^Predicting_Client, sequence: u32) {
	if sequence % game.DESYNC_CHECK_INPUTS != 0 {return}
	p := c.prediction.state.position
	centre := game.chunk_of({i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))})
	for dy in i32(-1) ..= 1 {
		for dz in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {
				if centre + {dx, dy, dz} not_in c.chunks {return}
			}
		}
	}
	send(c, game.Prediction_Check{sequence, game.player_fields(c.prediction.state)})
}

@(private = "file")
script_input :: proc(tick: int) -> game.Player_Input {
	in_ := game.Player_Input {
		move  = {0.4 * f32(math.sin(f64(tick) * 0.07)), 0.6},
		yaw   = -math.PI / 2 + 0.5 * f32(math.sin(f64(tick) * 0.03)),
		pitch = -0.7, // looking ahead and down, at the ground in front
	}
	if tick % 35 == 20 {in_.buttons += {.Jump}}
	return in_
}

@(private = "file")
run_script :: proc(
	t: ^testing.T,
	latency_ms, jitter_ms: f32,
	ticks := 150,
	nudge := false, // the client puts one ulp into its predicted velocity.x after every prediction
) -> (
	result: Run_Result,
	ok: bool,
) {
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	game.pipe_set_conditions(&pipe, {latency_ms = latency_ms, jitter_ms = jitter_ms})
	srv: Server
	if !start(
	&srv,
	{seed = 5, generator = .Classic, view_radius = 4, view_height = 2, workers = 2}, // M4's gentle hills: corrections only from latency, not chunks still arriving under a forest
	{&pipe, .Server},
	) {return}
	defer stop(&srv)

	c := Predicting_Client {
		endpoint = {&pipe, .Client},
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	game.block_arrays_init(&c.arrays, 2048)
	defer game.block_arrays_destroy(&c.arrays)
	defer delete(c.chunks)
	defer delete(c.results)

	c.key = test_key("latency_test")
	send(&c, test_hello("latency_test"))
	deadline := time.tick_add(time.tick_now(), 20 * time.Second)
	tick_wait :: proc() {time.sleep(game.TICK_DURATION)}

	// Join, and stand still until the world is there and the player has
	// landed (and the server agrees).
	for !c.welcomed {
		pump(t, &c)
		tick_wait()
		if time.tick_diff(time.tick_now(), deadline) < 0 {return}
	}
	for {
		pump(t, &c)
		msg := game.prediction_tick(&c.prediction, {pitch = -0.7}, &c.rules, query(&c))
		send(&c, msg)
		tick_wait()
		s := c.last_update.state
		settled := s.on_ground && c.last_update.acked > 0 && len(c.chunks) > 200
		if settled && c.prediction.state == s {break}
		if time.tick_diff(time.tick_now(), deadline) < 0 {return}
	}

	// The script: 150 ticks of walking and jumping, three edits.
	EDIT_TICKS :: [3]int{40, 80, 120}
	corrections_before := c.prediction.corrections
	for tick in 0 ..< ticks {
		pump(t, &c)
		msg := game.prediction_tick(&c.prediction, script_input(tick), &c.rules, query(&c))
		if nudge {
			v := &c.prediction.state.velocity.x
			v^ = transmute(f32)(transmute(u32)v^ + 1)
		}
		send(&c, msg)
		check(&c, msg.sequence)
		for edit_tick, i in EDIT_TICKS {
			if tick != edit_tick {continue}
			in_ := script_input(tick)
			f := [3]f64 {
				-math.sin(f64(in_.yaw)) * math.cos(f64(in_.pitch)),
				math.sin(f64(in_.pitch)),
				-math.cos(f64(in_.yaw)) * math.cos(f64(in_.pitch)),
			}
			eye := game.player_eye(c.prediction.state)
			hit, aimed := game.raycast(query(&c), eye, f, f64(c.rules.reach))
			if !testing.expectf(t, aimed, "edit %d: nothing aimed at", i) {return}
			e := game.Edit {
				id    = u32(i + 1),
				after = msg.sequence,
				pos   = hit.block,
				block = .Air,
			}
			if i == 1 { 	// place stone against the face
				e.pos, e.block = hit.block + hit.normal, .Stone
			}
			set_block(&c, e.pos, e.block) // predicted
			send(&c, e)
		}
		tick_wait()
	}
	// Everything acknowledged and answered.
	last := c.prediction.next_sequence - 1
	for c.last_update.acked != last || len(c.results) < 3 || c.prediction.count > 0 {
		pump(t, &c)
		tick_wait()
		if time.tick_diff(time.tick_now(), deadline) < 0 {return}
	}
	result.server_state = c.last_update.state
	result.predicted = c.prediction.state
	for i in 0 ..< 3 {result.edits[i] = c.results[u32(i + 1)]}
	result.corrections = c.prediction.corrections - corrections_before
	result.desyncs, result.judged, result.skipped =
		srv.desyncs, srv.checks_judged, srv.checks_skipped
	result.velocity = srv.desync_fields[.Velocity]
	return result, true
}

@(test)
test_same_results_with_latency :: proc(t: ^testing.T) {
	fast, fast_ok := run_script(t, 0, 0)
	slow, slow_ok := run_script(t, 200, 60) // and up to 60 ms of jitter
	if !testing.expect(t, fast_ok && slow_ok, "a run did not finish") {return}
	testing.expectf(
		t,
		fast.server_state == slow.server_state,
		"server ended at %v without latency, %v with",
		fast.server_state.position,
		slow.server_state.position,
	)
	testing.expect(t, fast.edits == slow.edits, "edits came out differently")
	for e in fast.edits {testing.expectf(t, e.accepted, "edit %d refused", e.id)}
	testing.expect(
		t,
		fast.predicted == fast.server_state && slow.predicted == slow.server_state,
		"prediction ended away from the server",
	)
	testing.expectf(
		t,
		slow.corrections == 0,
		"%d corrections with 200 ms latency",
		slow.corrections,
	)
	testing.expect(t, fast.server_state.position != {}, "nobody moved")
}

// The detector is quiet when nothing is wrong, 200 ms of latency and all, and
// judges enough checks not to be vacuous.
@(test)
test_no_desync_with_latency :: proc(t: ^testing.T) {
	r, ok := run_script(t, 200, 60, ticks = 450)
	if !testing.expect(t, ok, "the run did not finish") {return}
	testing.expectf(t, r.desyncs == 0, "%d desyncs", r.desyncs)
	total := r.judged + r.skipped
	testing.expectf(
		t,
		total > 8 && r.judged * 2 >= total,
		"judged %d of %d checks",
		r.judged,
		total,
	)
}

// A client whose prediction is one ulp off is told so, by field.
@(test)
test_desync_caught :: proc(t: ^testing.T) {
	r, ok := run_script(t, 200, 60, ticks = 450, nudge = true)
	if !testing.expect(t, ok, "the run did not finish") {return}
	testing.expectf(t, r.desyncs > 0, "no desync found (%d judged)", r.judged)
	testing.expectf(
		t,
		r.velocity == r.desyncs,
		"%d desyncs, %d in the velocity",
		r.desyncs,
		r.velocity,
	)
}
