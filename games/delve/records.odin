package delve

import "common:game"

// What the game replicates besides the engine's kinds (docs/games.md): the dungeon (a
// singleton), every delver's progress (keyed by player id, put to every player, so the
// scoreboard is whole on each side), a tag on each creature a player knows (keyed by
// the entity: its name, rank and level), and events: a hit's damage (the numbers that
// float up), a level gained, the warden's fall, a new dungeon.

Phase :: enum u8 {
	Building, // the dungeon's blocks are on their way
	Delving, // the warden lives
	Open, // the warden is dead: the way down is open
}

Delve :: struct {
	phase:  Phase,
	depth:  u8,
	seed:   u32,
	foes:   u16, // creatures alive
	warden: u32, // its entity id (0: dead, or none yet)
}

// Hero: a delver's progress (the key is its player id).
Hero :: struct {
	name:    string `net:"max=16"`,
	level:   u8,
	xp:      u32, // towards the next level
	next:    u32, // what the next level needs
	kills:   u32,
	deaths:  u16,
	best:    u8, // the deepest dungeon reached
	whirl:   u16, // ticks until the whirl is ready (0: ready)
	potions: u16,
	coins:   u32,
}

// Foe_Tag: a creature's tag (the key is its entity id).
Foe_Tag :: struct {
	name:  string `net:"max=16"`, // an elite's or the warden's ("": a common one)
	foe:   Foe,
	level: u8, // the depth it was made for
	elite: bool,
}

// Hit: harm done, where (a creature's middle or a delver's): what floats up.
Hit :: struct {
	at:     [3]f32,
	amount: u16,
	crit:   bool,
	taken:  bool, // a delver was hurt (red), not a creature
}

Level_Up :: struct {
	level: u8,
}

Warden_Down :: struct {
	by: string `net:"max=16"`, // the delver who dealt the last blow
}

Descended :: struct {
	depth: u8,
}

MAX_TAGS :: 256

KINDS :: game.Game_Kinds {
	states = {
		{name = "delve.delve", value = Delve},
		{name = "delve.hero", value = Hero, key = .Player, max_records = game.MAX_PLAYERS},
		{name = "delve.foe", value = Foe_Tag, key = .Entity, max_records = MAX_TAGS},
	},
	events = {
		{name = "delve.hit", value = Hit},
		{name = "delve.level_up", value = Level_Up},
		{name = "delve.warden_down", value = Warden_Down},
		{name = "delve.descended", value = Descended},
	},
}
