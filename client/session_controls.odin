package client

import "core:math"

import "../game"

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

// edit_controls: number keys and the wheel pick the hotbar item; the mouse
// buttons use it (item_use). Edits are predicted at once (if the shared
// rules allow them) and sent.
@(private)
edit_controls :: proc(s: ^Session, input: ^Input_State, keys: Bindings, dt: f32) {
	select := -1
	for k, i in hotbar_keys(keys) {if k in input.pressed {select = i}}
	if input.wheel.y != 0 {
		n := game.HOTBAR_SLOTS
		select = (s.inventory.selected - int(math.sign(input.wheel.y)) + n) % n
	}
	if select >= 0 && select != s.inventory.selected {
		session_inventory_do(s, {.Select, 0, select})
	}
	// Drop: one from the hand (with Ctrl: all of it).
	if keys.drop in input.pressed {
		all := input.held & {.Left_Control, .Right_Control} != {}
		session_inventory_do(s, {.Drop, s.inventory.selected, 1 if all else 0})
	}

	if keys.pick in input.pressed {session_pick(s)}

	s.edit_timer -= dt
	breaking := keys.attack in input.held
	placing := keys.use in input.held
	pressed := keys.attack in input.pressed || keys.use in input.pressed
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
	item := game.item_of_block(block)
	if item == game.NO_ITEM {return false}
	inv := &s.inventory
	for st, i in inv.slots[:game.HOTBAR_SLOTS] {
		if st.item != item || game.stack_empty(st) {continue}
		if i != inv.selected {session_inventory_do(s, {.Select, 0, i})}
		return true
	}
	if !session_allowed(s, "items.catalog") {return false}
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
		if !game.can_break(b) {return false}
		edit.pos, edit.block = hit.block, .Air
	} else {
		if hit.normal == {} {return false}
		edit.pos = hit.block + hit.normal
		current, loaded := world_block(&s.world, edit.pos)
		if !loaded ||
		   !can_place_from_hand(s, block) ||
		   !game.can_place_at(current, block, edit.pos, s.prediction.state) {return false}
		edit.block = block
	}
	before, _ := world_block(&s.world, edit.pos)
	if !world_set_block(&s.world, edit.pos, edit.block) {return false}
	edit_sound(s, edit.pos, before, edit.block)
	s.next_edit = edit.id
	append(&s.edits, edit)
	inventory_predict(s) // (one used up)
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
