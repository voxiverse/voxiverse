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
	quest_news:   Tween, // a step of a quest done: the tracker eases its new step in
	level_news:   Tween, // a level gained: the level beside the health bar pops
	heartbeat:    f64, // the feel clock at the low-health warning's last beat
	boss:         Maybe(game.Kind_Id), // a fight's foe a game shows its own bar of (hud_boss): the target frame leaves it out
}

// hud_boss: the kind of a fight's foe the game shows a bar of its own for while the fight
// is on (boss_bar; nil: none), which the target frame leaves out, so it is not shown twice.
hud_boss :: proc(s: ^Session, kind: Maybe(game.Kind_Id)) {s.hud.boss = kind}

// feed_experience: a line of the pickup feed for experience earned ("+25 XP": item
// NO_ITEM), or more on the newest such line while it is recent.
feed_experience :: proc(s: ^Session, gain: int) {
	h := &s.hud
	now := feel_now(s)
	if f := &h.feed[0];
	   f.count > 0 && f.item == game.NO_ITEM && feel_age(s, f.born) < PICKUP_MERGE {
		f.count += gain
		f.born = now
		return
	}
	copy(h.feed[1:], h.feed[:PICKUP_LINES - 1])
	h.feed[0] = {game.NO_ITEM, gain, now}
}

PICKUP_MERGE :: 2.0 // seconds: more of the newest line's item within this joins it
