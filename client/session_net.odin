package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../common/game"
import "../common/netcode"
import "../server"

// A session's messages: what the server sends (receive), what we send
// (send_message), over the in-process pipe or the network link, with the
// network's statistics and the optional trace.

@(private)
receive :: proc(s: ^Session) {
	if s.remote {
		was := s.link.state
		netcode.link_update(&s.link, time.tick_now())
		if s.link.state == .Failed {
			fail(s, s.link.reason)
			return
		}
		if was != .Connected && s.link.state == .Connected {
			log.info("session connected")
			send_message(
				s,
				game.Hello {
					game.PROTOCOL_VERSION,
					s.config.key.account,
					s.config.name,
					s.schema.hash,
				},
			)
		}
		netcode.link_receive(&s.link, &s.received)
		for p in s.received {
			s.traffic[.Server].messages[p[0]] += 1
			s.traffic[.Server].bytes[p[0]] += len(p)
		}
	} else {
		game.receive(s.endpoint, &s.received)
	}
	defer {
		for p in s.received {
			if s.remote {netcode.link_free(&s.link, p)} else {game.packet_free(s.endpoint, p)}
		}
		clear(&s.received)
	}
	for p in s.received {
		if s.state == .Failed {return}
		s.stats.bytes_received += len(p)
		m, ok := game.decode_server(p, s.scratch, s.reg)
		if !ok {
			fail(s, "the server sent an invalid message")
			return
		}
		if s.state != .Playing {
			#partial switch _ in m {
			case game.Welcome,
			     game.Reject,
			     game.Pong,
			     game.Challenge,
			     game.Characters,
			     game.Packs,
			     game.Pack_Part,
			     game.Packs_Changed:
			case game.Snapshot_Message:
				continue // unreliable: it overtook the welcome (newer ones follow)
			case:
				kind := game.message_kind_name(.Server, p[0])
				fail(s, fmt.tprintf("the server sent %s before welcoming us", kind))
				return
			}
		}
		switch v in m {
		case game.Challenge:
			send_message(s, game.Proof{game.account_sign(&s.config.key, v.nonce)})
		case game.Packs:
			packs_begin(s, v)
		case game.Pack_Part:
			packs_part(s, v)
		case game.Packs_Changed:
			packs_changed(s, v)
		case game.Characters:
			for c in s.characters {delete(c)}
			clear(&s.characters)
			for name in strings.fields(v.names, context.temp_allocator) {
				append(&s.characters, strings.clone(name))
			}
			s.state = .Choosing
		case game.Welcome:
			welcome(s, v)
		case game.World_Changed:
			// Travelled: nothing of the last world stays; the arrival (a
			// teleport), the new world's chunks and entities follow.
			world_clear(&s.world)
			loading_begin(s, true)
			clear(&s.entities)
			clear(&s.edits)
			clear(&s.puffs)
			s.welcome.address = v.address
			s.place = {
				biome = game.NO_BIOME,
			}
			s.arrivals += 1
			s.rules = v.rules
			game.receiver_reset(&s.rx)
			rules := v.rules
			game.receiver_seed(&s.rx, int(game.State_Kind.Rules), &rules)
			inventory_predict(s) // (no placing waits now)
			log.infof("session travelled to=%s", game.address_dir(v.address))
		case game.Reject:
			fail(
				s,
				strings.concatenate({"the server refused: ", v.reason}, context.temp_allocator),
			)
		case game.Chunk_Message:
			if !world_set_chunk(&s.world, v, s.scratch) {
				fail(s, "the server sent more of the world than was asked for")
				return
			}
			s.stats.chunks_received += 1
		case game.Pong:
			if s.net.ping_pending && v.id == s.net.ping_id {
				s.net.rtt_ms = f32(time.duration_milliseconds(time.tick_since(s.net.ping_sent)))
				s.net.ping_pending = false
			}
		case game.Unload_Chunk:
			world_remove_chunk(&s.world, v.pos)
			s.stats.unloads += 1
		case game.State_Message:
			got := make([dynamic]game.Received, context.temp_allocator)
			if !game.receive_state(&s.rx, v.data, &got) {
				fail(s, "the server sent an invalid State message")
				return
			}
			apply_received(s, got[:])
		case game.Snapshot_Message:
			got := make([dynamic]game.Received, context.temp_allocator)
			if !game.receive_snapshot(&s.rx, v.data, &got) {
				fail(s, "the server sent an invalid Snapshot message")
				return
			}
			clock_heard(&s.render_clock, s.rx.tick)
			apply_received(s, got[:])
			// Everything still present and not in the delta is unchanged now.
			for _, &o in s.others {track_hold(&o.track, s.rx.tick)}
			for _, &e in s.entities {track_hold(&e.track, s.rx.tick)}
		case game.Telemetry_Ack:
		case game.Stats_Page:
			stats_data_take(&s.player_stats, v)
		case game.Bulk_Begin:
			world_bulk_begin(&s.world, int(v.count))
		case game.Edit_Result:
			// The server's word, accepted or not: set it (undoing a rejected
			// prediction) and stop waiting.
			world_set_block(&s.world, v.pos, v.block)
			for e, i in s.edits {
				if e.id == v.id {
					ordered_remove(&s.edits, i)
					break
				}
			}
			inventory_predict(s) // (a refused block is ours again)
		case game.Column:
			world_set_column(&s.world, v)
		}
	}
}

@(private)
welcome :: proc(s: ^Session, w: game.Welcome) {
	if s.state != .Connecting {
		fail(s, "the server welcomed us twice")
		return
	}
	if w.protocol != game.PROTOCOL_VERSION || w.tick_rate != game.TICK_RATE {
		fail(s, "the server runs a different version")
		return
	}
	if w.content != s.reg.hash {
		fail(s, content_mismatch(s.reg, w))
		return
	}
	s.welcome = w
	s.home = w.address
	s.place = {
		biome = game.NO_BIOME,
	}
	// Everything the server can send us at once: the interest area plus the
	// margin within which we keep chunks.
	r, h :=
		i32(w.view_radius) + game.CLIENT_DROP_MARGIN, i32(w.view_height) + game.CLIENT_DROP_MARGIN
	capacity := game.interest_count(r, h)
	columns := game.interest_count(r, 0)
	if err := world_init(
		&s.world,
		s.reg,
		capacity,
		columns,
		worker_count(),
		virtual.arena_allocator(&s.arena),
	); err != nil {
		fail(s, "out of memory for the world")
		return
	}
	s.world_init = true
	s.rules = w.rules
	rules := w.rules
	game.receiver_seed(&s.rx, int(game.State_Kind.Rules), &rules)
	game.prediction_init(&s.prediction, {position = w.spawn})
	s.camera = {
		position = w.spawn + {0, game.PLAYER_EYE, 0},
	}
	s.state = .Playing
	if t, ok := s.teleport.?; ok {send_message(s, t)} 	// (the server says no if it may not)
	log.infof("session joined view=%dx%d capacity=%d", w.view_radius, w.view_height, capacity)
}

// notice keeps a message from the server for the console.
@(private)
notice :: proc(s: ^Session, text: string) {
	plain := game.format_strip(text)
	log.info("session ", plain)
	append(&s.notices, strings.clone(plain))
	chat_add(s, 0, text)
}

// flush sends what is due over the network (about once per display frame
// at most: acknowledgements need not go out a thousand times a second).
@(private)
flush :: proc(s: ^Session) {
	if !s.remote {return}
	now := time.tick_now()
	if time.tick_diff(s.last_flush, now) < FLUSH_INTERVAL {return}
	s.last_flush = now
	netcode.link_flush(&s.link, now)
}

// session_trace starts recording every message to net.trace next to the
// executable (see netdump and replay in docs/debugging.md); our own world only
// (it records the pipe).
session_trace :: proc(s: ^Session) -> bool {
	if s.remote {
		log.warn("net trace records a world of your own (for a server: --capture)")
		return false
	}
	path := path_next_to_exe("net.trace")
	header := game.Trace_Header {
		protocol     = game.PROTOCOL_VERSION,
		seed         = s.config.seed,
		view_radius  = u32(s.config.view_radius),
		view_height  = u32(s.config.view_height),
		allow_cheats = true, // as session_start configures it
	}
	if !game.pipe_trace_start(&s.pipe, path, header) {
		log.errorf("net trace cannot write path=%s", path)
		return false
	}
	log.infof("net trace recording path=%s", path)
	return true
}

// net_update pings once a second and refreshes the per-second rates.
@(private)
net_update :: proc(s: ^Session, dt: f32) {
	n := &s.net
	n.ping_timer += dt
	if n.ping_timer >= 1 && !n.ping_pending && s.state == .Playing {
		n.ping_timer = 0
		n.ping_id += 1
		n.ping_sent = time.tick_now()
		n.ping_pending = true
		send_message(s, game.Ping{n.ping_id})
	}
	n.rate_timer += dt
	if n.rate_timer >= 1 {
		now := s.traffic if s.remote else game.pipe_traffic(&s.pipe)
		for side in game.Side {
			for k in 0 ..< 256 {
				n.rates[side].messages[k] = int(
					math.round(
						f32(now[side].messages[k] - n.last[side].messages[k]) / n.rate_timer,
					),
				)
				n.rates[side].bytes[k] = int(
					f32(now[side].bytes[k] - n.last[side].bytes[k]) / n.rate_timer,
				)
			}
		}
		n.last = now
		n.rate_timer = 0
	}
}

@(private)
fail :: proc(s: ^Session, reason: string) {
	log.errorf("session %s", reason)
	s.state = .Failed
	s.failure = strings.clone(reason, virtual.arena_allocator(&s.arena))
	if !s.remote && s.pipe.allocator.procedure != nil {game.close(s.endpoint)}
}

@(private)
send_message :: proc(s: ^Session, m: game.Client_Message) {
	// Text the server would refuse to decode (ending the connection).
	#partial switch v in m {
	case game.Command:
		if len(v.command) > game.MAX_ADMIN_TEXT {
			append(&s.notices, strings.clone("Command too long"))
			return
		}
	case game.Set_Rule:
		if len(v.name) > game.MAX_RULE_TEXT || len(v.value) > game.MAX_RULE_TEXT {
			append(&s.notices, strings.clone("Rule text too long"))
			return
		}
	}
	clear(&s.writer.buf)
	game.encode_client(&s.writer, m)
	data := s.writer.buf[:]
	if s.remote {
		s.traffic[.Client].messages[data[0]] += 1
		s.traffic[.Client].bytes[data[0]] += len(data)
		netcode.link_send(&s.link, data, game.message_reliable(.Client, data[0]))
	} else {
		game.send(s.endpoint, data)
	}
}

// send_prediction_check tells the server what the client predicted after input
// `sequence`, every DESYNC_CHECK_INPUTS inputs, so it can name a desync
// (docs/determinism.md). Nothing while a chunk around the player is missing:
// the prediction is then not on the world the server has.
send_prediction_check :: proc(s: ^Session, sequence: u32) {
	if sequence % game.DESYNC_CHECK_INPUTS != 0 {return}
	p := s.prediction.state.position
	centre := game.chunk_of({i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))})
	for dy in i32(-1) ..= 1 {
		for dz in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {
				if world_get(&s.world, centre + {dx, dy, dz}) == nil {return}
			}
		}
	}
	send_message(s, game.Prediction_Check{sequence, game.player_fields(s.prediction.state)})
}

// packs_changed: the server reloaded its packs (development builds). A player
// here, on the same machine, builds the same registry from the same files and
// checks its hash; the App swaps it in once the mesh jobs are done. Anyone
// else was sent away by the server (they get the packs when they join again).
@(private = "file")
packs_changed :: proc(s: ^Session, v: game.Packs_Changed) {
	if s.remote {
		fail(s, "the server reloaded its packs; join again")
		return
	}
	fresh := server.registry_for_dir(s.config.save_dir, base_dir = server.dev_base_dir())
	if fresh == nil {
		fail(s, "the reloaded packs do not load here; see the log")
		return
	}
	if fresh.hash != v.content {
		game.registry_destroy(fresh)
		fail(
			s,
			fmt.tprintf(
				"your game built different content from the same packs (content %016x vs %016x)",
				fresh.hash,
				v.content,
			),
		)
		return
	}
	if s.reg_fresh != nil {game.registry_destroy(s.reg_fresh)} 	// (a newer one came before the swap)
	s.reg_fresh = fresh
}

// content_mismatch: why a server whose registry is not ours (Welcome.content
// differs) cannot be played here: the packs it uses that this game lacks.
@(private = "file")
content_mismatch :: proc(reg: ^game.Registry, w: game.Welcome) -> string {
	missing := make([dynamic]string, context.temp_allocator)
	rest := w.packs
	for entry in strings.split_iterator(&rest, ",") {
		namespace, _, _ := strings.partition(entry, "@")
		have := false
		for p in reg.packs {
			if fmt.tprintf("%s@%s", p.namespace, p.version) == entry && p.namespace == namespace {
				have = true
			}
		}
		if !have {append(&missing, entry)}
	}
	if len(missing) == 0 {
		return "this server's content differs from this game's"
	}
	return fmt.tprintf(
		"this server uses content packs this game does not have: %s",
		strings.join(missing[:], ", ", context.temp_allocator),
	)
}

// packs_cache_dir: VX_PACKS, else voxiverse/packs in the user data directory
// (the packs of servers joined, by hash; game.pack_cache_store).
packs_cache_dir :: proc() -> string {
	if p, set := os.lookup_env("VX_PACKS", context.temp_allocator); set && p != "" {return p}
	dir, err := os.user_data_dir(context.temp_allocator)
	if err != nil {return ""}
	return filepath.join({dir, "voxiverse", "packs"}, context.temp_allocator) or_else ""
}

// packs_begin: the server's packs (a remote server only: our own universe's
// are read here): ask for those the cache lacks.
@(private = "file")
packs_begin :: proc(s: ^Session, p: game.Packs) {
	if !s.remote || s.fetching {
		fail(s, "the server sent its packs when it should not")
		return
	}
	s.fetch = new(game.Pack_Fetch)
	want, err := game.pack_fetch_begin(s.fetch, p, packs_cache_dir())
	s.fetching = true
	if err != "" {
		fail(s, err)
		return
	}
	log.infof("session packs announced=%d wanted=%d", p.count, want.count)
	send_message(s, want)
	packs_built(s)
}

@(private = "file")
packs_part :: proc(s: ^Session, part: game.Pack_Part) {
	if !s.fetching || s.fetched {
		fail(s, "the server sent a pack part we did not ask for")
		return
	}
	if err := game.pack_fetch_part(s.fetch, part); err != "" {
		fail(s, err)
		return
	}
	packs_built(s)
}

// packs_built: once every pack is held, the registry the base pack and these
// make, and the word that we have it.
@(private = "file")
packs_built :: proc(s: ^Session) {
	if s.state == .Failed || s.fetched || !game.pack_fetch_complete(s.fetch) {return}
	sources, errs := game.pack_fetch_sources(s.fetch)
	all := make([dynamic]game.Pack_Source, context.temp_allocator)
	append(&all, game.pack_source_sent(game.base_pack_source(context.temp_allocator)))
	append(&all, ..sources)
	reg: ^game.Registry
	if len(errs) == 0 {reg, errs = game.registry_build(all[:], .Client)}
	if reg == nil {
		lines := make([dynamic]string, context.temp_allocator)
		for e in errs[:min(len(errs), 5)] {append(&lines, game.pack_error_text(e))}
		fail(
			s,
			strings.concatenate(
				{
					"the server's packs do not load: ",
					strings.join(lines[:], "; ", context.temp_allocator),
				},
				context.temp_allocator,
			),
		)
		return
	}
	if reg.hash != s.fetch.content {
		game.registry_destroy(reg)
		fail(
			s,
			fmt.tprintf(
				"your game built different content from the same packs (content %016x vs %016x)",
				reg.hash,
				s.fetch.content,
			),
		)
		return
	}
	if s.reg_owned {game.registry_destroy(s.reg)}
	s.reg, s.reg_owned, s.reg_swapped, s.fetched = reg, true, true, true
	session_texels(s)
	game.receiver_destroy(&s.rx)
	game.receiver_init(&s.rx, &s.schema, s.reg)
	send_message(s, game.Packs_Ready{reg.hash})
}
