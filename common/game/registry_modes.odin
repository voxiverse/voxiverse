package game

import "core:fmt"
import "core:slice"

// Game modes in the registry: data/game_modes/<name>.json,
//
//	{"abilities": ["fly", "invulnerable"], "kit": [{"item": "base:pickaxe", "count": 1}], "rules": {}}
//
// `rules` is reserved: only an empty object is accepted for now. `weapons` (optional)
// tunes weapons for the players in the mode: `{"voxiverse:pistol": {<a weapon object>}}`,
// each a whole weapon (as an item's `weapon`) in place of that item's own while a player
// is in the mode (weapon_of); the item must be a weapon.

@(private)
read_game_mode :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	m: ^Merged_Def,
	item_numbers: []Item,
) -> Mode_Def {
	def := Mode_Def {
		id = m.id,
	}
	if f := field_of(m, "weapons"); f != nil {
		if f.value.kind != .Object {
			fail_field(b, f, f.value, "weapons is {\"<item id>\": {<a weapon object>}, ...}")
		} else {
			weapons := make([dynamic]Mode_Weapon)
			for e in f.value.members {
				at, known := ref_index(b, .Item, e.key, f, e.value)
				if !known {continue}
				item := item_numbers[at]
				if info, _ := item_info(reg, item); info.weapon == nil {
					fail_field(b, f, e.value, fmt.aprintf("%s is not a weapon", e.key))
					continue
				}
				if w, ok := read_weapon(b, f, e.value, item_numbers); ok {
					append(&weapons, Mode_Weapon{item, w})
				}
			}
			def.weapons = weapons[:]
		}
	}
	if f := field_of(m, "abilities"); f != nil {
		if f.value.kind != .Array {
			fail_field(b, f, f.value, "abilities is a list of ability names")
		} else {
			for e in f.value.items {
				if e.kind != .String {
					fail_field(b, f, e, "an ability is a name such as \"fly\"")
					continue
				}
				a, ok := ability_parse(e.s)
				if !ok {
					fail_field(
						b,
						f,
						e,
						fmt.aprintf(
							"\"%s\" is not an ability%s",
							e.s,
							suggestion(e.s, slice.enumerated_array(&ABILITY_NAMES), false),
						),
					)
					continue
				}
				def.abilities += {a}
			}
		}
	}
	if f := field_of(m, "rules"); f != nil {
		if f.value.kind != .Object || len(f.value.members) != 0 {
			fail_field(b, f, f.value, "rules is reserved: an empty object for now")
		}
	}
	if f := field_of(m, "kit"); f != nil {
		if f.value.kind != .Array {
			fail_field(b, f, f.value, "kit is a list of {\"item\": ..., \"count\": ...}")
			return def
		}
		kit := make([dynamic]Kit_Entry)
		for e in f.value.items {
			if e.kind != .Object {
				fail_field(b, f, e, "a kit entry is {\"item\": \"<id>\", \"count\": 1}")
				continue
			}
			entry := Kit_Entry {
				count = 1,
			}
			have := false
			for em in e.members {
				switch em.key {
				case "item":
					if em.value.kind != .String {
						fail_field(b, f, em.value, "item is an item id")
						continue
					}
					if at, ok := ref_index(b, .Item, em.value.s, f, em.value); ok {
						entry.item, have = item_numbers[at], true
					}
				case "slot":
					if em.value.kind != .String {
						fail_field(b, f, em.value, "slot is hotbar, pockets or a worn slot")
						continue
					}
					switch em.value.s {
					case "hotbar":
						entry.place = .Hotbar
					case "pockets":
						entry.place = .Pockets
					case:
						worn := -1
						for name, i in EQUIP_NAMES {if name == em.value.s {worn = i}}
						if worn < 0 {
							fail_field(
								b,
								f,
								em.value,
								"slot is \"hotbar\", \"pockets\" or one of head, chest, legs, feet, offhand",
							)
							continue
						}
						entry.place, entry.worn = .Worn, Equip_Slot(worn)
					}
				case "count":
					if em.value.kind != .Int || em.value.i < 1 || em.value.i > 4096 {
						fail_field(b, f, em.value, "count is 1..4096")
					} else {
						entry.count = u16(em.value.i)
					}
				case:
					fail_field(
						b,
						f,
						em.value,
						fmt.aprintf("a kit entry has item, count and slot, not \"%s\"", em.key),
					)
				}
			}
			if have {append(&kit, entry)}
		}
		def.kit = kit[:]
	}
	return def
}
