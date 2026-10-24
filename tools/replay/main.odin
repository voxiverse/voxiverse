package replay

import "core:flags"
import "core:log"
import "core:os"
import "core:time"

import "../../base"
import "../../game"
import "../../server"

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

main :: proc() {
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
	header, records, complete := game.trace_read(data)
	defer delete(records)
	if !complete {log.warnf("replay trace damaged or cut short; replaying what precedes it path=%s", opts.file)}
	if header.protocol != game.PROTOCOL_VERSION {
		log.errorf(
			"replay trace protocol=%d, this build speaks %d",
			header.protocol,
			game.PROTOCOL_VERSION,
		)
		return false
	}

	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	if !game.pipe_trace_start(
		&pipe,
		opts.out,
		header,
	) {log.warnf("replay cannot record path=%s", opts.out)}
	srv: server.Server
	config := server.Config {
		seed         = header.seed,
		view_radius  = i32(header.view_radius),
		view_height  = i32(header.view_height),
		workers      = 2,
		allow_cheats = header.allow_cheats,
	}
	if !server.start(&srv, config, {&pipe, .Server}) {return false}
	client := game.Endpoint{&pipe, .Client}

	key := game.account_key_make()
	challenge: Maybe(game.Nonce)
	scratch := new(game.Block_Array)
	defer free(scratch)
	sent, received := 0, 0
	start := time.tick_now()
	end: time.Duration
	incoming := make([dynamic]game.Packet)
	defer delete(incoming)
	drain :: proc(
		client: game.Endpoint,
		incoming: ^[dynamic]game.Packet,
		challenge: ^Maybe(game.Nonce),
		scratch: ^game.Block_Array,
	) -> int {
		n := game.receive(client, incoming)
		for p in incoming {
			if m, ok := game.decode_server(p, scratch); ok {
				if c, is := m.(game.Challenge); is {challenge^ = c.nonce}
			}
			game.packet_free(client, p)
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
		if m, ok := game.decode_client(r.data); ok {
			#partial switch v in m {
			case game.Hello:
				h := v
				h.account = key.account
				clear(&w.buf)
				game.encode_client(&w, h)
				message = w.buf[:]
			case game.Proof:
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
				game.encode_client(&w, game.Proof{game.account_sign(&key, nonce)})
				message = w.buf[:]
			}
		}
		game.send(client, message)
		sent += 1
		end = at
	}
	linger := time.Duration(opts.linger * f64(time.Second))
	for time.tick_since(start) < end + linger {
		received += drain(client, &incoming, &challenge, scratch)
		time.sleep(time.Millisecond)
	}
	disconnected := game.is_closed(client)
	server_ok := server.stop(&srv)
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
