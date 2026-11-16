package replay

import "core:flags"
import "core:log"
import "core:os"
import "core:time"

import "common:access"
import "common:base"
import "common:game"
import platform "common:platform"
import "common:protocol"
import games "generated:games"
import "server:core"

// replay feeds the client's messages from a network trace to a fresh server
// (same seed and view distance, same timing), so whatever the server did
// with them happens again outside the game: an assert, a crash, a
// disconnect, a hang. The server's answers are recorded to a new trace for
// comparing with netdump. The recorded Proof signed another server's
// challenge (it is good for that one only): replay joins as an account of
// its own, its Hello carrying it and its Proof signing this server's.
//
//	build replay                       build/net.trace -> build/replay.trace
//	build replay -speed:4 some.trace   four times faster

Options :: struct {
	file:   string `args:"pos=0" usage:"trace to replay (default build/net.trace)"`,
	out:    string `usage:"trace of the replay (default build/replay.trace)"`,
	speed:  f64 `usage:"time factor (2 = twice as fast)"`,
	linger: f64 `usage:"seconds to keep the server running after the last message"`,
}

// base_registry: what block and item numbers in a recording mean.
base_registry: ^game.Registry

main :: proc() {
	base_registry = game.registry_base()
	host: base.Host
	platform.boot(&host)
	dbg: base.Debug
	context = base.debug_begin(&dbg, "replay.log", "replay")
	opts := Options {
		file   = "build/net.trace",
		out    = "build/replay.trace",
		speed  = 1,
		linger = 1,
	}
	flags.parse_or_exit(&opts, os.args, .Odin)
	ok := run(opts)
	ok = base.debug_end(&dbg) && ok
	os.exit(0 if ok else 1)
}

run :: proc(opts: Options) -> bool {
	data, err := os.read_entire_file_from_path(opts.file, context.allocator)
	if err != nil {
		log.errorf("replay cannot read path=%s error=%v", opts.file, err)
		return false
	}
	defer delete(data)
	header, records, complete := protocol.trace_read(data)
	defer delete(records)
	if !complete {log.warnf("replay trace damaged or cut short; replaying what precedes it path=%s", opts.file)}
	if header.protocol != protocol.PROTOCOL_VERSION {
		log.errorf(
			"replay trace protocol=%d, this build speaks %d",
			header.protocol,
			protocol.PROTOCOL_VERSION,
		)
		return false
	}

	pipe: protocol.Pipe
	protocol.pipe_init(&pipe)
	defer protocol.pipe_destroy(&pipe)
	if !protocol.pipe_trace_start(
		&pipe,
		opts.out,
		header,
	) {log.warnf("replay cannot record path=%s", opts.out)}
	srv: core.Server
	config := core.Config {
		seed         = header.seed,
		view_radius  = i32(header.view_radius),
		view_height  = i32(header.view_height),
		workers      = 2,
		allow_cheats = header.allow_cheats,
		game         = trace_game(records[:]),
	}
	if !core.start(&srv, config, {&pipe, .Server}) {return false}
	client := protocol.Endpoint{&pipe, .Client}

	key := access.account_key_make()
	challenge: Maybe(access.Nonce)
	scratch := new(game.Block_Array)
	defer free(scratch)
	sent, received := 0, 0
	start := time.tick_now()
	end: time.Duration
	incoming := make([dynamic]protocol.Packet)
	defer delete(incoming)
	drain :: proc(
		client: protocol.Endpoint,
		incoming: ^[dynamic]protocol.Packet,
		challenge: ^Maybe(access.Nonce),
		scratch: ^game.Block_Array,
	) -> int {
		n := protocol.receive(client, incoming)
		for p in incoming {
			if m, ok := protocol.decode_server(p, scratch, base_registry); ok {
				if c, is := m.(protocol.Challenge); is {challenge^ = c.nonce}
			}
			protocol.packet_free(client, p)
		}
		clear(incoming)
		return n
	}
	w: game.Writer
	game.writer_init(&w)
	defer game.writer_destroy(&w)
	for r in records {
		if r.sender != .Client {continue}
		at := time.Duration(f64(r.time) / opts.speed)
		for time.tick_since(start) < at {
			received += drain(client, &incoming, &challenge, scratch)
			time.sleep(time.Millisecond)
		}
		message := r.data
		if m, ok := protocol.decode_client(r.data, base_registry); ok {
			#partial switch v in m {
			case protocol.Hello:
				h := v
				h.account = key.account
				clear(&w.buf)
				protocol.encode_client(&w, h)
				message = w.buf[:]
			case protocol.Proof:
				// This server's challenge, signed (it may take a moment).
				deadline := time.tick_add(time.tick_now(), 5 * time.Second)
				for challenge == nil && time.tick_diff(time.tick_now(), deadline) > 0 {
					received += drain(client, &incoming, &challenge, scratch)
					time.sleep(time.Millisecond)
				}
				nonce, got := challenge.?
				if !got {
					log.error("replay the server sent no challenge")
					break
				}
				clear(&w.buf)
				protocol.encode_client(&w, protocol.Proof{access.account_sign(&key, nonce)})
				message = w.buf[:]
			}
		}
		protocol.send(client, message)
		sent += 1
		end = at
	}
	linger := time.Duration(opts.linger * f64(time.Second))
	for time.tick_since(start) < end + linger {
		received += drain(client, &incoming, &challenge, scratch)
		time.sleep(time.Millisecond)
	}
	disconnected := protocol.is_closed(client)
	server_ok := core.stop(&srv)
	received += drain(client, &incoming, &challenge, scratch)
	log.infof(
		"replay done sent=%d received=%d disconnected=%v server_ok=%v out=%s",
		sent,
		received,
		disconnected,
		server_ok,
		opts.out,
	)
	if disconnected {log.error("replay the server disconnected the client (see its warning above)")}
	return server_ok && !disconnected
}

// trace_game: the game the traced session played (its Welcome's), with its rules, so the
// replay runs them again; a game this build lacks replays as the default one.
trace_game :: proc(records: []protocol.Trace_Record) -> core.Game {
	scratch := new(game.Block_Array)
	defer free(scratch)
	played := protocol.trace_game(records, scratch, base_registry)
	fallback := core.Game{}
	for g in games.SERVER {
		if g.id == played {return g}
		if g.id == game.DEFAULT_GAME {fallback = g}
	}
	if played !=
	   "" {log.warnf("replay trace plays %s, a game this build lacks; replaying %s", played, fallback.id)}
	return fallback
}
