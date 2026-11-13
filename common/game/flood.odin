package game

// proto/flood: the Flood round as the server tells each player (server/core/flood.odin
// runs it; client/hud/flood.odin draws it). Throwaway prototype code.

Flood_Phase :: enum u8 {
	Waiting, // nobody here yet
	Countdown, // the arena is built, the round starts soon
	Playing,
	Reveal, // the round is over: its rule is shown
}

Flood_Rule :: enum u8 {
	Baseline, // the water rises steadily
	Tide, // it surges and retreats, rising overall
	Rot, // what the water touches crumbles
	Heavy, // explosions are huge and throw hard
}

FLOOD_RULE_NAMES := [Flood_Rule]string {
	.Baseline = "baseline",
	.Tide     = "tide",
	.Rot      = "rot",
	.Heavy    = "heavy",
}

FLOOD_RULE_TITLES := [Flood_Rule]string {
	.Baseline = "BASELINE: the water just rose",
	.Tide     = "TIDE: the water surged and fell back",
	.Rot      = "ROT: wet blocks crumbled",
	.Heavy    = "HEAVY BLAST: explosions were huge",
}

Flood_Result :: enum u8 {
	None,
	Won, // everyone still in stood on the goal
	Lost, // everyone drowned
	Time_Up,
}

// Flood_State: the round now. seconds counts whole seconds into the phase, so
// the record changes once a second (and when something happens).
Flood_State :: struct {
	phase:     Flood_Phase,
	rule:      Flood_Rule, // shown only in the debug overlay (and at the reveal)
	result:    Flood_Result,
	round:     u16,
	seed:      u32,
	seconds:   u16,
	countdown: u8, // seconds left in Countdown / Reveal
	level:     i16, // the water's top layer (y)
	goal_y:    i16, // the goal platform's top block
	goal_x:    i16, // its corner (it is FLOOD_GOAL_SIZE square)
	goal_z:    i16,
	players:   u8, // in the round
	alive:     u8,
	on_goal:   u8,
	made_it:   u8, // at the end
	out:       bool, // this player is out (spectating)
	under:     u8, // tenths of a second the head has been under water
}

FLOOD_GOAL_SIZE :: 7
