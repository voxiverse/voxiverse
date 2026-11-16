package horde

import "common:game"

// What the game replicates besides the engine's kinds (docs/games.md): the run (a
// singleton), every survivor's purse and tally (keyed by player id, put to every player,
// so the scoreboard is whole on each side), and a wave as it sets out or is held.

Run :: struct {
	phase:    Phase,
	run:      u16,
	wave:     u16, // on now, or the last (0: none yet)
	left:     u16, // seconds left of the countdown, the break or the run's end
	alive:    u16, // creatures in the yard
	to_come:  u16, // ... still to come out of the lairs
	best:     u16, // the best wave any run here reached
	standing: u8, // survivors not down
	players:  u8, // survivors in the run
	seed:     u32, // the yard's
	prices:   [Ware]u16, // what the shop asks (the gun's: the next one's, for this player)
}

// Survivor: a survivor's purse and tally (the key is its player id).
Survivor :: struct {
	name:  string `net:"max=16"`,
	coins: u32,
	kills: u32,
	downs: u16, // times down this run
	down:  bool, // down now: watching until the wave ends
	guns:  u8, // guns bought
}

// Wave_News: a wave set out (held false) or was held.
Wave_News :: struct {
	wave: u16,
	size: u16,
	boss: bool,
	held: bool,
}

KINDS :: game.Game_Kinds {
	states = {
		{name = "horde.run", value = Run},
		{name = "horde.survivor", value = Survivor, key = .Player, max_records = game.MAX_PLAYERS},
	},
	events = {{name = "horde.wave_news", value = Wave_News}},
}
