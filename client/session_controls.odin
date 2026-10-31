package client

import "core:math"

import "common:game"

// What the player does besides moving: the hotbar and the mouse buttons
// (items.odin), edits predicted at once and confirmed by the server, hits,
// rockets.

MAX_PENDING_EDITS :: 64
EDIT_REPEAT_SECONDS :: 0.25 // a held button edits again this often

// session_attack hits the aimed entity; false if none is aimed at.
session_attack :: proc(s: ^Session) -> bool {
	id, ok := s.aim_entity.?
	if !ok {return false}
	send_message(s, game.Attack{id, s.prediction.next_sequence - 1})
	return true
}

// session_use_entity uses the aimed entity (right click); false if none is aimed at.
session_use_entity :: proc(s: ^Session) -> bool {
	id, ok := s.aim_entity.?
	if !ok {return false}
	send_message(s, game.Use_Entity{id, s.prediction.next_sequence - 1})
	return true
}

// session_use_block uses the aimed block if it is one that is used (a chest
// opens: the server answers with its contents; a door turns); false if it is not.
session_use_block :: proc(s: ^Session) -> bool {
	hit, aimed := s.aim.?
	if !aimed {return false}
	b, _ := world_block(&s.world, hit.block)
	if s.reg.blocks.types[s.reg.blocks.type_of[b]].use == .Toggle_Open {
		return session_toggle(s, hit.block, b)
	}
	if b != .Chest {return false}
	if !s.inventory.chest_open {
		send_message(s, game.Use_Block{hit.block, s.prediction.next_sequence - 1})
	}
	return true
}

// edit_controls: number keys and the wheel pick the hotbar item; the mouse
// buttons use it (item_use). Edits are predicted at once (if the shared
// rules allow them) and sent.
@(private)
edit_controls :: proc(s: ^Session, input: ^Input_State, a: ^Actions, dt: f32) {
	select := -1
	for act, i in HOTBAR_ACTIONS {if action_pressed(a, act) {select = i}}
	n_slots := game.HOTBAR_SLOTS
	if action_pressed(a, .Hotbar_Next) {select = (s.inventory.selected + 1) % n_slots}
	if action_pressed(
		a,
		.Hotbar_Previous,
	) {select = (s.inventory.selected - 1 + n_slots) % n_slots}
	if input.wheel.y != 0 {
		n := game.HOTBAR_SLOTS
		select = (s.inventory.selected - int(math.sign(input.wheel.y)) + n) % n
	}
	if select >= 0 && select != s.inventory.selected {
		session_inventory_do(s, {.Select, 0, select})
	}
	// Drop: one from the hand (with Ctrl: all of it).
	all := input.held & {.Left_Control, .Right_Control} != {}
	pressed_drop := action_pressed(a, .Drop)
	if drop_repeat(&s.drop_repeat, pressed_drop, action_down(a, .Drop) && !all, seconds_now()) ||
	   (pressed_drop && all) {
		session_inventory_do(s, {.Drop, s.inventory.selected, 1 if all else 0})
	}

	if action_pressed(a, .Pick) {session_pick(s)}
	if action_pressed(a, .Swap_Offhand) {session_inventory_do(s, {.Swap_Offhand, 0, 0})}

	s.edit_timer -= dt
	breaking := action_down(a, .Attack)
	placing := action_down(a, .Use)
	pressed := action_pressed(a, .Attack) || action_pressed(a, .Use)
	if _, w, is_weapon := weapon_in_hand(s); is_weapon {
		// The trigger is the weapon's; a zooming weapon keeps the use button.
		weapon_controls(s, a)
		breaking = false
		pressed = action_pressed(a, .Use)
		if w.zoom > 0 {placing = false}
	}
	if _, hook := grapple_in_hand(s); hook {placing = false} 	// (the use button is the hook's)
	if !(breaking || placing) || (!pressed && s.edit_timer > 0) {return}
	s.edit_timer = EDIT_REPEAT_SECONDS
	item_use(s, held(s), breaking, placing)
}

// session_pick puts the aimed block's item in hand: the hotbar slot holding
// it is selected; failing that, with items.catalog, a stack of it goes into
// the hand (the selected slot if empty, else the first empty one, else the
// selected one: what was there goes back into the inventory). False if
// nothing was done.
session_pick :: proc(s: ^Session) -> bool {
	hit, aimed := s.aim.?
	if !aimed {return false}
	block, _ := world_block(&s.world, hit.block)
	item := game.item_of_block(s.reg, block)
	if item == game.NO_ITEM {return false}
	inv := &s.inventory
	for st, i in inv.slots[:game.HOTBAR_SLOTS] {
		if st.item != item || game.stack_empty(st) {continue}
		if i != inv.selected {session_inventory_do(s, {.Select, 0, i})}
		return true
	}
	if !session_ability(s, .Catalog) {return false}
	target := inv.selected
	if !game.stack_empty(inv.slots[target]) {
		for st, i in inv.slots[:game.HOTBAR_SLOTS] {
			if game.stack_empty(st) {
				target = i
				break
			}
		}
	}
	session_inventory_do(s, {.Take, game.CURSOR_SLOT, int(item)})
	session_inventory_do(s, {.Click, target, 0}) // (what was there is on the cursor now)
	session_inventory_do(s, {.Close, game.CURSOR_SLOT, 0})
	if target != inv.selected {session_inventory_do(s, {.Select, 0, target})}
	return true
}

// session_fire launches a rocket where we look (the server makes it).
session_fire :: proc(s: ^Session) -> bool {
	if !session_allowed(s, "world.fire") {return false}
	send_message(s, game.Fire{s.prediction.next_sequence - 1, s.camera.yaw, s.camera.pitch})
	append(&s.sounds, Sound_Event{.Launch, .Air, s.camera.position, 1})
	return true
}

// session_edit breaks the aimed block, or places block against its face:
// predicted now if the shared rules allow it, then sent. False if not.
session_edit :: proc(s: ^Session, place: bool, block: game.Block) -> bool {
	hit, aimed := s.aim.?
	if !aimed || len(s.edits) >= MAX_PENDING_EDITS {return false}
	edit := game.Edit {
		id    = s.next_edit + 1,
		after = s.prediction.next_sequence - 1, // the last input predicted
	}
	if !place {
		b, _ := world_block(&s.world, hit.block)
		if !game.can_break(&s.reg.blocks, b) {return false}
		edit.pos, edit.block, edit.face = hit.block, .Air, game.EDIT_FACE_BREAK
	} else {
		face, is_face := game.face_of_normal(hit.normal)
		if !is_face {return false}
		// Where it goes, and in which state: the rule the server runs on the same numbers.
		ctx := game.Place_Context {
			target = hit.block,
			face   = face,
			hit    = game.hit_sixteenths(hit.point, hit.block),
			yaw    = s.input_yaw,
		}
		query := game.Block_Query{&s.world, world_block, &s.reg.blocks}
		pos, state, ok := game.placement(
			s.reg,
			game.block_type_of(&s.reg.blocks, block),
			ctx,
			query,
		)
		if !ok {return false}
		current, loaded := world_block(&s.world, pos)
		if !loaded ||
		   !can_place_from_hand(s, state) ||
		   (game.has_support_rule(&s.reg.blocks, state) &&
				   !game.support_holds(&s.reg.blocks, state, pos, query)) ||
		   !game.can_place_at(
				   &s.reg.blocks,
				   current,
				   state,
				   pos,
				   s.prediction.state,
			   ) {return false}
		if at, to, has := game.companion(s.reg, state, pos); has {
			above, there := world_block(&s.world, at)
			if !there ||
			   !game.can_place_at(&s.reg.blocks, above, to, at, s.prediction.state) {return false}
		}
		edit.pos, edit.block = pos, state
		edit.target, edit.face, edit.hit = ctx.target, u8(face), ctx.hit
	}
	before, _ := world_block(&s.world, edit.pos)
	if !predict_edit(s, edit.pos, edit.block) {return false}
	edit_sound(s, edit.pos, before, edit.block)
	s.next_edit = edit.id
	append(&s.edits, edit)
	inventory_predict(s) // (one used up)
	send_message(s, edit)
	return true
}

// predict_edit applies an edit to our world as the server will: the cell, the
// other half of a door with it (broken, placed or turned together), and the
// neighbours that follow what changed (a fence joins). False if its chunk is not here.
predict_edit :: proc(s: ^Session, pos: game.Block_Pos, block: game.Block) -> bool {
	current, _ := world_block(&s.world, pos)
	cell, cell_to, two := game.companion(s.reg, current, pos)
	if !two {cell, cell_to, two = game.companion(s.reg, block, pos)}
	if two {
		// What the other cell becomes: nothing when breaking, its state when
		// placing, and the state turned with this one when toggling.
		there, _ := world_block(&s.world, cell)
		switch game.edit_kind(&s.reg.blocks, current, block) {
		case .Break:
			if there != cell_to {two = false}
			cell_to = .Air
		case .Toggle:
			if there != cell_to {two = false}
			_, cell_to, _ = game.companion(s.reg, block, pos)
		case .Place:
			_, cell_to, _ = game.companion(s.reg, block, pos)
		}
	}
	if !world_set_block(&s.world, pos, block) {return false}
	predict_neighbours(s, pos)
	if two && world_set_block(&s.world, cell, cell_to) {predict_neighbours(s, cell)}
	return true
}

// predict_neighbours: the four neighbours of pos follow it (shape_update).
predict_neighbours :: proc(s: ^Session, pos: game.Block_Pos) {
	query := game.Block_Query{&s.world, world_block, &s.reg.blocks}
	changes: [4]game.Block_Change
	for c in changes[:game.neighbour_updates(s.reg, pos, query, &changes)] {
		world_set_block(&s.world, c.pos, c.b)
	}
}

// session_toggle turns the door at pos (state b) open or shut: predicted now,
// then sent as an edit of its state. False if it cannot.
session_toggle :: proc(s: ^Session, pos: game.Block_Pos, b: game.Block) -> bool {
	if len(s.edits) >= MAX_PENDING_EDITS {return true} 	// (used, but too many are waiting)
	t := &s.reg.blocks
	i, found := game.prop_index(t, t.type_of[b], "open")
	if !found {return false}
	flipped := game.state_with(t, b, i, 1 - game.state_value(t, b, i))
	edit := game.Edit {
		id    = s.next_edit + 1,
		after = s.prediction.next_sequence - 1,
		pos   = pos,
		block = flipped,
		face  = game.EDIT_FACE_PLAIN,
	}
	if !predict_edit(s, pos, flipped) {return false}
	append(&s.sounds, Sound_Event{.Place, flipped, {f64(pos.x), f64(pos.y), f64(pos.z)} + 0.5, 1})
	s.next_edit = edit.id
	append(&s.edits, edit)
	send_message(s, edit)
	return true
}

// session_till makes farmland of the aimed grass or dirt (the hoe, right
// button): predicted now, then sent like a placed block. False if it cannot.
session_till :: proc(s: ^Session) -> bool {
	hit, aimed := s.aim.?
	if !aimed || len(s.edits) >= MAX_PENDING_EDITS {return false}
	current, _ := world_block(&s.world, hit.block)
	above, loaded := world_block(&s.world, hit.block + {0, 1, 0})
	if !loaded || !game.can_till(s.reg, current, above) {return false}
	edit := game.Edit {
		id    = s.next_edit + 1,
		after = s.prediction.next_sequence - 1,
		pos   = hit.block,
		block = .Farmland,
		face  = game.EDIT_FACE_PLAIN,
	}
	if !world_set_block(&s.world, edit.pos, .Farmland) {return false}
	edit_sound(s, edit.pos, current, .Farmland)
	s.next_edit = edit.id
	append(&s.edits, edit)
	send_message(s, edit)
	return true
}

// edit_sound: a block at pos went from old to new.
@(private)
edit_sound :: proc(s: ^Session, pos: game.Block_Pos, old, new: game.Block) {
	centre := [3]f64{f64(pos.x), f64(pos.y), f64(pos.z)} + 0.5
	if new == .Air {
		append(&s.sounds, Sound_Event{.Break, old, centre, 1})
	} else {
		append(&s.sounds, Sound_Event{.Place, new, centre, 1})
	}
}
