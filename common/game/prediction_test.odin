package game

import "core:math"
import "core:testing"

@(private = "file")
World :: struct {
	solid: map[Block_Pos]bool,
}

@(private = "file")
query :: proc(w: ^World) -> Block_Query {
	return {w, proc(data: rawptr, p: Block_Pos) -> (Block, bool) {
			return .Stone if p in (^World)(data).solid else .Air, true
		}}
}

@(private = "file")
make_world :: proc() -> World {
	w: World
	for x in i32(-40) ..= 40 {
		for z in i32(-40) ..= 40 {w.solid[{x, 0, z}] = true}
	}
	for z in i32(-40) ..= 40 {w.solid[{6, 1, z}] = true} 	// a step to jump onto
	return w
}

// A scripted player: walks, turns, jumps, sprints, flies.
@(private = "file")
scripted_input :: proc(tick: int) -> Player_Input {
	in_ := Player_Input {
		move = {0.3 * f32(math.sin(f64(tick) * 0.05)), 1},
		yaw  = -math.PI / 2 + 0.4 * f32(math.sin(f64(tick) * 0.02)),
	}
	if tick % 40 == 10 {in_.buttons += {.Jump}}
	if tick > 150 {in_.buttons += {.Sprint}}
	if tick == 220 {in_.buttons += {.Toggle_Fly}}
	if tick > 220 && tick < 260 {in_.buttons += {.Jump}}
	return in_
}

// Simulates client and server with messages delayed by `delay` ticks each
// way; returns the final client and server states and the client's
// prediction stats.
@(private = "file")
simulate :: proc(
	client_world, server_world: ^World,
	delay: int,
	ticks: int,
) -> (
	client: Prediction,
	server: Player_State,
) {
	rules := RULES_DEFAULTS
	start := Player_State {
		position = {0.5, 1, 0.5},
	}
	prediction_init(&client, start)
	server = start
	queue: Input_Queue
	to_server := make([dynamic]struct {
			due: int,
			msg: Input,
		}, context.temp_allocator)
	to_client := make([dynamic]struct {
			due: int,
			msg: Own_Player,
		}, context.temp_allocator)
	for tick in 0 ..< ticks + 4 * delay + 8 {
		// Client: deliver due updates, then this tick's input (until the script ends).
		for len(to_client) > 0 && to_client[0].due <= tick {
			prediction_reconcile(&client, to_client[0].msg, &rules, query(client_world))
			ordered_remove(&to_client, 0)
		}
		if tick < ticks {
			msg := prediction_tick(&client, scripted_input(tick), &rules, query(client_world))
			append(&to_server, struct {
				due: int,
				msg: Input,
			}{tick + delay, msg})
		}
		// Server: receive due inputs, apply this tick's, answer.
		for len(to_server) > 0 && to_server[0].due <= tick {
			input_queue_push(&queue, to_server[0].msg)
			ordered_remove(&to_server, 0)
		}
		buf: [INPUT_BUDGET_MAX]Input
		for msg in input_queue_tick(&queue, &buf) {player_step(&server, msg.input, &rules, query(server_world), TICK_SECONDS)}
		append(&to_client, struct {
			due: int,
			msg: Own_Player,
		}{tick + delay, Own_Player{acked = queue.last, state = server}})
	}
	return
}

@(test)
test_prediction_agrees_with_server :: proc(t: ^testing.T) {
	w := make_world()
	defer delete(w.solid)
	for delay in ([]int{0, 1, 3, 9}) { 	// up to 300 ms each way
		client, server := simulate(&w, &w, delay, 300)
		testing.expectf(
			t,
			client.state == server,
			"delay %d: client %v, server %v",
			delay,
			client.state.position,
			server.position,
		)
		testing.expectf(
			t,
			client.corrections == 0,
			"delay %d: %d corrections with identical worlds",
			delay,
			client.corrections,
		)
		testing.expect(t, client.count == 0)
	}
	// The script really moved the player (jumped the step, flew).
	client, _ := simulate(&w, &w, 2, 300)
	testing.expect(t, client.state.position.x > 30)
}

@(test)
test_prediction_corrects_to_server :: proc(t: ^testing.T) {
	// The server has a wall the client doesn't know about: the client walks
	// through it in prediction, is corrected, and ends where the server is.
	cw := make_world()
	defer delete(cw.solid)
	sw := make_world()
	defer delete(sw.solid)
	for y in i32(1) ..= 4 {
		for z in i32(-40) ..= 40 {sw.solid[{15, y, z}] = true}
	}
	client, server := simulate(&cw, &sw, 3, 200)
	testing.expect(t, client.corrections > 0)
	testing.expect(t, client.state == server)
	testing.expect(t, server.position.x < 15) // stopped by the wall
}

@(test)
test_input_budget :: proc(t: ^testing.T) {
	// A client sending three inputs per tick still moves one per tick.
	q: Input_Queue
	applied := 0
	seq: u32 = 1
	for _ in 0 ..< 100 {
		for _ in 0 ..< 3 {
			input_queue_push(&q, Input{sequence = seq})
			seq += 1
		}
		buf: [INPUT_BUDGET_MAX]Input
		applied += len(input_queue_tick(&q, &buf))
	}
	testing.expectf(t, applied <= 101, "applied %d inputs in 100 ticks", applied)
	testing.expect(t, q.dropped > 0 || q.discarded > 0)
	// After a silence it catches up a little (jitter): two a tick, not four.
	q2: Input_Queue
	buf: [INPUT_BUDGET_MAX]Input
	for _ in 0 ..< 50 {input_queue_tick(&q2, &buf)}
	for i in 1 ..= 10 {input_queue_push(&q2, Input{sequence = u32(i)})}
	testing.expect_value(t, len(input_queue_tick(&q2, &buf)), 2)
	testing.expect(t, q2.catching_up)
	// Old or repeated sequence numbers are refused.
	testing.expect(t, !input_queue_push(&q2, Input{sequence = 3}))
	testing.expect(t, sequence_before_or_at(max(u32), 2)) // wraparound
}

// Inputs of one client sent one per tick, delivered late, bunched and out of
// order (seeded): the server applies one per tick, two only while it logs a
// catch-up, and acknowledges every input it applied.
@(test)
test_input_jitter_buffer :: proc(t: ^testing.T) {
	for seed in u64(1) ..= 20 {
		state := seed * 0x9E3779B97F4A7C15
		rnd :: proc(s: ^u64, n: u64) -> u64 {
			s^ = s^ * 6364136223846793005 + 1442695040888963407
			return (s^ >> 33) % n
		}
		Late :: struct {
			due: int,
			msg: Input,
		}
		inflight: [dynamic]Late
		defer delete(inflight)
		q: Input_Queue
		applied, last_seq := 0, u32(0)
		TICKS :: 600
		for tick in 0 ..< TICKS + 60 {
			if tick < TICKS {
				delay := int(rnd(&state, 3)) // 0..2 ticks of jitter
				if rnd(&state, 40) == 0 {delay += 6 + int(rnd(&state, 6))} 	// a hiccup
				append(&inflight, Late{tick + delay, Input{sequence = u32(tick + 1)}})
			}
			// Everything due arrives, in a shuffled order.
			for i := 0; i < len(inflight); {
				if inflight[i].due <= tick {
					j := int(rnd(&state, u64(len(inflight))))
					if inflight[j].due > tick {j = i}
					input_queue_push(&q, inflight[j].msg)
					unordered_remove(&inflight, j)
					i = 0
				} else {
					i += 1
				}
			}
			buf: [INPUT_BUDGET_MAX]Input
			got := input_queue_tick(&q, &buf)
			testing.expectf(
				t,
				len(got) <= 1 || (len(got) == 2 && q.catching_up),
				"seed %d tick %d: %d inputs applied, catching_up=%v",
				seed,
				tick,
				len(got),
				q.catching_up,
			)
			for m in got {
				testing.expect(t, sequence_before(last_seq, m.sequence), "applied out of order")
				last_seq = m.sequence
			}
			applied += len(got)
			testing.expect_value(t, q.last, max(q.last, last_seq))
			testing.expectf(
				t,
				applied + q.discarded <= tick + 1 + INPUT_BUDGET_MAX,
				"faster than the tick rate",
			)
		}
		testing.expectf(t, q.target <= INPUT_TARGET_MAX, "target %d", q.target)
	}
}

// A steady client (one input a tick, no jitter) is applied in the tick it
// arrives, with no buffering: what the stepped server relies on.
@(test)
test_input_buffer_steady_client :: proc(t: ^testing.T) {
	q: Input_Queue
	for tick in 1 ..= 200 {
		input_queue_push(&q, Input{sequence = u32(tick)})
		buf: [INPUT_BUDGET_MAX]Input
		got := input_queue_tick(&q, &buf)
		if !testing.expectf(
			t,
			len(got) == 1 && got[0].sequence == u32(tick),
			"tick %d: %v",
			tick,
			got,
		) {return}
	}
	testing.expect_value(t, q.target, 0)
	testing.expect_value(t, q.catchups, 0)
}

// A real stall: the backlog past the limit is given up (and counted), the
// acknowledgement jumps over it.
@(test)
test_input_buffer_stall :: proc(t: ^testing.T) {
	q: Input_Queue
	buf: [INPUT_BUDGET_MAX]Input
	for tick in 1 ..= 30 {
		input_queue_push(&q, Input{sequence = u32(tick)})
		input_queue_tick(&q, &buf)
	}
	for _ in 0 ..< 20 {input_queue_tick(&q, &buf)} 	// silence
	for i in 31 ..= 50 {input_queue_push(&q, Input{sequence = u32(i)})}
	input_queue_tick(&q, &buf)
	testing.expect_value(t, q.stalls, 1)
	testing.expect(t, q.discarded > 0)
	testing.expect(t, q.count <= INPUT_STALL_BACKLOG)
	testing.expect(t, q.last > 31) // acknowledged past what was discarded
}
