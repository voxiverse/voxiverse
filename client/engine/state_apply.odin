package engine

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"

import "common:access"
import "common:base"
import "common:game"
import "common:protocol"
import "common:worldgen"

// What the server's State and Snapshot messages do to the session: the
// receiver decodes them into records and events (common/protocol/replica.odin), and one
// table says what each kind of record does here, a switch what each event does; the
// game's kinds go to its received hook (game.odin).

@(private)
Apply_Proc :: proc(s: ^Session, g: protocol.Received)

@(private, rodata)
APPLY := [protocol.State_Kind]Apply_Proc {
	.Own_Player    = apply_own_player,
	.Health        = apply_health,
	.Mode          = apply_mode,
	.Inventory     = apply_inventory,
	.Rules         = apply_rules,
	.Clock         = apply_clock,
	.Grants        = apply_grants,
	.Variables     = apply_variables,
	.Selection     = apply_selection,
	.Player        = apply_player,
	.Player_Motion = apply_player_motion,
	.Entity        = apply_entity,
	.Entity_Motion = apply_entity_motion,
	.Block         = apply_block,
	.Place         = apply_place,
	.Tally         = apply_tally,
	.Channel       = apply_channel,
	.Island        = apply_island,
	.Machine       = apply_machine,
	.Belt          = apply_belt,
}

// apply_received does what a message's records and events say, in order.
@(private)
apply_received :: proc(s: ^Session, got: []protocol.Received) {
	for g in got {
		if g.kind >= s.schema.engine { 	// the game's (game.odin)
			if s.game.received != nil {s.game.received(s, g)}
			continue
		}
		if g.op == .Event {
			apply_event(s, g)
		} else {
			APPLY[protocol.State_Kind(g.kind)](s, g)
		}
	}
}

@(private)
apply_own_player :: proc(s: ^Session, g: protocol.Received) {
	v := (^protocol.Own_Player)(g.value)^
	teleported := v.teleports != s.teleports
	s.teleports = v.teleports
	s.last_acked = v.acked
	protocol.prediction_reconcile(
		&s.prediction,
		v,
		&s.rules,
		{&s.world, world_block, &s.reg.blocks, {}},
		game.derive_character(s.reg, s.mode, &s.inventory),
		teleported,
	)
	if teleported {s.camera.yaw, s.camera.pitch = v.yaw, v.pitch}
}

@(private)
apply_mode :: proc(s: ^Session, g: protocol.Received) {
	if m, ok := game.mode_find(s.reg, (^protocol.Mode_Record)(g.value).mode); ok {s.mode = m}
}

@(private)
apply_health :: proc(s: ^Session, g: protocol.Received) {
	h := (^protocol.Health)(g.value)
	if !h.dead && !s.dead && s.max_health > 0 && h.health > s.health {
		game_seen(s, Seen_Heal{h.health - s.health}) // (not a respawn, nor the first word)
	}
	s.health, s.max_health, s.dead = h.health, h.max, h.dead
}

@(private)
apply_place :: proc(s: ^Session, g: protocol.Received) {
	s.place = (^protocol.Place)(g.value)^
}

@(private)
apply_inventory :: proc(s: ^Session, g: protocol.Received) {
	inventory_reconcile(s, (^protocol.Inventory_State)(g.value)^)
}

@(private)
apply_rules :: proc(s: ^Session, g: protocol.Received) {
	s.rules = (^game.Rules)(g.value)^
}

@(private)
apply_clock :: proc(s: ^Session, g: protocol.Received) {
	c := (^protocol.Clock)(g.value)
	// the anchor is the time at its tick; this message is of s.rx.tick
	behind := f64(s.rx.tick - c.tick) * f64(game.TICK_SECONDS)
	s.clock = game.advance_time(c.time, max(behind, 0), &s.rules)
}

@(private)
apply_grants :: proc(s: ^Session, g: protocol.Received) {
	v := (^protocol.Grants)(g.value)
	for gr in s.grants {delete(gr.pattern)}
	clear(&s.grants)
	if !access.grants_parse(v.text, &s.grants) {log.warn("session grants not understood")}
	for c in s.commands {delete(c)}
	clear(&s.commands)
	for name in strings.fields(v.commands, context.temp_allocator) {
		append(&s.commands, strings.clone(name))
	}
}

@(private)
apply_variables :: proc(s: ^Session, g: protocol.Received) {
	s.has_worldgen = true
	for p in base.vars_read(worldgen.params_table(), &s.worldgen, (^protocol.Variables)(g.value).text) {
		log.warnf("session variable not applied problem=%v text=%q", p.error, p.text)
	}
}

@(private)
apply_selection :: proc(s: ^Session, g: protocol.Received) {
	s.selection = (^protocol.Selection)(g.value).corners // (drawn: camera.odin)
}

@(private)
apply_island :: proc(s: ^Session, g: protocol.Received) {
	s.island = (^protocol.Island)(g.value)^
}

@(private)
apply_player :: proc(s: ^Session, g: protocol.Received) {
	id := u16(g.key.a)
	if g.op == .Remove {
		if o, known := s.others[id]; known {delete(o.name)}
		delete_key(&s.others, id)
		return
	}
	v := (^protocol.Player_Record)(g.value)
	if o, known := &s.others[id]; known && g.op == .Change {
		if o.name != v.name {
			delete(o.name)
			o.name = strings.clone(v.name)
		}
		o.worn = v.worn
		o.held = v.held
		o.kills, o.deaths = v.kills, v.deaths
		return
	}
	if o, known := s.others[id]; known {delete(o.name)} 	// a seat taken again
	s.others[id] = {
		name   = strings.clone(v.name),
		worn   = v.worn,
		held   = v.held,
		kills  = v.kills,
		deaths = v.deaths,
	}
	// its motion may have arrived first (the lanes are not ordered together)
	if m := protocol.receiver_snapshot_get(&s.rx, int(protocol.State_Kind.Player_Motion), g.key);
	   m != nil {
		other_snapshot(&s.others[id], s.rx.tick, (^protocol.Player_Motion)(m)^)
	}
}

@(private)
apply_tally :: proc(s: ^Session, g: protocol.Received) {
	s.tally = (^protocol.Tally)(g.value)^
}

@(private)
apply_player_motion :: proc(s: ^Session, g: protocol.Received) {
	if g.op == .Remove {return}
	if o, known := &s.others[u16(g.key.a)]; known {
		other_snapshot(o, s.rx.tick, (^protocol.Player_Motion)(g.value)^)
	}
}

@(private)
apply_entity :: proc(s: ^Session, g: protocol.Received) {
	id := u32(g.key.a)
	if g.op == .Remove {
		delete_key(&s.entities, id)
		return
	}
	v := (^protocol.Entity_Record)(g.value)
	if e, known := &s.entities[id]; known && g.op == .Change {
		if v.health < e.health {e.lost += e.health - v.health}
		e.kind, e.stack, e.health, e.max_health = v.kind, v.stack, v.health, v.max_health
		e.team, e.vision = v.team, v.vision
		return
	}
	if info := game.kind_info(s.reg, v.kind);
	   info != nil && info.hittable {journal_meet(s, v.kind)}
	s.entities[id] = {
		kind       = v.kind,
		stack      = v.stack,
		health     = v.health,
		max_health = v.max_health,
		team       = v.team,
		vision     = v.vision,
	}
	if m := protocol.receiver_snapshot_get(&s.rx, int(protocol.State_Kind.Entity_Motion), g.key);
	   m != nil {
		entity_snapshot(&s.entities[id], s.rx.tick, (^protocol.Entity_Motion)(m)^)
	}
}

@(private)
apply_entity_motion :: proc(s: ^Session, g: protocol.Received) {
	if g.op == .Remove {return}
	if e, known := &s.entities[u32(g.key.a)]; known {
		entity_snapshot(e, s.rx.tick, (^protocol.Entity_Motion)(g.value)^)
	}
}

// entity_snapshot adds what an Entity_Motion said about an entity.
@(private)
entity_snapshot :: proc(e: ^Other_Entity, tick: u32, m: protocol.Entity_Motion) {
	track_add(&e.track, {tick, m.position, m.yaw, m.pitch, false, false})
	e.looks = m.looks
	if e.last_seen == {} {e.last_seen = m.position}
}

@(private)
apply_block :: proc(s: ^Session, g: protocol.Received) {
	base.profile_scope("apply block change")
	v := (^protocol.Block_Record)(g.value)
	p := protocol.key_block(g.key)
	old, _ := world_block(&s.world, p)
	block := game.Block(v.block)
	changed := world_set_block(&s.world, p, block) && old != block
	// A gate opening: its void gathers (gates.odin).
	if changed && block == .Gate_Horizon {
		gate_void_appeared(s, p)
		journal_place(s, .Gate, {f64(p.x), f64(p.y), f64(p.z)})
	}
	// The world's own changes (flowing water) are quiet; someone else's edit
	// is heard where it happened.
	if changed && v.heard {edit_sound(s, p, old, block)}
}

// apply_machine keeps what a machine shows, by its chunk (machine_shown reads it).
@(private)
apply_machine :: proc(s: ^Session, g: protocol.Received) {
	if g.op == .Remove {return}
	p := protocol.key_block(g.key)
	shown := (^protocol.Machine_Record)(g.value).shown
	list, _ := &s.machines[game.chunk_of(p)]
	if list == nil {
		s.machines[game.chunk_of(p)] = make([dynamic]Machine_Shown, runtime.heap_allocator())
		list = &s.machines[game.chunk_of(p)]
	}
	for &m in list {
		if m.pos == p {
			m.shown = shown
			return
		}
	}
	append(list, Machine_Shown{p, shown})
}

@(private)
apply_channel :: proc(s: ^Session, g: protocol.Received) {
	if g.op == .Remove {return}
	id := int(g.key.d)
	v := (^protocol.Channel_Record)(g.value).value
	if id <= 0 || id >= len(s.reg.channels) || !s.reg.channels[id].replicated {
		fail(s, fmt.tprintf("the server sent a value of channel %d, which is not replicated", id))
		return
	}
	info := s.reg.channels[id]
	if v > game.channel_max(info) {
		fail(
			s,
			fmt.tprintf(
				"the server sent channel %s value %d above %d",
				info.name,
				v,
				game.channel_max(info),
			),
		)
		return
	}
	world_set_channel(&s.world, protocol.key_block(g.key), id, v)
}

@(private)
apply_event :: proc(s: ^Session, g: protocol.Received) {
	switch protocol.Event_Kind(g.kind - len(protocol.State_Kind)) {
	case .Notice:
		notice(s, (^protocol.Notice)(g.value).text)
	case .Chat_Line:
		v := (^protocol.Chat_Line)(g.value)
		chat_add(s, v.id, v.text)
		log.info("session chat ", game.format_strip(v.text))
		append(&s.notices, strings.clone(game.format_strip(v.text)))
	case .Chat_Delete:
		chat_delete(s, (^protocol.Chat_Delete)(g.value).id)
	case .Entity_Hurt:
		id := (^protocol.Entity_Hurt)(g.value).entity
		if e, known := &s.entities[id]; known {
			entity_flash(s, id, HURT)
			append(
				&s.sounds,
				Sound_Event{.Entity_Hurt, .Air, e.last_seen + {0, 0.5, 0}, 1, entity_voice(s, e)},
			)
			amount := int(e.lost)
			e.lost = 0
			game_seen(s, Seen_Hurt{id, e.kind, entity_middle(s, e), amount})
		}
	case .Entity_Died:
		id := (^protocol.Entity_Died)(g.value).entity
		if e, known := &s.entities[id]; known {
			entity_died(s, e)
			game_seen(s, Seen_Death{id, e.kind, entity_middle(s, e), int(e.lost) + int(e.health)})
		}
	case .Explosion:
		x := (^protocol.Explosion)(g.value)
		explosion_effects(s, x.position, f64(x.radius))
		game_seen(s, Seen_Blast{x.position, x.radius})
	case .Damage_Hit:
		s.hurt = (^protocol.Damage_Hit)(g.value)^
		s.hurts += 1
		s.hurt_age = 0
		game_seen(s, Seen_Harm{s.hurt.amount, s.hurt.yaw, s.hurt.known})
	case .Shot:
		shot_seen(s, (^protocol.Shot)(g.value))
	case .Swung:
		swung_seen(s, (^protocol.Swung)(g.value))
	case .Hit_Confirm:
		v := (^protocol.Hit_Confirm)(g.value)
		hit_confirmed(s, v)
		game_seen(s, Seen_Hit{v.kill, v.headshot})
	case .Player_Died:
		s.died += 1
		s.death_age = 0
		d := (^protocol.Player_Died)(g.value)
		kind, _ := game.damage_source_parse(d.cause)
		line := game.death_text(kind, s.config.name, d.attacker, d.weapon, true)
		s.death_len = copy(s.death_line[:], line)
	}
}
