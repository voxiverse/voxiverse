package server

import "core:log"

import "../common/game"

// Actions: what a player does besides moving (edit a block, hit an entity,
// fire a rocket). Each says which of its inputs it came after, and waits
// until the server has applied that input, so it is judged from where the
// player was when they did it (as the client predicted), however late the
// messages arrive.

Action :: union {
	game.Edit,
	game.Attack,
	game.Use_Entity,
	game.Use_Block,
	game.Fire,
	game.Shoot,
}

// FIRE_EVERY: ticks between a player's rockets.
@(private)
FIRE_EVERY :: game.TICK_RATE / 4

// queue_action holds an action until the input it follows has been
// applied (refusing it outright if too many are waiting).
queue_action :: proc(s: ^Server, c: ^Client, a: Action) {
	w := c.world
	if c.action_count == MAX_QUEUED_ACTIONS {
		if e, edit := a.(game.Edit); edit {send_message(s, c, edit_refused(w, e))}
		return
	}
	c.actions[c.action_count] = a
	c.action_count += 1
	run_due_actions(s, c)
}

// run_due_actions runs queued actions whose input has been applied, in order.
run_due_actions :: proc(s: ^Server, c: ^Client) {
	n := 0
	for ; n < c.action_count; n += 1 {
		a := c.actions[n]
		if !game.sequence_before_or_at(action_after(a), c.inputs.last) {break}
		if c.dead { 	// (the dead do nothing)
			if e, edit := a.(game.Edit); edit {send_message(s, c, edit_refused(c.world, e))}
			continue
		}
		switch v in a {
		case game.Edit:
			send_message(s, c, apply_edit(s, c, v))
		case game.Attack:
			attack(s, c, v)
		case game.Use_Entity:
			use_entity(s, c, v.entity)
		case game.Use_Block:
			use_block(s, c, v.pos)
		case game.Fire:
			if s.tick >= c.fired_at + FIRE_EVERY {
				c.fired_at = s.tick
				fire(s, c, v.yaw, v.pitch)
			}
		case game.Shoot:
			weapon_shoot(s, c, v)
		}
	}
	copy(c.actions[:], c.actions[n:c.action_count])
	c.action_count -= n
}

@(private = "file")
action_after :: proc(a: Action) -> u32 {
	switch v in a {
	case game.Edit:
		return v.after
	case game.Attack:
		return v.after
	case game.Use_Entity:
		return v.after
	case game.Use_Block:
		return v.after
	case game.Fire:
		return v.after
	case game.Shoot:
		return v.after
	}
	return 0
}

// edit_refused: the answer to an edit nobody looked at: the blocks as they are.
edit_refused :: proc(w: ^World, e: game.Edit) -> game.Edit_Result {
	current, _ := chunks_block(&w.chunks, e.pos)
	r := game.Edit_Result {
		id    = e.id,
		pos   = e.pos,
		block = current,
	}
	cell, _, two := game.companion(w.server.registry, current, e.pos)
	if !two {cell, _, two = game.companion(w.server.registry, e.block, e.pos)}
	if b, there := chunks_block(&w.chunks, cell); two && there {
		r.companion = game.Companion_Record{cell, b}
	}
	return r
}

// apply_edit checks an edit against the shared rules, from where the server
// has the player, and applies it if it passes. An edit of a two-cell block (a
// door) answers for the other cell too.
apply_edit :: proc(s: ^Server, c: ^Client, e: game.Edit) -> game.Edit_Result {
	result, cell, two := apply_edit_cells(s, c, e)
	if b, there := chunks_block(&c.world.chunks, cell); two && there {
		result.companion = game.Companion_Record{cell, b}
	}
	return result
}

// apply_edit_cells: apply_edit's work; it also says which other cell the edit
// concerns (the other half of a door), whatever became of it.
@(private = "file")
apply_edit_cells :: proc(
	s: ^Server,
	c: ^Client,
	e: game.Edit,
) -> (
	result: game.Edit_Result,
	cell: game.Block_Pos,
	two: bool,
) {
	w := c.world
	t := &s.registry.blocks
	current, loaded := chunks_block(&w.chunks, e.pos)
	result = {
		id    = e.id,
		pos   = e.pos,
		block = current,
	}
	if !loaded {return}
	cell_to: game.Block
	cell, cell_to, two = game.companion(s.registry, current, e.pos)
	if !two {cell, cell_to, two = game.companion(s.registry, e.block, e.pos)}
	player := c.player
	if !game.in_reach(
		game.player_eye(player),
		e.pos,
		f64(w.rules.reach) + game.EDIT_REACH_SLACK,
	) {return}
	ok := false
	slot := -1 // placing from (infinite: none)
	infinite := has_ability(s, c, .Infinite_Items)
	tilling := e.block == .Farmland
	kind := game.edit_kind(t, current, e.block)
	other_to: game.Block // what the other cell of a two-cell block becomes
	moves_other := false
	switch {
	case kind == .Break:
		ok = game.can_break(t, current)
		// (a half whose other half is not there breaks alone)
		there, _ := chunks_block(&w.chunks, cell)
		if two && there == cell_to {moves_other, other_to = true, .Air}
	case kind == .Toggle:
		// A door turns on both halves, which must be there and agree.
		there, _ := chunks_block(&w.chunks, cell)
		if !two || there != cell_to {return}
		_, other_to, _ = game.companion(s.registry, e.block, e.pos)
		moves_other = true
		ok = e.face == game.EDIT_FACE_PLAIN
	case tilling:
		// The hoe: farmland out of grass or dirt with air above.
		above, _ := chunks_block(&w.chunks, e.pos + {0, 1, 0})
		hoe := game.inventory_held(&c.inventory).item == game.item_of_tool(.Hoe)
		ok = hoe && game.can_till(s.registry, current, above)
	case:
		if !infinite {slot = game.inventory_placing_slot(s.registry, &c.inventory, e.block)}
		ok =
			(infinite || slot >= 0) &&
			game.can_place(t, e.block) &&
			placement_agrees(s, c, e) &&
			game.can_place_at(t, current, e.block, e.pos, player) &&
			support_placeable(w, e.pos, e.block) &&
			!anyone_else_in(s, c, e.pos, e.block)
		if two && ok {
			// The upper half goes where the lower half's rule left room for it.
			above, loaded2 := chunks_block(&w.chunks, cell)
			ok =
				loaded2 &&
				game.can_place_at(t, above, cell_to, cell, player) &&
				!anyone_else_in(s, c, cell, cell_to)
			moves_other, other_to = true, cell_to
		}
	}
	if !ok {return}
	system := game.Edit_System.Till if tilling else .Hand
	act := Act{action_begin(w, actor_of(s, c), system), system}
	if moves_other && admit(w, act, cell) != .Yes {
		protect_notice(s, c, act, cell)
		return
	}
	if !set_block(w, e.pos, e.block, act, c) {
		protect_notice(s, c, act, e.pos)
		return
	}
	if moves_other {
		// (breaking the lower half took the upper with it already: its support went)
		if now, _ := chunks_block(&w.chunks, cell); now != other_to {
			set_block(w, cell, other_to, act, c)
		}
	}
	result.accepted = true
	result.block, _ = chunks_block(&w.chunks, e.pos)
	if tilling && farmland_wet(w, e.pos) {set_block(w, e.pos, .Farmland_Moist, act)} 	// (everyone is told, the tiller too)
	switch {
	case kind == .Break:
		record(s, c, .Block_Mined, game.block_name(s.registry, current), at = e.pos)
	case kind == .Toggle:
		record(s, c, .Item_Used, game.block_name(s.registry, e.block), at = e.pos)
	case tilling:
		record(s, c, .Item_Used, "hoe", at = e.pos)
	case:
		record(s, c, .Block_Placed, game.block_name(s.registry, e.block), at = e.pos)
	}
	if kind == .Break {
		broken_drop(s, c, e.pos, current)
	} else if slot >= 0 {
		used_to_place(s, c, slot)
	}
	return
}

// attack: a player hits an entity, if it is within reach of where the
// server has the player (with the same slack as edits). The client chose it
// by its own ray; the server only checks it was possible.
@(private = "file")
attack :: proc(s: ^Server, c: ^Client, a: game.Attack) {
	w := c.world
	ent, index := entity_find(w, a.entity)
	if ent == nil || !game.ENTITY_INFO[ent.kind].hittable {return} 	// gone already: a late click
	if !entity_reachable(c, ent) {return}
	record(s, c, .Entity_Hit, game.ENTITY_INFO[ent.kind].name)
	if entity_attack(w, ent, c.player.position) {
		record(s, c, .Entity_Killed, game.ENTITY_INFO[ent.kind].name)
		log.debugf("server entity died id=%d by=%s", a.entity, client_name(c))
		entity_died(w, index)
	} else {
		entity_hurt_shown(w, a.entity)
	}
}

// anyone_else_in: block at pos would be inside another player.
@(private = "file")
anyone_else_in :: proc(s: ^Server, c: ^Client, pos: game.Block_Pos, block: game.Block) -> bool {
	for &other in s.clients {
		if &other != c &&
		   other.world == c.world &&
		   other.state == .Playing &&
		   !game.can_place_at(&s.registry.blocks, .Air, block, pos, other.player) {
			return true
		}
	}
	return false
}

// placement_agrees: running the placement rule on the edit's context gives
// the cell and the state the client sent (an edit with no context: only a
// type with the default rule, in its default state, at e.pos).
@(private = "file")
placement_agrees :: proc(s: ^Server, c: ^Client, e: game.Edit) -> bool {
	t := &s.registry.blocks
	type := game.block_type_of(t, e.block)
	if e.face == game.EDIT_FACE_PLAIN {
		def := &t.types[type]
		return def.place == .Default && def.default == e.block
	}
	face, is_face := game.Face(e.face), e.face < 6
	if !is_face {return false}
	w := c.world
	query := game.Block_Query{&w.chunks, chunks_block, t}
	pos, state, ok := game.placement(
		s.registry,
		type,
		{target = e.target, face = face, hit = e.hit, yaw = c.look[0]},
		query,
	)
	return ok && pos == e.pos && state == e.block
}

// support_placeable: block may be placed at pos: what needs support, only
// where it is held.
@(private)
support_placeable :: proc(w: ^World, pos: game.Block_Pos, block: game.Block) -> bool {
	t := &w.server.registry.blocks
	if !game.has_support_rule(t, block) {return true}
	return game.support_holds(t, block, pos, game.Block_Query{&w.chunks, chunks_block, t})
}
