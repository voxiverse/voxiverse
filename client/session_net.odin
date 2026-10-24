package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:time"

import "../base"
import "../game"
import "../netcode"
import "../worldgen"

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
			send_message(s, game.Hello{game.PROTOCOL_VERSION, s.config.name})
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
		m, ok := game.decode_server(p, s.scratch)
		if !ok {
			fail(s, "the server sent an invalid message")
			return
		}
		if s.state != .Playing {
			#partial switch _ in m {
			case game.Welcome, game.Reject, game.Pong:
			case game.Player_Update, game.Players, game.Entities, game.Time:
				continue // unreliable: it overtook the welcome (newer ones follow)
			case:
				kind := game.message_kind_name(.Server, p[0])
				fail(s, fmt.tprintf("the server sent %s before welcoming us", kind))
				return
			}
		}
		switch v in m {
		case game.Welcome:
			welcome(s, v)
		case game.Reject:
			fail(
				s,
				strings.concatenate({"the server refused: ", v.reason}, context.temp_allocator),
			)
		case game.Chunk_Message:
			if !world_set_chunk(&s.world, v, s.scratch) {
				fail(s, "too many chunks: the server sent more than its interest area")
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
		case game.Player_Update:
			// Over the network a teleport (sent reliably) may arrive after a
			// newer update: then only its direction still matters.
			if v.acked != 0 && game.sequence_before(v.acked, s.last_acked) {
				if v.teleported {s.camera.yaw, s.camera.pitch = v.yaw, v.pitch}
				continue
			}
			s.last_acked = v.acked
			game.prediction_reconcile(&s.prediction, v, &s.rules, {&s.world, world_block})
			if v.teleported {s.camera.yaw, s.camera.pitch = v.yaw, v.pitch}
		case game.Rules_Changed:
			s.rules = v.rules
		case game.Time:
			s.clock = v.time
		case game.Player_Joined:
			if o, known := s.others[v.player]; known {delete(o.name)} 	// a seat taken again
			s.others[v.player] = {
				name = strings.clone(v.name),
			}
		case game.Player_Left:
			if o, known := s.others[v.player]; known {
				delete(o.name)
			}
			delete_key(&s.others, v.player)
		case game.Players:
			if s.newest_at == {} || game.sequence_before(s.newest_tick, v.tick) {
				s.newest_tick, s.newest_at = v.tick, time.tick_now()
			}
			for i in 0 ..< v.count {
				e := v.entries[i]
				if o, known := &s.others[e.player]; known {other_snapshot(o, v.tick, e)}
			}
		case game.Blocks_Changed:
			// The world's own changes (flowing water): quietly.
			origin := game.chunk_origin(v.chunk)
			for i in 0 ..< v.count {
				e := v.entries[i]
				world_set_block(&s.world, origin + game.local_from_index(int(e.index)), e.block)
			}
		case game.Grants:
			for g in s.grants {delete(g.pattern)}
			clear(&s.grants)
			if !game.grants_parse(v.text, &s.grants) {log.warn("session grants not understood")}
			for c in s.commands {delete(c)}
			clear(&s.commands)
			for name in strings.fields(v.commands, context.temp_allocator) {
				append(&s.commands, strings.clone(name))
			}
		case game.Chat_Line:
			chat_add(s, v.id, v.text)
			log.info("session chat ", game.format_strip(v.text))
			append(&s.notices, strings.clone(game.format_strip(v.text)))
		case game.Chat_Delete:
			chat_delete(s, v.id)
		case game.Inventory_Update:
			inventory_reconcile(s, v)
		case game.Variables:
			s.has_worldgen = true
			for p in base.vars_read(worldgen.params_table(), &s.worldgen, v.text) {
				log.warnf("session variable not applied problem=%v text=%q", p.error, p.text)
			}
		case game.Notice:
			notice(s, v.text)
		case game.Bulk_Begin:
			world_bulk_begin(&s.world, int(v.count))
		case game.Explosion:
			explosion_effects(s, v.position, f64(v.radius))
		case game.Entity_Spawn:
			s.entities[v.entity] = {
				kind      = v.kind,
				stack     = v.stack,
				last_seen = v.position,
			}
			e := &s.entities[v.entity]
			track_add(&e.track, {tick = s.newest_tick, position = v.position, yaw = v.yaw})
		case game.Entities:
			if s.newest_at == {} || game.sequence_before(s.newest_tick, v.tick) {
				s.newest_tick, s.newest_at = v.tick, time.tick_now()
			}
			for i in 0 ..< v.count {
				x := v.entries[i]
				if e, known := &s.entities[x.entity]; known {
					track_add(&e.track, {v.tick, x.position, x.yaw, x.pitch, false})
				}
			}
		case game.Entity_Despawn:
			if e, known := &s.entities[v.entity]; known && v.died {
				entity_died(s, e)
			}
			delete_key(&s.entities, v.entity)
		case game.Entity_Hurt:
			if e, known := &s.entities[v.entity]; known {
				e.hurt_at = time.tick_now()
				append(&s.sounds, Sound_Event{.Entity_Hurt, .Air, e.last_seen + {0, 0.5, 0}, 1})
			}
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
		case game.Block_Changed:
			// Someone else's edit: heard where it happened.
			old, _ := world_block(&s.world, v.pos)
			if world_set_block(&s.world, v.pos, v.block) && old != v.block {
				edit_sound(s, v.pos, old, v.block)
			}
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
	s.welcome = w
	// Everything the server can send us at once: the interest area plus the
	// margin within which we keep chunks.
	r, h :=
		i32(w.view_radius) + game.CLIENT_DROP_MARGIN, i32(w.view_height) + game.CLIENT_DROP_MARGIN
	capacity := game.interest_count(r, h)
	columns := game.interest_count(r, 0)
	if err := world_init(
		&s.world,
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
// executable (see netdump and replay in DEBUGGING.md); our own world only
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
