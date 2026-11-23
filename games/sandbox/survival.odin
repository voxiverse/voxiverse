package sandbox

import "core:strings"

import "common:game"

// The survival loop's rules, both parts' (README.md, "Gathering, crafting and outposts"):
// where a recipe of the pack is made (by hand anywhere, or within reach of a fabricator),
// whether what a player carries makes it, and what an item is called on the screen. The
// recipes themselves are the pack's (pack/data/recipes/survival.json).

HAND :: "sandbox:hand" // a recipe made by hand, anywhere (its `machine`)
FABRICATOR :: "sandbox:fabricator" // ... made within FABRICATOR_REACH of a fabricator; also the block
BEACON_BLOCK :: "sandbox:outpost_beacon"
FABRICATOR_REACH :: 5 // blocks, each way, from the player's feet
OUTPOST_RADIUS :: 48 // blocks round a beacon (horizontally) where no hostile creature comes by itself
MAX_OUTPOSTS :: 32 // beacons a world keeps; the most a player is shown

// Station: where a recipe is made.
Station :: enum u8 {
	Hand,
	Fabricator,
}

// recipe_station: where r is made; false for a recipe that is not the sandbox's (the
// crafting grid's, another game's process).
recipe_station :: proc(r: ^game.Recipe_Def) -> (Station, bool) {
	switch r.machine {
	case HAND:
		return .Hand, true
	case FABRICATOR:
		return .Fabricator, true
	}
	return {}, false
}

// carried: how many of an item (or, with a tag, of the tag's items) the inventory holds in
// its slots.
carried :: proc(reg: ^game.Registry, inv: ^game.Inventory, item: game.Item, tag: i32) -> int {
	if tag == game.NO_TAG {return game.inventory_count(inv, item)}
	n := 0
	for st in inv.slots {
		if !game.stack_empty(st) && game.registry_item_in_tag(reg, st.item, tag) {n += st.count}
	}
	return n
}

// can_make: the inventory holds every input of r.
can_make :: proc(reg: ^game.Registry, r: ^game.Recipe_Def, inv: ^game.Inventory) -> bool {
	needs, tags, n := game.recipe_needs(r)
	for i in 0 ..< n {
		if carried(reg, inv, needs[i].item, tags[i]) < needs[i].count {return false}
	}
	return true
}

// item_label: an item as a player reads it: its name without the namespace, its words
// spaced and the first capitalised ("sandbox:flint_pick": "Flint pick").
item_label :: proc(
	reg: ^game.Registry,
	item: game.Item,
	allocator := context.temp_allocator,
) -> string {
	return id_label(game.item_id(reg, item), allocator)
}

// id_label: an id as a player reads it (item_label).
id_label :: proc(id: string, allocator := context.temp_allocator) -> string {
	name := id
	if at := strings.index_byte(name, ':'); at >= 0 {name = name[at + 1:]}
	b := transmute([]u8)strings.clone(name, allocator)
	for &c, i in b {
		if c == '_' {c = ' '}
		if i == 0 && c >= 'a' && c <= 'z' {c -= 'a' - 'A'}
	}
	return string(b)
}
