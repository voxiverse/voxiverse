package server

import "core:log"
import "core:time"

import "../game"
import "../netcode"

// Players: joining (welcomed where they left off), simulating their inputs
// each tick, telling them about each other, and leaving or being sent away.

// join: a client said hello with a free name. It is welcomed where it left
// off (in a saved world) or at the world spawn, introduced to the others and
// they to it.
@(private)
join :: proc(s: ^Server, c: ^Client, name: string) {
	c.state = .Playing
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
	if has_saved {
		// Where they left, looking where they looked, carrying what they carried.
		c.player = saved.state
		c.look = saved.look
		c.inventory = saved.inventory
		for st in saved.overflow {
			if !game.stack_empty(
				st,
			) {spawn_item(w, saved.state.position + {0, 0.5, 0}, st, {}, -1)}
		}
		land(s, c, saved.state.position, c.look, .Exact, remember = false)
	} else {
		land_at_spawn(s, c, remember = false)
	}
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
		},
	)
	send_message(s, c, game.Time{w.clock})
	refresh_grants(s, c) // what they may do
	if !has_saved {give_kit(s, c)} 	// (as their grants allow)
	c.inv_changed = true
	c.chat_tokens, c.chat_tick = CHAT_BURST, s.tick
	if m, ok := worldgen_variables(w); ok {send_message(s, c, m)}
	for &other in s.clients {
		if &other == c || other.state != .Playing {continue}
		send_message(s, c, game.Player_Joined{player_id(s, &other), client_name(&other)})
		send_message(s, &other, game.Player_Joined{player_id(s, c), name})
		if other.worn_sent != {} {
			send_message(s, c, game.Player_Worn{player_id(s, &other), other.worn_sent})
		}
	}
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
	record(s, c, .Session_End, n0 = i64((s.tick - c.joined_tick) / game.TICK_RATE))
	keep_player(s, c)
	chat_system(s, game.format_join({display_name(s, c), "&e left"}))
	member_get(&s.community, client_name(c)).seen = now_unix()
	for &other in s.clients {
		if &other != c && other.state == .Playing {
			send_message(s, &other, game.Player_Left{player_id(s, c)})
		}
	}
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
	query := game.Block_Query{&w.chunks, chunks_block}
	run_due_actions(s, c) // after inputs applied in earlier ticks
	waiting := landing_tick(s, c)
	for msg in game.input_queue_tick(&c.inputs, &buf) {
		held := c.player
		game.player_step(
			&c.player,
			msg.input,
			&w.rules,
			query,
			game.TICK_SECONDS,
			game.derive_mods(&c.inventory),
		)
		if c.afk && msg.input.move != {} {set_afk(s, c, false)} 	// back
		if waiting {
			// Held still until the blocks are there (a toggle still takes).
			c.player.position, c.player.velocity = held.position, {}
		}
		c.look = {msg.input.yaw, msg.input.pitch}
		run_due_actions(s, c)
	}
	set_position(c, c.player.position)
	update := game.Player_Update {
		acked      = c.inputs.last,
		state      = c.player,
		teleported = c.teleported,
		yaw        = c.teleport[0],
		pitch      = c.teleport[1],
	}
	// A teleport must arrive (the player is told where to look); the rest
	// are states, the newest of which wins.
	send_message(s, c, update, reliable = c.teleported)
	c.teleported = false
}

// send_players tells a client where the other players near it are.
@(private)
send_players :: proc(s: ^Server, c: ^Client) {
	m := game.Players {
		tick = u32(s.tick),
	}
	near := f64((s.config.view_radius + 1) * game.CHUNK_SIZE)
	for &other in s.clients {
		if &other == c || other.state != .Playing || other.world != c.world {continue}
		d := other.player.position - c.player.position
		if d.x * d.x + d.z * d.z > near * near {continue}
		m.entries[m.count] = {
			player   = player_id(s, &other),
			position = other.player.position,
			yaw      = other.look[0],
			pitch    = other.look[1],
			flying   = other.player.flying,
			crouched = other.player.crouched,
		}
		m.count += 1
	}
	if m.count > 0 {send_message(s, c, m)}
}

// disconnect refuses a client (a protocol error is the client's bug or an
// attack; either way it is logged): it is told why, then dropped.
@(private)
disconnect :: proc(s: ^Server, c: ^Client, reason: string) {
	log.warnf("server disconnecting client player=%d reason=%q", player_id(s, c), reason)
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
