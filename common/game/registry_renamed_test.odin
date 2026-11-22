package game

import "core:fmt"
import "core:testing"

// A pack's "renamed": the ids it no longer has find the ids that took their place (a save
// naming the old id loads), of every kind looked up by id, and the hash covers them.
@(test)
test_renamed_ids :: proc(t: ^testing.T) {
	manifest := `{"format": 1, "namespace": "farm", "version": "1", "requires": ["voxiverse"],
		"renamed": {"plough": "voxiverse:rifle", "farm:boulder": "stone", "scarecrow": "voxiverse:dummy"}}`
	farm := pack_of("farm", {{"data/blocks/a.json", `{"hay": {"material": "thatch"}}`}}, manifest)
	reg, errs := build_with(farm)
	testing.expect_value(t, errors_text(errs), "")
	if reg == nil {return}
	rifle, _ := registry_item(reg, "voxiverse:rifle")
	plough, found := registry_item(reg, "farm:plough")
	testing.expect(t, found)
	testing.expect_value(t, plough, rifle)
	stone, _ := registry_block(reg, "stone")
	boulder, found_block := registry_block(reg, "farm:boulder")
	testing.expect(t, found_block)
	testing.expect_value(t, boulder, stone)
	scarecrow, found_kind := registry_kind(reg, "farm:scarecrow")
	testing.expect(t, found_kind)
	testing.expect_value(t, scarecrow, reg.engine.dummy)
	// Only the old ids are renamed; one never defined is still unknown.
	_, unknown := registry_item(reg, "farm:spade")
	testing.expect(t, !unknown)

	plain := pack_of("farm", {{"data/blocks/a.json", `{"hay": {"material": "thatch"}}`}})
	without, _ := build_with(plain)
	if without == nil {return}
	testing.expect(t, without.hash != reg.hash, "a rename changes the registry's hash")
	_, before := registry_item(without, "farm:plough")
	testing.expect(t, !before)
}

@(test)
test_renamed_refusals :: proc(t: ^testing.T) {
	Case :: struct {
		name, renamed, want: string,
	}
	cases := []Case {
		{
			"another pack's id",
			`{"voxiverse:rock": "stone"}`,
			`farm/pack.json:1:64: "voxiverse:rock" is not an id of this pack's; a pack renames only its own ("farm:name")`,
		},
		{
			"an id still defined",
			`{"hay": "stone"}`,
			`farm/pack.json:1:64: "farm:hay" is still defined; rename only an id that is gone`,
		},
		{
			"to an id no pack has",
			`{"plough": "voxiverse:plough"}`,
			`farm/pack.json:1:64: "farm:plough" is renamed to "voxiverse:plough", which no pack defines`,
		},
		{
			"not a string",
			`{"plough": 3}`,
			`farm/pack.json:1:74: a renamed id's new id is a string, "namespace:name"`,
		},
	}
	for c in cases {
		manifest := fmt.tprintf(
			`{{"format": 1, "namespace": "farm", "version": "1", "renamed": %s}}`,
			c.renamed,
		)
		farm := pack_of(
			"farm",
			{{"data/blocks/a.json", `{"hay": {"material": "thatch"}}`}},
			manifest,
		)
		reg, errs := build_with(farm)
		testing.expectf(t, reg == nil, "%s: should be refused", c.name)
		testing.expectf(
			t,
			errors_text(errs) == c.want,
			"%s:\n--- got:\n%s\n--- want:\n%s",
			c.name,
			errors_text(errs),
			c.want,
		)
	}
}
