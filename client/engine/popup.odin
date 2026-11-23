package engine

import "common:game"

// What the HUD keeps from one frame to the next (client/hud): the held item's name, and
// in a world (Session.hud, so a new world starts it afresh) the pickup feed, the health
// bar's trail and the target frame.

Item_Popup :: struct {
	seen:   bool, // a slot has been seen (not yet: the first frame in a world shows)
	slot:   int, // the slot last seen selected
	age:    f32, // seconds since it began
	item:   game.Item,
	active: bool,
}

// popup_reset: out of a world (the next one starts afresh).
popup_reset :: proc(p: ^Item_Popup) {
	p^ = {}
}

TARGET_RANGE :: 48 // blocks: a creature this near under the crosshair is shown in the target frame
PICKUP_LINES :: 5 // lines the pickup feed shows at once
PICKUP_TALLY :: game.TOTAL_SLOTS + 1 // items the feed's tally holds: a slot each and the cursor

// Pickup_Line: "+3 iron ore": what came into the inventory, and when (the feel clock's
// ticks: a line stands while the world does).
Pickup_Line :: struct {
	item:  game.Item,
	count: int,
	born:  f64,
}

// Hud_State: the session's HUD between frames.
Hud_State :: struct {
	feed:         [PICKUP_LINES]Pickup_Line, // newest first (count 0: none)
	tally:        [PICKUP_TALLY]game.Stack, // the inventory's items, totalled, as last seen
	tally_len:    int,
	tallied:      bool, // a tally was taken (the first is no news)
	trail:        f32, // the health before the last hits: the bar's trail, falling to the health
	trail_health: f32, // the health last seen
	trail_born:   f64, // the feel clock when the last hit came
	aimed:        Maybe(u32), // the creature under the crosshair within TARGET_RANGE, nearer than any block (aim_update)
	target:       Maybe(u32), // the creature the target frame shows
	target_seen:  f64, // the feel clock's tick it was last under the crosshair
}
