package delve

import "core:fmt"

import "common:base"
import "common:game"

// Delve: a co-op dungeon crawl seen from above. A dungeon is laid out from a seed
// (dungeon.odin): rooms and corridors, a start room, a boss's room. Creatures wait in the
// rooms until a delver comes near or into their sight, then fight: biters that swarm,
// husks that close in, spitters that keep their distance and spit, brutes that are slow
// and hit hard, and the warden in the deepest room. Delvers fight back with a melee weapon
// and a bow, a whirl on a cooldown and potions; kills give experience, and levels give
// health and damage. Creatures and chests drop coins, potions and weapons with a rolled
// rarity and bonus, better deeper. The warden's death opens the way down: the next
// dungeon is deeper, bigger and harder. A delver who dies wakes in the start room, his
// level kept, the experience towards the next lost, and half his coins.
//
// This is its shared package: the rules both sides know, what the server tells the
// players (records.odin), the dungeon's plan and the game's pack (pack.odin). The server
// part (games/delve/server) builds the dungeon and runs the fights; the client part
// (games/delve/client) shows them from above.

INFO :: game.Game_Info {
	id          = "delve",
	name        = "Delve",
	description = "Co-op dungeon crawl from above: fight, loot, go deeper.",
}

// Foe: the creatures (the pack's kinds of the same names), the warden last.
Foe :: enum u8 {
	Biter, // small, fast, weak: in packs
	Husk, // closes in and strikes
	Spitter, // keeps its distance and spits
	Brute, // slow, tough, strikes hard
	Warden, // the boss: strikes near, spits far, calls biters
}

Foe_Info :: struct {
	kind:  string, // its pack kind's name
	label: string, // what players read
	xp:    int, // experience its death gives
	aggro: f64, // blocks: it notices a delver this near that it sees
	keep:  [2]f32, // the distances it keeps from its prey (near, far)
	coins: int, // what it drops, at depth 1
}

@(rodata)
FOES := [Foe]Foe_Info {
	.Biter   = {"biter", "biter", 3, 9, {0, 0.5}, 1},
	.Husk    = {"husk", "husk", 8, 10, {0, 0.7}, 2},
	.Spitter = {"spitter", "spitter", 10, 13, {5, 8}, 3},
	.Brute   = {"brute", "brute", 20, 8, {0, 0.9}, 5},
	.Warden  = {"warden", "the Warden", 120, 14, {0, 1.2}, 40},
}

SPIT_RANGE :: 11.0 // blocks: a spitter (or the warden) spits at a delver this near
LEASH :: 30.0 // blocks: a creature whose prey is further gives up
WARDEN_CALL_SECONDS :: 12 // the warden calls biters this often
WARDEN_SPIT_FROM :: 4.0 // blocks: further than this, the warden spits

// Weapon: what the loot tables roll (the pack's items of the same names).
Weapon :: enum u8 {
	Sword,
	Axe,
	Bow,
}
@(rodata)
WEAPON_ITEMS := [Weapon]string {
	.Sword = "delve:sword",
	.Axe   = "delve:axe",
	.Bow   = "delve:bow",
}
@(rodata)
WEAPON_NAMES := [Weapon]string {
	.Sword = "sword",
	.Axe   = "axe",
	.Bow   = "bow",
}

COIN :: "delve:coin"
POTION :: "delve:potion"
DELVER_MODE :: "delve:delver"
CHEST_KIND :: "delve:chest"
FLOOR_BLOCK :: "delve:flagstone"
WALL_BLOCK :: "delve:wall"
MOSSY_BLOCK :: "delve:mossy_wall"
RUNE_BLOCK :: "delve:rune_pillar"
BRAZIER_BLOCK :: "delve:brazier"
BONES_BLOCK :: "delve:bones"
EXIT_BLOCK :: "delve:way_down"

// Rarity: a rolled weapon's grade; its bonus to damage grows with it.
Rarity :: enum u8 {
	Plain,
	Fine,
	Rare,
	Fabled,
}
@(rodata)
RARITY_NAMES := [Rarity]string {
	.Plain  = "plain",
	.Fine   = "fine",
	.Rare   = "rare",
	.Fabled = "fabled",
}
@(rodata)
RARITY_BONUS := [Rarity]int {
	.Plain  = 0,
	.Fine   = 15,
	.Rare   = 35,
	.Fabled = 60,
}

// A weapon's game data (game.Stack.data): its rarity over its bonus, percent.
// Stack.data 0 (a kit's weapon) is plain with no bonus.
loot_data :: proc(rarity: Rarity, bonus: int) -> u32 {
	return u32(rarity) << 16 | u32(clamp(bonus, 0, 0xffff))
}

loot_rarity :: proc(data: u32) -> Rarity {
	r := data >> 16
	return Rarity(r) if r <= u32(max(Rarity)) else .Plain
}

loot_bonus :: proc(data: u32) -> int {
	return int(data & 0xffff)
}

// loot_text: a rolled weapon as players read it ("rare axe +41%").
loot_text :: proc(weapon: Weapon, data: u32) -> string {
	if data == 0 {return WEAPON_NAMES[weapon]}
	return fmt.tprintf(
		"%s %s +%d%%",
		RARITY_NAMES[loot_rarity(data)],
		WEAPON_NAMES[weapon],
		loot_bonus(data),
	)
}

// loot_roll: a weapon from the loot tables at a depth (luck: an elite's or a boss's
// better odds, 0..3).
loot_roll :: proc(r: ^base.Rng, depth, luck: int) -> (weapon: Weapon, data: u32) {
	weapon = Weapon(base.rng_int_max(r, len(Weapon)))
	roll := base.rng_f64(r) - 0.04 * f64(depth) - 0.12 * f64(luck)
	rarity := Rarity.Plain
	switch {
	case roll < 0.03:
		rarity = .Fabled
	case roll < 0.15:
		rarity = .Rare
	case roll < 0.45:
		rarity = .Fine
	}
	bonus := RARITY_BONUS[rarity] + base.rng_int_max(r, 11) + 3 * (depth - 1)
	return weapon, loot_data(rarity, max(bonus, 1))
}

// Levels: experience to the next level, and what a level gives.
MAX_LEVEL :: 50

xp_to_next :: proc(level: int) -> int {
	return 20 + 15 * level * level
}

// level_health: health points a level adds to a delver's most.
level_health :: proc(level: int) -> f32 {
	return 2 * f32(max(level, 1) - 1)
}

// level_damage: what a level multiplies a delver's damage by.
level_damage :: proc(level: int) -> f32 {
	return 1 + 0.1 * f32(max(level, 1) - 1)
}

// depth_toughness: what a depth multiplies its creatures' health and damage by.
depth_toughness :: proc(depth: int) -> f32 {
	return 1 + 0.35 * f32(max(depth, 1) - 1)
}

ELITE_HEALTH :: 2.5 // an elite's health, times its kind's
ELITE_DAMAGE :: 1.5
CRIT_CHANCE :: 0.1
CRIT_DAMAGE :: 2.0

// The whirl (game action 0): every creature around the delver is struck.
WHIRL_SECONDS :: 8
WHIRL_RADIUS :: 3.5
WHIRL_DAMAGE :: 6

// The potion (game action 1).
POTION_HEAL :: 8

// ACTIONS: the names of the game's actions, in order (the client part's Game.actions).
ACTIONS :: []string{"Whirl", "Drink potion"}

// An elite's name: two syllables of one list and one of another.
@(rodata)
NAME_HEADS := [?]string{"Gor", "Ul", "Vex", "Mor", "Skar", "Dra", "Nim", "Kel", "Zub", "Ash"}
@(rodata)
NAME_TAILS := [?]string {
	"rak",
	"gash",
	"mire",
	"tooth",
	"vane",
	"rot",
	"hask",
	"lun",
	"drel",
	"kin",
}

elite_name :: proc(r: ^base.Rng) -> string {
	return fmt.tprintf(
		"%s%s",
		NAME_HEADS[base.rng_int_max(r, len(NAME_HEADS))],
		NAME_TAILS[base.rng_int_max(r, len(NAME_TAILS))],
	)
}
