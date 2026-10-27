package client

import "core:log"
import "core:strings"
import "core:time"

import "../base"
import "../common/game"
import "../common/worldgen"

// What the server's State and Snapshot messages do to the session (M39): the
// receiver decodes them into records and events (common/game/replica.odin), and one
// table says what each kind of record does here, a switch what each event does.

@(private)
Apply_Proc :: proc(s: ^Session, g: game.Received)

@(private, rodata)
APPLY := [game.State_Kind]Apply_Proc {
	.Own_Player    = apply_own_player,
	.Health        = apply_health,
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
}

// apply_received does what a message's records and events say, in order.
@(private)
apply_received :: proc(s: ^Session, got: []game.Received) {
	for g in got {
		if g.op == .Event {
			apply_event(s, g)
		} else {
			APPLY[game.State_Kind(g.kind)](s, g)
		}
	}
}

@(private)
apply_own_player :: proc(s: ^Session, g: game.Received) {
	v := (^game.Own_Player)(g.value)^
	teleported := v.teleports != s.teleports
	s.teleports = v.teleports
	s.last_acked = v.acked
	game.prediction_reconcile(
		&s.prediction,
		v,
		&s.rules,
		{&s.world, world_block},
		game.derive_mods(&s.inventory),
		teleported,
	)
	if teleported {s.camera.yaw, s.camera.pitch = v.yaw, v.pitch}
}

@(private)
apply_health :: proc(s: ^Session, g: game.Received) {
	h := (^game.Health)(g.value)
	s.health, s.max_health = h.health, h.max
}

@(private)
apply_place :: proc(s: ^Session, g: game.Received) {
	s.place = (^game.Place)(g.value)^
}

@(private)
apply_inventory :: proc(s: ^Session, g: game.Received) {
	inventory_reconcile(s, (^game.Inventory_State)(g.value)^)
}

@(private)
apply_rules :: proc(s: ^Session, g: game.Received) {
	s.rules = (^game.Rules)(g.value)^
}

@(private)
apply_clock :: proc(s: ^Session, g: game.Received) {
	c := (^game.Clock)(g.value)
	// the anchor is the time at its tick; this message is of s.rx.tick
	behind := f64(s.rx.tick - c.tick) * f64(game.TICK_SECONDS)
	s.clock = game.advance_time(c.time, max(behind, 0), &s.rules)
}

@(private)
apply_grants :: proc(s: ^Session, g: game.Received) {
	v := (^game.Grants)(g.value)
	for gr in s.grants {delete(gr.pattern)}
	clear(&s.grants)
	if !game.grants_parse(v.text, &s.grants) {log.warn("session grants not understood")}
	for c in s.commands {delete(c)}
	clear(&s.commands)
	for name in strings.fields(v.commands, context.temp_allocator) {
		append(&s.commands, strings.clone(name))
	}
}

@(private)
apply_variables :: proc(s: ^Session, g: game.Received) {
	s.has_worldgen = true
	for p in base.vars_read(worldgen.params_table(), &s.worldgen, (^game.Variables)(g.value).text) {
		log.warnf("session variable not applied problem=%v text=%q", p.error, p.text)
	}
}

@(private)
apply_selection :: proc(s: ^Session, g: game.Received) {
	s.selection = (^game.Selection)(g.value).corners // (drawn: camera.odin)
}

@(private)
apply_player :: proc(s: ^Session, g: game.Received) {
	id := u16(g.key.a)
	if g.op == .Remove {
		if o, known := s.others[id]; known {delete(o.name)}
		delete_key(&s.others, id)
		return
	}
	v := (^game.Player_Record)(g.value)
	if o, known := &s.others[id]; known && g.op == .Change {
		if o.name != v.name {
			delete(o.name)
			o.name = strings.clone(v.name)
		}
		o.worn = v.worn
		return
	}
	if o, known := s.others[id]; known {delete(o.name)} 	// a seat taken again
	s.others[id] = {
		name = strings.clone(v.name),
		worn = v.worn,
	}
	// its motion may have arrived first (the lanes are not ordered together)
	if m := game.receiver_snapshot_get(&s.rx, int(game.State_Kind.Player_Motion), g.key);
	   m != nil {
		other_snapshot(&s.others[id], s.rx.tick, (^game.Player_Motion)(m)^)
	}
}

@(private)
apply_player_motion :: proc(s: ^Session, g: game.Received) {
	if g.op == .Remove {return}
	if o, known := &s.others[u16(g.key.a)]; known {
		other_snapshot(o, s.rx.tick, (^game.Player_Motion)(g.value)^)
	}
}

@(private)
apply_entity :: proc(s: ^Session, g: game.Received) {
	id := u32(g.key.a)
	if g.op == .Remove {
		delete_key(&s.entities, id)
		return
	}
	v := (^game.Entity_Record)(g.value)
	if e, known := &s.entities[id]; known && g.op == .Change {
		e.kind, e.stack = v.kind, v.stack
		return
	}
	s.entities[id] = {
		kind  = v.kind,
		stack = v.stack,
	}
	if m := game.receiver_snapshot_get(&s.rx, int(game.State_Kind.Entity_Motion), g.key);
	   m != nil {
		entity_snapshot(&s.entities[id], s.rx.tick, (^game.Entity_Motion)(m)^)
	}
}

@(private)
apply_entity_motion :: proc(s: ^Session, g: game.Received) {
	if g.op == .Remove {return}
	if e, known := &s.entities[u32(g.key.a)]; known {
		entity_snapshot(e, s.rx.tick, (^game.Entity_Motion)(g.value)^)
	}
}

// entity_snapshot adds what an Entity_Motion said about an entity.
@(private)
entity_snapshot :: proc(e: ^Other_Entity, tick: u32, m: game.Entity_Motion) {
	track_add(&e.track, {tick, m.position, m.yaw, m.pitch, false, false})
	e.flags = m.flags
	if e.last_seen == {} {e.last_seen = m.position}
}

@(private)
apply_block :: proc(s: ^Session, g: game.Received) {
	v := (^game.Block_Record)(g.value)
	p := game.key_block(g.key)
	if !v.heard {
		world_set_block(&s.world, p, v.block) // the world's own changes (flowing water): quietly
		return
	}
	// Someone else's edit: heard where it happened.
	old, _ := world_block(&s.world, p)
	if world_set_block(&s.world, p, v.block) && old != v.block {edit_sound(s, p, old, v.block)}
}

@(private)
apply_event :: proc(s: ^Session, g: game.Received) {
	switch game.Event_Kind(g.kind - len(game.State_Kind)) {
	case .Notice:
		notice(s, (^game.Notice)(g.value).text)
	case .Chat_Line:
		v := (^game.Chat_Line)(g.value)
		chat_add(s, v.id, v.text)
		log.info("session chat ", game.format_strip(v.text))
		append(&s.notices, strings.clone(game.format_strip(v.text)))
	case .Chat_Delete:
		chat_delete(s, (^game.Chat_Delete)(g.value).id)
	case .Entity_Hurt:
		if e, known := &s.entities[(^game.Entity_Hurt)(g.value).entity]; known {
			e.hurt_at = time.tick_now()
			append(&s.sounds, Sound_Event{.Entity_Hurt, .Air, e.last_seen + {0, 0.5, 0}, 1})
		}
	case .Entity_Died:
		if e, known := &s.entities[(^game.Entity_Died)(g.value).entity]; known {
			entity_died(s, e)
		}
	case .Explosion:
		x := (^game.Explosion)(g.value)
		explosion_effects(s, x.position, f64(x.radius))
	case .Player_Died:
		s.died += 1
	}
}
