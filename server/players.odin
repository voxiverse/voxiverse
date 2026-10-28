package server

import "core:log"
import "core:time"

import "../base"
import "../common/game"
import "../common/netcode"

// Players: joining (welcomed where they left off), simulating their inputs
// each tick, telling them about each other, and leaving or being sent away.

// join: a client said hello with a free name. It is welcomed where it left
// off (in a saved world) or at the world spawn, introduced to the others and
// they to it.
@(private)
join :: proc(s: ^Server, c: ^Client, name: string) {
	c.state = .Playing
	game.sender_init(&c.tx, &s.schema)
	c.name_len = copy(c.name_buf[:], name)
	saved, has_saved := player_record(s, name)
	c.joined_tick = s.tick
	if has_saved {
		c.stats = counters_clone(saved.stats)
		// (read from its file just now, not kept in the store: ours to free)
		if _, kept := s.store.players[name]; !kept {counters_free(&saved.stats)}
	}
	// In the world they left (loaded again if it was not), else the home world.
	c.world = s.home
	if a, elsewhere := saved.world.?; has_saved && elsewhere {
		if w := world_load(s, a); w != nil {c.world = w}
	}
	w := c.world
	disturb(s, c)
	if has_saved {
		// Where they left, looking where they looked, carrying what they carried.
		c.player = saved.state
		c.look = saved.look
		c.inventory = saved.inventory
		ledger_inventory(s, w, .Scope_In, &c.inventory)
		for st in saved.overflow {
			if !game.stack_empty(st) {
				ledger_stack(s, w, .Spill_Old, st)
				spawn_item(w, saved.state.position + {0, 0.5, 0}, st, {}, -1)
			}
		}
		land(s, c, saved.state.position, c.look, .Exact, remember = false)
	} else {
		land_at_spawn(s, c, remember = false)
	}
	mode := mode_default(s, w)
	if has_saved {
		if m, ok := game.mode_find(s.registry, base.var_text(&saved.mode));
		   ok && saved.mode.len > 0 {mode = m}
	}
	set_game_mode(s, c, mode, {"join", ""})
	send_message(
		s,
		c,
		game.Welcome {
			protocol = game.PROTOCOL_VERSION,
			tick_rate = game.TICK_RATE,
			player = player_id(s, c),
			spawn = c.player.position,
			view_radius = u32(s.config.view_radius),
			view_height = u32(s.config.view_height),
			rules = w.rules,
			address = w.address,
			content = s.registry.hash,
			packs = packs_text(s.registry),
		},
	)
	replica_seed(s, c) // (the rules came with the Welcome)
	c.clock_pending = true
	refresh_grants(s, c) // what they may do
	if !has_saved { 	// (as their grants allow)
		give_kit(s, c) // the world's
		kit_give(s, c) // and the mode's (survival: the weapons)
	}
	c.inv_changed = true
	c.chat_tokens, c.chat_tick = CHAT_BURST, s.tick
	if m, ok := worldgen_variables(w); ok {state_put(s, c, .Variables, &m)}
	log.infof("server player joined player=%d name=%q", player_id(s, c), name)
	online := 0
	for &other in s.clients {if other.state == .Playing {online += 1}}
	record(s, c, .Session_Start, n0 = i64(online))
	chat_system(s, game.format_join({display_name(s, c), "&e joined"}))
	m := member_get(&s.community, name)
	m.seen = now_unix()
	if c.address != "" {set_string(&m.ip, c.address)}
	if s.community.motd != "" {notice(s, c, s.community.motd)}
}

// leave: a client is gone (left, timed out or was dropped): its player is
// kept for the save and the others are told.
@(private)
leave :: proc(s: ^Server, c: ^Client, reason: string) {
	farewell(s, c, reason)
	if p, ok := c.link.(netcode.Peer_Id);
	   ok {netcode.host_kick(&s.host, p, reason, time.tick_now())}
	client_reset(c)
}

// farewell: a playing client's player is kept for the save, and the others
// are told it left.
@(private)
farewell :: proc(s: ^Server, c: ^Client, reason: string) {
	if c.state != .Playing {return}
	respawn(s, c) // (leaving at the death screen: kept alive, at the spawn)
	record(s, c, .Session_End, n0 = i64((s.tick - c.joined_tick) / game.TICK_RATE))
	ledger_inventory(s, c.world, .Scope_Out, &c.inventory)
	keep_player(s, c)
	chat_system(s, game.format_join({display_name(s, c), "&e left"}))
	member_get(&s.community, client_name(c)).seen = now_unix()
	log.infof(
		"server player left player=%d name=%q reason=%s",
		player_id(s, c),
		client_name(c),
		reason,
	)
}

// simulate_player applies this tick's inputs and tells the client where
// its player is.
@(private)
simulate_player :: proc(s: ^Server, c: ^Client) {
	w := c.world
	buf: [game.INPUT_BUDGET_MAX]game.Input
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks}
	run_due_actions(s, c) // after inputs applied in earlier ticks
	if c.inv_changed {disturb(s, c)} 	// (the mods its gear gives)
	waiting := landing_tick(s, c)
	for msg in game.input_queue_tick(&c.inputs, &buf) {
		held := c.player
		input := msg.input
		if c.dead { 	// (at the death screen: standing still, as the client's prediction does)
			input = {
				yaw   = input.yaw,
				pitch = input.pitch,
			}
		}
		game.player_step(
			&c.player,
			input,
			&w.rules,
			query,
			game.TICK_SECONDS,
			character_mods(s, c),
		)
		if c.afk && msg.input.move != {} {set_afk(s, c, false)} 	// back
		if waiting {
			// Held still until the blocks are there (a toggle still takes).
			c.player.position, c.player.velocity = held.position, {}
		}
		c.look = {msg.input.yaw, msg.input.pitch}
		if waiting {disturb(s, c)}
		check_judge(s, c, msg.sequence)
		run_due_actions(s, c)
	}
	if c.inputs.discarded_now > 0 {
		log.warnf(
			"server input stall player=%d discarded=%d acked=%d target=%d",
			player_id(s, c),
			c.inputs.discarded_now,
			c.inputs.last,
			c.inputs.target,
		)
	} else if c.inputs.catching_up {
		log.debugf(
			"server input catch-up player=%d acked=%d target=%d",
			player_id(s, c),
			c.inputs.last,
			c.inputs.target,
		)
	}
	set_position(c, c.player.position)
	if c.teleported {c.teleports += 1}
	own := game.Own_Player {
		acked     = c.inputs.last,
		state     = c.player,
		teleports = c.teleports,
		yaw       = c.teleport[0],
		pitch     = c.teleport[1],
	}
	// (a snapshot record keeps being sent until one holding it is acknowledged:
	// a teleport arrives, and the newest state wins)
	state_put(s, c, .Own_Player, &own)
	c.teleported = false
}

// players_put tells a client who else is in its world (their names and what
// they wear) and where the ones near it are.
@(private)
players_put :: proc(s: ^Server, c: ^Client) {
	near := f64((s.config.view_radius + 1) * game.CHUNK_SIZE)
	for &other in s.clients {
		if &other == c || other.state != .Playing || other.world != c.world {continue}
		id := player_id(s, &other)
		record := game.Player_Record {
			name = client_name(&other),
			worn = game.worn_of(&other.inventory),
		}
		state_put(s, c, .Player, &record, game.key_player(id))
		d := other.player.position - c.player.position
		if d.x * d.x + d.z * d.z > near * near {continue}
		motion := game.Player_Motion {
			position = other.player.position,
			yaw      = other.look[0],
			pitch    = other.look[1],
			flying   = other.player.flying,
			crouched = other.player.crouched,
		}
		state_put(s, c, .Player_Motion, &motion, game.key_player(id))
	}
}

// disconnect refuses a client (a protocol error is the client's bug or an
// attack; either way it is logged): it is told why, then dropped.
@(private)
disconnect :: proc(s: ^Server, c: ^Client, reason: string) {
	log.warnf("server disconnecting client player=%d reason=%q", player_id(s, c), reason)
	replica_flush(s, c) // (what was said before, a notice of why, still arrives)
	send_message(s, c, game.Reject{reason})
	switch l in c.link {
	case Local:
		game.close(s.local)
		leave(s, c, reason)
		c.state = .Gone // the pipe is closed: this seat stays shut
	case netcode.Peer_Id:
		// The Reject goes out with the next flushes; the connection ends after.
		farewell(s, c, reason)
		c.state = .Gone
		c.kick_at = s.tick + KICK_DELAY
		c.kick_reason = reason
	}
}

// kick_due drops refused remote clients whose Reject has had time to go.
@(private)
kick_due :: proc(s: ^Server) {
	for &c in s.clients {
		if c.state == .Gone && c.kick_at != 0 && s.tick >= c.kick_at {
			leave(s, &c, c.kick_reason)
		}
	}
}
