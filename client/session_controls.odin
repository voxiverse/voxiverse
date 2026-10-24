package client

import "core:math"

import "../game"
import "../platform"

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
edit_controls :: proc(s: ^Session, input: ^Input_State, dt: f32) {
	keys := [?]platform.Key{.Num_1, .Num_2, .Num_3, .Num_4, .Num_5, .Num_6, .Num_7, .Num_8, .Num_9}
	slots := len(hotbar_items(s))
	for k, i in keys[:slots] {
		if k in input.pressed {s.hotbar = i}
	}
	if input.wheel.y != 0 {
		s.hotbar = (s.hotbar - int(math.sign(input.wheel.y)) + slots) % slots
	}
	s.hotbar = min(s.hotbar, slots - 1)

	s.edit_timer -= dt
	breaking := .Left in input.mouse_down
	placing := .Right in input.mouse_down
	pressed := input.mouse_pressed & {.Left, .Right} != {}
	if !(breaking || placing) || (!pressed && s.edit_timer > 0) {return}
	s.edit_timer = EDIT_REPEAT_SECONDS
	item_use(s, held_item(s), breaking, placing)
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
		   !game.can_place_at(current, block, edit.pos, s.prediction.state) {return false}
		edit.block = block
	}
	before, _ := world_block(&s.world, edit.pos)
	if !world_set_block(&s.world, edit.pos, edit.block) {return false}
	edit_sound(s, edit.pos, before, edit.block)
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
