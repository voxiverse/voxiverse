package client

import "../game"

// Items: what the hotbar holds and the mouse uses. A block is placed with
// the right button (the left breaks, or hits a critter); a tool is used
// with the left.

Tool :: enum u8 {
	Launcher, // fires rockets
}

Item :: union {
	game.Block,
	Tool,
}

Tool_Info :: struct {
	name:  string,
	cheat: bool, // only where the server allows cheats (creative tools)
}

@(rodata)
TOOL_INFO := [Tool]Tool_Info {
	.Launcher = {name = "rocket", cheat = true},
}

// HOTBAR: everything a player can hold, in hotbar order (at most nine).
HOTBAR := [?]Item {
	game.Block.Stone,
	game.Block.Dirt,
	game.Block.Grass,
	game.Block.Sand,
	game.Block.Log,
	game.Block.Leaves,
	game.Block.Water,
	game.Block.Lamp,
	Tool.Launcher,
}
#assert(len(HOTBAR) <= 9) // number keys 1-9

item_name :: proc(item: Item) -> string {
	switch v in item {
	case game.Block:
		return game.BLOCK_INFO[v].name
	case Tool:
		return TOOL_INFO[v].name
	}
	return ""
}

// hotbar_items: the hotbar here (cheat items only where cheats are allowed).
hotbar_items :: proc(s: ^Session) -> []Item {
	items := make([dynamic]Item, 0, len(HOTBAR), context.temp_allocator)
	cheats := session_can_cheat(s)
	for item in HOTBAR {
		if t, tool := item.(Tool); tool && TOOL_INFO[t].cheat && !cheats {continue}
		append(&items, item)
	}
	return items[:]
}

// held_item: the selected hotbar item.
held_item :: proc(s: ^Session) -> Item {
	items := hotbar_items(s)
	return items[clamp(s.hotbar, 0, len(items) - 1)]
}

// item_use: the mouse buttons with item held.
item_use :: proc(s: ^Session, item: Item, breaking, placing: bool) {
	switch v in item {
	case game.Block:
		if breaking && !placing && session_attack(s) {return}
		session_edit(s, placing && !breaking, v)
	case Tool:
		switch v {
		case .Launcher:
			if breaking {session_fire(s)}
		}
	}
}
