package client

import "core:math"

import "../common/game"

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
// opens: the server answers with its contents); false if it is not.
session_use_block :: proc(s: ^Session) -> bool {
	hit, aimed := s.aim.?
	if !aimed {return false}
	if b, _ := world_block(&s.world, hit.block); b != .Chest {return false}
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

	s.edit_timer -= dt
	breaking := action_down(a, .Attack)
	placing := action_down(a, .Use)
	pressed := action_pressed(a, .Attack) || action_pressed(a, .Use)
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
		   (game.block_is_plant(block) && !plant_stands(s, edit.pos, block)) ||
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

// session_till makes farmland of the aimed grass or dirt (the hoe, right
// button): predicted now, then sent like a placed block. False if it cannot.
session_till :: proc(s: ^Session) -> bool {
	hit, aimed := s.aim.?
	if !aimed || len(s.edits) >= MAX_PENDING_EDITS {return false}
	current, _ := world_block(&s.world, hit.block)
	above, loaded := world_block(&s.world, hit.block + {0, 1, 0})
	if !loaded || !game.can_till(current, above) {return false}
	edit := game.Edit {
		id    = s.next_edit + 1,
		after = s.prediction.next_sequence - 1,
		pos   = hit.block,
		block = .Farmland,
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

// plant_stands: the block under pos holds a plant (loaded and fit).
@(private = "file")
plant_stands :: proc(s: ^Session, pos: game.Block_Pos, plant: game.Block) -> bool {
	below, loaded := world_block(&s.world, pos + {0, -1, 0})
	return loaded && game.plant_supported(plant, below)
}
