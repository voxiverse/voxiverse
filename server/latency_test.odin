package server

import "core:math"
import "core:testing"
import "core:time"

import "../common/game"

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
	flying:       bool,
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
	last_update: game.Own_Player,
	rx:          State_Rx,
	teleports:   u8,
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
	return {c, client_block, test_blocks()}
}

@(private = "file")
pump :: proc(t: ^testing.T, c: ^Predicting_Client) {
	packets := make([dynamic]game.Packet, context.temp_allocator)
	game.receive(c.endpoint, &packets)
	for p in packets {
		defer game.packet_free(c.endpoint, p)
		m, ok := game.decode_server(p, c.scratch, test_reg())
		if !testing.expect(t, ok) {continue}
		#partial switch v in m {
		case game.Challenge:
			send(c, game.Proof{game.account_sign(&c.key, v.nonce)})
		case game.Welcome:
			c.welcome, c.welcomed, c.rules = v, true, v.rules
			game.prediction_init(&c.prediction, {position = v.spawn})
			rules := v.rules
			game.receiver_seed(&c.rx.rx, int(game.State_Kind.Rules), &rules)
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
		case game.State_Message, game.Snapshot_Message:
			for g in state_rx_take(t, &c.rx, m) {
				#partial switch game.State_Kind(g.kind) {
				case .Own_Player:
					c.last_update = (^game.Own_Player)(g.value)^
					teleported := c.last_update.teleports != c.teleports
					c.teleports = c.last_update.teleports
					game.prediction_reconcile(
						&c.prediction,
						c.last_update,
						&c.rules,
						query(c),
						teleported = teleported,
					)
				case .Rules:
					c.rules = (^game.Rules)(g.value)^
				}
			}
		case game.Edit_Result:
			c.results[v.id] = v
			set_block(c, v.pos, v.block)
			if cm, two := v.companion.?; two {set_block(c, cm.pos, cm.block)}
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
	still_ticks := 0, // then standing still, no edits, still checking: a quiet stretch where checks are always judged
	nudge := false, // the client puts one ulp into its predicted velocity.x after every prediction
	fly := false, // the character is in a mode with `fly`, takes off and flies (no edits)
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
	state_rx_init(&c.rx)
	defer state_rx_destroy(&c.rx)
	game.block_arrays_init(&c.arrays, 2048)
	defer game.block_arrays_destroy(&c.arrays)
	defer delete(c.chunks)
	defer delete(c.results)

	mods := game.MODS_NONE
	if fly {
		inv: game.Inventory
		m, _ := game.mode_find(srv.registry, "creative")
		mods = game.derive_character(srv.registry, m, &inv)
	}
	c.key = test_key("latency_test")
	send(&c, test_hello("latency_test"))
	// Each phase gets its own budget: the script alone is `ticks` sleeps long,
	// and sleeps overshoot on a loaded runner, so one deadline for the whole
	// run would be a race against the machine's speed.
	PHASE_BUDGET :: 20 * time.Second
	deadline := time.tick_add(time.tick_now(), PHASE_BUDGET)
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
		msg.snapshot = c.rx.rx.ack
		send(&c, msg)
		tick_wait()
		s := c.last_update.state
		settled := s.on_ground && c.last_update.acked > 0 && len(c.chunks) > 200
		if settled && c.prediction.state == s {break}
		if time.tick_diff(time.tick_now(), deadline) < 0 {return}
	}

	deadline = time.tick_add(time.tick_now(), PHASE_BUDGET)
	// The script: 150 ticks of walking and jumping, three edits.
	EDIT_TICKS :: [3]int{40, 80, 120}
	corrections_before := c.prediction.corrections
	for tick in 0 ..< ticks + still_ticks {
		pump(t, &c)
		in_ := script_input(tick) if tick < ticks else game.Player_Input{pitch = -0.7}
		if fly && tick == 10 {in_.buttons += {.Toggle_Fly}}
		if fly && tick > 10 && tick < ticks {in_.buttons += {.Jump}}
		msg := game.prediction_tick(&c.prediction, in_, &c.rules, query(&c), mods)
		msg.snapshot = c.rx.rx.ack
		if nudge {
			v := &c.prediction.state.velocity.x
			v^ = transmute(f32)(transmute(u32)v^ + 1)
		}
		send(&c, msg)
		check(&c, msg.sequence)
		for edit_tick, i in EDIT_TICKS {
			if tick != edit_tick || fly {continue}
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
				face  = game.EDIT_FACE_BREAK,
			}
			if i == 1 { 	// place stone against the face
				face, _ := game.face_of_normal(hit.normal)
				e.pos, e.block = hit.block + hit.normal, .Stone
				e.target, e.face, e.hit =
					hit.block, u8(face), game.hit_sixteenths(hit.point, hit.block)
			}
			set_block(&c, e.pos, e.block) // predicted
			send(&c, e)
		}
		tick_wait()
	}
	// Everything acknowledged and answered.
	deadline = time.tick_add(time.tick_now(), PHASE_BUDGET)
	last := c.prediction.next_sequence - 1
	for c.last_update.acked != last || (len(c.results) < 3 && !fly) || c.prediction.count > 0 {
		pump(t, &c)
		tick_wait()
		if time.tick_diff(time.tick_now(), deadline) < 0 {return}
	}
	result.server_state = c.last_update.state
	result.predicted = c.prediction.state
	if !fly {for i in 0 ..< 3 {result.edits[i] = c.results[u32(i + 1)]}}
	result.flying = c.prediction.state.flying
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

// The script ends standing still with no edits, for DESYNC_QUIET_TICKS plus
// eight check intervals: the server applies at least one input per tick, so at
// least some checks land after the quiet time however the sleeps overshoot.
@(private = "file")
QUIET_STRETCH :: game.DESYNC_QUIET_TICKS + 8 * game.DESYNC_CHECK_INPUTS

// The detector is quiet when nothing is wrong, 200 ms of latency and all, and
// judges enough checks not to be vacuous.
@(test)
test_no_desync_with_latency :: proc(t: ^testing.T) {
	r, ok := run_script(t, 200, 60, ticks = 450, still_ticks = QUIET_STRETCH)
	if !testing.expect(t, ok, "the run did not finish") {return}
	testing.expectf(t, r.desyncs == 0, "%d desyncs", r.desyncs)
	total := r.judged + r.skipped
	testing.expectf(t, total > 8 && r.judged >= 4, "judged %d of %d checks", r.judged, total)
}

// A client whose prediction is one ulp off is told so, by field.
// Flight is predicted: the client flies the same ticks the server does, with
// latency and no corrections (both ask derive_character for `fly`).
@(test)
test_fly_predicted_with_latency :: proc(t: ^testing.T) {
	r, ok := run_script(t, 200, 60, fly = true)
	if !testing.expect(t, ok, "the run did not finish") {return}
	testing.expect(t, r.flying && r.server_state.flying, "both sides are flying")
	testing.expect(t, r.predicted == r.server_state, "prediction ended away from the server")
	testing.expect_value(t, r.corrections, 0)
	testing.expect_value(t, r.desyncs, 0)
}

@(test)
test_desync_caught :: proc(t: ^testing.T) {
	r, ok := run_script(t, 200, 60, ticks = 450, still_ticks = QUIET_STRETCH, nudge = true)
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

// M48: stairs and slabs placed from every side with 200 ms of latency each way and
// jitter: each edit carries what it followed, the server runs the same rule and
// agrees, the client's blocks end equal to the server's; an edit whose state
// disagrees with its context is refused.
@(test)
test_shaped_placements_with_latency :: proc(t: ^testing.T) {
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	game.pipe_set_conditions(&pipe, {latency_ms = 200, jitter_ms = 60})
	srv: Server
	if !testing.expect(
		t,
		start(
			&srv,
			{
				seed = 5,
				generator = .Classic,
				view_radius = 4,
				view_height = 2,
				workers = 2,
				allow_cheats = true,
			},
			{&pipe, .Server},
		),
	) {return}
	defer stop(&srv)
	c := Predicting_Client {
		endpoint = {&pipe, .Client},
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	state_rx_init(&c.rx)
	defer state_rx_destroy(&c.rx)
	game.block_arrays_init(&c.arrays, 2048)
	defer game.block_arrays_destroy(&c.arrays)
	defer delete(c.chunks)
	defer delete(c.results)
	c.key = test_key("latency_test")
	send(&c, test_hello("latency_test"))
	tick_wait :: proc() {time.sleep(game.TICK_DURATION)}
	deadline := time.tick_add(time.tick_now(), 20 * time.Second)
	for !c.welcomed {
		pump(t, &c)
		tick_wait()
		if !testing.expect(t, time.tick_diff(time.tick_now(), deadline) > 0, "no welcome") {return}
	}
	stand :: proc(t: ^testing.T, c: ^Predicting_Client, yaw: f32, ticks: int) -> u32 {
		seq: u32
		for _ in 0 ..< ticks {
			pump(t, c)
			msg := game.prediction_tick(
				&c.prediction,
				{pitch = -0.7, yaw = yaw},
				&c.rules,
				query(c),
			)
			msg.snapshot = c.rx.rx.ack
			send(c, msg)
			seq = msg.sequence
			tick_wait()
		}
		return seq
	}
	for {
		stand(t, &c, 0, 1)
		s := c.last_update.state
		if s.on_ground &&
		   c.last_update.acked > 0 &&
		   len(c.chunks) > 200 &&
		   c.prediction.state == s {break}
		if !testing.expect(
			t,
			time.tick_diff(time.tick_now(), deadline) > 0,
			"never landed",
		) {return}
	}
	p := c.prediction.state.position
	o := game.Block_Pos{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
	// A wall two blocks east, four high: stairs and slabs go against its west face.
	for text in ([]string{"fill ~1 ~ ~-3 ~3 ~3 ~3 air", "fill ~2 ~ ~-3 ~2 ~3 ~3 stone"}) {
		send(&c, game.Command{text})
		stand(t, &c, 0, 3)
	}
	stand(t, &c, 0, 25)
	wall := o + {2, 0, 0}
	_, ok := client_block(&c, wall)
	if !testing.expect(t, ok) {return}
	Placed :: struct {
		id:  u32,
		pos: game.Block_Pos,
		b:   game.Block,
	}
	placed := make([dynamic]Placed, context.temp_allocator)
	for k in 0 ..< 24 {
		z, y := i32(k % 7) - 3, i32(k / 7)
		face_yaw := f32(k % 4) * math.PI / 2 + 0.1 // every quadrant
		hit_y := u8(3 if (k / 4) % 2 == 0 else 12) // both halves
		name := "stone_stairs" if k < 16 else "stone_slab"
		type := game.block_type_of(&test_reg().blocks, test_block(name))
		ctx := game.Place_Context {
			target = wall + {0, y, z},
			face   = .Neg_X,
			hit    = {0, hit_y, 8},
			yaw    = face_yaw,
		}
		pos, state, good := game.placement(test_reg(), type, ctx, query(&c))
		if !testing.expectf(t, good, "placement %d refused by the rule", k) {return}
		seq := stand(t, &c, face_yaw, 2)
		id := u32(k + 1)
		set_block(&c, pos, state) // predicted
		send(&c, game.Edit{id, seq, pos, state, ctx.target, u8(ctx.face), ctx.hit})
		append(&placed, Placed{id, pos, state})
		stand(t, &c, face_yaw, 1)
	}
	// A forged edit: the context says one thing, the state another.
	forged_type := game.block_type_of(&test_reg().blocks, test_block("stone_stairs"))
	forged_ctx := game.Place_Context {
		target = wall + {0, 3, 3},
		face   = .Pos_Y,
		hit    = {8, 16, 8},
		yaw    = 0,
	}
	fpos, fstate, _ := game.placement(test_reg(), forged_type, forged_ctx, query(&c))
	wrong, _ := game.state_set(&test_reg().blocks, fstate, "facing", "east")
	seq := stand(t, &c, 0, 2)
	send(
		&c,
		game.Edit{100, seq, fpos, wrong, forged_ctx.target, u8(forged_ctx.face), forged_ctx.hit},
	)
	seq = stand(t, &c, 0, 2)
	send(
		&c,
		game.Edit{101, seq, fpos, fstate, forged_ctx.target, u8(forged_ctx.face), forged_ctx.hit},
	)
	// All answered.
	deadline = time.tick_add(time.tick_now(), 20 * time.Second)
	for len(c.results) < len(placed) + 2 {
		stand(t, &c, 0, 1)
		if !testing.expect(
			t,
			time.tick_diff(time.tick_now(), deadline) > 0,
			"not all answered",
		) {return}
	}
	for pl in placed {
		r := c.results[pl.id]
		testing.expectf(t, r.accepted, "edit %d (%v) refused", pl.id, state_text(test_reg(), pl.b))
		got, _ := chunks_block(&srv.home.chunks, pl.pos)
		testing.expectf(
			t,
			got == pl.b,
			"server has %s, client placed %s",
			state_text(test_reg(), got),
			state_text(test_reg(), pl.b),
		)
		mine, _ := client_block(&c, pl.pos)
		testing.expect_value(t, mine, got)
	}
	testing.expect(t, !c.results[100].accepted, "a forged state was accepted")
	testing.expect(t, c.results[101].accepted, "the honest edit after it was refused")
}

// M48b: a door placed, opened and closed at 200 ms each way with jitter: both
// halves are predicted and the server agrees; a door with no room above is
// refused and both cells are put back (the upper half by the companion).
@(test)
test_doors_with_latency :: proc(t: ^testing.T) {
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	game.pipe_set_conditions(&pipe, {latency_ms = 200, jitter_ms = 60})
	srv: Server
	if !testing.expect(
		t,
		start(
			&srv,
			{
				seed = 5,
				generator = .Classic,
				view_radius = 4,
				view_height = 2,
				workers = 2,
				allow_cheats = true,
			},
			{&pipe, .Server},
		),
	) {return}
	defer stop(&srv)
	c := Predicting_Client {
		endpoint = {&pipe, .Client},
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	state_rx_init(&c.rx)
	defer state_rx_destroy(&c.rx)
	game.block_arrays_init(&c.arrays, 2048)
	defer game.block_arrays_destroy(&c.arrays)
	defer delete(c.chunks)
	defer delete(c.results)
	c.key = test_key("latency_test")
	send(&c, test_hello("latency_test"))
	deadline := time.tick_add(time.tick_now(), 20 * time.Second)
	for !c.welcomed {
		pump(t, &c)
		time.sleep(game.TICK_DURATION)
		if !testing.expect(t, time.tick_diff(time.tick_now(), deadline) > 0, "no welcome") {return}
	}
	stand :: proc(t: ^testing.T, c: ^Predicting_Client, ticks: int) -> u32 {
		seq: u32
		for _ in 0 ..< ticks {
			pump(t, c)
			msg := game.prediction_tick(&c.prediction, {pitch = -0.7}, &c.rules, query(c))
			msg.snapshot = c.rx.rx.ack
			send(c, msg)
			seq = msg.sequence
			time.sleep(game.TICK_DURATION)
		}
		return seq
	}
	for {
		stand(t, &c, 1)
		s := c.last_update.state
		if s.on_ground &&
		   c.last_update.acked > 0 &&
		   len(c.chunks) > 200 &&
		   c.prediction.state == s {break}
		if !testing.expect(
			t,
			time.tick_diff(time.tick_now(), deadline) > 0,
			"never landed",
		) {return}
	}
	p := c.prediction.state.position
	o := game.Block_Pos{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
	// Room for a door at o + (2, 0, 0) and a ceiling over the one at o + (2, 0, 3).
	for text in ([]string{"fill ~2 ~-1 ~-1 ~2 ~3 ~4 stone", "fill ~2 ~ ~ ~2 ~3 ~ air", "fill ~2 ~ ~3 ~2 ~ ~3 air"}) {
		send(&c, game.Command{text})
		stand(t, &c, 3)
	}
	stand(t, &c, 25)
	door_type := game.block_type_of(&test_reg().blocks, test_block("voxiverse:planks_door"))
	door :: proc(
		t: ^testing.T,
		c: ^Predicting_Client,
		id: u32,
		type: game.Block_Type,
		pos: game.Block_Pos,
	) -> (
		lower: game.Block,
		ok: bool,
	) {
		ctx := game.Place_Context {
			target = pos + {0, -1, 0},
			face   = .Pos_Y,
			hit    = {8, 16, 8},
			yaw    = 0,
		}
		_, lower, ok = game.placement(test_reg(), type, ctx, query(c))
		if !ok {return}
		seq := stand(t, c, 2)
		set_block(c, pos, lower)
		_, upper, _ := game.companion(test_reg(), lower, pos)
		set_block(c, pos + {0, 1, 0}, upper)
		send(c, game.Edit{id, seq, pos, lower, ctx.target, u8(ctx.face), ctx.hit})
		return
	}
	at_door := o + {2, 0, 0}
	lower, ok := door(t, &c, 1, door_type, at_door)
	if !testing.expect(t, ok, "the door's placement was refused by the rule") {return}
	await :: proc(t: ^testing.T, c: ^Predicting_Client, id: u32) -> bool {
		deadline := time.tick_add(time.tick_now(), 20 * time.Second)
		for _, answered := c.results[id]; !answered; _, answered = c.results[id] {
			stand(t, c, 1)
			if !testing.expect(
				t,
				time.tick_diff(time.tick_now(), deadline) > 0,
				"no answer",
			) {return false}
		}
		return true
	}
	if !await(t, &c, 1) {return}
	testing.expect(t, c.results[1].accepted, "the door was refused")
	// Opened, then closed: both halves turn each time, predicted at once.
	turn :: proc(t: ^testing.T, c: ^Predicting_Client, id: u32, pos: game.Block_Pos) -> bool {
		now, _ := client_block(c, pos)
		tb := &test_reg().blocks
		i, _ := game.prop_index(tb, tb.type_of[now], "open")
		flipped := game.state_with(tb, now, i, 1 - game.state_value(tb, now, i))
		seq := stand(t, c, 2)
		set_block(c, pos, flipped)
		_, upper, _ := game.companion(test_reg(), flipped, pos)
		set_block(c, pos + {0, 1, 0}, upper)
		send(c, game.edit_plain(id, seq, pos, flipped))
		return await(t, c, id)
	}
	for id in u32(2) ..= 3 {
		if !turn(t, &c, id, at_door) {return}
		testing.expectf(t, c.results[id].accepted, "turning %d was refused", id)
		stand(t, &c, 10)
		for cell in ([]game.Block_Pos{at_door, at_door + {0, 1, 0}}) {
			got, _ := chunks_block(&srv.home.chunks, cell)
			mine, _ := client_block(&c, cell)
			testing.expectf(
				t,
				got == mine,
				"turn %d: server %s, client %s",
				id,
				state_text(test_reg(), got),
				state_text(test_reg(), mine),
			)
		}
	}
	back, _ := chunks_block(&srv.home.chunks, at_door)
	testing.expect_value(t, back, lower) // closed again
	// No room above: the forged edit is refused and both cells go back as the server has them.
	bad := o + {2, 0, 3}
	send(&c, game.Command{"setblock ~2 ~1 ~3 stone"})
	stand(t, &c, 30)
	seq := stand(t, &c, 2)
	set_block(&c, bad, lower)
	_, upper, _ := game.companion(test_reg(), lower, bad)
	set_block(&c, bad + {0, 1, 0}, upper)
	send(&c, game.Edit{4, seq, bad, lower, bad + {0, -1, 0}, u8(game.Face.Pos_Y), {8, 16, 8}})
	if !await(t, &c, 4) {return}
	testing.expect(t, !c.results[4].accepted, "a door with a ceiling was accepted")
	for cell in ([]game.Block_Pos{bad, bad + {0, 1, 0}}) {
		got, _ := chunks_block(&srv.home.chunks, cell)
		mine, _ := client_block(&c, cell)
		testing.expectf(
			t,
			got == mine,
			"after the refusal: server %s, client %s",
			state_text(test_reg(), got),
			state_text(test_reg(), mine),
		)
	}
	above, _ := client_block(&c, bad + {0, 1, 0})
	testing.expect_value(t, above, game.Block.Stone)
}

@(private = "file")
state_text :: proc(reg: ^game.Registry, b: game.Block) -> string {
	return game.state_text(reg, b)
}

@(private = "file")
test_block :: proc(name: string) -> game.Block {
	b, ok := game.registry_block(test_reg(), name)
	if !ok {panic(name)}
	return b
}
