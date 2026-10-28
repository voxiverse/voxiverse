package game

// Modifiers: what the things a character wears or holds change about them,
// as data on the item (Item_Info.modifiers), gathered by one function
// (derive_mods) that the server and the client's prediction both call with
// the same inventory, so prediction stays exact. Only the equipment slots
// count (worn armor, the offhand), not what is in the pockets.

BASE_HEALTH :: 20 // health points (two to a heart)

Modifier_Kind :: enum u8 {
	Speed, // walking, sprinting and sneaking: +0.1 is ten percent faster
	Jump, // jump height: +0.1 is ten percent higher
	Air_Jumps, // jumps in the air before landing
	Max_Health, // health points
}

Modifier :: struct {
	kind:   Modifier_Kind,
	amount: f32,
}

// Mods: the numbers physics and rules read for one character.
Mods :: struct {
	speed:      f32, // multiplier
	jump:       f32, // multiplier
	air_jumps:  u8,
	max_health: f32,
}

MODS_NONE :: Mods{1, 1, 0, BASE_HEALTH}

// derive_mods: what inv's equipment makes of a character.
derive_mods :: proc(reg: ^Registry, inv: ^Inventory) -> (m: Mods) {
	m = MODS_NONE
	air := f32(0)
	for st in inv.equipment {
		if stack_empty(st) {continue}
		info, _ := item_info(reg, st.item)
		for mod in info.modifiers {
			switch mod.kind {
			case .Speed:
				m.speed += mod.amount
			case .Jump:
				m.jump += mod.amount
			case .Air_Jumps:
				air += mod.amount
			case .Max_Health:
				m.max_health += mod.amount
			}
		}
	}
	m.air_jumps = u8(clamp(air, 0, 3))
	m.speed = clamp(m.speed, 0.5, 3)
	m.jump = clamp(m.jump, 0.5, 3)
	return
}
