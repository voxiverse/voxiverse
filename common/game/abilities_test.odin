package game

import "core:strings"
import "core:testing"

// Game modes are data: profiles of abilities. A mode defined only in a pack
// works with no code naming it; derive_abilities adds the equipment's grants.

@(test)
test_base_modes_are_profiles :: proc(t: ^testing.T) {
	src := base_pack_source(context.temp_allocator)
	reg, errs := registry_build({src}, .Server, context.temp_allocator)
	testing.expect(t, reg != nil, errors_text(errs))
	if reg == nil {return}
	creative, ok1 := mode_find(reg, "creative")
	survival, ok2 := mode_find(reg, "voxiverse:survival")
	testing.expect(t, ok1 && ok2)
	c, s := mode_abilities(reg, creative), mode_abilities(reg, survival)
	testing.expect(t, .Fly in c && .Invulnerable in c && .Catalog in c && .Infinite_Items in c)
	testing.expect(t, .Health in s && .Regenerate in s && .Fly not_in s && .Catalog not_in s)
	testing.expect_value(t, mode_label(reg, survival), "survival")
	_, nope := mode_find(reg, "spectator")
	testing.expect(t, !nope)
}

@(test)
test_a_pack_defines_a_mode :: proc(t: ^testing.T) {
	pack := pack_of(
		"modes",
		{
			{
				"data/game_modes/spectator.json",
				`{"spectator": {"abilities": ["fly", "invulnerable"], "kit": [{"item": "voxiverse:stone", "count": 3}]}}`,
			},
		},
	)
	reg, errs := build_with(pack)
	testing.expect(t, reg != nil, errors_text(errs))
	if reg == nil {return}
	m, ok := mode_find(reg, "modes:spectator")
	testing.expect(t, ok)
	testing.expect_value(t, mode_abilities(reg, m), Abilities{.Fly, .Invulnerable})
	testing.expect_value(t, len(reg.game_modes[m].kit), 1)
	testing.expect_value(t, reg.game_modes[m].kit[0].count, 3)
	inv: Inventory
	testing.expect_value(t, derive_abilities(reg, m, &inv), Abilities{.Fly, .Invulnerable})
}

@(test)
test_unknown_ability_is_a_load_error :: proc(t: ^testing.T) {
	pack := pack_of("modes", {{"data/game_modes/x.json", `{"x": {"abilities": ["flying"]}}`}})
	reg, errs := build_with(pack)
	testing.expect(t, reg == nil)
	testing.expect(t, strings.contains(errors_text(errs), "\"flying\" is not an ability"))
}

@(test)
test_worn_items_grant_and_revoke_abilities :: proc(t: ^testing.T) {
	src := base_pack_source(context.temp_allocator)
	reg, _ := registry_build({src}, .Server, context.temp_allocator)
	if !testing.expect(t, reg != nil) {return}
	survival, _ := mode_find(reg, "survival")
	cap := item_of_armor(.Cap)
	info := &reg.items.armor[.Cap]
	saved := info.modifiers
	defer info.modifiers = saved
	info.modifiers = [2]Modifier {
		{.Grant_Ability, f32(Ability.Fly)},
		{.Revoke_Ability, f32(Ability.Health)},
	}
	inv: Inventory
	testing.expect_value(
		t,
		derive_abilities(reg, survival, &inv),
		Abilities{.Health, .Regenerate, .Drop_On_Death},
	)
	inv.equipment[.Head] = {cap, 1, 0}
	testing.expect_value(
		t,
		derive_abilities(reg, survival, &inv),
		Abilities{.Fly, .Regenerate, .Drop_On_Death},
	)
}
