package horde

import "core:testing"

import "common:game"

// Horde's pack tunes the base pack's guns while Horde is played (its numbers, loading
// rounds) and leaves them as they are everywhere else; the guns' old ids find them.
@(test)
test_the_guns_are_the_base_packs_tuned :: proc(t: ^testing.T) {
	base := game.registry_base(context.temp_allocator)
	reg, errs := game.registry_build(
		{game.base_pack_source(context.temp_allocator), PACK},
		.Server,
		context.temp_allocator,
	)
	testing.expect_value(t, len(errs), 0)
	if reg == nil || base == nil {return}
	weapon :: proc(reg: ^game.Registry, id: string) -> game.Weapon_Info {
		item, _ := game.registry_item(reg, id)
		info, _ := game.registry_item_info(reg, item)
		return info.weapon.? or_else {}
	}
	round, _ := game.registry_item(reg, ROUND_ITEM)
	Gun :: struct {
		id:          string,
		horde, open: f32, // its damage here and in every other game
	}
	for g in ([]Gun{{"voxiverse:pistol", 4, 5}, {"voxiverse:rifle", 3, 3}, {"voxiverse:shotgun", 2, 2}}) {
		testing.expect_value(t, weapon(reg, g.id).damage, g.horde)
		testing.expect_value(t, weapon(reg, g.id).ammo, round)
		testing.expect_value(t, weapon(base, g.id).damage, g.open)
		testing.expect_value(t, weapon(base, g.id).ammo, game.NO_ITEM)
	}
	testing.expect_value(t, weapon(reg, "voxiverse:pistol").range, 80)
	testing.expect_value(t, weapon(base, "voxiverse:pistol").range, 100)
	old, found := game.registry_item(reg, "horde:pistol")
	pistol, _ := game.registry_item(reg, "voxiverse:pistol")
	testing.expect(t, found)
	testing.expect_value(t, old, pistol)
}
