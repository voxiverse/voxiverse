package game

import "core:strings"

// Abilities: what a character can do, as data. A game mode is a profile of
// abilities (data/game_modes/<name>.json in a pack); the abilities in play are
// the mode's profile plus what the character wears (derive_abilities, beside
// derive_mods: the server and the client's prediction both call it with the
// same mode and inventory, so flight is predicted). No code asks which mode a
// player is in: systems ask for an ability. A new mode is a data file; a new
// ability is a value here and the system that asks for it.
//
// Permissions (permissions.odin) are what a player may *ask for*; abilities are
// what their character *can do*. They are kept apart.

Ability :: enum u8 {
	Fly, // may fly (with the world's allow_flying rule on)
	Invulnerable, // damage does nothing
	Instant_Break, // blocks break at once (read when break times exist)
	Infinite_Items, // placing and breaking use nothing up and leave nothing
	Catalog, // may take any item from the catalog
	Health, // has health (a bar; damage applies)
	Regenerate, // health comes back by itself (the world's natural_regeneration rule)
	Drop_On_Death, // the inventory drops where they fell (unless the world keeps it)
}

Abilities :: bit_set[Ability;u32]

ABILITY_NAMES := [Ability]string {
	.Fly            = "fly",
	.Invulnerable   = "invulnerable",
	.Instant_Break  = "instant_break",
	.Infinite_Items = "infinite_items",
	.Catalog        = "catalog",
	.Health         = "health",
	.Regenerate     = "regenerate",
	.Drop_On_Death  = "drop_on_death",
}

ability_name :: proc(a: Ability) -> string {return ABILITY_NAMES[a]}

ability_parse :: proc(text: string) -> (a: Ability, ok: bool) {
	for n, i in ABILITY_NAMES {if n == text {return i, true}}
	return {}, false
}

// Kit_Place: where a kit's stack goes.
Kit_Place :: enum u8 {
	Anywhere, // the first free slot, hotbar first
	Hotbar,
	Pockets, // the grid beyond the hotbar
	Worn, // the equipment slot Kit_Entry.worn
}

// Kit_Entry: a stack a mode's kit gives.
Kit_Entry :: struct {
	item:  Item,
	count: u16,
	place: Kit_Place,
	worn:  Equip_Slot,
}

// Mode_Def: a game mode from a pack.
Mode_Def :: struct {
	id:        string, // "base:survival"
	abilities: Abilities,
	kit:       []Kit_Entry,
}

NO_MODE :: -1

// mode_find: the index in reg.game_modes of the mode with this id; a bare
// name ("survival") means the base pack's.
mode_find :: proc(reg: ^Registry, text: string) -> (index: int, ok: bool) {
	full := text
	if !strings.contains(text, ":") {
		full = strings.concatenate({BASE_NAMESPACE, ":", text}, context.temp_allocator)
	}
	if at, found := reg.ids[.Game_Mode][full]; found {return int(at), true}
	return NO_MODE, false
}

// mode_label: a mode's id without the base namespace ("survival", "demo:adventure").
mode_label :: proc(reg: ^Registry, mode: int) -> string {
	if mode < 0 || mode >= len(reg.game_modes) {return ""}
	return strings.trim_prefix(reg.game_modes[mode].id, BASE_NAMESPACE + ":")
}

// mode_abilities: the profile of mode (nothing for an unknown one).
mode_abilities :: proc(reg: ^Registry, mode: int) -> Abilities {
	if mode < 0 || mode >= len(reg.game_modes) {return {}}
	return reg.game_modes[mode].abilities
}

// derive_abilities: what a character in mode wearing inv can do: the mode's
// profile, then the equipment's grants and revokes.
derive_abilities :: proc(reg: ^Registry, mode: int, inv: ^Inventory) -> (a: Abilities) {
	a = mode_abilities(reg, mode)
	for st in inv.equipment {
		if stack_empty(st) {continue}
		info, _ := item_info(reg, st.item)
		for mod in info.modifiers {
			at := int(mod.amount)
			if at < 0 || at >= len(Ability) {continue}
			#partial switch mod.kind {
			case .Grant_Ability:
				a += {Ability(at)}
			case .Revoke_Ability:
				a -= {Ability(at)}
			}
		}
	}
	return
}
