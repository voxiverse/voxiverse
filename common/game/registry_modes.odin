package game

import "core:fmt"
import "core:slice"

// Game modes in the registry: data/game_modes/<name>.json,
//
//	{"abilities": ["fly", "invulnerable"], "kit": [{"item": "base:pickaxe", "count": 1}], "rules": {}}
//
// `rules` is reserved: only an empty object is accepted for now.

@(private)
read_game_mode :: proc(b: ^Reg_Build, m: ^Merged_Def, item_numbers: []Item) -> Mode_Def {
	def := Mode_Def {
		id = m.id,
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
						fmt.aprintf("a kit entry has item and count, not \"%s\"", em.key),
					)
				}
			}
			if have {append(&kit, entry)}
		}
		def.kit = kit[:]
	}
	return def
}
