package dedicated

import "core:fmt"
import "core:log"
import "core:math"
import "core:net"
import "core:os"
import "core:sync"
import "core:time"

import "../base"
import "../game"
import "../netcode"
import "../server"

// The `server` benchmark scenario (PLAN.md, M19; `build bench server`): the
// server alone, as players load it. A fresh scratch world (the client's
// scratch seed), listening on the loopback; BENCH_BOTS simulated players
// join over UDP (the real handshake, as a client does), go up, and fly
// straight out in their own directions, each streaming its own land. What
// arrives is decoded and dropped: nothing is drawn or meshed, so the times
// are the server's. After a warm-up, BENCH_MEASURE_SECONDS are measured: its
// ticks, streaming, chunk generation and column tops, bytes sent. Each of
// BENCH_REPETITIONS is a server of its own. No sheep (the same work every
// run). The worker count follows the machine (as a dedicated server's
// does): results compare on one machine.

BENCH_SCENARIO :: "server"
BENCH_VERSION :: 1
BENCH_REPETITIONS :: 3
BENCH_BOTS :: 8
BENCH_SEED :: 0x5eed // the client's scratch world (client SCRATCH_SEED)
BENCH_WARMUP_SECONDS :: 5
BENCH_MEASURE_SECONDS :: 30
BENCH_JOIN_TIMEOUT :: 30 // seconds
BENCH_ALTITUDE :: 80 // the bots fly at

Bot_Stage :: enum u8 {
	Connecting,
	Lifting, // the teleport up asked for, flying asked for
	Flying,
}

Bot :: struct {
	link:     netcode.Link,
	name:     string,
	key:      game.Account_Key,
	yaw:      f32, // its direction out
	scratch:  ^game.Block_Array,
	schema:   game.Schema,
	rx:       game.Receiver, // what the server says (its own player: Own_Player)
	messages: [dynamic][]u8,
	stage:    Bot_Stage,
	welcomed: bool,
	position: [3]f64, // the server's last word
	flying:   bool,
	seq:      u32,
	next:     time.Tick, // its next input (one a tick, as a client sends)
	asked:    bool, // the teleport and flying asked for
}

// run_benchmark runs the server scenario and writes its result.
// smoke: one short repetition, written as "server-smoke" (CI).
run_benchmark :: proc(scenario: string, smoke := false) -> bool {
	if scenario != BENCH_SCENARIO {
		log.errorf(
			"no benchmark scenario %q in the server (it has: %s; the game has the others)",
			scenario,
			BENCH_SCENARIO,
		)
		return false
	}
	result := base.Bench_Result {
		scenario = BENCH_SCENARIO,
		version  = BENCH_VERSION,
	}
	defer base.bench_result_destroy(&result)
	log.infof(
		"bench %s: %d players flying out of a fresh world over UDP (%d repetitions)",
		BENCH_SCENARIO,
		BENCH_BOTS,
		BENCH_REPETITIONS,
	)
	repetitions := 1 if smoke else BENCH_REPETITIONS
	if smoke {result.scenario = "server-smoke"}
	for rep in 0 ..< repetitions {
		bench_repetition(&result, smoke) or_return
		log.infof("bench %s repetition %d of %d done", BENCH_SCENARIO, rep + 1, repetitions)
	}
	append(&result.counts, base.Bench_Count{"players", BENCH_BOTS})
	path := base.bench_result_write(&result)
	if path == "" {
		log.error("bench could not write the result (run from the repository: build/ must exist)")
		return false
	}
	for m in base.Metric {
		medians := make([dynamic]f64, context.temp_allocator)
		for rep in result.repetitions {if rep[m].count > 0 {append(&medians, base.metric_value(m, rep[m]))}}
		if len(medians) == 0 {continue}
		info := base.METRIC_INFO[m]
		lo, hi := medians[0], medians[0]
		for v in medians {lo, hi = min(lo, v), max(hi, v)}
		log.infof(
			"bench %s %s %.3f %s (repetitions %.3f..%.3f)",
			BENCH_SCENARIO,
			info.name,
			base.median_of(medians[:]),
			info.unit,
			lo,
			hi,
		)
	}
	log.infof("bench %s result=%s", BENCH_SCENARIO, path)
	return true
}

// bench_repetition: one server, its players joining, warming up, measured.
@(private = "file")
bench_repetition :: proc(result: ^base.Bench_Result, smoke: bool) -> bool {
	config := server.Config {
		seed            = BENCH_SEED,
		view_radius     = 12,
		view_height     = 6,
		workers         = max(1, os.get_processor_core_count() / 2),
		everyone_cheats = true, // (the teleport up, flying)
		max_players     = BENCH_BOTS,
		listen          = true,
		port            = 0, // any free one
		name            = "benchmark",
		no_sheep        = true,
	}
	srv := new(server.Server)
	defer free(srv)
	if !server.start(srv, config, {}) {return false}
	stopped := false
	defer if !stopped {server.stop(srv)}
	for !sync.atomic_load(&srv.listening) {time.sleep(time.Millisecond)}
	port := srv.host.socket.port

	bots := new([BENCH_BOTS]Bot) // (each Link is large: not on the stack)
	defer free(bots)
	for &b, i in bots {
		b.name = fmt.aprintf("bot%d", i + 1)
		seed: [32]u8
		for k in 0 ..< 32 {seed[k] = u8(k * 13 + i * 101 + 7)}
		game.account_key_set(&b.key, seed[:])
		b.yaw = f32(i) * 2 * math.PI / BENCH_BOTS
		b.scratch = new(game.Block_Array)
		b.schema = game.game_schema()
		game.receiver_init(&b.rx, &b.schema)
		netcode.link_connect(&b.link, {net.IP4_Loopback, port}, "", time.tick_now())
	}
	defer for &b in bots {
		netcode.link_close(&b.link, "benchmark over")
		for p in b.messages {netcode.link_free(&b.link, p)}
		delete(b.messages)
		free(b.scratch)
		game.receiver_destroy(&b.rx)
		game.schema_destroy(&b.schema)
		delete(b.name)
	}

	// Joining: every bot in, up and flying.
	started := time.tick_now()
	for {
		pump(bots[:])
		all_flying := true
		for b in bots {all_flying &&= b.stage == .Flying}
		if all_flying {break}
		if time.duration_seconds(time.tick_since(started)) > BENCH_JOIN_TIMEOUT {
			log.errorf("bench the players never all got flying")
			return false
		}
		time.sleep(2 * time.Millisecond)
	}
	// Warm-up, then the measured part.
	phase := time.tick_now()
	warmup := 1.0 if smoke else f64(BENCH_WARMUP_SECONDS)
	measure := 3.0 if smoke else f64(BENCH_MEASURE_SECONDS)
	for time.duration_seconds(time.tick_since(phase)) < warmup {
		pump(bots[:])
		time.sleep(2 * time.Millisecond)
	}
	base.metrics_start()
	phase = time.tick_now()
	for time.duration_seconds(time.tick_since(phase)) < measure {
		pump(bots[:])
		time.sleep(2 * time.Millisecond)
	}
	base.bench_repetition_end(result)
	stopped = true
	return server.stop(srv)
}

// pump: each bot's network in and out, its messages handled, its input sent
// when one is due.
@(private = "file")
pump :: proc(bots: []Bot) {
	now := time.tick_now()
	for &b in bots {
		was := b.link.state
		netcode.link_update(&b.link, now)
		if was != .Connected && b.link.state == .Connected {
			send(&b, game.Hello{game.PROTOCOL_VERSION, b.key.account, b.name, b.schema.hash})
		}
		netcode.link_receive(&b.link, &b.messages)
		for p in b.messages {
			defer netcode.link_free(&b.link, p)
			m, ok := game.decode_server(p, b.scratch)
			if !ok {continue}
			#partial switch v in m {
			case game.Challenge:
				send(&b, game.Proof{game.account_sign(&b.key, v.nonce)})
			case game.Characters:
				send(&b, game.Choose{b.name})
			case game.Welcome:
				b.welcomed = true
				rules := v.rules
				game.receiver_seed(&b.rx, int(game.State_Kind.Rules), &rules)
			case game.State_Message, game.Snapshot_Message:
				got := make([dynamic]game.Received, context.temp_allocator)
				#partial switch s in m {
				case game.State_Message:
					game.receive_state(&b.rx, s.data, &got)
				case game.Snapshot_Message:
					game.receive_snapshot(&b.rx, s.data, &got)
				}
				for g in got {
					if g.op != .Event && game.State_Kind(g.kind) == .Own_Player {
						own := (^game.Own_Player)(g.value)
						b.position, b.flying = own.state.position, own.state.flying
					}
				}
			case game.Reject:
				log.errorf("bench %s refused: %s", b.name, v.reason)
			}
		}
		clear(&b.messages)
		if b.welcomed && time.tick_diff(b.next, now) >= 0 {
			b.next = time.tick_add(now, game.TICK_DURATION)
			bot_input(&b)
		}
		netcode.link_flush(&b.link, now)
	}
}

// bot_input: up (a teleport, flying), then straight out.
@(private = "file")
bot_input :: proc(b: ^Bot) {
	input := game.Player_Input {
		yaw = b.yaw,
	}
	switch b.stage {
	case .Connecting:
		if !b.asked {
			x, z := b.position.x, b.position.z
			send(b, game.Command{fmt.tprintf("tp %.1f %d %.1f", x, BENCH_ALTITUDE, z)})
			input.buttons = {.Toggle_Fly}
			b.asked = true
		}
		b.stage = .Lifting
	case .Lifting:
		if b.flying && b.position.y >= BENCH_ALTITUDE - 1 {b.stage = .Flying}
	case .Flying:
		input.move = {0, 1}
		input.buttons = {.Sprint}
	}
	b.seq += 1
	send(b, game.Input{b.seq, input, b.rx.ack})
}

@(private = "file")
send :: proc(b: ^Bot, m: game.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.encode_client(&w, m)
	netcode.link_send(&b.link, w.buf[:], game.message_reliable(.Client, w.buf[0]))
}
