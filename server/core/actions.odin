package core

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"

import "common:base"
import "common:game"
import "common:protocol"

// Actions: what a player does besides moving (edit a block, hit an entity,
// fire a rocket). Each says which of its inputs it came after, and waits
// until the server has applied that input, so it is judged from where the
// player was when they did it (as the client predicted), however late the
// messages arrive.

Action :: union {
	protocol.Edit,
	protocol.Attack,
	protocol.Use_Entity,
	protocol.Use_Block,
	protocol.Fire,
	protocol.Shoot,
}

// FIRE_EVERY: ticks between a player's rockets.
@(private)
FIRE_EVERY :: game.TICK_RATE / 4

// swing_near tells everyone within hearing of c that c swung: their avatars
// see the arm arc (the swing events the view model gets, replicated). For an
// action that did something; a swing that hits nothing shows on the swinger's
// screen only, like a silent weapon.
@(private)
swing_near :: proc(s: ^Server, c: ^Client) {
	for &o in s.clients {
		if &o == c || o.state != .Playing || o.world != c.world || !player_seen(&o, c) {continue}
		d := o.player.position - c.player.position
		if d.x * d.x + d.y * d.y + d.z * d.z > SHOT_HEARD * SHOT_HEARD {continue}
		swung := protocol.Swung {
			player = player_id(s, c),
		}
		event_send(s, &o, .Swung, &swung)
	}
}

// queue_action holds an action until the input it follows has been
// applied (refusing it outright if too many are waiting).
queue_action :: proc(s: ^Server, c: ^Client, a: Action) {
	w := c.world
	if c.action_count == MAX_QUEUED_ACTIONS {
		if e, edit := a.(protocol.Edit); edit {send_message(s, c, edit_refused(w, e))}
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
		if !protocol.sequence_before_or_at(action_after(a), c.inputs.last) {break}
		if c.dead || has_ability(s, c, .Spectate) { 	// (the dead do nothing, nor do those who only watch)
			if e, edit := a.(protocol.Edit); edit {send_message(s, c, edit_refused(c.world, e))}
			continue
		}
		switch v in a {
		case protocol.Edit:
			if v.face == game.EDIT_FACE_BREAK_BEGIN {
				c.breaking = {v.pos, v.after, true} // (asks nothing: no answer)
				continue
			}
			swing_near(s, c)
			send_message(s, c, apply_edit(s, c, v))
		case protocol.Attack:
			swing_near(s, c)
			attack(s, c, v)
		case protocol.Use_Entity:
			swing_near(s, c)
			use_entity(s, c, v.entity)
		case protocol.Use_Block:
			swing_near(s, c)
			use_block(s, c, v.pos)
		case protocol.Fire:
			if s.tick >= c.fired_at + FIRE_EVERY {
				c.fired_at = s.tick
				fire(s, c, v.yaw, v.pitch)
			}
		case protocol.Shoot:
			weapon_shoot(s, c, v)
		}
	}
	copy(c.actions[:], c.actions[n:c.action_count])
	c.action_count -= n
}

@(private = "file")
action_after :: proc(a: Action) -> u32 {
	switch v in a {
	case protocol.Edit:
		return v.after
	case protocol.Attack:
		return v.after
	case protocol.Use_Entity:
		return v.after
	case protocol.Use_Block:
		return v.after
	case protocol.Fire:
		return v.after
	case protocol.Shoot:
		return v.after
	}
	return 0
}

// edit_refused: the answer to an edit nobody looked at: the blocks as they are.
edit_refused :: proc(w: ^World, e: protocol.Edit) -> protocol.Edit_Result {
	current, _ := chunks_block(&w.chunks, e.pos)
	r := protocol.Edit_Result {
		id    = e.id,
		pos   = e.pos,
		block = current,
	}
	cell, _, two := game.companion(w.server.registry, current, e.pos)
	if !two {cell, _, two = game.companion(w.server.registry, e.block, e.pos)}
	if b, there := chunks_block(&w.chunks, cell); two && there {
		r.companion = protocol.Companion_Record{cell, b}
	}
	return r
}

// apply_edit checks an edit against the shared rules, from where the server
// has the player, and applies it if it passes. An edit of a two-cell block (a
// door) answers for the other cell too.
apply_edit :: proc(s: ^Server, c: ^Client, e: protocol.Edit) -> protocol.Edit_Result {
	result, cell, two := apply_edit_cells(s, c, e)
	if b, there := chunks_block(&c.world.chunks, cell); two && there {
		result.companion = protocol.Companion_Record{cell, b}
	}
	return result
}

// apply_edit_cells: apply_edit's work; it also says which other cell the edit
// concerns (the other half of a door), whatever became of it.
@(private = "file")
apply_edit_cells :: proc(
	s: ^Server,
	c: ^Client,
	e: protocol.Edit,
) -> (
	result: protocol.Edit_Result,
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
		held := game.inventory_held(&c.inventory)
		if ok &&
		   !has_ability(s, c, .Instant_Break) &&
		   !game.can_gather(s.registry, current, held) {
			notice(s, c, tier_text(game.block_tier(s.registry, current)))
			return
		}
		if ok && !break_held_long_enough(s, c, e, current, held) {return}
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
	if g := &s.config.game; g.editing != nil {
		becomes := game.Block.Air if kind == .Break else e.block
		if why := g.editing(s, c, e.pos, current, becomes); why != "" {
			notice(s, c, why)
			return
		}
	}
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
		quest_note(s, c, {goal = .Break, block = current, count = 1})
	case kind == .Toggle:
		record(s, c, .Item_Used, game.block_name(s.registry, e.block), at = e.pos)
	case tilling:
		record(s, c, .Item_Used, "hoe", at = e.pos)
	case:
		record(s, c, .Block_Placed, game.block_name(s.registry, e.block), at = e.pos)
		quest_note(s, c, {goal = .Place, block = e.block, count = 1})
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
// by its own ray; the server only checks it was possible. With a melee weapon
// in hand it is a swing instead (whatever entity it names; 0: none).
@(private = "file")
attack :: proc(s: ^Server, c: ^Client, a: protocol.Attack) {
	w := c.world
	held := game.inventory_held(&c.inventory)
	if info, known := game.item_info(s.registry, held.item); known && !game.stack_empty(held) {
		if melee, swung := info.melee.?; swung {
			swing(s, c, held, melee)
			return
		}
	}
	ent, found := entity_find(w, a.entity)
	if !found {return} 	// gone already: a late click
	info := game.kind_info(s.registry, entity_kind(w, ent))
	if !info.hittable {return}
	if !entity_reachable(c, ent) {return}
	record(s, c, .Entity_Hit, game.kind_name(info))
	if entity_attack(w, ent, c.player.position, {amount = 1, kind = .Hit, by = c}) {
		record(s, c, .Entity_Killed, game.kind_name(info))
		log.debugf("server entity died id=%d by=%s", a.entity, client_name(c))
	}
}

// swing: c swings the melee weapon in hand, if its cooldown has run: everything
// hittable whose box comes within the weapon's reach of the eyes and lies inside its
// arc about where c faces (horizontally), in sight, is struck for its damage (the
// game's harming hook may change it): creatures knocked back, other players hurt as a
// blow hurts them (pvp permitting). Returns how many were struck.
swing :: proc(s: ^Server, c: ^Client, held: game.Stack, melee: game.Melee_Info) -> (struck: int) {
	if c.dead || s.tick < c.swing_due {return}
	c.swing_due = s.tick + u64(max(math.round(melee.cooldown * game.TICK_RATE), 1))
	melee := melee
	melee.damage = game.skill_value(s.registry, &c.skills, .Melee_Damage, melee.damage)
	w := c.world
	eye := game.player_eye(c.player)
	name := game.item_name(s.registry, held.item)
	yaw := f64(c.look[0])
	facing := [2]f64{-base.sin(yaw), -base.cos(yaw)}
	least := base.cos(f64(melee.arc) * math.RAD_PER_DEG / 2) // (the arc's edge, as a cosine)
	reach := f64(melee.reach)
	// within: the box's nearest point is in reach, its middle inside the arc, in sight.
	within :: proc(
		w: ^World,
		eye: [3]f64,
		lo, hi: [3]f64,
		facing: [2]f64,
		least, reach: f64,
	) -> bool {
		near := [3]f64 {
			clamp(eye.x, lo.x, hi.x),
			clamp(eye.y, lo.y, hi.y),
			clamp(eye.z, lo.z, hi.z),
		}
		d := near - eye
		if d.x * d.x + d.y * d.y + d.z * d.z > reach * reach {return false}
		mid := (lo + hi) / 2
		to := [2]f64{mid.x - eye.x, mid.z - eye.z}
		l := math.sqrt(to.x * to.x + to.y * to.y)
		if l > 0.3 {
			if (to.x * facing.x + to.y * facing.y) / l < least {return false}
		}
		return sees(w, eye, mid)
	}
	found := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_sphere(
		&w.entity_world.spatial,
		eye,
		reach + ROCKET_REACH,
		{all = {.Hittable}},
		&found,
	)
	slice.sort(found[:])
	for id in found {
		e, there := entity_find(w, u32(id))
		if !there {continue}
		info := game.kind_info(s.registry, entity_kind(w, e))
		if !info.hittable {continue}
		lo, hi := game.entity_box(info, entity_pos(w, e))
		if !within(w, eye, lo, hi, facing, least, reach) {continue}
		struck += 1
		record(s, c, .Entity_Hit, game.kind_name(info))
		harm := Entity_Harm {
			amount = max(int(math.round(melee.damage)), 1),
			kind   = .Hit,
			by     = c,
			weapon = name,
			stack  = held,
		}
		if entity_attack(w, e, c.player.position, harm) {
			record(s, c, .Entity_Killed, game.kind_name(info))
		}
	}
	for &o in s.clients {
		if &o == c || o.world != w || o.state != .Playing || o.dead || bodiless(s, &o) {continue}
		lo, hi := game.player_box(o.player)
		if !within(w, eye, lo, hi, facing, least, reach) {continue}
		source := Damage_Source {
			kind     = .Hit,
			attacker = u16(player_id(s, c)),
			weapon   = name,
			stack    = held,
			pos      = c.player.position,
			placed   = true,
		}
		if r := damage(s, &o, melee.damage, source); r == .Hurt || r == .Killed {struck += 1}
	}
	return
}

// anyone_else_in: block at pos would be inside another player.
@(private = "file")
anyone_else_in :: proc(s: ^Server, c: ^Client, pos: game.Block_Pos, block: game.Block) -> bool {
	for &other in s.clients {
		if &other != c &&
		   other.world == c.world &&
		   other.state == .Playing &&
		   !bodiless(s, &other) &&
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
placement_agrees :: proc(s: ^Server, c: ^Client, e: protocol.Edit) -> bool {
	t := &s.registry.blocks
	type := game.block_type_of(t, e.block)
	if e.face == game.EDIT_FACE_PLAIN {
		def := &t.types[type]
		return def.place == .Default && def.default == e.block
	}
	face, is_face := game.Face(e.face), e.face < 6
	if !is_face {return false}
	w := c.world
	query := game.Block_Query{&w.chunks, chunks_block, t, {}}
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
	return game.support_holds(t, block, pos, game.Block_Query{&w.chunks, chunks_block, t, {}})
}

// farmland_wet: water within 4 blocks across, on the farmland's level or the one above
// (the hoe's test; the random rule in data/sim/growth.json reads the same box).
farmland_wet :: proc(w: ^World, p: game.Block_Pos) -> bool {
	for y in i32(0) ..= 1 {
		for z in i32(-4) ..= 4 {
			for x in i32(-4) ..= 4 {
				b, _ := chunks_block(&w.chunks, p + {x, y, z})
				if _, water := game.water_level(b); water {return true}
			}
		}
	}
	return false
}

// tier_text: what a player is told who breaks a block its tool cannot gather.
@(private = "file")
tier_text :: proc(tier: u8) -> string {
	return fmt.tprintf("That needs a tier %d tool", tier)
}

// Break_Begin: where a player began to break a block (an Edit of face
// EDIT_FACE_BREAK_BEGIN), after which of its inputs.
Break_Begin :: struct {
	pos:   game.Block_Pos,
	after: u32,
	set:   bool,
}

// break_held_long_enough: where breaking takes time (game.break_ticks), c began to break
// this block and held on for at least its ticks: counted in its inputs, one a tick and
// never more (INPUT_BUDGET_MAX), so a client cannot break faster than its tool allows.
// The begin is spent either way.
@(private = "file")
break_held_long_enough :: proc(
	s: ^Server,
	c: ^Client,
	e: protocol.Edit,
	current: game.Block,
	held: game.Stack,
) -> bool {
	abilities := game.derive_abilities(s.registry, c.mode, &c.inventory)
	need := game.break_ticks(s.registry, &c.world.rules, current, held, abilities, &c.skills)
	begin := c.breaking
	c.breaking = {}
	if need == 0 {return true}
	return begin.set && begin.pos == e.pos && int(e.after - begin.after) >= need
}
